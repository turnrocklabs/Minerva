# Plugin snapshot transport

Scene panels can use their registered `_MinervaIPC` helper's
`request_bulk(channel, payload, timeout_ms)` for document-sized exchanges with
their own backend or a granted host capability. This is an explicit route over
the existing broker and MCP connection. It creates no files, blob handles or
second copy of durable document state.

```gdscript
var ipc := get_node_or_null("_MinervaIPC")
if ipc == null or not ipc.has_method("request_bulk"):
    # Surface an unsupported-host error before attempting a large mutation.
    return
var limit: int = ipc.get_bulk_payload_limit()
var reply: Dictionary = await ipc.request_bulk(
    "my_plugin.load_snapshot", {"snapshot": document}, 120000)
```

Use ordinary requests for small control messages. Use bulk requests for both
uploading a snapshot and requesting an export: the chosen route also determines
the reply limit. Channel names still have to appear in the panel's
`ipc_channels` and manifest's `ui.ipc_messages`. Host capability grants are
checked normally. A bulk request cannot address another panel's registration.

## Bounds and lifetime

The bulk limit is **8,388,608 UTF-8 bytes** for the complete serialized argument
dictionary and, separately, the complete broker reply dictionary. Wrapper keys
count. Exceeding either returns `payload_too_large` with the limit and measured
size; replies are never truncated. An oversized reply may follow a successful
backend mutation, so callers must reconcile before retrying a mutation.

The helper allocates a distinct correlation ID per call. Success, timeout and
panel removal release its pending observer. Closing or re-registering the panel
returns `panel_unloading` to pending callers; a response from an old registration
cannot reach a new tab. A local timeout/close does not cancel backend computation
or undo a mutation. The backend connection retains its own request until reply,
connection loss or its existing 1,800-second scene request timeout.

| Hop | Contract |
| --- | --- |
| Page ↔ scene wrapper | A custom embedded page bridge is plugin-owned. It must explicitly support and bound bulk JSON in both directions, preserve request IDs, and reject oversized data. It must not put the full record back through a small control route. |
| Scene wrapper ↔ host broker | `request_bulk` enforces the 8 MiB limits above. Ordinary requests retain the legacy 65,536-character check until E3 changes control-message accounting to UTF-8 bytes. |
| Host ↔ plugin stdio backend | Existing newline-delimited MCP `tools/call`; no smaller frame cap in the Minerva connection. Native readers assemble bytes before UTF-8 decoding. JSON-RPC and MCP text wrapping can make the wire frame larger than the dictionary limit. The bulk limit is an application boundary, not a limit on allocation by the underlying reader. |
| Backend domain validation | Plugin-owned; its own record/envelope ceiling may be smaller and must be updated deliberately. Transport success does not mean the backend accepted a mutation. |
| Save/restore | `PluginScenePanelHost.invoke_save` / `invoke_load` pass the complete dictionary directly through the native panel hooks; no 64 KiB request signal. Persist the record, not a temporary IPC reference. File-capability routes have their own 8 MiB file limit. |

`host.documents.get_node/get_blob/put_blob/patch_state` remain the existing
handle-based document API. They are useful for exchanging editor assets, but
adding a blob does not automatically change a panel's backend snapshot protocol.
Bulk IPC does not create a parallel blob store or relax those capabilities'
ownership checks.

## Council adoption

Council's scene wrapper should feature-detect `request_bulk`, then use it for
load, export and snapshot-bearing command exchanges. Its custom CEF bridge must
carry the corresponding page request/reply without its old whole-record limit.
Measure encoded UTF-8 (`TextEncoder` in JavaScript,
`to_utf8_buffer().size()` in GDScript), including all envelope fields.

Council must also change its backend's deliberate 64 KiB snapshot ceiling under
its own transport/size items. The host feature alone does not fix that ceiling,
empty-panel identity adoption, or live activity UI. Keep unsupported-host errors
explicit; do not fall back to the old route for a large snapshot.

The host regression `test/test_plugin_bulk_snapshot.gd` uses a real stdio
subprocess, an unescaped Unicode snapshot over 70 KB, deliberate splitting inside
a UTF-8 character, native save/load hooks, size refusals, permission refusals,
timeout cleanup and panel replacement. Page JSON serialization is covered;
installed Council/CEF behavior remains part of the Council integration gate.
