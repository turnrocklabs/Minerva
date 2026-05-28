# Pickup

STATE: `CAD DCR shipped — Minerva macOS/Windows release builds broken, blocks HITL`

Last updated 2026-05-27.

---

## TL;DR

**CAD plugin DCR `019e6a4bcb0c71019723011d8f8c8cf1` shipped.** cad-v0.1.1 is live on
imrans-lab/minerva-plugins with embedded PBS python on 3 platforms.

**BUT** the user can't HITL because the downloaded **macOS Minerva.app crashes at launch**
with `Library not loaded: @rpath/libminerva-vt.dylib`. Linux likely works; Windows
unverified. **Next session picks up DCR `019e5ce2160f76d9868f7a000c41614b`** to fix the
Minerva build packaging across all three platforms.

---

## 0. CAD DCR — SHIPPED (status: review needed → done after HITL)

### What landed

- `imrans-lab/minerva-plugins:main`
  - Merge `a9af25a` (DCR's W1-W3 combined: cad embedded PBS python runtime)
  - Registry `6e8fd7e` (registry.json points at cad-v0.1.1)
  - **Release `cad-v0.1.1`** with 3 platform tarballs (linux-x86_64, macos-universal,
    windows-x86_64). 150-330MB each — embedded cpython 3.12.13 + build123d 0.10.0 +
    cadquery-ocp 7.8.1.1.post1 + mcad_worker.

- `turnrocklabs/Minerva:development`
  - Merge `5a6b955f` (W2 helpers + W3 tarball-smoke cad gate)

### Layer verification (cad fix proven before HITL block)

| Layer | Status | Evidence |
|---|---|---|
| L1 bundle self-test | ✅ green | macos-arm64 local + all 3 CI legs in run 26551796885 |
| L2 cad-side Go binary roundtrip | ✅ green | `cad/embedded_python_spawn_test.go` PASS on laptop in 56s |
| L3 real release tarball | ✅ green | Downloaded cad-0.1.1-macos-universal.tar.gz, mcad_validate sphere(5) returned ok=true in 35s |
| L4 HITL | ⏸️ BLOCKED | Minerva.app won't launch (separate DCR) |

### CAD work remaining (after HITL)

After HITL passes:
- Transition DCR `019e6a4bcb0c` to `shipped`.
- File follow-up DCRs:
  - linux-arm64 cad bundle (cadquery-ocp 7.8.x has no aarch64 wheels; bump build123d or
    use a private wheel index).
  - W2 cad-evaluate test install_from_url hang (PluginPolicy + cad capabilities in
    headless context).
  - `regen_registry.py` TARGETS list drops linux-arm64 to avoid 404 in marketplace.

---

## 1. THE BLOCKER — DCR `019e5ce2160f76d9868f7a000c41614b`

**Title:** "build.yml: latent CI bugs on all three platforms (surfaced by W0+W1
workflow_dispatch)"

**Status:** new (diagnosis written 2026-05-25; no work done)

**Pull with:** `mcp__docket__docket_get id=019e5ce2160f project=minerva`

### What the docket already knows

Four items found by W0+W1 swarm. Items #1+#2 are FIXED. Items #3+#4 are OPEN:

**Item #3 — macOS framework copy at parse time (OPEN, root cause of our HITL block).**

`src/SConstruct` lines 60-66 do:

```python
if env["platform"] == "macos":
    minerva_vt_src = "gdextension/terminal/ghostty-shim/zig-out/lib/libminerva-vt.dylib"
    framework_dir = "bin/libterminal.{}.{}.framework".format(env["platform"], env["target"])
    minerva_vt_dst = os.path.join(framework_dir, "libminerva-vt.dylib")
    if os.path.exists(minerva_vt_src) and os.path.isdir(framework_dir):  # ← parse-time
        shutil.copy2(minerva_vt_src, minerva_vt_dst)
```

The `os.path.isdir(framework_dir)` check runs at SConstruct **parse time**, before
scons builds the framework. Fresh CI checkout → framework dir doesn't exist yet → copy
skipped → libminerva-vt.dylib never gets into the .framework → exported .app missing
the dylib → DYLD lookup fails at launch.

