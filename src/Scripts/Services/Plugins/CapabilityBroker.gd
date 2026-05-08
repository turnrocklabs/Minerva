class_name CapabilityBroker
extends RefCounted
## Host capability broker for the Minerva plugin system.
##
## Routes capability requests to host services, gated by PluginPolicy:
##   - mcp.proxy:<tool_name> → MinervaMCPServer._execute_tool_impl()
##   - secrets:<op>:<handle> → docket vault (per-plugin namespaced)
##
## Return format (all public methods):
##   Success: {"success": true, "result": {...}}
##   Failure: {"success": false, "error_code": "...", "error_message": "...", ...}
##
## Design notes:
## - CapabilityBroker is stateless with respect to plugin identity; it delegates
##   all grant checks to PluginPolicy.
## - Per-handle isolation for secrets is enforced at the broker, not by trust:
##   the docket handle is auto-prefixed with "plugin/<id>/" so plugins can never
##   construct a string that reaches another plugin's secrets.
## - host.echo is a trivial debug capability: returns {"echo": <args>} unchanged.
##   It is useful for validating the bidirectional channel end-to-end without
##   requiring a real host service.  Always safe to grant in dev/test manifests.
## - Other capabilities not listed above return "unknown_capability".
##
## Re-entrancy note (bidirectional channel):
##   When a plugin calls minerva/capability from WITHIN a tools/call handler,
##   Minerva's _stdio_request loop (MCPServerConnection.gd) detects the inbound
##   "method":"minerva/capability" message and dispatches it inline via
##   _handle_plugin_capability_request → capability_request_handler → broker.dispatch.
##   The _in_stdio_request guard prevents _on_async_output_ready from double-draining
##   the stdio pipe while this nested dispatch is in flight.  The plugin's tool
##   call resumes only after the capability response is written back to its stdin
##   and it sends its tools/call result.  This is single-threaded cooperative
##   re-entrancy — no two capability requests from the same plugin can overlap
##   because the plugin blocks waiting for each response before sending the next.

## Policy engine reference — required for capability gating.
var policy: PluginPolicy = null

## Audit log reference — optional. When set, capability dispatches and
## denials are logged in addition to what PluginPolicy already records.
var audit_log: PluginAuditLog = null


func _init(p_policy: PluginPolicy = null, p_audit_log: PluginAuditLog = null) -> void:
	policy = p_policy
	audit_log = p_audit_log


# ---------------------------------------------------------------------------
# Static helpers
# ---------------------------------------------------------------------------

## Validate that a requested path is within the allowed scopes.
## Normalizes both paths before comparison.
## Returns true if path is within any of the allowed_paths, false otherwise.
static func is_path_in_scope(path: String, allowed_paths: Array) -> bool:
	if allowed_paths.is_empty():
		return false

	# Normalize the requested path
	var abs_path: String = ProjectSettings.globalize_path(path) if path.begins_with("user://") else path
	abs_path = abs_path.simplify_path()

	# Check against each allowed path
	for allowed in allowed_paths:
		var abs_allowed: String = ProjectSettings.globalize_path(str(allowed)) if str(allowed).begins_with("user://") else str(allowed)
		abs_allowed = abs_allowed.simplify_path()

		# Check if the requested path is within the allowed path
		if abs_path.begins_with(abs_allowed):
			return true

	return false


# ---------------------------------------------------------------------------
# Public dispatch entry point
# ---------------------------------------------------------------------------

