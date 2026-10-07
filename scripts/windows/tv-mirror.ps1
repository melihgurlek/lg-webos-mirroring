# One-click mirroring to the TV, Windows version of scripts/tv-mirror.sh. With no argument it
# toggles: if Moonlight is showing this PC on the TV, stop; otherwise start.
#
# start:  start Sunshine, wake the TV over LAN, reinstall Moonlight (and restore its pairing)
#         if Developer Mode expiry deleted it, then open Moonlight with launch params that
#         stream Desktop right away.
# stop:   close Moonlight on the TV and stop Sunshine. Starting Sunshine takes ~30 s on Windows
#         (display detection inside Sunshine), so start is slower than on Linux.
# backup: save Moonlight's settings + pairing keys from the TV (done automatically on start).
#
# Config (optional): %APPDATA%\lg-mirror\config, one KEY=VALUE per line:
#   TV_MAC=78:5D:C8:28:71:6E  DEVICE=lgtv  APP_NAME=Desktop  IPK=%LOCALAPPDATA%\lg-mirror\moonlight.ipk
#   SUNSHINE_SERVICE=SunshineService  KEEP_SUNSHINE=0 (1 = leave Sunshine running after stop, so the
#   next start takes ~6 s instead of ~30 s)
# The app's numeric GameStream ID is looked up from Sunshine each time using Moonlight's
# backed-up client cert; APP_ID is only a fallback.
#
# Written for Windows PowerShell 5.1 (it ships with Windows and can show toast notifications).
param([ValidateSet('toggle', 'start', 'stop', 'backup')][string]$Action = 'toggle')
$ErrorActionPreference = 'Continue'
$env:OPENSSL_ENABLE_SHA1_SIGNATURES = '1'

# The shortcut runs with no window, so keep a log to see what a click did.
$logFile = Join-Path $env:LOCALAPPDATA 'lg-mirror\tv-mirror.log'
$clock = [Diagnostics.Stopwatch]::StartNew()
function Log([string]$text) {
    try {
        New-Item -ItemType Directory -Force (Split-Path $logFile) | Out-Null
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 256KB) { Move-Item -Force $logFile "$logFile.old" }
        Add-Content $logFile ("{0} [{1}] +{2:n1}s {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, $clock.Elapsed.TotalSeconds, $text)
    } catch {}
}

$confDir = Join-Path $env:APPDATA 'lg-mirror'
$cfg = @{
    DEVICE = 'lgtv'; APP_NAME = 'Desktop'; APP_ID = '881448767'; TV_MAC = ''
    IPK = Join-Path $env:LOCALAPPDATA 'lg-mirror\moonlight.ipk'
    SUNSHINE_SERVICE = 'SunshineService'; KEEP_SUNSHINE = '0'
    SUNSHINE_EXE = Join-Path $env:ProgramFiles 'Sunshine\sunshine.exe'
}
if (Test-Path "$confDir\config") {
    foreach ($line in Get-Content "$confDir\config") {
        # -cmatch: case-insensitive [A-Z] misses "I" under Turkish culture (I lowercases to dotless i)
        if ($line -cmatch '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') {
            $cfg[$Matches[1]] = [Environment]::ExpandEnvironmentVariables($Matches[2].Trim('"', "'"))
        }
    }
}
$BACKUP = Join-Path $confDir 'moonlight-conf.tar.gz'
$APP = 'com.limelight.webos'
$APP_DIR = "/media/developer/apps/usr/palm/applications/$APP"
$TAR = Join-Path $env:SystemRoot 'System32\tar.exe'
$CURL = Join-Path $env:SystemRoot 'System32\curl.exe'

# Clicking the icon twice quickly must not run two copies against the TV.
$mutex = New-Object Threading.Mutex($false, 'Local\lg-tv-mirror')
if (-not $mutex.WaitOne(0)) { Log "$Action ignored: another run is still busy"; exit 0 }
Log "$Action requested (config: $(if (Test-Path "$confDir\config") { "$confDir\config" } else { "none" }), DEVICE=$($cfg.DEVICE))"

