# Pickup

STATE: `PDF & Printing substrate DCR filed + approved; nametag-maker plugin filed (blocked by P1.1). Next: P1.0 — draft the host.pdf.* contract (direct + HITL).`

Last updated 2026-06-01.

> **Branch-scoped pivot.** This `pickup.md` belongs to the **`pdf-print-substrate`** branch (off `development` @ `73b0c821`). `development` stays focused on **codetools** — its P1.4 (visualizer panel HITL) is PARKED, state preserved in docket kb `019e7f366d99` + memory `project_codetools_extraction.md`. Do NOT merge this pickup back to `development`.

---

## TL;DR

New initiative: **add a document-output subsystem (PDF generation, view, export, print) to Minerva**, then build a **standalone nametag-maker marketplace plugin** as its first consumer. Came out of a goal to port `~/gitlab/minervaservices/experiments/NameTagMaker` (a Python fpdf2 script → duplex cardstock name-tag PDF) into a Minerva plugin — but Minerva already imports .xlsx natively, so the plugin's only real need is **PDF generation**, which we're putting in the substrate.

Governing DCR `019e809f` (`minerva` docket, **approved**). The plugin is a **standalone** work_item, NOT a DCR child — connected only by `blocked_by P1.1`.

The whole plan was designed against the project rubric (reliability → durability → cost → readability → DRY → well-factored). Read the DCR description — it carries the locked decisions, the rubric guardrails, and the phasing.

---

## 0. What to do next session — P1.0 (critical path, DIRECT + HITL)

**Draft the `host.pdf.*` capability contract** — docket `019e80a0293d` (status: open). Design-only; the API both the sidecar AND the nametag plugin code against. Freezing it is what lets P1.1 and the plugin build in parallel. I draft → owner signs off.

The contract must cover at minimum the primitives the existing `TagRenderer` uses (derived from `~/gitlab/minervaservices/experiments/NameTagMaker/generate_tags.py`):

- `new_doc`
- `add_page(Letter, unit=pt)`
- `set_font(bundled TTF, regular/bold, size)`  — DejaVuSans/-Bold must be BUNDLED (the script's hardcoded `/usr/share/fonts/...` path is the one guaranteed mac/Windows crash)
- `draw_text(x, y, align)`
- `draw_image(png, x, y, w)`
- `draw_line` · `draw_rect`
- `output → bytes` (base64)

Specify: exact arg field names, the `{success, result}` return envelope (broker convention), units (points), font-handle model, PNG input shape. Crop marks / duplex column-reversal / registration offsets are coordinate math that lives in the PLUGIN, not host.pdf — keep the surface minimal.

After P1.0 is signed off: split into two parallel tracks — **work-cycle P1.1** (Minerva repo) and **start the plugin's non-PDF ~90%** (minerva-plugins repo) against the frozen contract. Only the plugin's last mile (the render call) waits on P1.1.

---

## 1. The docket tree (all in the `minerva` project, prefix MNR)

- **DCR `019e809f`** — "Support printing & PDFs in Minerva" (approved). Design of record: decisions, rubric guardrails, non-goals, architecture, phasing, open questions.
- Phase children:
  - **P1 `019e809fb22f`** — Precise PDF generation (`host.pdf.*`). [critical path]
  - P2 `019e809fc888` — View & preview (webview): pageable read-only PDF + PDF-as-note. [stub]
  - P3 `019e809fd8fc` — Export a view to PDF (`host.export.pdf`). [stub]
  - P4 `019e809fe9a3` — Print (`host.print`) — OPT-IN. [stub]
- P1 grandchildren:
  - **P1.0 `019e80a0293d`** — define host.pdf.* contract. **OPEN — do this next.**
  - **P1.1 `019e80a0596b`** — host.pdf MVP (gofpdf sidecar + nametag primitives + bundled fonts + smoke test + pixel-diff gate). **The plugin's blocker.**
  - P1.2 `019e80a06854` — broker wiring + audit + permissions. [stub]
  - P1.3 `019e80a0789e` — richer draw primitives. [stub]
  - P1.4 `019e80a0855e` — plugin-guide section. [stub]
- **Nametag-maker plugin `019e80a0f17a`** — STANDALONE work_item, `blocked_by P1.1`. Repo `minerva-plugins`. Buffer pipeline (xlsx→spreadsheet→.mtags→PDF), HTML+PDF.js viewer, HITL physical-print acceptance.

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

1. Read this file. The docket tree is filed; DCR `019e809f` is approved.
2. Start **P1.0 `019e80a0293d`**: draft the `host.pdf.*` contract (primitives listed in §0), get owner sign-off. DIRECT + HITL — no sub-agents for the contract.
3. On sign-off: work-cycle **P1.1 `019e80a0596b`** (Minerva) and start the nametag plugin's non-PDF 90% (minerva-plugins) in parallel against the frozen contract.
