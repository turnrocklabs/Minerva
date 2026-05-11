# Bug D — Blob-split for `host.documents.get_state` / `set_state`

**Status:** Design proposal. Pending decision.
**Authors:** HITL discovery 2026-05-10 (T6 R7 follow-up). Architecture surfaced when migrated `minerva_presentation_list_slides` returned `bufio.Scanner: token too long` against a routine 50-slide deck (58 MB on disk, mostly embedded image base64).
**Blocks:** Resumption of T6 HITL. Every migrated presentation tool calls `loadDeck → mutate → saveDeck`, paying the full panel-state JSON cost over stdin per call — both directions on mutators.

## The actual problem

`host.documents.get_state` returns the entire plugin-scene panel state in one wire payload. For host-owned plugins (presentation), that state includes every embedded blob (image base64, future video/PDF thumbnails). For a typical deck — text, color, and images — the wire size is tens of megabytes.

Symptoms across three subsystems:

1. **Transport:** `bufio.Scanner` defaults to 64 KB lines; the Go plugin had it bumped to 1 MB; a 58 MB envelope blows past both. This is "Bug C" — fixable in 5 lines but it just moves the threshold, not removes it.
2. **Plugin process cost:** every tool call — even `list_slides`, which only needs `{id, title, tile_count}` per slide — pays a full deck JSON parse on read and (for mutators) a full re-serialize on write. Hundreds of ms wasted per call.
3. **LLM context safety:** today's migrated tools project the deck down before returning to the LLM, so the LLM doesn't choke. But there's no architectural guard preventing a future tool author from leaking blob content into a tool response. The risk is structural, not theoretical.

The migration is faithful to the in-process GDScript pattern (load, mutate, save). In-process that load was a pointer copy; over IPC it's a megabyte-scale JSON parse on every call. The pattern doesn't survive translation.

## Constraint: what's actually blob-shaped

In presentation: image-tile bytes (base64 PNG/JPEG). Annotation attachments. In future plugins: terminal scrollback, large CSV / spreadsheet cells, embedded PDF, video thumbnails. Common shape: **payload bytes that the plugin tool usually doesn't need to see**, but that's currently inlined into the panel-state envelope.

What's *not* blob-shaped: tile coordinates, slide titles, layout metadata, annotation envelopes (text only), aspect ratio. The bulk of plugin-tool work is metadata, not blob content.

## Options

### Option 1 — Projection arg on `get_state`

Caller passes `{fields: ["slides[*].title", "slides[*].id"]}`; broker walks the panel-state dict and returns only the requested subset.

**Pros:** One capability, one grant. Caller decides shape. No symmetric work needed on writes (mutators still pay full set_state cost — issue stays).

**Cons:** Projection grammar to design (JSON Path? Dotted? GraphQL-ish?). Server-side walker has to be generic over arbitrary plugin schemas. Doesn't fix `set_state` — the symmetric mutator problem is wholly unaddressed. Projection only helps reads.

**Verdict:** Half-measure. Solves the LLM-leak risk for reads but leaves mutators stranded.

### Option 2 — Per-plugin typed read/write capabilities

`host.documents.get_slide_metadata`, `host.documents.get_tile`, `host.documents.set_slide_title`, etc. One narrow capability per access pattern.

**Pros:** Each capability is small, auditable, easy to grant in fine-grained ways. Symmetric reads/writes. Server dispatch is trivial.

**Cons:** Every plugin schema becomes part of the host capability surface. Adding a field to a plugin schema requires a new host capability, a new manifest entry, a new grant. Capability count explodes (a deck might have 15+ caps; multi-plugin host gets unmanageable). Plugin authors can't iterate freely on their own schema — the host owns the API.

**Verdict:** Wrong layer of coupling. The host shouldn't know what a "slide" is.

### Option 3 — Generic navigation + blob split + patches (recommended)

The host treats panel state as a tree of (mostly small) JSON nodes plus opaque blob handles. Plugins navigate down with one generic `get_node`, fetch blobs only when needed, and write with JSON Patch.

**Read API:**
- `host.documents.get_state(editor_name)` — returns shallow root: top-level metadata + slide list with **handles** where blobs would have been (e.g. `image_tile: {kind: "image", blob_handle: "blob-7"}` instead of inline bytes). Bounded payload regardless of deck size.
- `host.documents.get_node(editor_name, path)` — returns the subtree at a JSON Pointer path. Still blob-stripped. Use for "read slide 3" or "read all tiles in slide 7."
- `host.documents.get_blob(editor_name, blob_handle)` — fetches blob bytes when (and only when) explicitly needed. The image-edit tool needs this; `list_slides` never calls it.

