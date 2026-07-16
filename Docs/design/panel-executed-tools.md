# Panel-Executed Plugin MCP Tools — R0 Contract

DCR `019f6c3d0e3d` (approved 2026-07-16). Owner directive: *"I don't want
Minerva aware of PCB workflows in any way. It really should be 100% the
plugin's code."* Serial plan (umbrella `019f6c4562`): R0 (this doc,
`019f6c45a279`) → C1 dispatcher (`019f6c45b614`) → C2 pcb wave 1
(`019f6c45f09e`) → C3 pcb wave 2 + core deletion (`019f6c4604ba`) → C4 refine
loop (`019f6c464ff0`) → C5 explicit-propose (`019f6c465fd8`) → C6 second-plugin
proof (`019f6c469422`). Campaign mode: fully autonomous, deferred HITL —
every deferred human check gets an automated proxy in
`Docs/design/panel-tools-hitl-debt.md`; ONE consolidated acceptance session at
the end. Decisions scored on the owner's 7-axis rubric
(reliability/durability/performance/debuggability/cost/discoverable/user-visible).

## 1. Spike findings (2026-07-16, file:line evidence)

**(a) Where plugin tools dispatch today.**
`MinervaMCPServer._execute_tool_impl` → `PluginToolRegistry.is_plugin_tool()`
→ `handle_tool_call` (PluginToolRegistry.gd:287): resolve plugin by
`_plugin_by_tool` → **require plugin subprocess RUNNING** → policy/audit →
`conn.call_tool()` to the subprocess → `_process_capability_requests` → stderr
drain. Tool sources: `register_plugin_tools` (manifest-declared, exact names,
:115) and `register_backend_tools` (discovered, `_backend_name` mapping, :595).

**(b) Host/panel resolution.**
`MCPPcbPanelTools._resolve_host` (:1413) is one line:
`AnnotationHostRegistry.get_host(editor_name)` — global and plugin-agnostic,
with `_no_host_error` (:1421) listing known editors (an error-UX convention to
keep). But AnnotationHostRegistry is annotation-substrate-specific; not every
scene panel has a host. `PluginScenePanelBroker` (register_panel :301,
get_panel_owner :437, editor_name-keyed blob store) tracks live panels and is
the general seam.

**(c) Manifest/validation/persistence impact.**
- Parse is loose: `PluginDefinition.gd:634-636` keeps whole tool dicts;
  `validate()` only enforces the `minerva_<id>_` prefix (:427-434). Unknown
  fields are NOT rejected → adding `executor` is back-compat safe.
- **The choke point**: `PluginToolRegistry.register_plugin_tools`
  (PluginToolRegistry.gd:160-165) rebuilds each entry keeping only
  name/description/input_schema/source — it would silently DROP `executor`.
  C1's registry change lands here.
- PluginDB round-trips tool dicts verbatim (`to_dict` :334 / `from_dict`
  :634-636) → `executor` persists automatically once kept.
- **Gotcha**: `.gd`/`.tscn` hot reload (PluginManager.gd:1383, :1430) does NOT
  re-parse the manifest; a manifest `executor` edit on an installed plugin
  requires reinstall/rebuild (PluginManager.gd:418-424 path). Migration rounds
  must reinstall the pcb plugin for live acceptance; MCP clients need `/mcp`
  reconnect to see moved tools (known registry-refresh gotcha).
- tools/list flow (singleton_object.gd:658-680 → MCPManager.gd:671 →
  MinervaMCPHttpServer._handle_tools_list :283-295) carries
  name/description/input_schema only — panel tools flow identically, no change.
- No tool-count CI guard exists. Watch: `scripts/run-functional-tests.sh`
  `--pcb-guard` tier and `scripts/check-no-codetools-bleed.sh` (module-migration
  guards, not counters).

**(d) Migration table.** §3 below — 21 tools in MCPPcbPanelTools.gd, every one
migrates; helper disposition in §4.

## 2. Contract

### Manifest
`tools[]` entries gain an OPTIONAL field:

```json
{ "name": "minerva_pcb_get_components", "description": "…",
  "input_schema": { … }, "executor": "panel" }
```

- `executor`: `"panel"` | `"backend"`; absent ⇒ `"backend"` (full back-compat).
- `PluginDefinition.validate()` rejects any other value
  (`tool_executor_invalid:<name>`).
