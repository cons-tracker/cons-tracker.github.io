# Builds web/index.html from src/template.html (the app's code) + src/bundle-base.html (libraries and fonts)
# How to run:  powershell -NoProfile -ExecutionPolicy Bypass -File tools/build.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$base = Join-Path $root 'src\bundle-base.html'
$tplPath = Join-Path $root 'src\template.html'
$out = Join-Path $root 'web\index.html'
$supabaseJs = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.4/dist/umd/supabase.min.js'

$text = [IO.File]::ReadAllText($base, (New-Object Text.UTF8Encoding($false)))
$lines = $text -split "`n"
$ix = [Array]::FindIndex($lines, [Predicate[string]]{ param($l) $l.Trim() -eq '<script type="__bundler/template">' })
if ($ix -lt 0) { throw 'template block not found in src/bundle-base.html' }

$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength = [int]::MaxValue
$tpl = [IO.File]::ReadAllText($tplPath, [Text.Encoding]::UTF8)
# Hide the raw template (<x-dc>: every dialog open, {{ }} placeholders) until the app replaces it with #dc-root,
# and keep the orange splash on screen meanwhile, so nothing flashes between the splash and the app
$bootCss = @"
<style id="boot-hide">
x-dc{display:none!important}
body:has(> x-dc){margin:0;min-height:100vh;background:#c67139 url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 400'%3E%3Cpath d='M120 300 L180 100 L220 100 L280 300 Z' fill='%23fff7ee'/%3E%3Crect x='194' y='130' width='12' height='30' fill='%23c67139'/%3E%3Crect x='194' y='185' width='12' height='35' fill='%23c67139'/%3E%3Crect x='194' y='245' width='12' height='40' fill='%23c67139'/%3E%3C/svg%3E") center/min(100vw,100vh) no-repeat}
</style>
"@
$headEnd = $tpl.IndexOf('</head>')
if ($headEnd -lt 0) { throw '</head> not found in src/template.html' }
$tpl = $tpl.Substring(0, $headEnd) + $bootCss + $tpl.Substring($headEnd)
$json = $ser.Serialize($tpl)
if ($json -match '</script') { throw 'template json contains </script>' }
$lines[$ix + 1] = $json
$html = $lines -join "`n"

# 1) <head>: page name, PWA manifest, Supabase scripts (must load before the bundle unpacks)
$head = @"
<title>ระบบติดตามงานก่อสร้าง</title>
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="theme-color" content="#c67139">
  <link rel="manifest" href="./manifest.json">
  <link rel="icon" href="./icons/icon-192.png">
  <link rel="apple-touch-icon" href="./icons/apple-touch-icon.png">
  <script>
    /* PWA: register the service worker and capture the install prompt from the start (the app renders only after the Supabase data loads) */
    if ('serviceWorker' in navigator && location.protocol.indexOf('http') === 0) {
      window.addEventListener('load', function () { navigator.serviceWorker.register('./sw.js', { scope: './' }).catch(function () {}); });
    }
    window.addEventListener('beforeinstallprompt', function (ev) { ev.preventDefault(); window.__pwaPrompt = ev; window.dispatchEvent(new Event('pwa-installable')); });
  </script>
  <script src="./config.js"></script>
  <script src="$supabaseJs"></script>
  <script src="./cloud.js"></script>
"@
if ($html -notmatch '<title>Bundled Page</title>') { throw 'title marker not found' }
$html = $html.Replace('<title>Bundled Page</title>', $head)

# 2) Wait for Supabase data to load before rendering the app
$marker = "    setStatus('Rendering...');"
if (-not $html.Contains($marker)) { throw 'render marker not found' }
$html = $html.Replace($marker, "    try { if (window.__cloudReady) { setStatus('กำลังโหลดข้อมูล…'); await window.__cloudReady; } } catch (e) { console.warn(e); }`n" + $marker)
$html = $html.Replace('<div id="__bundler_loading">Unpacking...</div>', '<div id="__bundler_loading">กำลังโหลด…</div>')

# OneDrive sometimes holds the file open while syncing: retry a few times before giving up
function Write-Retry([string]$path, [string]$text) {
  for ($i = 1; $i -le 8; $i++) {
    try { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false))); return }
    catch { if ($i -eq 8) { throw }; Start-Sleep -Milliseconds 750 }
  }
}
Write-Retry $out $html

# 3) Bump the service worker version so devices pull the new version
$sw = Join-Path $root 'web\sw.js'
$swText = [IO.File]::ReadAllText($sw, [Text.Encoding]::UTF8)
$stamp = (Get-Date).ToString('yyyyMMddHHmmss')
$swText = [regex]::Replace($swText, "const VERSION = '[^']*';", "const VERSION = '$stamp';")
Write-Retry $sw $swText

"built web/index.html ($((Get-Item $out).Length) bytes), sw version $stamp"
