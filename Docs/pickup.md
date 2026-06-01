# Pickup

## ⏵ CURRENT PHASE (Session 2 — 2026-06-01, Linux)

The **in-app nametag editor is BUILT + verified**, committed **LOCALLY (NOT pushed)**. This session: N1 spike→rasterize · N2 `.mtags` preview+annotate editor · N2.5 annotation binding (core `AnnotationOverlay` host-transform seam) · N3 live render (`nametag.render` IPC → `host.pdf.generate` → `pdftoppm`) · N4 `build_from_sheet` (spreadsheet→`.mtags`) · N6 shipped skill **"Nametag Maker"** (in manifest `skills[]`).

End-to-end gap analysis (do the WHOLE student scenario inside Minerva, no host shell): need (a) a cross-platform **`.docx` DATA reader**, (b) **nametag richness** — generic front/back faces + free image placement. Filed in the `minerva` docket: **DCR `019e8547775c`** (docx reader) + proof `019e8547f0f6`; plugin gaps **`019e854798`** (generic faces) + **`019e8547b7`** (image placement); plus CAD-leak bug `019e85329a1b`.

**ALL of §7 steps 1–4 are DONE (2026-06-01). The whole "make student name tags from a .docx, inside Minerva, over MCP" scenario passed live acceptance — docx reader + generic back faces + free image placement + skill + the end-to-end run. DCR `019e8547775c` shipped. REMAINING: push the LOCAL commits when ready; optional N3-push / N5 packaging / promote skill to repo master.dct.**

---

STATE: `Substrate (P1.0/P1.1/P1.2) DONE + LIVE-VALIDATED end-to-end on macOS. Nametag plugin R1+R3 DONE. Drove minerva_nametag_maker_nametag_generate over MCP in a real Minerva session → returned a 2-page %PDF (byte_size 31551) — proving the WHOLE chain: MCP → plugin backend → host.pdf.generate → broker → live sidecar spawn → gofpdf. Three install/runtime bugs found+fixed today (see §6). REMAINING: (a) the HTML PANEL UI click-through (preview/save/HITL) is UNTESTED — only the backend tool was driven via MCP; (b) R2 spreadsheet import (optional — panel uses CSV paste); (c) R4 build/package/registry for marketplace. RESUMING ON LINUX: rebuild BOTH gitignored per-platform binaries FIRST (see §5).`

Last updated 2026-06-01 (Session 2, Linux — in-app editor built; next = docx reader + plugin gaps; see §7). [Session 1 below: end of macOS session.]

> **THIS FILE IS THE AUTHORITATIVE CROSS-MACHINE RESUME DOC.** The docket DB (`Docs/minerva.dct`) is **gitignored** and local to the macOS machine — docket items/comments may NOT be present on Linux. Everything needed to resume is captured here in pickup.md (which travels via git). Docket IDs are listed for reference if the DB is synced.

> **Session-1 work pushed**; **Session-2 commits (§7) are LOCAL / NOT pushed** — push when the owner says. (Session-1: Minerva `pdf-print-substrate` + minerva-plugins `main` pushed; see §6.)

> **Branch-scoped pivot.** This `pickup.md` belongs to the **`pdf-print-substrate`** branch (off `development` @ `73b0c821`). `development` stays focused on **codetools** — its P1.4 (visualizer panel HITL) is PARKED, state preserved in docket kb `019e7f366d99` + memory `project_codetools_extraction.md`. Do NOT merge this pickup back to `development`.

---

## TL;DR

New initiative: **add a document-output subsystem (PDF generation, view, export, print) to Minerva**, then build a **standalone nametag-maker marketplace plugin** as its first consumer. Came out of a goal to port `~/gitlab/minervaservices/experiments/NameTagMaker` (a Python fpdf2 script → duplex cardstock name-tag PDF) into a Minerva plugin — but Minerva already imports .xlsx natively, so the plugin's only real need is **PDF generation**, which we're putting in the substrate.

Governing DCR `019e809f` (`minerva` docket, **approved**). The plugin is a **standalone** work_item, NOT a DCR child — connected only by `blocked_by P1.1`.

The whole plan was designed against the project rubric (reliability → durability → cost → readability → DRY → well-factored). Read the DCR description — it carries the locked decisions, the rubric guardrails, and the phasing.

