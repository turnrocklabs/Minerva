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

## PluginScopeGrants — preloaded for the same reason (loaded in isolation in tests).
const _PluginScopeGrants := preload("res://Scripts/Services/Plugins/PluginScopeGrants.gd")

## CoreProvider — preloaded to allow structured model_spec routing for core_action providers.
## Using preload (not class_name) so CapabilityBroker loads correctly in headless test contexts.
const _CoreProvider := preload("res://Scripts/Services/Providers/Core/CoreProvider.gd")

## Observability signals — fired per plugin chat invocation so panels and
## status surfaces can show what's in flight. Panels subscribe via
## SingletonObject.plugin_capability_broker. Receivers should filter by
## plugin_id since one broker serves all plugins.
signal plugin_chat_invoked(plugin_id: String, provider_name: String, model_name: String)
signal plugin_chat_completed(plugin_id: String, provider_name: String, model_name: String, duration_ms: int, ok: bool, tokens_in: int, tokens_out: int, error: String)

## Policy engine reference — required for capability gating.
var policy: PluginPolicy = null

## Audit log reference — optional. When set, capability dispatches and
## denials are logged in addition to what PluginPolicy already records.
var audit_log: PluginAuditLog = null

## Scope grants persistence layer — shared instance, loaded once in _init().
## Holds runtime filesystem scope grants that persist across restarts.
var _scope_grants = null  # PluginScopeGrants (typed via _PluginScopeGrants const)

## Test-only one-shot injection. When set to a non-null Variant before a
## host.dialogs.* dispatch, the handler short-circuits the FileDialog popup
## and returns this value as the success result, then clears the override.
## Real plugins never trigger this path.
static var _test_dialog_override = null


func _init(p_policy: PluginPolicy = null, p_audit_log: PluginAuditLog = null) -> void:
	policy = p_policy
	audit_log = p_audit_log
	_scope_grants = _PluginScopeGrants.new()


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
		"host.documents.patch_state":
			named_result = await _handle_host_documents_patch_state(plugin_id, args)
		"host.documents.put_blob":
			named_result = _handle_host_documents_put_blob(plugin_id, args)
		"host.files.read":
			named_result = _handle_host_files_read(plugin_id, args)
		"host.files.write":
			named_result = _handle_host_files_write(plugin_id, args)
		"host.files.list":
			named_result = _handle_host_files_list(plugin_id, args)
		"host.files.exists":
			named_result = _handle_host_files_exists(plugin_id, args)
		"host.files.stat":
			named_result = _handle_host_files_stat(plugin_id, args)
		"host.files.mkdir":
			named_result = _handle_host_files_mkdir(plugin_id, args)
		"host.files.delete":
			named_result = _handle_host_files_delete(plugin_id, args)
		"host.files.move":
			named_result = _handle_host_files_move(plugin_id, args)
		"host.editors.list":
			named_result = _handle_host_editors_list(plugin_id, args)
		"host.editors.export":
			named_result = await _handle_host_editors_export(plugin_id, args)
		"host.editors.open":
			named_result = _handle_host_editors_open(plugin_id, args)
		"host.providers.chat":
			named_result = await _handle_host_providers_chat(plugin_id, args)
		"host.dialogs.file_picker":
			named_result = await _handle_host_dialogs_file_picker(plugin_id, args)
		"host.dialogs.directory_picker":
			named_result = await _handle_host_dialogs_directory_picker(plugin_id, args)
		"host.permissions.grant_scope":
			named_result = await _handle_host_permissions_grant_scope(plugin_id, args)
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
			# Reachable only for paired_dsl panels (broker-attached buffers).
			# Non-JSON buffer (e.g. .mcad DSL plain text) is not navigable —
			# surface as not_buffer_canonical so callers don't confuse it with
			# "valid JSON but path missing."
			#
			# host_owned_save panels (.mdeck) are unreachable here as of the
			# _resolve_editor_buffer architectural fix: that function now
			# returns null for PLUGIN_SCENE editors without a broker-attached
			# buffer, routing them through the panel-canonical branch above
			# (where request_panel_state runs the blob-strip walker). The
			# previous defensive strip call here became dead code.
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
# host.documents.patch_state + put_blob handlers (phase 5 R4 — write caps)
# ---------------------------------------------------------------------------

## Apply an RFC 6902 JSON Patch to an editor's panel state, atomically.
##
## Args: {editor_name: String, json_patch: Array}
##   json_patch: non-empty Array of op Dictionaries, each with an "op" key.
##
## Behaviour:
##   1. Resolve editor and obtain current panel state (same logic as get_state).
##   2. Pre-validate blob handle references in patch ops — any __blob_handle__
##      value must exist in the editor's blob store BEFORE apply. Unknown handle
##      → reject atomically with unknown_blob_handle + op_index.
##   3. Apply patch via JsonPatch.apply (atomic — either all ops succeed or the
##      original state is returned untouched and patch_failed is returned).
##   4. After successful apply, walk patch ops and update refcounts:
##      add/copy → +1 per handle in value; remove → -1 per handle at old path;
##      replace → +1 for new handle, -1 for old handle; move → net 0 per handle
##      (source removed, dest added); test → 0.
##   5. Write new state back to panel (apply_panel_state for plugin-scene
##      non-canonical editors, or serialize-to-JSON for buffer-canonical).
##   6. Mark editor dirty.
##
## Audit entry carries shape-only summary (no op values, no blob bytes):
##   patch_op_count, patch_op_kinds, patch_paths, blob_handle_refs.
##
## On success: {editor_name, op_count, applied_ops, dirty: true}
## Errors: schema_validation_failed, editor_not_found, not_buffer_canonical
##         (host-owned editors), unknown_blob_handle (pre-validation),
##         patch_failed (apply failure).
func _handle_host_documents_patch_state(plugin_id: String, args: Dictionary) -> Dictionary:
	# Schema validation.
	var editor_name: String = str(args.get("editor_name", "")).strip_edges()
	if editor_name.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.patch_state requires 'editor_name'")

	var json_patch: Variant = args.get("json_patch", null)
	if not (json_patch is Array):
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.patch_state: 'json_patch' must be a non-empty Array")
	var patch: Array = json_patch as Array
	if patch.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.patch_state: 'json_patch' must be a non-empty Array")

	# Each element must be a Dictionary with an "op" key.
	for i in range(patch.size()):
		if not (patch[i] is Dictionary):
			return PluginErrors.schema_validation_failed(plugin_id,
				"host.documents.patch_state: json_patch[%d] must be a Dictionary" % i)
		if not (patch[i] as Dictionary).has("op"):
			return PluginErrors.schema_validation_failed(plugin_id,
				"host.documents.patch_state: json_patch[%d] missing required 'op' key" % i)

	var ed = _find_editor_by_name(editor_name)
	if ed == null:
		return PluginErrors.editor_not_found(plugin_id, editor_name)

	var ownership_err := _check_editor_ownership(plugin_id, ed, editor_name)
	if not ownership_err.is_empty():
		return ownership_err

	# Determine editor path (plugin-scene non-canonical vs buffer-canonical).
	var ed_type: int = int(ed.type) if "type" in ed else -1

	# Host-owned editors (text, graphics, etc.) are not JSON-navigable via patch.
	if ed_type != Editor.Type.PLUGIN_SCENE:
		return PluginErrors.not_buffer_canonical(plugin_id, editor_name)

	var buffer: DocumentBuffer = _resolve_editor_buffer(ed)
	var is_buffer_canonical: bool = buffer != null

	# Obtain current panel state for pre-validation and apply.
	var current_state: Variant = null
	var owner_pid: String = str(ed.plugin_id) if "plugin_id" in ed else ""
	var pname: String = str(ed.panel_name) if "panel_name" in ed else ""

	if not is_buffer_canonical:
		if owner_pid.is_empty() or pname.is_empty():
			return PluginErrors.not_buffer_canonical(plugin_id, editor_name)
		var pbroker = _get_panel_broker()
		if pbroker == null or not pbroker.has_method("request_panel_state"):
			return PluginErrors.not_buffer_canonical(plugin_id, editor_name)
		var resp: Dictionary = await pbroker.request_panel_state(owner_pid, pname)
		if not resp.get("success", false):
			return {
				"success": false,
				"error_code": str(resp.get("error_code", "panel_state_unavailable")),
				"error_message": str(resp.get("error_message", "")),
				"plugin_id": plugin_id,
				"editor_name": editor_name,
			}
		current_state = resp.get("state", {})
	else:
		# Buffer-canonical: parse buffer text as JSON.
		var parsed = JSON.parse_string(buffer.text if buffer.text != "" else "{}")
		if parsed == null:
			current_state = {}
		else:
			current_state = parsed

	# --- Pre-validate blob handle references -----------------------------------
	# Walk each op's value / from fields and collect any __blob_handle__ refs.
	# Any unknown handle → reject the entire patch before touching state.
	var pbroker_for_blobs = _get_panel_broker()
	for i in range(patch.size()):
		var op_dict: Dictionary = patch[i] as Dictionary
		var op: String = str(op_dict.get("op", ""))

		# Ops that carry a new value: add, replace, test.
		if op in ["add", "replace", "test"] and op_dict.has("value"):
			var val_err := _validate_blob_handles_in_value(
				plugin_id, editor_name, op_dict["value"], i, pbroker_for_blobs)
			if not val_err.is_empty():
				return val_err

		# copy op: value comes from the "from" path in the current state.
		if op == "copy" and op_dict.has("from"):
			var from_path: String = str(op_dict["from"])
			var fr: Dictionary = _JsonPointer.resolve(current_state, from_path)
			if fr.get("found", false):
				var val_err := _validate_blob_handles_in_value(
					plugin_id, editor_name, fr.get("value"), i, pbroker_for_blobs)
				if not val_err.is_empty():
					return val_err

	# --- Apply patch atomically via JsonPatch.apply ----------------------------
	const JsonPatchScript := preload("res://Scripts/Services/Plugins/JsonPatch.gd")
	var patch_result: Dictionary = JsonPatchScript.apply(current_state, patch)
	if not patch_result.get("success", false):
		var err: Dictionary = patch_result.get("error", {})
		return PluginErrors.patch_failed(
			plugin_id, editor_name,
			int(err.get("op_index", 0)),
			str(err.get("code", "unknown")),
			str(err.get("message", "Patch application failed")),
		)

	var new_state: Variant = patch_result["doc"]

	# --- Refcount delta computation (cold-review R4 redesign) ------------------
	# Compute deltas as the difference of two whole-state handle multisets:
	# initial (pre-apply) vs final (post-apply). This is correct under all
	# patch shapes — op:add that replaces an existing key, op:move into a
	# pre-existing path, multi-op patches that mutate the same path, etc.
	# All of those failed under the previous per-op delta scheme.
	#
	# Atomicity: the deltas are *computed* here but *committed* only after
	# the panel-state write below succeeds. If apply_panel_state fails, the
	# refcounts must not have moved.
	var blob_deltas: Dictionary = {}  # handle:String -> delta:int (may be negative)
	if pbroker_for_blobs != null and pbroker_for_blobs.has_method("_inc_blob_refcount"):
		var initial_counts: Dictionary = {}
		_count_handles_multiset(current_state, initial_counts)
		var final_counts: Dictionary = {}
		_count_handles_multiset(new_state, final_counts)
		var all_handles: Dictionary = {}
		for h_init in initial_counts.keys():
			all_handles[h_init] = true
		for h_fin in final_counts.keys():
			all_handles[h_fin] = true
		for h in all_handles.keys():
			var before: int = int(initial_counts.get(h, 0))
			var after: int = int(final_counts.get(h, 0))
			var delta: int = after - before
			if delta != 0:
				blob_deltas[h] = delta

	# --- Write new state back --------------------------------------------------
	if not is_buffer_canonical:
		var pbroker2 = _get_panel_broker()
		if pbroker2 == null or not pbroker2.has_method("apply_panel_state"):
			return PluginErrors.not_buffer_canonical(plugin_id, editor_name)
		# new_state may be any Variant (root-replace patch); cast defensively.
		var new_dict: Dictionary = new_state if new_state is Dictionary else {}
		var resp2: Dictionary = await pbroker2.apply_panel_state(owner_pid, pname, new_dict)
		if not resp2.get("success", false):
			# State write failed → refcount deltas NOT committed (atomic guarantee).
			return {
				"success": false,
				"error_code": str(resp2.get("error_code", "panel_state_unavailable")),
				"error_message": str(resp2.get("error_message", "")),
				"plugin_id": plugin_id,
				"editor_name": editor_name,
			}
	else:
		# Buffer-canonical: serialize new state to JSON and write to buffer.
		var new_json: String = JSON.stringify(new_state)
		buffer.apply_edit(new_json)
		buffer.mark_dirty()

	# --- Refcount commit (post state-write) -------------------------------------
	# Only reached when the panel-state write above succeeded. Apply the
	# deltas computed before the write — multi-step inc/dec per handle as
	# the multiset diff dictates.
	if pbroker_for_blobs != null and pbroker_for_blobs.has_method("_inc_blob_refcount"):
		for h in blob_deltas.keys():
			var d: int = int(blob_deltas[h])
			if d > 0:
				for _i in range(d):
					pbroker_for_blobs._inc_blob_refcount(editor_name, h)
			elif d < 0:
				for _i in range(-d):
					pbroker_for_blobs._dec_blob_refcount(editor_name, h)

	# Mark dirty (non-canonical path also calls apply_panel_state which handles dirty
	# internally via CHANNEL_HOST_OWNED_SAVE_SET_REQUEST, but explicit mark here
	# ensures the editor tab shows the unsaved indicator on buffer-canonical path).
	if is_buffer_canonical and buffer != null:
		buffer.mark_dirty()

	# --- Build audit shape-only summary ----------------------------------------
	var op_kinds_set: Dictionary = {}
	var paths_set: Dictionary = {}
	var handle_refs_set: Dictionary = {}
	for op_d in patch:
		if not (op_d is Dictionary):
			continue
		var op_str: String = str((op_d as Dictionary).get("op", ""))
		op_kinds_set[op_str] = true
		for pkey in ["path", "from"]:
			if (op_d as Dictionary).has(pkey):
				var tok: String = str((op_d as Dictionary)[pkey])
				# Top-level path = first two tokens of JSON pointer (e.g. "/slides")
				var parts: PackedStringArray = tok.split("/", false)
				paths_set["/" + (parts[0] if parts.size() > 0 else tok)] = true
		if (op_d as Dictionary).has("value"):
			_collect_blob_handles((op_d as Dictionary)["value"], handle_refs_set)

	# Inject the shape-only summary into args so _audit_dispatch picks it up.
	args["patch_op_count"]   = patch.size()
	args["patch_op_kinds"]   = op_kinds_set.keys()
	args["patch_paths"]      = paths_set.keys()
	args["blob_handle_refs"] = handle_refs_set.keys()
	# Redact the raw json_patch so op values don't appear in the audit log.
	args.erase("json_patch")

	print("[CapabilityBroker] Plugin '%s' patch_state on editor '%s' (%d ops)" % [
		plugin_id, editor_name, patch.size()])
	return PluginErrors.success({
		"editor_name": editor_name,
		"op_count": patch.size(),
		"applied_ops": patch.size(),
		"dirty": true,
	})