**Write API:**
- `host.documents.patch_state(editor_name, json_patch)` — applies RFC 6902 JSON Patch to the panel state. Small mutations, small wire size. Replaces today's `set_state(panel_state: ...)` for the common mutator case.
- `host.documents.put_blob(editor_name, bytes) → blob_handle` — uploads a blob, returns a handle the plugin then references in a subsequent `patch_state`.
- (Keep `set_state` available for whole-document replace; rare, but legitimate for import/restore.)

**Pros:**
- Generic — works for any plugin schema. Host doesn't learn "slide" or "tile."
- Symmetric — reads and writes both stay small.
- Blob-safe — `get_state` is bounded by metadata size, never by blob count or size. LLM-safe by construction.
- JSON Patch is RFC-standard; well-defined semantics, mature libraries on both Godot and Go sides.
- Plugin authors keep schema freedom.

**Cons:**
- Plugin's `_on_panel_save_request` must declare which keys are blobs (so the broker can substitute handles). Small per-plugin contract.
- Tools that genuinely need a blob pay a roundtrip (`get_blob`). Acceptable — they need the bytes anyway.
- Blob lifecycle: orphan handles after a patch that removes their reference need GC. Solvable with reference counting at save time (panel state is canonical; anything not referenced is orphan).
- More moving parts than Option 1.

**Verdict:** Most work, but the only option that scales past the immediate fire and survives future plugin types.

## Recommendation

**Option 3.** Bug C transport bump is still worth shipping as a safety belt (and as the bridge while D is being built), but the design work that actually unblocks HITL is D.

## Migration impact on T6's 13 migrated tools

Tools that need rework after Option 3 lands, grouped by patch complexity:

**Trivial (1-line addressing change, no other logic):**
- `list_slides` — replace `loadDeck` + walk with `get_node("/slides")`.
- `get_slide` — `get_node("/slides/<i>")`.
- `list_tiles` — `get_node("/slides/<i>/tiles")`.

**Simple mutators (read-modify-write → JSON Patch builder):**
- `add_slide`, `remove_slide`, `move_slide`, `set_slide_title`, `set_aspect`, `set_slide_background` — each becomes one or two `op: add/remove/replace/move` patches. ~10-15 lines per tool, down from current ~20.
- `add_text_tile`, `remove_tile` — same shape.
- `modify_spreadsheet_cells`, `resize_spreadsheet` — JSON Patch on cells array. Cleaner than today's read-mutate-write.

**Needs blob roundtrip:**
- `add_image_tile` (already in core, not yet migrated) — would call `put_blob` then `patch_state` with the handle.

**No-op:**
- `create_deck` — writes to disk, no state involved.

Net: most migrated tools shrink. None are deleted. The migration's "what" is correct; the "how" becomes leaner.

## Plugin-side contract (Option 3)

A plugin opting into blob-handle replacement declares blob keys in its panel's save shape. Suggested mechanism: the plugin's `_on_panel_save_request` returns state where blob values are wrapped: `{__blob__: true, content_type: "image/png", bytes: PackedByteArray}`. The broker strips the bytes, assigns a handle, stores `bytes` in a per-editor blob store keyed by handle, and replaces the wrapped value with `{__blob_handle__: "blob-N", content_type: "image/png"}` in the outbound state.

Inbound `patch_state` that includes a `{__blob_handle__: ...}` reference is resolved against the same store when the panel applies the patch. `put_blob` adds to the store with a fresh handle. Save-to-disk serializes blobs back inline.

Blob store lives at the broker (`PluginScenePanelBroker`), keyed by (editor_name, handle). Cleared on editor close.

## Resolved questions

Rubric for proposals below: reliability, performance (memory, CPU), DRY design.

### 1. JSON Patch on a tree with blob handles

**Proposal:** Single broker-side helper `validate_blob_refs(patch, blob_store)` runs once per `patch_state` call. Walks the patch ops, collects every `__blob_handle__` referenced (in `value` or `from`), verifies each exists in the editor's blob store. Unknown handle → reject the entire patch atomically with `unknown_blob_handle` error code, no partial application.

Blob lifecycle is reference-counted at the broker. Each patch op that adds a handle reference increments; each that removes a node carrying a handle decrements. Refcount hits zero → blob GC'd immediately, same call stack. `op=copy` with a handle in the source path increments — two refs to the same blob is legal (e.g. duplicating a slide).

- **Reliability:** Atomic apply (validate first, mutate second) prevents half-applied patches leaving the store inconsistent. Refcount GC prevents orphan blob accumulation across long sessions.
- **Performance:** O(patch_ops) validation; handle lookup is a dict probe. Refcount ops are O(1). No tree walks beyond what patch application already does.
- **DRY:** One validation helper, one refcount table per editor. Both live alongside the existing per-editor blob store — no new subsystem.

### 2. Concurrent mutations

