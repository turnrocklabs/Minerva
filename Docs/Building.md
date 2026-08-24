# Building Minerva

Everything needed to get a fresh clone compiling on Linux, macOS, or Windows.
`README.md` covers the common path; this file is the complete reference,
including the pieces the main build script deliberately leaves out.

## The short version

```bash
git clone --recursive https://github.com/turnrocklabs/Minerva.git
cd Minerva
scripts/build-extensions.sh                                          # Linux / macOS
powershell -ExecutionPolicy Bypass -File scripts\build-extensions.ps1  # Windows
```

Then open `src/project.godot` in Godot **4.6+** and press F5.

That is enough for everything except CEF-hosted plugin panels and the PDF
sidecar — see [Builds not covered](#builds-not-covered-by-the-main-script).

## What `build-extensions.sh` / `.ps1` does

Both scripts are idempotent — re-running them skips work that is already
current. They handle, in order:

| Step | Notes |
|---|---|
| Git submodules | `src/godot-cpp`, `vendor/ghostty`, `vendor/godot_wry`, `vendor/EIRTeam.FFmpeg` |
| Zig 0.15.2 | Downloaded user-local; no sudo/admin |
| SCons | Installed via pip |
| ghostty-vt shim | Zig build → `libminerva-vt` |
| Terminal GDExtension | SCons build → `libterminal.*` |
| godot_wry WebView | Cargo build, with Minerva's patches applied first |
| EIRTeam.FFmpeg 1.1.4 | Prebuilt download, **falling back to a source build** |
| godot-sqlite 4.7 | Prebuilt download |

Both libraries land in `src/bin/`.

The Windows script mirrors the `build-windows` job in
`.github/workflows/build.yml`, which is the source of truth if the two ever
disagree.

### Prerequisites the scripts do NOT install

- **Rust / Cargo** — via rustup, needed for `godot_wry`. Windows needs
  rustc ≥ 1.85.
- **Linux only:** `libgtk-3-dev` and `libwebkit2gtk-4.1-dev` for `godot_wry`.
  Without them the script skips the WebView build and panels fall back.
- **Windows only:** Visual Studio 2022 with "Desktop development with C++"
  (`cl`, `lib`, `dumpbin`), plus Python 3 + pip.
- **macOS:** Xcode command line tools.

## Builds not covered by the main script

Two things are separate because they need a heavier toolchain, and one is a
fallback you only hit on some platforms.

### godot-cef — CEF-hosted plugin panels

```bash
scripts/build-godot-cef.sh            # auto-detects platform
scripts/build-godot-cef.sh linux      # or macos / windows
```

Needs rustup; the script installs the pinned Rust nightly, `export-cef-dir`,
CMake + Ninja (`pip install cmake ninja`), and the ~1 GB CEF binary bundle if
any are missing. It pins `vendor/godot_cef` to v1.13.0, applies every
`patches/godot_cef/*.patch`, builds, and deploys to
`src/addons/godot_cef/bin/<platform>/`:

| Platform | Deploy directory |
|---|---|
| linux | `bin/x86_64-unknown-linux-gnu/` |
| macos | `bin/universal-apple-darwin/` |
| windows | `bin/x86_64-pc-windows-msvc/` |

**Cross-compiling is not supported** — run the script on each target OS.

The CEF version must match the `cef` / `cef-dll-sys` crate versions pinned in
`vendor/godot_cef/Cargo.lock`. Mixing a `libcef` from a different major.minor
makes `cef::initialize()` fail at runtime rather than at build time.

### FFmpeg from source

`build-extensions.sh` prefers EIRTeam's prebuilt release, but upstream does not
ship binaries for every platform — notably **macOS**. When the download has no
binaries for your platform, build from source:

```bash
scripts/build-ffmpeg.sh          # auto-detects platform
```

First build takes **30–60 minutes** (it compiles FFmpeg itself via ffmpeg-kit);
later runs are skipped while the marker file is current. Needs Homebrew (macOS)
or apt (Linux) for autotools/yasm/nasm, plus SCons.

### host.pdf sidecar

```bash
scripts/build-host-pdf.sh        # auto-detects platform
```

A standalone pure-Go binary (`src/sidecars/host_pdf`) deployed to `src/bin/`.
Fonts are embedded, so it reads no OS font paths. Deliberately **not** wired
into `build-extensions.sh` — build it only if you need the PDF capability.

## Vendor patches

Minerva carries local patches against two vendored dependencies. Both are
applied at build time and the submodule is reset afterwards, so
`git status` stays clean and the patches never live in the submodule's history.

- `patches/godot_wry-*.patch` — applied by `build-extensions.sh`.
  See `patches/README.md`, which also documents how to add one.
- `patches/godot_cef/*.patch` — applied by `build-godot-cef.sh`.
  See `patches/godot_cef/README.md` for the rationale behind each.

Patches are rebased by hand when a submodule is bumped. Keep them minimal so
upstream drift does not break them all at once.

## macOS: clear quarantine before the FIRST launch

For a **packaged** `.app` (a downloaded or distributed build, not one you run
from the editor):

```bash
xattr -dr com.apple.quarantine /path/to/Minerva.app
```

This must run **before the app is launched for the first time**. Gatekeeper
caches its decision about helper binaries on first launch, so clearing the
attribute afterwards does not undo the damage — you get a build whose helper
processes fail in ways that look like application bugs.

## If you already cloned without `--recursive`

```bash
git submodule update --init --recursive
scripts/build-extensions.sh
```

## Verifying a build

The main scripts end with a verify step that checks the expected libraries
exist in `src/bin/`. Beyond that, opening `src/project.godot` and pressing F5
is the real test: a missing GDExtension shows up as a failed autoload or a
panel falling back, not as a build error.
