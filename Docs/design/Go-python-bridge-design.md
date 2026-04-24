# Go ↔ Python Subprocess Bridge — CAD Plugin Design

**Status:** Design (pre-implementation)
**Date:** 2026-04-24
**Scope:** IPC bridge between the CAD plugin's Go MCP server and its long-lived Python Build123d worker subprocess.
**Upstream:** `Plugin-platform-thought.md` §4.2, `Plugin-platform-policy.md`.
**Non-goals:** Reopening the subprocess-vs-in-process decision; evaluating cgo / goempy for v1; pure-Go/Rust B-Rep alternatives.

---

## 1. Overview

The CAD plugin is a Go binary hosting an MCP server. It owns `.mcad` I/O, sidecar coordination, render/export orchestration, and the Godot scene panel. Geometry work (parse → translate → OCCT / Build123d → mesh / STEP / STL) is delegated to a long-lived Python subprocess speaking JSON over stdin/stdout. The worker is the existing `mcad/` package from the ccsandbox Flask backend, re-hosted behind a stdio dispatcher that replaces `app.py`. Stdin/stdout carries control messages; stderr carries logs. Mesh bytes travel in-band as length-delimited frames. OCCT C++ exceptions and Python crashes are contained at the subprocess boundary; the Go parent observes them as process exit + stderr and restarts transparently.

---

## 2. Process Model

**Topology:** one Go parent ↔ exactly one Python worker. Lifetime scoped to the plugin, not individual requests. Launched lazily on the first geometry-touching MCP call; a plugin start with only an `init` from Minerva does not spin up Python. Shut down on plugin stop/reload; no auto-idle-shutdown in v1.

**No worker pool.** OCCT is thread-hostile and Build123d's shape cache is per-interpreter; the typical pattern is bursty-single (edit → render → wait); packaging one Python runtime is simpler than N; the Go server serializes inbound requests cleanly enough for single-user UI concurrency.

**Restart on crash:**
- Parent watches the process handle. Abnormal exit (non-zero, signal, stdio EOF without `shutdown`) → fail the in-flight request, auto-relaunch on next request.
- Circuit breaker: 3 crashes within 60 s stops auto-relaunch until plugin reload. Prevents a wedged OCCT install from pegging CPU.
- Go logs every crash (exit code, stderr tail, last method) for post-mortems.

**Concurrency:** Go serializes requests via a single outbound channel and correlates responses by `id`. Each MCP handler goroutine `await`s its correlation ID.

---

## 3. Message Framing

**Decision: length-prefixed JSON (`Content-Length` header, LSP/JSON-RPC-style framing).**

Versus newline-delimited JSON (NDJSON): NDJSON is simpler, but one stray `print()` from a dep (Build123d, OCC, NumPy all emit warnings) desynchronizes the stream permanently. The CAD worker is an unusually high-payload case for stdio-MCP — a tessellated mesh is single-digit MB. Length-prefixed framing treats the body as opaque bytes, detects header-mismatch immediately (allowing a clean worker restart), and mirrors MCP's own stdio and LSP framing.

**Frame format** (ASCII headers, UTF-8 body):

```
Content-Length: 12345\r\n
Content-Type: application/json; charset=utf-8\r\n
\r\n
{ ...json... }
```

Only `Content-Length` is mandatory; `Content-Type` is reserved for future binary framing (§9). Worker MUST NOT write any non-header bytes to stdout; all logs go to stderr. On header parse failure, Go drains stdout, logs the offending prefix (≤ 1 KB), and kills + restarts.

---

## 4. Request / Response Protocol

Shape is JSON-RPC 2.0-ish but minimal and not wire-compatible with JSON-RPC libraries — we don't need batching, named-vs-positional, or server-initiated calls.

**Request (Go → Python):**
```json
{
  "id": "req_00017",
  "method": "evaluate",
  "params": { "source": "...", "tolerance": 0.1 },
  "deadline_ms": 30000
}
```

**Response (Python → Go):**
```json
{
  "id": "req_00017",
  "ok": true,
  "result": { ... }
}
```
or
```json
{
  "id": "req_00017",
  "ok": false,
  "error": {
    "kind": "parse" | "translate" | "occt" | "python" | "timeout" | "cancelled" | "internal",
    "message": "...",
    "details": { "line": 12, "col": 4 },
    "traceback": "...(optional, stderr-captured)"
  }
}
```

