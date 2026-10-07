# Submit a Moonlight pairing PIN to the local Sunshine without opening the web UI.
# Windows version of scripts/sunshine-pair.sh.
#
# Newer Sunshine builds require the pending request's pairing_id alongside the PIN;
# GET /api/pin lists pending requests.
#
# The Sunshine login comes from SUNSHINE_USER/SUNSHINE_PASS in %APPDATA%\lg-mirror\config,
# or from environment variables of the same names.
#
# Usage: .\sunshine-pair.ps1 <PIN> [client-name]
param([Parameter(Mandatory)][string]$Pin, [string]$Name = 'LG TV')
$ErrorActionPreference = 'Stop'
$conf = Join-Path $env:APPDATA 'lg-mirror\config'
if ((Test-Path $conf) -and -not ($env:SUNSHINE_USER -and $env:SUNSHINE_PASS)) {
    foreach ($line in Get-Content $conf) {
        if ($line -cmatch '^\s*(SUNSHINE_USER|SUNSHINE_PASS)\s*=\s*(.*?)\s*$') { Set-Item "env:$($Matches[1])" $Matches[2].Trim('"', "'") }
    }
}
if (-not $env:SUNSHINE_USER -or -not $env:SUNSHINE_PASS) { throw "set SUNSHINE_USER and SUNSHINE_PASS (in $conf or the environment)" }

$api = 'https://localhost:47990/api'
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'   # -k works for the self-signed cert in any PowerShell
$auth = "$($env:SUNSHINE_USER):$($env:SUNSHINE_PASS)"

$pending = (& $curl -sk -u $auth "$api/pin" | Out-String | ConvertFrom-Json).pairings
if (-not $pending) {
    Write-Error 'No pending pairing request - select the PC in Moonlight first.'
    exit 1
}
$id = [string]@($pending)[-1].id

# Send the body from a file: PowerShell 5.1 mangles quotes in native-command arguments.
$body = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText($body, (@{ pin = $Pin; name = $Name; pairing_id = $id } | ConvertTo-Json -Compress))
    & $curl -sk -u $auth -X POST "$api/pin" -H 'Content-Type: application/json' --data-binary "@$body"
    Write-Host
} finally { Remove-Item $body }
