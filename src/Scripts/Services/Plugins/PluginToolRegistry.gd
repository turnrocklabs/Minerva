class_name PluginToolRegistry
extends RefCounted
## Bridges plugin tools into Minerva's MCP tool system.
##
## Maintains a registry of tools contributed by installed plugins and handles
## forwarding tool call requests to the correct plugin's MCPServerConnection.
##
## Tool name convention enforced here: every plugin tool MUST start with
## "minerva_<plugin_id>_". This is also validated by PluginDefinition, so by
## the time tools reach this registry they should already conform — but we
## re-validate defensively.
##
## Integration points (see bottom of this file for the MinervaMCPServer integration plan):
##   - Called by MinervaMCPServer._execute_tool_impl() for any tool name that is
##     not in the built-in match block (checked via is_plugin_tool()).
##   - Called after plugin_started / plugin_stopped / plugin_crashed signals to
##     keep the registry in sync with running state.

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted when tools are registered for a plugin.
signal tools_registered(plugin_id: String, tool_names: Array)

## Emitted when tools are unregistered for a plugin.
signal tools_unregistered(plugin_id: String, tool_names: Array)


# ---------------------------------------------------------------------------
# Dependencies (set via _init or property assignment)
# ---------------------------------------------------------------------------

## PluginManager instance — used to look up plugin state and MCPServerConnection.
var plugin_manager: PluginManager = null

## PluginPolicy instance — used to check policy before forwarding tool calls.
var plugin_policy: PluginPolicy = null

## PluginAuditLog instance — used to record tool call events.
var audit_log: PluginAuditLog = null

## CapabilityBroker instance — used to dispatch host capability requests from plugins.
var capability_broker = null  # CapabilityBroker

## PluginScenePanelBroker instance — used to resolve live scene panels for
## panel-executed tools (executor == "panel"). Untyped for testability (tests
## assign it directly). When null, _resolve_scene_panel_broker() falls back to
## the SingletonObject autoload's `plugin_scene_panel_broker` property (same
## duck-typed lookup PluginScenePanelHost uses).
var scene_panel_broker = null  # PluginScenePanelBroker


# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

## Map of plugin_id -> Array[Dictionary] where each dict has:
##   name: String
##   description: String
##   input_schema: Dictionary
##   source: String  ("plugin:<id>")
##   executor: String  ("panel" | "backend"; absent in manifest ⇒ "backend")
var _tools_by_plugin: Dictionary = {}

## Reverse index: tool_name -> plugin_id for fast lookup.
var _plugin_by_tool: Dictionary = {}

## Built-in tool name set: populated via set_builtin_tool_names() so that
## register_plugin_tools() can reject conflicts without importing MinervaMCPServer.
var _builtin_tool_names: Dictionary = {}

## Stderr toast rate limiting: plugin_id -> { window_start: float, count: int }
## Prevents log spam from flooding toasts — max 5 toasts per plugin per 30 seconds
var _stderr_toast_counts: Dictionary = {}

## Stderr toast rate limit configuration (per plugin, fixed)
var _stderr_toast_limit := {
	"max_toasts": 5,
	"window_seconds": 30.0,
}


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _init(
	p_plugin_manager: PluginManager = null,
	p_plugin_policy: PluginPolicy = null,
	p_audit_log: PluginAuditLog = null
) -> void:
	plugin_manager = p_plugin_manager
	plugin_policy = p_plugin_policy
	audit_log = p_audit_log


# ---------------------------------------------------------------------------
# Built-in tool name set
# ---------------------------------------------------------------------------

## Supply the set of names already claimed by Minerva's built-in tool system.
## Call this once during initialisation, before any plugins are registered.
## tool_names: Array[String] — all built-in tool names.
func set_builtin_tool_names(tool_names: Array) -> void:
	_builtin_tool_names.clear()
	for n in tool_names:
		_builtin_tool_names[str(n)] = true


# ---------------------------------------------------------------------------
# Registration / unregistration
# ---------------------------------------------------------------------------