## Dispatch a capability call on behalf of a plugin.
##
## Steps:
## 1. Validate inputs.
## 2. Ask PluginPolicy whether the capability is granted.
## 3. For mcp.proxy:<tool>, call MinervaMCPServer._execute_tool_impl().
## 4. For other capabilities, return not_implemented.
##
## Returns {"success": true, "result": {...}} or a PluginErrors failure dict.
func dispatch(plugin_id: String, capability: String, args: Dictionary) -> Dictionary:
	if plugin_id.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id, "plugin_id must not be empty")

	if capability.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id, "capability must not be empty")

	# Gate: check with policy engine before any execution (deny-by-default)
	if policy != null:
		var check := policy.check_capability(plugin_id, capability)
		if not check.get("allowed", false):
			# Policy already logged the denial via _record_decision; log at
			# broker level too so capability-request outcomes are queryable
			# independently of raw policy events.
			_audit(plugin_id, PluginAuditLog.EVENT_CAPABILITY_DENIED, {
				"capability": capability,
				"reason": check.get("error_code", "not_granted"),
			})
			# Re-wrap as success=false (check_capability already uses PluginErrors format)
			return {
				"success": false,
				"error_code": check.get("error_code", PluginErrors.CODE_CAPABILITY_NOT_GRANTED),
				"error_message": check.get("error_message", "Capability not granted"),
				"plugin_id": plugin_id,
			}
	else:
		# No policy engine — fail closed
		push_warning("[CapabilityBroker] No policy engine set — denying dispatch of '%s' for plugin '%s'" % [capability, plugin_id])
		_audit(plugin_id, PluginAuditLog.EVENT_CAPABILITY_DENIED, {
			"capability": capability,
			"reason": "no_policy_engine",
		})
		return PluginErrors.capability_not_granted(plugin_id, capability)

	# Route mcp.proxy:<tool_name> to MinervaMCPServer
	if capability.begins_with("mcp.proxy:"):
		var mcp_result := await _handle_mcp_proxy(plugin_id, capability, args)
		_audit_dispatch(plugin_id, capability, mcp_result)
		return mcp_result

	# Route secrets:<op>:<handle> to docket vault, namespaced per plugin.
	if capability.begins_with("secrets:"):
		var sec_result := await _handle_secrets(plugin_id, capability, args)
		_audit_dispatch(plugin_id, capability, sec_result)
		return sec_result

	# Named capability dispatch
	var named_result: Dictionary
	match capability:
		"network.none":
			# network.none is a deny marker — granting it is a configuration error
			named_result = PluginErrors.permission_denied(plugin_id,
				"network.none is a deny marker and cannot be dispatched")
		"host.echo":
			# Trivial debug capability: echoes args back to the caller.
			# Useful for validating the bidirectional channel end-to-end.
			named_result = _handle_host_echo(plugin_id, args)
		"host.documents.list_open":
			named_result = _handle_host_documents_list_open(plugin_id, args)
		"host.documents.get_state":
			named_result = _handle_host_documents_get_state(plugin_id, args)
		_:
			named_result = {
				"success": false,
				"error_code": PluginErrors.CODE_UNKNOWN_CAPABILITY,
				"error_message": "Unknown capability '%s'" % capability,
				"plugin_id": plugin_id,
				"capability": capability,
			}
	_audit_dispatch(plugin_id, capability, named_result)
	return named_result


# ---------------------------------------------------------------------------
# mcp.proxy handler
# ---------------------------------------------------------------------------

## Route an mcp.proxy:<tool_name> capability to MinervaMCPServer._execute_tool_impl().
func _handle_mcp_proxy(plugin_id: String, capability: String, args: Dictionary) -> Dictionary:
	var tool_name: String = capability.substr("mcp.proxy:".length())

	if tool_name.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"mcp.proxy capability requires a tool name (e.g. mcp.proxy:minerva_create_note)")

	var minerva_server = _get_minerva_server()
	if minerva_server == null:
		return PluginErrors.schema_validation_failed(plugin_id,
			"mcp.proxy: MinervaMCPServer is not available")

	print("[CapabilityBroker] Plugin '%s' invoking mcp.proxy:%s" % [plugin_id, tool_name])

	var result: Dictionary = await minerva_server._execute_tool_impl(tool_name, args)

	# Wrap the MCP tool result in our standard success/failure format.
	# MinervaMCPServer tools return {"success": true/false, ...} or {"error": "..."}.
	if result.get("success", false) or (not result.has("error") and not result.has("error_code")):
		return PluginErrors.success(result)
	else:
		return {
			"success": false,
			"error_code": "mcp_tool_error",
			"error_message": result.get("error", "Unknown error from tool '%s'" % tool_name),
			"plugin_id": plugin_id,
			"tool_name": tool_name,
		}


# ---------------------------------------------------------------------------
# secrets handler
# ---------------------------------------------------------------------------