- Name prefix rule, schema-as-source-of-truth, and tools/list surfacing are
  unchanged.

### Dispatch (the ONLY core logic, generic forever)
In `PluginToolRegistry.handle_tool_call`, after step-1 plugin resolution, when
the registry entry carries `executor == "panel"`:

1. **No subprocess requirement.** Panel tools run host-side; the RUNNING check
   is skipped (this also removes the backend-stopped failure mode for these
   tools — rubric: reliability, user-visible).
2. **Resolve the live panel** from `args.editor_name` (REQUIRED for panel tools
   in v1; structured `editor_name_required` otherwise): primary lookup via the
   scene-panel broker's editor registry (C1 adds a
   `get_panel_for_editor(editor_name)` accessor if absent); fallback
   `AnnotationHostRegistry.get_host(editor_name).get_panel()` duck-typed.
   Miss ⇒ `editor_not_found` error listing known editors (keeps the
   `_no_host_error` UX).
3. **Ownership check**: the resolved panel must belong to the tool's plugin
   (broker `get_panel_owner`) — a pcb tool can never execute against another
   plugin's panel.
4. **Duck-typed execution**: `await panel.handle_tool(tool_name, args)` —
   async-capable (route tools await the worker). Missing method ⇒
   `panel_no_handler`; a returned `{}` or non-Dictionary ⇒ `tool_unhandled`.
   The plugin's return Dictionary is the tool result verbatim (plugins own
   their envelopes; existing `_ok/_err` shapes migrate with the tools).
5. **Policy/audit**: same audit events as backend dispatch
   (`tool_call_dispatched`/`tool_call_result` with `executor: "panel"` in the
   payload — debuggability axis). Capability gating is unchanged: panel code
   already runs host-side under the plugin's granted capabilities; the
   dispatch-boundary policy is plugin-installed-and-not-disabled, exactly as
   for backend tools.

### Plugin-side convention
One entry point per scene panel: `func handle_tool(tool_name: String,
args: Dictionary) -> Dictionary` (may await). pcb implements it in a new
`pcb/ui/panel_tools.gd` (preloaded by PCBPanel; internal match dispatch;
host/model/spatial helpers move here or to their natural owners per §4). The
panel root forwards. No `class_name` (off-tree rule).

### Explicit non-goals (v1)
- Editor-independent panel tools (no `editor_name`): not supported; revisit
  only with a concrete need.
- Streaming/progress from panel tools: same non-support as backend tools today.

## 3. Migration table (spike d, verbatim)

| name | handler:line | touches | wave | target |
|------|--------------|---------|------|--------|
| minerva_pcb_set_board_size | `_set_board_size`:419 | data.set_board_size | W1 | ui/panel_tools.gd (model op) |
| minerva_pcb_get_components | `_get_components`:429 | data.components | W1 | ui/panel_tools.gd (model op) |
| minerva_pcb_get_nets | `_get_nets`:451 | data.nets | W1 | ui/panel_tools.gd (model op) |
| minerva_pcb_get_pin_position | `_get_pin_position`:465 | comp.get_pin_world_position | W1 | ui/panel_tools.gd (model op) |
| minerva_pcb_pin_info | `_pin_info`:514 | host.pad_at/pin_info | W1 | ui/panel_tools.gd → host |
| minerva_pcb_add_component | `_add_component`:552 | data.new_component/add | W1 | ui/panel_tools.gd (model op) |
| minerva_pcb_move_component | `_move_component`:618 | data.move_component | W1 | ui/panel_tools.gd (model op) |
| minerva_pcb_move_relative | `_move_relative`:634 | spatial.interpret_relative_move | W1 | ui/panel_tools.gd → host/spatial |
| minerva_pcb_rotate_component | `_rotate_component`:665 | data.rotate_component | W1 | ui/panel_tools.gd (model op) |
| minerva_pcb_delete_component | `_delete_component`:691 | data.remove_component | W1 | ui/panel_tools.gd (model op) |
| minerva_pcb_connect_net | `_connect_net`:706 | data.connect_pin_to_net | W1 | ui/panel_tools.gd (model op) |
| minerva_pcb_spatial_query | `_spatial_query`:738 | spatial.get_components_near | W1 | ui/panel_tools.gd → host/spatial |
| minerva_pcb_describe_component | `_describe_component`:771 | spatial.describe_component_context | W1 | ui/panel_tools.gd → host/spatial |
| minerva_pcb_import_csv | `_import_csv`:807 | data.from_csv | W1 | ui/panel_tools.gd (model op) |
| minerva_pcb_export_csv | `_export_csv`:818 | data.to_csv | W1 | ui/panel_tools.gd (model op) |
| minerva_pcb_import_footprint_geometry | `_import_footprint_geometry`:825 | comp.load_pad_geometry | W1 | ui/panel_tools.gd (model op) |
| minerva_pcb_get_change_journal | `_get_change_journal`:789 | data.change_journal | W2 | ui/panel_tools.gd (model op) |
| minerva_pcb_import_trace_geometry | `_import_trace_geometry`:880 | data traces/vias | W2 | ui/panel_tools.gd (model op) |
| minerva_pcb_export_trace_geometry | `_export_trace_geometry`:945 | data traces/vias | W2 | ui/panel_tools.gd (model op) |
| minerva_pcb_get_image | `_get_image`:990 | host.render_content_to_image | W2 | ui/panel_tools.gd → panel/host |
| minerva_pcb_apply_route_hints | `_apply_route_hints`:1068 (async) | host.run_router + proposals + materialize (incl. delete-on-commit contract, de244127) | W2 | ui/panel_tools.gd → host |