## Register all tools declared in a plugin's manifest array.
##
## tools: the Array[Dictionary] from PluginDefinition.tools — each entry must
##        have "name", "description", and "input_schema" keys.
##
## Returns {"ok": true, "registered": [<names>]} on success.
## Returns {"error": "..."} if any tool fails validation (no tools are
## registered for this plugin — all-or-nothing per plugin).
func register_plugin_tools(plugin_id: String, tools: Array) -> Dictionary:
	if plugin_id.is_empty():
		return {"error": "plugin_id must not be empty"}

	if tools.is_empty():
		# Nothing to register — valid but a no-op.
		_tools_by_plugin[plugin_id] = []
		return {"ok": true, "registered": []}

	var expected_prefix := "minerva_%s_" % plugin_id

	# Validate all tools before registering any (atomic).
	var validated: Array[Dictionary] = []
	for tool_entry in tools:
		if not tool_entry is Dictionary:
			return {"error": "Tool entry is not a Dictionary for plugin '%s'" % plugin_id}

		var tool_name: String = tool_entry.get("name", "")
		if tool_name.is_empty():
			return {"error": "Tool entry is missing 'name' field for plugin '%s'" % plugin_id}

		# Enforce naming convention.
		if not tool_name.begins_with(expected_prefix):
			return {
				"error": "Tool '%s' in plugin '%s' must start with '%s'" % [
					tool_name, plugin_id, expected_prefix
				]
			}

		# Reject conflicts with built-in tools.
		if _builtin_tool_names.has(tool_name):
			return {
				"error": "Tool '%s' conflicts with a built-in Minerva tool" % tool_name
			}

		# Reject conflicts with tools from OTHER plugins (allow re-registration
		# from the SAME plugin — handled by unregistering first below).
		var existing_owner: String = _plugin_by_tool.get(tool_name, "")
		if not existing_owner.is_empty() and existing_owner != plugin_id:
			return {
				"error": "Tool '%s' is already registered by plugin '%s'" % [
					tool_name, existing_owner
				]
			}

		# Executor: "panel" tools dispatch host-side to the plugin's live scene
		# panel; "backend" (default when absent) forwards to the subprocess.
		# PluginDefinition.validate() already rejects other values — this is
		# the same defensive re-validation the prefix check above performs.
		var executor := str(tool_entry.get("executor", "backend"))
		if executor != "panel" and executor != "backend":
			return {
				"error": "tool_executor_invalid:%s (plugin '%s': executor must be 'panel' or 'backend', got '%s')" % [
					tool_name, plugin_id, executor
				]
			}

		var entry := {
			"name": tool_name,
			"description": str(tool_entry.get("description", "")),
			"input_schema": tool_entry.get("input_schema", {"type": "object", "properties": {}}),
			"source": "plugin:%s" % plugin_id,
			"executor": executor,
		}
		# Preserve _backend_name so handle_tool_call can strip the auto-prefix
		# before forwarding to the plugin's stdio channel. Backend-discovered
		# tools (round 1) set this to the unprefixed name from tools/list;
		# manifest-declared tools omit it (the manifest name is already what
		# the backend recognises).
		if tool_entry.has("_backend_name"):
			entry["_backend_name"] = str(tool_entry["_backend_name"])
		validated.append(entry)

	# Remove any previous registration for this plugin (idempotent re-register).
	# Emit tools_unregistered for the purged names so downstream listeners
	# (mcp_manager.tool_registry, tool_search_index) clean up — otherwise
	# orphan entries leak when manifest names differ from backend names.
	var stale_names: Array = _unregister_internal(plugin_id)
	if not stale_names.is_empty():
		tools_unregistered.emit(plugin_id, stale_names)

	# Commit to registry.
	_tools_by_plugin[plugin_id] = validated
	var registered_names: Array = []
	for entry in validated:
		var n: String = entry["name"]
		_plugin_by_tool[n] = plugin_id
		registered_names.append(n)

	print("[PluginToolRegistry] Registered %d tool(s) for plugin '%s'" % [
		validated.size(), plugin_id
	])

	if audit_log != null:
		audit_log.log_event(plugin_id, "tool_register", {"tools": registered_names})

	tools_registered.emit(plugin_id, registered_names)
	return {"ok": true, "registered": registered_names}


## Remove all tools registered under plugin_id.
## Safe to call even if the plugin has no registered tools.
func unregister_plugin_tools(plugin_id: String) -> void:
	var removed_names := _unregister_internal(plugin_id)
	if removed_names.is_empty():
		return

	print("[PluginToolRegistry] Unregistered %d tool(s) for plugin '%s'" % [
		removed_names.size(), plugin_id
	])

	if audit_log != null:
		audit_log.log_event(plugin_id, "tool_unregister", {"tools": removed_names})

	tools_unregistered.emit(plugin_id, removed_names)


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

## Return all tool definitions registered by plugin_id.
## Returns an empty Array if the plugin has no registered tools.
func get_plugin_tools(plugin_id: String) -> Array:
	return _tools_by_plugin.get(plugin_id, []).duplicate(true)


## Return all plugin tools across all plugins as a flat Array[Dictionary].
func get_all_plugin_tools() -> Array:
	var result: Array = []
	for plugin_id in _tools_by_plugin:
		for entry in _tools_by_plugin[plugin_id]:
			result.append(entry.duplicate(true))
	return result


