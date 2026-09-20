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

# Belt and braces: also enable whatever built-in RDP rules exist,
# matched by SID-independent group substring in either language.
try {
    Get-NetFirewallRule -Direction Inbound -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayGroup -match 'Remotedesktop|Remote Desktop' } |
        Enable-NetFirewallRule -ErrorAction SilentlyContinue
    Note "builtin RDP rules enabled"
} catch { Note "ERROR fwgroup: $($_.Exception.Message)" }

# The registry flag alone does not bind the listener if TermService is
# not running.
try {
    Set-Service -Name TermService -StartupType Automatic -ErrorAction Stop
    Start-Service -Name TermService -ErrorAction SilentlyContinue
    $svc = Get-Service TermService
    Note "TermService $($svc.Status)/$($svc.StartType)"
} catch { Note "ERROR termservice: $($_.Exception.Message)" }

# --- 3b. Network profile + firewall diagnostics -----------------------
# Windows classifies this network as "Oeffentlich" (Public) on first
# boot. The build image sets it to Private for WinRM, but that is a
# per-connection setting and does not survive into the deployed VM, so
# it has to be set again here. The AppStore-RDP-In rule is scoped
# Profile Any and should apply regardless - the diagnostics below exist
# so that if 3389 is still filtered we can see which of the two is
# actually to blame instead of guessing.
try {
    Get-NetConnectionProfile | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
    }
    Note "network profile set to Private"
} catch { Note "could not set network profile: $($_.Exception.Message)" }

try {
    foreach ($prof in Get-NetConnectionProfile) {
        Note "netprofile iface=$($prof.InterfaceAlias) category=$($prof.NetworkCategory)"
    }
    foreach ($fw in Get-NetFirewallProfile) {
        Note "fwprofile $($fw.Name) enabled=$($fw.Enabled) inbound=$($fw.DefaultInboundAction)"
    }
    $rule = Get-NetFirewallRule -Name 'AppStore-RDP-In' -ErrorAction SilentlyContinue
    if ($rule) {
        Note "rdprule enabled=$($rule.Enabled) profile=$($rule.Profile) action=$($rule.Action) dir=$($rule.Direction)"
        # enabled/profile/action looked correct while every inbound TCP
        # port still timed out, so report what the rule actually MATCHES.
        $pf = $rule | Get-NetFirewallPortFilter
        Note "rdprule filter proto=$($pf.Protocol) localport=$($pf.LocalPort) remoteport=$($pf.RemotePort)"
        $af = $rule | Get-NetFirewallAddressFilter
        Note "rdprule addrs local=$($af.LocalAddress) remote=$($af.RemoteAddress)"
    } else {
        Note "rdprule MISSING"
    }

    # Which IPv6 addresses does Windows actually hold? If this does not
    # include the address Neutron assigned to the port, packets to that
    # address are dropped before Windows ever sees them - which looks
    # exactly like a firewall problem from outside.
    foreach ($addr in Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue) {
        Note "ipv6 $($addr.IPAddress)/$($addr.PrefixLength) iface=$($addr.InterfaceAlias) origin=$($addr.PrefixOrigin)/$($addr.SuffixOrigin) state=$($addr.AddressState)"
    }
    foreach ($r in Get-NetRoute -AddressFamily IPv6 -ErrorAction SilentlyContinue) {
        if ($r.DestinationPrefix -eq "::/0") { Note "ipv6 defaultroute via $($r.NextHop) iface=$($r.InterfaceAlias)" }
    }
} catch { Note "diag error: $($_.Exception.Message)" }

# --- 3c. IPv6 address --------------------------------------------------
# Set statically from the address Terraform allocated on the Neutron
# port, rather than relying on DHCPv6.
#
# This subnet is dhcpv6-stateful, and Windows would not take an address
# from it. It only solicits once a Router Advertisement sets the M flag,
# and the netsh parameters that would override that are rejected on this
# build ("Falscher Parameter"). The guest therefore came up holding only
# a link-local address, which from outside is indistinguishable from a
# firewall blocking RDP - packets to the global address never arrived at
# all. Several rounds were spent on the wrong layer because of it.
#
# The port exists before the instance, so Terraform knows the address up
# front and there is no need to discover it at boot.
$v6Addr   = '${ipv6_addr}'
$v6Prefix = '${ipv6_prefix}'
$v6Gw     = '${ipv6_gw}'

try {
    $ifIndex = (Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1).ifIndex
    Note "ipv6 ifindex=$ifIndex target=$v6Addr/$v6Prefix gw=$v6Gw"

    $have = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $v6Addr }
    if ($have) {
        Note "ipv6 address already present"
    } else {
        New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $v6Addr -PrefixLength $v6Prefix -ErrorAction Stop | Out-Null
        Note "ipv6 static address set"
    }
} catch { Note "ERROR ipv6 address: $($_.Exception.Message)" }

try {
    $haveRoute = Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction SilentlyContinue
    if ($haveRoute) {
        Note "ipv6 default route already present"
    } else {
        New-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '::/0' -NextHop $v6Gw -ErrorAction Stop | Out-Null
        Note "ipv6 default route added via $v6Gw"
    }
} catch { Note "ERROR ipv6 route: $($_.Exception.Message)" }

# Confirm what the interface ended up holding.
$globalV6 = $null
foreach ($attempt in 1..15) {
    $globalV6 = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike 'fe80*' -and $_.IPAddress -ne '::1' } |
        Select-Object -First 1
    if ($globalV6) { break }
    Start-Sleep -Seconds 2
}
if ($globalV6) {
    Note "ipv6 GLOBAL ACQUIRED $($globalV6.IPAddress)/$($globalV6.PrefixLength) state=$($globalV6.AddressState)"
} else {
    Note "ERROR: still no global IPv6 - RDP will be unreachable"
}

# --- 3d. RDP certificate ----------------------------------------------
# RDP presents a self-signed certificate, so a trust warning is normal
# without a PKI. The NAME on it was not: it read DESKTOP-TBBP874, the
# machine name from Packer build time. The certificate is generated once
# and then baked into the image, and sysprep does not regenerate it - so
# every desktop cloned from that image presented the same stale name.
#
# Beyond looking alarming, it defeats the one check a student could
# actually make: the name in the warning should be their own machine.
# Delete it and let TermService issue a fresh one for the real hostname.
try {
    Get-ChildItem 'Cert:\LocalMachine\Remote Desktop' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
        -Name 'SSLCertificateSHA1Hash' -ErrorAction SilentlyContinue
    Restart-Service TermService -Force -ErrorAction Stop
    Note "rdp certificate cleared, TermService restarted for regeneration"
} catch { Note "rdp certificate reset failed: $($_.Exception.Message)" }

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
