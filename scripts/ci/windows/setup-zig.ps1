$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '../../..'))
$ZigVersion = "0.15.2"
$url = "https://ziglang.org/download/$ZigVersion/zig-x86_64-windows-$ZigVersion.zip"
Invoke-WebRequest -Uri $url -OutFile "$env:RUNNER_TEMP\zig.zip"
Expand-Archive -Path "$env:RUNNER_TEMP\zig.zip" -DestinationPath "$env:RUNNER_TEMP\zig" -Force
$zigExe = Get-ChildItem -Recurse -Path "$env:RUNNER_TEMP\zig" -Filter zig.exe | Select-Object -First 1
if (-not $zigExe) { Write-Error "zig.exe not found after extraction"; exit 1 }
Add-Content -Path $env:GITHUB_PATH -Value $zigExe.Directory.FullName
& $zigExe.FullName version
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
