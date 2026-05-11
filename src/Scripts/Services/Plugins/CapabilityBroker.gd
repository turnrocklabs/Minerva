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

## JsonPointer — preloaded to avoid class_name scope issues when CapabilityBroker
## is loaded in isolation (e.g. headless tests). JsonPatch.gd uses the same pattern.
const _JsonPointer := preload("res://Scripts/Services/Plugins/JsonPointer.gd")

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

## Return the string when non-empty, else null. Avoids the
## `String if cond else null` ternary which Godot's analyzer flags as
## mutually-incompatible. Uses if/else (not a ternary) because the
## ternary form fires the same warning even with a Variant return type —
## the analyzer is structural, not flow-sensitive.
static func _str_or_null(value: String) -> Variant:
	if value.is_empty():
		return null
	return value


## Wrap is_path_in_scope with a structured result for capability handlers.
##
## Returns either {success: true, result: {path: <normalized abs>}} on accept,
## or a PluginErrors failure dict on reject (schema_validation_failed for
## empty input, non-absolute input, or `..` traversal; target_not_allowlisted
## for out-of-scope paths).
##
## Centralizes the path-normalization + scope-check + error-wrapping triad so
## host.files.* handlers (T5) share one validator.
##
## Defense layers (in order):
##   1. Empty input rejected.
##   2. user:// prefix is expanded; everything else must already be absolute.
##      Rejects relative paths so a future relative entry in allowed_paths can
##      never match unexpectedly, and so plugins can't bypass scope by working
##      from the host's CWD.
##   3. Raw `..` segments in the input are rejected BEFORE simplify_path. This
##      is defense in depth: simplify_path collapses `/tmp/foo/../etc` to
##      `/tmp/etc` (or `/etc`), which the scope check would catch — but
##      treating the explicit traversal attempt as a hard error gives a
##      clearer audit signal than a silent allowlist miss.
##   4. simplify_path normalizes the candidate.
##   5. is_path_in_scope checks prefix-with-trailing-slash so `/tmp/foo` does
##      NOT match an allowed scope of `/tmp/foobar` (NIT-6 from T4 review).
##
## SECURITY LIMITATION: symlink resolution is not performed here. Godot does
## not expose realpath() to GDScript without spawning a process. A grant for
## /tmp combined with an escape symlink /tmp/escape -> /etc still defeats the
## scope check. Hosts MUST ensure no escape symlinks exist within granted
## scopes. Plugins gain control over /tmp/escape by writing through this
## validator, but they cannot CREATE symlinks via host.files.write (which only
## writes file content). Treat granted scopes as transitive trust.
static func validate_files_path(plugin_id: String, path: String, allowed_paths: Array) -> Dictionary:
	if path.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id, "path must not be empty")

	# Embedded null bytes pass simplify_path / begins_with as ordinary chars but
	# would be silently truncated at the libc layer (`open(2)`), creating a gap
	# between what the validator audits and what FileAccess actually opens.
	# Reject loudly instead.
	if path.contains(char(0)):
		return PluginErrors.schema_validation_failed(
			plugin_id, "path must not contain null bytes"
		)

	# user:// is the only supported relative-style prefix; expand it then enforce
	# absolute-path-only for everything else.
	var raw_path: String = path
	if raw_path.begins_with("user://"):
		raw_path = ProjectSettings.globalize_path(raw_path)

	if not raw_path.is_absolute_path():
		return PluginErrors.schema_validation_failed(
			plugin_id, "path must be absolute or user://-prefixed (got: '%s')" % path
		)

	# Reject explicit `..` segments. `/tmp/foo/../bar` is rejected even though
	# simplify_path would collapse it to `/tmp/bar` — explicit traversal is a
	# clearer audit signal than a silent allowlist miss.
	for segment in raw_path.split("/"):
		if segment == "..":
			return PluginErrors.schema_validation_failed(
				plugin_id, "path must not contain '..' segments (got: '%s')" % path
			)

	var abs_path: String = raw_path.simplify_path()

	if not is_path_in_scope(abs_path, allowed_paths):
		return PluginErrors.target_not_allowlisted(plugin_id, abs_path)

	return PluginErrors.success({"path": abs_path})


