# Pickup

LATEST **2026-07-27 PM** — **PCB E-campaign: D0-expose SHIPPED (`6307238`, CI green). 25 rounds done, D1 next. Docket is UP; the canonical anchor is the docket hint, not this file.**

**Read `docket_hint_get(project="minerva", component="pcb-e-campaign", key="state")` first** — it is the resume anchor and it is current. This file is the human-readable echo.

- **D0-expose was INSERTED before D1 by owner ruling.** Pre-flight on what was billed as a pure-prose round found the tool surface D1 must describe was itself incomplete: the pcb plugin's 11 worker-backed tools were named `pcb_*`, declared in no manifest, and surfaced by Minerva's start-time discovery as double-prefixed `minerva_pcb_pcb_drc`. All 11 are now `minerva_pcb_*` and manifest-declared with the Go specs' schemas and descriptions. Item `019fa486b408`, done.
- **D1 `019f3e045dac` is next and its own `tool_deps` are wrong, not just its prose.** Six of the seven names it lists now exist; `minerva_pcb_ping` does not — the real tool is bare `ping`, deliberately left unrenamed. Read comments 831 and 836 before briefing.
- **R7 added to the terminal HITL register** (now 6 checks): after REINSTALL + `/mcp` reconnect, `minerva_plugin_inspect("pcb")` should list the 11 and one should return a real result live. Owner chose to leave it deferred; the automated proxy is the new gd registration test plus the stdio smoke.
- **The A/B result is filed** as hint `019fa47ec6ff` (VOID by its own canary; the template does the work; ~730k tokens — a 15-run A/B is not cheap).
- **Two premise corrections this session, both mine, both caught by gates before they reached code.** The overstatement pattern is written up in the anchor and in hint `019fa485d55a`.
- **New durable hint worth reading before any mutation work:** `019fa4c853c1` — you CANNOT mutation-test the pcb gd suite from a copied or symlinked tree; Godot canonicalizes `res://` through the symlink and reads the real checkout.
- **Filed not fixed, new:** `019fa4c88f33` (`withDefaultLibDir` injection unpinned; its body carries a live hazard — a swapped library handler binding makes `go test` perform a real network fetch).

The two `minerva.dct.*-BACKUP-2026-07-27` files are still untracked in `Docs/`. Docket has loaded the merged log cleanly all session, so they can be deleted whenever you want — left in place because deleting them is your call.

---

EARLIER **2026-07-27 AM** — **PCB E-campaign: C4b SHIPPED. 24 rounds done. Two skills authored. DOCKET WAS DOWN when this was written.**

## `Docs/minerva.dct` — diverged and MERGED (no action needed)

Two machines wrote to the docket log. It is **NDJSON, not SQLite**, so a record-level union was possible and was done; Docket does its own cleanup on load.

- Upstream (`d264bd10`, `8cc7ace5`) carried a CEF first-party-browser discussion from another machine.
- This machine carried the 2026-07-27 session: C4a and C4b, their premise corrections and close-outs, and the items filed against both.

**Merged result: 1673 items, 833 comments, 331 links, 5574 events, exactly one `meta` line.** Verified no item is lost from either side (upstream-only kept: 1; this-machine-only kept: 156). 179 records existed on both sides with different content and were resolved by later `updated_at`.

Both pre-merge files are preserved untracked in `Docs/` — `minerva.dct.UPSTREAM-BACKUP-2026-07-27` and `minerva.dct.SESSION-BACKUP-2026-07-27` — delete them once Docket has loaded the merged log cleanly.

**Still not in Docket:** the A/B result below was never filed (the connection dropped mid-write). File it as a durable hint under `work-cycle`.

## Where things are

**minerva-plugins `main` @ `4da474a`, pushed, clean, CI green.** Nothing in flight.
- `905ce82` C4b — net classes authorable in board YAML (feature).
- `4da474a` — 4 mutation-corpus entries + a harness fix.

**Campaign: 24 rounds done** — A0a A1 A1a A0c A5 A1b F1a A2+A3 A4 B1 B1a B2 C0 C1 C2a C2b C2c C2d T0 C3a C3b C4a C4b.
**NEXT = D1**, manifest skill rewrite (`019f3e045dac`). Staffing: Sonnet impl / Opus cold review / **Opus** text+test adversary / Sonnet code adversary — D1 is nearly pure prose, so station 2.0 is the load-bearing gate, not 2.2.
**Then**: D2, D3, D4, D5, F1a-panel, E1, E3, F1b, A0b. Hard ordering: **D4 before F0**; **F1a-panel before E1**.
**Then** one terminal HITL session, 5 checks: R3 golden bless · R4 clean-machine marketplace install · R6 mac/win install-only · E2 label de-overlap (`019f97a71218`+`019f97a74633`) · D4v silk legibility.