**Notifications (Python → Go, no id):**
```json
{ "method": "worker.ready", "params": { "version": "1.0.0", "build123d": "0.9.1", "occt": "7.8.1" } }
{ "method": "log", "params": { "level": "warn", "source": "occt", "message": "..." } }
{ "method": "progress", "params": { "id": "req_00017", "phase": "tessellate", "fraction": 0.4 } }
```

**Correlation IDs:** Go issues monotonic `req_NNNNN`; Python echoes unchanged. Responses with unknown/stale ids are logged and dropped.

**Timeouts:** each request carries `deadline_ms`. The worker cooperatively checks the deadline between translator phases. The Go parent enforces an outer deadline at `deadline_ms + 500 ms`; on breach, kill + restart.

**Cancellation:** v1 is deadline-only; no mid-flight cancel. OCCT isn't safely interruptible — the only reliable kill is SIGTERM → SIGKILL, which means relaunching anyway. If the MCP client cancels, Go marks the request cancelled upstream but lets the worker finish (result discarded) unless deadline fires. A `cancel` notification can be added later once a safe interruption point exists.

---

## 5. Worker Lifecycle

**Cold start.** Go resolves the bundled interpreter (§6) and runs `python -m mcad_worker`. Environment is scrubbed (`PYTHONHOME` set, `PYTHONPATH` cleared, `PYTHONDONTWRITEBYTECODE=1`, `PYTHONUNBUFFERED=1`). Stdin/stdout are anonymous pipes; stderr goes to a log-pump goroutine. Spawned in a new process group for clean signal delivery (Unix `Setpgid`, Windows `CREATE_NEW_PROCESS_GROUP`).

**Ready signal.** Python emits `worker.ready` after importing `mcad`, importing `build123d`, and running a 1 mm-cube no-op tessellation to confirm OCCT init. Go holds requests until then. Budget: 5 s typical, 15 s hard — timeout treated as a crash.

**Graceful shutdown.** Go sends `shutdown`; worker flushes and exits 0 within 2 s. If not, SIGTERM; after 3 s, SIGKILL.

**Crash-and-restart.** See §2. In-flight request fails with `kind: "occt"` or `kind: "python"` carrying the stderr tail; next request gets a fresh worker.

**State warming.** Minimal: the worker keeps a module-level `last_program` cache (size 1) keyed by `hash(source)` so `mcad_render` right after `mcad_validate` skips parse+translate. Build123d/OCCT internal caches live for the worker's lifetime. No cross-restart persistence.

---

## 6. Python Packaging

**Decision: `python-build-standalone` (PBS) redistributable, extracted to the plugin's `data_directory` on first run.**

### Options evaluated

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **System Python** | Zero distribution size | User must install; versions drift; conflicts with conda/pyenv; fails the "no install burden" policy | Rejected per policy |
| **`goempy` (cgo-embed CPython + `go:embed` wheels)** | Single binary; no extraction | cgo build toolchain required on every target; defeats crash isolation (OCCT exceptions land in-proc); goempy is a young project | Rejected — contradicts subprocess decision |
| **PBS + `go:embed` into Go binary, extract on first run** | One artifact; no installer; deterministic version | Go binary grows ~40-80 MB compressed per platform; first-run extraction latency | **Chosen** |
| **PBS shipped alongside plugin zip (not embedded)** | Smaller Go binary | Plugin install becomes multi-file; breaks Minerva's single-binary plugin model | Secondary fallback if binary size becomes painful |
| **`pyoxidizer` / `py2app` / `PyInstaller`** | Single-file options exist | Each has platform quirks, uneven maintenance; PBS is the cleanest substrate the others sit on top of | Not worth the layer |

### Shape of the chosen option

**Build-time:** `go:embed` a tar.zst per target triple containing: PBS CPython 3.12.x (pinned minor; relocatable, known-good OpenSSL/zlib); a pre-built `site-packages/` with Build123d + `cadquery-ocp` OCCT wheel + the `mcad/` source; a SHA-256 manifest.