## Validate that a requested path is within the allowed scopes.
## Normalizes both paths before comparison and uses prefix-with-trailing-slash
## semantics so /tmp/foo is NOT considered in scope for /tmp/foobar.
## Returns true if path is within any of the allowed_paths, false otherwise.
static func is_path_in_scope(path: String, allowed_paths: Array) -> bool:
	if allowed_paths.is_empty():
		return false

	# Normalize the requested path
	var abs_path: String = ProjectSettings.globalize_path(path) if path.begins_with("user://") else path
	abs_path = abs_path.simplify_path()

	# Check against each allowed path with prefix-plus-separator semantics so
	# `/tmp/foo` does not match an allowed scope `/tmp/foobar`. Exact match is
	# also accepted (a grant for /tmp/foo allows operating on /tmp/foo itself).
	for allowed in allowed_paths:
		var abs_allowed: String = ProjectSettings.globalize_path(str(allowed)) if str(allowed).begins_with("user://") else str(allowed)
		abs_allowed = abs_allowed.simplify_path()

		if abs_path == abs_allowed:
			return true
		var prefix: String = abs_allowed if abs_allowed.ends_with("/") else abs_allowed + "/"
		if abs_path.begins_with(prefix):
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
		_audit_dispatch(plugin_id, capability, args, mcp_result)
		return mcp_result

	# Route secrets:<op>:<handle> to docket vault, namespaced per plugin.
	if capability.begins_with("secrets:"):
		var sec_result := await _handle_secrets(plugin_id, capability, args)
		_audit_dispatch(plugin_id, capability, args, sec_result)
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
			named_result = await _handle_host_documents_get_state(plugin_id, args)
		"host.documents.set_state":
			named_result = await _handle_host_documents_set_state(plugin_id, args)
		"host.documents.mark_dirty":
			named_result = _handle_host_documents_mark_dirty(plugin_id, args)
		"host.documents.get_node":
			named_result = await _handle_host_documents_get_node(plugin_id, args)
		"host.documents.get_blob":
			named_result = _handle_host_documents_get_blob(plugin_id, args)
		"host.files.read":
			named_result = _handle_host_files_read(plugin_id, args)
		"host.files.write":
			named_result = _handle_host_files_write(plugin_id, args)
		"host.editors.list":
			named_result = _handle_host_editors_list(plugin_id, args)
		"host.editors.export":
			named_result = await _handle_host_editors_export(plugin_id, args)
		_:
			named_result = {
				"success": false,
				"error_code": PluginErrors.CODE_UNKNOWN_CAPABILITY,
				"error_message": "Unknown capability '%s'" % capability,
				"plugin_id": plugin_id,
				"capability": capability,
			}
	_audit_dispatch(plugin_id, capability, args, named_result)
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
## than a DocumentBuffer (e.g. .mdeck slide tiles), the broker performs a
## host_owned_save IPC roundtrip via PluginScenePanelBroker.request_panel_state:
## the panel script returns its serialised state, and the response is folded
## into the editor-state envelope under `panel_state`. T6 R0 substrate.
##
## In headless / pre-MainScene contexts where the panel broker isn't wired,
## the response shape falls back to the pre-T6 placeholder
## (`unsupported_reason: "panel_state_via_host_owned_save"`).
func _handle_host_documents_get_state(plugin_id: String, args: Dictionary) -> Dictionary:
	var editor_name: String = str(args.get("editor_name", "")).strip_edges()
	if editor_name.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.get_state requires 'editor_name'")

	var ed = _find_editor_by_name(editor_name)
	if ed == null:
		return PluginErrors.editor_not_found(plugin_id, editor_name)

	print("[CapabilityBroker] Plugin '%s' invoking host.documents.get_state (editor='%s')" % [plugin_id, editor_name])

	var ed_type: int = int(ed.type) if "type" in ed else -1
	if ed_type == Editor.Type.PLUGIN_SCENE:
		var buffer: DocumentBuffer = _resolve_editor_buffer(ed)
		if buffer == null:
			# Panel-canonical: state lives in panel UI memory. Round-trip
			# through PluginScenePanelBroker.
			var owner_pid: String = str(ed.plugin_id) if "plugin_id" in ed else ""
			var pname: String = str(ed.panel_name) if "panel_name" in ed else ""
			if owner_pid.is_empty() or pname.is_empty():
				return PluginErrors.not_buffer_canonical(plugin_id, editor_name)
			var pbroker = _get_panel_broker()
			if pbroker != null and pbroker.has_method("request_panel_state"):
				var resp: Dictionary = await pbroker.request_panel_state(owner_pid, pname)
				if not resp.get("success", false):
					return {
						"success": false,
						"error_code": str(resp.get("error_code", "panel_state_unavailable")),
						"error_message": str(resp.get("error_message", "")),
						"plugin_id": plugin_id,
						"editor_name": editor_name,
					}
				var state_envelope: Dictionary = _describe_editor_state(ed)
				state_envelope["panel_state"] = resp.get("state", {})
				state_envelope.erase("unsupported_reason")
				return PluginErrors.success(state_envelope)
			# Headless / no panel broker — fall through to placeholder shape.

	return PluginErrors.success(_describe_editor_state(ed))