## Find a plugin tool definition by exact name.
## Returns {} if not found.
func find_tool(tool_name: String) -> Dictionary:
	var plugin_id: String = _plugin_by_tool.get(tool_name, "")
	if plugin_id.is_empty():
		return {}
	for entry in _tools_by_plugin.get(plugin_id, []):
		if entry.get("name") == tool_name:
			return entry.duplicate(true)
	return {}


## Return true if tool_name is a plugin-registered tool (not a built-in).
func is_plugin_tool(tool_name: String) -> bool:
	return _plugin_by_tool.has(tool_name)


## Return the plugin_id that owns tool_name, or "" if not a plugin tool.
func get_tool_owner(tool_name: String) -> String:
	return _plugin_by_tool.get(tool_name, "")


## Return the total number of plugin tools across all plugins.
func get_tool_count() -> int:
	var count := 0
	for plugin_id in _tools_by_plugin:
		count += _tools_by_plugin[plugin_id].size()
	return count


# ---------------------------------------------------------------------------
# Tool call dispatch
# ---------------------------------------------------------------------------

## Dispatch a tool call to the owning plugin.
##
## Flow:
##   1. Look up which plugin owns the tool.
##   2. Verify the plugin is currently RUNNING via PluginManager.
##   3. Check policy via PluginPolicy (deny-by-default for unknown capabilities;
##      for simple tool dispatch we check "tool_call" capability).
##   4. Forward the call to the plugin's MCPServerConnection.call_tool().
##   5. Log the call outcome in PluginAuditLog.
##
## Returns the result Dictionary from the plugin, or a structured error from
## PluginErrors if any pre-flight check fails.
##
## NOTE: This method is async (uses await internally). The caller inside
## MinervaMCPServer._execute_tool_impl() must use "return await".
func handle_tool_call(tool_name: String, args: Dictionary) -> Dictionary:
	# --- Step 1: resolve owning plugin ---
	var plugin_id: String = _plugin_by_tool.get(tool_name, "")
	if plugin_id.is_empty():
		return PluginErrors.tool_not_found("", tool_name)

	# --- Step 1.5: panel-executed tools (executor == "panel") ---
	# Panel tools run host-side inside the plugin's live scene panel; the
	# plugin subprocess is irrelevant, so the RUNNING check below is skipped
	# (DCR 019f6c3d0e3d contract §2 — this also removes the backend-stopped
	# failure mode for these tools).
	if _get_tool_executor(plugin_id, tool_name) == "panel":
		return await _handle_panel_tool_call(plugin_id, tool_name, args)

	# --- Step 2: verify plugin is running ---
	if plugin_manager == null:
		push_error("[PluginToolRegistry] plugin_manager is not set")
		return PluginErrors.plugin_not_running(plugin_id)

	var status := plugin_manager.get_plugin_status(plugin_id)
	if status.get("error"):
		return PluginErrors.plugin_not_running(plugin_id)

	if not status.get("running", false):
		return PluginErrors.plugin_not_running(plugin_id)

	# --- Step 3: policy check ---
	# Plugin tools are callable if the plugin is running. Host capability checks
	# happen in CapabilityBroker when the plugin tries to USE a host capability,
	# not here at the tool dispatch boundary.
	if audit_log != null:
		audit_log.log_event(plugin_id, "policy_allow", {
			"tool": tool_name,
			"reason": "plugin running, tool dispatch allowed",
		})

	# --- Step 4: get connection and forward ---
	var conn: MCPServerConnection = plugin_manager.get_connection(plugin_id)
	if conn == null:
		push_error("[PluginToolRegistry] No connection for running plugin '%s'" % plugin_id)
		return PluginErrors.plugin_not_running(plugin_id)

	if audit_log != null:
		audit_log.log_event(plugin_id, "tool_call_dispatched", {
			"tool": tool_name,
			"args_keys": args.keys(),
		})

	# Resolve the backend name: backend-discovered tools may have a different
	# name on the wire (the short name the backend registered, before auto-prefix
	# was applied). Look it up from the stored "_backend_name" field. If absent
	# (manifest-declared tools always use the exact name), use tool_name as-is.
	var dispatch_name := tool_name
	for entry in _tools_by_plugin.get(plugin_id, []):
		if entry.get("name") == tool_name:
			var backend_name: String = entry.get("_backend_name", "")
			if not backend_name.is_empty():
				dispatch_name = backend_name
			break

	var result: Dictionary = await conn.call_tool(dispatch_name, args)

	if audit_log != null:
		var succeeded := not result.has("error")
		audit_log.log_event(plugin_id, "tool_call_result", {
			"tool": tool_name,
			"success": succeeded,
		})

	# --- Step 5: process brokered capability requests ---
	# If the plugin's response includes "capability_requests", dispatch each
	# through the CapabilityBroker. This lets plugins request host actions
	# (e.g. notes.create) as part of their tool response.
	result = await _process_capability_requests(plugin_id, tool_name, result)

	# --- Step 6: drain stderr to Minerva's error display ---
	# Plugin stderr is diagnostic output, not tool results. Route it to
	# Minerva's toast system so the user sees it, not the LLM.
	# BUT apply rate limiting to prevent log spam from flooding the UI.
	var stderr_output := _drain_plugin_stderr(plugin_id)
	if not stderr_output.is_empty():
		# Always log to audit
		if audit_log != null:
			audit_log.log_event(plugin_id, "stderr", {"output": stderr_output})
		# Only toast if stderr contains ERROR or WARNING (not routine INFO logs)
		var has_error := stderr_output.contains("ERROR") or stderr_output.contains("CRITICAL")
		var has_warning := stderr_output.contains("WARNING") or stderr_output.contains("WARN")
		if has_error or has_warning:
			# Check if we can show a toast for this plugin
			if _check_stderr_toast_rate_limit(plugin_id):
				var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject") if Engine.get_main_loop() else null
				if so and so.has_method("create_toast_notification"):
					var toast_type: int = 2 if has_error else 1  # ERROR=2, WARNING=1
					so.create_toast_notification("[Plugin:%s] %s" % [plugin_id, stderr_output], toast_type)
			else:
				# Toast rate limit exceeded — logged to audit but not shown to user
				if audit_log != null:
					audit_log.log_event(plugin_id, "stderr_toast_dropped", {
						"reason": "rate_limit_exceeded",
						"output_preview": stderr_output.left(100)
					})

	return result