function Notify([string]$text) {
    Write-Host $text
    Log $text
    if ($PSVersionTable.PSEdition -eq 'Core') { return }   # no WinRT in PowerShell 7
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>TV Mirror</text><text>$([Security.SecurityElement]::Escape($text))</text></binding></visual></toast>")
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        $toast.Tag = 'tv-mirror'; $toast.Group = 'tv-mirror'   # same tag: each toast replaces the last
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(
            '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show($toast)
    } catch {}
}
function Say([string]$text) { Notify $text }
function Fail([string]$text) { Notify $text; exit 1 }

# --- running native tools with a timeout -------------------------------------------------

function Quote-Arg([string]$a) {  # MSVCRT / node command-line quoting
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    return '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Run([string]$file, [string[]]$argv, [int]$timeoutSec = 60) {
    $psi = New-Object Diagnostics.ProcessStartInfo $file
    $psi.Arguments = ($argv | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    try { $p = [Diagnostics.Process]::Start($psi) } catch { return [pscustomobject]@{ Code = -1; Out = '' } }
    $out = $p.StandardOutput.ReadToEndAsync(); $null = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null
        return [pscustomobject]@{ Code = -1; Out = '' }
    }
    [pscustomobject]@{ Code = $p.ExitCode; Out = $out.Result }
}

# The ares-* commands are npm .cmd shims around node scripts. Calling node directly avoids
# cmd.exe's quoting rules and its 8 KB command-line limit (restore_conf sends a few KB).
$aresCache = @{}
function Ares([string]$tool, [string[]]$argv, [int]$timeoutSec = 60) {
    if (-not $aresCache.ContainsKey($tool)) {
        $shim = Get-Command "$tool.cmd" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $node = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $shim) { Fail "The webOS CLI ($tool) isn't installed. Run: npm install -g @webos-tools/cli" }
        $js = $null
        if ($node -and ((Get-Content $shim.Source -Raw) -match '"%dp0%\\([^"]+\.js)"')) {
            $js = Join-Path (Split-Path $shim.Source) $Matches[1]
        }
        $aresCache[$tool] = if ($js -and (Test-Path $js)) { @($node.Source, $js) } else { @($env:ComSpec, '/d', '/c', $shim.Source) }
    }
    $cmd = $aresCache[$tool]
    Run $cmd[0] (@($cmd[1..($cmd.Count - 1)]) + $argv) $timeoutSec
}

# --- TV ----------------------------------------------------------------------------------

function Find-TvIp {
    $candidates = @("$env:APPDATA\.webos\tv", "$env:APPDATA\.webos", "$env:USERPROFILE\.webos\tv", "$env:APPDATA\.webos\ose") |
        ForEach-Object { Join-Path $_ 'novacom-devices.json' }
    foreach ($f in $candidates) {
        if (-not (Test-Path $f)) { continue }
        $dev = (Get-Content $f -Raw | ConvertFrom-Json) | Where-Object { $_.name -eq $cfg.DEVICE } | Select-Object -First 1
        if ($dev) { return $dev.host }
    }
}
$tvIp = Find-TvIp
if (-not $tvIp) { Fail "No webOS device '$($cfg.DEVICE)' configured (ares-setup-device)." }

function Tv-Up {
    try { (New-Object Net.NetworkInformation.Ping).Send($tvIp, 1000).Status -eq 'Success' } catch { $false }
}

function Wake([string]$mac) {
    $bytes = [byte[]]($mac -split '[:-]' | ForEach-Object { [Convert]::ToByte($_, 16) })
    $pkt = [byte[]](@(0xFF) * 6 + $bytes * 16)
    $udp = New-Object Net.Sockets.UdpClient
    $udp.EnableBroadcast = $true
    foreach ($port in 9, 7) { $null = $udp.Send($pkt, $pkt.Length, [Net.IPAddress]::Broadcast, $port) }
    $udp.Close()
}