## Write new buffer text for a single editor (optimistic-concurrency write).
##
## Args: {editor_name: String, buffer_text: String, expected_version?: int}
## Unknown keys are rejected (strict schema — writes are destructive).
##
## On success: {editor_name, version, dirty: true, kind, plugin_id}
## Errors: editor_not_found, not_buffer_canonical, version_conflict,
##         schema_validation_failed.
func _handle_host_documents_set_state(plugin_id: String, args: Dictionary) -> Dictionary:
	# Strict args allowlist — unknown keys are a footgun on destructive writes.
	# T6 R0 added `panel_state` for plugin-scene non-canonical editors;
	# `buffer_text` and `panel_state` are mutually exclusive — the broker
	# routes by which one was supplied AND the editor type.
	var allowed_keys := ["editor_name", "buffer_text", "panel_state", "expected_version"]
	for k in args.keys():
		if k not in allowed_keys:
			return PluginErrors.schema_validation_failed(plugin_id,
				"host.documents.set_state: unknown arg '%s' (allowed: %s)" % [k, str(allowed_keys)])

	var editor_name: String = str(args.get("editor_name", "")).strip_edges()
	if editor_name.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.set_state requires 'editor_name'")

	var has_buffer_text := args.has("buffer_text")
	var has_panel_state := args.has("panel_state")
	if has_buffer_text and has_panel_state:
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.set_state: 'buffer_text' and 'panel_state' are mutually exclusive")
	if not has_buffer_text and not has_panel_state:
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.set_state requires 'buffer_text' (text editors) or 'panel_state' (plugin-scene panels)")

	# Size cap on panel_state — applied BEFORE editor lookup so an oversize
	# payload is rejected without disclosing editor existence and without
	# consuming the lookup work.
	if has_panel_state:
		var raw_state_pre: Variant = args["panel_state"]
		if not (raw_state_pre is Dictionary):
			return PluginErrors.schema_validation_failed(plugin_id,
				"host.documents.set_state: 'panel_state' must be a Dictionary")
		var serialized_pre: String = JSON.stringify(raw_state_pre)
		if serialized_pre.length() > _FILES_MAX_BYTES:
			return PluginErrors.payload_too_large(plugin_id, _FILES_MAX_BYTES, serialized_pre.length())

	var ed = _find_editor_by_name(editor_name)
	if ed == null:
		return PluginErrors.editor_not_found(plugin_id, editor_name)

	var ownership_err := _check_editor_ownership(plugin_id, ed, editor_name)
	if not ownership_err.is_empty():
		return ownership_err

	# T6 R0 — plugin-scene non-canonical path. The plugin sent panel_state
	# (a Dictionary) and we IPC-roundtrip it to the panel for application.
	if has_panel_state:
		var ed_type_ps: int = int(ed.type) if "type" in ed else -1
		if ed_type_ps != Editor.Type.PLUGIN_SCENE:
			return PluginErrors.schema_validation_failed(plugin_id,
				"host.documents.set_state: 'panel_state' requires plugin-scene editor")
		var buffer_pre_check: DocumentBuffer = _resolve_editor_buffer(ed)
		if buffer_pre_check != null:
			# Plugin-scene editor that DOES have a canonical buffer (paired_dsl).
			# Force the plugin to use buffer_text — mixing modes here would
			# silently bypass version + dirty bookkeeping the buffer owns.
			return PluginErrors.schema_validation_failed(plugin_id,
				"host.documents.set_state: this plugin-scene editor is buffer-canonical; use 'buffer_text'")
		# panel_state Dictionary type-check + size cap already enforced
		# above (before editor lookup); raw_state is therefore safe to read.
		var raw_state: Dictionary = args["panel_state"] as Dictionary
		var owner_pid: String = str(ed.plugin_id) if "plugin_id" in ed else ""
		var pname: String = str(ed.panel_name) if "panel_name" in ed else ""
		if owner_pid.is_empty() or pname.is_empty():
			return PluginErrors.not_buffer_canonical(plugin_id, editor_name)
		var pbroker = _get_panel_broker()
		if pbroker == null or not pbroker.has_method("apply_panel_state"):
			return PluginErrors.not_buffer_canonical(plugin_id, editor_name)
		var resp: Dictionary = await pbroker.apply_panel_state(owner_pid, pname, raw_state as Dictionary)
		if not resp.get("success", false):
			return {
				"success": false,
				"error_code": str(resp.get("error_code", "panel_state_unavailable")),
				"error_message": str(resp.get("error_message", "")),
				"plugin_id": plugin_id,
				"editor_name": editor_name,
			}
		var ed_type_ok: int = int(ed.type) if "type" in ed else -1
		var pid_ok: String = str(ed.plugin_id) if "plugin_id" in ed else ""
		print("[CapabilityBroker] Plugin '%s' set_state (panel) on editor '%s'" % [plugin_id, editor_name])
		return PluginErrors.success({
			"editor_name": editor_name,
			"dirty": true,
			"kind": _editor_kind_string(ed_type_ok),
			"plugin_id": _str_or_null(pid_ok),
			"buffer_canonical": false,
		})

	# Buffer-canonical path (existing).
	var buffer_text: String = str(args["buffer_text"])
	var buffer: DocumentBuffer = _resolve_editor_buffer(ed)
	if buffer == null:
		return PluginErrors.not_buffer_canonical(plugin_id, editor_name)

	# Optimistic concurrency: if caller supplied expected_version, check it
	# against the current version before mutating.
	if args.has("expected_version"):
		var expected: int = int(args["expected_version"])
		if buffer.version != expected:
			return PluginErrors.version_conflict(plugin_id, editor_name, expected, buffer.version)

	buffer.apply_edit(buffer_text)
	# apply_edit is a no-op when buffer_text == buffer.text — version doesn't bump
	# and dirty is preserved (could be false). set_state's contract is "host
	# explicitly replaced state," so always mark dirty regardless. Otherwise the
	# result dict's dirty:true would lie when a plugin re-writes identical text.
	buffer.mark_dirty()

	var ed_type: int = int(ed.type) if "type" in ed else -1
	var pid: String = str(ed.plugin_id) if "plugin_id" in ed else ""
	print("[CapabilityBroker] Plugin '%s' set_state on editor '%s' (version→%d)" % [plugin_id, editor_name, buffer.version])
	return PluginErrors.success({
		"editor_name": editor_name,
		"version": buffer.version,
		"dirty": buffer.dirty,
		"kind": _editor_kind_string(ed_type),
		"plugin_id": _str_or_null(pid),
	})


## Mark an editor's canonical DocumentBuffer as dirty without changing its text.
##
## Args: {editor_name: String}
## Unknown keys are rejected (strict schema).
##
## On success: {editor_name, dirty: true, kind, plugin_id}
## Errors: editor_not_found, not_buffer_canonical, schema_validation_failed.
func _handle_host_documents_mark_dirty(plugin_id: String, args: Dictionary) -> Dictionary:
	# Strict args allowlist.
	var allowed_keys := ["editor_name"]
	for k in args.keys():
		if k not in allowed_keys:
			return PluginErrors.schema_validation_failed(plugin_id,
				"host.documents.mark_dirty: unknown arg '%s' (allowed: %s)" % [k, str(allowed_keys)])

	var editor_name: String = str(args.get("editor_name", "")).strip_edges()
	if editor_name.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.mark_dirty requires 'editor_name'")

	var ed = _find_editor_by_name(editor_name)
	if ed == null:
		return PluginErrors.editor_not_found(plugin_id, editor_name)

	var ownership_err := _check_editor_ownership(plugin_id, ed, editor_name)
	if not ownership_err.is_empty():
		return ownership_err

	var buffer: DocumentBuffer = _resolve_editor_buffer(ed)
	if buffer == null:
		return PluginErrors.not_buffer_canonical(plugin_id, editor_name)

	buffer.mark_dirty()

	var ed_type: int = int(ed.type) if "type" in ed else -1
	var pid: String = str(ed.plugin_id) if "plugin_id" in ed else ""
	print("[CapabilityBroker] Plugin '%s' mark_dirty on editor '%s'" % [plugin_id, editor_name])
	return PluginErrors.success({
		"editor_name": editor_name,
		"dirty": true,
		"kind": _editor_kind_string(ed_type),
		"plugin_id": _str_or_null(pid),
	})


