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

# Windows classifies the OpenStack network as "Oeffentlich" (Public), and
# WinRM refuses to apply its firewall exception on a Public profile:
#   "Die WinRM-Firewallausnahme funktioniert nicht, da einer der
#    Netzwerkverbindungstypen auf diesem Computer auf Oeffentlich
#    festgelegt ist"  (0x80338169)
# That is why the previous build's "winrm set" calls errored out. Move
# every adapter to Private before touching WinRM.
try {
    Get-NetConnectionProfile | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
    }
    Write-Output "network profile set to Private"
} catch {
    Write-Output "could not set network profile: $($_.Exception.Message)"
}

Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

# A native command's non-zero exit does NOT throw, not even under
# ErrorActionPreference 'Stop'. The previous version therefore printed a
# success message while winrm set was failing. Report the exit codes so
# the console log shows the truth.
& winrm set winrm/config/service/auth '@{Basic="true"}' | Out-Null
Write-Output "winrm auth Basic exit=$LASTEXITCODE"
& winrm set winrm/config/service '@{AllowUnencrypted="false"}' | Out-Null
Write-Output "winrm AllowUnencrypted exit=$LASTEXITCODE"

if (-not (Get-NetFirewallRule -Name 'Packer-WinRM-HTTPS' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'Packer-WinRM-HTTPS' -DisplayName 'Packer WinRM HTTPS' `
        -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow -Profile Any | Out-Null
}