function Tv-Run([string]$command, [int]$timeoutSec = 40) {
    $r = Ares 'ares-novacom' @('-d', $cfg.DEVICE, '--run', $command) $timeoutSec
    ($r.Out -split "`r?`n" | Where-Object { $_ -notmatch '^\[Info\]' }) -join "`n"
}

# Moonlight keeps its settings and pairing keys in $APP_DIR/conf, which a reinstall wipes.
# There's no file transfer for TV devices (ares-push/pull are disabled), so go via base64.
function Backup-Conf {
    $b64 = Tv-Run "cd $APP_DIR/conf && tar cz key hosts.ini moonlight.ini | base64"
    $tmp = [IO.Path]::GetTempFileName()
    try { [IO.File]::WriteAllBytes($tmp, [Convert]::FromBase64String($b64)) } catch { Remove-Item $tmp; return $false }
    if ((& $TAR tzf $tmp 2>$null) -contains 'key/key.pem') {
        New-Item -ItemType Directory -Force $confDir | Out-Null
        Move-Item -Force $tmp $BACKUP
        return $true
    }
    Remove-Item $tmp; $false
}

function Restore-Conf {
    if (-not (Test-Path $BACKUP)) { return $false }
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($BACKUP))
    # The marker is printed only if every step succeeded, so the remote exit code isn't needed.
    (Tv-Run ("mkdir -p $APP_DIR/conf && cd $APP_DIR/conf && echo $b64 | base64 -d | tar xz " +
        "&& chmod 777 key && chmod 644 key/* && chmod 666 hosts.ini moonlight.ini && echo restored-ok")) -match 'restored-ok'
}

# --- Sunshine ----------------------------------------------------------------------------

function Get-SunshineService { Get-Service $cfg.SUNSHINE_SERVICE -ErrorAction SilentlyContinue }

function Sunshine-Running {
    $svc = Get-SunshineService
    if ($svc) { return $svc.Status -eq 'Running' }
    [bool](Get-Process sunshine -ErrorAction SilentlyContinue)
}

function Set-Sunshine([ValidateSet('start', 'stop')][string]$verb) {
    $svc = Get-SunshineService
    if ($svc) {
        try {
            if ($verb -eq 'start') { Start-Service $svc -ErrorAction Stop } else { Stop-Service $svc -ErrorAction Stop }
        } catch {
            # The user wasn't granted start/stop rights (install-shortcuts.ps1 does that): ask for admin.
            try { Start-Process sc.exe "$verb $($cfg.SUNSHINE_SERVICE)" -Verb RunAs -WindowStyle Hidden -Wait } catch {}
        }
        return
    }
    if ($verb -eq 'start') {
        if (Get-Process sunshine -ErrorAction SilentlyContinue) { return }
        if (-not (Test-Path $cfg.SUNSHINE_EXE)) { Fail "Sunshine isn't installed (no service '$($cfg.SUNSHINE_SERVICE)', no $($cfg.SUNSHINE_EXE))." }
        Start-Process $cfg.SUNSHINE_EXE -WorkingDirectory (Split-Path $cfg.SUNSHINE_EXE) -WindowStyle Hidden
    } else {
        Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force
    }
}

function Host-Uuid {  # Sunshine's GameStream unique id; it answers a few seconds after starting
    for ($i = 0; $i -lt 15; $i++) {
        $xml = & $CURL -s --max-time 2 http://localhost:47989/serverinfo 2>$null | Out-String
        if ($xml -match '<uniqueid>([^<]+)</uniqueid>') { return $Matches[1] }
        Start-Sleep 1
    }
}