# ---------------------------------------------------------------------------
# host.documents.get_node + get_blob handlers (phase 5 R2)
# ---------------------------------------------------------------------------

## Return the subtree of an editor's panel state at a JSON Pointer path.
##
## Args: {editor_name: String, path: String}
##   path: RFC 6901 JSON Pointer — empty string returns the entire document root,
##         otherwise must start with '/'. Probing for optional fields is normal;
##         found=false is a non-error outcome.
##
## On success: {editor_name, path, found: bool, value: Variant, key: Variant}
##   found=true  → value holds the resolved subtree; key is the last Dict key or
##                 Array index.
##   found=false → value is null; key is null (path does not exist in doc).
##
## Errors: schema_validation_failed (bad args), editor_not_found.
##
## NOTE: Blob values are returned as {__blob_handle__, content_type} placeholders
## when the panel has already used _store_blob. R3 will add outbound state-stripping
## that substitutes handles automatically before this handler reads the state.
func _handle_host_documents_get_node(plugin_id: String, args: Dictionary) -> Dictionary:
	var editor_name: String = str(args.get("editor_name", "")).strip_edges()
	if editor_name.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.get_node requires 'editor_name'")

	var path: String = str(args.get("path", ""))
	# path must be empty (root) or start with '/'.
	if not path.is_empty() and not path.begins_with("/"):
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.get_node: 'path' must be empty (root) or start with '/' (got: '%s')" % path)

	var ed = _find_editor_by_name(editor_name)
	if ed == null:
		return PluginErrors.editor_not_found(plugin_id, editor_name)

	print("[CapabilityBroker] Plugin '%s' invoking host.documents.get_node (editor='%s', path='%s')" % [plugin_id, editor_name, path])

	# Obtain the panel state the same way get_state does for plugin-scene editors.
	# Error classification (cold-review R2 follow-up): plugin authors must be
	# able to distinguish "this editor doesn't expose a navigable JSON tree"
	# from "the path didn't resolve in a navigable tree." So non-navigable
	# editor configurations return `not_buffer_canonical` (mirroring get_state's
	# convention at line 466) rather than silently returning `found=false` from
	# an empty fallback document.
	var state: Variant = null
	var ed_type: int = int(ed.type) if "type" in ed else -1
	if ed_type == Editor.Type.PLUGIN_SCENE:
		var buffer: DocumentBuffer = _resolve_editor_buffer(ed)
		if buffer == null:
			# Panel-canonical: round-trip through PluginScenePanelBroker.
			var owner_pid: String = str(ed.plugin_id) if "plugin_id" in ed else ""
			var pname: String = str(ed.panel_name) if "panel_name" in ed else ""
			if owner_pid.is_empty() or pname.is_empty():
				# Matches get_state's behavior at L466 for the same precondition.
				return PluginErrors.not_buffer_canonical(plugin_id, editor_name)
			var pbroker = _get_panel_broker()
			if pbroker != null and pbroker.has_method("request_panel_state"):
				var resp: Dictionary = await pbroker.request_panel_state(owner_pid, pname)
				if not resp.get("success", false):
					return {
						"success": false,
						"error_code": str(resp.get("error_code", "panel_state_unavailable")),
						"error_message": str(resp.get("error_message", "")),
						"plugin_id": plugin_id,
						"editor_name": editor_name,
						"path": path,
					}
				state = resp.get("state", {})
			else:
				# Headless / no panel broker — empty doc, nothing to navigate.
				state = {}
		else:
			# Buffer-canonical: parse buffer text as JSON to navigate it.
			# Non-JSON buffer (e.g. .mcad DSL plain text) is not navigable —
			# surface as not_buffer_canonical so callers don't confuse it with
			# "valid JSON but path missing."
			var parsed = JSON.parse_string(buffer.text)
			if parsed == null or not (parsed is Dictionary or parsed is Array):
				return PluginErrors.not_buffer_canonical(plugin_id, editor_name)
			state = parsed
	else:
		# Host-owned editor (text, graphics, etc.): not navigable via JSON
		# Pointer. Return not_buffer_canonical so callers can tell "wrong
		# editor type" from "valid panel but path missing."
		return PluginErrors.not_buffer_canonical(plugin_id, editor_name)

	var r: Dictionary = _JsonPointer.resolve(state, path)
	return PluginErrors.success({
		"editor_name": editor_name,
		"path": path,
		"found": r.get("found", false),
		"value": r.get("value", null),
		"key": r.get("key", null),
	})


## Return blob bytes for a handle stored in an editor's blob store.
##
## Args: {editor_name: String, blob_handle: String}
##
## On success: {editor_name, blob_handle, content_type: String, bytes_b64: String}
##   bytes_b64 is the Marshalls.raw_to_base64() encoding of the stored bytes.
##
## Errors: schema_validation_failed (bad args), editor_not_found,
##         blob_not_found (handle unknown or already GC'd).
func _handle_host_documents_get_blob(plugin_id: String, args: Dictionary) -> Dictionary:
	var editor_name: String = str(args.get("editor_name", "")).strip_edges()
	if editor_name.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.get_blob requires 'editor_name'")

	var blob_handle: String = str(args.get("blob_handle", "")).strip_edges()
	if blob_handle.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.get_blob requires 'blob_handle'")

	# Editor existence check — surface a clear error rather than a confusing
	# blob_not_found when the editor name is simply wrong.
	var ed = _find_editor_by_name(editor_name)
	if ed == null:
		return PluginErrors.editor_not_found(plugin_id, editor_name)

	var pbroker = _get_panel_broker()
	if pbroker == null or not pbroker.has_method("_get_blob_record"):
		return PluginErrors.blob_not_found(plugin_id, editor_name, blob_handle)

	var rec: Dictionary = pbroker._get_blob_record(editor_name, blob_handle)
	if not rec.get("found", false):
		return PluginErrors.blob_not_found(plugin_id, editor_name, blob_handle)

	var bytes: PackedByteArray = rec.get("bytes", PackedByteArray())
	var content_type: String = str(rec.get("content_type", "application/octet-stream"))
	print("[CapabilityBroker] Plugin '%s' invoking host.documents.get_blob (editor='%s', handle='%s', %d bytes)" % [plugin_id, editor_name, blob_handle, bytes.size()])
	return PluginErrors.success({
		"editor_name": editor_name,
		"blob_handle": blob_handle,
		"content_type": content_type,
		"bytes_b64": Marshalls.raw_to_base64(bytes),
	})


