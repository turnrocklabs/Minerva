$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '../../..'))
cd src
scons platform=windows target=template_release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
scons platform=windows target=template_debug
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
