# Prepare a github-upload/ folder holding only the files to upload to GitHub (drag everything inside into the repo)
# How to run:  powershell -NoProfile -ExecutionPolicy Bypass -File tools/package.ps1
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$out = Join-Path $root 'github-upload'
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force $out | Out-Null
foreach ($d in 'web', 'src', 'supabase', 'tools', '.github') {
  Copy-Item -Recurse -Force (Join-Path $root $d) (Join-Path $out $d)
}
foreach ($f in 'README.md', '.gitignore') { Copy-Item -Force (Join-Path $root $f) $out }
$files = Get-ChildItem -Recurse -File $out
$big = $files | Where-Object { $_.Length -gt 25MB }
if ($big) { throw ('file larger than 25MB (GitHub web upload limit): ' + ($big.FullName -join ', ')) }
"github-upload: $($files.Count) files, $([math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 2)) MB"