## Upload blob bytes to the per-editor blob store, returning a handle.
##
## Args: {editor_name: String, content_type: String, bytes_b64: String}
##   bytes_b64: Marshalls.raw_to_base64() encoding of the blob bytes.
##
## The returned handle may be used in a subsequent patch_state op as a
## {__blob_handle__: handle, content_type: type} reference in a value field.
##
## The blob is stored at refcount=1 immediately. It is NOT referenced by any
## panel state until a subsequent patch_state adds it. There is a brief window
## where the store has a refcount-1 entry unreferenced by state — this is
## intentional and safe. The blob will be GC'd when:
##   - A patch_state remove/replace op decrements its refcount to 0, OR
##   - The editor is closed (_clear_blobs_for_editor).
## There is no automatic timeout. Plugin authors should always follow
## put_blob with a patch_state that references the returned handle.
##
## On success: {editor_name, blob_handle: String, content_type: String}
## Errors: schema_validation_failed, editor_not_found.
func _handle_host_documents_put_blob(plugin_id: String, args: Dictionary) -> Dictionary:
	var editor_name: String = str(args.get("editor_name", "")).strip_edges()
	if editor_name.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.put_blob requires 'editor_name'")

	var content_type: String = str(args.get("content_type", "")).strip_edges()
	if content_type.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.put_blob requires 'content_type'")

	var bytes_b64: String = str(args.get("bytes_b64", "")).strip_edges()
	if bytes_b64.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.put_blob requires 'bytes_b64'")

	# Editor existence check before spending time on base64 decode.
	var ed = _find_editor_by_name(editor_name)
	if ed == null:
		return PluginErrors.editor_not_found(plugin_id, editor_name)

	# Decode base64 bytes.
	var bytes: PackedByteArray = Marshalls.base64_to_raw(bytes_b64)
	if bytes.is_empty() and not bytes_b64.is_empty():
		# Marshalls.base64_to_raw returns empty on invalid base64.
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.put_blob: 'bytes_b64' is not valid base64 (decoded to empty)")

	var pbroker = _get_panel_broker()
	if pbroker == null or not pbroker.has_method("_store_blob"):
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.documents.put_blob: panel broker not available")

	var handle: String = pbroker._store_blob(editor_name, bytes, content_type)

	print("[CapabilityBroker] Plugin '%s' put_blob on editor '%s' → handle '%s' (%d bytes, %s)" % [
		plugin_id, editor_name, handle, bytes.size(), content_type])
	return PluginErrors.success({
		"editor_name": editor_name,
		"blob_handle": handle,
		"content_type": content_type,
	})


# ---------------------------------------------------------------------------
# patch_state helpers
# ---------------------------------------------------------------------------

## Walk a value tree and return a non-empty PluginErrors dict if any
## {__blob_handle__: H} reference is unknown in the editor's blob store.
## Returns {} (empty) when all handles are valid or none are present.
## op_index is the patch array index being validated (for error attribution).
func _validate_blob_handles_in_value(
		plugin_id: String, editor_name: String,
		value: Variant, op_index: int, pbroker
) -> Dictionary:
	if value is Dictionary:
		var d: Dictionary = value as Dictionary
		# Check for a blob handle placeholder.
		if d.has("__blob_handle__") and d["__blob_handle__"] is String:
			var handle: String = d["__blob_handle__"] as String
			if handle.is_empty():
				return {}  # Empty handle — not a valid placeholder, pass through.
			if pbroker == null or not pbroker.has_method("_get_blob_record"):
				return PluginErrors.unknown_blob_handle(plugin_id, editor_name, handle, op_index)
			var rec: Dictionary = pbroker._get_blob_record(editor_name, handle)
			if not rec.get("found", false):
				return PluginErrors.unknown_blob_handle(plugin_id, editor_name, handle, op_index)
			return {}
		# Recurse into all dict values.
		for k in d.keys():
			var child_err := _validate_blob_handles_in_value(
				plugin_id, editor_name, d[k], op_index, pbroker)
			if not child_err.is_empty():
				return child_err
	elif value is Array:
		var arr: Array = value as Array
		for item in arr:
			var child_err := _validate_blob_handles_in_value(
				plugin_id, editor_name, item, op_index, pbroker)
			if not child_err.is_empty():
				return child_err
	return {}


## Walk a value tree and count blob handles into a multiset.
##   out_counts: handle (String) -> count (int). Same handle appearing N times
##   under different paths → count=N. Used by the patch_state refcount
##   computation: net delta = final_counts[h] - initial_counts[h].
##
## Distinct from _collect_blob_handles (set semantics, key->true) which the
## audit summary uses. The multiset form is necessary because op:add of a
## value that already exists at the path REPLACES (RFC 6902 §4.1), so the
## old value's handle leaves the doc and the new value's handle enters —
## a per-path "did this handle appear" check would miss that.
static func _count_handles_multiset(value: Variant, out_counts: Dictionary) -> void:
	if value is Dictionary:
		var d: Dictionary = value as Dictionary
		if d.has("__blob_handle__") and d["__blob_handle__"] is String:
			var h: String = d["__blob_handle__"] as String
			if not h.is_empty():
				out_counts[h] = int(out_counts.get(h, 0)) + 1
			return
		for k in d.keys():
			_count_handles_multiset(d[k], out_counts)
	elif value is Array:
		var arr: Array = value as Array
		for item in arr:
			_count_handles_multiset(item, out_counts)


