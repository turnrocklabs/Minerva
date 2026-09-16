# Build Minerva's Windows native editor dependencies, including the MCP schema helper.
# Run from repo root: powershell -ExecutionPolicy Bypass -File scripts\build-extensions.ps1
#
# Helper-only setup is also exercised by the CI helper matrix.
#
# Auto-installed if missing:
#   - Zig 0.15.2 (downloaded to $env:LOCALAPPDATA\zig)
#   - SCons (in .build-venv if missing)
#   - Git submodules (godot-cpp, vendor/ghostty, vendor/godot_wry, ...)
#
# Required on the machine (NOT auto-installed):
#   - Visual Studio 2022 with "Desktop development with C++" (MSVC: cl, lib, dumpbin)
#   - Rust toolchain via rustup (cargo) — current stable; godot-rust needs rustc >= 1.85
#   - Python 3 + pip
#
# Also installs prebuilt addon binaries (release downloads, no compile):
#   - godot-sqlite (2shady4u v4.7)
#   - EIRTeam.FFmpeg (1.1.4)
#
# NOT built here (separate script + heavier toolchain):
#   - godot_cef -> scripts\build-godot-cef.sh windows
#       (nightly Rust + ~1 GB CEF bundle; also needs CMake + Ninja on PATH —
#        `pip install cmake ninja` works)

param([switch]$Check, [switch]$HelperOnly, [switch]$VoiceOnly)

$ErrorActionPreference = "Stop"
function Assert-NativeSuccess([string]$Step) {
    if ($LASTEXITCODE -ne 0) { throw "$Step failed (exit $LASTEXITCODE)." }
}
$RepoRoot = git rev-parse --show-toplevel
Assert-NativeSuccess "Find repository"
Set-Location $RepoRoot

if ($HelperOnly -and $VoiceOnly) {
    throw "-HelperOnly and -VoiceOnly are mutually exclusive."
}

function Get-GitBash {
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCommand) { throw "Git for Windows is required to build the Voice runtime." }
    $gitRoot = Split-Path (Split-Path $gitCommand.Source -Parent) -Parent
    foreach ($root in @($gitRoot, (Split-Path $gitRoot -Parent))) {
        foreach ($candidate in @(
            (Join-Path $root "bin\bash.exe"),
            (Join-Path $root "usr\bin\bash.exe")
        )) {
            if (Test-Path $candidate) { return $candidate }
        }
    }
    throw "Git Bash was not found beside $($gitCommand.Source). Install Git for Windows."
}

function Build-VoiceRuntime {
    $gitBash = Get-GitBash
    $voicePython = (Get-Command python -ErrorAction Stop).Source
    Write-Host ""
    Write-Host "=== Building bundled Voice runtime (windows-x86_64) ===" -ForegroundColor Cyan
    $previousVoicePython = $env:MINERVA_VOICE_BUILD_PYTHON
    try {
        $env:MINERVA_VOICE_BUILD_PYTHON = $voicePython
        & $gitBash "src/plugins/voice/scripts/build-runtime.sh" "windows-x86_64"
        Assert-NativeSuccess "Voice runtime build"
    } finally {
        $env:MINERVA_VOICE_BUILD_PYTHON = $previousVoicePython
    }
}

$ZigVersion = "0.15.2"
$ZigDir = "$env:LOCALAPPDATA\zig"

Write-Host "Building Minerva GDExtensions for platform: windows" -ForegroundColor Cyan

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "Install Python 3.9+ (including pip and venv) and add it to PATH."
}
python -c "import sys; sys.exit(0 if sys.version_info >= (3, 9) else 'Python 3.9+ is required')"
Assert-NativeSuccess "Python prerequisite"
if ($Check) {
    $checkArgs = @()
    if ($HelperOnly) { $checkArgs += "--helper-only" }
    if ($VoiceOnly) { $checkArgs += "--voice-only" }
    python scripts/check-editor-ready.py @checkArgs
    Assert-NativeSuccess "Editor readiness"
    exit 0
}
if ($VoiceOnly) {
    Build-VoiceRuntime
    python scripts/check-editor-ready.py --voice-only
    Assert-NativeSuccess "Voice runtime readiness"
    exit 0
}
if (-not $HelperOnly -and -not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw "cargo not found. Install Rust via https://rustup.rs (then 'rustup update stable')."
}