**Runtime directory (user:// primary, res:// fallback).** On first plugin start the Go binary checks its data_directory — which is `<user_data>/plugins/<plugin_id>/` (Minerva tells it this path at spawn). Extraction target:

```
<data_directory>/runtime/<plugin_version>/
  ├── bin/python3 (or python.exe)
  ├── lib/...
  ├── site-packages/...
  └── manifest.sha256
```

Lookup + extract flow:

1. **Primary — user-local cache.** Check `<data_directory>/runtime/<plugin_version>/`. If present and `manifest.sha256` matches → reuse.
2. **Fallback — Minerva-bundled pre-extract.** Some Minerva distributions may ship CAD as a pre-bundled plugin with the runtime already unpacked in the install tree (mapped via `res://plugins/<plugin_id>/runtime/`). If `runtime_prebundled_path` is passed in the plugin's spawn env and valid, the Go binary copies that tree into `<data_directory>/runtime/<plugin_version>/` (file copy, no tarball extract — faster first-run). This path matters for shipping Minerva-with-CAD as a single install artifact. Skipped silently if absent.
3. **Last resort — embedded tarball.** Extract the `go:embed`'d tarball atomically (write-temp-then-rename) to `<data_directory>/runtime/<plugin_version>/`.

Once any of those succeeds, invoke `<data_directory>/runtime/<plugin_version>/bin/python3 -m mcad_worker`.

**Versioning for rollback.** `<plugin_version>` in the path means upgrades create a new directory; the previous version remains one generation for rollback. GC policy: after a successful start on the new version, the next start cleans up runtime directories older than N-1 (default keep 2).

### Isolation and collisions

Each Python-using plugin ships its own PBS runtime + its own `site-packages`. No cross-plugin Python imports, no shared Build123d version, no runtime-level coupling. Consequences:

- **Modernization is per-plugin.** A plugin updates its Python or OCCT versions by re-releasing with a new embedded tarball. Other plugins unaffected.
- **Disk cost: ~100 MB per Python-using plugin.** Acceptable for v1.
- **Shared-pool opt-in deferred.** A future `runtime.shared_pool: "cpython-3.12"` manifest field could let multiple plugins reuse `<user_data>/shared/runtimes/cpython-3.12.x/`. Keyed by major.minor. Plugins needing non-matching patches fall back to per-plugin. Not in v1 — premature until a second Python-using plugin ships.

### Platform variants

| Target | Interpreter source | Launcher |
|---|---|---|
| linux-x64 | PBS `cpython-3.12.x-x86_64-unknown-linux-gnu-install_only` | `bin/python3` |
| linux-arm64 | PBS `aarch64-unknown-linux-gnu-install_only` | `bin/python3` |
| macOS-universal | PBS `aarch64-apple-darwin-install_only` + `x86_64-apple-darwin-install_only` merged with `lipo`, or shipped as two separate tarballs selected at runtime by `runtime.GOARCH` | `bin/python3` |
| Windows-x64 | PBS `x86_64-pc-windows-msvc-install_only` | `python.exe` |

PBS needs no separate C runtime on modern Windows (UCRT). On Linux the `install_only` flavors static-link OpenSSL/libffi, so glibc is the only host requirement.

**Not in scope for v1:** signed tarballs (Go binary is already the trust root); shared-runtime across plugins (future optimization, saves ~60 MB if a second Python-using plugin ships).

---

## 7. Error Surfaces

Errors are classified by `kind` on the wire so the Go side can pick the right UX and retry policy:

| `kind` | Cause | Go treatment |
|---|---|---|
| `parse` | `ParseError` from mcad lexer/parser | Return to MCP with `{line, col}` — user-visible squiggle fodder |
| `translate` | `TranslatorError` | Return to MCP; no retry |
| `occt` | OCCT raised a C++ exception caught by Build123d / pythonocc | Return + mark worker *suspect*; if the same request repeats, consider the worker contaminated and recycle |
| `python` | Unhandled Python exception outside translator/OCCT | Return + recycle worker (traceback on stderr) |
| `timeout` | Worker exceeded `deadline_ms` | Kill worker, relaunch, return `timeout` |
| `cancelled` | Deadline from caller | Don't kill worker (may finish); just drop the response |
| `internal` | Frame parse error, correlation mismatch, worker wrote non-header bytes to stdout | Log full context, recycle worker |
| `crashed` | Worker process exited mid-request | Last 4 KB of stderr attached; circuit breaker check (§2) |

**OCCT C++ specifically.** pythonocc-core translates most OCCT exceptions into Python `RuntimeError` subclasses, but some (stack corruption, SIGSEGV in BRepFill) bypass the handler. We can't distinguish these from Python bugs at the bridge — both become `crashed`. Recycling either way is fine.

**Hang/timeout.** Cooperative cancellation checks the deadline between translator phases. OCCT calls aren't pre-emptable; if the deadline fires inside one, Go's outer deadline kills the process ~500 ms later. That's the only way to safely reclaim wedged OCCT state.

Every error path either returns a structured error to the MCP caller or logs enough context (stderr tail, method, pid, uptime) to reproduce. No silent drops.

---

## 8. Bridge-Crossing Operations

Only these methods exist on the worker dispatcher in v1. Every MCP tool in the Go layer composes from this set.

### 8.1 `evaluate`

**Params:** `{ source: str, tolerance?: float (default 0.1), angular_tolerance?: float (default 0.1) }`

**Result:** `{ shape_name: str, mesh: { vertices: [[x,y,z], ...], faces: [[i,j,k], ...] }, edges: [ {id, kind, coords, ...} ] }`

**Errors:** `parse`, `translate`, `occt`. Direct port of `evaluate_source` in `mcad/evaluator.py`. Backs `mcad_render` (Go rasterizes mesh → PNG) and `mcad_list_edges`.

### 8.2 `export`

**Params:** `{ source: str, format: "stl" | "step" | "3mf", path: str }`

**Result:** `{ path: str }` (final path after extension inference)

**Errors:** `parse`, `translate`, `occt`, `python` (I/O failure). Direct port of `export_source`. Go validates `format` against the v1-locked set (STL binary + STEP per policy) before crossing.

### 8.3 `validate`

**Params:** `{ source: str }`

**Result:** `{ ok: bool, errors: [{line, col, message}], warnings: [...] }`

**Errors:** only `internal` / `python`. Parse/translate errors are *data*, populating the result's `errors` list. New method (Flask didn't have it); skips tessellation entirely. Critical for the LLM inner loop (§4.5 of the thought paper).