---

## 0. Status — substrate + plugin backend DONE & LIVE-VALIDATED

The PDF substrate (P1.0 contract → P1.1 gofpdf sidecar → P1.2 broker wiring) is complete, and the nametag plugin's backend + panel (R1 + R3) are built. **The end-to-end path is proven live on macOS:** a real Minerva session ran `minerva_nametag_maker_nametag_generate` over MCP and got back a valid 2-page duplex `%PDF`. That exercises every layer including the previously-unproven P1.2 live sidecar spawn.

**What is NOT yet validated / done (the actual next work):**
1. **The HTML panel UI click-through** — preview (PDF.js render), the Save flow (file_picker→grant_scope→files.write), and the HITL print-acceptance states have NOT been exercised by a human. Only the *backend tool* was driven via MCP. Open Minerva → Open Panel "nametag_panel" → generate/preview/save and confirm each works (esp. PDF.js render under the active webview, and the save dialog).
2. **R2 — spreadsheet import** (`mcp.proxy:minerva_get_spreadsheet_data`): optional. The panel currently takes pasted CSV / `rows`; wiring xlsx-from-an-open-spreadsheet is a nice-to-have, not required to make tags.
3. **R4 — build/package/registry**: cross-compile the plugin per-platform, tarball (binary + manifest + ui/ + SHA256SUMS), add to `registry.json` so it's marketplace-installable. (See `presentation`'s `.github/workflows/presentation.yml` for the packaging recipe.)

Done items (docket IDs for reference; DB may be macOS-local): P1.0 `019e80a0293d`, P1.1 `019e80a0596b`, P1.2 `019e80a06854`. Nametag plugin `019e80a0f17a` (in_progress: R1+R3 done).

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
| Minerva | branch **`pdf-print-substrate`** off `development` @ `73b0c821` (pushed). Sidecar at `src/sidecars/host_pdf/`; broker wiring in `CapabilityBroker.gd`. |
| minerva-plugins | `main` (pushed). Plugin at `nametag-maker/` (Go backend + `ui/nametag_panel.html`). Plugin id is **`nametag_maker`** (underscore; dir is `nametag-maker`). |
| **Binaries (gitignored — REBUILD on Linux)** | sidecar `src/bin/minerva-host-pdf-<plat>` (via `scripts/build-host-pdf.sh`); plugin `nametag-maker/nametag-maker-plugin` (via `cd nametag-maker && go build -o nametag-maker-plugin .`). |
| Nametag reference | `~/gitlab/minervaservices/experiments/NameTagMaker/generate_tags.py` (pixel-diff oracle) |
| Plugin API docs | `~/github/minerva-plugins/docs/PLUGIN_DEVELOPER_GUIDE.md` + `PLUGIN_API_COVERAGE.md` (both carry a `host.pdf.generate` row now) |

Pre-existing dirty state on the branch (NOT ours, do not commit): `vendor/EIRTeam.FFmpeg`, `vendor/godot_cef`, `*.uid` files under `src/test/`. The docket DB `Docs/minerva.dct*` is gitignored churn.

---

## 4. Hard rules

- Per-file `git add` only. No `-A` / `.`. No `--no-verify`. **No `vendor/` touches.** No force-push, no `git reset --hard`.
- Commit co-author trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- This initiative works on the **`pdf-print-substrate`** branch (owner authorized a branch for this work, distinct from the codetools no-branch convention on `development`).
- Pre-flight before any work-cycle: clean tree + correct submodule SHAs + on the intended base; record the base SHA per task.

---

## 5. Linux resume — exact steps