# ---------------------------------------------------------------------------
# host.files.* handlers (T5 R1)
# ---------------------------------------------------------------------------

## Maximum bytes returnable by host.files.read or writable by host.files.write
## in a single request. 8 MiB chosen to comfortably cover image tiles and
## small data files without giving plugins a memory-bomb primitive.
const _FILES_MAX_BYTES := 8 * 1024 * 1024

## Strict allowlists for host.files.* args. Unknown keys are footguns on
## destructive ops; mirror the host.documents.set_state pattern.
const _FILES_READ_ALLOWED_ARGS := ["path", "encoding"]
const _FILES_WRITE_ALLOWED_ARGS := ["path", "content", "encoding", "create_parents"]
const _FILES_VALID_ENCODINGS := ["text", "base64"]


## Read a scoped file as text or base64.
##
## Args: {path: String, encoding?: "text"|"base64"} (default "text")
##
## On success: {path, encoding, size, content} where size is bytes-on-disk and
## content is either UTF-8 text (encoding=text) or base64 of the raw bytes.
##
## Errors: schema_validation_failed (bad args / non-absolute / `..` traversal),
##         filesystem_disabled (manifest has filesystem.mode != scoped_paths),
##         target_not_allowlisted (path outside scope),
##         payload_too_large (size > _FILES_MAX_BYTES),
##         io_error (open failure, e.g. file-not-found / permission-denied).
func _handle_host_files_read(plugin_id: String, args: Dictionary) -> Dictionary:
	var arg_check := _validate_files_args(plugin_id, args, _FILES_READ_ALLOWED_ARGS)
	if not arg_check.get("success", false):
		return arg_check

	var def: PluginDefinition = _get_plugin_definition(plugin_id)
	if def == null or def.filesystem_mode != "scoped_paths" or def.filesystem_paths.is_empty():
		return PluginErrors.filesystem_disabled(plugin_id, "host.files.read")

	var path_check := validate_files_path(plugin_id, str(args.get("path", "")), def.filesystem_paths)
	if not path_check.get("success", false):
		return path_check
	var abs_path: String = path_check["result"]["path"]

	var encoding: String = str(args.get("encoding", "text"))
	if encoding not in _FILES_VALID_ENCODINGS:
		return PluginErrors.schema_validation_failed(
			plugin_id, "encoding must be one of %s (got: '%s')" % [str(_FILES_VALID_ENCODINGS), encoding]
		)

	var fa := FileAccess.open(abs_path, FileAccess.READ)
	if fa == null:
		var err := FileAccess.get_open_error()
		return PluginErrors.io_error(plugin_id, abs_path, "open failed: error=%d" % err)

	var size := fa.get_length()
	if size > _FILES_MAX_BYTES:
		fa.close()
		return PluginErrors.payload_too_large(plugin_id, _FILES_MAX_BYTES, size)

	var bytes := fa.get_buffer(size)
	fa.close()

	var content: String
	if encoding == "text":
		content = bytes.get_string_from_utf8()
	else:
		content = Marshalls.raw_to_base64(bytes)

	print("[CapabilityBroker] Plugin '%s' read '%s' (%d bytes, %s)" % [plugin_id, abs_path, size, encoding])
	return PluginErrors.success({
		"path": abs_path,
		"encoding": encoding,
		"size": size,
		"content": content,
	})


