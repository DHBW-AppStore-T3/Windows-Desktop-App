#ps1_sysnative
# Build-time only. Creates the account Packer authenticates as, because
# the base image's built-in Administrator is disabled.
# NOTE: goes through Packer's templatefile(); avoid dollar-brace and
# percent-brace sequences other than the two intended variables.
$ErrorActionPreference = 'Stop'

$u = '${build_user}'
$p = ConvertTo-SecureString '${build_password}' -AsPlainText -Force

New-LocalUser -Name $u -Password $p -PasswordNeverExpires -AccountNeverExpires | Out-Null
Add-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-544').Name -Member $u

Write-Output "created build user"

# WinRM refuses to apply its firewall exception while any connection is
# classified Public (0x80338169), which is how Windows classifies the
# OpenStack network on first boot. Move every adapter to Private first, or
# the "winrm set" calls below fail.
try {
    Get-NetConnectionProfile | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
    }
    Write-Output "network profile set to Private"
} catch {
    Write-Output "could not set network profile: $($_.Exception.Message)"
}

# Windows applies UAC remote token filtering to LOCAL accounts: over the
# network, a local administrator that is not the built-in Administrator
# gets a filtered token and WinRM answers 401. The built-in account is
# exempt - but it is disabled in this image, which is why we create our
# own admin, and therefore why we land squarely in the restriction.
#
# This is the documented requirement for driving Windows with Packer via
# a local account. sysprep.ps1 removes it again so the setting never
# reaches a student desktop.
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null
Write-Output "LocalAccountTokenFilterPolicy=1"

# Belt and braces: WinRM also honours this group directly.
try {
    Add-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-580').Name -Member $u -ErrorAction Stop
    Write-Output "added to Remote Management Users"
} catch {
    Write-Output "Remote Management Users: $($_.Exception.Message)"
}

Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

# A native command's non-zero exit does not throw, not even under
# ErrorActionPreference 'Stop', so report the exit codes explicitly -
# otherwise a failed "winrm set" still prints a success message.
& winrm set winrm/config/service/auth '@{Basic="true"}' | Out-Null
Write-Output "winrm auth Basic exit=$LASTEXITCODE"
& winrm set winrm/config/service '@{AllowUnencrypted="false"}' | Out-Null
Write-Output "winrm AllowUnencrypted exit=$LASTEXITCODE"

if (-not (Get-NetFirewallRule -Name 'Packer-WinRM-HTTPS' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'Packer-WinRM-HTTPS' -DisplayName 'Packer WinRM HTTPS' `
        -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow -Profile Any | Out-Null
}