# Check C++ tools before downloading/building dependencies.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "Install Visual Studio 2022 with 'Desktop development with C++'."
}
$vsPath = & $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
Assert-NativeSuccess "Locate Visual Studio"
if (-not $vsPath) { throw "No Visual Studio installation with C++ tools found." }
Import-Module (Join-Path $vsPath "Common7\Tools\Microsoft.VisualStudio.DevShell.dll")
Enter-VsDevShell -VsInstallPath $vsPath -DevCmdArguments "-arch=x64 -host_arch=x64" -SkipAutomaticLocation | Out-Null
Set-Location $RepoRoot
foreach ($tool in @("cl", "lib", "dumpbin")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required C++ tool missing: $tool" }
}
if (-not (Get-Command scons -ErrorAction SilentlyContinue)) {
    python -m venv .build-venv
    Assert-NativeSuccess "Create build environment"
    & .\.build-venv\Scripts\python.exe -m pip install scons
    Assert-NativeSuccess "Install SCons"
    $env:PATH = "$RepoRoot\.build-venv\Scripts;$env:PATH"
}
python scripts/build-json-schema-helper.py --platform windows
Assert-NativeSuccess "MCP schema helper build"
if ($HelperOnly) {
    python scripts/check-editor-ready.py --helper-only
    Assert-NativeSuccess "MCP schema helper readiness"
    exit 0
}

Build-VoiceRuntime

# ── Git submodules ────────────────────────────────────────────────────
Write-Host "Initializing git submodules..."
git submodule update --init --recursive
Assert-NativeSuccess "Initialize submodules"

# ── Install Zig if needed ─────────────────────────────────────────────
$zigExe = "$ZigDir\zig.exe"
$needZig = $true
if (Test-Path $zigExe) {
    if ((& $zigExe version 2>$null) -eq $ZigVersion) { $needZig = $false }
}
if ($needZig) {
    Write-Host "Installing Zig $ZigVersion..."
    $zigZip = "zig-x86_64-windows-${ZigVersion}.zip"
    $tmpDir = Join-Path $env:TEMP "zig-download"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    Invoke-WebRequest -Uri "https://ziglang.org/download/${ZigVersion}/${zigZip}" -OutFile "$tmpDir\$zigZip"
    Expand-Archive -Path "$tmpDir\$zigZip" -DestinationPath $tmpDir -Force
    New-Item -ItemType Directory -Force -Path $ZigDir | Out-Null
    Copy-Item -Path "$tmpDir\zig-x86_64-windows-${ZigVersion}\*" -Destination $ZigDir -Recurse -Force
}
$env:PATH = "$ZigDir;$env:PATH"
Write-Host "Zig $(& zig version)"

# ── Build godot_wry (Rust) ────────────────────────────────────────────
Write-Host ""
Write-Host "=== Building godot_wry ===" -ForegroundColor Cyan
python scripts/apply-wry-patches.py
Assert-NativeSuccess "Apply WRY patches"
Push-Location vendor\godot_wry\rust
& cargo build --release
Assert-NativeSuccess "WRY build"
Pop-Location
New-Item -ItemType Directory -Force -Path src\addons\godot_wry\bin\x86_64-pc-windows-msvc | Out-Null
Copy-Item vendor\godot_wry\rust\target\release\godot_wry.dll src\addons\godot_wry\bin\x86_64-pc-windows-msvc\ -Force
Write-Host "Installed godot_wry.dll"

# ── Build ghostty-vt shim (Zig, MSVC ABI) ─────────────────────────────
# -Dtarget=x86_64-windows-msvc pins the DLL's CRT to the OS UCRT. The shim is
# LLD-linked, so MSVC link.exe cannot consume Zig's import lib — we regenerate a
# native one below (that, not this flag, is what makes scons link).
# --global-cache-dir on the repo drive avoids Zig 0.15.2's cross-drive path panic.
Write-Host ""
Write-Host "=== Building ghostty-vt shim ===" -ForegroundColor Cyan
Push-Location src\gdextension\terminal\ghostty-shim
& zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-msvc --global-cache-dir (Join-Path $RepoRoot ".zig-global-cache")
Assert-NativeSuccess "Ghostty shim build"
Pop-Location

# ── Copy shim DLL to bin ──────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path src\bin | Out-Null
$shimDll = Get-ChildItem -Recurse -Path src\gdextension\terminal\ghostty-shim\zig-out -Filter minerva-vt.dll | Select-Object -First 1
if (-not $shimDll) { Write-Error "minerva-vt.dll not produced by zig build"; exit 1 }
Copy-Item $shimDll.FullName src\bin\ -Force
Write-Host "Copied minerva-vt.dll to src\bin\"