## Write content to a scoped file.
##
## Args: {path: String, content: String, encoding?: "text"|"base64",
##        create_parents?: bool} (defaults: encoding=text, create_parents=false)
##
## On success: {path, encoding, bytes_written}
##
## Errors mirror read, plus io_error on write/dir-creation failure.
##
## NOTE: writes are NOT atomic (no .tmp + rename). T5 R2 may revisit if the
## presentation plugin needs crash-safe writes; for now plugins should treat
## host.files.write as best-effort sequential write.
func _handle_host_files_write(plugin_id: String, args: Dictionary) -> Dictionary:
	var arg_check := _validate_files_args(plugin_id, args, _FILES_WRITE_ALLOWED_ARGS)
	if not arg_check.get("success", false):
		return arg_check

	if not args.has("content"):
		return PluginErrors.schema_validation_failed(
			plugin_id, "host.files.write requires 'content'"
		)

	var def: PluginDefinition = _get_plugin_definition(plugin_id)
	if def == null or def.filesystem_mode != "scoped_paths" or def.filesystem_paths.is_empty():
		return PluginErrors.filesystem_disabled(plugin_id, "host.files.write")

	var path_check := validate_files_path(plugin_id, str(args.get("path", "")), def.filesystem_paths)
	if not path_check.get("success", false):
		return path_check
	var abs_path: String = path_check["result"]["path"]

	var encoding: String = str(args.get("encoding", "text"))
	if encoding not in _FILES_VALID_ENCODINGS:
		return PluginErrors.schema_validation_failed(
			plugin_id, "encoding must be one of %s (got: '%s')" % [str(_FILES_VALID_ENCODINGS), encoding]
		)

	# Decode content per encoding before any size check, so the size cap reflects
	# real bytes-on-disk rather than encoded payload size.
	var bytes: PackedByteArray
	if encoding == "text":
		bytes = str(args["content"]).to_utf8_buffer()
	else:
		bytes = Marshalls.base64_to_raw(str(args["content"]))
		if bytes.is_empty() and not str(args["content"]).is_empty():
			return PluginErrors.schema_validation_failed(
				plugin_id, "content is not valid base64"
			)

	if bytes.size() > _FILES_MAX_BYTES:
		return PluginErrors.payload_too_large(plugin_id, _FILES_MAX_BYTES, bytes.size())

	# Create parent directories if requested. The validator already confirmed
	# the path is in-scope, so any parent created is also in-scope.
	if bool(args.get("create_parents", false)):
		var parent_dir: String = abs_path.get_base_dir()
		if not DirAccess.dir_exists_absolute(parent_dir):
			var mk_err := DirAccess.make_dir_recursive_absolute(parent_dir)
			if mk_err != OK:
				return PluginErrors.io_error(
					plugin_id, abs_path, "mkdir_recursive failed: error=%d on '%s'" % [mk_err, parent_dir]
				)

	var fa := FileAccess.open(abs_path, FileAccess.WRITE)
	if fa == null:
		var err := FileAccess.get_open_error()
		return PluginErrors.io_error(plugin_id, abs_path, "open failed: error=%d" % err)
	fa.store_buffer(bytes)
	fa.close()

	print("[CapabilityBroker] Plugin '%s' wrote '%s' (%d bytes, %s)" % [plugin_id, abs_path, bytes.size(), encoding])
	return PluginErrors.success({
		"path": abs_path,
		"encoding": encoding,
		"bytes_written": bytes.size(),
	})


## Strict-allowlist arg validator for host.files.*. Returns success({}) on ok
## or schema_validation_failed on unknown keys / missing required fields.
func _validate_files_args(plugin_id: String, args: Dictionary, allowed_keys: Array) -> Dictionary:
	for k in args.keys():
		if k not in allowed_keys:
			return PluginErrors.schema_validation_failed(
				plugin_id, "unknown arg '%s' (allowed: %s)" % [k, str(allowed_keys)]
			)
	if not args.has("path"):
		return PluginErrors.schema_validation_failed(plugin_id, "'path' is required")
	if str(args["path"]).is_empty():
		return PluginErrors.schema_validation_failed(plugin_id, "'path' must not be empty")
	return PluginErrors.success({})


## Resolve a plugin's PluginDefinition via the policy engine's plugin_db.
## Returns null if policy or plugin_db is unset, or if the id is unknown.
func _get_plugin_definition(plugin_id: String) -> PluginDefinition:
	if policy == null or policy.plugin_db == null:
		return null
	return policy.plugin_db.get_by_id(plugin_id)


## Resolve the SingletonObject's PluginScenePanelBroker. Used by host.documents.*
## handlers when an editor is plugin_scene non-canonical (state lives in panel
## UI memory and must be retrieved via the host_owned_save IPC roundtrip).
## Returns null in headless / pre-MainScene contexts.
func _get_panel_broker():
	var root = Engine.get_main_loop().root if Engine.get_main_loop() else null
	if root == null:
		return null
	var so = root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	if not "plugin_scene_panel_broker" in so:
		return null
	return so.get("plugin_scene_panel_broker")


# ---------------------------------------------------------------------------
# host.editors.* handlers (T5 R2)
# ---------------------------------------------------------------------------

## Strict args allowlist for host.editors.export.
const _EDITORS_EXPORT_ALLOWED_ARGS := ["editor_name", "format"]

## Editor types reserved for Minerva internals — never exposed through
## host.editors.list or host.editors.export. ACTIVITY_LOG in particular
## logs every MCP call (including other plugins' args), so allowing
## arbitrary plugin export of it would be a cross-plugin information leak.
## DOCKET / PLUGIN_MANAGER / LOGS / WORKER_STATUS are similar host UI tabs
## that hold operational state, not user content. If a plugin wants its
## own state, it owns the panel and uses host.documents.* instead.
const _EDITORS_INTERNAL_TYPES := [
	Editor.Type.ACTIVITY_LOG,
	Editor.Type.LOGS,
	Editor.Type.PLUGIN_MANAGER,
	Editor.Type.DOCKET,
	Editor.Type.WORKER_STATUS,
]


static func _editor_is_internal(editor) -> bool:
	if editor == null or not "type" in editor:
		return false
	return int(editor.type) in _EDITORS_INTERNAL_TYPES


## Enumerate open editors with their advertised export formats.
##
## Each entry: {editor_name, kind, plugin_id, panel_name, export_formats}.
## export_formats is an Array[String] (empty for editors that don't support
## export). Plugins use this to discover what's available; pair with
## host.editors.export to actually retrieve content.
##
## In headless / pre-MainScene contexts, editor_pane is null and this returns
## an empty list (the channel itself still works).
func _handle_host_editors_list(plugin_id: String, _args: Dictionary) -> Dictionary:
	var editors: Array = []
	var editor_pane = _get_editor_pane()
	if editor_pane != null and editor_pane.has_method("get_open_editors"):
		for ed in editor_pane.get_open_editors():
			if ed == null:
				continue
			# Hide Minerva-internal tabs (activity log, docket, plugin manager,
			# logs, worker status). Plugins shouldn't see, let alone export, them.
			if _editor_is_internal(ed):
				continue
			editors.append(_describe_editor_for_export(ed))
	print("[CapabilityBroker] Plugin '%s' invoking host.editors.list (%d editors)" % [plugin_id, editors.size()])
	return PluginErrors.success({"editors": editors})


