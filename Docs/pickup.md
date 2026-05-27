# Pickup

STATE: `DCR 019e6a4bcb0c — W2 RED test partially written, RED proof pending on laptop`

Last updated 2026-05-27 — laptop handoff. Workstation is being put down; resume on laptop.

---

## 0. WHAT THIS DCR IS

**DCR `019e6a4bcb0c71019723011d8f8c8cf1`** — CAD plugin: embedded PBS python runtime (Plan A). Status: `designing`.

Closes HITL #2 from the prior marketplace push (DCR `019e62ade5be`): cad evaluate fails with
`bridge.Worker.Start: exec: fork/exec /usr/bin/python3: no such file or directory` because the
marketplace tarball ships only the cad-plugin binary + manifest + ui/ — no Python, no
mcad_worker package, no build123d / cadquery-ocp.

Plan A (your choice 2026-05-27): build a per-platform PBS (`python-build-standalone`) bundle
containing cpython 3.12.x + build123d + cadquery-ocp + mcad_worker, `go:embed` it into the
cad-plugin Linux binary, extract to `<data_directory>/runtime/<plugin_version>/` on first run.
Per-plugin isolation, no Minerva-host-python dependency, no network at first start.

Full plan + 5-why analysis + 4-option comparison: see DCR docket article on item
`019e6a4bcb0c71019723011d8f8c8cf1` (project: minerva). Read with
`mcp__docket__docket_get id=019e6a4bcb0c project=minerva`.

---

## 1. DCR TREE (already filed in docket)

```
DCR  019e6a4bcb0c  designing — CAD plugin embedded PBS python runtime (Plan A)
├── W0   019e6a4c30a3  DONE    — branch setup, risk controls, briefing kit
├── W1a  019e6a4c91cb  backlog — cad/scripts/build-runtime-bundle.sh (linux-x86_64)
├── W1b  019e6a4cf762  backlog — cad: go:embed + ExtractEmbedded + PythonPath
├── W1c  019e6a4d422a  backlog — cad: bridge.Worker env + cad-side regression test
├── W2   019e6a4d96fb  in_progress — Minerva RED functional test (this one needs laptop work)
├── W3   019e6a4e0455  backlog — cad.yml + v0.1.1 release + smoke evaluate + flip W2 GREEN
└── W4   019e6a4e37b9  backlog — HITL (single gate at end)
```

Every item has full description+spec text in the docket article. Use
`docket_get id=<short> project=minerva` to read.

---

## 2. WHAT'S COMMITTED + PUSHED

### Minerva (turnrocklabs/Minerva)

Branch: `dcr/cad-embedded-python-test` (off `development`, base `f653adf3`).

Commits on the branch:
- `f6426348` — docket: file DCR 019e6a4bcb0c cad-plugin embedded PBS python runtime
- (a second commit will be added below with the test file + this pickup before push)

### plugins (imrans-lab/minerva-plugins via remote `lab`)

Branch: `dcr/cad-embedded-python-linux` (off `main`, base `cf25d61`).

No commits yet on the branch — it was branched but no implementation work has begun in plugins
repo. The branch is pushed so you can pull it on the laptop and start W1a there.

---

## 3. CURRENT IN-PROGRESS WORK — W2 STATE

### Files on disk (committed below before handoff)

- `~/github/Minerva/src/test/test_marketplace_install_start_cad_evaluate.gd` (NEW, ~310 lines)
- `~/github/Minerva/src/test/test_marketplace_install_start_cad_evaluate.gd.uid` (Godot auto)
- `~/github/Minerva/scripts/run-functional-tests.sh` (added entry to PLUGIN_TESTS array)

### What's done in W2

