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

# cloudbase-init creates the HTTPS listener itself; we only need Basic
# auth enabled so Packer can present the credential over that TLS
# channel. AllowUnencrypted stays false — 5986 is TLS.
& winrm set winrm/config/service/auth '@{Basic="true"}' | Out-Null
& winrm set winrm/config/service '@{AllowUnencrypted="false"}' | Out-Null

if (-not (Get-NetFirewallRule -Name 'Packer-WinRM-HTTPS' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'Packer-WinRM-HTTPS' -DisplayName 'Packer WinRM HTTPS' `
        -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow -Profile Any | Out-Null
}
