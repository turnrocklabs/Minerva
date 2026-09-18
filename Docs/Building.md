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

Close Minerva and its editor before a full native rebuild. After the dependency
check passes, open `src/project.godot` in Godot **4.6+** and press F5.

This includes the MCP helper required for plugin startup. CEF-hosted plugin
panels and the PDF sidecar need separate builds. See
[Builds not covered](#builds-not-covered-by-the-main-script).

## What `build-extensions.sh` / `.ps1` does

Both scripts support incremental reruns. They check required toolchains before
compilation and handle these dependencies:

| Step | Notes |
|---|---|
| Git submodules | `src/godot-cpp`, `vendor/ghostty`, `vendor/EIRTeam.FFmpeg` |
| Zig 0.15.2 | Downloaded user-local; no sudo/admin |
| SCons | Uses an existing install, or installs into ignored `.build-venv` |
| MCP JSON Schema helper | Pinned, checksum-verified jsoncons + Minerva patch; C++17 build |
| Built-in Voice runtime | Pinned CPython 3.12, wheels, detector models, and current worker source for the host architecture |
| ghostty-vt shim | Zig build → `libminerva-vt` |
| Terminal GDExtension | SCons build → `libterminal.*` |
| EIRTeam.FFmpeg 1.1.4 | Prebuilt download; Unix script falls back to source build |
| godot-sqlite 4.7 | Prebuilt download |

Terminal, shim, and schema helper land in `src/bin/`; addon libraries land in
`src/addons/`. The final check fails if a required artifact is missing, cannot
load on the current host, or the schema helper fails its protocol check.

The CI helper matrix runs the same contributor helper-only setup on Linux,
Windows, macOS ARM, and macOS Intel before separate release packaging tests.
The full native build and export jobs still have platform-specific recipes.

### Prerequisites the scripts do NOT install

- **All platforms:** Git, Python **3.9+** with pip and venv, and a C++17 compiler.
  On Debian/Ubuntu, install `build-essential python3-venv curl unzip`.
- **Windows only:** Visual Studio 2022 with "Desktop development with C++"
  (`cl`, `lib`, `dumpbin`), plus Python 3 + pip.
- **macOS:** Xcode command line tools.

SCons is installed locally when missing, avoiding global Python package changes.
Unix Zig downloads live under `~/.local/share/minerva/`, with a launcher link in
`~/.local/bin/`; deleting temporary directories no longer breaks the toolchain.

## Repairing or checking an existing checkout

```bash
scripts/build-extensions.sh --helper-only          # Build/check only the MCP helper
scripts/build-extensions.sh --voice-only           # Build/check only built-in Voice
scripts/build-extensions.sh --check                # Check installed native dependencies
scripts/build-extensions.sh --check --helper-only  # Only probe the installed helper
scripts/build-extensions.sh --check --voice-only   # Only probe Voice
```

```powershell
./scripts/build-extensions.ps1 -HelperOnly
./scripts/build-extensions.ps1 -VoiceOnly
./scripts/build-extensions.ps1 -Check
./scripts/build-extensions.ps1 -Check -HelperOnly
./scripts/build-extensions.ps1 -Check -VoiceOnly
```

Helper-only setup needs Python, SCons and a C++ compiler; it does not initialize
submodules, install Zig, or rebuild loaded GDExtensions. It is the targeted repair
for `MCP JSON Schema helper is missing at ...` during plugin startup.

Voice-only setup needs Python, Git Bash on Windows, curl, and tar. It bypasses
C++, SCons, Zig, Rust, and native GDExtension builds. It uses the same pinned
runtime recipe as release CI and is the targeted repair command shown when the
built-in Voice runtime is missing or stale.

jsoncons archives are checksum-verified and cached in `.dependency-cache/`
(`MINERVA_DEPENDENCY_CACHE` overrides that location). Verified extracted headers
retain their timestamps so SCons can skip compilation on a second run. If the
generated source tree or pinned inputs change, setup stops with instructions to
preserve local edits and move `src/native/vendor/jsoncons` aside before reacquiring.
Interrupted downloads and extraction do not leave a partial tree marked current.

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

Minerva carries local patches against vendored dependencies.
- `patches/godot_cef/*.patch` — applied by `build-godot-cef.sh`.
  That separate script has its own checkout/reset behavior; preserve local CEF
  work before running it. See `patches/godot_cef/README.md` for the rationale.
- `src/native/json_schema_helper/jsoncons-integral-multiple-of.patch` — verified
  and applied by the schema helper builder to the generated jsoncons tree.

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

The main scripts and check-only mode share `scripts/check-editor-ready.py`:

- Start the actual helper, ping it, compile a schema, accept valid input, reject
  invalid input, compare numbers, release the handle, and require a clean EOF exit.
- Verify the host Voice runtime's required files, manifest hashes, target and
  interpreter architecture, and source-input fingerprint; then perform a bounded
  MCP initialize and require a clean EOF exit without opening audio devices.
- Load terminal, ghostty shim, SQLite and FFmpeg in isolated native loader processes.
  The OS checks host architecture and linked dependencies; GDExtension entry symbols
  must exist. Run with a Python interpreter matching your Godot architecture.
- Report CEF and PDF presence separately. Their runtime behavior is not tested.

This does not launch Godot, import the project, or prove every extension's Godot
API compatibility. Finish with an editor run and plugin-start HITL; browser panels
and PDF need their own functional checks. Release packaging validation remains separate.