# GET with Moonlight's client cert. curl.exe on Windows (Schannel) can't use PEM keys, so do
# it in .NET: load the PEM key into a CAPI container, which Schannel can use for client auth.
$gsClient = @'
using System; using System.IO; using System.Net; using System.Text.RegularExpressions;
using System.Security.Cryptography; using System.Security.Cryptography.X509Certificates;
public static class GsClient {
    static byte[] buf; static int pos;
    static int Len() { int b = buf[pos++]; if (b < 0x80) return b; int n = b & 0x7f, l = 0; while (n-- > 0) l = (l << 8) | buf[pos++]; return l; }
    static byte[] Tlv(byte tag) { if (buf[pos++] != tag) throw new Exception("unexpected key format"); int l = Len(); var r = new byte[l]; Array.Copy(buf, pos, r, 0, l); pos += l; return r; }
    static void Enter(byte tag) { if (buf[pos++] != tag) throw new Exception("unexpected key format"); Len(); }
    static byte[] Int(int size) {
        var v = Tlv(2); int s = 0; while (s < v.Length - 1 && v[s] == 0) s++;
        int len = v.Length - s; if (size < len) size = len;
        var r = new byte[size]; Array.Copy(v, s, r, size - len, len); return r;
    }
    static byte[] Pem(string text, string label) {
        var m = Regex.Match(text, "-----BEGIN " + label + "-----(.*?)-----END " + label + "-----", RegexOptions.Singleline);
        return m.Success ? Convert.FromBase64String(m.Groups[1].Value) : null;
    }
    static RSAParameters RsaKey(string pemText) {
        byte[] pkcs1 = Pem(pemText, "RSA PRIVATE KEY");
        if (pkcs1 == null) {  // PKCS#8 wraps the PKCS#1 key in an OCTET STRING
            buf = Pem(pemText, "PRIVATE KEY"); pos = 0;
            if (buf == null) throw new Exception("no private key in PEM");
            Enter(0x30); Tlv(2); Tlv(0x30); pkcs1 = Tlv(4);
        }
        buf = pkcs1; pos = 0; Enter(0x30); Tlv(2);
        var p = new RSAParameters();
        p.Modulus = Int(0); p.Exponent = Int(0);
        int half = (p.Modulus.Length + 1) / 2;
        p.D = Int(p.Modulus.Length); p.P = Int(half); p.Q = Int(half);
        p.DP = Int(half); p.DQ = Int(half); p.InverseQ = Int(half);
        return p;
    }
    public static string Get(string url, string certFile, string keyFile) {
        var cert = new X509Certificate2(Pem(File.ReadAllText(certFile), "CERTIFICATE"));
        var csp = new CspParameters(24);  // PROV_RSA_AES: can sign SHA-256 for TLS 1.2
        csp.KeyContainerName = "lg-mirror-" + Guid.NewGuid();
        csp.Flags = CspProviderFlags.NoPrompt;
        var rsa = new RSACryptoServiceProvider(csp);
        try {
            rsa.ImportParameters(RsaKey(File.ReadAllText(keyFile)));
            cert.PrivateKey = rsa;
            ServicePointManager.ServerCertificateValidationCallback = delegate { return true; };  // Sunshine's cert is self-signed
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.ClientCertificates.Add(cert);
            req.Timeout = 5000;
            using (var resp = req.GetResponse()) using (var r = new StreamReader(resp.GetResponseStream())) return r.ReadToEnd();
        } finally { rsa.PersistKeyInCsp = false; rsa.Clear(); }
    }
}
'@