### 8.4 `list_edges`

**Params:** `{ source: str }`

**Result:** `[ {id, kind, coords, ...} ]`

**Errors:** same as `evaluate`. Conceptually redundant with `evaluate` (edges come free), but a separate method lets Go skip the mesh serialization when only edge IDs are wanted. Uses the `last_program` cache to avoid re-tessellating.

### 8.5 `deviation` (backs `mcad_deviation`)

**Params:** `{ source: str, reference: { kind: "stl" | "ply" | "pcd", path: str, transform?: mat4, sample_budget?: int } }`

**Result:** `{ max_mm, rms_mm, p95_mm, per_region: [{region_id, max_mm, rms_mm, bbox}] }`

**Errors:** all of the above plus `python` (reference I/O). New method not in the Flask backend. Point-to-surface distance from reference samples to the evaluated mesh. The worker reads the reference file by path — only the path crosses the bridge. Path resolution is Go's job; the worker refuses anything outside the `allowed_roots` capability list passed in `init`.

### 8.6 Lifecycle methods

- `init` (Go → Python, first call before any work): `{ plugin_version, allowed_roots, features }` → `{ worker_version, occt_version }`
- `shutdown` (Go → Python): graceful exit.

---

## 9. Binary Payload Handling

A typical interactively-edited part is 50 K–500 K vertices + 100 K–1 M triangles — 5–50 MB of JSON. Not a deal-breaker in a single stdio frame, but worth engineering around.

**v1 baseline:** single-frame JSON with numeric arrays. Simple, debuggable, works. Measure before optimizing.

**Escape hatch in the protocol but unused in v1:** `Content-Type: application/x-mcad-binary` — 4-byte LE JSON-envelope length, JSON envelope `{id, ok, result_meta: {format, counts}}`, then raw `float32[]` vertices + `uint32[]` faces. Worker negotiates via `init` `features: ["binary_mesh"]`; over a threshold, emits binary.

**Streaming** is not on the v1 menu. Tessellation isn't incremental in Build123d; there's nothing to stream mid-compute. `progress` notifications surface phase fractions for UI but the mesh itself arrives in one frame.

**Export payloads don't cross the bridge.** Worker writes STL/STEP to the Go-specified path; only the path comes back.

---

## 10. Platform Differences

**Process spawning.**
- Linux/macOS: `SysProcAttr{Setpgid: true}` so `kill(-pgid, SIGTERM)` reaps grandchildren (Build123d can shell out to `gmsh` for some ops).
- Windows: `CreateProcess` with `CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW`. No portable SIGTERM — graceful is the `shutdown` JSON request; fallback is `TerminateProcess`.