## Collect all __blob_handle__ strings from a value tree into a set dict
## (key→true). Used for the audit summary's blob_handle_refs field.
static func _collect_blob_handles(value: Variant, out_set: Dictionary) -> void:
	if value is Dictionary:
		var d: Dictionary = value as Dictionary
		if d.has("__blob_handle__") and d["__blob_handle__"] is String:
			var h: String = d["__blob_handle__"] as String
			if not h.is_empty():
				out_set[h] = true
			return
		for k in d.keys():
			_collect_blob_handles(d[k], out_set)
	elif value is Array:
		var arr: Array = value as Array
		for item in arr:
			_collect_blob_handles(item, out_set)


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
const _FILES_LIST_ALLOWED_ARGS := ["path", "include_hidden"]
const _FILES_EXISTS_ALLOWED_ARGS := ["path"]
const _FILES_STAT_ALLOWED_ARGS := ["path"]
const _FILES_MKDIR_ALLOWED_ARGS := ["path", "parents"]
const _FILES_DELETE_ALLOWED_ARGS := ["path", "recursive"]
const _FILES_MOVE_ALLOWED_ARGS := ["source", "dest", "overwrite"]
## Maximum directory entries returned by host.files.list in a single request.
const _FILES_LIST_MAX_ENTRIES := 10000


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


## List entries in a scoped directory.
##
## Args: {path: String, include_hidden?: bool} (default include_hidden=false)
##
## On success: {path, entries: [{name, kind, size, modified_unix}, ...], truncated?: true}
## Errors: schema_validation_failed, filesystem_disabled, target_not_allowlisted,
##         not_a_directory (inline code), io_error.
func _handle_host_files_list(plugin_id: String, args: Dictionary) -> Dictionary:
	var arg_check := _validate_files_args(plugin_id, args, _FILES_LIST_ALLOWED_ARGS)
	if not arg_check.get("success", false):
		return arg_check

	var def: PluginDefinition = _get_plugin_definition(plugin_id)
	if def == null or def.filesystem_mode != "scoped_paths" or def.filesystem_paths.is_empty():
		return PluginErrors.filesystem_disabled(plugin_id, "host.files.list")

	var path_check := validate_files_path(plugin_id, str(args.get("path", "")), def.filesystem_paths)
	if not path_check.get("success", false):
		return path_check
	var abs_path: String = path_check["result"]["path"]

	# A file passed as path is a user error — surface a clear code, not io_error.
	if FileAccess.file_exists(abs_path):
		return {
			"success": false,
			"error_code": "not_a_directory",
			"error_message": "Path is a file, not a directory: '%s'" % abs_path,
			"plugin_id": plugin_id,
			"path": abs_path,
		}

	var da := DirAccess.open(abs_path)
	if da == null:
		var err := DirAccess.get_open_error()
		return PluginErrors.io_error(plugin_id, abs_path, "DirAccess.open failed: error=%d" % err)

	var include_hidden: bool = bool(args.get("include_hidden", false))
	# DirAccess.include_hidden controls whether hidden files (dot-prefix on Linux)
	# appear in get_next() output. Must be set before list_dir_begin().
	da.include_hidden = include_hidden
	var entries: Array = []
	var truncated := false

	da.list_dir_begin()
	while true:
		var name: String = da.get_next()
		if name.is_empty():
			break
		if name == "." or name == "..":
			continue
		if not include_hidden and name.begins_with("."):
			continue
		if entries.size() >= _FILES_LIST_MAX_ENTRIES:
			truncated = true
			break
		var full: String = abs_path.path_join(name)
		var is_dir: bool = da.current_is_dir()
		var kind: String = "dir" if is_dir else "file"
		var size: int = 0
		if not is_dir:
			var fa_tmp := FileAccess.open(full, FileAccess.READ)
			if fa_tmp != null:
				size = fa_tmp.get_length()
				fa_tmp.close()
		var modified_unix: int = int(FileAccess.get_modified_time(full))
		entries.append({
			"name": name,
			"kind": kind,
			"size": size,
			"modified_unix": modified_unix,
		})
	da.list_dir_end()

	print("[CapabilityBroker] Plugin '%s' list '%s' (%d entries)" % [plugin_id, abs_path, entries.size()])
	var result: Dictionary = {"path": abs_path, "entries": entries}
	if truncated:
		result["truncated"] = true
	return PluginErrors.success(result)


## Check whether a scoped path exists and what kind it is.
##
## Args: {path: String}
##
## On success: {path, exists: bool, kind: "file"|"dir"|null}
## Scope check runs regardless of existence — scope is the trust boundary.
## Errors: schema_validation_failed, filesystem_disabled, target_not_allowlisted.
func _handle_host_files_exists(plugin_id: String, args: Dictionary) -> Dictionary:
	var arg_check := _validate_files_args(plugin_id, args, _FILES_EXISTS_ALLOWED_ARGS)
	if not arg_check.get("success", false):
		return arg_check

	var def: PluginDefinition = _get_plugin_definition(plugin_id)
	if def == null or def.filesystem_mode != "scoped_paths" or def.filesystem_paths.is_empty():
		return PluginErrors.filesystem_disabled(plugin_id, "host.files.exists")

	var path_check := validate_files_path(plugin_id, str(args.get("path", "")), def.filesystem_paths)
	if not path_check.get("success", false):
		return path_check
	var abs_path: String = path_check["result"]["path"]

	var exists_file: bool = FileAccess.file_exists(abs_path)
	var exists_dir: bool = DirAccess.dir_exists_absolute(abs_path)
	var exists: bool = exists_file or exists_dir
	var kind: Variant = null
	if exists_file:
		kind = "file"
	elif exists_dir:
		kind = "dir"

	print("[CapabilityBroker] Plugin '%s' exists '%s' → %s (%s)" % [plugin_id, abs_path, str(exists), str(kind)])
	return PluginErrors.success({"path": abs_path, "exists": exists, "kind": kind})


## Return metadata for a scoped path.
##
## Args: {path: String}
##
## On success: {path, kind: "file"|"dir", size: int, modified_unix: int}
## Errors: schema_validation_failed, filesystem_disabled, target_not_allowlisted, io_error.
func _handle_host_files_stat(plugin_id: String, args: Dictionary) -> Dictionary:
	var arg_check := _validate_files_args(plugin_id, args, _FILES_STAT_ALLOWED_ARGS)
	if not arg_check.get("success", false):
		return arg_check

	var def: PluginDefinition = _get_plugin_definition(plugin_id)
	if def == null or def.filesystem_mode != "scoped_paths" or def.filesystem_paths.is_empty():
		return PluginErrors.filesystem_disabled(plugin_id, "host.files.stat")

	var path_check := validate_files_path(plugin_id, str(args.get("path", "")), def.filesystem_paths)
	if not path_check.get("success", false):
		return path_check
	var abs_path: String = path_check["result"]["path"]

	var exists_file: bool = FileAccess.file_exists(abs_path)
	var exists_dir: bool = DirAccess.dir_exists_absolute(abs_path)

	if not exists_file and not exists_dir:
		return PluginErrors.io_error(plugin_id, abs_path, "path does not exist")

	var kind: String = "file" if exists_file else "dir"
	var size: int = 0
	if exists_file:
		var fa_tmp := FileAccess.open(abs_path, FileAccess.READ)
		if fa_tmp != null:
			size = fa_tmp.get_length()
			fa_tmp.close()
	var modified_unix: int = int(FileAccess.get_modified_time(abs_path))

	print("[CapabilityBroker] Plugin '%s' stat '%s' → kind=%s size=%d" % [plugin_id, abs_path, kind, size])
	return PluginErrors.success({
		"path": abs_path,
		"kind": kind,
		"size": size,
		"modified_unix": modified_unix,
	})


## Create a scoped directory.
##
## Args: {path: String, parents?: bool} (default parents=false)
##
## Idempotent: if the path already exists as a directory, returns created=false (success).
## If it exists as a file, returns io_error.
## On success: {path, created: bool}
## Errors: schema_validation_failed, filesystem_disabled, target_not_allowlisted, io_error.
func _handle_host_files_mkdir(plugin_id: String, args: Dictionary) -> Dictionary:
	var arg_check := _validate_files_args(plugin_id, args, _FILES_MKDIR_ALLOWED_ARGS)
	if not arg_check.get("success", false):
		return arg_check

	var def: PluginDefinition = _get_plugin_definition(plugin_id)
	if def == null or def.filesystem_mode != "scoped_paths" or def.filesystem_paths.is_empty():
		return PluginErrors.filesystem_disabled(plugin_id, "host.files.mkdir")

	var path_check := validate_files_path(plugin_id, str(args.get("path", "")), def.filesystem_paths)
	if not path_check.get("success", false):
		return path_check
	var abs_path: String = path_check["result"]["path"]

	# Idempotent: already a directory → success with created=false.
	if DirAccess.dir_exists_absolute(abs_path):
		print("[CapabilityBroker] Plugin '%s' mkdir '%s' (already exists)" % [plugin_id, abs_path])
		return PluginErrors.success({"path": abs_path, "created": false})

	# Exists as a file → error.
	if FileAccess.file_exists(abs_path):
		return PluginErrors.io_error(plugin_id, abs_path,
			"path already exists as a file; cannot create directory there")

	var parents: bool = bool(args.get("parents", false))
	var err: int
	if parents:
		err = DirAccess.make_dir_recursive_absolute(abs_path)
	else:
		err = DirAccess.make_dir_absolute(abs_path)

	if err != OK:
		return PluginErrors.io_error(plugin_id, abs_path,
			"mkdir%s failed: error=%d" % ["_recursive" if parents else "", err])

	print("[CapabilityBroker] Plugin '%s' mkdir '%s' (created, parents=%s)" % [plugin_id, abs_path, str(parents)])
	return PluginErrors.success({"path": abs_path, "created": true})


