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

# Packer authenticates with NTLM over the HTTPS listener cloudbase-init
# creates later in its own run, so nothing here is load-bearing any more.
# Basic is enabled only as a fallback, and only after making sure the
# service is up: at this point ConfigWinRMListenerPlugin has not run yet,
# so WinRM may still be stopped and "winrm set" would fail. A native
# command's non-zero exit does not throw under ErrorActionPreference
# 'Stop', which is exactly how the first attempt failed without a trace.
try {
    Set-Service -Name WinRM -StartupType Automatic
    Start-Service -Name WinRM
    & winrm set winrm/config/service/auth '@{Basic="true"}' | Out-Null
    & winrm set winrm/config/service '@{AllowUnencrypted="false"}' | Out-Null
    Write-Output "WinRM Basic auth enabled as fallback"
} catch {
    Write-Output "WinRM pre-configuration skipped (NTLM is the primary path)"
}

if (-not (Get-NetFirewallRule -Name 'Packer-WinRM-HTTPS' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'Packer-WinRM-HTTPS' -DisplayName 'Packer WinRM HTTPS' `
        -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow -Profile Any | Out-Null
}
