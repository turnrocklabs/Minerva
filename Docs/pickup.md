# Pickup

STATE: `P1.0 + P1.1 + P1.2 DONE. host.pdf.generate is contract-frozen, gofpdf-backed (gate-PASSED), and broker-wired with audit redaction. The substrate is functionally complete. Next: BUILD THE NAMETAG PLUGIN (019e80a0f17a, minerva-plugins) — the original goal + the live-spawn validation point. P1.3 (richer primitives) / P1.4 (full plugin-guide section) are deferrable stubs.`

Last updated 2026-06-01.

> **Unpushed as of this update:** Minerva `d05d665b` (P1.2) + the pickup commit on `pdf-print-substrate`; minerva-plugins `45bbe98` (guide rows) on `main`. (Minerva pushed through `ac045772`.)

> **Branch-scoped pivot.** This `pickup.md` belongs to the **`pdf-print-substrate`** branch (off `development` @ `73b0c821`). `development` stays focused on **codetools** — its P1.4 (visualizer panel HITL) is PARKED, state preserved in docket kb `019e7f366d99` + memory `project_codetools_extraction.md`. Do NOT merge this pickup back to `development`.

---

## TL;DR

New initiative: **add a document-output subsystem (PDF generation, view, export, print) to Minerva**, then build a **standalone nametag-maker marketplace plugin** as its first consumer. Came out of a goal to port `~/gitlab/minervaservices/experiments/NameTagMaker` (a Python fpdf2 script → duplex cardstock name-tag PDF) into a Minerva plugin — but Minerva already imports .xlsx natively, so the plugin's only real need is **PDF generation**, which we're putting in the substrate.

Governing DCR `019e809f` (`minerva` docket, **approved**). The plugin is a **standalone** work_item, NOT a DCR child — connected only by `blocked_by P1.1`.

The whole plan was designed against the project rubric (reliability → durability → cost → readability → DRY → well-factored). Read the DCR description — it carries the locked decisions, the rubric guardrails, and the phasing.

---

## 0. What to do next session — P1.2 ‖ nametag plugin (P1.0 + P1.1 DONE)

**P1.0 `019e80a0293d` DONE** — contract FROZEN at `Docs/design/host_pdf_contract.md`: stateless declarative-batch **`host.pdf.generate(doc)`** (doc → images registry → pages → ops = `draw_text`/`draw_image`/`draw_line`/`draw_rect`). Envelope `{success,result}`, points + top-left origin, color `[r,g,b]`, 8 MB cap, DejaVu bundled, `fit` sidecar-side auto-shrink. §8 maps every `TagRenderer` primitive; §11 has the rubric rationale. Changes require a new docket item.

**P1.1 `019e80a0596b` DONE** — pure-Go `go-pdf/fpdf` sidecar at `src/sidecars/host_pdf/` (commits 7b856a67 sidecar+fonts+12 tests, a06432a3 gate; pushed). go-pdf/fpdf **v0.9.0** (v1.4.x retracted — nudge `minerva-host-pdf/gofpdf.module`). Built via `scripts/build-host-pdf.sh` → `src/bin/` (gitignored). **Pixel-diff gate PASSED** vs `generate_tags.py`: overall mean-abs 0.0255, 0.048% pixels differ (AA-only), string widths match to 3 decimals — gofpdf confirmed, no Python fallback. A faithful Go layout port (grid/corner-marks/duplex/icon/fit incl. the legacy `_draw_name` floor/floor-1 quirk) lives in `src/sidecars/host_pdf/cmd/gateharness/harness.go` — reuse as the plugin's layout spec.

Next, two tracks:

1. **P1.2 `019e80a06854`** (Minerva, this branch) — wire `host.pdf.generate` through `CapabilityBroker` (route to the sidecar; manifest `host_capabilities`; audit; add the 4 new error codes — `font_not_available`/`unknown_image_id`/`image_decode_failed`/`pdf_generation_failed` — to `PluginErrors`). Makes host.pdf callable from a plugin in-app. Open detail: the sidecar reply → `{success,result}` mapping (contract §10; mirror `_handle_mcp_proxy`). Smallest step to make host.pdf real.
2. **nametag plugin `019e80a0f17a`** (minerva-plugins repo) — now UNBLOCKED. Non-PDF ~90%: xlsx→spreadsheet→.mtags pipeline (`mcp.proxy:minerva_get_spreadsheet_data`), HTML+PDF.js viewer, HITL physical-print acceptance. Last mile = the `host.pdf.generate` call, which needs P1.2 to work in-app.

---

## 1. The docket tree (all in the `minerva` project, prefix MNR)

