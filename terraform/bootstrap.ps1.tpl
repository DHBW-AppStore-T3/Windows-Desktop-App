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

# --- 3c. Force DHCPv6 -------------------------------------------------
# The guest came up with only a link-local address for several rounds.
# The subnet is dhcpv6-stateful, and Windows starts a DHCPv6 client only
# when a Router Advertisement carries the M (Managed) flag. Linux hosts
# on this same network do not wait for that - their netplan sets
# "dhcp6: true", which solicits unconditionally - which is why the
# AppStore's own Linux VMs hold a /128 DHCPv6 lease here and Windows
# held nothing.
#
# managedaddress/otherstateful make Windows behave the same way: solicit
# regardless of what the RA says.
try {
    $ifAlias = (Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1).Name
    if (-not $ifAlias) { $ifAlias = (Get-NetConnectionProfile | Select-Object -First 1).InterfaceAlias }
    Note "ipv6 iface=$ifAlias"

    foreach ($i in Get-NetIPInterface -AddressFamily IPv6 -ErrorAction SilentlyContinue) {
        Note "ipv6 iface-state $($i.InterfaceAlias) dhcp=$($i.Dhcp) ra=$($i.RouterDiscovery)"
    }

    # Kept only as a belt-and-braces nudge. The premise behind adding it
    # was wrong: the interface already reports dhcp=Enabled, so Windows
    # was soliciting all along - the replies were being dropped. It also
    # returned exit=1 in practice, so nothing here may depend on it.
    & netsh interface ipv6 set interface "$ifAlias" managedaddress=enabled otherstateful=enabled 2>&1 | Out-Null
    Note "ipv6 managedaddress nudge exit=$LASTEXITCODE (advisory only)"
    & ipconfig /renew6 | Out-Null
    Note "ipv6 renew6 exit=$LASTEXITCODE"
} catch { Note "ERROR ipv6-force: $($_.Exception.Message)" }

# Give DHCPv6 time to land before we judge it.
$globalV6 = $null
foreach ($attempt in 1..30) {
    $globalV6 = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -notlike 'fe80*' -and $_.IPAddress -ne '::1' } |
        Select-Object -First 1
    if ($globalV6) { break }
    Start-Sleep -Seconds 2
}
if ($globalV6) {
    Note "ipv6 GLOBAL ACQUIRED $($globalV6.IPAddress)/$($globalV6.PrefixLength) state=$($globalV6.AddressState) origin=$($globalV6.PrefixOrigin)/$($globalV6.SuffixOrigin)"
} else {
    Note "ERROR: still no global IPv6 after 60s - RDP will be unreachable"
}

# --- 4. Windows activation -------------------------------------------
# Base image is VOLUME_KMSCLIENT channel; it needs a reachable KMS,
# found either via DNS SRV (_vlmcs._tcp) or set explicitly here.
try {
    if ($kmsHost -ne '') {
        & cscript.exe //nologo "$env:SystemRoot\System32\slmgr.vbs" /skms $kmsHost | Out-Null
        Note "KMS host set to $kmsHost"
    }
    & cscript.exe //nologo "$env:SystemRoot\System32\slmgr.vbs" /ato | Out-Null
    Note "activation attempted"
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
