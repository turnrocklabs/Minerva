# Pickup

STATE: `macOS export build mostly fixed, blocked on Godot CEF.framework dlopen path resolution`

Last updated 2026-05-28.

---

## TL;DR

Spent 10 CI iterations on DCR `019e5ce2160f76d9868f7a000c41614b` peeling layers
of macOS export brokenness. Got the Minerva.app bundle built with all 5
GDExtensions present (terminal + libminerva-vt + WRY + sqlite + CEF), but
**the headless smoke launch still fails** because dyld can't resolve the path
Godot wants to dlopen for CEF.

Next session picks up at **iter 11**: try **move instead of symlink** for the
CEF path canonicalization. If that doesn't work, strip CEF for macOS (like we
already did for FFmpeg) to unblock HITL.

Latest commit on `turnrocklabs/Minerva:development` is `d09811b7`. All 10
iteration commits are pushed.

---

## 0. Current state of DCR `019e5ce2160f`

### Iteration history (10 push/fix cycles on `build.yml`)

| # | Bug found | Fix |
|---|---|---|
| 1 (40efc099) | macOS export running on ubuntu-latest silently skipped Frameworks/ bundling | Split macOS export into its own `export-macos` job on `macos-latest` |
| 1.5 (40efc099) | CI step copied universal libminerva-vt.dylib to wrong dir (`src/gdextension/bin/` not `src/bin/`) → SConstruct fell back to wrong-arch zig-out lib → ld emitted `warning: ignoring file ... built for macOS-x86_64` | Changed `cp libminerva-vt.dylib ../bin/` to `../../bin/` in build-macos |
| 2 (9903efaf) | macOS Gatekeeper SIGKILL'd unsigned Godot binary (`Killed: 9` / exit 137) | `xattr -dr com.apple.quarantine Godot.app` before launching |
| 3 (c3b7ef86) | `timeout` not in macos-latest PATH (failed before `--import` could warm the asset cache) + SConstruct still linking wrong-arch libminerva-vt because zig-out/lib/ was last overwritten with x86_64 | Dropped timeout, also `cp libminerva-vt.dylib ghostty-shim/zig-out/lib/` after lipo so ld sees universal |
| 4 (b3955939) | Frameworks/ bundling aborted at `Failed to open .../libgdffmpeg.macos.template_release.framework` because EIRTeam.FFmpeg's autobuild zip has no macOS support; also WRY .gdextension expected `.framework` but cargo built `.dylib` | Wrap libgodot_wry.dylib as a .framework in build-macos; strip ffmpeg.gdextension `[libraries] macos.*` lines at CI time |
| 5 (6e421955) | Frameworks/ still empty — strip from iter 4 only removed `[libraries]` macos.* lines, not the multi-line `[dependencies] macos = { ... }` block which still pointed at libavcodec.dylib etc. | awk-based strip handles the multi-line block |
| 6 (28d42362) | Frameworks/ FINALLY populated with all 5 extensions, smoke launch fails on CEF dlopen path mismatch (Godot's exporter bundles by basename, runtime looks for full path) + smoke grep over-fires on stripped ffmpeg | Post-export symlink `Contents/Frameworks/addons/godot_cef/bin/universal-apple-darwin/Godot CEF.framework -> ../../../../Godot CEF.framework`; filter ffmpeg from smoke grep |
| 7 (dac9d370) | build-godot tried to download `godot-wry-macos` artifact it doesn't need anymore (race with build-macos since I'd dropped it from `needs`) | Removed the dead download step from build-godot |
| 8 (6a9a6800) | iter 6's symlink target was hollow — godot-cef.yml's `actions/upload-artifact` step silently drops macOS framework binary symlinks (`Foo.framework/Foo -> Versions/Current/Foo`), so the downloaded artifact has the framework dir but no Mach-O binary | Bypass broken artifact pipeline: run `scripts/build-godot-cef.sh macos` in export-macos (same path local devs use) |
| 9 (60d31726) | CEF build-from-source failed at `cargo build --bin gdcef_helper --target x86_64-apple-darwin` with `can't find crate for core/std` — macos-latest is ARM64, cef-bundler's universal build needs both targets' rustlib in nightly toolchain | `rustup target add --toolchain nightly x86_64-apple-darwin aarch64-apple-darwin` |
| 10 (d09811b7) | Verify step passed (all 5 extensions in Frameworks/, CEF binary present), but smoke launch still fails: dyld returns `(not a file)` for the symlinked CEF path | (failed; next iteration's work) |

### What's confirmed working

- ✅ `check-gdextension`, `build-linux`, `build-windows`, `build-macos`, `functional-tests`, `build-godot` (Linux + Windows exports)
- ✅ macOS export creates Minerva.app
- ✅ `Contents/Frameworks/` populated with: libterminal framework + libminerva-vt.dylib + libgodot_wry.framework + libgdsqlite framework + Godot CEF.framework (+ Godot CEF.app helper)
- ✅ CEF framework binary actually exists inside the framework (was missing in iter 6/7 due to artifact upload symlink loss)
- ✅ `Verify macOS build assets` step passes

### What's currently failing (iter 10's state)

Smoke launch grep flags this from dyld:

```
ERROR: Can't open dynamic library: addons/godot_cef/bin/universal-apple-darwin/Godot CEF.framework.
Error: dlopen(...): tried:
  '.../Contents/Frameworks/addons/godot_cef/bin/universal-apple-darwin/Godot CEF.framework' (not a file)
  ...
```

The path Godot tells dyld to open at runtime is
`addons/godot_cef/bin/universal-apple-darwin/Godot CEF.framework` (Godot
prepends the .gdextension dir to the [libraries] macos value, which is
`bin/universal-apple-darwin/Godot CEF.framework` without `res://` prefix). But
Godot's macOS exporter bundled the framework by basename →
`Contents/Frameworks/Godot CEF.framework`.

My iter 10 symlink at
`Contents/Frameworks/addons/godot_cef/bin/universal-apple-darwin/Godot
CEF.framework` → `../../../../Godot CEF.framework` is in place (verified in
the build log), but dyld's `(not a file)` diagnostic suggests it sees the
symlink itself rather than following through to the framework directory.
Likely lstat() vs stat() in dyld's framework path resolution.

### Next session — first thing to try (iter 11)

**Move instead of symlink.** Replace the post-export symlink fixup with a
`mv`:

```bash
# Run in Contents/Frameworks/, after Godot's export
mkdir -p addons/godot_cef/bin/universal-apple-darwin
mv "Godot CEF.framework" "addons/godot_cef/bin/universal-apple-darwin/Godot CEF.framework"
mv "Godot CEF.app"       "addons/godot_cef/bin/universal-apple-darwin/Godot CEF.app"
# Re-sign because move may invalidate ad-hoc signatures
codesign --force --deep --sign - "addons/godot_cef/bin/universal-apple-darwin/Godot CEF.framework" 2>/dev/null || true
codesign --force --deep --sign - "addons/godot_cef/bin/universal-apple-darwin/Godot CEF.app" 2>/dev/null || true
```

This puts a REAL framework directory at the path Godot looks up. No
symlink-resolution surprises.

Risks:
- CEF helper app may reference its sibling framework via absolute or
  hardcoded relative path → may need investigation if the move breaks
  CEF helper process spawning. The dlopen success is the priority though.
- Ad-hoc codesign on the bundle might break after the move — try without
  re-signing first, since the smoke launch we care about ignores Gatekeeper.

### Fallback (if iter 11 fails)

**Strip CEF macOS entries** the same way we did for FFmpeg. App boots without
plugin webview panels on macOS. Add a follow-up DCR for proper CEF macOS
support. This unblocks HITL.

---

## 1. Pre-existing problems we discovered, NOT addressed in this DCR

### A. `tarball-smoke` failing on every run

Fails because Minerva's CI launch tries to connect to external MCP servers
(cobrowser, codetools) that aren't running on the runner. The tarball-smoke
script's grep treats their "Can't connect" errors as fatal. Has been failing
since the CAD merge (commit `5a6b955f`), unrelated to macOS work.

**TODO**: File DCR. Likely fix is in `scripts/tarball-smoke.sh` — its stdout
grep should exclude expected external-MCP-server "Can't connect" warnings
(matches `cobrowser` and `codetools` server names).

### B. EIRTeam.FFmpeg has no macOS framework in upstream releases

The autobuild release zip `eirteam-ffmpeg-1.1.4.zip` ships linux64 + win64
binaries only. `src/addons/ffmpeg/macos/` ends up empty after the download.

**Current state**: We strip `ffmpeg.gdextension`'s macos entries at CI time
so Godot doesn't try to bundle nonexistent paths. Video playback disabled on
macOS.

**TODO** (queued for after macOS export green): wire `scripts/build-ffmpeg.sh`
into export-macos with `actions/cache@v4` keyed on the
`vendor/EIRTeam.FFmpeg` submodule SHA. Script builds FFmpeg + gdextension
from source (30-60min first build, fast on cache hit). User authorized this
in the conversation.

### C. `godot-cef.yml` workflow's artifact upload drops symlinks

The macOS Godot CEF.framework's binary is stored at `Versions/A/Godot CEF`
with a symlink `Godot CEF.framework/Godot CEF -> Versions/Current/Godot
CEF`. `actions/upload-artifact@v4` doesn't preserve those by default. So the
downloaded artifact is broken.

**Current workaround**: build CEF from source in export-macos (bypasses the
broken artifact). Heavier (~15-20min in CI) but reliable.

**TODO**: File DCR. Possible fixes: `actions/upload-artifact` with `tar`
preprocessing, OR matrix-build godot-cef.yml per platform on native runners
so build artifacts don't need the upload roundtrip.

### D. `libgodot_wry.dylib` vs `libgodot_wry.framework` mismatch

Cargo's `cargo build --release` emits `libgodot_wry.dylib`, but
`WRY.gdextension` declares macOS as `bin/universal-apple-darwin/
libgodot_wry.framework`. We wrap the .dylib in a minimal framework structure
in build-macos. Works in CI; should mirror what
`scripts/build-extensions.sh` does locally (which also wraps + adds Info.plist
+ install_name_tool).

**Status**: Working. Could be cleaner if we replicated the local
build-extensions.sh framework structure exactly (Info.plist + @rpath
identifier), but dlopen succeeded as is in iter 5+.

### E. macOS Windows verify+smoke not yet added

The original DCR's items #3 + #4 included adding macOS + Windows verify+smoke
gates mirroring the Linux block in build.yml. macOS is done (in export-macos
job). Windows is NOT — `build-godot` still runs on ubuntu-latest and produces
Windows builds without a verify+smoke gate.

**TODO** (after macOS is green): split Windows export to its own
`export-windows` job on windows-latest, add verify+smoke gate. Could keep
build-godot for Linux only (rename to `export-linux`).

---

## 2. Git state at handoff

### Minerva (`turnrocklabs/Minerva`)

- HEAD on `development` is `d09811b7` (iter 10).
- 10 iteration commits pushed: `40efc099` → `9903efaf` → `c3b7ef86` →
  `b3955939` → `6e421955` → `28d42362` → `dac9d370` → `6a9a6800` →
  `60d31726` → `d09811b7`.
- Working tree clean except for pre-existing `vendor/EIRTeam.FFmpeg` and
  `vendor/godot_cef` submodule drift (don't touch).

### Plugins (`imrans-lab/minerva-plugins`)

Unchanged this session. `main` at `6e8fd7e` (cad-v0.1.1 release). All CAD
work shipped previously.

---

## 3. Context that must survive compaction

### Key files touched in `build.yml`

- `build-macos` job: added `cp libminerva-vt.dylib ghostty-shim/zig-out/lib/`
  after lipo. Wrapped libgodot_wry.dylib into a `.framework` directory with
  codesign. Upload uses `path:` for the framework dir.
- `export-macos` job (NEW, ~200 lines): runs on `macos-latest`. Sequence:
  download terminal-macos + godot-wry-macos artifacts, strip
  ffmpeg.gdextension macOS entries, download other addons, build godot-cef
  from source, install Godot + templates, export to .app, post-export CEF
  symlink fixup (CURRENTLY BROKEN), verify, smoke-launch with
  ffmpeg-tolerant grep.
- `build-godot` job: macOS export removed (now in export-macos). godot_wry
  (macOS) download removed. Else unchanged.
- `create-release`: `needs: [build-godot, export-macos]`.

### Hard rules (unchanged from prior pickup)

- Per-file `git add` only. No `-A` or `.`.
- No `--no-verify`. No `vendor/` touches.
- No force-push, no `git reset --hard`.
- Co-author trailer on commits.
- Minerva `development` push: autonomous-loop authorization carries.

---

## 4. First actions for next session

1. Open this file. Confirm state matches the run on
   `https://github.com/turnrocklabs/Minerva/actions/runs/26557616011`
   (iter 10's run).
2. Try iter 11 with **move-instead-of-symlink** for CEF (sketch in section 0).
3. If iter 11 fails: fall back to **strip CEF macOS** (section 0 fallback).
4. After macOS export green: HITL test (user downloads release, launches
   Minerva.app, confirms it boots, optionally tests CAD plugin install).
5. After HITL: queue follow-ups (FFmpeg from source / Windows export native /
   CEF artifact fix / tarball-smoke regression).

---

## 5. Loop budget accounting

- Original budget: 9 loops.
- Spent: 10 iterations (1 over budget by user-authorized continuation).
- Reason for overage: each iteration peeled exactly one layer; we ran out
  before hitting the bottom of the macOS-export-on-cross-OS / artifact-symlink
  / dyld-framework-search layered cake.
- Suggestion for next session: declare iter 11 + iter 12 budget upfront, with
  the fallback strip-CEF path as the explicit floor for "ship something".