## Delete a scoped file or directory.
##
## Args: {path: String, recursive?: bool} (default recursive=false)
##
## Files: removed regardless of recursive flag.
## Directories: if recursive=false, DirAccess.remove_absolute (fails if non-empty).
## If recursive=true, walk and remove contents first (with per-path scope checks),
## then remove the directory itself.
##
## On success: {path, removed: true, kind: "file"|"dir", entries_removed?: int}
## Errors: schema_validation_failed, filesystem_disabled, target_not_allowlisted, io_error.
func _handle_host_files_delete(plugin_id: String, args: Dictionary) -> Dictionary:
	var arg_check := _validate_files_args(plugin_id, args, _FILES_DELETE_ALLOWED_ARGS)
	if not arg_check.get("success", false):
		return arg_check

	var def: PluginDefinition = _get_plugin_definition(plugin_id)
	if def == null or def.filesystem_mode != "scoped_paths" or def.filesystem_paths.is_empty():
		return PluginErrors.filesystem_disabled(plugin_id, "host.files.delete")

	var path_check := validate_files_path(plugin_id, str(args.get("path", "")), def.filesystem_paths)
	if not path_check.get("success", false):
		return path_check
	var abs_path: String = path_check["result"]["path"]

	var is_file: bool = FileAccess.file_exists(abs_path)
	var is_dir: bool = DirAccess.dir_exists_absolute(abs_path)

	if not is_file and not is_dir:
		return PluginErrors.io_error(plugin_id, abs_path, "path does not exist")

	var kind: String = "file" if is_file else "dir"

	if is_file:
		var err := DirAccess.remove_absolute(abs_path)
		if err != OK:
			return PluginErrors.io_error(plugin_id, abs_path, "remove_absolute failed: error=%d" % err)
		print("[CapabilityBroker] Plugin '%s' delete '%s' (file)" % [plugin_id, abs_path])
		return PluginErrors.success({"path": abs_path, "removed": true, "kind": kind})

	# Directory path.
	var recursive: bool = bool(args.get("recursive", false))
	if not recursive:
		var err := DirAccess.remove_absolute(abs_path)
		if err != OK:
			return PluginErrors.io_error(plugin_id, abs_path,
				"remove_absolute failed (directory may be non-empty): error=%d" % err)
		print("[CapabilityBroker] Plugin '%s' delete '%s' (empty dir)" % [plugin_id, abs_path])
		return PluginErrors.success({"path": abs_path, "removed": true, "kind": kind})

	# Recursive directory removal with per-path scope checks.
	# _delete_recursive returns {ok: bool, count: int, error: ...} so we can
	# propagate the entry count (GDScript ints are pass-by-value, not by ref).
	var rec_result := _delete_recursive(plugin_id, abs_path, def.filesystem_paths)
	if not rec_result.get("ok", false):
		return rec_result.get("error", PluginErrors.io_error(plugin_id, abs_path, "recursive delete failed"))

	var entries_removed: int = int(rec_result.get("count", 0))
	print("[CapabilityBroker] Plugin '%s' delete '%s' (recursive, %d entries)" % [
		plugin_id, abs_path, entries_removed])
	return PluginErrors.success({
		"path": abs_path,
		"removed": true,
		"kind": kind,
		"entries_removed": entries_removed,
	})


## Recursive delete helper. Walks the tree, removes files and subdirs.
## Every path is re-validated against allowed_paths before removal.
## Returns {ok: true, count: int} on success or {ok: false, error: <PluginErrors dict>}
## on scope violation / io error. Uses a return Dictionary to carry the count because
## GDScript passes ints by value (not by reference).
func _delete_recursive(
		plugin_id: String, dir_path: String, allowed_paths: Array
) -> Dictionary:
	var da := DirAccess.open(dir_path)
	if da == null:
		return {"ok": false, "error": PluginErrors.io_error(plugin_id, dir_path,
			"recursive delete: DirAccess.open failed on '%s'" % dir_path)}

	da.include_hidden = true  # Delete everything, including hidden files.
	da.list_dir_begin()
	var children: Array[String] = []
	while true:
		var name: String = da.get_next()
		if name.is_empty():
			break
		if name == "." or name == "..":
			continue
		children.append(name)
	da.list_dir_end()

	var total_count: int = 0

	for name in children:
		var child: String = dir_path.path_join(name)
		# Defense-in-depth: re-validate each child (guards against escape symlinks).
		if not is_path_in_scope(child, allowed_paths):
			return {"ok": false, "error": PluginErrors.target_not_allowlisted(plugin_id, child)}

		if DirAccess.dir_exists_absolute(child):
			var sub_result := _delete_recursive(plugin_id, child, allowed_paths)
			if not sub_result.get("ok", false):
				return sub_result
			total_count += int(sub_result.get("count", 0))
		else:
			var child_err := DirAccess.remove_absolute(child)
			if child_err != OK:
				return {"ok": false, "error": PluginErrors.io_error(plugin_id, child,
					"recursive delete: remove_absolute failed on '%s': error=%d" % [child, child_err])}
			total_count += 1

	# Remove the now-empty directory itself.
	var err := DirAccess.remove_absolute(dir_path)
	if err != OK:
		return {"ok": false, "error": PluginErrors.io_error(plugin_id, dir_path,
			"recursive delete: remove_absolute failed on dir '%s': error=%d" % [dir_path, err])}
	total_count += 1
	return {"ok": true, "count": total_count}


## Move/rename a scoped path.
##
## Args: {source: String, dest: String, overwrite?: bool} (default overwrite=false)
##
## Both source and dest must be within scope. If dest exists and overwrite=false →
## io_error. If dest exists and overwrite=true → delete dest first (files or empty dirs).
## On success: {source, dest, overwritten: bool}
## Errors: schema_validation_failed, filesystem_disabled, target_not_allowlisted, io_error.
func _handle_host_files_move(plugin_id: String, args: Dictionary) -> Dictionary:
	# Strict allowlist — note: source+dest replace the standard "path" requirement.
	for k in args.keys():
		if k not in _FILES_MOVE_ALLOWED_ARGS:
			return PluginErrors.schema_validation_failed(
				plugin_id, "unknown arg '%s' (allowed: %s)" % [k, str(_FILES_MOVE_ALLOWED_ARGS)]
			)
	if not args.has("source") or str(args.get("source", "")).is_empty():
		return PluginErrors.schema_validation_failed(plugin_id, "'source' is required")
	if not args.has("dest") or str(args.get("dest", "")).is_empty():
		return PluginErrors.schema_validation_failed(plugin_id, "'dest' is required")

	var def: PluginDefinition = _get_plugin_definition(plugin_id)
	if def == null or def.filesystem_mode != "scoped_paths" or def.filesystem_paths.is_empty():
		return PluginErrors.filesystem_disabled(plugin_id, "host.files.move")

	# Validate both source and dest independently.
	var src_check := validate_files_path(plugin_id, str(args["source"]), def.filesystem_paths)
	if not src_check.get("success", false):
		return src_check
	var abs_source: String = src_check["result"]["path"]

	var dst_check := validate_files_path(plugin_id, str(args["dest"]), def.filesystem_paths)
	if not dst_check.get("success", false):
		return dst_check
	var abs_dest: String = dst_check["result"]["path"]

	if not FileAccess.file_exists(abs_source) and not DirAccess.dir_exists_absolute(abs_source):
		return PluginErrors.io_error(plugin_id, abs_source, "source path does not exist")

	var overwrite: bool = bool(args.get("overwrite", false))
	var dest_exists_file: bool = FileAccess.file_exists(abs_dest)
	var dest_exists_dir: bool = DirAccess.dir_exists_absolute(abs_dest)
	var dest_exists: bool = dest_exists_file or dest_exists_dir
	var overwritten := false

	if dest_exists:
		if not overwrite:
			return PluginErrors.io_error(plugin_id, abs_dest,
				"dest exists; pass overwrite=true to replace")
		# overwrite=true: delete dest. Dirs must be empty (no recursive overwrite).
		var del_err: int = DirAccess.remove_absolute(abs_dest)
		if del_err != OK:
			return PluginErrors.io_error(plugin_id, abs_dest,
				"overwrite: remove_absolute failed on dest: error=%d" % del_err)
		overwritten = true

	var rename_err := DirAccess.rename_absolute(abs_source, abs_dest)
	if rename_err != OK:
		return PluginErrors.io_error(plugin_id, abs_source,
			"rename_absolute failed: error=%d" % rename_err)

	print("[CapabilityBroker] Plugin '%s' move '%s' → '%s' (overwritten=%s)" % [
		plugin_id, abs_source, abs_dest, str(overwritten)])
	return PluginErrors.success({"source": abs_source, "dest": abs_dest, "overwritten": overwritten})


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


# ---------------------------------------------------------------------------
# host.providers.chat handler
# ---------------------------------------------------------------------------

## Maximum total image payload size (approximate decoded bytes) per request.
const _CHAT_MAX_IMAGE_BYTES := 10 * 1024 * 1024  # 10 MB

