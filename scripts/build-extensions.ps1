# Build all Minerva GDExtensions (terminal + ghostty-vt shim).
# Run from repo root: powershell -ExecutionPolicy Bypass -File scripts\build-extensions.ps1
#
# Prerequisites installed automatically if missing:
#   - Zig 0.15.2 (downloaded to $env:LOCALAPPDATA\zig)
#   - SCons (via pip)
#   - Git submodules (godot-cpp, vendor/ghostty)

$ErrorActionPreference = "Stop"
$RepoRoot = git rev-parse --show-toplevel
Set-Location $RepoRoot

$ZigVersion = "0.15.2"
$ZigDir = "$env:LOCALAPPDATA\zig"

Write-Host "Building for platform: windows" -ForegroundColor Cyan

# ── Git submodules ────────────────────────────────────────────────────

Write-Host "Initializing git submodules..."
git submodule update --init --recursive

# ── Install Zig if needed ─────────────────────────────────────────────

$zigExe = "$ZigDir\zig.exe"
$needZig = $true
if (Test-Path $zigExe) {
    $currentVersion = & $zigExe version 2>$null
    if ($currentVersion -eq $ZigVersion) { $needZig = $false }
}

if ($needZig) {
    Write-Host "Installing Zig $ZigVersion..."
    $arch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "x86" }
    $zigZip = "zig-${arch}-windows-${ZigVersion}.zip"
    $zigUrl = "https://ziglang.org/download/${ZigVersion}/${zigZip}"
    $tmpDir = Join-Path $env:TEMP "zig-download"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

    Write-Host "Downloading $zigUrl..."
    Invoke-WebRequest -Uri $zigUrl -OutFile "$tmpDir\$zigZip"
    Expand-Archive -Path "$tmpDir\$zigZip" -DestinationPath $tmpDir -Force

    New-Item -ItemType Directory -Force -Path $ZigDir | Out-Null
    Copy-Item -Path "$tmpDir\zig-${arch}-windows-${ZigVersion}\*" -Destination $ZigDir -Recurse -Force

    $env:PATH = "$ZigDir;$env:PATH"
    Write-Host "Zig $(& $zigExe version) installed to $ZigDir"
} else {
    $env:PATH = "$ZigDir;$env:PATH"
    Write-Host "Zig $(& zig version) already installed"
}

# ── Install SCons if needed ───────────────────────────────────────────

if (-not (Get-Command scons -ErrorAction SilentlyContinue)) {
    Write-Host "Installing SCons via pip..."
    pip install scons
}

# ── Build ghostty-vt shim (Zig) ──────────────────────────────────────

Write-Host ""
Write-Host "=== Building ghostty-vt shim ===" -ForegroundColor Cyan
Set-Location "src\gdextension\terminal\ghostty-shim"
& zig build -Doptimize=ReleaseFast
Set-Location $RepoRoot

$shimLib = "src\gdextension\terminal\ghostty-shim\zig-out\lib\minerva-vt.dll"
if (-not (Test-Path $shimLib)) {
    # Try .lib or .so as fallback
    $shimLib = Get-ChildItem "src\gdextension\terminal\ghostty-shim\zig-out\lib\*minerva*" | Select-Object -First 1
    if (-not $shimLib) {
        Write-Host "ERROR: Shim library not found" -ForegroundColor Red
        exit 1
    }
}
Write-Host "Shim built: $shimLib"

# ── Build Godot C++ extension (SCons) ────────────────────────────────

Write-Host ""
Write-Host "=== Building Godot terminal extension ===" -ForegroundColor Cyan
Set-Location src
& scons platform=windows
Set-Location $RepoRoot

# ── Copy shim library to bin/ ─────────────────────────────────────────

Write-Host ""
Write-Host "=== Installing libraries ===" -ForegroundColor Cyan
Copy-Item $shimLib -Destination "src\bin\" -Force
Write-Host "Copied $(Split-Path $shimLib -Leaf) to src\bin\"

# ── Verify ────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Build complete ===" -ForegroundColor Green
Write-Host "Libraries in src\bin\:"
Get-ChildItem "src\bin\*terminal*", "src\bin\*minerva*" | Format-Table Name, Length -AutoSize
Write-Host ""
Write-Host "Open src\project.godot in Godot 4.4+ to run Minerva."