## Route a secrets:<op>:<handle> capability to the docket vault.
##
## Capability format: "secrets:<op>:<handle>" where op is get|set|delete.
## The plugin's manifest must declare each capability+handle combination it needs in
## permissions.host_capabilities (e.g. "secrets:get:obs_password", "secrets:set:obs_password").
## Per-handle access is enforced by the existing PluginPolicy exact-match check.
##
## Handles are namespaced as "plugin/<plugin_id>/<handle>" inside the docket vault
## so plugins cannot reach each other's secrets even if a misconfigured manifest
## or compromised plugin tries to read a sibling's handle.
##
## Args:
##   secrets:get / secrets:delete — no required args.
##   secrets:set — args.value is the secret value to store.
func _handle_secrets(plugin_id: String, capability: String, args: Dictionary) -> Dictionary:
	var rest: String = capability.substr("secrets:".length())
	var sep: int = rest.find(":")
	if sep == -1:
		return PluginErrors.schema_validation_failed(plugin_id,
			"secrets capability must be 'secrets:<op>:<handle>' (op=get|set|delete)")

	var op: String = rest.substr(0, sep)
	var handle_suffix: String = rest.substr(sep + 1)
	if handle_suffix.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"secrets capability requires a non-empty handle")

	var minerva_server = _get_minerva_server()
	if minerva_server == null:
		return PluginErrors.schema_validation_failed(plugin_id,
			"secrets: MinervaMCPServer is not available")

	# Namespace under "plugin/<id>/" so plugins cannot reach other plugins' handles.
	var docket_handle: String = "plugin/%s/%s" % [plugin_id, handle_suffix]
	var tool_args: Dictionary = {"handle": docket_handle}
	var tool_name: String

	match op:
		"get":
			tool_name = "minerva_docket_secret_get"
		"set":
			if not args.has("value"):
				return PluginErrors.schema_validation_failed(plugin_id,
					"secrets:set requires args.value")
			tool_args["value"] = str(args["value"])
			tool_name = "minerva_docket_secret_set"
		"delete":
			tool_name = "minerva_docket_secret_delete"
		_:
			return PluginErrors.schema_validation_failed(plugin_id,
				"Unknown secrets op '%s' (expected get|set|delete)" % op)

	print("[CapabilityBroker] Plugin '%s' invoking secrets:%s on handle '%s'" % [plugin_id, op, handle_suffix])

	var result: Dictionary = await minerva_server._execute_tool_impl(tool_name, tool_args)

	if result.has("error"):
		# Distinguish "secret not found" (a normal "not yet set" state for plugins)
		# from real errors. The vault returns a string; sniff its prefix.
		var err: String = str(result["error"])
		if op == "get" and err.begins_with("Secret not found"):
			return PluginErrors.success({"handle": handle_suffix, "value": null, "exists": false})
		return {
			"success": false,
			"error_code": "secrets_error",
			"error_message": err,
			"plugin_id": plugin_id,
			"operation": op,
			"handle": handle_suffix,
		}

	# Strip the namespace prefix from the returned handle so the plugin only
	# sees its own handle name, not the internal docket-side path.
	if result.has("handle"):
		var returned_handle: String = str(result["handle"])
		var prefix: String = "plugin/%s/" % plugin_id
		if returned_handle.begins_with(prefix):
			result["handle"] = returned_handle.substr(prefix.length())

	return PluginErrors.success(result)


# ---------------------------------------------------------------------------
# host.echo handler
# ---------------------------------------------------------------------------

## Trivial debug capability: echoes the caller's args back unchanged.
## Returns {"echo": <args>} so the plugin can verify round-trip fidelity.
func _handle_host_echo(plugin_id: String, args: Dictionary) -> Dictionary:
	print("[CapabilityBroker] Plugin '%s' invoking host.echo" % plugin_id)
	return PluginErrors.success({"echo": args})


# ---------------------------------------------------------------------------
# host.documents.* handlers (phase 3 reads)
# ---------------------------------------------------------------------------

## Enumerate currently-open editor documents.
##
## Each entry: {editor_name, kind, plugin_id, panel_name, path}.
## - kind: stable string mapped from Editor.Type ("text_editor", "plugin_scene", ...).
## - plugin_id / panel_name: set for PLUGIN_SCENE editors, null for host editors.
## - path: absolute file path when bound; null for anonymous/unbacked editors.
##
## In headless / pre-MainScene contexts, editor_pane is null and this returns
## an empty list — the channel itself still works.
func _handle_host_documents_list_open(plugin_id: String, _args: Dictionary) -> Dictionary:
	var docs: Array = []
	var editor_pane = _get_editor_pane()
	if editor_pane != null and editor_pane.has_method("get_open_editors"):
		for ed in editor_pane.get_open_editors():
			if ed == null:
				continue
			docs.append(_describe_editor_summary(ed))
	print("[CapabilityBroker] Plugin '%s' invoking host.documents.list_open (%d docs)" % [plugin_id, docs.size()])
	return PluginErrors.success({"documents": docs})


