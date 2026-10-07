# Repack a Moonlight TV .ipk so it can persist settings and pairing on older webOS TVs.
# Windows version of scripts/repack-moonlight-ipk.sh; see that file for why.
#
# Windows has no `ar`, and extracting to NTFS would lose the Unix modes, so this edits the
# package in memory: it appends mode-777 conf/ and cache/ directory entries to data.tar.gz.
#
# Usage: repack-moonlight-ipk.ps1 com.limelight.webos_X.Y.Z_arm.ipk [out.ipk]
param([Parameter(Mandatory)][string]$In, [string]$Out)
$ErrorActionPreference = 'Stop'
$In = (Resolve-Path $In).Path
if (-not $Out) { $Out = $In -replace '\.ipk$', '_writable.ipk' }
$Out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)
$ascii = [Text.Encoding]::ASCII

# --- ar archive: "!<arch>\n", then members with 60-byte headers, data padded to even length
$ar = [IO.File]::ReadAllBytes($In)
if ($ascii.GetString($ar, 0, 8) -ne "!<arch>`n") { throw "$In isn't an ipk (ar archive)" }
$members = New-Object Collections.Generic.List[object]
$pos = 8
while ($pos + 60 -le $ar.Length) {
    $hdr = $ascii.GetString($ar, $pos, 60)
    $size = [long]$hdr.Substring(48, 10).Trim()
    $data = New-Object byte[] $size
    [Array]::Copy($ar, $pos + 60, $data, 0, $size)
    $members.Add([pscustomobject]@{ Header = $hdr; Name = $hdr.Substring(0, 16).Trim().TrimEnd('/'); Data = $data })
    $pos += 60 + $size + ($size % 2)
}
$dataMember = $members | Where-Object Name -eq 'data.tar.gz'
if (-not $dataMember) { throw 'data.tar.gz not found in the ipk' }

function Gunzip([byte[]]$bytes) {
    $src = New-Object IO.MemoryStream(, $bytes)
    $gz = New-Object IO.Compression.GZipStream($src, [IO.Compression.CompressionMode]::Decompress)
    $dst = New-Object IO.MemoryStream
    $gz.CopyTo($dst); $gz.Dispose()
    ,$dst.ToArray()   # comma: return the byte[] itself, not its unrolled items
}
function Gzip([byte[]]$bytes) {
    $dst = New-Object IO.MemoryStream
    $gz = New-Object IO.Compression.GZipStream($dst, [IO.Compression.CompressionLevel]::Optimal)
    $gz.Write($bytes, 0, $bytes.Length); $gz.Dispose()
    ,$dst.ToArray()   # comma: return the byte[] itself, not its unrolled items
}

# Write an ASCII field into a 512-byte tar header at $base + $off.
function Put([byte[]]$buf, [int]$base, [int]$off, [int]$len, [string]$s) {
    [Array]::Clear($buf, $base + $off, $len)
    $b = $ascii.GetBytes($s); [Array]::Copy($b, 0, $buf, $base + $off, $b.Length)
}
function Fix-Checksum([byte[]]$buf, [int]$base) {
    Put $buf $base 148 8 '        '
    $sum = 0; for ($i = 0; $i -lt 512; $i++) { $sum += $buf[$base + $i] }
    Put $buf $base 148 8 ([Convert]::ToString($sum, 8).PadLeft(6, '0') + "`0 ")
}

# --- tar: walk the headers to find the app dir and where the end-of-archive blocks start.
# Like the bash version's --owner=0 --group=0, make everything root-owned on the way.
$tar = Gunzip $dataMember.Data
$pos = 0; $appDir = $null; $longName = $null
while ($pos + 512 -le $tar.Length) {
    $isZero = $true
    for ($i = 0; $i -lt 512; $i++) { if ($tar[$pos + $i] -ne 0) { $isZero = $false; break } }
    if ($isZero) { break }
    $name = $ascii.GetString($tar, $pos, 100).Split([char]0)[0]
    $prefix = $ascii.GetString($tar, $pos + 345, 155).Split([char]0)[0]
    if ($prefix) { $name = "$prefix/$name" }
    if ($longName) { $name = $longName; $longName = $null }
    $size = [Convert]::ToInt64(('0' + $ascii.GetString($tar, $pos + 124, 12).Trim([char]0, ' ')), 8)
    $type = [char]$tar[$pos + 156]
    if ($type -eq 'L') { $longName = $ascii.GetString($tar, $pos + 512, $size).TrimEnd([char]0) }
    Put $tar $pos 108 8 '0000000'; Put $tar $pos 116 8 '0000000'
    if ($ascii.GetString($tar, $pos + 257, 5) -eq 'ustar') { Put $tar $pos 265 32 'root'; Put $tar $pos 297 32 'root' }
    Fix-Checksum $tar $pos
    if (-not $appDir -and $name -match '^(\./)?(usr/palm/applications/[^/]+)/') { $appDir = $Matches[1] + $Matches[2] }
    $pos += 512 + [math]::Ceiling($size / 512) * 512
}
if (-not $appDir) { throw 'usr/palm/applications/<app> not found in data.tar.gz' }

function Dir-Header([string]$path) {
    $h = New-Object byte[] 512
    Put $h 0 0 100 $path
    Put $h 0 100 8 '0000777'; Put $h 0 108 8 '0000000'; Put $h 0 116 8 '0000000'   # mode, uid, gid
    Put $h 0 124 12 '00000000000'                                                  # size
    Put $h 0 136 12 ([Convert]::ToString([DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), 8).PadLeft(11, '0'))
    $h[156] = [byte][char]'5'                                                      # directory
    Put $h 0 257 6 'ustar'; Put $h 0 263 2 '00'; Put $h 0 265 32 'root'; Put $h 0 297 32 'root'
    Fix-Checksum $h 0
    ,$h
}

$newTar = New-Object IO.MemoryStream
$newTar.Write($tar, 0, $pos)
foreach ($d in 'conf', 'cache') { $newTar.Write((Dir-Header "$appDir/$d/"), 0, 512) }
$newTar.Write((New-Object byte[] 1024), 0, 1024)                               # end of archive
$pad = (10240 - $newTar.Length % 10240) % 10240
$newTar.Write((New-Object byte[] $pad), 0, $pad)
$dataMember.Data = Gzip $newTar.ToArray()

# --- write the ar archive back, same member order and headers, new data.tar.gz size
$outStream = New-Object IO.MemoryStream
$outStream.Write($ascii.GetBytes("!<arch>`n"), 0, 8)
foreach ($m in $members) {
    $hdr = $m.Header.Substring(0, 48) + ([string]$m.Data.Length).PadRight(10) + $m.Header.Substring(58)
    $outStream.Write($ascii.GetBytes($hdr), 0, 60)
    $outStream.Write($m.Data, 0, $m.Data.Length)
    if ($m.Data.Length % 2) { $outStream.WriteByte(10) }
}
[IO.File]::WriteAllBytes($Out, $outStream.ToArray())
Write-Host "wrote $Out (added $appDir/conf and cache, mode 777)"
