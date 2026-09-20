#ps1_sysnative
# Runs once as SYSTEM via cloudbase-init's UserDataPlugin.
#
# NOTE ON TEMPLATING: this file goes through Terraform's templatefile().
# "$" followed by "{" and "%" followed by "{" are Terraform syntax, so
# PowerShell's dollar-brace form and the percent-brace ForEach-Object
# alias must NOT appear anywhere below -- Terraform would try to
# interpret them even inside a PowerShell comment. Plain $var and
# $($expr) are fine.
#
# NOTE ON SECRETS: user_data is readable by any process on the instance
# via the metadata service and the config drive — that is inherent to
# OpenStack. It is tolerable only because one VM serves exactly one
# student, so the only password here is that student's own. Never put a
# shared secret in this file.

$ErrorActionPreference = 'Continue'
$log = 'C:\appstore-bootstrap.log'
function Note($msg) {
    $line = "[$(Get-Date -Format o)] $msg"
    # stdout as well as the file: cloudbase-init copies it into the Nova
    # console log, which is readable with `openstack console log show`
    # even when nothing else about the VM is reachable.
    Write-Output "@@BOOTSTRAP $msg"
    Add-Content -Path $log -Value $line -ErrorAction SilentlyContinue
}

Note "start user=${username}"

$user     = '${username}'
$pass     = '${password}'
$isAdmin  = ('${is_admin}' -eq 'true')
$kmsHost  = '${kms_host}'
$fullName = '${displayname}'

