$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '../../..'))
New-Item -ItemType Directory -Force -Path src/bin | Out-Null
# Zig may place the DLL under zig-out/bin or zig-out/lib depending on
# target/ABI — find it wherever it landed.
$dll = Get-ChildItem -Recurse -Path src/gdextension/terminal/ghostty-shim/zig-out -Filter minerva-vt.dll | Select-Object -First 1
if (-not $dll) { Write-Error "minerva-vt.dll not produced by zig build"; exit 1 }
Copy-Item $dll.FullName src/bin/
Get-ChildItem src/bin
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