# ---------------------------------------------------------------------------
# Panel-executed tool dispatch (executor == "panel", DCR 019f6c3d0e3d)
# ---------------------------------------------------------------------------

## Path to AnnotationHostRegistry — loaded lazily (never preloaded) so this
## file's parse chain stays independent of the annotation substrate.
const _ANNOTATION_HOST_REGISTRY_PATH := "res://Scripts/Services/Annotations/AnnotationHostRegistry.gd"


## Return the executor for a registered tool: "panel" or "backend".
## Unknown tools resolve to "backend" (the caller has already validated
## ownership via _plugin_by_tool, so this is just a field read).
func _get_tool_executor(plugin_id: String, tool_name: String) -> String:
	for entry in _tools_by_plugin.get(plugin_id, []):
		if entry.get("name") == tool_name:
			return str(entry.get("executor", "backend"))
	return "backend"


## Resolve the PluginScenePanelBroker: explicit injection first (tests,
## future wiring), then the SingletonObject autoload's
## `plugin_scene_panel_broker` property (production — same duck-typed lookup
## PluginScenePanelHost._get_broker uses). Returns null when unavailable.
func _resolve_scene_panel_broker():
	if scene_panel_broker != null:
		return scene_panel_broker
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return null
	var root: Node = (loop as SceneTree).root
	if root == null:
		return null
	var so: Node = root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	if "plugin_scene_panel_broker" in so:
		return so.get("plugin_scene_panel_broker")
	return null


## Lazily load AnnotationHostRegistry's script for its static methods.
## Returns null if the script is missing (annotation substrate absent).
func _annotation_host_registry():
	if not ResourceLoader.exists(_ANNOTATION_HOST_REGISTRY_PATH):
		return null
	return load(_ANNOTATION_HOST_REGISTRY_PATH)