## Return the serialized state of a single editor.
##
## Args: {editor_name: String}
##
## Buffer-canonical paths (paired_dsl plugin scenes, path-bound text editors,
## anonymous editors bound via bind_to_buffer_path) return buffer_canonical=true
## with buffer_text + version + dirty from the shared DocumentBuffer.
##
## For plugin-scene editors whose canonical state lives in panel UI rather
## than a DocumentBuffer (e.g. .mdeck slide tiles), buffer_canonical=false is
## returned with whatever metadata IS available. Full state extraction via
## host_owned_save IPC is out of scope for this round.
func _handle_host_documents_get_state(plugin_id: String, args: Dictionary) -> Dictionary:
	var editor_name: String = str(args.get("editor_name", "")).strip_edges()
	if editor_name.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.get_state requires 'editor_name'")

	var ed = _find_editor_by_name(editor_name)
	if ed == null:
		return PluginErrors.editor_not_found(plugin_id, editor_name)

	print("[CapabilityBroker] Plugin '%s' invoking host.documents.get_state (editor='%s')" % [plugin_id, editor_name])
	return PluginErrors.success(_describe_editor_state(ed))


# ---------------------------------------------------------------------------
# Editor enumeration helpers
# ---------------------------------------------------------------------------

func _get_editor_pane():
	var root = Engine.get_main_loop().root if Engine.get_main_loop() else null
	if root == null:
		return null
	var so = root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	return so.get("editor_pane") if "editor_pane" in so else null


## Find an open editor by tab title. Mirrors MCPToolUtils.find_editor_by_name
## but inlined to keep CapabilityBroker free of MCP-module deps.
func _find_editor_by_name(editor_name: String):
	var editor_pane = _get_editor_pane()
	if editor_pane == null:
		return null
	if editor_pane.has_method("get_open_editors"):
		for ed in editor_pane.get_open_editors():
			if ed != null and "tab_title" in ed and str(ed.tab_title) == editor_name:
				return ed
	return null


## Stable string for an Editor.Type int. Decoupled from the enum so plugins
## can match exact strings without parsing Godot enums.
static func _editor_kind_string(ed_type: int) -> String:
	match ed_type:
		Editor.Type.TEXT: return "text_editor"
		Editor.Type.PLUGIN_SCENE: return "plugin_scene"
		Editor.Type.GRAPHICS: return "graphics"
		Editor.Type.SPREADSHEET: return "spreadsheet"
		Editor.Type.PCB: return "pcb"
		Editor.Type.VIDEO_EDITOR: return "video_editor"
		Editor.Type.WEBVIEW: return "webview"
		Editor.Type.DOCKET: return "docket"
		Editor.Type.PLUGIN_MANAGER: return "plugin_manager"
		Editor.Type.WORKER_STATUS: return "worker_status"
		Editor.Type.ACTIVITY_LOG: return "activity_log"
		Editor.Type.KANBAN: return "kanban"
		Editor.Type.VIDEO: return "video"
		Editor.Type.PACKAGE: return "package"
		Editor.Type.LOGS: return "logs"
		_: return "unknown"


## Resolve the canonical DocumentBuffer for an editor, if any.
## Order: paired_dsl plugin-scene broker attachment, editor.get_document_buffer(),
## file-path-keyed registry buffer.
func _resolve_editor_buffer(editor) -> DocumentBuffer:
	var ed_type: int = int(editor.type) if "type" in editor else -1
	var pid: String = str(editor.plugin_id) if "plugin_id" in editor else ""
	var pname: String = str(editor.panel_name) if "panel_name" in editor else ""
	var ed_file: String = str(editor.file) if "file" in editor else ""

	if ed_type == Editor.Type.PLUGIN_SCENE:
		var so_root = Engine.get_main_loop().root.get_node_or_null("SingletonObject") if Engine.get_main_loop() else null
		var pbroker = null
		if so_root != null and "plugin_scene_panel_broker" in so_root:
			pbroker = so_root.get("plugin_scene_panel_broker")
		if pbroker != null and not pid.is_empty() and not pname.is_empty() \
				and pbroker.has_method("get_attached_buffer"):
			var attached: DocumentBuffer = pbroker.get_attached_buffer(pid, pname)
			if attached != null:
				return attached

	if editor.has_method("get_document_buffer"):
		var buf: DocumentBuffer = editor.get_document_buffer()
		if buf != null:
			return buf

	if not ed_file.is_empty():
		var reg_r := DocumentRegistry.get_instance().get_or_create_buffer(ed_file)
		if reg_r.ok:
			return reg_r.buffer

	return null


