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
  <link rel="apple-touch-icon" href="./icons/icon-512.png">
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

[IO.File]::WriteAllText($out, $html, (New-Object Text.UTF8Encoding($false)))

# 3) Bump the service worker version so devices pull the new version
$sw = Join-Path $root 'web\sw.js'
$swText = [IO.File]::ReadAllText($sw, [Text.Encoding]::UTF8)
$stamp = (Get-Date).ToString('yyyyMMddHHmmss')
$swText = [regex]::Replace($swText, "const VERSION = '[^']*';", "const VERSION = '$stamp';")
[IO.File]::WriteAllText($sw, $swText, (New-Object Text.UTF8Encoding($false)))

"built web/index.html ($((Get-Item $out).Length) bytes), sw version $stamp"