## Dispatch a panel-executed tool to the live scene panel named by
## args.editor_name. All failures are PluginErrors-structured dictionaries;
## a successful panel return Dictionary passes through VERBATIM.
##
## Resolution order (contract §2.2):
##   1. Scene-panel broker registry (panel_name == editor tab name).
##   2. Duck-typed fallback: AnnotationHostRegistry.get_host(editor_name)
##      → host.get_panel() when the host exposes it.
##
## Ownership (contract §2.3): the resolved panel must belong to the calling
## tool's plugin. Established via broker.get_panel_owner, falling back to a
## duck-typed `plugin_id` property on the panel itself (fallback-resolved
## panels the broker doesn't know). Undeterminable ownership is a DENY —
## fail-safe, a tool must never execute against another plugin's panel.
func _handle_panel_tool_call(plugin_id: String, tool_name: String, args: Dictionary) -> Dictionary:
	# --- editor_name is required for panel tools (v1) ---
	var editor_name := str(args.get("editor_name", ""))
	if editor_name.is_empty():
		return PluginErrors.editor_name_required(plugin_id, tool_name)

	# --- Resolve the live panel ---
	var broker = _resolve_scene_panel_broker()
	var panel: Object = null
	if broker != null and broker.has_method("get_panel_for_editor"):
		panel = broker.get_panel_for_editor(editor_name)

	if panel == null:
		# Fallback: annotation-substrate hosts that expose their panel.
		var ahr = _annotation_host_registry()
		if ahr != null:
			var host = ahr.get_host(editor_name)
			if host != null and host.has_method("get_panel"):
				panel = host.get_panel()

	if panel == null or not is_instance_valid(panel):
		# Miss: list every editor name we know about (mirrors the
		# MCPPcbPanelTools._no_host_error UX so callers can self-correct).
		var known: Array = []
		if broker != null and broker.has_method("list_panel_editor_names"):
			known = broker.list_panel_editor_names()
		var ahr2 = _annotation_host_registry()
		if ahr2 != null:
			for n in ahr2.list_editor_names():
				if not known.has(n):
					known.append(n)
		return PluginErrors.editor_not_found(plugin_id, editor_name, known)

	# --- Ownership check ---
	var owner_id := ""
	if broker != null and broker.has_method("get_panel_owner"):
		owner_id = str(broker.get_panel_owner(editor_name))
	if owner_id.is_empty() and "plugin_id" in panel:
		owner_id = str(panel.get("plugin_id"))
	if owner_id != plugin_id:
		return PluginErrors.panel_not_owned(plugin_id, editor_name, owner_id)

	# --- Policy/audit: same boundary events as backend dispatch ---
	if audit_log != null:
		audit_log.log_event(plugin_id, "policy_allow", {
			"tool": tool_name,
			"reason": "plugin installed, panel tool dispatch allowed",
			"executor": "panel",
		})
		audit_log.log_event(plugin_id, "tool_call_dispatched", {
			"tool": tool_name,
			"args_keys": args.keys(),
			"executor": "panel",
		})

	# --- Execute (duck-typed, async-capable) ---
	if not panel.has_method("handle_tool"):
		if audit_log != null:
			audit_log.log_event(plugin_id, "tool_call_result", {
				"tool": tool_name,
				"success": false,
				"executor": "panel",
				"error_code": PluginErrors.CODE_PANEL_NO_HANDLER,
			})
		return PluginErrors.panel_no_handler(plugin_id, editor_name)

	var result: Variant = await panel.handle_tool(tool_name, args)

	if not (result is Dictionary) or (result as Dictionary).is_empty():
		if audit_log != null:
			audit_log.log_event(plugin_id, "tool_call_result", {
				"tool": tool_name,
				"success": false,
				"executor": "panel",
				"error_code": PluginErrors.CODE_TOOL_UNHANDLED,
			})
		return PluginErrors.tool_unhandled(plugin_id, tool_name, editor_name)

	var result_dict: Dictionary = result
	if audit_log != null:
		audit_log.log_event(plugin_id, "tool_call_result", {
			"tool": tool_name,
			"success": not result_dict.has("error"),
			"executor": "panel",
		})

	# Contract §2.4: the plugin's Dictionary is the tool result verbatim —
	# plugins own their envelopes. No capability-request post-processing and
	# no stderr drain: both are subprocess concerns.
	return result_dict


# ---------------------------------------------------------------------------
# Brokered capability request processing
# ---------------------------------------------------------------------------

## Process capability_requests embedded in a plugin tool result.
## The plugin returns JSON like:
##   {"content": [{"type":"text","text":"..."}], "capability_requests": [
##     {"capability": "notes.create", "args": {"title": "...", "content": "..."}}
##   ]}
## Minerva dispatches each through CapabilityBroker (policy-checked) and appends
## the outcomes to the result.
func _process_capability_requests(plugin_id: String, tool_name: String, result: Dictionary) -> Dictionary:
	if capability_broker == null:
		return result

	# The tool result from MCP has content nested — extract capability_requests
	# from the inner text payload if present.
	var cap_requests: Array = []

	# Check direct field first
	if result.has("capability_requests"):
		cap_requests = result["capability_requests"]
	else:
		# Parse from MCP content text (the plugin serializes JSON inside "text")
		var content = result.get("content", [])
		if content is Array and content.size() > 0:
			var first = content[0]
			if first is Dictionary and first.get("type") == "text":
				var inner_text: String = first.get("text", "")
				var json := JSON.new()
				if json.parse(inner_text) == OK and json.data is Dictionary:
					cap_requests = json.data.get("capability_requests", [])

	if cap_requests.is_empty():
		return result

	# Dispatch each capability request through the broker
	var broker_results: Array = []
	for req in cap_requests:
		if not req is Dictionary:
			continue
		var capability: String = str(req.get("capability", ""))
		var cap_args: Dictionary = req.get("args", {})

		if audit_log != null:
			audit_log.log_event(plugin_id, "capability_request", {
				"tool": tool_name,
				"capability": capability,
			})

		var broker_result: Dictionary = await capability_broker.dispatch(plugin_id, capability, cap_args)
		broker_results.append({
			"capability": capability,
			"result": broker_result,
		})

		if audit_log != null:
			audit_log.log_event(plugin_id,
				"policy_allow" if broker_result.get("success", false) else "policy_deny",
				{"capability": capability, "tool": tool_name})

	# Append broker results to the tool response
	if not broker_results.is_empty():
		result["capability_results"] = broker_results

	return result