## Invoke a Minerva provider with a canonical message envelope.
##
## Args (required — one of 'model' or 'model_spec' must be present):
##   messages:    Array of {role, text, images?} — mirrors ChatHistoryItem wire format.
##   model:       String — model name (e.g. "claude-sonnet-4-6") or "default".
##                Mutually exclusive with model_spec; if both are present, model_spec wins.
##   model_spec:  Dictionary — structured provider spec (preferred over model string).
##                Enables routing to Core-action providers and avoids brittle display-name
##                string matching. Three supported shapes (mirrors ProviderOptionButton spec):
##                  {kind: "core_action", service_client_id: String, service_name: String, action_name: String}
##                  {kind: "dynamic",    model_id: int}   # model_id >= DYNAMIC_MODEL_ID_BASE (10000)
##                  {kind: "builtin",    model_id: int}   # model_id is a key in API_MODEL_PROVIDER_SCRIPTS
## Args (optional):
##   provider:    String — disambiguates when model is offered by multiple providers.
##   max_tokens:  int
##   temperature: float
##
## Returns: PluginErrors.success({model, provider, content, stop_reason, usage}) or error dict.
func _handle_host_providers_chat(plugin_id: String, args: Dictionary) -> Dictionary:
	# --- 1. Validate required args -------------------------------------------
	if not args.has("messages") or not (args["messages"] is Array):
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.providers.chat requires 'messages' (Array)")

	var has_model: bool = args.has("model")
	var has_spec: bool = args.has("model_spec") and (args["model_spec"] is Dictionary)

	if not has_model and not has_spec:
		return PluginErrors.schema_validation_failed(plugin_id,
			"host.providers.chat requires 'model' (String) or 'model_spec' (Dictionary)")

	# model_spec takes precedence over model when both are provided.
	var model_name_req: String = ""
	if not has_spec:
		model_name_req = str(args["model"]).strip_edges()
		if model_name_req.is_empty():
			return PluginErrors.schema_validation_failed(plugin_id,
				"host.providers.chat: 'model' must not be empty")

	var messages_raw: Array = args["messages"] as Array
	for i in range(messages_raw.size()):
		if not (messages_raw[i] is Dictionary):
			return PluginErrors.schema_validation_failed(plugin_id,
				"host.providers.chat: messages[%d] must be a Dictionary" % i)
		var msg: Dictionary = messages_raw[i] as Dictionary
		if not msg.has("role"):
			return PluginErrors.schema_validation_failed(plugin_id,
				"host.providers.chat: messages[%d] missing 'role'" % i)
		# Accept OpenAI-standard "content" as alias for legacy "text".
		# Either field satisfies the schema; readers fall back content→text below.
		if not msg.has("text") and not msg.has("content"):
			return PluginErrors.schema_validation_failed(plugin_id,
				"host.providers.chat: messages[%d] missing 'text' (or 'content')" % i)

	var provider_hint: String = str(args.get("provider", "")).strip_edges().to_lower()

	# --- 2. Payload size check (approximate decoded image bytes) -------------
	var approx_image_bytes: float = 0.0
	for msg_raw in messages_raw:
		var msg_d: Dictionary = msg_raw as Dictionary
		var imgs: Variant = msg_d.get("images", null)
		if imgs is Array:
			for b64 in (imgs as Array):
				approx_image_bytes += float(str(b64).length()) * 0.75
	if approx_image_bytes > float(_CHAT_MAX_IMAGE_BYTES):
		return PluginErrors.payload_too_large(plugin_id, _CHAT_MAX_IMAGE_BYTES, int(approx_image_bytes))

	# --- 3. Resolve provider + model via SingletonObject ---------------------
	var so = _get_singleton_object()
	if so == null:
		return PluginErrors.model_not_available(plugin_id, model_name_req)

	# Resolve "default" to the TurnRock/Core provider (free, always available).
	var resolved_model_id: int = -1
	var resolved_provider_enum: int = -1

	# --- 3a. model_spec structured resolution (bypasses string-match loop) ---
	# When model_spec is present it always wins over the model string.
	var provider: BaseProvider = null  # may be set directly by core_action path
	if has_spec:
		var spec: Dictionary = args["model_spec"] as Dictionary
		var spec_kind: String = str(spec.get("kind", "")).strip_edges()
		match spec_kind:
			"core_action":
				# Validate required fields
				if not spec.has("service_client_id") or str(spec.get("service_client_id", "")).is_empty():
					return PluginErrors.schema_validation_failed(plugin_id,
						"host.providers.chat model_spec kind='core_action' requires 'service_client_id'")
				if not spec.has("action_name") or str(spec.get("action_name", "")).is_empty():
					return PluginErrors.schema_validation_failed(plugin_id,
						"host.providers.chat model_spec kind='core_action' requires 'action_name'")
				var svc_client_id: String = str(spec["service_client_id"])
				var action_name_req: String = str(spec["action_name"])
				# Look up Core node — same pattern as AgentSpawner._create_core_provider()
				var core_node = Engine.get_main_loop().root.get_node_or_null("Core") if Engine.get_main_loop() else null
				if core_node == null:
					return PluginErrors.model_not_available(plugin_id,
						"core_action:%s/%s" % [svc_client_id, action_name_req])
				var matched_service = null
				var matched_action = null
				for svc in core_node.services:
					if svc.client_id == svc_client_id:
						for act in svc.actions:
							if act.name == action_name_req:
								matched_service = svc
								matched_action = act
								break
						if matched_action != null:
							break
				if matched_service == null or matched_action == null:
					return PluginErrors.model_not_available(plugin_id,
						"core_action:%s/%s" % [svc_client_id, action_name_req])
				# Construct CoreProvider directly — resolved_model_id stays -1 (no script_map entry)
				provider = _CoreProvider.new(matched_service, matched_action)
				model_name_req = str(provider.model_name) if "model_name" in provider else (
					"%s (%s)" % [svc_client_id, action_name_req])
				resolved_provider_enum = int(so.get("API_PROVIDER").get("TURNROCK", -1)) if "API_PROVIDER" in so else -1

			"dynamic":
				# Coerce model_id from float (JSON round-trip) to int.
				var dyn_id: int = int(spec.get("model_id", -1))
				if dyn_id < 10000:
					return PluginErrors.schema_validation_failed(plugin_id,
						"host.providers.chat model_spec kind='dynamic' requires model_id >= 10000")
				var dyn_map = so.get("_dynamic_provider_map") if "_dynamic_provider_map" in so else {}
				if not dyn_map.has(dyn_id):
					# model_id may be a per-model offset within a base range; check any entry covers it
					var covered: bool = false
					for base_id in dyn_map.keys():
						var dyn_info_d: Dictionary = dyn_map[base_id] as Dictionary
						var mgr = dyn_info_d.get("manager", null)
						if mgr == null:
							continue
						for cfg_d in mgr.models:
							if cfg_d is Dictionary and int(cfg_d.get("id", -1)) == dyn_id:
								covered = true
								break
						if covered:
							break
					if not covered:
						return PluginErrors.model_not_available(plugin_id, "dynamic:%d" % dyn_id)
				resolved_model_id = dyn_id
				# provider will be created below via the >= 10000 branch

			"builtin":
				# Coerce model_id from float (JSON round-trip) to int.
				var builtin_id: int = int(spec.get("model_id", -1))
				var script_map_b = so.get("API_MODEL_PROVIDER_SCRIPTS") if "API_MODEL_PROVIDER_SCRIPTS" in so else {}
				if not script_map_b.has(builtin_id):
					return PluginErrors.model_not_available(plugin_id, "builtin:%d" % builtin_id)
				resolved_model_id = builtin_id
				var pm2b = so.get("MODEL_TO_PROVIDER") if "MODEL_TO_PROVIDER" in so else {}
				resolved_provider_enum = int(pm2b.get(resolved_model_id, -1))
				# provider will be created below via the script_map2 branch

			_:
				return PluginErrors.schema_validation_failed(plugin_id,
					"host.providers.chat model_spec has unknown kind '%s' (expected core_action, dynamic, or builtin)" % spec_kind)

	elif model_name_req == "default":
		# Default → Core/TurnRock
		var api_model_providers = so.get("API_MODEL_PROVIDERS") if "API_MODEL_PROVIDERS" in so else null
		if api_model_providers != null and api_model_providers.has("TURNROCK"):
			resolved_model_id = int(api_model_providers.get("TURNROCK"))
			resolved_provider_enum = int(so.get("API_PROVIDER").get("TURNROCK", -1)) if "API_PROVIDER" in so else -1
		else:
			return PluginErrors.model_not_available(plugin_id, model_name_req)
	else:
		# Search all registered model scripts for a match on model_name.
		# Collect all (model_id, provider_enum) pairs whose model_name matches.
		var provider_map = so.get("MODEL_TO_PROVIDER") if "MODEL_TO_PROVIDER" in so else null
		var script_map = so.get("API_MODEL_PROVIDER_SCRIPTS") if "API_MODEL_PROVIDER_SCRIPTS" in so else null
		var display_names = so.get("PROVIDER_DISPLAY_NAMES") if "PROVIDER_DISPLAY_NAMES" in so else {}

		if script_map == null or provider_map == null:
			return PluginErrors.model_not_available(plugin_id, model_name_req)

		var candidates: Array = []  # [{model_id, provider_enum, provider_name}]

		# Check built-in (static) models
		for mid in script_map.keys():
			var mid_int: int = int(mid)
			if mid_int < 0:
				continue
			var pscript = script_map[mid_int]
			if pscript == null:
				continue
			# Instantiate temporarily to read model_name — only for static models
			# (dynamic models are handled separately via managers).
			if mid_int < 10000:  # Below DYNAMIC_MODEL_ID_BASE
				var inst: BaseProvider = pscript.new() if pscript.can_instantiate() else null
				if inst == null:
					continue
				var inst_model: String = str(inst.model_name) if "model_name" in inst else ""
				var prov_enum: int = int(provider_map.get(mid_int, -1))
				var prov_name: String = str(display_names.get(prov_enum, "")).to_lower()
				if inst_model.to_lower() == model_name_req.to_lower():
					candidates.append({
						"model_id": mid_int,
						"provider_enum": prov_enum,
						"provider_name": prov_name,
					})
				inst.free()

		# Check dynamic models via managers
		var dyn_map = so.get("_dynamic_provider_map") if "_dynamic_provider_map" in so else {}
		for id_base in dyn_map.keys():
			var dyn_info: Dictionary = dyn_map[id_base] as Dictionary
			var manager = dyn_info.get("manager", null)
			var prov_e: int = int(dyn_info.get("provider", -1))
			var prov_n: String = str(display_names.get(prov_e, "")).to_lower()
			if manager == null:
				continue
			for config in manager.models:
				if not (config is Dictionary):
					continue
				var cfg: Dictionary = config as Dictionary
				var cfg_model: String = str(cfg.get("model_name", "")).to_lower()
				if cfg_model == model_name_req.to_lower():
					candidates.append({
						"model_id": int(cfg.get("id", -1)),
						"provider_enum": prov_e,
						"provider_name": prov_n,
					})

		if candidates.is_empty():
			return PluginErrors.model_not_available(plugin_id, model_name_req)

		if candidates.size() == 1:
			resolved_model_id = int(candidates[0]["model_id"])
			resolved_provider_enum = int(candidates[0]["provider_enum"])
		else:
			# Multiple providers — filter by provider_hint if given
			if not provider_hint.is_empty():
				var filtered: Array = []
				for c in candidates:
					if str(c["provider_name"]).to_lower() == provider_hint:
						filtered.append(c)
				if filtered.size() == 1:
					resolved_model_id = int(filtered[0]["model_id"])
					resolved_provider_enum = int(filtered[0]["provider_enum"])
				elif filtered.is_empty():
					# Hint given but matched nothing → ambiguous (still return all candidates)
					var cand_names: Array = []
					for c in candidates:
						cand_names.append(str(c["provider_name"]))
					return PluginErrors.model_ambiguous(plugin_id, model_name_req, cand_names)
				else:
					# Multiple even after hint — still ambiguous
					var cand_names2: Array = []
					for c in filtered:
						cand_names2.append(str(c["provider_name"]))
					return PluginErrors.model_ambiguous(plugin_id, model_name_req, cand_names2)
			else:
				var cand_names3: Array = []
				for c in candidates:
					cand_names3.append(str(c["provider_name"]))
				return PluginErrors.model_ambiguous(plugin_id, model_name_req, cand_names3)

	# --- Create the provider instance ----------------------------------------
	# provider may already be set (core_action path above); only instantiate when not.
	var provider_map2 = so.get("MODEL_TO_PROVIDER") if "MODEL_TO_PROVIDER" in so else {}
	var script_map2 = so.get("API_MODEL_PROVIDER_SCRIPTS") if "API_MODEL_PROVIDER_SCRIPTS" in so else {}

	if provider == null:
		if resolved_model_id < 0:
			return PluginErrors.model_not_available(plugin_id, model_name_req)

		if resolved_model_id >= 10000:  # Dynamic model
			provider = so.create_dynamic_provider(resolved_model_id)
		elif script_map2.has(resolved_model_id):
			var pscript = script_map2[resolved_model_id]
			if pscript != null and pscript.can_instantiate():
				provider = pscript.new()

	if provider == null:
		return PluginErrors.model_not_available(plugin_id, model_name_req)

	# Guard: the script_map "default" path instantiates CoreProvider with no
	# service/action, producing a non-functional provider that would later fail
	# inside generate_content. Surface the missing context as a clear error
	# pointing callers at the explicit model_spec path.
	if provider is CoreProvider and provider.service == null:
		provider.queue_free()
		return PluginErrors.model_not_available(plugin_id,
			"%s — 'default' needs model_spec={kind:'core_action', service_client_id, action_name}" % model_name_req)

	# Provider must be in the scene tree to use _ready() and timers
	var so_node = Engine.get_main_loop().root.get_node_or_null("SingletonObject") if Engine.get_main_loop() else null
	if so_node != null:
		so_node.add_child(provider)

	# --- Get actual provider name + check enabled ----------------------------
	var display_names2: Dictionary = so.get("PROVIDER_DISPLAY_NAMES") if "PROVIDER_DISPLAY_NAMES" in so else {}
	var actual_provider_enum: int = int(provider_map2.get(resolved_model_id, resolved_provider_enum))
	var actual_provider_name: String = str(display_names2.get(actual_provider_enum, "Unknown")).to_lower()
	var actual_model_name: String = str(provider.model_name) if "model_name" in provider else model_name_req

	# Check if plugins are allowed to use this provider. Distinct from
	# is_provider_enabled (which is a menu-filter for selection UIs); the
	# plugin gate defaults true so plugins inherit the same access the chat UI
	# has. Users can opt out per-provider via set_provider_allowed_for_plugins.
	if so.has_method("is_provider_allowed_for_plugins"):
		if not so.is_provider_allowed_for_plugins(actual_provider_enum):
			provider.queue_free()
			return PluginErrors.provider_disabled(plugin_id, actual_provider_name)
	# Check API key (non-free providers only; free providers have empty API_KEY by design)
	# We check by seeing if input_token_cost > 0 AND API_KEY is empty as a heuristic.
	# Local/Turnrock are exempt — their cost reflects server-side metering, not a
	# user-supplied key (Core auth is socket-level; Local has no remote at all).
	var api_provider_const: Variant = so.get("API_PROVIDER") if "API_PROVIDER" in so else null
	var is_keyless_provider: bool = false
	if api_provider_const != null:
		var turnrock_enum: int = int(api_provider_const.get("TURNROCK", -1))
		var local_enum: int = int(api_provider_const.get("LOCAL", -1))
		is_keyless_provider = (actual_provider_enum == turnrock_enum) or (actual_provider_enum == local_enum)
	var api_key_val: String = str(provider.API_KEY) if "API_KEY" in provider else ""
	if not is_keyless_provider and provider.input_token_cost > 0.0 and api_key_val.is_empty():
		provider.queue_free()
		return PluginErrors.provider_disabled(plugin_id, actual_provider_name)

	# --- 4. Hierarchical budget check ----------------------------------------
	var cost_tracker = so.get("cost_tracker") if "cost_tracker" in so else null
	if cost_tracker != null and cost_tracker.has_method("check_hierarchical_budget"):
		var budget_check: Dictionary = cost_tracker.check_hierarchical_budget(
			plugin_id, actual_provider_name, actual_model_name)
		if not budget_check.get("ok", true):
			provider.queue_free()
			return PluginErrors.budget_exceeded(
				plugin_id,
				str(budget_check.get("which_budget", "")),
				float(budget_check.get("budget", 0.0)),
				float(budget_check.get("spent", 0.0)),
				str(budget_check.get("period", "day")),
			)

	# --- 5. Reconstruct ChatHistoryItems from args.messages[] ----------------
	var prompt: Array[Variant] = []
	for msg_raw2 in messages_raw:
		var msg_d2: Dictionary = msg_raw2 as Dictionary
		var role_str: String = str(msg_d2.get("role", "user")).to_lower()
		var text_str: String = str(msg_d2.get("text", msg_d2.get("content", "")))

		var chi := ChatHistoryItem.new()

		# Map role string to ChatRole enum
		match role_str:
			"system":
				chi.Role = ChatHistoryItem.ChatRole.SYSTEM
			"assistant":
				chi.Role = ChatHistoryItem.ChatRole.ASSISTANT
			"model":
				chi.Role = ChatHistoryItem.ChatRole.MODEL
			"tool":
				chi.Role = ChatHistoryItem.ChatRole.TOOL
			_:  # "user" and anything else
				chi.Role = ChatHistoryItem.ChatRole.USER

		chi.Message = text_str
		chi.provider = provider

		# Decode base64-PNG images
		var imgs_raw: Variant = msg_d2.get("images", null)
		if imgs_raw is Array:
			var img_arr: Array[Image] = []
			for b64_str in (imgs_raw as Array):
				var raw_bytes: PackedByteArray = Marshalls.base64_to_raw(str(b64_str))
				if not raw_bytes.is_empty():
					var img := Image.new()
					if img.load_png_from_buffer(raw_bytes) == OK:
						img_arr.append(img)
			chi.Images = img_arr
			# CoreProvider.Format builds its multimodal payload from
			# InjectedNotes — Images alone gets dropped at Format-time. Mirror
			# the chat UI pattern (where user-attached image notes flow through
			# notes_container.to_prompt → InjectedNotes) so plugin-supplied
			# images actually reach the model.
			for img in img_arr:
				chi.InjectedNotes.append(img)

		prompt.append(chi)

	# Bridge ChatHistoryItem → provider-specific dict shape via provider.Format().
	# Mirrors the chat UI pattern (ChatPane.gd:442-445, NotesChatTab.gd:80). Without
	# this, providers that ship `messages: [...]` as a JSON array (e.g., CoreProvider's
	# OpenAI-compatible path at line 145) serialize the raw RefCounted objects and the
	# server rejects them — e.g., model-chat returns 'dictionary update sequence
	# element #0 has length 1; 2 is required' from Python's dict() constructor.
	if provider.has_method("Format"):
		var formatted_prompt: Array[Variant] = []
		for chi_item in prompt:
			var formatted: Variant = provider.Format(chi_item)
			if formatted != null:
				formatted_prompt.append(formatted)
		prompt = formatted_prompt

	# --- 6. Set provider chat IDs for cost attribution and stop_all_requests -
	var chat_id_key: String = "plugin/%s" % plugin_id
	provider.chat_id = chat_id_key
	provider.owner_history_id = chat_id_key

	# --- 7. Build additional_params ------------------------------------------
	var additional_params: Dictionary = {}
	if args.has("max_tokens"):
		var mt: Variant = args["max_tokens"]
		if mt is int or mt is float:
			additional_params["max_tokens"] = int(mt)
	if args.has("temperature"):
		var temp: Variant = args["temperature"]
		if temp is float or temp is int:
			additional_params["temperature"] = float(temp)

	# --- 8. Generate content -------------------------------------------------
	print("[CapabilityBroker] Plugin '%s' invoking host.providers.chat (model=%s, provider=%s)" % [
		plugin_id, actual_model_name, actual_provider_name])
	plugin_chat_invoked.emit(plugin_id, actual_provider_name, actual_model_name)
	var _chat_start_us: int = Time.get_ticks_msec()

	var bot_response: BotResponse = await provider.generate_content(prompt, additional_params)

	var _chat_duration_ms: int = Time.get_ticks_msec() - _chat_start_us

	# Detach from scene tree now that the call is done
	if provider.get_parent() != null:
		provider.get_parent().remove_child(provider)

	if bot_response == null:
		plugin_chat_completed.emit(plugin_id, actual_provider_name, actual_model_name,
			_chat_duration_ms, false, 0, 0, "generate_content returned null")
		provider.queue_free()
		return PluginErrors.provider_error(plugin_id, actual_provider_name, actual_model_name,
			"generate_content returned null")

	if not str(bot_response.error).is_empty():
		plugin_chat_completed.emit(plugin_id, actual_provider_name, actual_model_name,
			_chat_duration_ms, false, 0, 0, str(bot_response.error))
		provider.queue_free()
		return PluginErrors.provider_error(plugin_id, actual_provider_name, actual_model_name,
			str(bot_response.error))

	plugin_chat_completed.emit(plugin_id, actual_provider_name, actual_model_name,
		_chat_duration_ms, true,
		int(bot_response.prompt_tokens), int(bot_response.completion_tokens), "")

	# --- 9. Record cost -------------------------------------------------------
	if cost_tracker != null and cost_tracker.has_method("record_chat_cost"):
		cost_tracker.record_chat_cost(bot_response, chat_id_key)

	# --- 10. Build response ---------------------------------------------------
	var input_tok: int = int(bot_response.prompt_tokens)
	var output_tok: int = int(bot_response.completion_tokens)
	var cost_usd: float = (
		float(input_tok) * provider.input_token_cost +
		float(output_tok) * provider.output_token_cost
	) / 1_000_000.0
	var is_free: bool = provider.input_token_cost == 0.0 and provider.output_token_cost == 0.0

	provider.queue_free()

	# Emit OpenAI-shape response so plugins built around the standard shape (e.g.,
	# reading choices[0].message.content) Just Work. Most LLM providers — and the
	# model-chat backend in particular — already speak OpenAI shape natively; we
	# preserve it through the broker rather than flattening and re-inflating.
	# Provider name + cost summary live alongside the OpenAI fields for callers
	# that want Minerva-specific context (these are additive, not in conflict).
	return PluginErrors.success({
		"model": actual_model_name,
		"choices": [{
			"index": 0,
			"message": {
				"role": "assistant",
				"content": str(bot_response.text),
			},
			"finish_reason": "stop",
		}],
		"usage": {
			"prompt_tokens": input_tok,
			"completion_tokens": output_tok,
			"total_tokens": input_tok + output_tok,
		},
		"provider": actual_provider_name,
		"cost_usd": cost_usd,
		"free": is_free,
	})