# --- 1. Local account -------------------------------------------------
# The image ships with the built-in Administrator DISABLED (confirmed on
# the DHBW base image: cloudbase-init's CreateUserPlugin fails with
# "Das Konto ist momentan deaktiviert"). We therefore create our own
# account and leave Administrator disabled.
try {
    $sec = ConvertTo-SecureString $pass -AsPlainText -Force
    if (Get-LocalUser -Name $user -ErrorAction SilentlyContinue) {
        Set-LocalUser -Name $user -Password $sec
        Note "user exists, password reset"
    } else {
        New-LocalUser -Name $user -Password $sec -FullName $fullName `
            -PasswordNeverExpires -AccountNeverExpires -ErrorAction Stop | Out-Null
        Note "user created"
    }
} catch { Note "ERROR user: $($_.Exception.Message)" }

# Groups are resolved by well-known SID, never by name: the image is
# German, where these are "Remotedesktopbenutzer" and "Administratoren".
try {
    $rdpGroup = (Get-LocalGroup -SID 'S-1-5-32-555').Name
    Add-LocalGroupMember -Group $rdpGroup -Member $user -ErrorAction Stop
    Note "added to RDP group '$rdpGroup'"
} catch { Note "ERROR rdpgroup: $($_.Exception.Message)" }

if ($isAdmin) {
    try {
        $adminGroup = (Get-LocalGroup -SID 'S-1-5-32-544').Name
        Add-LocalGroupMember -Group $adminGroup -Member $user -ErrorAction Stop
        Note "added to admin group '$adminGroup'"
    } catch { Note "ERROR admingroup: $($_.Exception.Message)" }
} else {
    Note "student is NOT local admin (student_is_admin=false)"
}

# --- 2. Account lockout ----------------------------------------------
# RDP with password auth is a brute-force target even behind a scoped
# security group. 10 tries / 15 min observation, 15 min lockout.
try {
    & net accounts /lockoutthreshold:10 /lockoutduration:15 /lockoutwindow:15 | Out-Null
    Note "lockout policy set"
} catch { Note "ERROR lockout: $($_.Exception.Message)" }

# --- 3. Enable RDP ----------------------------------------------------
try {
    Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
        -Name fDenyTSConnections -Value 0 -ErrorAction Stop
    Note "fDenyTSConnections=0"
} catch { Note "ERROR fDeny: $($_.Exception.Message)" }

# NLA on: unauthenticated clients never reach the full RDP stack.
try {
    Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
        -Name UserAuthentication -Value 1 -ErrorAction Stop
    Note "NLA=1"
} catch { Note "ERROR nla: $($_.Exception.Message)" }

# An explicit rule rather than `Enable-NetFirewallRule -DisplayGroup
# 'Remote Desktop'`: that group name is localised ("Remotedesktop") and
# the English form silently matches nothing on this image.
try {
    if (-not (Get-NetFirewallRule -Name 'AppStore-RDP-In' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'AppStore-RDP-In' -DisplayName 'AppStore RDP (TCP 3389)' `
            -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow `
            -Profile Any -Enabled True -ErrorAction Stop | Out-Null
    }
    Note "firewall rule created"
} catch { Note "ERROR fwrule: $($_.Exception.Message)" }

# The registry flag alone does not bind the listener if TermService is
# not running.
try {
    Set-Service -Name TermService -StartupType Automatic -ErrorAction Stop
    Start-Service -Name TermService -ErrorAction SilentlyContinue
    $svc = Get-Service TermService
    Note "TermService $($svc.Status)/$($svc.StartType)"
} catch { Note "ERROR termservice: $($_.Exception.Message)" }

# --- 3b. Network profile ----------------------------------------------
# Windows classifies this network as "Oeffentlich" (Public) on first boot.
# The build image sets it to Private for WinRM, but that is a per-connection
# setting and does not survive into the deployed VM, so it has to be set
# again here. AppStore-RDP-In is scoped Profile Any and applies either way;
# this keeps the machine's own classification honest.
try {
    Get-NetConnectionProfile | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
    }
    Note "network profile set to Private"
} catch { Note "WARN could not set network profile: $($_.Exception.Message)" }

# --- 3c. IPv6 address --------------------------------------------------
# Set statically from the address Terraform allocated on the Neutron port
# rather than via DHCPv6. The subnet is dhcpv6-stateful and Windows will not
# take an address from it: it only solicits once a Router Advertisement sets
# the M flag, and the netsh parameters that would override that are rejected
# on this build. The guest then comes up holding only a link-local address,
# which from outside is indistinguishable from a blocked firewall.
#
# The port is created before the instance, so the address is known up front
# and nothing has to be discovered at boot.
$v6Addr   = '${ipv6_addr}'
$v6Prefix = '${ipv6_prefix}'
$v6Gw     = '${ipv6_gw}'

try {
    $ifIndex = (Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1).ifIndex

    $have = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $v6Addr }
    if (-not $have) {
        New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $v6Addr -PrefixLength $v6Prefix -ErrorAction Stop | Out-Null
    }
    Note "ipv6 $v6Addr/$v6Prefix on ifindex $ifIndex"
} catch { Note "ERROR ipv6 address: $($_.Exception.Message)" }

try {
    if (-not (Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction SilentlyContinue)) {
        New-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '::/0' -NextHop $v6Gw -ErrorAction Stop | Out-Null
    }
    Note "ipv6 default route via $v6Gw"
} catch { Note "ERROR ipv6 route: $($_.Exception.Message)" }

# --- 3d. RDP certificate ----------------------------------------------
# Self-signed, so a trust warning is unavoidable without a PKI. The NAME on
# it is what matters: it is the only check a student can make against the
# machine they were told to connect to.
#
# It must be issued explicitly, because letting TermService generate its own
# gets the name wrong. A Windows machine carries two names, and
# cloudbase-init's SetHostNamePlugin changes only the NetBIOS one:
#
#   NetBIOS computer : win11-xxxxxxxx      <- renamed
#   DNS computer     : DESKTOP-xxxxxxx     <- left at the sysprep value
#
# TermService names its certificate after the DNS hostname, so every
# regeneration landed back on the sysprep name. Terraform already knows the
# instance name, so it is passed in and used directly - no reboot, no race.

$certName = '${vm_name}'
Note "certificate name=$certName"

# Align the DNS hostname too, so the machine is internally consistent and
# anything else that reads it (and any certificate Windows reissues later
# on its own) gets the right name.
try {
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'Hostname' -Value $certName -ErrorAction Stop
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'NV Hostname' -Value $certName -ErrorAction Stop
    Note "dns hostname set to $certName"
} catch { Note "WARN dns hostname update failed: $($_.Exception.Message)" }

try {
    # Drop whatever TermService issued for itself on first start.
    Get-ChildItem 'Cert:\LocalMachine\Remote Desktop' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # Legacy SChannel CSP rather than CNG: it puts the private key in
    # MachineKeys as a file, which is what makes the ACL grant below
    # possible at all.
    $cert = New-SelfSignedCertificate -Subject "CN=$certName" -DnsName $certName `
        -CertStoreLocation 'Cert:\LocalMachine\My' `
        -Provider 'Microsoft RSA SChannel Cryptographic Provider' `
        -KeyExportPolicy NonExportable -KeySpec KeyExchange `
        -KeyLength 2048 -HashAlgorithm SHA256 `
        -NotAfter (Get-Date).AddYears(1) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.1') `
        -ErrorAction Stop

    # TermService runs as NETWORK SERVICE and cannot present a key it
    # cannot read. Granted by well-known SID, never by name: the image is
    # German, where this account is "NT-AUTORITAET\NETZWERKDIENST".
    if ($cert.PrivateKey -and $cert.PrivateKey.CspKeyContainerInfo) {
        $keyFile = Join-Path "$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys" $cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
        $acl = Get-Acl -Path $keyFile
        $sid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-20')
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'Read', 'Allow')))
        Set-Acl -Path $keyFile -AclObject $acl
        Note "private key readable by NETWORK SERVICE"
    } else {
        Note "WARN private key file not found - TermService may reject the certificate"
    }

    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'SSLCertificateSHA1Hash' `
        -Value $cert.GetCertHash() -Type Binary -ErrorAction Stop

    Restart-Service TermService -Force -ErrorAction Stop
    Start-Sleep -Seconds 5

    # Read back what is actually bound rather than trusting the write:
    # a certificate TermService silently refused looks identical from
    # here otherwise, and the student is the one who would find out.
    $bound = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'SSLCertificateSHA1Hash' -ErrorAction Stop).SSLCertificateSHA1Hash
    $boundHex = (($bound | ForEach-Object { $_.ToString('x2') }) -join '').ToUpper()
    if ($boundHex -eq $cert.Thumbprint.ToUpper()) {
        Note "rdp certificate bound subject=$($cert.Subject) thumbprint=$($cert.Thumbprint)"
    } else {
        Note "WARN rdp certificate mismatch bound=$boundHex expected=$($cert.Thumbprint)"
    }
} catch { Note "ERROR rdp certificate: $($_.Exception.Message)" }

# --- 4. Windows activation -------------------------------------------
# Base image is VOLUME_KMSCLIENT channel; it needs a reachable KMS,
# found either via DNS SRV (_vlmcs._tcp) or set explicitly here.
try {
    if ($kmsHost -ne '') {
        & cscript.exe //nologo "$env:SystemRoot\System32\slmgr.vbs" /skms $kmsHost | Out-Null
        Note "KMS host set to $kmsHost"
    }
    & cscript.exe //nologo "$env:SystemRoot\System32\slmgr.vbs" /ato | Out-Null
    Note "activation attempted exit=$LASTEXITCODE"

    # LicenseStatus: 0 unlicensed, 1 licensed, 2 OOB grace, 3 OOT grace,
    # 4 non-genuine, 5 notification, 6 extended grace. Students are not
    # local admins and slmgr needs elevation, so the answer has to reach
    # the console log rather than waiting for someone to check in-session.
    foreach ($lic in Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" -ErrorAction SilentlyContinue) {
        Note "activation name=$($lic.Name) status=$($lic.LicenseStatus) reason=$($lic.LicenseStatusReason) kms=$($lic.KeyManagementServiceMachine) grace_min=$($lic.GracePeriodRemaining)"
    }
} catch { Note "ERROR activation: $($_.Exception.Message)" }

# --- 5. Report listening state ---------------------------------------
# The listener needs a moment to bind after TermService starts, so poll
# rather than sampling once - a bare "not listening yet" told us nothing
# about whether it came up a second later.
try {
    $bound = $false
    foreach ($attempt in 1..30) {
        if (Get-NetTCPConnection -State Listen -LocalPort 3389 -ErrorAction SilentlyContinue) {
            $bound = $true
            $addrs = (Get-NetTCPConnection -State Listen -LocalPort 3389 |
                ForEach-Object { $_.LocalAddress }) -join ","
            Note "RDP LISTENING ok after $attempt checks on [$addrs]"
            break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $bound) { Note "ERROR: 3389 never started listening" }
} catch { Note "ERROR listen-check: $($_.Exception.Message)" }

Note "done"