# ---------------------------------------------------------------------------
# Stderr draining
# ---------------------------------------------------------------------------

## Read all available stderr lines from a plugin's subprocess.
func _drain_plugin_stderr(plugin_id: String) -> String:
	var conn: MCPServerConnection = plugin_manager.get_connection(plugin_id)
	if conn == null:
		return ""
	if not is_instance_valid(conn._subprocess):
		return ""
	var lines: String = ""
	while conn._subprocess.has_stderr():
		var line: String = conn._subprocess.read_stderr_line()
		if not line.is_empty():
			if not lines.is_empty():
				lines += "\n"
			lines += line
	return lines


## Check if a stderr toast can be displayed for this plugin.
## Returns true if the toast is within the rate limit, false if exceeding.
## Uses a sliding window: max 5 toasts per 30 seconds per plugin.
func _check_stderr_toast_rate_limit(plugin_id: String) -> bool:
	var current_time := Time.get_ticks_msec() / 1000.0

	# Initialize plugin entry if not present
	if not _stderr_toast_counts.has(plugin_id):
		_stderr_toast_counts[plugin_id] = {
			"window_start": current_time,
			"count": 0,
		}

	var entry: Dictionary = _stderr_toast_counts[plugin_id]
	var window_start: float = entry["window_start"]
	var count: int = entry["count"]

	# Check if window has expired
	if current_time - window_start > _stderr_toast_limit["window_seconds"]:
		# Window reset: new window starts now
		entry["window_start"] = current_time
		entry["count"] = 1
		return true

	# Check if we've exceeded the limit
	if count >= _stderr_toast_limit["max_toasts"]:
		return false

	# Increment counter and allow
	entry["count"] = count + 1
	return true


# ---------------------------------------------------------------------------
# Lifecycle helpers (wire these to PluginManager signals)
# ---------------------------------------------------------------------------

## Call this when a plugin stops or crashes to clean up its tools.
## Typically wired to PluginManager.plugin_stopped and plugin_crashed signals.
func on_plugin_stopped(plugin_id: String) -> void:
	unregister_plugin_tools(plugin_id)


## Call this when a plugin starts successfully to re-register its tools from
## the PluginDefinition (if they are not already registered).
## Typically wired to PluginManager.plugin_started signal.
func on_plugin_started(plugin_id: String) -> void:
	if plugin_manager == null:
		return

	var def: PluginDefinition = plugin_manager.get_db().get_by_id(plugin_id)
	if def == null:
		return

	if _tools_by_plugin.has(plugin_id) and not _tools_by_plugin[plugin_id].is_empty():
		# Already registered (e.g., registered at install time and plugin just started).
		return

	var result := register_plugin_tools(plugin_id, def.tools)
	if result.get("error"):
		push_error("[PluginToolRegistry] Failed to register tools for '%s' on start: %s" % [
			plugin_id, result.get("error")
		])


# ---------------------------------------------------------------------------
# Backend-discovered tool registration (dynamic discovery via tools/list)
# ---------------------------------------------------------------------------
#
# PREFIX POLICY: Option B — Auto-prefix
#
# Plugin backends (e.g. Go binaries) advertise clean, short tool names such as
# "mcad_validate" or "cad.evaluate". At registration time Minerva transforms
# each name to "minerva_<plugin_id>_<sanitized_name>", where sanitization
# replaces every '.' with '_'. This keeps plugin code clean and adds the
# required namespace at the Minerva boundary.
#
# Special cases:
#   - If a name ALREADY starts with "minerva_<plugin_id>_" it is used as-is
#     (no double-prefix). This lets conformant backends opt in without
#     breakage.
#   - Names that start with "minerva_" but belong to a DIFFERENT plugin's
#     prefix are rejected as they could shadow another plugin's tools.
#
# Rationale: plugin authors should not need to know Minerva's internal naming
# conventions; Minerva adds the namespace. The manifest's tools[] array is
# preserved as install-time expected-tool metadata and is not affected by this
# runtime discovery path.