**Path handling.** Go normalizes every bridge path (`filepath.Clean`, forward slashes). Worker treats paths as opaque strings, converting with `pathlib.Path` only at I/O time. Windows long-path `\\?\` prefixes travel unchanged. `allowed_roots` compared after symlink resolution both sides.

**Signals.**
- Unix: worker SIGTERM handler sets a shutdown flag, flushes, exits. SIGINT ignored (that's Minerva's concern).
- Windows: `shutdown` JSON is the only graceful path.
- SIGPIPE on stdout → worker exits silently (parent is gone anyway).

**Buffering.** `PYTHONUNBUFFERED=1` unconditionally; dispatcher also flushes stdout after each frame. Go uses `bufio.Reader` with ≥ 1 MB buffer to avoid mesh-frame fragmentation.

**Case sensitivity.** Linux case-sensitive, macOS/Windows case-insensitive defaults. Paths round-trip as-given; the worker does no case normalization.

---

## 11. Testing Strategy

**Go side, worker mocked.** A pure-Go double in `plugin/cad/internal/workerfake` implements framing + canned responses keyed by `(method, params-hash)`. All Go MCP tool handlers unit-test against it; no Python dep in CI. Covers: happy-path round-trips for all 5 methods; framing edge cases (oversize body, missing `Content-Length`, garbage after separator); correlation (out-of-order, duplicate, unknown IDs); timeout; crash + restart + circuit breaker; shutdown sequence (flush → SIGTERM → SIGKILL).

**Python side, Go parent mocked.** Tests import `mcad_worker` directly and call `handle_request(dict) -> dict`, bypassing stdio. Validates dispatch, error classification, `last_program` cache. Re-runs the inherited `mcad/tests/` against the new entry point to catch port regressions.

**Integration.** A tagged suite launches the real worker against a dev-mode PBS extract (fixture cache). Validates: cold-start budget; `worker.ready` ordering; real `evaluate` round-trip for the T-beam DSL; crash-triggers-restart-next-request-succeeds. Runs on the platform matrix, not fast CI.

**Property/fuzz.** Light dose on framing only: `testing/quick` generator over header values, split boundaries, body sizes; framer never panics, never loses sync past one bad frame.

**Not in v1 tests:** mesh-size perf regression suite (file when real parts exist); OCCT crash injection (revisit when a known-crashing part turns up).

---

## 12. Questions — All Resolved 2026-04-24

*Propagated decisions: Q1 binary-mesh threshold deferred until measured; Q2 runtime extraction layout = Option A, per-plugin under `<data_directory>/runtime/<plugin_version>/` (simplest; C content-addressable deferred as future optimization); Q3 Anaconda preference = dev-only (plugins ship their own PBS envs; Anaconda stays as the developer-convenience reality without leaking into distribution); Q4 idle shutdown acceptable — hosted dispatch obviates via `019da41823517154afe359ec70d513bd`; Q5 `allowed_roots = [workspace_root, data_directory]` confirmed; Q6 progress notifications wired in v1 with scene-panel routing + CAD panel UI tasks filed; Q7 no explicit sign-off process — file DCRs to change direction.*


1. **Binary mesh threshold.** §9 escape hatch defaults to "never in v1, measure first." Acceptable, or set a threshold (e.g. 100 K vertices) from day one?
-- never in v1, measure first

2. **Runtime directory layout.** `<data_directory>/runtime/cad-<plugin_version>/` (simple, trivial rollback, re-extracts on every upgrade) vs `<data_directory>/runtime/python-3.12.x/` (shared across plugin versions, smaller upgrade hit). Recommend the first for v1; revisit with a second Python-using plugin.
-- Plugins will entirely move to a new repo, with a per-plugin directory structure. Plugins will probably be fully public repos, using a custom license (based on the Minerva license.)

3. **Python version pin.** 3.12.x proposed. If Minerva tooling is standardizing on a different minor, say so.
-- Anaconda is used in dev. I'd love to standardize on some variant of this if possible. We should have 3.12.x as a fallback when we can't get anaconda or equivalant.

4. **Worker idle shutdown.** Proposal: none in v1. A long session with an open `.mcad` tab holds ~200 MB resident. Acceptable?
-- Acceptable-ish. We have another DCR to allow back-ends to move to other servers (aka REST/Minerva Core). Most deployments will likely use docker containers deployed on a back-end (either owned by user or by Turnrock)

5. **`allowed_roots` default.** Proposal: `[<workspace_root>, <data_directory>]`. Anything else escalates. Confirm.
-- confirm

6. **Progress notifications to UI.** Protocol emits them; Minerva's MCP surface doesn't route them to panels today. Wire now or park?
-- wire now

7. **Escalate now, or defer?** No item individually hits `Plugin-platform-escalation.md` thresholds, but Q2 + Q5 are non-reversible-ish schema choices — flagging in case explicit sign-off is wanted before implementation starts.
-- No need for explicit sign-off -- we can always file a DCR and change.