# ── Regenerate MSVC-native import lib for the shim ────────────────────
# MSVC link.exe cannot consume Zig/LLD's import lib (directives break default-lib
# resolution -> ~100 unresolved CRT/kernel32 externals). Rebuild a clean native
# import lib from the DLL's actual exports (dumpbin -> .def -> lib.exe), overwriting
# Zig's in place so SConstruct's LIBPATH/LIBS resolve a link.exe-friendly archive.
Write-Host ""
Write-Host "=== Regenerating MSVC import lib for the shim ===" -ForegroundColor Cyan
$shim   = "src\gdextension\terminal\ghostty-shim\zig-out"
$dllPath = Join-Path $shim "bin\minerva-vt.dll"
$defOut  = Join-Path $shim "lib\minerva-vt.def"
$libOut  = Join-Path $shim "lib\minerva-vt.lib"
$names = & dumpbin /exports $dllPath | ForEach-Object {
    if ($_ -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(minerva_vt\w*)') { $Matches[1] }
}
Assert-NativeSuccess "Read shim exports"
if (-not $names) { Write-Error "No minerva_vt* exports found in $dllPath"; exit 1 }
Write-Host "Exports ($($names.Count)): $($names -join ', ')"
@("LIBRARY minerva-vt", "EXPORTS") + $names | Set-Content -Path $defOut -Encoding ascii
& lib /def:$defOut /machine:x64 /out:$libOut | Out-Null
Assert-NativeSuccess "Build shim import library"
if (-not (Test-Path $libOut)) { Write-Error "lib.exe did not produce $libOut"; exit 1 }
Write-Host "Regenerated $libOut"

# ── Build the terminal GDExtension (release + debug) ──────────────────
Write-Host ""
Write-Host "=== Building terminal GDExtension (SCons) ===" -ForegroundColor Cyan
Push-Location src
& scons platform=windows target=template_release
Assert-NativeSuccess "Terminal release build"
& scons platform=windows target=template_debug
Assert-NativeSuccess "Terminal debug build"
Pop-Location

# ── Install godot-sqlite (prebuilt release download) ──────────────────
$SqliteVersion = "v4.7"
$SqliteMarker  = "src\addons\godot-sqlite\.sqlite-version"
if ((Test-Path $SqliteMarker) -and ((Get-Content $SqliteMarker) -eq $SqliteVersion) -and
    (Test-Path "src\addons\godot-sqlite\bin\libgdsqlite.windows.template_debug.x86_64.dll")) {
    Write-Host "godot-sqlite $SqliteVersion already installed"
} else {
    Write-Host ""
    Write-Host "=== Downloading godot-sqlite $SqliteVersion ===" -ForegroundColor Cyan
    $tmp = Join-Path $env:TEMP ("sqlite-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    Invoke-WebRequest -Uri "https://github.com/2shady4u/godot-sqlite/releases/download/$SqliteVersion/bin.zip" -OutFile "$tmp\bin.zip"
    Expand-Archive "$tmp\bin.zip" -DestinationPath "$tmp\extract" -Force
    New-Item -ItemType Directory -Force "src\addons\godot-sqlite\bin" | Out-Null
    Copy-Item "$tmp\extract\bin\*" "src\addons\godot-sqlite\bin\" -Recurse -Force
    $SqliteVersion | Set-Content $SqliteMarker
    Write-Host "godot-sqlite $SqliteVersion installed"
}

# ── Install EIRTeam.FFmpeg (prebuilt release download) ────────────────
$FfmpegVersion = "1.1.4"
$FfmpegTag     = "autobuild-2025-11-12-13-44"
$FfmpegMarker  = "src\addons\ffmpeg\.ffmpeg-version"
$ffWin = "src\addons\ffmpeg\win64\libgdffmpeg.windows.template_debug.x86_64.dll"
if ((Test-Path $ffWin) -and (Test-Path $FfmpegMarker) -and ((Get-Content $FfmpegMarker) -eq $FfmpegVersion)) {
    Write-Host "EIRTeam.FFmpeg $FfmpegVersion already installed"
} else {
    Write-Host ""
    Write-Host "=== Downloading EIRTeam.FFmpeg $FfmpegVersion ===" -ForegroundColor Cyan
    $tmp = Join-Path $env:TEMP ("ffmpeg-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    Invoke-WebRequest -Uri "https://github.com/EIRTeam/EIRTeam.FFmpeg/releases/download/$FfmpegTag/eirteam-ffmpeg-$FfmpegVersion.zip" -OutFile "$tmp\ff.zip"
    Expand-Archive "$tmp\ff.zip" -DestinationPath "$tmp\extract" -Force
    $ffSrc = (Get-ChildItem -Recurse -Path "$tmp\extract" -Filter ffmpeg.gdextension | Select-Object -First 1).Directory.FullName
    if ($ffSrc -and (Test-Path "$ffSrc\win64")) {
        New-Item -ItemType Directory -Force "src\addons\ffmpeg\win64" | Out-Null
        Copy-Item "$ffSrc\win64\*" "src\addons\ffmpeg\win64\" -Recurse -Force
        $FfmpegVersion | Set-Content $FfmpegMarker
        Write-Host "EIRTeam.FFmpeg $FfmpegVersion installed"
    } else {
        Write-Warning "Could not find win64/ in downloaded FFmpeg zip"
    }
}

# ── Verify ────────────────────────────────────────────────────────────
python scripts/check-editor-ready.py
Assert-NativeSuccess "Editor readiness"