function App-Id {  # GameStream ID of APP_NAME, via Sunshine's /applist with Moonlight's client cert
    $id = $null
    if (Test-Path $BACKUP) {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
        New-Item -ItemType Directory $dir | Out-Null
        try {
            & $TAR xzf $BACKUP -C $dir key 2>$null
            if (-not ('GsClient' -as [type])) { Add-Type -TypeDefinition $gsClient }
            $uid = (Get-Content "$dir\key\uniqueid.dat" -Raw).Trim()
            $xml = [xml][GsClient]::Get("https://localhost:47984/applist?uniqueid=$uid", "$dir\key\client.pem", "$dir\key\key.pem")
            $id = $xml.SelectNodes('//App') | Where-Object { $_.AppTitle -eq $cfg.APP_NAME } | ForEach-Object { $_.ID } | Select-Object -First 1
        } catch {
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }
    if ($id) { $id } else { $cfg.APP_ID }
}

# --- actions -----------------------------------------------------------------------------

function Start-Mirror {
    Say 'Starting...'
    Set-Sunshine start
    if (-not (Sunshine-Running)) { Fail "Couldn't start Sunshine." }
    Log 'sunshine started'

    if (-not (Tv-Up)) {
        if (-not $cfg.TV_MAC) { Fail 'The TV is off. Turn it on with the remote and click again.' }
        Say 'Turning the TV on...'
        Wake $cfg.TV_MAC
        for ($i = 0; $i -lt 60 -and -not (Tv-Up); $i++) { Start-Sleep 1 }
        if (-not (Tv-Up)) { Fail "The TV didn't wake up. Turn it on with the remote and click again." }
    }

    # The Developer Mode SSH service comes up a few seconds after the network does.
    $apps = ''
    for ($i = 0; $i -lt 12; $i++) {
        $r = Ares 'ares-install' @('-d', $cfg.DEVICE, '--list') 20
        if ($r.Code -eq 0 -and $r.Out.Trim()) { $apps = $r.Out; break }
        Start-Sleep 5
    }
    Log 'listed TV apps'
    if (-not $apps) { Fail "Can't reach Developer Mode on the TV. Open the Developer Mode app on the TV and check it's ON." }

    if ($apps -notmatch [regex]::Escape($APP)) {
        if (-not (Test-Path $cfg.IPK)) { Fail "Moonlight is missing from the TV and $($cfg.IPK) doesn't exist." }
        Say 'Reinstalling Moonlight on the TV...'
        if ((Ares 'ares-install' @('-d', $cfg.DEVICE, $cfg.IPK) 180).Code -ne 0) { Fail 'Reinstalling Moonlight failed.' }
        if (-not (Restore-Conf)) { Say "Moonlight was reinstalled but its pairing couldn't be restored. Pair it again with the PIN shown on the TV." }
    } else {
        # Refresh every time so a pairing made since (e.g. from Linux) isn't lost on a reinstall.
        $null = Backup-Conf
    }

    $uuid = Host-Uuid
    if (-not $uuid) { Fail "Sunshine isn't responding." }
    Log 'got host uuid'
    # Launch params only apply on a fresh start, so close any running instance first.
    $null = Ares 'ares-launch' @('-d', $cfg.DEVICE, '--close', $APP) 20
    Log 'closed Moonlight'
    $params = '{"host_uuid":"' + $uuid + '","host_app_id":' + (App-Id) + '}'
    Log "app id looked up: $params"
    if ((Ares 'ares-launch' @('-d', $cfg.DEVICE, $APP, '-p', $params) 30).Code -ne 0) { Fail "Couldn't open Moonlight on the TV." }
    Say 'Mirroring to the TV. Click the icon again to stop.'
}

function Stop-Mirror {
    if (Tv-Up) { $null = Ares 'ares-launch' @('-d', $cfg.DEVICE, '--close', $APP) 20 }
    if ($cfg.KEEP_SUNSHINE -ne '1') { Set-Sunshine stop }
    Say 'Stopped.'
}

function Is-Mirroring {
    (Sunshine-Running) -and (Tv-Up) -and ((Ares 'ares-launch' @('-d', $cfg.DEVICE, '--running') 20).Out -match [regex]::Escape($APP))
}

switch ($Action) {
    'start' { Start-Mirror }
    'stop' { Stop-Mirror }
    'backup' { if (Backup-Conf) { Write-Host "saved $BACKUP" } else { Write-Error 'backup failed'; exit 1 } }
    'toggle' {
        $on = Is-Mirroring
        Log "toggle: mirroring=$on (sunshine=$(Sunshine-Running))"
        if ($on) { Stop-Mirror } else { Start-Mirror }
    }
}