## Resolve the externally-visible file path for an editor.
## Returns null when the editor is anonymous / unbacked.
static func _resolve_editor_path(editor, buffer: DocumentBuffer):
	if buffer != null and not buffer.file_path.is_empty() \
			and not DocumentRegistry.is_unbacked_path(buffer.file_path):
		return buffer.file_path
	if "file" in editor:
		var ed_file: String = str(editor.file)
		if not ed_file.is_empty():
			return ed_file
	return null


## Summary record for list_open (no buffer text).
func _describe_editor_summary(editor) -> Dictionary:
	var ed_type: int = int(editor.type) if "type" in editor else -1
	var pid: String = str(editor.plugin_id) if "plugin_id" in editor else ""
	var pname: String = str(editor.panel_name) if "panel_name" in editor else ""
	var buffer: DocumentBuffer = _resolve_editor_buffer(editor)
	return {
		"editor_name": str(editor.tab_title) if "tab_title" in editor else "",
		"kind": _editor_kind_string(ed_type),
		"plugin_id": pid if not pid.is_empty() else null,
		"panel_name": pname if not pname.is_empty() else null,
		"path": _resolve_editor_path(editor, buffer),
	}


## Full state record for get_state.
func _describe_editor_state(editor) -> Dictionary:
	var ed_type: int = int(editor.type) if "type" in editor else -1
	var pid: String = str(editor.plugin_id) if "plugin_id" in editor else ""
	var pname: String = str(editor.panel_name) if "panel_name" in editor else ""
	var buffer: DocumentBuffer = _resolve_editor_buffer(editor)
	var state: Dictionary = {
		"editor_name": str(editor.tab_title) if "tab_title" in editor else "",
		"kind": _editor_kind_string(ed_type),
		"plugin_id": pid if not pid.is_empty() else null,
		"panel_name": pname if not pname.is_empty() else null,
		"path": _resolve_editor_path(editor, buffer),
		"buffer_canonical": buffer != null,
	}
	if buffer != null:
		state["buffer_text"] = buffer.text
		state["version"] = buffer.version
		state["dirty"] = buffer.dirty
	else:
		# Plugin-scene panels whose canonical state lives in panel UI rather
		# than a DocumentBuffer. Round 3 returns the metadata that IS available
		# without round-tripping through host_owned_save IPC.
		state["buffer_text"] = ""
		state["version"] = 0
		state["dirty"] = false
		state["note"] = "buffer-not-canonical: panel state requires host_owned_save IPC (out of scope for this round)"
	return state


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Return the MinervaMCPServer instance from the autoload, or null.
func _get_minerva_server():
	var root = Engine.get_main_loop().root if Engine.get_main_loop() else null
	if root == null:
		return null
	var so = root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	var mcp_mgr = so.get("mcp_manager") if "mcp_manager" in so else null
	if mcp_mgr == null:
		return null
	return mcp_mgr.get("minerva_server") if "minerva_server" in mcp_mgr else null


## Log a capability event to the audit log (if wired).
func _audit(plugin_id: String, event_type: String, detail: Dictionary) -> void:
	if audit_log != null:
		audit_log.log_event(plugin_id, event_type, detail)


## Log a capability dispatch outcome (granted = dispatched, failed = denied).
func _audit_dispatch(plugin_id: String, capability: String, result: Dictionary) -> void:
	if audit_log == null:
		return
	if result.get("success", false):
		audit_log.log_event(plugin_id, PluginAuditLog.EVENT_CAPABILITY_DISPATCHED, {
			"capability": capability,
		})
	else:
		audit_log.log_event(plugin_id, PluginAuditLog.EVENT_CAPABILITY_DENIED, {
			"capability": capability,
			"reason": result.get("error_code", "unknown"),
		})