## Gates (numbers move every round — read them from the suite, never from here)

    worker  cd pcb/worker && PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -m pytest tests/ -q -p no:cacheprovider    # 1358 passed / 1 skipped at 4da474a
    gd      bash pcb/scripts/run-gd-tests.sh /home/imran/github/Minerva                                            # ABSOLUTE path; ../../Minerva fails
    go      cd pcb && go vet ./... && go test -count=1 ./...
    sweep   pcb/worker/tools/mutants/run_sweep.py --sweep -j 6 --control-passed <current> --control-skipped 1

**Sweep facts that will otherwise cost a round:** corpus is at **44 = the band ceiling** (raise or displace). **SIX survivors is the floor, not zero** — five are real holes (`019fa2502d09`), one is a documented equivalent mutant. **CHECK THE CONTROL IS GREEN before believing any kill set** — a red control makes every mutant look killed. `run_sweep` refuses a dirty tree, so to sweep uncommitted work mirror the tree to a scratch repo and commit *there*.

## Two skills authored this session (committed, not yet exercised)

- **NEW `.claude/skills/orchestrator/SKILL.md`** — PM role: selection, acceptance, the record, knowledge stores, escalation, campaigns, close-out. Owner reviewed an earlier draft with 14 comments; all accepted and applied (strip history, define terms before use, add templates, do/don't format).
- **MODIFIED `.claude/skills/work-cycle/SKILL.md`** — 8 changes. Campaign mode MOVED OUT to orchestrator. "Memory and hints" rewritten (it pointed at the volatile store, at the wrong moment, and never said to write back). Sub-agent prompts now say *state constraints, point at facts*. New anti-pattern 20.
- Placement rule: **work-cycle = how to run this round; orchestrator = what the goal is and what success looks like.** Unplaceable rules default to orchestrator.

## A/B test on skill wording — VOID by its own canary, but one usable finding

Pre-registered 3-arm test (persona framing vs scope claim vs canary-with-template-removed), N=5, Sonnet, one frozen fixture, primary metric = word count.
**Result: VOID.** Canary moved the median 36.8%; the pre-registered validity gate required ≥50%. Nothing is concluded about persona vs scope.
**The metric was the error** — word count doesn't measure what a template controls. The secondary (labelled-field conformance) separated cleanly: **A 6.0/6 · B 5.6/6 · C 2.6/6**.
**Usable without more sampling: the template is doing essentially all the work.** Whatever the role sentence adds is too small for 2×5 to separate. Treat the template as load-bearing, the role wording as a style call.
**Cost was ~48k tokens per run, ~730k total** — an order of magnitude above my estimate. Do not call a 15-run A/B cheap.
Artifacts under the session scratchpad: `ab-prereg.md`, `ab/skill_{A,B,C}.md`, `ab/fixture.md`, `ab/out/*.txt`.

## Needs the owner — neither blocks anything

1. **Routing and DRC disagree by design** (since C4a). An explicit caller width/clearance outranks a net-class minimum in routing; DRC holds copper to the class floor. So an override can produce copper DRC flags. Documented in `pcb/docs/routing.md`, not changed. If routing should REFUSE such an override, that is a code change needing its own item.
2. **`019f9fb32de7`** (sev 2, `_segment_clear` corner-permissive for all callers, residue 14/2889). Needs a fix direction — supercover DDA vs swept-rectangle — before it can be scheduled. Open since C2d.

## Filed, not fixed, NOT adopted

`019fa0349a4e` `019fa0718a20` `019fa0d13faa` `019fa075e081` `019fa0f8d575` `019fa109766f` `019fa109b43c` `019fa172dd21` `019fa17326b5` `019fa1cda337` `019fa20b112a` `019fa2502d09` `019fa2c51322` `019fa2eaef03`

Adoption rule: an item joins the campaign candidate set **only if it explicitly blocks a subtree item**.
`019fa109b43c` is pinned by a test labelled a known bug — **invert that assertion when it lands, never delete it, then RE-MUTATE it** (an inverted assertion inherits no kill power from the original).

**NOT YET FILED — Docket was down.** Record the A/B result above as a durable hint under `work-cycle` when Docket returns.

## Owner rulings — do not reopen

- Guarded parallel fan-out **stays**; concurrency needs a **named qualifier** (disjoint fences / not both driving Godot / reviewer-and-adversary never concurrent). "It feels independent" is not a qualifier. No blanket serial rule.
- **No region selector** on `minerva_pcb_delete_traces`; exact ids + exact `net_name` is the shape. Revisit home `019fa1cda337`, deferred.

## The failure mode this session kept producing

Five factual errors, all mine, all one shape: **a fact asserted about a file that was never opened** — a false floor value in a brief, a symbol name taken from a sub-agent report, two false claims in a filed item, and a premise about a guard's semantics that an implementer correctly refused. Both new skills exist to close it: briefs point at facts rather than stating them, and tracker writes get opened-and-verified before they are written. The gates caught every instance; none reached the code.

---

LATEST **2026-07-21** — **hermetic-CAM KEYSTONE: K1-parser + K1-types + K2 (compiler) ALL SHIPPED + Sol-APPROVED. K3 (repoint emitters) is NEXT — behind 3 ratified gates.**

**K2 SHIPPED `d8f26e1` (minerva-plugins main) — Sol cold review APPROVED after 4 reconciliation rounds** (question `019f7dade006`, approval comment 632; independently verified 576 passed/1 skipped, clean worktree, both schema guards + annulus/plating conflict detection). **K2 = FootprintDefinition→ResolvedBoard compiler, gated default-OFF by non-wiring** (nothing live imports it; K3 wires it). Delivered: `compile_board.py` (`compile_board()` returns `ResolutionSuccess{board,diagnostics}`|`ResolutionFailure`; `DefaultCapabilityPolicy`) · **NEW `fab_capability.py`** = the neutral shared emitter-capability authority (EMITTED_LAYERS/SUFFIXES + FABRICATION_CRITICAL_OUTPUTS + SUPPORTED_PAD_SHAPES/GRAPHIC_PRIMITIVES/HOLE_SHAPES; K2 + every emitter import it) · additive IR extensions (`ResolvedComponent.value`, `geometry.TRANSFORM_VERSION`, `resolve_footprint(lock=…)` snapshot). Sole constructor of PlacedPad/PlacedGraphic via the ONE PlacementTransform (mirror incl); STRICT/fail-closed/no-invented-geometry; board-namespaced content-derived ids; complete pad+graphic projection parity + board-carriage oracle; compile-census over all 11 seeds. Suite baseline now **576 passed / 1 skipped**.

**K3 STARTS BEHIND 3 SOL-RATIFIED GATES (do not repoint a consumer past its gate):** (1) **persistent-ID + pin-geometry-authority migration `019f802ca3af`** (v1→v2 mint persisted board/entity ids, board-namespace children, reject invalid authored ids; formalize locked-footprint-authoritative + typed per-pad overrides; deprecate legacy inline pin geometry) — hard `blocks` K3; the DRC/routing switch cannot cross it. (2) **YAML-v2 shared Go/Python validation boundary** (migration comment 629) — mandatory before K3 consumes v2. (3) **faithful CAM capability conformance** (K3 comment 628) — the emitter must render every SUPPORTED pad/graphic/hole primitive faithfully; today's gerber.py flattens SMD→rect, so this gate is RED until fixed. Reference: durable hint `pcb-worker/layer-authority` `019f800e6668`.

**CONTEXT:** codex/Sol review found Stage 2's NAMED contract (live A1 `FootprintDefinition` + `ResolvedBoard` IR) was NOT delivered — the pad-bug fix used a pragmatic `comp["pads"]`-dict path; A1 was dormant. So my "Stage 2 steps 1–7 COMPLETE" was OVERCLAIM → **Stage 2 `019f761fe518` STAYS `in_progress`** (comment 602). Ratified a correction Plan-of-Record — captured in the Minerva spreadsheet **"Hermetic-CAM Work Plan"** + the keystone docket tree.

**KEYSTONE `019f7abf55c2`** (Build ResolvedBoard IR + FootprintDefinition→ResolvedBoard compiler) decomposed into children: **K1-parser `019f7aed3c62` DONE `429f9d6`** · **K1-types `019f7aed2151` DONE `06da15e`** · **K2 `019f7aed55d4` DONE `d8f26e1`** · **K3 `019f7aed6d9e` NEXT (gated)** · K4 `019f7aed8923` (cutover, HITL golden-bless). Deps: K1→K2→K3→K4; keystone blocks Stage 4 `019f761ffa46` blocks acquisition-B `019f77b11f88`; keystone blocks routing DCR `019f7095c395`.

**SHIPPED THIS SESSION (minerva-plugins main, all pushed):** `f16fe37` Go-test fix (bug `019f7abf9c8e` verified) · `28b4fe1` DRC relabel (connectivity/topology honesty; `019f7abf7e7b` relabel-facet done, geometric facet = PoR step 9) · `429f9d6` K1-parser (lossless-or-flag footprint parser) · `06da15e` K1-types (ResolvedBoard IR + completed FootprintDefinition + placement-mirror transform + `canonical_id.py` RFC 8785 JCS + `pad_types.py`). **Suite baseline now 475 passed / 1 skipped.**

**K1-TYPES CONTRACT = keystone comments 610–618** (design-of-record; **Sol IMPLEMENTED it** after 4 reconciliation Q&A rounds, 612–617). VERIFIED: `canonical_id` = genuine RFC 8785 JCS (Appendix-B vectors, cross-language reproducible — memory hint `pcb-resolved-ir/canonical-id-encoding`); bottom-flip transform hand-confirmed vs the pcbnew oracle; cold Opus review **approve_with_notes** (all 9 contract points). **4 LOW-SEV notes on comment 620 → feed K2's CapabilityPolicy** (fp_text-on-copper default_blocking edge; zone-keepout layer; cutout type-check; test-only id detail).

**K2 `019f7aed55d4` — DONE `d8f26e1` (see top block).** The original acceptance (kept for the record): the FootprintDefinition→ResolvedBoard **compiler**, gated OFF, STRICT/no-defaults, sole constructor of PlacedPad/Graphic. **K2 ACCEPTANCE additions on comment 618:** returns `ResolutionResult` (`ResolutionSuccess{board,diagnostics}` | `ResolutionFailure`); implements the `CapabilityPolicy` (copper/drill/mask/paste loss BLOCKS; docs WARN; context-eval; captured-but-K3-unsupported explicit); compile-census (all 11 seed footprints → `ResolutionSuccess`). **Model: Claude Opus IMPLEMENT + Sol REVIEW.**

**WORKFLOW (this session's model):** 1 large Sol IMPLEMENT item (K1-types) + Sol as REVIEWER + design-consultant via docket `question` items (610–618). Conserve Claude quota (was 85% weekly; Sol smaller budget → 1 impl item only, reviews K2 + step-9 DRC). **SERIALIZE Sol + Claude in the same tree** (no parallel — high conflict-resolution cost). Sol consult = file a self-contained docket `question` (repo/base-SHA/files/rubric); owner bridges. See memory `feedback_sol_consult_via_docket_question`.

**REMAINING (post-K2):** K3 repoint gerber/kicad/drc onto IR (parity, gated) · K4 cutover (delete dict path + emitter invented-geometry sweep — annulus=2×/silk-boxes/defaults REMOVED as REVIEWED golden changes, NOT ruling-4 auto-accept; closes keystone + resolve {1,1} `019f78387ba6`; Stage 2 → done) · Stage 4 (step 8 router fail-closed `019f783860c8` = the fail-closed-VIOLATION; step 9 geometric DRC `019f7abf7e7b` geo-facet = Sol reviews) · routing T3–T8 `019f7095c395` · then acquisition-B design (**C3 REJECTED** — must target the live contract).

**ENV:** Linux desktop imran-Ubuntu-Main (NOT the Mac laptop). Test venv per hint `pcb-worker/test.linux` `019f790e8a62`: create real venv + `pip install -e 'worker[dev]'`; 475/1 baseline; a gerbonara-less venv silently skips ~53 CAM tests. **Standalone Docket MCP** (`mcp__docket__*`), project `minerva` = `Docs/minerva.dct`.

---

EARLIER (2026-07-19 AM) — hermetic-CAM DCR `019f761ead82`; Stage 2 pad-bug FIXED + oracle-VERIFIED; Step 4a-ii DONE (emitter fail-closed, commit `0223b04`). Steps 1–4a-ii DONE.** Stage 2 migration path D: **S1 transform→geometry.py `369937e` · S2 A1 FootprintDefinition+fixtures `cd5d2e7` · S3 chain resolve into fab behind default-OFF gate `1577d1d` · S4a-i spike resolves to real 0805 land + golden regen `baae81a` · owner re-bless → correctness oracle LIVE `0e10b87`**. The strict-xfail for pad bug `019f7736b236` is GONE — now a LIVE PASS: emitter(resolved spike) == owner-re-blessed golden EXACTLY on copper/mask/drill/edge. Suite **412 pass / 1 skip / 0 xfail** (pad-bug xfail GONE). Pad bug `019f7736b236` at docket status **`verified`** (oracle gate b green; `closed` HELD for gate a = first real smart-remote fabrication). **Step 4a-ii SHIPPED `0223b04` (base `0e10b87`), design (2) = best-effort resolve + EMITTER fail-closed:** gerber/kicad SMD placeholders (1.0×0.6 / 1 0.6) DELETED; `pad_source.iter_pads(require_smd_size=True)` raises `PadGeometryError` on a sizeless SMD pad (OPT-IN — drc reads centers only, untouched); `methods.RESOLVE_FAB_GEOMETRY_DEFAULT` flipped ON with `resolve.resolve_board_best_effort` (unresolvable footprint left inline, coincidence still fatal), standalone `resolve` action STRICT; `_from_pin` normalizes 0/neg drill→None (symmetric with `_from_resolved`). Goldens `board-F_{Cu,Mask,SilkS}` + emitter drift-pin regenerated resolved (drilltest UNCHANGED; ruling-4 diff-empty vs blessed oracle on copper/mask/drill/edge). Cold Opus review approve_with_notes (nit fixed). Functional floor: real `gerbers` dispatch emits real 1.0×1.45 0805 land, zero placeholder. **Blast radius was bigger than pickup first implied** — fail-closed raises on ANY raw SMD-no-geom build, so test_rotation/test_determinism_gate/oracle-*/kicad-cli-DRC-oracle + capture_emitter_golden all resolve-first now; test_step3_resolve_fab REFRAMED to gate-ON+fail-closed. **DEFERRED (owner-confirm at HITL):** `route_bridge._DEFAULT_PAD_SIZE` → item `019f783860c8` (router keepout = DEGRADE side, route() doesn't resolve; fail-closing breaks the live router) + residual `resolve._pads_from_parsed {1.0,1.0}` → `019f78387ba6`. **Step 4b badge SHIPPED `dde4a6d` + rendering VERIFIED via MCP** — the amber "!" unresolved-footprint triangle renders on exactly the right parts (U2 unresolvable = badged; R1/J1 real pads + MH1 mounting hole = NOT badged), confirmed in a real off-screen board capture. Pins-as-dots fallback pre-existed; 4b adds the badge via `pcb_canvas.gd::_draw_unresolved_badge` (`show_unresolved_badges` toggles).

**GET_IMAGE SIDE-QUEST (unblocked the 4b HITL — all PLUGIN-ONLY, owner guardrail "no PCB code in Minerva core", verified core has no native PCB remnant):** `minerva_pcb_get_image` was returning a blank/wrong frame (capture-path regression from the native→plugin port — the port stripped `capture_to_image` with a wrong "MCP export lives in the worker" rationale, `pcb_canvas.gd:20`; replacement screenshotted the window + cropped → editor background only; width/height ignored). Bug `019f7876e3d4` (now docket `active`). Fixes: `b596238` restored offscreen `capture_to_image` (own SubViewport + fresh canvas copy over same board data → render → read texture; honors width/height; null headless keeps the graceful-null test contract); `d60a2fb` STALL fix (repeat captures stalled past MCP timeout because `frame_post_draw` doesn't fire while the app is idle/background-throttled → replaced with `RenderingServer.force_draw(false)` after one `process_frame`) + enlarged badge (7→11) + hover tooltip (`_get_tooltip`). Also added `minerva_pcb_set_view` (pan/zoom camera, `ab0a5a2`) for detail inspection. Filed multimodal-delivery substrate bug `019f789b9608` (MCP image results wrapped `type:text` — Minerva-hosted LLMs can't vision-decode; external agents use save_to_path+read). Cold Opus review on every change (approve / approve_with_notes).

**4b VISUAL HITL PASSED — owner sign-off 2026-07-19 (post-restart, `d60a2fb` loaded).** All three items GREEN: (a) enlarged badge (7→11) reads clearly + lands on exactly the unresolved part; (b) hover tooltip confirmed by owner ("U2 — unresolved footprint / Pads are approximate…"); (c) repeat-capture stall GONE (4 back-to-back captures, no timeout — `force_draw` fix confirmed on Linux). Reproduced on a fresh "Badge Signoff" board: U2 (unresolvable QFN) badged; R1 (SMD real pads), J1 (TH real pads), MH1 (mounting hole) NOT badged. **MH1 "4 green corner triangles" cosmetic did NOT reproduce** (mounting_holes-as-Extra render as a clean black circle — owner confirmed circle cutout green); no action. **get_image capture bug `019f7876e3d4` → `verified`** (standalone Docket MNR; comment 595). **Stage 2 step 4b + get_image sign-off recorded on `019f761fe518` comment 596.** ⇒ **Stage 2 steps 1–6 COMPLETE.**

**PAD BUG FIXED (steps 1–7); Stage 2 CONTRACT still open — do NOT call Stage 2 complete (codex peer review, owner-endorsed 2026-07-19).** Steps 1–7 (incl. Step 7 provenance-collapse `8436708` + HITL PASSED, task `019f791cdf26` done: the 4 resolved-vs-fallback reps → ONE predicate `pad_source.has_resolved_pads(comp)`; GD key `footprint_found`→canonical `has_pad_geometry` back-compat; suite 413/1/0, zero golden change) delivered the **pad-bug fix** (`019f7736b236`, oracle-verified — real value) via a pragmatic `comp["pads"]`-dict wiring. They did **NOT** deliver Stage 2's NAMED contract: **no ResolvedBoard IR type exists; A1 `FootprintDefinition` is DORMANT** (nothing imports it but its test); `to_board_pad_dicts` is lossy (drops rotation/corner_rratio/drill-shape/mask-margin/model3d/provenance). `019f761fe518` correctly STAYS `in_progress` (comment 602 corrects my earlier "COMPLETE").

**DOCKET RESTRUCTURED per the corrected sequence (this session):** new keystone **`019f7abf55c2` — Build ResolvedBoard IR + live FootprintDefinition→ResolvedBoard compiler** (strict, NO geometry defaults; child of Stage 2). It **blocks** Stage 4 `019f761ffa46` (migrate router/DRC/canvas/CAM onto IR) which **blocks** acquisition B `019f77b11f88`; keystone also **blocks** routing DCR `019f7095c395`. Reclassified: `019f783860c8` route_bridge 1.0×1.0 keepout = **FAIL-CLOSED-RULING VIOLATION** (not degrade — routing must fail closed; reparented → Stage 4, prio 2, comment 601); `019f78387ba6` resolve `{1.0,1.0}` = fail-closed HOLE, reparented → keystone, prio 2. New: DRC bug `019f7abf7e7b` (center-only `_Pad` claims geometric clean it can't verify → split draft-connectivity/geometric-DRC/DFM; child of Stage 4); Go-test bug `019f7abf9c8e` (`main_test.go` want-list missing `pcb.draft_check`, red since `7f5060b`/T2.4 — PRE-DATES this session, NOT set_view; child of routing DCR).

**CORRECTED SEQUENCE (codex, endorsed):** (1) keystone IR+compiler → (2) migrate router+geometric-DRC onto IR (kill route_bridge keepout, stop claiming geometric-clean) → (3) routing-workspace T3–T8 on stable IR → (4) THEN acquisition B as adapters onto the LIVE contract. **B recommendation C3 REJECTED** (comment 603): the lossy bridge drops exactly the fields B needs (real land sizes/roundrect/mask) → acquisition must target the live IR, not a nominal record. Design B now; do NOT DCR-ify / file B0–B6 until keystone + Stage-4 land and B is re-ratified. Fold in review hardening: coincidence guard is CENTER-ONLY (needs structural review + package identity), layered library w/ lock-pinned identities, content-addressed 3D mirror (not url+sha), stage-for-review even official, import defenses, preserve original source. **NEXT = start the keystone `019f7abf55c2`** (the real Stage 2). Also fix Go test `019f7abf9c8e` (trivial).

**ENV (Linux desktop `imran-Ubuntu-Main`, NOT the Mac laptop):** worker `.venv` is a bare anaconda symlink w/ no dev deps — the pickup's macOS env notes (gerbv /opt/homebrew) don't apply here. Test venv: create real venv + `pip install -e 'worker[dev]'`; run `cd pcb/worker && <venv>/bin/python -m pytest tests/ -q`. Durable hint: pcb-worker/test.linux (`019f790e8a62`). **Use standalone Docket MCP (`mcp__docket__*`), not Minerva's passthrough** — survives Minerva up/down, has all projects; the `minerva` project = `Docs/minerva.dct` (prefix MNR). **minerva-plugins main commit trail this session (all pushed):** `0223b04` 4a-ii · `dde4a6d` 4b badge · `ab0a5a2` set_view+get_image fit · `b596238` offscreen capture · `d60a2fb` badge-size+tooltip+stall-fix. 4a-ii/4b + get_image detail: docket `019f761fe518` comments 589–594, bug `019f7876e3d4`.

## Key decisions this session (Step 4 reshaped by spike investigation)
- Spike revealed: the spike board's footprints weren't in the seed lib (resolve FAILED) and the blessed golden's SMD pads were a SYNTHETIC hardcoded 1.2×1.3 (no library source). Owner chose (over 3 clarifying rounds): **import real footprints + re-bless** (not inline); **Option A** = scope the correctness oracle to fab-critical copper/mask/drill/edge, EXCLUDE silk (`GeometryDiff.excluding_layers`); **close pad bug now, coverage-audit next**.
- Vendored 3 real-land seed footprints keyed by BARE names (R_0805/C_0805/TH_TestPoint) so the spike board is UNCHANGED (preserves libcheck missing-fp coverage). Anti-circularity kept: golden regenerated by INDEPENDENT `generate.py` (gerber_writer), emitter is pcb_worker (pygerber).
- Owner insight → NEW follow-ups: **silk-text/image is an unimplemented emitter feature** `019f77fd6d69` (blank silk = no assembly designators; `gerber.py:446` "reference-designator text is future"; parser drops `fp_text`); **manufacturable-feature golden coverage audit** `019f77fd9c6c` (a synthetic golden only certifies what it contains — audit vs a real fabricated+assembled board). Memory updated: `feedback_golden_bless_gerbv_walkthrough` now carries the coverage+perceivability caveat.

## State: all committed + pushed
- **minerva-plugins** `main` @ `0e10b87` — 0 unpushed, clean. Stage 2 campaign commits: `369937e`(S1) · `cd5d2e7`(S2) · `1577d1d`(S3) · `baae81a`(S4a-i) · `0e10b87`(re-bless). (Standing policy: Minerva → `development`, minerva-plugins → `main`.)
- **Minerva** `development` — 0 unpushed; only `Docs/minerva.dct` dirty (live docket, commit at handoff).

## Done this session (reliability-first sequence: backbone → CAM decision → harness → [Stage 2])
1. **Verification backbone `019f7710cb12` DONE.** SB.1 gerbonara reader + dev-only kicad-cli DRC oracle (`e33ee3d`); SB.3 determinism gate + kicad-cli boundary lint (`afbce24`); SB.2 golden geometry-diff + provenance (`2a201a4`). Gerber golden `spike-gerber-v1` **blessed** via gerbv walkthrough (`24c8e08`). kicad-cli is DEV/CI-ONLY (boundary-lint enforced); gerbonara pip-pinned, no-FCIB.
2. **CAM emitter decision `019f761fcfc3` DONE + RATIFIED.** Adopt **gerbonara 1.6.3 as the single unified emitter** (Gerber+Excellon+IPC-356); split rejected. Decision @ `780246c` (`pcb/spikes/cam/DECISION.md`). Conditions carried into productionize `019f761fefae`.
3. **Harness completion.** Slot + IPC-356 diff `019f7772eca0` resolved (`6a5c217`). Excellon/slots/IPC-356 golden `cam-excellon-ipc356-v1` **blessed WITH CAVEAT** (`d0792dc`, item `019f777e9206` done): drills/slot visually blessed in gerbv; IPC-356 blessed only as symbolic net-membership (no netlist viewer → tracked `019f77aa012e`).
4. **Stage 2 `019f761fe518` designed + ratified** (status `open`) — full design + 4 rulings + migration path D are in that item's docket comments.

## NEXT — Stage 2 implementation (`019f761fe518`)
**Ratified design: A1 + B1 + C2\* + D.**
- **A1** flat, KiCad-INDEPENDENT FootprintDefinition (formalize the pad DTO `resolve._pads_from_parsed` already emits + add fab fields: per-pad `rotation_deg`, `corner.rratio`, `drill.shape` incl oval-slot, `overrides.solder_mask_margin`, canonical `layers`, `model3d`, `lock`).
- **B1** ONE mandatory resolved-tree IR (footprint-local coords, one shared transform, carries `layer_stack`/holes/outline/net_index); preserves the editable GD component tree. Consumers become "resolve, then compile."
- **C2\*** reframed → footprint acquisition system (see below).
- **D** low-risk-first migration.

**KEY REFRAME:** the correct pad geometry ALREADY EXISTS — `resolve.py:resolve_board()` computes it (fail-closed, 0.01mm coincidence), but the fab path (`gerber.py:_harvest`) reads `comp["pins"]` (placeholder 1.0×0.6, bug `019f7736b236`) and `resolve_board()` is NEVER chained into fab (`methods.py` `_gerbers/_generate/_drc` run on the raw board). So Stage 2 is WIRING + formalizing + kill-duplication + fail-closed, NOT inventing geometry. Duplication to collapse: 8 pad-reconstruction sites → 1; 5 transform copies → 2 (Py+GD); 4 provenance formats → 1.

**MIGRATION PATH D — the autonomous campaign (steps 1–6):**
1. Promote the place-transform → `pcb_worker/geometry.py` (zero-risk refactor; `drc` already imports it from `gerber`).
2. Extend FootprintDefinition additively + synthetic 0402/0603/SOIC fixtures (smart-remote lacks them).
3. Chain `resolve` into the fab path behind a gate; `gerber._harvest` + `kicad._footprint` read `comp["pads"]`; geometry-diff old-vs-new per board.
4. Remove ALL placeholder defaults (`DEFAULT_SMD_PAD_W/H_MM`, `route_bridge._DEFAULT_PAD_SIZE`, kicad 1/0.6) → **fail closed**. RULING: canvas DEGRADES (pins-as-dots + badge — a `.gd` change → needs app-restart VISUAL HITL), fab FAILS CLOSED.
5. Regenerate byte-goldens through the production path. RULING: **auto-accept** if geometry-diff EMPTY vs blessed `spike-gerber-v1`.
6. The strict-xfail `test_spike_golden_correctness_oracle_matches_emitter` XPASSes → flip to live green → **bug `019f7736b236` CLOSES.**
7. (After parity) collapse remaining provenances → the footprint acquisition system (design C, separate pass).

**4 OWNER RULINGS (locked):** (1) canvas degrades / fab fails closed; (2) v1 = rect/roundrect/circle/oval pads + SMD/TH/NPTH + round drills, fail-closed on exotic (custom/trapezoid/chamfer + oval-slots) until needed; (3) library = **ON-DEMAND FETCH of ANY footprint from ARBITRARY repos/URLs** (Digikey/Mouser/SparkFun/SnapEDA/mfr) + hand-authored for no-library parts; (4) auto-accept regenerated goldens if they diff-match the blessed golden.

**DESIGN C — SPLIT OUT into its own item `019f77b11f88` (footprint acquisition + authoring; own design pass + ratify gate; NOT part of Stage 2 steps 1–6).** Stage 2 steps 1–6 use the EXISTING sha-pinned seed-lib resolve as-is and need NO new sources to close the pad bug. The acquisition system is the EXTENSION: sources = KiCad release | arbitrary git/URL | vendor export | HAND-AUTHORED (native A1, no KiCad) | (future) generated. `.kicad_mod` is TEXT (not FCIB) → vendorable with provenance; only 3D binaries by-reference — AND 3D can be authored in the CAD DSL (text), so authored parts are text end-to-end. Fetch-on-first-use → lock → hermetic. Blocked by Stage 2 (needs A1 + IR); land at step 7.

**STAGE 2 EXECUTION:** work-cycle campaign, steps 1–6 autonomous (safety nets = geometry-diff oracle + blessed golden + ruling-4 auto-accept), Opus impl + Opus cold review. Stop for the step-4 canvas-degrade VISUAL HITL. NOTE: unlike the backbone (test-only fences), Stage 2 DOES touch runtime `pcb_worker/*.py` + `.gd` — that's expected.

## Pending / deferred
- **Follow-ups:** pad bug `019f7736b236` (closes at Stage 2 step 6); Excellon-header bug `019f7720928d` (may die with the gerbonara-emitter migration); gerbonara 1.6.3 writer bugs `019f7773257` (productionize condition); IPC-356 visual tool `019f77aa012e` (closes the netlist-bless caveat).
- **Routing DCR `019f7095c395`:** Band A done; Band B/C (T3–T8) PAUSED — deferred to after the hermetic-CAM IR migration (some routing UI reworks onto ResolvedBoard IR). via GATE `019f70f76c2f` still open.
- **Smart-remote board: DEFERRED** — do NOT route/fabricate until Stage 2 (real footprints); fabricating now = defective pads. Breadboard bring-up `019f77110389` (wiring sheet + ESP32-S3 firmware; sources at `~/gitlab/ccsandbox/smart-remote`) waits for a "good in theory" board.
- Later hermetic-CAM stages: YAML v2 `019f761fda74`, productionize CAM `019f761fefae`, migrate-to-IR `019f761ffa46`, mfr profile+coupon `019f762004dc`, 3D STEP `019f763ca706`, assembly `019f763cdf5b`, RF `019f7644892a`.

## Environment / harness (don't relearn)
- **PCB worker tests:** `cd ~/github/minerva-plugins/pcb/worker && .venv/bin/python -m pytest tests/ -q`. Venv = Python 3.12.12 WITH pip (this one works — the general "uv venvs are pip-less" warning does NOT apply here). Baseline: **330 passed + 1 skip + 1 xfail** (xfail = pad bug, flips green at Stage 2 step 6).
- **gerbv** (bless tool): `/opt/homebrew/bin/gerbv`. Bless a golden by walking each layer/drill vs stated intent (see memory `feedback_golden_bless_gerbv_walkthrough`).
- **NEVER** `godot --headless --path ~/github/Minerva` (that's the live session). Minerva is running this session.
- Deploy matrix: manifest→REINSTALL; worker.py→plugin restart; Go broker→rebuild+reinstall; panel/core `.gd`→APP RESTART; after reinstall `/mcp` reconnect.
- Session commit trail (minerva-plugins main): `e33ee3d` SB.1 · `afbce24` SB.3 · `2a201a4` SB.2 · `24c8e08` Gerber bless · `780246c` CAM decision · `6a5c217` slot/IPC diff · `dbfce7d` Excellon golden · `d0792dc` Excellon bless.

## Key docket IDs
hermetic-CAM DCR `019f761ead82` · **Stage 2 FootprintDefinition/IR `019f761fe518` (ratified — NEXT; design in its comments)** · verification backbone `019f7710cb12` (done) · CAM decision `019f761fcfc3` (done) · footprint acquisition+authoring `019f77b11f88` (design C, split out, own ratify) · pad bug `019f7736b236` · gerbonara bugs `019f7773257` · IPC-356 tool `019f77aa012e` · productionize CAM `019f761fefae`. Memory: `feedback_golden_bless_gerbv_walkthrough`, `project_pcb_hermetic_cam_dcr`.