- Test file written, parallels `test_marketplace_install_start_scansort.gd` (DRY check passed —
  same structure, only deltas: PLUGIN_ID, BINARY_NAME, ui/ copy, randomized port, AND the
  critical extra step 3 that calls `mcad_validate` via `MCPServerConnection.call_tool()` and
  asserts a non-error worker response. The scansort sibling stops at state=RUNNING; that gap is
  what masked HITL #2.
- Registered in `scripts/run-functional-tests.sh` PLUGIN_TESTS array.
- Two fixes applied while debugging on workstation:
  - **Port randomization** — was hardcoded 18767; killed test orphans landed on the port
    and blocked subsequent runs with `OSError: [Errno 98] Address already in use`. Fixed by
    `PORT = 30000 + (Time.get_ticks_msec() % 20000)`.
  - **Two-stage probe** — was a 5s HTTPRequest.request_completed loop (50 iters x 100ms).
    Replaced with: 15s OS-level TCP socket probe via `exec 3<>/dev/tcp/...` + one HTTPRequest
    verification once port is up. Reason: full singleton boot starves create_timer +
    HTTPRequest in cad's test context (more autoload activity than scansort sibling).

### What still needs doing on W2

1. **Confirm RED baseline.** Run on the laptop (fresh boot, before any long-lived Minerva
   session):
   ```bash
   cd ~/github/Minerva
   timeout 300 stdbuf -oL -eL godot --headless --path src \
       --script test/test_marketplace_install_start_cad_evaluate.gd 2>&1 \
       | tee /tmp/cad_w2_red.log
   ```
   Expected: test fails with one of these envelope errors at step 3 (mcad_validate):
   - `bridge.Worker.Start: exec: fork/exec /usr/bin/python3: no such file or directory`
   - Or any other worker-spawn error containing "fork/exec", "python3", or "no such file"
   - The test specifically prints `(RED baseline — worker python spawn failure; the bug
     DCR 019e6a4bcb0c fixes)` when this happens.
2. If the test PASSES against cad-v0.1.0 (extremely unexpected), the test is broken — likely
   the cad-v0.1.0 binary on `~/github/plugins/cad/cad-plugin` has been swapped for a newer
   build. Verify with `sha256sum ~/github/plugins/cad/cad-plugin` and cross-check the
   imrans-lab cad-v0.1.0 release.
3. Once RED is confirmed: do NOT change the test. Move to W1a. (The test will turn GREEN
   automatically after W1a/b/c land and W3 rebuilds the cad binary in
   `~/github/plugins/cad/cad-plugin` with the embedded python.)

### Why this was slow on the workstation

The workstation had a long-running Minerva session before the test was invoked, with nudge
+ cobrowser + codetools MCP servers alive and gdcef CEF helper processes contending for
engine main-loop frames during `--headless --script` boot. On a fresh laptop boot this should
take ~60-90s total (matching the scansort sibling's runtime). If the laptop also shows
multi-minute setup, kill any background godot/cefclient/mcp-server processes first.

---

## 4. RESUMING ON THE LAPTOP

### Cross-machine sanity checks (paths differ on the laptop)

The test uses `$HOME + "/github/plugins/cad"` for the cad source tree. Verify on the laptop:

```bash
echo "HOME=$HOME"
ls -la $HOME/github/plugins/cad/manifest.json $HOME/github/plugins/cad/cad-plugin $HOME/github/plugins/cad/ui
```

All three must exist. If they don't, clone:
- `git clone git@github.com:imrans-lab/minerva-plugins.git $HOME/github/plugins`
- The cad-plugin binary needs to be built: `cd $HOME/github/plugins/cad && go build .`

### Pull the branches on the laptop

```bash
# Minerva
cd $HOME/github/Minerva   # or wherever
git fetch origin
git checkout dcr/cad-embedded-python-test

# plugins
cd $HOME/github/plugins
git fetch lab            # if you set up imrans-lab as `lab` remote here too
git checkout dcr/cad-embedded-python-linux
```

If laptop's plugins remote layout is different (e.g. `origin` points at imrans-lab on laptop
but `lab` on workstation), use whatever name maps to the imrans-lab/minerva-plugins URL.

### Resume sequence (6 - 1 = 5 iters remaining)

1. **W2 finalize (iter 2)** — run the test on laptop, confirm RED, commit a `pickup` note
   recording the verbatim RED log; transition W2 to `blocked_by` W1a (or leave in_progress).
2. **W1a (iter 3)** — implement `cad/scripts/build-runtime-bundle.sh`. Spec in docket item
   `019e6a4c91cb`. Read with `docket_get id=019e6a4c91cb project=minerva`.
3. **W1b (iter 4)** — go:embed + ExtractEmbedded + PythonPath. Spec in `019e6a4cf762`.
4. **W1c (iter 5)** — bridge.Worker env + cad regression test. Spec in `019e6a4d422a`.
5. **W3 (iter 6)** — cad.yml integrate + release v0.1.1 + Minerva smoke evaluate. Spec in
   `019e6a4e0455`. **PAUSE for user HITL on direct main push to imrans-lab/minerva-plugins
   per pickup §6.**
6. **W4** — single HITL gate. Spec in `019e6a4e37b9`.

### Pre-flight on laptop (same as W0 did on workstation)

```bash
cd $HOME/github/Minerva && git status -uno && git rev-parse --abbrev-ref HEAD
cd $HOME/github/plugins && git status -uno && git rev-parse --abbrev-ref HEAD
```

Assert both branches checked out clean, then start.

---

## 5. NUDGE HINTS WORTH READING (saved this session)

```
nudge_get_hint component=minerva-plugin-platform key=python-runtime-not-a-host-capability
nudge_get_hint component=cad-plugin                 key=embed-go-is-not-embedding
nudge_get_hint component=minerva-testing            key=sceneTree-script-blocks-on-full-autoload
```

Plus all 8 from the prior autonomous loop (pickup §4 of `f653adf3`).

---

## 6. HARD RULES (UNCHANGED)

- Per-file `git add` only. No `-A`/`.`.
- No `--no-verify`. No `vendor/` touches.
- No force-push, no `git reset --hard`.
- Co-author trailer: `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.
- Plugins repo `imrans-lab/minerva-plugins`: user authorization for the cad-v0.1.1 main push
  in W3 is **NOT carried over from this session** — re-ask before that push.
- Minerva `development` push: autonomous-loop authorization applies; the new branch
  `dcr/cad-embedded-python-test` was created so we don't need to push to development until
  W3 merges back.

---

## 7. WHAT THE TEST FILE ACTUALLY LOOKS LIKE (quick reference)

`src/test/test_marketplace_install_start_cad_evaluate.gd` — key shape:

```
extends SceneTree

const PLUGIN_ID := "cad"
const PLUGIN_SRC_REL := "/github/plugins/cad"     # joined with $HOME
const BINARY_NAME := "cad-plugin"
const VALIDATE_SOURCE := "result = sphere(5)"
var PORT: int = 30000 + (Time.get_ticks_msec() % 20000)

func _run():
    # step 1: install_from_url   (works against cad-v0.1.0)
    # step 2: start_plugin       (works against cad-v0.1.0)
    # step 3: mcad_validate      (FAILS against cad-v0.1.0 — this is the RED gate)
    # step 4: stop_plugin
```

The step-3 failure path explicitly looks for `fork/exec` / `python3` / `no such file or
directory` in the error text and prints `(RED baseline ...)` so the failure is unambiguously
the DCR-019e6a4bcb0c bug, not a false-positive.