- **DCR `019e809f`** — "Support printing & PDFs in Minerva" (approved). Design of record: decisions, rubric guardrails, non-goals, architecture, phasing, open questions.
- Phase children:
  - **P1 `019e809fb22f`** — Precise PDF generation (`host.pdf.*`). [critical path]
  - P2 `019e809fc888` — View & preview (webview): pageable read-only PDF + PDF-as-note. [stub]
  - P3 `019e809fd8fc` — Export a view to PDF (`host.export.pdf`). [stub]
  - P4 `019e809fe9a3` — Print (`host.print`) — OPT-IN. [stub]
- P1 grandchildren:
  - **P1.0 `019e80a0293d`** — define host.pdf.* contract. **DONE — FROZEN at `Docs/design/host_pdf_contract.md`.**
  - **P1.1 `019e80a0596b`** — host.pdf MVP (gofpdf sidecar + bundled fonts + smoke test + pixel-diff gate). **DONE + GATE-PASSED (7b856a67/a06432a3, pushed).**
  - **P1.2 `019e80a06854`** — broker wiring + audit + permissions. **DONE (d05d665b; guide rows in minerva-plugins 45bbe98).** Residual: literal in-app spawn e2e rides on the first consumer (`--script` can't fork+exec SubProcess — harness limit, not a code gap; broker reuses the production MCPServerConnection path).
  - P1.3 `019e80a0789e` — richer draw primitives. [stub]
  - P1.4 `019e80a0855e` — plugin-guide section. [stub]
- **Nametag-maker plugin `019e80a0f17a`** — STANDALONE work_item, **UNBLOCKED (P1.1 done)**. Repo `minerva-plugins`. Buffer pipeline (xlsx→spreadsheet→.mtags→PDF), HTML+PDF.js viewer, HITL physical-print acceptance. Layout spec = `src/sidecars/host_pdf/cmd/gateharness/harness.go`.

---

## 2. Locked decisions (full detail in DCR `019e809f`)

1. **`host.pdf` is the ONE generator** — plugins call it, never embed their own PDF lib (DRY).
2. **Generation = Go `go-pdf/fpdf` bundled MCP-service sidecar** (NOT in-process GDExtension — PDF gen is non-realtime/stateless/no-scene-tree). Start from the presentation/codetools Go-backend scaffolding + existing capability-broker pattern. **Gated on the P1.1 pixel-diff**: diff gofpdf output vs the original Python; if a font/DPI detail won't port → fall back to embedded-Python reuse of fpdf2.
3. **View/preview/notes/export ride the existing webview** (godot_cef preferred, godot_wry fallback). PDFium / a from-scratch clone are NON-GOALS.
4. **Each capability independently shippable**; DCR is "done enough" after P1+P2; P4 print is opt-in (system-PDF-app is the v1 floor).

### Rubric guardrails (every task checks against these in its DoD)
1. Plugins rolling own PDF → DRY break → host.pdf is the one generator (the `blocked_by` edge enforces no embedded copy).
2. PDFium / clone → durability+reliability break → webview for view, wrapped/sidecar lib for gen.
3. Silent CEF↔WRY divergence → reliability break → capability-probe + degrade visibly.
4. Over-investing P4 Windows spool → cost break → system-PDF-app floor; direct spool opt-in.

---

## 3. Build / branch state

| Component | State |
|---|---|
| Minerva | branch **`pdf-print-substrate`** off `development` @ `73b0c821` (pushed) |
| minerva-plugins | `main` — nametag plugin not started yet (blocked by P1.1) |
| Nametag reference | `~/gitlab/minervaservices/experiments/NameTagMaker/generate_tags.py` (pixel-diff reference) |
| Plugin API docs | `~/github/minerva-plugins/docs/PLUGIN_DEVELOPER_GUIDE.md` + `PLUGIN_API_COVERAGE.md` |

Pre-existing dirty state on the branch (NOT ours, do not commit): `vendor/EIRTeam.FFmpeg`, `vendor/godot_cef`, `src/test/test_marketplace_install_start_codetools.gd.uid`.

---

## 4. Hard rules

- Per-file `git add` only. No `-A` / `.`. No `--no-verify`. **No `vendor/` touches.** No force-push, no `git reset --hard`.
- Commit co-author trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- This initiative works on the **`pdf-print-substrate`** branch (owner authorized a branch for this work, distinct from the codetools no-branch convention on `development`).
- Pre-flight before any work-cycle: clean tree + correct submodule SHAs + on the intended base; record the base SHA per task.

---

## 5. First actions for next session

1. Read this file + the FROZEN contract `Docs/design/host_pdf_contract.md`. DCR `019e809f` approved; P1.0 done.
2. Pre-flight (clean tree + correct submodule SHAs + on `pdf-print-substrate`), then work-cycle **P1.1 `019e80a0596b`** (Minerva): gofpdf sidecar implementing `host.pdf.generate`, bundled DejaVu, smoke test, pixel-diff gate vs `generate_tags.py`. Record the base SHA.
3. In parallel, start the nametag plugin's non-PDF ~90% (minerva-plugins, `019e80a0f17a`) against the frozen contract — only the `host.pdf.generate` call waits on P1.1.