**Proposal:** Inherit the broker's existing single-threaded serialization — no new locking. Godot main thread + the T2 re-entrancy guard already mean patches apply in arrival order, atomically per call. Document this invariant in `PluginScenePanelBroker.gd` next to the dispatch table; do not add an explicit lock.

Plugin authors needing multi-step transactional semantics compose multiple ops into one patch (JSON Patch is naturally batched — N ops in one call apply atomically) rather than issuing N separate `patch_state` calls.

- **Reliability:** Atomicity comes from the broker, not the plugin — plugins can't accidentally split a logical mutation. Multi-op patches give transaction semantics for free.
- **Performance:** Zero overhead — no locks acquired, no contention. Sequential application matches today's set_state behavior, which has been proven adequate.
- **DRY:** Reuses the existing single-thread invariant. No new primitive to maintain or test.

### 3. `set_state` (full replace) lifecycle

**Proposal:** Keep `set_state` available, no deprecation at code level. Docstring labels it "whole-document replace; prefer `patch_state` for incremental change." Use cases that legitimately need it: import from external format, factory reset, undo-to-checkpoint, test-fixture seeding. Plugin authors writing new tools should reach for `patch_state` by default — but the capability stays.

Don't try to express `set_state` as a giant patch — that re-creates the size problem we're fixing. Two write caps is acceptable redundancy because each serves a distinct lifecycle event.

- **Reliability:** Existing `set_state` consumers (tests, internal restore paths) keep working unchanged. No flag day.
- **Performance:** No cost — `set_state` stays the same code path it is today. Patch_state is the cheap default; `set_state` is paid only when whole-document replace is the actual semantic.
- **DRY:** Two write caps with distinct semantics is correct factoring, not duplication. Forcing `set_state` through `patch_state` would be a 58 MB JSON Patch — the same wall, reshaped.

### 4. Cap naming

**Proposal:** Four new strings in the existing `host.documents.*` family:

- `host.documents.get_node`
- `host.documents.patch_state`
- `host.documents.get_blob`
- `host.documents.put_blob`

Kept distinct (not collapsed into a wildcard `host.documents.*`) so audit logs and policy decisions surface which access shape was used. Default-granted alongside `host.documents.get_state` / `set_state` for plugins that have already declared the read/write group via manifest — same trust scope, finer log signal.

- **Reliability:** Distinct strings let the audit log answer "did this plugin read blobs?" without inferring from envelope size. Useful for incident review.
- **Performance:** Cap-string match is a dict lookup; four entries vs. one wildcard is indistinguishable.
- **DRY:** Strings live in the same `host.documents.*` namespace, alongside the existing get/set. No new namespace conventions.

### 5. Audit log shape for `patch_state`

**Proposal:** Audit entry for `patch_state` includes:

- `patch_op_count: int` — how many ops in the batch
- `patch_op_kinds: Array[String]` — unique set of ops used (`["add", "remove"]`, etc.)
- `patch_paths: Array[String]` — unique top-level paths affected (e.g. `["/slides/3/title", "/aspect"]`)
- `blob_handle_refs: Array[String]` — handles referenced in this patch
- `success: bool`

Explicitly **excluded:** patch op `value` fields, full patch body, any user content. Patch values can include slide titles (user text), annotations, even (post-`put_blob`) blob handle pointers that themselves carry no user content. Logging values would risk leaking user data into audit; the shape-only summary is enough to reconstruct "what kind of change" without leaking "what content."

- **Reliability:** Shape-only logs survive log retention/exfiltration without privacy exposure. Sufficient for debugging mutation flow and detecting anomalies (e.g. unusual op patterns).
- **Performance:** Summary extraction is O(patch_ops) and runs once per call. No JSON re-serialization of values. Audit volume is bounded by op count, not patch size.
- **DRY:** Reuses the existing `_audit(plugin_id, EVENT_CAPABILITY_DISPATCHED, ...)` channel; adds a stable schema for the dispatch's metadata dict. Same pattern as today's `EVENT_SCENE_DISPATCHED` fields.

## Work breakdown estimate

- Substrate (broker + IPC): ~3 days. Blob store, handle generation, patch_state + json-patch dispatch, plugin save-shape parsing.
- Plugin-side library helper (Go): ~1 day. `host.Patch(path, op, value)` builder, `host.GetNode`, `host.GetBlob`.
- T6 tool rework: ~1 day. Mechanical given the helpers are in place.
- Tests + cold review: ~2 days.

~7 days total. Compared to: continuing to ship migrated tools on the current shape and walking into the same wall on every subsequent plugin.

## Decisions (2026-05-10)

1. **Option 3 approved** as the direction.
2. **Filed as broker DCR phase 5.** (Sibling to phases 1–4 already shipped; T6 work-in-progress is paused, not abandoned.)
3. **T6 HITL paused** until phase 5 substrate lands. Migration tool reshaping resumes after.
