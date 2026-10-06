$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '../../..'))
Set-Location src/gdextension/terminal/ghostty-shim
# Keep caches on the workspace drive to avoid Zig 0.15.2's cross-drive assertion.
# The MSVC target selects UCRT; import-shim.ps1 produces the native import library.
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-msvc --global-cache-dir "$env:GITHUB_WORKSPACE\.zig-global-cache"
Write-Host "--- zig-out tree ---"
Get-ChildItem -Recurse zig-out | Select-Object FullName
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
