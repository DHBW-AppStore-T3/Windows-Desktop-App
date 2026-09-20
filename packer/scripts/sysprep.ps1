# Generalise the image so each deployed VM gets a fresh SID and re-runs
# cloudbase-init against its own user_data.
$ErrorActionPreference = 'Stop'

# Remove the build-only account so it never reaches a student desktop.
Remove-LocalUser -Name 'packerbuild' -ErrorAction SilentlyContinue
Get-NetFirewallRule -Name 'Packer-WinRM-HTTPS' -ErrorAction SilentlyContinue | Remove-NetFirewallRule

# Undo the build-time UAC relaxation. It exists only so Packer can drive
# this machine over WinRM with a local account; leaving it enabled would
# weaken every student desktop cloned from this image.
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue
Write-Output "LocalAccountTokenFilterPolicy removed"

$cbDir    = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init'
$unattend = Join-Path $cbDir 'conf\Unattend.xml'
$sysprep  = "$env:SystemRoot\System32\Sysprep\sysprep.exe"

if (Test-Path $unattend) {
    # Cloudbase-init's own unattend re-registers its service for the
    # specialize pass on the next boot.
    Write-Output "sysprep with cloudbase-init Unattend.xml"
    & $sysprep /generalize /oobe /shutdown /unattend:"$unattend"
} else {
    Write-Output "WARNING: $unattend missing - plain sysprep. Verify that cloudbase-init still runs on deployed VMs."
    & $sysprep /generalize /oobe /shutdown
}