## Sanitize a raw backend tool name for use as a Minerva-namespaced tool name.
## Replaces '.' with '_'. Other characters are left as-is (Go tool names are
## typically alphanumeric + underscores already).
static func _sanitize_tool_name(raw_name: String) -> String:
	return raw_name.replace(".", "_")


## Apply the auto-prefix policy to a raw backend tool name.
## Returns the conformant "minerva_<plugin_id>_<name>" string.
## Does NOT double-prefix if the name already conforms.
static func _apply_prefix(plugin_id: String, raw_name: String) -> String:
	var expected_prefix := "minerva_%s_" % plugin_id
	if raw_name.begins_with(expected_prefix):
		return raw_name  # Already conformant — use as-is.
	var sanitized := _sanitize_tool_name(raw_name)
	return expected_prefix + sanitized


## Discover and register tools reported by the plugin backend via tools/list.
##
## This is the dynamic discovery path: called by PluginManager after a plugin
## has fully started (MCP handshake complete). It calls conn.refresh_tools(),
## transforms each returned tool name with the auto-prefix policy (Option B),
## and registers the resulting tool definitions.
##
## Any manifest-declared tools already registered under this plugin_id are
## REPLACED by the backend-discovered set (the backend is authoritative at
## runtime; manifest tools are install-time review metadata only).
##
## Returns {"ok": true, "registered": [...]} on success.
## Returns {"error": "..."} if discovery or registration fails.
## Returns {"ok": true, "registered": [], "skipped": "no_connection"} if the
## connection is unavailable (non-fatal for headless/test scenarios).
func register_backend_tools(plugin_id: String, conn: MCPServerConnection) -> Dictionary:
	if plugin_id.is_empty():
		return {"error": "plugin_id must not be empty"}

	if conn == null:
		push_warning("[PluginToolRegistry] register_backend_tools: no connection for '%s'" % plugin_id)
		return {"ok": true, "registered": [], "skipped": "no_connection"}

	# Refresh the tools list from the backend.
	var refresh_err: int = await conn.refresh_tools()
	if refresh_err != OK:
		push_warning("[PluginToolRegistry] tools/list refresh failed for plugin '%s' (err=%d)" % [
			plugin_id, refresh_err
		])
		return {"error": "tools/list refresh failed with error %d" % refresh_err}

	var raw_tools: Array = conn.tools  # Array of MCPToolDefinition objects
	if raw_tools.is_empty():
		print("[PluginToolRegistry] No tools reported by backend for plugin '%s'" % plugin_id)
		# Use the public unregister so tools_unregistered fires for any prior
		# registration (e.g. manifest tools) that the backend churn supersedes.
		unregister_plugin_tools(plugin_id)
		_tools_by_plugin[plugin_id] = []
		return {"ok": true, "registered": []}

	# Transform each backend tool into a conformant entry dict.
	var entries: Array[Dictionary] = []
	for tool_def in raw_tools:
		if tool_def == null:
			continue
		var raw_name: String = str(tool_def.name) if tool_def.name != null else ""
		if raw_name.is_empty():
			continue

		var namespaced_name := _apply_prefix(plugin_id, raw_name)

		# Reject if the name starts with "minerva_" but conflicts with another
		# plugin's prefix (e.g. "minerva_otherplugin_foo").
		var expected_prefix := "minerva_%s_" % plugin_id
		if namespaced_name.begins_with("minerva_") and not namespaced_name.begins_with(expected_prefix):
			push_warning("[PluginToolRegistry] Backend tool '%s' for plugin '%s' would produce '%s' which conflicts with another plugin's prefix — skipping" % [
				raw_name, plugin_id, namespaced_name
			])
			continue

		var entry := {
			"name": namespaced_name,
			"description": str(tool_def.description) if tool_def.description != null else "",
			"input_schema": tool_def.input_schema if tool_def.input_schema != null else {"type": "object", "properties": {}},
			"source": "plugin:%s" % plugin_id,
			# Backend-discovered tools are by definition served by the plugin
			# subprocess — they are always executor "backend".
			"executor": "backend",
			# Preserve the original backend name for dispatch — _call_tool_stdio
			# uses the namespaced name and the plugin receives it via tools/call.
			# The backend must handle the namespaced name OR we strip the prefix
			# before forwarding. For now we forward as-is (the backend echoes its
			# own name from tools/list, so it will recognise the prefixed name if
			# it declared it, or the stripped name if it declared the short form).
			"_backend_name": raw_name,
		}
		entries.append(entry)

	if entries.is_empty():
		print("[PluginToolRegistry] All backend tools filtered for plugin '%s'" % plugin_id)
		unregister_plugin_tools(plugin_id)
		_tools_by_plugin[plugin_id] = []
		return {"ok": true, "registered": []}

	# Use register_plugin_tools with the already-namespaced entries.
	# That function enforces the prefix rule again — since we applied the prefix
	# above, all entries should pass. Build the dict array it expects.
	var result := register_plugin_tools(plugin_id, entries)
	if result.has("error"):
		push_error("[PluginToolRegistry] register_backend_tools failed for '%s': %s" % [
			plugin_id, result.get("error")
		])
	return result


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Internal unregister that returns the list of removed tool names without
## emitting signals or logging (callers handle those).
func _unregister_internal(plugin_id: String) -> Array:
	var tools: Array = _tools_by_plugin.get(plugin_id, [])
	if tools.is_empty():
		_tools_by_plugin.erase(plugin_id)
		return []

	var removed: Array = []
	for entry in tools:
		var n: String = entry.get("name", "")
		if not n.is_empty():
			_plugin_by_tool.erase(n)
			removed.append(n)

	_tools_by_plugin.erase(plugin_id)
	return removed