## 4. Helper disposition

- **Dispatcher-generic** (`_reg`:362, `handle`:370, `_resolve_host`:1413,
  `_no_host_error`:1421, `_ok`:1498, `_err`:1504): resolution + error UX move
  into the C1 generic dispatcher; `_ok`/`_err` envelope builders migrate
  plugin-side with the tools (plugins own envelopes).
- **Host-access** (`_get_data`:1430, `_get_spatial`:1437, `_resolve_data`:1445):
  plugin-side, into panel_tools.gd.
- **Route-workflow cluster** (`_run_router`:1110 … `_arr_pair`:1394, incl.
  `_write_back_proposals`:1160 and `_materialize_routes`:1207): W2,
  plugin-side (panel_tools.gd → PcbAnnotationHost). Broker envelope handling
  stays plugin-side (double-envelope hint `pcb-plugin/broker-ipc-double-envelope`).
- **Pure geometry** (`_build_polylines_from_segments`:1457,
  `_arr_to_vec2`:1402): plugin-side, ui/model or panel_tools.gd.
- Constants `_PANEL_LOCAL_TOOLS`:48 and `_VALID_FOOTPRINTS`:74: the tool list
  dissolves into the manifest; the footprint enum migrates with add_component.

## 5. Acceptance matrix

| Gate | Scenario | Round |
|---|---|---|
| E2E-P1 | A hello-style plugin serves ONE `executor:"panel"` tool end-to-end through the REAL MCP dispatch path (headless: MODULE-equivalent call through PluginToolRegistry.handle_tool_call with a mounted panel); structured errors proven for editor_name_required / editor_not_found / panel_no_handler; backend tools regression-green. | C1 |
| E2E-P2 | Every migrated pcb tool keeps its name and arg/result shape: the existing test_pcb_* suites pass UNMODIFIED (callers can't tell the executor changed); per-wave. | C2, C3 |
| E2E-P3 | MCPPcbPanelTools.gd DELETED; full pcb + annotations sweep green; grep gate proves zero pcb workflow semantics in src/Scripts (generic dispatcher only). | C3 |
| E2E-P4 | A second scene-panel plugin (cad or graphics) serves one panel tool with ZERO core diff (diffstat is the assertion); plugin_system_guide.md documents the executor. | C6 |

Suites run from WORKTREE copies only (godot/cli-path-kills-live-debug-session:
`godot --path` on the main checkout kills the owner's live session).

## 6. HITL debt register

`Docs/design/panel-tools-hitl-debt.md` — created with R0. Every 3a/3b-class
check deferred during C1-C6 is appended there WITH its automated proxy (no
proxy, no deferral). Known entries the campaign will accrue: live pcb plugin
reinstall + tool parity spot-check (C2/C3), refine-loop live session (C4),
explicit-propose live session (C5). One consolidated owner session burns the
register at campaign end.
