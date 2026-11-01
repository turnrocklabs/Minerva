# godot-cef patches

Patches applied to the `vendor/godot_cef` submodule (upstream: `dsh0416/godot-cef` pinned to `v1.13.0`) before building.

`scripts/build-godot-cef.sh` applies every `*.patch` in this directory in filename order, then builds + deploys to `src/addons/godot_cef/bin/<platform>/`.

## 0003-macos-export-bundle-path.patch

Godot may load `libgdcef.dylib` from the exported app's flat
`Contents/Frameworks` directory. Resolve `Godot CEF.app` beside that dylib when
present, while retaining the source/addon layout where the app is beside the
containing `Godot CEF.framework`. Both the Chromium framework and helper
subprocess use the same resolved bundle root.

## 0001-paste-doubling-option-a.patch

**Problem:** In CEF-hosted plugin panels, the first `Ctrl+V` after focusing any editable DOM input committed the clipboard twice, producing `TEXT+TEXT`.

**Cause:** When the user focuses an editable DOM node, the gdcef render process activates a hidden Godot `LineEdit` IME proxy. `Ctrl+V` then fires both paths at once: (a) the `LineEdit`'s native paste → `text_changed` → `ime_commit_text` into CEF, and (b) `host.send_key_event` → CEF's browser-host native `Ctrl+V` handler. The shortcut table in `crates/gdcef/src/input/mod.rs` intentionally omits plain `Ctrl+V` because upstream expected the browser host to handle it alone — but with the IME proxy active, both paths run.

**Fix (Option A):** Add a plain `Ctrl/Cmd+V` entry to `EditorShortcuts` and early-return from `handle_key_event` when `focus_on_editable_field` is true. The IME proxy becomes the sole paste sink during IME activation; outside IME activation, the browser host still handles Ctrl+V normally.

**Upstream status:** Consultant RCA confirmed on 2026-04-21 (Minerva docket discussion `019db0ba`). PR to `dsh0416/godot-cef` is a pending follow-up — when it merges and `vendor/godot_cef` is bumped past it, remove this patch.

**Trade-off:** This is Option A (tactical). The cleaner long-term fix (Option B) is to restrict the IME proxy to real composition/preedit/candidate-window integration rather than using it as a generic paste sink — but that needs CJK/IME validation which we don't currently have the environment for.

## 0004-order-cef-shutdown-after-browser-close.patch

Keep CEF initialized for the extension lifetime, track every created browser,
and close and drain them during Scene-stage extension teardown before the one
final `CefShutdown`. If browser close callbacks cannot complete within the
bounded drain, terminate instead of unloading `libcef` with live callbacks.
On Windows, retain the exact loaded `libcef.dll` module for the remaining host
process lifetime after verifying the raw `cef_initialize` export's module
identity. The packaged-helper probe emits shutdown phases so CI proves browser
drain and `CefShutdown` completed before a clean process exit.

## 0005-document-navigation-lock.patch

Adds an opt-in construction-time exact initial-document lock for privileged
CEF panels. Locked instances allow their host-created file URL once, block
main-frame replacement and popups synchronously, and redact raw IPC bodies
from inspector diagnostics so document capabilities cannot enter logs. The
lock owns the exact immutable backing file and removes only that file and its
empty directory after `OnBeforeClose`; its drop path covers creation failure.

## 0006-pump-reentrancy-input-trace.patch

Applies after 0001–0005 to the exact upstream gitlink
`179d86bfc322df1df409239f331a256418d01c1a` (gdext 0.4.5). The `v1.13.0`
tag is not a substitute for that gitlink.

`CefTexture::on_process` holds a `self.base_mut()` guard only while pumping
CEF. The guard temporarily makes the Rust instance re-bindable for nested
Godot notifications; no Rust fields or helper bindings are held inside that
scope. AppKit menu actions may still run during the pump. This change removes
the observed binding conflict; it does not disable shortcuts or claim universal
FFI re-entrancy safety.

Pump/binding inventory:

- **on_process:** the Minerva-reachable pump now uses the scoped base guard.
- **CefTexture2D frame hook:** unchanged. Minerva creates `CefTexture`, whose
  helper is shut down and has its frame hook disconnected at construction.
  Direct `CefTexture2D` consumers are outside this observed abort repair.
- **0004 finalize_cef drain:** unchanged. It runs at extension teardown without
  a `CefTexture` instance binding, with the existing bounded browser-close drain
  and finalizing guard. Browser shutdown guarantees are retained.
- **_deferred_create_browser:** unchanged. It has no explicit message-loop pump,
  but holds the texture/helper bindings over synchronous browser creation.
  Native startup/open-panel behavior remains an unverified pre-existing
  boundary. A demonstrated creation callback failure needs a separate
  disposition; this patch does not claim that boundary is proven safe.

### Opt-in input trace

Set `MINERVA_CEF_INPUT_TRACE=1` before launching the diagnostic build to enable
`[MinervaCefTrace]` records. It is off by default. Use only synthetic non-secret
text, including in the password field, and close the diagnostic session before
using real credentials.

DOM `console.info` records use CEF's existing stderr logging; they are not
connected to Godot's `console_message` signal. Godot's user log alone is not a
complete trace. After the owner closes Minerva, launch the installed diagnostic
build from Terminal and capture stdout and stderr together (adjust the app path
if installed elsewhere):

```sh
mkdir -p "$HOME/Library/Logs/MinervaCefTrace"
MINERVA_CEF_INPUT_TRACE=1 /Applications/Minerva.app/Contents/MacOS/Minerva \
  > "$HOME/Library/Logs/MinervaCefTrace/session.log" 2>&1
```

Confirm `stage=dom_ready` appears in that file before interpreting a missing DOM
input event. Return only the `[MinervaCefTrace]` records and reproduction outcomes,
not the complete application log. The actual capture must be verified on the
diagnostic build; source logging configuration is not a trace receipt.

The trace records host main/sub-viewport focus-owner classes and container
focus, native texture/proxy routing, proxy editing and IME state, CEF event
kind, pressed/released state, modifier flags and a paste-chord classification.
`control`/`command`/`shift`/`alt` categories distinguish modifier down/up pairs;
all other keys are called `other`. Native sequence numbers order the forwarding
and proxy events. DOM records classify password/plain/other inputs and count
input events. They never record field values, characters, raw key codes,
scan codes, Unicode values, clipboard data, field names/IDs, document
capabilities or IPC payloads. Native and host code read key codes internally
only to classify fixed categories; DOM instrumentation never reads field
values or clipboard data. No paste or modifier-state behavior is changed.

Owner trace: focus a plain field, paste synthetic text with Cmd+V, then type
plain letters; repeat in a password field and compare chat paste. Correlate
`host_key`, `texture_input`, `proxy_gui_input`, `cef_shortcut`, `cef_send`,
`proxy_text_changed` and `dom_input` records. Missing input routes, a proxy with
editing=false, suppressed paste with no proxy commit, or Command/Control flags
remaining on later non-modifier events distinguish the current hypotheses.
Return the evidence before choosing any paste fix. Preserve the existing
first-paste-exactly-once regression.

The owner reproduced the unpatched abort with one Ctrl-Cmd-F keypress
(report `Minerva-2026-11-01-004024.ips`). After the producer build and owner
installation, verify Ctrl-Cmd-F, Globe-F, Cmd-M and Cmd-Q with two HTML panels
open, plus startup/open-panel and shutdown observations. These native checks,
producer/compiler/Clippy evidence, matching-host Godot analyzer/GATE-W and
Windows/Linux CI build/smoke remain pending; a source review is not acceptance.
