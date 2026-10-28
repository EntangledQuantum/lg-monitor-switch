<#
.SYNOPSIS
  Install (or remove) LG Monitor Switch for the current Windows user.
  No admin rights needed.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File Install-LGMonitor.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File Install-LGMonitor.ps1 -Startup     # also start at login (tray)
  powershell -NoProfile -ExecutionPolicy Bypass -File Install-LGMonitor.ps1 -Uninstall
#>
param(
    [switch]$Startup,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'

$dest = Join-Path $env:LOCALAPPDATA 'LGMonitor'
$programs = [Environment]::GetFolderPath('Programs')
$startupDir = [Environment]::GetFolderPath('Startup')
$menuLink = Join-Path $programs 'LG Monitor Switch.lnk'
$startLink = Join-Path $startupDir 'LG Monitor Switch.lnk'

if ($Uninstall) {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*LGMonitor.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $menuLink, $startLink -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output "Removed LG Monitor Switch. Your settings are kept in $env:APPDATA\LGMonitor (delete that folder to remove them)."
    return
}

New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'LGMonitor.ps1'), (Join-Path $PSScriptRoot 'LGMonitor.ico') -Destination $dest -Force
Get-ChildItem -LiteralPath $dest | Unblock-File -ErrorAction SilentlyContinue

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script = Join-Path $dest 'LGMonitor.ps1'
$icon = Join-Path $dest 'LGMonitor.ico'
$shell = New-Object -ComObject WScript.Shell

function New-Shortcut($path, $extraArgs) {
    $lnk = $shell.CreateShortcut($path)
    $lnk.TargetPath = $ps
    $lnk.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" $extraArgs".Trim()
    $lnk.WorkingDirectory = $dest
    $lnk.IconLocation = "$icon,0"
    $lnk.Description = 'Brightness, contrast and input switching for a shared LG monitor'
    $lnk.Save()
}

New-Shortcut $menuLink ''
Write-Output "Installed to $dest"
Write-Output "Start menu: LG Monitor Switch"
if ($Startup) {
    New-Shortcut $startLink '-Tray'
    Write-Output "Starts at login (tray icon only)."
} else {
    Remove-Item -LiteralPath $startLink -ErrorAction SilentlyContinue
}
Write-Output ''
Write-Output 'Next: open "LG Monitor Switch" from the Start menu, click Settings... and enter the Linux PC address and token.'