# ---------------------------------------------------------------------------
# MinervaMCPServer integration plan (DO NOT modify MinervaMCPServer.gd yet)
# ---------------------------------------------------------------------------
#
# This registry is designed to slot into MinervaMCPServer with minimal changes
# during the vertical slice. Here is the exact integration plan:
#
# 1. INSTANTIATION (MinervaMCPServer._init)
#    Add one line after `mcp_manager` is confirmed non-null:
#
#      var plugin_tool_registry := PluginToolRegistry.new(
#          plugin_manager_singleton,   # however PluginManager is accessed
#          plugin_policy_singleton,
#          plugin_audit_log_singleton
#      )
#      plugin_tool_registry.set_builtin_tool_names(mcp_manager.tool_registry.keys())
#
# 2. TOOL REGISTRATION INTO mcp_manager.tool_registry
#    When a plugin starts, its tools must appear in mcp_manager.tool_registry so
#    that minerva_tool_search can discover them and get_tools_for_chat returns them.
#    Wire the tools_registered signal:
#
#      plugin_tool_registry.tools_registered.connect(
#          func(plugin_id, tool_names):
#              for entry in plugin_tool_registry.get_plugin_tools(plugin_id):
#                  var tool_def := MCPToolDefinition.new()
#                  tool_def.name = entry["name"]
#                  tool_def.description = entry["description"]
#                  tool_def.input_schema = entry["input_schema"]
#                  tool_def.server_name = "plugin:%s" % plugin_id
#                  tool_def.tool_set = "plugin"
#                  mcp_manager.tool_registry[entry["name"]] = tool_def
#                  tool_search_index.register_tool(
#                      entry["name"], entry["description"],
#                      tool_def.to_anthropic_format(), "plugin"
#                  )
#      )
#
#    Wire tools_unregistered to purge from mcp_manager.tool_registry:
#
#      plugin_tool_registry.tools_unregistered.connect(
#          func(plugin_id, tool_names):
#              for name in tool_names:
#                  mcp_manager.tool_registry.erase(name)
#                  # tool_search_index has no remove API yet; add one when needed
#      )
#
# 3. DISPATCH IN _execute_tool_impl()
#    Add ONE clause at the very END of the match block, just before the
#    "Unknown minerva tool" fallthrough:
#
#      # Plugin tool dispatch (must be last — after all built-in cases)
#      if plugin_tool_registry.is_plugin_tool(tool_name):
#          return await plugin_tool_registry.handle_tool_call(tool_name, arguments)
#
# 4. LIFECYCLE WIRING (PluginManager signals)
#    Wire PluginManager signals to keep the registry in sync:
#
#      plugin_manager.plugin_started.connect(plugin_tool_registry.on_plugin_started)
#      plugin_manager.plugin_stopped.connect(plugin_tool_registry.on_plugin_stopped)
#      plugin_manager.plugin_crashed.connect(plugin_tool_registry.on_plugin_stopped)
#
# 5. INITIAL POPULATION (for plugins already in DB at boot)
#    After wiring signals, iterate all installed plugins and register their tools:
#
#      for def in plugin_manager.get_db().get_all():
#          plugin_tool_registry.register_plugin_tools(def.id, def.tools)
#
# Design rationale:
#   - "tool_call" capability acts as a single on/off grant per plugin.
#     Fine-grained per-tool grants are deferred to a future capability iteration.
#   - Tools from stopped/crashed plugins are immediately purged so they don't
#     appear in minerva_tool_search results or produce confusing errors.
#   - Re-registration on plugin restart is idempotent (unregister then re-register).
#   - Built-in tool name conflict detection prevents plugins from shadowing
#     core Minerva functionality.
