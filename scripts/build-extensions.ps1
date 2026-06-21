# Build Minerva's Windows GDExtensions: ghostty-vt shim + terminal + godot_wry.
# Run from repo root: powershell -ExecutionPolicy Bypass -File scripts\build-extensions.ps1
#
# Mirrors the build-windows job in .github/workflows/build.yml (the source of truth).
#
# Auto-installed if missing:
#   - Zig 0.15.2 (downloaded to $env:LOCALAPPDATA\zig)
#   - SCons (via pip)
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

$ErrorActionPreference = "Stop"
$RepoRoot = git rev-parse --show-toplevel
Set-Location $RepoRoot

$ZigVersion = "0.15.2"
$ZigDir = "$env:LOCALAPPDATA\zig"

Write-Host "Building Minerva GDExtensions for platform: windows" -ForegroundColor Cyan

# ── Git submodules ────────────────────────────────────────────────────
Write-Host "Initializing git submodules..."
git submodule update --init --recursive

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

# ── Install SCons if needed ───────────────────────────────────────────
if (-not (Get-Command scons -ErrorAction SilentlyContinue)) {
    Write-Host "Installing SCons via pip..."
    pip install scons
}

# ── Require cargo (godot_wry) ─────────────────────────────────────────
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Error "cargo not found. Install Rust via https://rustup.rs (then 'rustup update stable')."
    exit 1
}

# ── Enter VS Developer Shell (puts cl / lib / dumpbin on PATH) ────────
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Error "Visual Studio Installer not found. Install VS 2022 with 'Desktop development with C++'."
    exit 1
}
$vsPath = & $vswhere -latest -property installationPath
if (-not $vsPath) { Write-Error "No Visual Studio with C++ tools found."; exit 1 }
Import-Module (Join-Path $vsPath "Common7\Tools\Microsoft.VisualStudio.DevShell.dll")
Enter-VsDevShell -VsInstallPath $vsPath -DevCmdArguments "-arch=x64 -host_arch=x64" -SkipAutomaticLocation | Out-Null
Set-Location $RepoRoot
$env:PATH = "$ZigDir;$env:PATH"   # re-assert Zig ahead of any VS shims

# ── Build godot_wry (Rust) ────────────────────────────────────────────
Write-Host ""
Write-Host "=== Building godot_wry ===" -ForegroundColor Cyan
Push-Location vendor\godot_wry
git checkout -- .   # reset so patches stay idempotent
Get-ChildItem ..\..\patches\godot_wry-*.patch -ErrorAction SilentlyContinue | ForEach-Object {
    git apply $_.FullName; Write-Host "Applied: $($_.Name)"
}
Set-Location rust
& cargo build --release
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
if (-not $names) { Write-Error "No minerva_vt* exports found in $dllPath"; exit 1 }
Write-Host "Exports ($($names.Count)): $($names -join ', ')"
@("LIBRARY minerva-vt", "EXPORTS") + $names | Set-Content -Path $defOut -Encoding ascii
& lib /def:$defOut /machine:x64 /out:$libOut | Out-Null
if (-not (Test-Path $libOut)) { Write-Error "lib.exe did not produce $libOut"; exit 1 }
Write-Host "Regenerated $libOut"

# ── Build the terminal GDExtension (release + debug) ──────────────────
Write-Host ""
Write-Host "=== Building terminal GDExtension (SCons) ===" -ForegroundColor Cyan
Push-Location src
& scons platform=windows target=template_release
& scons platform=windows target=template_debug
Pop-Location

# ── Install godot-sqlite (prebuilt release download) ──────────────────
$SqliteVersion = "v4.7"
$SqliteMarker  = "src\addons\godot-sqlite\.sqlite-version"
if ((Test-Path $SqliteMarker) -and ((Get-Content $SqliteMarker) -eq $SqliteVersion)) {
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
Write-Host ""
Write-Host "=== Build complete ===" -ForegroundColor Green
Get-ChildItem "src\bin\*terminal*", "src\bin\*minerva*" | Format-Table Name, Length -AutoSize
Get-ChildItem "src\addons\godot_wry\bin\x86_64-pc-windows-msvc\godot_wry.dll" -ErrorAction SilentlyContinue | Format-Table Name, Length -AutoSize
Write-Host "Installed addons: godot_wry, godot-sqlite, ffmpeg (terminal in src\bin\)."
Write-Host "Open src\project.godot in Godot 4.6+ to run Minerva."
Write-Host "Note: godot_cef is built separately -> scripts\build-godot-cef.sh windows (needs CMake + Ninja)." -ForegroundColor DarkGray