1. **Pull both repos.** Minerva: `git checkout pdf-print-substrate && git pull`. minerva-plugins: `git checkout main && git pull`.
2. **Rebuild BOTH binaries** (gitignored, per-platform — they do NOT travel via git):
   - Sidecar: `cd ~/github/Minerva && scripts/build-host-pdf.sh` → produces `src/bin/minerva-host-pdf-linux`. (Go ≥1.25; `go-pdf/fpdf` resolves to v0.9.0 — do NOT pin v1.4.x, it's retracted.)
   - Plugin backend: `cd ~/github/minerva-plugins/nametag-maker && go build -o nametag-maker-plugin .`
   - Sanity: `cd ~/github/Minerva/src/sidecars/host_pdf && go test ./...` and same in the plugin dir — all green.
3. **Run Minerva** from the editor on `pdf-print-substrate` (the broker resolves the sidecar as `res://bin/minerva-host-pdf-linux` via `OS.get_name()`).
4. **Install + grant + open the plugin:** install `~/github/minerva-plugins/nametag-maker/manifest.json`; grant its 4 capabilities (`host.pdf.generate`, `host.dialogs.file_picker`, `host.permissions.grant_scope`, `host.files.write`); Open Panel "nametag_panel".
5. **Do the UI click-through** (the untested part — item §0.1): paste CSV / upload icon → Generate → confirm **PDF.js preview renders** (WRY/WebKit is the likely Linux webview — the panel uses the legacy UMD build specifically for this; first real WebKit confirmation) → Save → confirm the save dialog + write → HITL Accept. Report any failure; fold into a fix round.
   - Quick backend smoke without the UI: drive `minerva_nametag_maker_nametag_generate` over Minerva's MCP (worked on macOS — returns `{success:true, page_count:2, bytes_b64:"JVBER..."}`).
6. Then tackle **R4 packaging** (and optionally **R2 import**) per §0.

### Hard rules still apply
Per-file `git add` only; co-author trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`; no `vendor/` touches; work on `pdf-print-substrate` (Minerva) and `main` (minerva-plugins, its convention). Don't commit the gitignored binaries or `.import`/`.uid`/`minerva.dct` churn.

---

## 6. Session log (macOS, 2026-06-01) — what got built + bugs fixed

**Commits (all pushed):**
- Minerva `pdf-print-substrate`: `c4f9e581` P1.0 contract · `7b856a67` P1.1 sidecar+fonts+tests · `a06432a3` P1.1 pixel-diff gate · `d05d665b` P1.2 broker wiring+audit redaction · `8d2f15d2` fix: host.pdf.generate added to PluginDefinition allowlist · `fc2e0c91` fix: sidecar startup-panic (explicit object InputSchema) · plus pickup/docs commits.
- minerva-plugins `main`: `9b13ac4` R1 backend spine · `0e12e7e` R3 HTML+PDF.js panel + backend-driven save · `e989619` fix: plugin id `nametag-maker`→`nametag_maker` + panel tool prefix · `45bbe98` docs: guide capability rows.

**Three bugs found at first real install/run, all fixed:**
1. Plugin `id` rejected dashes (`PluginDefinition` requires `[a-z0-9_]`) → renamed id to `nametag_maker` (panel tool name became `minerva_nametag_maker_nametag_generate`). The Go module path / dir / binary keep the dash (filenames are unaffected).
2. `host.pdf.generate` rejected at install — `PluginDefinition.ALLOWED_HOST_CAPABILITIES` is a SEPARATE allowlist from the broker's dispatch and lacked it. Added + a regression check in `test_host_capability_pdf.gd`.
3. **Sidecar panicked on startup** (`AddTool: input schema must have type object`) → exited immediately → every spawn was broker "Can't connect". Cause: `mcp.AddTool` inferred a non-object schema from the `json.RawMessage` input type. Fix: explicit `InputSchema: &jsonschema.Schema{Type:"object"}`. Added `server_test.go::TestRegisterToolsNoPanic` (the `Generate()` unit tests bypassed the MCP server, so they never caught it).

**Key design facts to remember:**
- host.pdf.generate capability `args` ARE the doc directly (top-level `defaults`/`metadata`/`images`/`pages`), NOT wrapped in `{doc:…}`.
- Save MUST be backend-driven: the webview `pluginIPC` channel caps payloads at 64 KiB (`PluginWebviewBroker.MAX_PAYLOAD_BYTES`), so a real PDF's base64 can't cross it. `nametag_save` regenerates server-side and does file_picker→grant_scope→files.write; `minerva.call` (HTTP) and backend capability calls have no such cap.
- `host.dialogs.file_picker` wants `filters` as an Array of String in FileDialog format (`"*.pdf ; PDF Files"`), NOT objects.
- Name shrink uses the contract `fit` (gate-proven to match fpdf2), not the legacy floor/floor-1 quirk — correct for a new tool.
- gofpdf nuance saved (macOS nudge only; recorded here for Linux): `go-pdf/fpdf@latest` = v0.9.0 (v1.4.x retracted); has all needed APIs.

---

## 7. SESSION 2 (2026-06-01, Linux) — in-app editor built; NEXT = docx reader + plugin gaps

### What got built (committed LOCAL, NOT pushed)
- **Minerva `pdf-print-substrate`:** `daa5654e` — `AnnotationOverlay` now consumes a host view-transform + zoom + `view_changed` (backward-compatible CORE seam; lets a scaled/scrolled host bind annotations). Ran annotation suites green.
- **minerva-plugins `main`:** `3c850e1` `.mtags` preview+annotate editor · `0b50d67` live render (`nametag.render` IPC) · `8a18aef` `build_from_sheet` (spreadsheet→`.mtags`) · `fb226b9` ship skill in manifest · `f2fdb98` declare plugin tools in manifest `tools[]` (so the skill's deps resolve) · `8392d0d` rename skill → "Nametag Maker".
- Memory: `project_nametag_inapp_editor.md`. The editor is a **PREVIEW+ANNOTATE surface (NOT a data form)**: rasterized PDF (pdftoppm; CEF dropped), annotations page-anchored + semantic (`anchored_to: "tag: <name>"`), `.mtags` host_owned doc, data home = a Minerva spreadsheet via `build_from_sheet`.

### The gap (why the scenario isn't fully in-Minerva yet)
Producing the camp tags used HOST tools (Read/Python/Bash) a production agent doesn't have. To do it ALL over MCP:
- **DOCX reader** [DCR `019e8547775c`, proof `019e8547f0f6`]: teacher data is `.docx` (a Word TABLE); Minerva imports only csv/tsv/xlsx/.minsheet. DECISION: **core GDScript `ZIPReader`+`XMLParser` → `minerva_read_document` {text,tables,images}** (zero deps, cross-platform; general infra not domain → core OK). VIEWING a docx (needs libreoffice/word) is OUT (not cross-platform) → deferred. [hint `ingest/docx-ingestion-approach`]
- **nametag generic front/back faces** [`019e854798`]: `build_from_sheet` `back_mode` is only `blank|same` — no distinct back (schedule). Renderer already supports per-row front/back; **EXPOSE it**.
- **nametag free image placement** [`019e8547b7`]: size/rotate/translate images anywhere; `build_from_sheet` is text-only. Add a placed-image primitive to faces + expose images; **VERIFY `host.pdf` `draw_image` rotation** (add if absent).

### ORDER OF OPERATIONS — steps 1–3 DONE (2026-06-01), step 4 PENDING
1. ✅ **DOCX work** — DCR `019e8547775c` (→ reviewing) + proof `019e8547f0f6` (→ done). Core `minerva_read_document(path)→{text,tables,images}` via `OOXMLReader.gd` (pure `ZIPReader`+`XMLParser`, zero deps). Each table carries a clean `csv` (collapses Word's wrapped headers) → pipe into `minerva_create_spreadsheet_editor`. 30/30 tests incl. real 61-student roster. **Commit Minerva `cc78d90c`.** Reference: `Docs/design/docx_proof_reference.gd`.
2. ✅ **Plugin gap fills** — `019e854798` + `019e8547b7` (both → done).
   - Faces: `build_from_sheet` now takes `shared_back` (one constant back, e.g. a schedule) + `back_mapping` (per-row back). **Plugin `737cf1e`.**
   - Images: `host.pdf` `draw_image` gained `angle` (rotation about center, CW-positive). **Core `3f82c6eb`** (sidecar rebuilt). Plugin `Face.Placed` free placement (inches+rotation), exposed via `faceArgs.images[]` and `build_from_sheet` `icon_path`/`images[]`/`front_images`/`shared_back.images`. **Plugin `c3d23cc`.**
3. ✅ **Skill update** — "Nametag Maker" skill now lists `minerva_read_document` in `tool_deps`, steps cover the `.docx`→csv→sheet path + two-sided + logo, system_prompt §1/§4 updated. **Plugin `80d269c`.** (Re-seed happens on reinstall — step 4.)
4. ✅ **Test within Minerva** — **ACCEPTANCE PASSED live over MCP (2026-06-01).** Drove the whole camp scenario in a running Minerva: `minerva_read_document` on the real `.docx` → 61 students → `minerva_create_spreadsheet_editor(csv)` "Camp Roster 2026" → `get_spreadsheet_data(json)` → `build_from_sheet` (front mapping + `back_mapping` per-row schedule, `preview_first_only`) → 2-page `.mtags` → `minerva_open_file` (nametag_editor panel, live AnnotationHost confirmed) → `nametag_save(rows_path, layout=detailed)` → **16-page** `~/temp3/camp_lanyards_2026.pdf` (no dialog). No host shell/Python anywhere. DCR `019e8547775c` → **shipped**.

### Step 4 launch checklist (for re-runs — was used to bring the app up)
The core changed (new `minerva_read_document` tool + global class cache + rotated sidecar) AND the plugin manifest changed (new skill deps/steps), so a plain reconnect is not enough:
1. **Launch Minerva** from the Godot editor on `pdf-print-substrate` (loads the new core — the class cache `src/.godot/global_script_class_cache.cfg` already has `OOXMLReader`/`MCPDocumentTools`; sidecar `src/bin/minerva-host-pdf-linux` already rebuilt; plugin binary `nametag-maker/nametag-maker-plugin` already rebuilt).
2. **Reinstall** the plugin (manifest changed → reinstall re-seeds the skill): `minerva_plugin_install` with `~/github/minerva-plugins/nametag-maker/manifest.json`, then `minerva_plugin_start` id=`nametag_maker`.
3. **`/mcp` reconnect** (new core tool + plugin schema changes — else nested args mis-pass).
4. Verify: `minerva_read_document` is registered (tool count was 256 at boot) and `minerva_nametag_maker_nametag_build_from_sheet` accepts `shared_back`/`front_images`. Then drive the scenario (the camp `.docx` is at `/home/imran/Downloads/2026 Explorer Family Camp - student info for lanyards.docx`).

### Commits this session (LOCAL, unpushed) — Minerva `pdf-print-substrate`: `cc78d90c` (docx reader), `3f82c6eb` (host.pdf rotation). minerva-plugins `main`: `737cf1e` (faces), `c3d23cc` (images), `80d269c` (skill).

### Gotchas to respect during the work (all saved as docket hints)
- **BEFORE opening any plugin `godot_scene` panel** after editing its `.gd`: parse-check headless — `godot --headless --path src --check-only --script <abs plugin .gd>` — a parse error **CRASHES the whole app**. [`godot/preflight-parse-check-plugin-scripts`]
- After a **CORE `.gd` change a plugin references**: **RESTART Minerva** (load new core) BEFORE opening the plugin, else parse-error crash. [`plugin/core-change-restart-before-plugin-that-depends-on-it`]
- `minerva_open_file` is **IDEMPOTENT**: to load an edited scene script, **CLOSE the tab then reopen**. [`godot/plugin-scene-script-reload-needs-tab-close`]
- After any plugin **tool-SCHEMA change**: user must **`/mcp` reconnect** or nested args stringify. [`project_nametag_faces_capability`]
- A plugin **skill whose `tool_deps` reference the plugin's OWN tools** must declare them in `manifest tools[]` or the skill is HIDDEN from the picker. [`plugin/plugin-skill-deps-on-own-tools-need-manifest-tools`]
- Plugins ship skills in **`manifest.skills[]`** (NOT `minerva_skill_create`, which writes the user's `master.dct`). [`plugin/plugins-ship-skills-in-manifest`]
- Annotation overlay now reads `get_annotation_view_transform()`/`get_annotation_zoom()`/`view_changed` from the host. [`annotations/host-view-transform-seam`]
- **Push:** Session-2 commits are LOCAL — push only when the owner says.

### Reference
Docket epic `019e80a0f17a` (nametag): N1/N2/N2.5/N4/N6 **done**, N3 in_progress (live-render pull done; auto-render-on-load deferred), N5 packaging backlog. New: DCR `019e8547775c` (+proof `019e8547f0f6`), plugin gaps `019e854798`/`019e8547b7`, CAD-leak bug `019e85329a1b`. Memory: `project_nametag_inapp_editor`, `project_editor_pane_grid_is_variable`, `feedback_generated_artifact_editors_are_preview_annotate`.
