# Pickup

STATE: `PLUGIN_SUBSTRATE_FIX — PRE-COMPACTION READY`

Last updated 2026-05-20. Pre-compaction handoff for the plugin-substrate
connection-layer fix (the CAD render-regression remediation). **Design is
finalized, the docket is set up, all test fixtures are built and reviewed.**
The next phase is the autonomous implementation loop. Read this whole file
before acting.

---

## 1. What this is

The CAD plugin renders no geometry — its canonical T-Beam test produces nothing.
RCA-traced to Minerva's MCP-over-stdio connection layer, NOT the CAD plugin
(CAD's own code is unchanged, last commit `8a25497`).

This is **not** a narrow CAD patch — it's a connection-layer rewrite that also
unblocks future provider-plugin and PCB-plugin work. Tracked as **remediation on
RCA `019e46b5`** — not a DCR (regression remediation rides the RCA workflow:
`root_caused → remediating → verified → closed`).

## 2. Root cause (source-proven)

Commit `fcdeda02` added an unconditional 30s **serialization gate** at
`MCPServerConnection.gd:710-716`; `_stdio_request` then polls stdout. Two
`_stdio_request` coroutines polling at once each consume the other's response —
the gate serializes to hide that race. The slow `cad.evaluate` queues behind the
gate and blows the CAD panel's fixed 30s reply budget → no mesh. Contributing:
`f2289f04`'s async drainer discards bare id-responses (`:981-982`). Full RCA:
docket `rca` `019e46b5`.

## 3. The fix design — W1 (`019e470b1397`)

Replace the gate + poll with **a single always-live stdout reader + a
pending-requests map keyed by JSON-RPC id**:

- `_pending: Dictionary` — `request_id → _PendingRequest` (a RefCounted with one
  `signal resolved(result: Dictionary)`).
- `_stdio_request(request, timeout_sec := 120.0)`: register a `_PendingRequest`,
  write the request, if `timeout_sec > 0` start a `SceneTreeTimer` →
  `_resolve_pending(id, timeout-error)`, then `await pending.resolved`. No gate,
  no poll. `timeout_sec = 0` = unbounded / cancel-only.
- The `output_ready` handler (`_on_async_output_ready`) becomes THE reader — drop
  the `_in_stdio_request` gate so it runs always. Per line: `method` present →
  existing routing (capability/event/state/notify, unchanged); `id` + no
  `method` → `_resolve_pending(id, msg)`; else log.
- `_resolve_pending(id, result)`: idempotent first-wins (`if not
  _pending.has(id): return`; erase; emit). Response / timeout / future-cancel
  all funnel through it.
- Fail-all outstanding on subprocess exit/disconnect with a connection-lost error.
- Delete `_in_stdio_request` (grep ALL refs), the poll loop, `_drain_pending_async`.

Rubric improvements folded in (keep change size S):
- **A reliability** — a ~250ms backstop drain timer per connection; defends
  against a missed `output_ready` signal stranding a response.
- **B debuggability** — thread the tool name into `_stdio_request` so
  timeout/error logs name the tool; add `_pending` introspection.
- **C discoverable** — rename `_on_async_output_ready` (it is now THE reader);
  delete the stale gate-rationale (701-709) + `_connect_stdio` async-drain
  (628-634) comments.
- **D user-visible** — connection-layer errors are structured with a
  human-readable `message`: `{error:{code, message}}`.

**DO NOT** revert `fcdeda02` (it fixed a real concurrent-read race — the
dispatcher subsumes its intent). **DO NOT** build streaming. Full spec is also
in W1's docket description.

## 4. Docket — 8 work-items under RCA `019e46b5`

| ID | Item | Status | Blocked by |
|----|------|--------|-----------|
| `019e470b20b9` | W2 — Test data fixtures | **done** | — |
| `019e470b2a3d` | W3 — Layer-A fixture plugin | **done** | — |
| `019e470b39f3` | W4 — Substrate functional tests F1/F2/F4/F5/F6 (fail-first) | backlog | W3 ✓ |
| `019e470b444f` | W5 — Per-plugin tests (CAD F3, scansort, presentation) | backlog | W2 ✓ |
| `019e470b1397` | W1 — Substrate fix (single dispatcher + per-id routing) | backlog | W4 |
| `019e470b4e33` | W6 — CI test job + F7 exported-build overlay | backlog | W1 |
| `019e471a5c62` | W8 — CAD panel surfaces runtime errors to the user | backlog | W1 |
| `019e470b54c8` | W7 — HITL verification with real data | backlog | W1, W8 |

W2 and W3 are done, so **W4 and W5 are now unblocked** — they are the entry points.

## 5. Test plan

8 functional tests, ALL on the REAL `MCPServerConnection` (not `StubMCPConnection`
— mock connections are why the regression shipped invisibly). Tests live
Minerva-side in `src/test/`.

- **F1** — two concurrent `call_tool`s in flight; assert each caller gets its own id's result.
- **F2** — one `sleep(~15000)` + 5 instant `echo`s concurrent; echoes <1s, sleep returns correct.
- **F4** — response routed to its waiter by id amid interleaved traffic; a bare/unmatched response doesn't wedge a waiter.
- **F5** — a caller 2s budget errors at ~2s; a no-budget call waits.
- **F6** — cancel an in-flight call; the connection still serves the next call.
- **F3 (CAD)** — spawn real cad-plugin → open T-Beam `.mcad` → `cad.evaluate` → assert mesh triangle count > 0, finite bbox.
- **scansort** — real model-chat/qwen, NO stubs: fixtures → clear cache → import rule set → fresh vault → `process()` → assert placement.
- **presentation** — open `test_deck.mdeck` → assert 3 slides / 7 tiles.

F1/F2/F4/F5/F6 = W4 (drive the W3 fixture plugin). F3 + scansort + presentation = W5.
**Fail-first discipline:** W4's tests and F3 must be confirmed FAILING against
current code *before* W1 lands, then PASS after.

## 6. Fixtures — built, reviewed, committed (W2 + W3)

- `src/test/fixtures/stdio_timing_probe/` — Layer-A fixture plugin (`manifest.json`
  + `stdio_timing_probe.py`); asyncio, handles concurrent in-flight requests;
  tools `echo` / `sleep` / `never_reply` / `emit_stray`. Cold-Opus-reviewed.
- `src/test/fixtures/scansort-staging/` — 6 synthetic PII-free PDFs +
  `gen_fixtures.py` + `rules.json` (v2 `RulesFile`) + `expected_placement.json`
  + `README.md`. All visually verified vision-classifiable; all files verified
  PII/secret-free.
- `src/test/fixtures/presentation/test_deck.mdeck` (+ `README.md`) — small
  schema-valid deck, 3 slides / 7 tiles.

## 7. DONE vs NOT DONE

**DONE (pre-compaction):** RCA + 8 work-items + dependency graph; the fix design
(captured in W1); W2 + W3 fixtures built and reviewed; this pickup + memory +
nudge; a WIP commit.

**NOT DONE — the autonomous loop's job:** W4, W5, W1, W6, W8. (W7 HITL = the user.)

## 8. Autonomous loop (post-compaction)

The loop implements W4 → W1 → W6/W8, guarded by the test suite. Order
(dependency-driven): write W4 + W5 tests **fail-first** (confirm they FAIL on
current code) → implement W1 → suite goes green → W8 (CAD panel errors) + W6 (CI).
- **Guardrail tiering:** F1–F6 (fixture plugin, fast, hermetic) run every
  iteration; per-plugin tests (CAD needs build123d; scansort needs model-chat
  reachable) run at checkpoints, not every iteration.
- **Done oracle:** F1–F6 + per-plugin tests green. W7 (HITL, real data) = user.
- Driver: `/work-cycle` against RCA `019e46b5`'s work-items.
- A loop that writes its own tests can pass by writing weak ones — W4/W5 specs
  are tightly defined in their docket descriptions; implement the spec, and keep
  the fail-first checkpoint.

## 9. Hard rules (carry-forward)

- Per-file / explicit-path `git add` only. No `git add -A` / `git add .`.
- No `--no-verify`. No `--no-gpg-sign`.
- No `vendor/` touches. No committing `src/addons/sightline_probe/` or
  `src/project.godot` while that addon is enabled.
- No `git reset --hard`, no force-push, no destructive ops without explicit auth.
- pkill target is `godot`, not `Minerva`.
- Source is read-only — scansort copies to destinations, never alters source.
- PII/HBI: never commit **real** documents / `.ssort` vaults / audit logs /
  `.scansort-state.json`. NOTE: the **synthetic** PDFs in
  `src/test/fixtures/scansort-staging/` ARE meant to be committed — they are
  verified PII-free; the rule targets real documents.
- Rubric (7 axes): reliability → durability → performance → debuggability →
  cost → discoverable → user-visible.
- RCA requests → 5-why chain with file:line source proof.

## 10. Cold-start procedure

1. Read this file + the W1 docket item (`019e470b1397`) for the full fix spec.
2. `git -C ~/github/Minerva log --oneline -3` — confirm the WIP commit at tip.
3. `git -C ~/github/Minerva status` — the test fixtures should be committed.
4. Next work = W4 / W5 (unblocked, W2+W3 done). Fail-first, then W1.