## Render an editor in a named format and return its bytes (base64-encoded).
##
## Args: {editor_name: String, format: String}
##
## On success: {editor_name, format, mime, size, content} where size is the
## byte count of the rendered output and content is base64 of those bytes.
## All exports are returned as base64 to keep the response shape uniform
## across binary (PNG) and text (CSV / plain text) formats.
##
## Errors: schema_validation_failed, editor_not_found, format_not_supported,
##         payload_too_large (if rendered bytes exceed 8 MiB cap).
func _handle_host_editors_export(plugin_id: String, args: Dictionary) -> Dictionary:
	for k in args.keys():
		if k not in _EDITORS_EXPORT_ALLOWED_ARGS:
			return PluginErrors.schema_validation_failed(
				plugin_id, "unknown arg '%s' (allowed: %s)" % [k, str(_EDITORS_EXPORT_ALLOWED_ARGS)]
			)

	var editor_name: String = str(args.get("editor_name", "")).strip_edges()
	if editor_name.is_empty():
		return PluginErrors.schema_validation_failed(
			plugin_id, "host.editors.export requires 'editor_name'"
		)
	var format: String = str(args.get("format", "")).strip_edges()
	if format.is_empty():
		return PluginErrors.schema_validation_failed(
			plugin_id, "host.editors.export requires 'format'"
		)

	var ed = _find_editor_by_name(editor_name)
	if ed == null:
		return PluginErrors.editor_not_found(plugin_id, editor_name)

	# Surface internal editor tabs as "not found" rather than format errors —
	# their existence shouldn't be observable to plugins.
	if _editor_is_internal(ed):
		return PluginErrors.editor_not_found(plugin_id, editor_name)

	if not ed.has_method("export_to_format"):
		# Editor predates the export contract — treat as no formats.
		return PluginErrors.format_not_supported(plugin_id, editor_name, format, [])

	var supported: Array = []
	if ed.has_method("export_formats"):
		var ef: PackedStringArray = ed.export_formats()
		for entry in ef:
			supported.append(entry)

	if format not in supported:
		return PluginErrors.format_not_supported(plugin_id, editor_name, format, supported)

	var raw: Dictionary = await ed.export_to_format(format)
	if not raw.get("success", false):
		# The editor knew the format but couldn't render it (e.g. graphics
		# editor with no layers). Surface as format_not_supported and
		# propagate the editor's detail string so plugins can distinguish
		# "format unknown" from "format known but render failed".
		var fail: Dictionary = PluginErrors.format_not_supported(plugin_id, editor_name, format, supported)
		var detail: String = str(raw.get("detail", ""))
		if not detail.is_empty():
			fail["detail"] = detail
		return fail

	var bytes: PackedByteArray = raw.get("bytes", PackedByteArray())
	if bytes.size() > _FILES_MAX_BYTES:
		return PluginErrors.payload_too_large(plugin_id, _FILES_MAX_BYTES, bytes.size())

	print("[CapabilityBroker] Plugin '%s' exported editor '%s' as %s (%d bytes)" % [plugin_id, editor_name, format, bytes.size()])
	return PluginErrors.success({
		"editor_name": editor_name,
		"format": format,
		"mime": str(raw.get("mime", "application/octet-stream")),
		"size": bytes.size(),
		"content": Marshalls.raw_to_base64(bytes),
	})


## Build a single host.editors.list entry. Reuses _describe_editor_summary's
## shape and appends export_formats so plugins can decide whether to call
## host.editors.export without a discovery round-trip.
func _describe_editor_for_export(editor) -> Dictionary:
	var summary: Dictionary = _describe_editor_summary(editor)
	var formats: Array = []
	if editor.has_method("export_formats"):
		var ef: PackedStringArray = editor.export_formats()
		for entry in ef:
			formats.append(entry)
	summary["export_formats"] = formats
	return summary


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

	# Resolution order mirrors MCPDocTools._resolve_target so reads here see the
	# same buffer that doc_read/doc_write would. Order: paired_dsl plugin-scene
	# broker attachment, then path-keyed registry, then anonymous-bound buffer.
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

	if not ed_file.is_empty():
		var reg_r := DocumentRegistry.get_instance().get_or_create_buffer(ed_file)
		if reg_r.ok:
			return reg_r.buffer

	# Anonymous editor that was bind_to_buffer_path()'d to an unbacked buffer —
	# the buffer is canonical even though editor.file is empty.
	if editor.has_method("get_document_buffer"):
		var buf: DocumentBuffer = editor.get_document_buffer()
		if buf != null:
			return buf

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
		"plugin_id": _str_or_null(pid),
		"panel_name": _str_or_null(pname),
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
		"plugin_id": _str_or_null(pid),
		"panel_name": _str_or_null(pname),
		"path": _resolve_editor_path(editor, buffer),
		"buffer_canonical": buffer != null,
	}
	if buffer != null:
		state["buffer_text"] = buffer.text
		state["version"] = buffer.version
		state["dirty"] = buffer.dirty
	else:
		# Plugin-scene panels whose canonical state lives in panel UI rather
		# than a DocumentBuffer. Round-4 set_state must branch on
		# unsupported_reason rather than string-matching free text.
		state["buffer_text"] = ""
		state["version"] = 0
		state["dirty"] = false
		state["unsupported_reason"] = "panel_state_via_host_owned_save"
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


