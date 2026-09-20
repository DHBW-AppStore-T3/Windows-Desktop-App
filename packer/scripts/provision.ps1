# Baked into the image once, rather than run on every VM boot.
#
# Deliberately does NOT run Windows Update: the worker kills a Packer
# build at 3600s (worker/app/services/packer_executor.py), and a full
# update run alone can exceed that. Patches come from rebuilding this
# image on a cadence against the current vendor base image.
$ErrorActionPreference = 'Stop'
Write-Output "== provisioning starts =="

# --- Baseline hardening ----------------------------------------------
Write-Output "-- disabling SMBv1"
Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null

Write-Output "-- disabling SMB server (student desktops never serve shares)"
Set-Service -Name LanmanServer -StartupType Disabled -ErrorAction SilentlyContinue

# --- Desktop usability ------------------------------------------------
Write-Output "-- power: never sleep, never turn off display"
& powercfg /setactive SCHEME_MIN
& powercfg /change standby-timeout-ac 0
& powercfg /change monitor-timeout-ac 0
& powercfg /change hibernate-timeout-ac 0

Write-Output "-- timezone"
& tzutil /s "W. Europe Standard Time"

# --- RDP firewall rule, pre-baked -------------------------------------
# bootstrap.ps1.tpl also creates this at deploy time; having it in the
# image means a VM is reachable even if user_data were to fail.
if (-not (Get-NetFirewallRule -Name 'AppStore-RDP-In' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'AppStore-RDP-In' -DisplayName 'AppStore RDP (TCP 3389)' `
        -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow `
        -Profile Any -Enabled True | Out-Null
}
Set-Service -Name TermService -StartupType Automatic

# --- Course software --------------------------------------------------
# ADD COURSE TOOLING HERE. Keep it offline-ish and fast; anything that
# downloads gigabytes will push the build towards the 1h ceiling.
# Example:
#   & winget install --id Microsoft.VisualStudioCode --silent --accept-package-agreements

Write-Output "== provisioning done =="