## Helper to get the SingletonObject node (or null in headless context).
func _get_singleton_object():
	var root = Engine.get_main_loop().root if Engine.get_main_loop() else null
	if root == null:
		return null
	return root.get_node_or_null("SingletonObject")


# ---------------------------------------------------------------------------
# host.editors.open handler
# ---------------------------------------------------------------------------

## Strict args allowlist for host.editors.open.
const _EDITORS_OPEN_ALLOWED_ARGS := ["path"]


## host.editors.open — open a file at an absolute path as an editor tab.
##
## Args: {path: String}.  The host dispatches the open via
## SingletonObject.open_file_at_path which handles idempotency (returns the
## existing tab if already open) and extension → plugin/editor-type routing.
##
## On success returns {tab_name, kind, plugin_id, panel_name, path,
## was_already_open}.  The was_already_open flag is best-effort: SingletonObject
## doesn't report it directly, so we infer by checking the editor list before
## the dispatch.
##
## Errors: schema_validation_failed, file_not_found, editor_pane_unavailable,
## open_failed.
func _handle_host_editors_open(plugin_id: String, args: Dictionary) -> Dictionary:
	for k in args.keys():
		if k not in _EDITORS_OPEN_ALLOWED_ARGS:
			return PluginErrors.schema_validation_failed(
				plugin_id, "unknown arg '%s' (allowed: %s)" % [k, str(_EDITORS_OPEN_ALLOWED_ARGS)]
			)

	var path: String = str(args.get("path", "")).strip_edges()
	if path.is_empty():
		return PluginErrors.schema_validation_failed(
			plugin_id, "host.editors.open requires 'path'"
		)

	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject") if Engine.get_main_loop() else null
	if so == null or not so.has_method("open_file_at_path"):
		return {
			"success": false,
			"error_code": "editor_pane_unavailable",
			"error_message": "open_file_at_path not available (headless or pre-MainScene)",
			"plugin_id": plugin_id,
		}

	# Best-effort was_already_open detection: scan the editor list for a tab
	# whose file matches the resolved absolute path BEFORE dispatching.
	var was_already_open: bool = false
	var editor_pane = _get_editor_pane()
	if editor_pane != null and editor_pane.has_method("get_open_editors"):
		for ed in editor_pane.get_open_editors():
			if ed != null and "file" in ed and str(ed.file) == path:
				was_already_open = true
				break

	var result: Dictionary = so.open_file_at_path(path)
	if not result.get("ok", false):
		var errors: Array = result.get("errors", [])
		var msg: String = ", ".join(errors) if errors.size() > 0 else "open_file_at_path returned ok=false"
		# Differentiate failure modes via the error string. Order matters:
		# editor_pane is the headless / pre-MainScene case, file_not_found is
		# the bad-path case, everything else collapses to open_failed.
		var code: String = "open_failed"
		for e in errors:
			var es: String = str(e)
			if es.begins_with("file_not_found") or es.begins_with("not_a_file"):
				code = "file_not_found"
				break
			if es.find("editor_pane") >= 0:
				code = "editor_pane_unavailable"
				break
		return {
			"success": false,
			"error_code": code,
			"error_message": msg,
			"plugin_id": plugin_id,
			"path": path,
		}

	print("[CapabilityBroker] Plugin '%s' opened editor '%s' (already_open=%s)" % [
		plugin_id, str(result.get("editor_name", "")), str(was_already_open)])
	return PluginErrors.success({
		"tab_name": str(result.get("editor_name", "")),
		"kind": str(result.get("editor_kind", "")).to_lower(),
		"plugin_id": result.get("plugin_id"),
		"panel_name": result.get("panel_name"),
		"path": path,
		"was_already_open": was_already_open,
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


## Resolve the canonical DocumentBuffer for an editor (or null if the editor
## is panel-canonical / anonymous / unbacked).
##
## For PLUGIN_SCENE editors, ONLY the broker-attached buffer counts (the
## paired_dsl pattern, attached explicitly via PluginScenePanelBroker
## .attach_buffer_to_panel). Path-keyed DocumentRegistry lookups are NOT
## consulted — host_owned_save panels (.mdeck) own state in panel memory
## and any incidental path-keyed buffer would silently bypass the
## panel-canonical IPC round-trip (and thus the broker's blob-strip walker)
## in get_node/get_state/patch_state/set_state. See hint
## minerva-plugin-platform/host-documents-get-node-buffer-canonical-bypasses-strip
## for the bypass class this resolution rule closes.
##
## For non-PLUGIN_SCENE editors (text, graphics, etc.), the path-keyed
## registry fallthrough is still in place — that's how MCPDocTools'
## doc_read/doc_write surface for those editor types.
func _resolve_editor_buffer(editor) -> DocumentBuffer:
	var ed_type: int = int(editor.type) if "type" in editor else -1
	var pid: String = str(editor.plugin_id) if "plugin_id" in editor else ""
	var pname: String = str(editor.panel_name) if "panel_name" in editor else ""
	var ed_file: String = str(editor.file) if "file" in editor else ""

	if ed_type == Editor.Type.PLUGIN_SCENE:
		# Only the broker-attached buffer (paired_dsl) counts here. Returning
		# null for plugin-scene editors without an attached buffer routes the
		# capability handlers through the panel-canonical request_panel_state
		# path — which is where the strip walker lives.
		var so_root = Engine.get_main_loop().root.get_node_or_null("SingletonObject") if Engine.get_main_loop() else null
		var pbroker = null
		if so_root != null and "plugin_scene_panel_broker" in so_root:
			pbroker = so_root.get("plugin_scene_panel_broker")
		if pbroker != null and not pid.is_empty() and not pname.is_empty() \
				and pbroker.has_method("get_attached_buffer"):
			var attached: DocumentBuffer = pbroker.get_attached_buffer(pid, pname)
			if attached != null:
				return attached
		# No broker-attached buffer → panel-canonical. Do NOT fall through to
		# the path-keyed registry lookup below (that would create an incidental
		# buffer and bypass the strip walker).
		return null

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
##
## INVARIANT: `buffer.text` is emitted raw to the wire with no blob-strip pass.
## This is safe TODAY because the only producer of buffer-canonical state via
## `_resolve_editor_buffer` is the paired_dsl pattern (PluginScenePanelBroker
## .attach_buffer_to_panel), and all paired_dsl plugins in-tree carry plain
## text (e.g. `.mcad` DSL source). A future paired_dsl plugin emitting JSON
## with `{__blob__, content_type, bytes}` envelopes WOULD bypass the strip
## walker here — same R3 coupling class as phase 5 R7's get_node bypass.
##
## If such a plugin is added: detect JSON in `buffer.text`, run the strip
## walker on the parsed value, re-stringify before emitting. Companion
## docket follow-up tracks this latent gap; the missing paired_dsl
## `get_state` integration test would have caught it in review.
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
# host.dialogs handlers
# ---------------------------------------------------------------------------

## Strict args allowlists for host.dialogs pickers.
const _DIALOGS_FILE_PICKER_ALLOWED_ARGS := ["title", "initial_path", "filters", "mode"]
const _DIALOGS_DIRECTORY_PICKER_ALLOWED_ARGS := ["title", "initial_path"]


## host.dialogs.file_picker — pop a FileDialog in file mode and await selection.
##
## Args (all optional):
##   title:        String — dialog title (default "Choose File")
##   initial_path: String — sets FileDialog.current_path if non-empty
##   filters:      Array of String — FileDialog filter strings (e.g. "*.txt ; Text Files")
##   mode:         String — "open" (default) or "save"
##
## Returns (success result):
##   On pick:   {cancelled: false, path: String}
##   On cancel: {cancelled: true}
##
## Errors: schema_validation_failed, dialog_unavailable (headless without override).
func _handle_host_dialogs_file_picker(plugin_id: String, args: Dictionary) -> Dictionary:
	# 1. Strict arg allowlist check
	for k in args.keys():
		if k not in _DIALOGS_FILE_PICKER_ALLOWED_ARGS:
			return PluginErrors.schema_validation_failed(
				plugin_id, "unknown arg '%s' (allowed: %s)" % [k, str(_DIALOGS_FILE_PICKER_ALLOWED_ARGS)]
			)

	# Validate mode
	var mode: String = str(args.get("mode", "open")).strip_edges().to_lower()
	if mode != "open" and mode != "save":
		return PluginErrors.schema_validation_failed(
			plugin_id, "host.dialogs.file_picker: 'mode' must be 'open' or 'save' (got: '%s')" % mode
		)

	# Validate filters — each entry must be a String
	var raw_filters = args.get("filters", [])
	if not (raw_filters is Array):
		return PluginErrors.schema_validation_failed(
			plugin_id, "host.dialogs.file_picker: 'filters' must be an Array"
		)
	for i in range((raw_filters as Array).size()):
		if not ((raw_filters as Array)[i] is String):
			return PluginErrors.schema_validation_failed(
				plugin_id, "host.dialogs.file_picker: filters[%d] must be a String" % i
			)

	# 2. Test override short-circuit
	if CapabilityBroker._test_dialog_override != null:
		var injected = CapabilityBroker._test_dialog_override
		CapabilityBroker._test_dialog_override = null
		return PluginErrors.success(injected)

	# 3. Headless guard
	if DisplayServer.get_name() == "headless":
		return {
			"success": false,
			"error_code": "dialog_unavailable",
			"error_message": "host.dialogs.* requires a UI session; tests must use _test_dialog_override",
			"plugin_id": plugin_id,
		}

	# 4. Build and pop the dialog
	var title: String = str(args.get("title", "Choose File"))
	var initial_path: String = str(args.get("initial_path", ""))
	var filters: Array = raw_filters as Array

	var dialog := FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE if mode == "save" else FileDialog.FILE_MODE_OPEN_FILE
	dialog.title = title
	if not initial_path.is_empty():
		dialog.current_path = initial_path
	if not filters.is_empty():
		dialog.filters = PackedStringArray(filters)

	Engine.get_main_loop().root.add_child(dialog)

	# Dialog state lives in a Dictionary so the signal-handler lambdas mutate
	# the same instance via reference. Plain `var` primitives don't work here:
	# GDScript lambdas capture primitives by value, so `done = true` inside the
	# lambda would write to the lambda's local slot and the `while not done`
	# loop would spin forever.
	var state: Dictionary = {
		"picked_path": "",
		"cancelled": false,
		"done": false,
	}

	dialog.file_selected.connect(func(p: String):
		state.picked_path = p
		state.done = true
	)
	dialog.canceled.connect(func():
		state.cancelled = true
		state.done = true
	)

	dialog.popup_centered(Vector2i(700, 500))

	while not state.done:
		await Engine.get_main_loop().process_frame

	dialog.queue_free()

	if state.cancelled:
		return PluginErrors.success({"cancelled": true})
	return PluginErrors.success({"cancelled": false, "path": state.picked_path})


## host.dialogs.directory_picker — pop a FileDialog in directory mode and await selection.
##
## Args (all optional):
##   title:        String — dialog title (default "Choose Directory")
##   initial_path: String — sets FileDialog.current_path if non-empty
##
## Returns (success result):
##   On pick:   {cancelled: false, path: String}
##   On cancel: {cancelled: true}
##
## Errors: schema_validation_failed, dialog_unavailable (headless without override).
func _handle_host_dialogs_directory_picker(plugin_id: String, args: Dictionary) -> Dictionary:
	# 1. Strict arg allowlist check
	for k in args.keys():
		if k not in _DIALOGS_DIRECTORY_PICKER_ALLOWED_ARGS:
			return PluginErrors.schema_validation_failed(
				plugin_id, "unknown arg '%s' (allowed: %s)" % [k, str(_DIALOGS_DIRECTORY_PICKER_ALLOWED_ARGS)]
			)

	# 2. Test override short-circuit
	if CapabilityBroker._test_dialog_override != null:
		var injected = CapabilityBroker._test_dialog_override
		CapabilityBroker._test_dialog_override = null
		return PluginErrors.success(injected)

	# 3. Headless guard
	if DisplayServer.get_name() == "headless":
		return {
			"success": false,
			"error_code": "dialog_unavailable",
			"error_message": "host.dialogs.* requires a UI session; tests must use _test_dialog_override",
			"plugin_id": plugin_id,
		}

	# 4. Build and pop the dialog
	var title: String = str(args.get("title", "Choose Directory"))
	var initial_path: String = str(args.get("initial_path", ""))

	var dialog := FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.title = title
	if not initial_path.is_empty():
		dialog.current_path = initial_path

	Engine.get_main_loop().root.add_child(dialog)

	# See file_picker for why state is a Dictionary: GDScript lambdas capture
	# primitives by value, so direct `var` mutation in the signal handlers
	# wouldn't propagate to the await loop.
	var state: Dictionary = {
		"picked_path": "",
		"cancelled": false,
		"done": false,
	}

	dialog.dir_selected.connect(func(p: String):
		state.picked_path = p
		state.done = true
	)
	dialog.canceled.connect(func():
		state.cancelled = true
		state.done = true
	)

	dialog.popup_centered(Vector2i(700, 500))

	while not state.done:
		await Engine.get_main_loop().process_frame

	dialog.queue_free()

	if state.cancelled:
		return PluginErrors.success({"cancelled": true})
	return PluginErrors.success({"cancelled": false, "path": state.picked_path})


# ---------------------------------------------------------------------------
# host.permissions handler
# ---------------------------------------------------------------------------

## Strict args allowlist for host.permissions.grant_scope.
const _PERMISSIONS_GRANT_SCOPE_ALLOWED_ARGS := ["path", "reason"]


## host.permissions.grant_scope — request runtime expansion of filesystem_paths.
##
## Args:
##   path:   String (required) — absolute path to grant; must not contain '..'
##           segments or null bytes.
##   reason: String (optional) — short human-readable string shown in the
##           confirmation dialog.
##
## Returns (success result):
##   On grant (new):  {granted: true,  already_granted: false, cancelled: false, path: String}
##   On short-circuit:{granted: true,  already_granted: true,  cancelled: false, path: String}
##   On cancel:       {granted: false, already_granted: false, cancelled: true,  path: String}
##
## Errors: schema_validation_failed, dialog_unavailable (headless without override).
func _handle_host_permissions_grant_scope(plugin_id: String, args: Dictionary) -> Dictionary:
	# 1. Strict arg allowlist
	for k in args.keys():
		if k not in _PERMISSIONS_GRANT_SCOPE_ALLOWED_ARGS:
			return PluginErrors.schema_validation_failed(
				plugin_id,
				"unknown arg '%s' (allowed: %s)" % [k, str(_PERMISSIONS_GRANT_SCOPE_ALLOWED_ARGS)]
			)

	# 2. Path syntactic validation — mirrors validate_files_path's rules but
	#    intentionally does NOT call it (that would scope-check the path, defeating
	#    the whole point of this capability).
	var raw_path: Variant = args.get("path", null)
	if raw_path == null or not (raw_path is String) or (raw_path as String).is_empty():
		return PluginErrors.schema_validation_failed(plugin_id, "path is required and must be a non-empty String")

	var path_str: String = raw_path as String

	# Reject null bytes — silently truncated at libc layer.
	if path_str.contains(char(0)):
		return PluginErrors.schema_validation_failed(
			plugin_id, "path must not contain null bytes"
		)

	# Must be absolute (no user:// expansion here — grant_scope is for real FS paths)
	if not path_str.is_absolute_path():
		return PluginErrors.schema_validation_failed(
			plugin_id,
			"path must be absolute (got: '%s')" % path_str
		)

	# Reject explicit '..' segments.
	for segment in path_str.split("/"):
		if segment == "..":
			return PluginErrors.schema_validation_failed(
				plugin_id, "path must not contain '..' segments (got: '%s')" % path_str
			)

	var abs_path: String = path_str.simplify_path()

	# 3. Look up the plugin def to check / mutate filesystem_paths.
	# We reach the def through the policy engine's plugin_db.
	var def = null
	if policy != null and policy.plugin_db != null:
		def = policy.plugin_db.get_by_id(plugin_id)

	# 4. Short-circuit if already granted.
	if def != null and abs_path in def.filesystem_paths:
		return PluginErrors.success({
			"granted": true,
			"already_granted": true,
			"cancelled": false,
			"path": abs_path,
		})

	# 5. Test override short-circuit (consume ONE override, like dialogs).
	#    NOTE: checked AFTER the already-granted short-circuit so tests can
	#    verify that an already-granted path does NOT consume the override.
	if CapabilityBroker._test_dialog_override != null:
		var injected: Dictionary = CapabilityBroker._test_dialog_override
		CapabilityBroker._test_dialog_override = null
		var granted: bool = injected.get("granted", false)
		if granted and def != null:
			if abs_path not in def.filesystem_paths:
				def.filesystem_paths.append(abs_path)
			if _scope_grants != null:
				_scope_grants.grant_path(plugin_id, abs_path)
		return PluginErrors.success({
			"granted": granted,
			"already_granted": false,
			"cancelled": injected.get("cancelled", not granted),
			"path": abs_path,
		})

	# 6. Headless guard — no dialog possible without a UI session.
	if DisplayServer.get_name() == "headless":
		return {
			"success": false,
			"error_code": "dialog_unavailable",
			"error_message": "host.permissions.grant_scope requires a UI session; tests must use _test_dialog_override",
			"plugin_id": plugin_id,
		}

	# 7. Build and pop a ConfirmationDialog (yes/no — not a file picker).
	var reason: String = str(args.get("reason", ""))
	var dialog_text: String = reason
	if not dialog_text.is_empty():
		dialog_text += "\n\n"
	dialog_text += "This grant persists until you revoke it."

	var dialog := ConfirmationDialog.new()
	dialog.title = "Plugin '%s' wants access to '%s'" % [plugin_id, abs_path]
	dialog.dialog_text = dialog_text
	dialog.ok_button_text = "Allow"

	Engine.get_main_loop().root.add_child(dialog)

	# State is a Dictionary so the signal-handler lambdas can mutate by
	# reference; primitives captured by `func()` lambdas are by-value, which
	# would leave the `while not done` loop spinning forever.
	# `confirmed` is the only state we actually read — a canceled close just
	# falls through to the deny return at the bottom of the function, so we
	# don't need a separate cancel flag.
	var state: Dictionary = {
		"confirmed": false,
		"done": false,
	}

	dialog.confirmed.connect(func():
		state.confirmed = true
		state.done = true
	)
	dialog.canceled.connect(func():
		state.done = true
	)

	dialog.popup_centered()

	while not state.done:
		await Engine.get_main_loop().process_frame

	dialog.queue_free()

	if state.confirmed:
		# Mutate def.filesystem_paths and persist the grant.
		if def != null:
			if abs_path not in def.filesystem_paths:
				def.filesystem_paths.append(abs_path)
		if _scope_grants != null:
			_scope_grants.grant_path(plugin_id, abs_path)
		return PluginErrors.success({
			"granted": true,
			"already_granted": false,
			"cancelled": false,
			"path": abs_path,
		})

	return PluginErrors.success({
		"granted": false,
		"already_granted": false,
		"cancelled": true,
		"path": abs_path,
	})


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
	"buffer_text", "bytes", "bytes_b64", "data", "content", "value",
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