## Enforce that destructive capabilities on PLUGIN_SCENE editors are scoped
## to the editor's owning plugin. Read-only capabilities (list_open, get_state)
## intentionally do NOT use this — agents may need to inspect any open editor.
##
## Returns {} (empty dict) if ownership is fine OR the editor isn't a plugin
## scene (host-owned editors have no plugin owner). Returns a PluginErrors
## ownership_required dict otherwise. Caller short-circuits on non-empty return.
##
## `editor` is intentionally untyped — accepts any object exposing .type and
## .plugin_id, which matters for the test suite's _OwnedEditorStub. Keep the
## helper's name and signature stable; tests reach in directly.
func _check_editor_ownership(plugin_id: String, editor, editor_name: String) -> Dictionary:
	if editor == null:
		return {}
	var ed_type: int = int(editor.type) if "type" in editor else -1
	if ed_type != Editor.Type.PLUGIN_SCENE:
		return {}
	var owner_id: String = str(editor.plugin_id) if "plugin_id" in editor else ""
	# Owner-unset plugin-scene editors are a host bookkeeping bug; deny defensively.
	if owner_id.is_empty() or owner_id != plugin_id:
		return PluginErrors.ownership_required(plugin_id, editor_name, owner_id)
	return {}


## Build a redaction-safe summary of capability call args for audit logging.
##
## Three redaction rules:
##   1. Field-name denylist: matched fields (regardless of nesting depth via
##      one level of dict recursion) are replaced with "<redacted: ...>"
##      descriptors. Includes document-write fields (buffer_text, bytes,
##      data, content, value) and common credential field names that
##      mcp.proxy: tools commonly forward (password, token, secret, api_key,
##      authorization).
##   2. One level of dict recursion so {wrapper: {api_key: "..."}} doesn't
##      leak. Beyond depth 1, nested dicts are summarised as
##      "<nested dict: N keys>" rather than recursed further (defends both
##      against perf and against silently-shipping deeper structures).
##   3. Length cap on remaining string fields: anything over CAP chars
##      becomes "<truncated: N chars>".
##
## Non-string scalar values (int, bool, float) pass through unchanged.
## Arrays pass through (no key-name handle to denylist on); document the
## constraint so capability authors don't tuck secrets into [params, value]
## arrays.
const _AUDIT_REDACT_FIELDS := [
	# Document-write payload fields (set_state buffer body, raw bytes/data).
	"buffer_text", "bytes", "data", "content", "value",
	# Credential / auth field names commonly carried by mcp.proxy: tools and
	# secrets: capability args. Forward-looks at T5+ MCP exposure.
	"password", "token", "secret", "api_key", "authorization",
]
const _AUDIT_STRING_CAP := 256

static func _redact_args(args: Dictionary, depth: int = 0) -> Dictionary:
	var out: Dictionary = {}
	for k in args.keys():
		var key: String = str(k)
		var val = args[k]
		if key in _AUDIT_REDACT_FIELDS:
			out[key] = _redact_value(val)
		elif val is Dictionary:
			if depth < 1:
				out[key] = _redact_args(val, depth + 1)
			else:
				out[key] = "<nested dict: %d keys>" % (val as Dictionary).size()
		elif val is String and val.length() > _AUDIT_STRING_CAP:
			out[key] = "<truncated: %d chars>" % val.length()
		else:
			out[key] = val
	return out


## Produce a redaction descriptor for a denylisted field's value.
## Reports a meaningful size hint per type rather than a misleading
## var_to_str-derived length (which inflates Packed*Array sizes by ~10x).
static func _redact_value(val) -> String:
	if val is String:
		return "<redacted: %d chars>" % val.length()
	if val is PackedByteArray:
		return "<redacted: %d bytes>" % (val as PackedByteArray).size()
	if val is Array:
		return "<redacted: %d items>" % (val as Array).size()
	if val is Dictionary:
		return "<redacted: %d keys>" % (val as Dictionary).size()
	return "<redacted>"


## Log a capability event to the audit log (if wired).
func _audit(plugin_id: String, event_type: String, detail: Dictionary) -> void:
	if audit_log != null:
		audit_log.log_event(plugin_id, event_type, detail)


## Log a capability dispatch outcome.
##
## Success → EVENT_CAPABILITY_DISPATCHED.
## Policy-level denial (capability_not_granted, permission_denied,
##   target_not_allowlisted, rate_limit_exceeded, confirmation_required)
##   → EVENT_CAPABILITY_DENIED.
## All other broker-level failures (editor_not_found, not_buffer_canonical,
##   version_conflict, schema_validation_failed, unknown_capability,
##   mcp_tool_error, secrets_error, …)
##   → EVENT_CAPABILITY_FAILED.
## Codes that route to EVENT_CAPABILITY_DENIED (policy-class denials).
## ownership_required is included because cross-plugin editor mutation is a
## permission decision (the plugin lacks rights for THIS target), not a
## broker-validation failure — audit consumers should see it as a security event.
const _POLICY_DENY_CODES := [
	PluginErrors.CODE_CAPABILITY_NOT_GRANTED,
	PluginErrors.CODE_PERMISSION_DENIED,
	PluginErrors.CODE_TARGET_NOT_ALLOWLISTED,
	PluginErrors.CODE_RATE_LIMIT_EXCEEDED,
	PluginErrors.CODE_CONFIRMATION_REQUIRED,
	PluginErrors.CODE_OWNERSHIP_REQUIRED,
]

func _audit_dispatch(plugin_id: String, capability: String, args: Dictionary, result: Dictionary) -> void:
	if audit_log == null:
		return
	var args_summary := _redact_args(args)
	if result.get("success", false):
		audit_log.log_event(plugin_id, PluginAuditLog.EVENT_CAPABILITY_DISPATCHED, {
			"capability": capability,
			"args_summary": args_summary,
		})
	else:
		var error_code: String = result.get("error_code", "unknown")
		if error_code in _POLICY_DENY_CODES:
			audit_log.log_event(plugin_id, PluginAuditLog.EVENT_CAPABILITY_DENIED, {
				"capability": capability,
				"reason": error_code,
				"args_summary": args_summary,
			})
		else:
			audit_log.log_event(plugin_id, PluginAuditLog.EVENT_CAPABILITY_FAILED, {
				"capability": capability,
				"reason": error_code,
				"args_summary": args_summary,
			})