Works locally only because devs have leftover framework dirs from prior builds. Docket
proposes: `env.AddPostAction(library, ...)` instead of parse-time check.

**Item #4 — Windows missing ghostty-vt build (OPEN, Windows runtime risk).**

`build-windows` job has no `zig build` step. Terminal extension's SConstruct
unconditionally links `minerva-vt.lib` → `LINK : fatal error LNK1181: cannot open input
file 'minerva-vt.lib'`. The docket flags this as an open question: cross-compile shim
to Windows, or have SConstruct conditionally exclude minerva-vt on Windows?
`scripts/build-extensions.sh` only handles linux/macos, suggesting the latter was
original intent.

### What I added to the analysis 2026-05-27

Beyond the docket's 2026-05-25 findings, the current build.yml has **post-export
verification + smoke-launch only on Linux** (build.yml lines 682-746). macOS and
Windows export steps run but don't gate the artifact. So:
- Linux: protected by verify+smoke ✅
- macOS: NO gate — actual macOS .app from a recent CI run is missing libminerva-vt.dylib (confirmed by user's launch crash)
- Windows: NO gate — unknown if it runs at all from a fresh download

The fix is two layers:
1. Resolve items #3+#4 (the actual packaging bugs).
2. Add macOS + Windows equivalents of the Linux verify+smoke block (so this class of bug fails at CI, not at HITL).

### Proposed plan for the next session

Five rounds:

| Round | Work |
|---|---|
| R1 | Reproduce + investigate: download the same Minerva.app the user has; inspect what's inside (`unzip -l Minerva.app/Contents/`). Confirm libminerva-vt.dylib is missing. Investigate item #3's SConstruct change locally + confirm the AddPostAction approach. |
| R2 | Item #3 fix: rewrite the SConstruct framework-copy as a scons builder action (or AddPostAction). Push to dev; CI runs build.yml. |
| R3 | Add macOS verify+smoke step in build.yml (mirror Linux lines 682-746): check `Minerva.app/Contents/Frameworks/libminerva-vt.dylib` + CEF runtime files, then smoke-launch with `--headless --quit-after 30` to detect dlopen errors. |
| R4 | Item #4 + Windows verify+smoke: decide cross-compile vs conditional exclude, implement, add Windows verify+smoke step in build.yml. |
| R5 | Verify all 3 platforms run from a fresh download. Then return to CAD HITL on the now-working Minerva. |

### Acceptance criteria for DCR `019e5ce2`

1. A push to `development` produces Minerva-{Windows,Linux,macOS} artifacts that all
   pass a post-export `--headless --quit-after 30` smoke launch in CI.
2. User downloads the macOS .app from a fresh CI run and it launches without dyld errors.
3. Same for Windows (.exe) and Linux (AppImage or .x86_64).
4. Then CAD HITL resumes against this build.

---

## 2. GIT STATE AT HANDOFF

### Minerva (`turnrocklabs/Minerva`)

- HEAD on `development` is `5a6b955f` (CAD's W2+W3 Minerva-side merge — pushed).
- Local working tree: `Docs/minerva.dct` modified (docket DB drift, pre-existing) +
  vendor/ submodule modifications (pre-existing). `Docs/pickup.md` (this file)
  will be modified by next agent at session-start.
- Stash: there's a `git stash` entry from this session containing `Docs/minerva.dct`
  pre-merge. Drop it (`git stash drop`) — the merged state is fine.

### Plugins (`imrans-lab/minerva-plugins`)

- HEAD on `main` is `6e8fd7e` (registry regen — pushed). Clean.
- DCR branch `dcr/cad-embedded-python-linux` is fully merged + can be deleted whenever.

### Tags / Releases

- `cad-v0.1.1` on imrans-lab/minerva-plugins — final release, 3 platform tarballs.
- `cad-v0.1.1-branch-dcr-cad-embedded-python-linux` — prerelease (can keep or delete).
- Plus the auto-tagged prereleases from intermediate fix-up commits.

---

## 3. CONTEXT THAT MUST SURVIVE COMPACTION

### Key technical details for the build-fix work

- **SConstruct path bug** is at `src/SConstruct:60-66`. Parse-time `os.path.isdir()`
  vs build-time `AddPostAction`. Docket DCR has the proposed fix shape.
- **terminal.gdextension** at `src/bin/terminal.gdextension` declares
  `[dependencies] macos = { "../../bin/libminerva-vt.dylib": "" }`. The Linux
  equivalent `linux.x86_64 = { ... }` works. macOS entry is declared but the
  exporter drops it (Godot exporter `[dependencies]` quirk).
- **Linux verify block** in `.github/workflows/build.yml:682-746` is the template
  to copy for macOS + Windows. Has both file-presence check and smoke-launch.
- **Build-extensions script**: `scripts/build-extensions.sh` (Unix-only, no Windows
  variant) is one signal the project considers ghostty-vt as Unix-only.
- **Universal binary build for macOS** is at `build.yml:436-450`. Creates `libminerva-vt-arm64.dylib` + `libminerva-vt-x86_64.dylib`, then lipo to universal `libminerva-vt.dylib`, then `cp` to `src/bin/`. The .dylib EXISTS in `src/bin/`. The SConstruct copy into the framework is what fails.

### Process / tooling notes

- 11-loop CAD DCR autonomous run completed this session. Loop budget format
  works for self-paced work. User authorized budget extension when Windows
  fix-ups stretched past planned scope.
- Reviewer sub-agent pattern (Opus, fresh context, ~50-100 lines of brief)
  caught real issues in W1a/W1b. Worth re-using.
- `Monitor` tool with 10-min poll + 35-min stall detect worked well for CI
  watching. `gh run view --json` is the right API.
- Docket-update for substantive scope amendments (vs creating new DCRs) kept
  the work item history coherent. Pattern: append a `## Scope amendment —
  <date>` section instead of replacing the original description.

### CAD-fix details that aren't blocking but worth knowing

- `cad/internal/runtime/extract.go` is **plugin-agnostic by design**. When a
  second python-embedded plugin arrives, mechanically move to `pkg/pyembed/`
  and update import paths in cad/.
- `scripts/build-python-runtime-bundle.sh` at minerva-plugins repo root is
  also plugin-agnostic. Reads each plugin's `scripts/runtime-bundle.lock`
  for pins.
- `bridge.Worker.readyTimeout` was bumped from 15s to 60s default (with env
  override `MINERVA_WORKER_READY_TIMEOUT_SEC`) because cold-extract of the
  embedded bundle takes 30-50s on first start.
- macOS Gatekeeper: PBS unsigned binaries extracted at runtime DID NOT
  trigger quarantine for the CAD bundle's python.exe — the L3 verification
  ran clean without `xattr` cleanup. So gatekeeper hostility may be milder
  than feared.

---

## 4. HARD RULES (UNCHANGED)

- Per-file `git add` only. No `-A` or `.`.
- No `--no-verify`. No `vendor/` touches.
- No force-push, no `git reset --hard`.
- Co-author trailer on commits.
- Plugins repo `imrans-lab/minerva-plugins`: user authorization for any main push
  is per-instance — re-ask each time.
- Minerva `development` push: autonomous-loop authorization carries (per
  this session's Gate C confirmation).

---

## 5. FIRST ACTIONS FOR NEXT SESSION

1. `mcp__docket__docket_get id=019e5ce2160f project=minerva` to read the full DCR.
2. Read `src/SConstruct` lines 60-66 to confirm the parse-time bug is still there.
3. Download the same Minerva.app the user hit the crash on (latest macOS build
   from imrans-lab/turnrocklabs Minerva Actions).
4. Verify the dylib is missing inside the .app:
   `unzip -l Minerva.app/Contents/Frameworks/libterminal.macos.template_release.framework/`.
5. Then propose loop budget to the user and start the implementation rounds above.

**Do not start the CAD HITL work in next session** — that's gated on Minerva
build packaging being fixed first.
