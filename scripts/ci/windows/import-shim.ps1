$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '../../..'))
# Generate a native MSVC import library from the DLL exports; Zig's library
# breaks default-library resolution when consumed by MSVC.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
# Include standalone Build Tools, which vswhere's default product filter excludes.
$vsPath = & $vswhere -products '*' -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $vsPath) { throw "No Visual Studio installation with C++ tools found." }
Import-Module (Join-Path $vsPath "Common7\Tools\Microsoft.VisualStudio.DevShell.dll")
Enter-VsDevShell -VsInstallPath $vsPath -DevCmdArguments "-arch=x64 -host_arch=x64" -SkipAutomaticLocation | Out-Null

$shim   = "src\gdextension\terminal\ghostty-shim\zig-out"
$dll    = Join-Path $shim "bin\minerva-vt.dll"
$defOut = Join-Path $shim "lib\minerva-vt.def"
$libOut = Join-Path $shim "lib\minerva-vt.lib"

# Pull the exported C symbols straight from the built DLL (source of truth).
$names = & dumpbin /exports $dll | ForEach-Object {
    if ($_ -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(minerva_vt\w*)') { $Matches[1] }
}
if (-not $names) { Write-Error "No minerva_vt* exports found in $dll"; exit 1 }
Write-Host "Exports ($($names.Count)): $($names -join ', ')"

# LIBRARY pins the import lib to minerva-vt.dll (bundled next to the exe
# at runtime via terminal.gdextension [dependencies]).
@("LIBRARY minerva-vt", "EXPORTS") + $names | Set-Content -Path $defOut -Encoding ascii
& lib /def:$defOut /machine:x64 /out:$libOut
if (-not (Test-Path $libOut)) { Write-Error "lib.exe did not produce $libOut"; exit 1 }
Write-Host "Regenerated MSVC import lib:"; Get-Item $libOut
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
