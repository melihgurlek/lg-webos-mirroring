# Install the "Mirror to TV" toggle shortcut (Start menu + desktop) and stash the Moonlight
# ipk it reinstalls from. Windows version of scripts/install-desktop-icons.sh. The shortcut
# runs scripts\windows\tv-mirror.ps1 straight from this repo, so moving the repo means
# re-running this.
#
# It also sets the Sunshine service to manual start (it doesn't run until the first click) and
# lets you start/stop it without a UAC prompt per click. That needs admin once: the script
# asks for it. Pass -SkipServiceSetup to leave the service alone.
#
# Usage: install-shortcuts.ps1 [-Ipk moonlight_writable.ipk] [-TvMac 78:5D:C8:28:71:6E] [-SkipServiceSetup]
param([string]$Ipk, [string]$TvMac, [switch]$SkipServiceSetup, [string]$GrantSid)
$ErrorActionPreference = 'Stop'
$service = 'SunshineService'

function Grant-ServiceControl([string]$sid) {
    # Append an ACE giving this user start (RP), stop (WP), query status (LC) and read (RC)
    # on the service, then make it start on demand instead of at boot.
    $sddl = ((& sc.exe sdshow $service) -join '').Trim()
    if ($sddl -notmatch '^D:') { throw "Can't read the $service security descriptor: $sddl" }
    if ($sddl -notmatch [regex]::Escape(";;;$sid)")) {
        $ace = "(A;;RPWPLCRC;;;$sid)"
        $i = $sddl.IndexOf('S:')
        $sddl = if ($i -ge 0) { $sddl.Insert($i, $ace) } else { $sddl + $ace }
        & sc.exe sdset $service $sddl | Out-Null
        if ($LASTEXITCODE) { throw 'sc sdset failed' }
    }
    & sc.exe config $service start= demand | Out-Null
}

# Re-launched elevated by the code below: only do the service part.
if ($GrantSid) { Grant-ServiceControl $GrantSid; exit }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here 'tv-mirror.ps1'
$conf = Join-Path $env:APPDATA 'lg-mirror'
$data = Join-Path $env:LOCALAPPDATA 'lg-mirror'
New-Item -ItemType Directory -Force $conf, $data | Out-Null

if ($Ipk) { Copy-Item -Force $Ipk (Join-Path $data 'moonlight.ipk') }
if ($TvMac) {
    $file = Join-Path $conf 'config'
    $lines = @(if (Test-Path $file) { Get-Content $file | Where-Object { $_ -notmatch '^\s*TV_MAC\s*=' } })
    Set-Content $file ($lines + "TV_MAC=$TvMac")
}

# conhost --headless runs PowerShell with no window at all; -WindowStyle Hidden alone still
# flashes a window, and opens a visible one when Windows Terminal is the default terminal.
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shell = New-Object -ComObject WScript.Shell
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Mirror to TV.lnk'
$desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Mirror to TV.lnk'
foreach ($path in $startMenu, $desktop) {
    $lnk = $shell.CreateShortcut($path)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $lnk.Arguments = "--headless `"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$script`""
    $lnk.WorkingDirectory = $here
    $lnk.IconLocation = (Join-Path $env:SystemRoot 'System32\imageres.dll') + ',193'
    $lnk.Description = 'Start or stop mirroring this PC to the LG TV'
    $lnk.Save()
}

if (-not $SkipServiceSetup) {
    if (Get-Service $service -ErrorAction SilentlyContinue) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $self = $MyInvocation.MyCommand.Path
        Write-Host "Granting you start/stop rights on $service (asks for admin once)..."
        $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$self`" -GrantSid $sid"
        if ($p.ExitCode) { Write-Warning "Service setup failed; each click will ask for admin to start/stop Sunshine." }
    } else {
        Write-Warning "$service not found. Install Sunshine first, or the script runs sunshine.exe directly."
    }
}
Write-Host "Installed. Click 'Mirror to TV' on the desktop or in the Start menu to start, again to stop."
