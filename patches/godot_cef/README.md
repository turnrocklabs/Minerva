# godot-cef patches

Patches applied to the `vendor/godot_cef` submodule (upstream: `dsh0416/godot-cef` pinned to `v1.13.0`) before building.

`scripts/build-godot-cef.sh` applies every `*.patch` in this directory in filename order, then builds + deploys to `src/addons/godot_cef/bin/<platform>/`.

## 0001-paste-doubling-option-a.patch

**Problem:** In CEF-hosted plugin panels, the first `Ctrl+V` after focusing any editable DOM input committed the clipboard twice, producing `TEXT+TEXT`.

**Cause:** When the user focuses an editable DOM node, the gdcef render process activates a hidden Godot `LineEdit` IME proxy. `Ctrl+V` then fires both paths at once: (a) the `LineEdit`'s native paste → `text_changed` → `ime_commit_text` into CEF, and (b) `host.send_key_event` → CEF's browser-host native `Ctrl+V` handler. The shortcut table in `crates/gdcef/src/input/mod.rs` intentionally omits plain `Ctrl+V` because upstream expected the browser host to handle it alone — but with the IME proxy active, both paths run.

**Fix (Option A):** Add a plain `Ctrl/Cmd+V` entry to `EditorShortcuts` and early-return from `handle_key_event` when `focus_on_editable_field` is true. The IME proxy becomes the sole paste sink during IME activation; outside IME activation, the browser host still handles Ctrl+V normally.

**Upstream status:** Consultant RCA confirmed on 2026-04-21 (Minerva docket discussion `019db0ba`). PR to `dsh0416/godot-cef` is a pending follow-up — when it merges and `vendor/godot_cef` is bumped past it, remove this patch.

**Trade-off:** This is Option A (tactical). The cleaner long-term fix (Option B) is to restrict the IME proxy to real composition/preedit/candidate-window integration rather than using it as a generic paste sink — but that needs CJK/IME validation which we don't currently have the environment for.
