class_name PluginManager
extends Node
## Lifecycle supervisor for Minerva plugins.
##
## Owns a PluginDB, drives per-plugin state transitions, spawns and tears down
## MCPServerConnection instances, and monitors running processes for unexpected
## exits.  Policy enforcement and MCP tool registration are handled elsewhere.
##
## Crash-loop detection: if a plugin crashes 3 or more times within a 60-second
## rolling window, it is placed in CRASH_LOOP state and will not be auto-restarted.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## How often (seconds) to poll running plugins for liveness.
const HEALTH_CHECK_INTERVAL_SEC := 5.0

## Number of crashes within the window that triggers CRASH_LOOP.
const CRASH_LOOP_THRESHOLD := 3

## Rolling window (seconds) used for crash-loop detection.
const CRASH_LOOP_WINDOW_SEC := 60.0

## How often (seconds) to check plugin file modification times for hot reload.
const FILE_WATCH_INTERVAL_SEC := 2.0

## Seconds to wait after a file change before triggering a reload (debounce).
const RELOAD_DEBOUNCE_SEC := 0.5

## File extensions watched for hot reload.
const WATCH_EXTENSIONS := ["py", "js", "sh", "json", "gd", "tscn"]

## Mirrors of PluginDefinition.State to avoid parse-order dependency.
## PluginManager extends Node (parsed early); PluginDefinition extends RefCounted.
const S_INSTALLED := 0   # S_INSTALLED
const S_STARTING := 1    # S_STARTING
const S_RUNNING := 2     # S_RUNNING
const S_STOPPED := 3     # S_STOPPED
const S_ERROR := 4       # S_ERROR
const S_CRASH_LOOP := 5  # S_CRASH_LOOP


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

signal plugin_started(id: String)
signal plugin_stopped(id: String)
signal plugin_crashed(id: String)
signal plugin_state_changed(id: String, old_state: int, new_state: int)
signal plugin_file_changed(id: String)


# ---------------------------------------------------------------------------
# Private types
# ---------------------------------------------------------------------------

## Per-plugin runtime bookkeeping stored in _runtime dict (keyed by plugin id).
## We use a plain Dictionary rather than a class so that we don't need a
## separate file for a simple struct.
##
## Fields:
##   connection: MCPServerConnection | null
##   start_time: float   — Time.get_unix_time_from_system() at last start
##   crash_count: int    — total lifetime crashes
##   crash_times: Array[float]  — timestamps of crashes within rolling window
##   stopping: bool      — true while stop_plugin is running (avoid re-entry)


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

var _db = null  # PluginDB — initialized in _ready to avoid parse-order issues

## id -> runtime Dictionary (see comment above)
var _runtime: Dictionary = {}

## Accumulated time since last health-check sweep.
var _health_timer_acc: float = 0.0

## Accumulated time since last file-watch sweep.
var _file_watch_acc: float = 0.0

## Per-plugin file modification time snapshots.
## Structure: { plugin_id: { file_path: modified_time_int } }
var _file_mtimes: Dictionary = {}

## Per-plugin debounce timers awaiting reload after a file change.
## Structure: { plugin_id: SceneTreeTimer }
## A non-null entry means a debounce is in flight for that plugin.
var _reload_pending: Dictionary = {}

## Per-plugin set of paths that changed during the current debounce window.
## Accumulated during file-watch scans; consumed (and cleared) when the debounce
## timer fires.  Structure: { plugin_id: Array[String] }
var _pending_changed_paths: Dictionary = {}

## Per-plugin live scene-panel registry for hot-reload.
## Maps plugin_id -> Array of Dictionaries:
##   { "panel_name": String, "tscn_path": String, "editor": Editor,
##     "vbox": Control, "root": Control }
## Populated when a PLUGIN_SCENE editor is opened; cleaned on close / stop.
## NOTE: Only PluginManager.gd writes to this; callers use the public API below.
var _live_scene_panels: Dictionary = {}


# ---------------------------------------------------------------------------
# Lifecycle (Node)
# ---------------------------------------------------------------------------

func _ready() -> void:
	if _db == null:
		_db = load("res://Scripts/Services/Plugins/PluginDB.gd").new()
	print("[PluginManager] Ready — %d plugin(s) in DB" % _db.get_all().size())


func _process(delta: float) -> void:
	_health_timer_acc += delta
	if _health_timer_acc >= HEALTH_CHECK_INTERVAL_SEC:
		_health_timer_acc = 0.0
		_run_health_checks()

	_file_watch_acc += delta
	if _file_watch_acc >= FILE_WATCH_INTERVAL_SEC:
		_file_watch_acc = 0.0
		_run_file_watch_checks()


# ---------------------------------------------------------------------------
# Public API — install / remove
# ---------------------------------------------------------------------------

## Parse a manifest.json, validate it, and register the plugin in the DB.
##
## If the manifest declares skills[] (DCR 019df57b), seed them into the user
## docket after the core install completes.  When auto_confirm_skills is false
## (default), a confirmation dialog is shown to the user before seeding; pass
## true for headless / programmatic flows that have already obtained consent.
##
## Returns {"ok": true, "id": "..."} on the no-skills path, or with extra keys
## on the skill-seeding path:
##   "skills_seeded": int — newly created records
##   "skills_skipped": int — already-installed pristine matches (idempotent re-install)
##   "skills_deferred_to_update": int — content changed; T4 reconciliation handles
##   "skills_declined": true — user cancelled the seed dialog (only when not auto-confirmed)
##
## Returns {"error": "..."} on install failure.
func install_plugin(manifest_path: String, auto_confirm_skills: bool = false) -> Dictionary:
	var def = _db.install(manifest_path)
	if def == null:
		# PluginDB.install already push_error'd; check for duplicate separately.
		var PluginDef = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
		var check_def = PluginDef.from_manifest(manifest_path)
		if check_def != null and _db.has_plugin(check_def.id):
			return {"error": "Plugin '%s' is already installed" % check_def.id}
		return {"error": "Failed to install plugin from manifest: %s" % manifest_path}

	_ensure_runtime(def.id)

	# Auto-create plugin data directory and declared filesystem paths
	var create_result := _create_plugin_directories(def)
	if create_result.has("error"):
		# Don't fail the install, but log a warning
		push_warning("[PluginManager] Warning creating directories for '%s': %s" % [def.id, create_result["error"]])

	# Default-grant declared capabilities (except privilege-escalation ones).
	# Install is the trust act; per-capability opt-in is friction the user
	# can reverse later by revoking specific caps.
	_auto_grant_declared_capabilities(def)

	print("[PluginManager] Installed plugin '%s' v%s" % [def.id, def.version])

	var result: Dictionary = {"ok": true, "id": def.id}

	# Skill seeding (DCR 019df57b T3).
	if not def.skills.is_empty():
		var seed_result := await _seed_plugin_skills(def, auto_confirm_skills)
		result.merge(seed_result)

	# Cross-plugin reactivity (DCR 019df57b T7).  This plugin's declared tools
	# are now part of the "available" set; any pre-existing skill whose
	# unsatisfied_deps included one of those tools should re-resolve.
	var reactivity := _recompute_skill_reactivity()
	if reactivity.get("updated", 0) > 0:
		result["reactivity_updated"] = reactivity.get("updated", 0)
		result["reactivity_now_satisfied"] = reactivity.get("now_satisfied", 0)
		result["reactivity_now_unsatisfied"] = reactivity.get("now_unsatisfied", 0)

	return result


## Resolve tool_deps + (optionally) confirm with user + materialise skill records.
## Internal helper for install_plugin's skill-seeding path.
func _seed_plugin_skills(def, auto_confirm: bool) -> Dictionary:
	var SeederClass = load("res://Scripts/Services/Plugins/PluginSkillSeeder.gd")
	var available_tools: Dictionary = _build_available_tools()
	var docket_manager = _get_docket_manager()

	var resolved: Array = SeederClass.resolve_deps(def, available_tools)

	var accepted: bool = auto_confirm
	if not auto_confirm:
		accepted = await _show_skill_seed_dialog(def, resolved)

	if not accepted:
		return {
			"skills_seeded": 0,
			"skills_skipped": 0,
			"skills_deferred_to_update": 0,
			"skills_declined": true,
		}

	var materialise_result: Dictionary = SeederClass.materialize(def.id, resolved, docket_manager)
	return {
		"skills_seeded": materialise_result.get("seeded", 0),
		"skills_skipped": materialise_result.get("skipped", 0),
		"skills_deferred_to_update": materialise_result.get("deferred_to_update", 0),
	}


## Spawn the install-skill confirmation dialog, await the user's choice.
## Returns true on accept, false on cancel / close.
##
## If the PluginManager isn't in a SceneTree (headless smoke test that forgot
## to add_child the manager), defaults to false (decline) rather than blocking
## indefinitely.
func _show_skill_seed_dialog(def, resolved: Array) -> bool:
	if not is_inside_tree():
		push_warning("[PluginManager] Skill seed dialog requested but PluginManager not in SceneTree; declining by default")
		return false

	var DialogClass = load("res://Scripts/Services/Plugins/PluginSkillSeedDialog.gd")
	var dialog = DialogClass.new()
	add_child(dialog)
	var display_name: String = def.name if not def.name.is_empty() else def.id
	dialog.configure(display_name, resolved)
	dialog.popup_centered()
	var accepted: bool = await dialog.seed_decision
	dialog.queue_free()
	return accepted


## Create plugin data directories. Called on successful install.
## Creates user://plugins/data/<plugin_id>/ and any declared filesystem_paths.
## Returns {"ok": true} or {"error": "..."}.
func _create_plugin_directories(def) -> Dictionary:  # def: PluginDefinition
	# Create base plugin data directory
	var base_dir := "user://plugins/data".path_join(def.id)
	var err := DirAccess.make_dir_recursive_absolute(base_dir)
	if err != OK:
		return {"error": "Failed to create plugin data directory '%s': %s" % [base_dir, error_string(err)]}

	print("[PluginManager] Created plugin data directory: %s" % base_dir)

	# Create any declared filesystem_paths
	if def.filesystem_mode == "scoped_paths":
		for path in def.filesystem_paths:
			# Expand user:// to absolute path
			var abs_path: String = ProjectSettings.globalize_path(path) if path.begins_with("user://") else path
			err = DirAccess.make_dir_recursive_absolute(abs_path)
			if err != OK:
				# Log but don't fail — plugin might use paths conditionally
				push_warning("[PluginManager] Could not create filesystem path '%s' for plugin '%s': %s" % [path, def.id, error_string(err)])
			else:
				print("[PluginManager] Created filesystem path: %s" % abs_path)

	return {"ok": true}


## Re-install (upgrade) an already-installed plugin from a new manifest version.
##
## DCR 019df57b T4: reconciles skill records against the new manifest:
##   - new skills → seeded fresh
##   - pristine record (customised=false) with content changed → silent overwrite
##   - customised record with content changed → diff dialog (auto-confirm bypass
##     available for headless/MCP flows via auto_confirm_updates=true)
##   - record absent from new manifest → marked deprecated (NOT deleted)
##
## Returns:
##   {"ok": true, "id": "...", "reconcile": {...counts...}, ...}
##   {"error": "..."}
func update_plugin(manifest_path: String, auto_confirm_updates: bool = false) -> Dictionary:
	var PluginDef = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	var def = PluginDef.from_manifest(manifest_path)
	if def == null:
		return {"error": "Failed to parse manifest: %s" % manifest_path}
	if not _db.has_plugin(def.id):
		return {"error": "Plugin '%s' not installed; use install_plugin first" % def.id}

	if not _db.update_definition(def):
		return {"error": "Failed to update plugin definition for '%s'" % def.id}

	var result: Dictionary = {"ok": true, "id": def.id}

	var docket_manager = _get_docket_manager()
	var SeederClass = load("res://Scripts/Services/Plugins/PluginSkillSeeder.gd")
	var available_tools := _build_available_tools()

	# Phase 1: classify each skill action (no docket writes yet).
	var plan: Dictionary = SeederClass.plan_reconcile(def, available_tools, docket_manager)

	# Phase 2: collect user decisions for prompt_required actions.
	var decisions: Dictionary = {}
	for action in plan.get("actions", []):
		if str(action.get("action", "")) != SeederClass.RECONCILE_PROMPT_REQUIRED:
			continue
		var skill: Dictionary = action.get("skill", {})
		var skill_id := str(skill.get("id", ""))
		if auto_confirm_updates:
			decisions[skill_id] = true
			continue
		var existing: Dictionary = action.get("existing", {})
		var accepted: bool = await _show_skill_update_dialog(def, existing, skill)
		decisions[skill_id] = accepted

	# Phase 3: commit.
	var reconcile_result: Dictionary = SeederClass.apply_reconcile(plan, decisions, docket_manager)
	result["reconcile"] = reconcile_result

	# T7 reactivity — tool_deps may have shifted in silent updates / accepted prompts.
	var reactivity := _recompute_skill_reactivity()
	if reactivity.get("updated", 0) > 0:
		result["reactivity_updated"] = reactivity.get("updated", 0)
		result["reactivity_now_satisfied"] = reactivity.get("now_satisfied", 0)
		result["reactivity_now_unsatisfied"] = reactivity.get("now_unsatisfied", 0)

	return result


## Spawn the update-confirmation dialog for one customised+changed skill,
## await the user's choice.  Returns true on accept (overwrite), false otherwise.
func _show_skill_update_dialog(def, existing_record: Dictionary, new_skill: Dictionary) -> bool:
	if not is_inside_tree():
		push_warning("[PluginManager] Skill update dialog requested but PluginManager not in SceneTree; declining by default")
		return false
	var DialogClass = load("res://Scripts/Services/Plugins/PluginSkillUpdateDialog.gd")
	var dialog = DialogClass.new()
	add_child(dialog)
	var display_name: String = def.name if not def.name.is_empty() else def.id
	dialog.configure(display_name, existing_record, new_skill)
	dialog.popup_centered()
	var accepted: bool = await dialog.update_decision
	dialog.queue_free()
	return accepted


## Stop the plugin if running, then remove it from the DB.
## If delete_data is true, also remove the plugin's data directory.
## Returns {"ok": true} or {"error": "..."}.
func remove_plugin(id: String, delete_data: bool = false) -> Dictionary:
	if not _db.has_plugin(id):
		return {"error": "Plugin '%s' not found" % id}

	var def = _db.get_by_id(id)
	if def.state in [S_RUNNING, S_STARTING]:
		var stop_result := stop_plugin(id)
		if stop_result.get("error"):
			return {"error": "Could not stop plugin before removal: %s" % stop_result.get("error")}

	# Unseed plugin-shipped skills before removing the plugin from the DB
	# (DCR 019df57b T6).  Pristine records hard-delete; customised records
	# auto-convert to source="user" so user edits are preserved.
	var unseed_result: Dictionary = _unseed_plugin_skills(id)

	_runtime.erase(id)

	if not _db.remove(id):
		return {"error": "Failed to remove plugin '%s' from DB" % id}

	# Clean up data directory if requested
	if delete_data:
		var data_dir := "user://plugins/data".path_join(id)
		var err := _delete_directory_recursive(data_dir)
		if err != OK:
			push_warning("[PluginManager] Could not delete data directory for '%s': %s" % [id, error_string(err)])
		else:
			print("[PluginManager] Deleted plugin data directory: %s" % data_dir)

	print("[PluginManager] Removed plugin '%s'" % id)

	# Cross-plugin reactivity (DCR 019df57b T7).  Plugin's declared tools are
	# no longer "available"; any remaining skill (any source) whose tool_deps
	# referenced them now has them in unsatisfied_deps.  Runs AFTER _db.remove
	# so the uninstalled plugin's tools fall out of _build_available_tools.
	var reactivity := _recompute_skill_reactivity()

	var result: Dictionary = {"ok": true}
	if unseed_result.get("deleted", 0) > 0 or unseed_result.get("kept", 0) > 0:
		result["skills_deleted"] = unseed_result.get("deleted", 0)
		result["skills_kept"] = unseed_result.get("kept", 0)
		result["skills_kept_ids"] = unseed_result.get("kept_skill_ids", [])
	if reactivity.get("updated", 0) > 0:
		result["reactivity_updated"] = reactivity.get("updated", 0)
		result["reactivity_now_satisfied"] = reactivity.get("now_satisfied", 0)
		result["reactivity_now_unsatisfied"] = reactivity.get("now_unsatisfied", 0)
	return result


## Remove plugin-seeded skill records on uninstall.  Pristine records get
## hard-deleted; customised records get their source flipped to "user" with
## pristine_hash / pristine_content cleared (no longer reconcilable).
func _unseed_plugin_skills(plugin_id: String) -> Dictionary:
	var docket_manager = _get_docket_manager()
	if docket_manager == null:
		return {"deleted": 0, "kept": 0, "kept_skill_ids": []}
	var SeederClass = load("res://Scripts/Services/Plugins/PluginSkillSeeder.gd")
	return SeederClass.unseed(plugin_id, docket_manager)


## Recompute unsatisfied_deps for every skill record after a plugin lifecycle
## change (DCR 019df57b T7).  Called from install_plugin and remove_plugin
## after their main work commits.
func _recompute_skill_reactivity() -> Dictionary:
	var docket_manager = _get_docket_manager()
	if docket_manager == null:
		return {"updated": 0, "now_satisfied": 0, "now_unsatisfied": 0}
	var SeederClass = load("res://Scripts/Services/Plugins/PluginSkillSeeder.gd")
	return SeederClass.recompute_unsatisfied(_build_available_tools(), docket_manager)


## Build the union of (1) MCP-registered tools and (2) all installed plugins'
## declared tools.  This is the "available_tools" set used by skill-deps
## resolution: a tool counts as available if it's currently in the MCP
## registry OR known to be declared by an installed plugin (regardless of
## whether that plugin is currently running — invocation time enforces that).
func _build_available_tools() -> Dictionary:
	var available: Dictionary = {}
	if typeof(SingletonObject) != TYPE_NIL and "mcp_manager" in SingletonObject \
			and SingletonObject.mcp_manager != null \
			and "tool_registry" in SingletonObject.mcp_manager:
		for tool_name in (SingletonObject.mcp_manager.tool_registry as Dictionary):
			available[tool_name] = true
	if _db != null:
		for def in _db.get_all():
			for tool_entry in def.tools:
				var tname := str(tool_entry.get("name", ""))
				if not tname.is_empty():
					available[tname] = true
	return available


## Resolve the docket manager via SingletonObject if available, else null.
## Used by skill-seeding helpers; tests bypass this and pass a ToolRegistry directly.
func _get_docket_manager():
	if typeof(SingletonObject) != TYPE_NIL and "docket_manager" in SingletonObject:
		return SingletonObject.docket_manager
	return null


# ---------------------------------------------------------------------------
# Public API — start / stop / restart
# ---------------------------------------------------------------------------

## Start a plugin: create MCPServerConnection, configure stdio, connect.
## State transitions: INSTALLED/STOPPED/ERROR → STARTING → RUNNING or ERROR.
## Returns {"ok": true} or {"error": "..."}.
func start_plugin(id: String) -> Dictionary:
	var def = _db.get_by_id(id)
	if def == null:
		return {"error": "Plugin '%s' not found" % id}

	if def.state == S_RUNNING:
		return {"error": "Plugin '%s' is already running" % id}

	if def.state == S_STARTING:
		return {"error": "Plugin '%s' is already starting" % id}

	if def.state == S_CRASH_LOOP:
		return {"error": "Plugin '%s' is in crash-loop — reset it first" % id}

	# Merge persisted runtime scope grants into def.filesystem_paths so all
	# host.files.* validators see user-approved paths from prior sessions.
	var GrantsClass = load("res://Scripts/Services/Plugins/PluginScopeGrants.gd")
	if GrantsClass != null:
		var grants_store = GrantsClass.new()
		for granted_path in grants_store.get_granted_paths(def.id):
			if granted_path not in def.filesystem_paths:
				def.filesystem_paths.append(granted_path)

	# One-time migration for plugins installed before default-grant landed:
	# if the policy has no entry at all for this plugin (not even an empty list),
	# treat as "freshly installed" and auto-grant declared caps. An empty list
	# means the user explicitly revoked everything — leave it alone.
	if _policy_ref != null and not _policy_ref._grants.has(def.id):
		_auto_grant_declared_capabilities(def)

	# Clean up any leftover connection from a previous run.
	_cleanup_connection(id)

	_transition_state(id, S_STARTING)

	# Build command + args from the manifest.
	# SubProcess doesn't support chdir, so resolve relative script paths to
	# absolute paths based on the plugin's data_directory.
	var command: String = def.entrypoint
	# Always globalize: marketplace-installed plugins have data_directory =
	# "user://plugins/<id>" and side-loaded plugins have an OS-absolute path.
	# SubProcess (fork+exec) needs a real filesystem path either way; an
	# unresolved user:// or res:// scheme passed to OS.execute fails with
	# ERR_CANT_CONNECT even though FileAccess.file_exists() understands it.
	var plugin_dir: String = ProjectSettings.globalize_path(def.data_directory)

	# Resolve relative entrypoint (e.g., "./obs_controller") to absolute path.
	# This is needed for Go binaries and other executables without file extensions,
	# since the args resolution loop below only handles .py/.js/.sh/.gd files.
	if command.begins_with("./"):
		var abs_command: String = plugin_dir.path_join(command.substr(2))
		if FileAccess.file_exists(abs_command) or FileAccess.file_exists(ProjectSettings.localize_path(abs_command)):
			command = abs_command
		else:
			# Binary not found — plugin probably wasn't compiled for this platform.
			# Fail early so the UI shows "error" with a clear message instead of
			# letting the OS-level spawn failure take down the subprocess API.
			var msg := "Plugin binary not found at '%s'. This plugin needs to be compiled for %s." % [abs_command, OS.get_name()]
			push_error("[PluginManager] " + msg)
			_cleanup_connection(id)
			_transition_state(id, S_ERROR)
			return {"error": msg}

	var resolved_args: PackedStringArray = PackedStringArray()
	for arg in def.args:
		if arg.ends_with(".py") or arg.ends_with(".js") or arg.ends_with(".sh") or arg.ends_with(".gd"):
			# Resolve script path relative to plugin directory
			var full_path: String = plugin_dir.path_join(arg)
			if FileAccess.file_exists(full_path) or FileAccess.file_exists(ProjectSettings.localize_path(full_path)):
				resolved_args.append(full_path)
			else:
				resolved_args.append(arg)
		else:
			resolved_args.append(arg)

	# Create and configure the connection.
	var conn := MCPServerConnection.new(def.id, "", MCPServerConnection.TransportType.STDIO)
	conn.configure_stdio(command, resolved_args)

	# Tag the connection with the plugin id so _stdio_request can pass it to the handler.
	conn.plugin_id = id

	# Wire bidirectional capability request handler so the plugin can call
	# Minerva tools mid-execution via minerva/capability on stdout.
	var broker = _get_capability_broker()
	if broker != null:
		conn.capability_request_handler = func(p_id: String, capability: String, args: Dictionary) -> Dictionary:
			return await broker.dispatch(p_id, capability, args)
	else:
		push_warning("[PluginManager] No CapabilityBroker available — plugin '%s' cannot use bidirectional capabilities" % id)

	# Set event broker reference for async event/state routing
	var event_broker_ref = _get_event_broker()
	if event_broker_ref != null:
		conn.event_broker = event_broker_ref

	var rt := _ensure_runtime(id)
	rt["connection"] = conn
	rt["start_time"] = Time.get_unix_time_from_system()
	rt["stopping"] = false

	# Connect liveness signals so we can react to disconnects.
	if not conn.disconnected.is_connected(_on_plugin_disconnected.bind(id)):
		conn.disconnected.connect(_on_plugin_disconnected.bind(id))

	print("[PluginManager] Starting plugin '%s': %s %s" % [id, command, str(def.args)])

	var err: Error = await conn.connect_to_server()

	if err != OK:
		push_error("[PluginManager] Failed to start plugin '%s': %s" % [id, error_string(err)])
		_cleanup_connection(id)
		_transition_state(id, S_ERROR)
		return {"error": "Subprocess failed to start: %s" % error_string(err)}

	_transition_state(id, S_RUNNING)

	# Defensive: ensure the connection's single stdout reader is wired.
	# connect_to_server() already does this for STDIO; the is_connected guard
	# makes this a harmless no-op when it is already connected.
	if conn._subprocess and not conn._subprocess.output_ready.is_connected(conn._drain_stdout):
		conn._subprocess.output_ready.connect(conn._drain_stdout)

	plugin_started.emit(id)
	print("[PluginManager] Plugin '%s' is RUNNING" % id)

	# Dynamic tool discovery: query the backend's tools/list and register the
	# results into PluginToolRegistry with the auto-prefix policy (Option B).
	# Awaited so callers observe a fully-registered tool surface when
	# start_plugin() returns — no race window where the plugin is RUNNING but
	# its tools aren't yet callable. plugin_started fires before discovery so
	# any manifest-declared tools (registered by on_plugin_started) land first;
	# backend discovery then supersedes them via the registry's purge-and-emit
	# path.
	await _discover_backend_tools(id, conn)

	return {"ok": true}


## Discover and register the plugin backend's tools.
## Awaited from start_plugin() so the plugin's tools are callable as soon as
## start_plugin() returns. Reviewer (cycle round 1) flagged the original
## fire-and-forget shape as a race; this is the resolution.
## conn is MCPServerConnection (untyped to avoid parse-order dependency).
func _discover_backend_tools(plugin_id: String, conn) -> void:
	# Resolve tool registry via SingletonObject (avoids circular dep at parse time).
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject") if Engine.get_main_loop() else null
	if so == null:
		push_warning("[PluginManager] SingletonObject not in scene tree; skipping backend tool discovery for '%s'" % plugin_id)
		return
	var registry = so.get("plugin_tool_registry") if "plugin_tool_registry" in so else null
	if registry == null:
		push_warning("[PluginManager] plugin_tool_registry not available; skipping backend tool discovery for '%s'" % plugin_id)
		return
	var result: Dictionary = await registry.register_backend_tools(plugin_id, conn)
	if result.get("error"):
		push_warning("[PluginManager] Backend tool discovery for '%s' failed: %s" % [
			plugin_id, result.get("error")
		])
	elif result.get("skipped"):
		print("[PluginManager] Backend tool discovery skipped for '%s': %s" % [
			plugin_id, result.get("skipped")
		])
	else:
		print("[PluginManager] Backend tool discovery for '%s': %d tool(s) registered" % [
			plugin_id, result.get("registered", []).size()
		])


## Stop a running plugin cleanly.
## Returns {"ok": true} or {"error": "..."}.
func stop_plugin(id: String) -> Dictionary:
	var def = _db.get_by_id(id)
	if def == null:
		return {"error": "Plugin '%s' not found" % id}

	if def.state == S_STOPPED:
		return {"ok": true}  # Already stopped, idempotent.

	var rt := _ensure_runtime(id)
	if rt.get("stopping", false):
		return {"ok": true}  # Re-entrant call during async stop — ignore.
	rt["stopping"] = true

	# Cancel any pending hot-reload debounce to prevent stale restart
	_reload_pending.erase(id)
	_pending_changed_paths.erase(id)

	print("[PluginManager] Stopping plugin '%s'..." % id)

	_cleanup_connection(id)
	_transition_state(id, S_STOPPED)
	rt["stopping"] = false
	rt["start_time"] = 0.0

	plugin_stopped.emit(id)
	print("[PluginManager] Plugin '%s' STOPPED" % id)
	return {"ok": true}


## Stop and then start a plugin.
## Returns {"ok": true} or {"error": "..."}.
func restart_plugin(id: String) -> Dictionary:
	if not _db.has_plugin(id):
		return {"error": "Plugin '%s' not found" % id}

	print("[PluginManager] Restarting plugin '%s'..." % id)

	var stop_result := stop_plugin(id)
	if stop_result.get("error"):
		return {"error": "Restart failed during stop: %s" % stop_result.get("error")}

	# Small yield so the subprocess OS handle is fully released before we
	# respawn — not strictly necessary but avoids port/pipe races.
	await Engine.get_main_loop().create_timer(0.2).timeout

	return await start_plugin(id)


# ---------------------------------------------------------------------------
# Public API — query
# ---------------------------------------------------------------------------

## Return a status snapshot for one plugin.
## Keys: id, state, state_name, uptime_sec, crash_count, running
func get_plugin_status(id: String) -> Dictionary:
	var def = _db.get_by_id(id)
	if def == null:
		return {"error": "Plugin '%s' not found" % id}

	var rt := _ensure_runtime(id)
	var now := Time.get_unix_time_from_system()
	var start_time: float = rt.get("start_time", 0.0)
	var uptime := (now - start_time) if start_time > 0.0 else 0.0

	return {
		"id": id,
		"name": def.name,
		"version": def.version,
		"state": def.state,
		"state_name": ["INSTALLED","STARTING","RUNNING","STOPPED","ERROR","CRASH_LOOP"][def.state],
		"uptime_sec": uptime,
		"crash_count": rt.get("crash_count", 0),
		"running": def.state == S_RUNNING,
	}


## Return a status snapshot for every installed plugin.
func get_all_plugins() -> Array:
	var result: Array = []
	for def in _db.get_all():
		result.append(get_plugin_status(def.id))
	return result


## Expose the underlying PluginDB for read-only access by other systems.
func get_db():  # -> PluginDB
	return _db


## Return the MCPServerConnection for a running plugin, or null.
func get_connection(id: String) -> MCPServerConnection:
	var rt: Dictionary = _runtime.get(id, {})
	return rt.get("connection", null) as MCPServerConnection


## Return the PluginPolicy instance (used by PluginMCPTools).
var _policy_ref = null  # PluginPolicy
func get_policy():  # -> PluginPolicy
	return _policy_ref


## Capabilities that REQUIRE explicit user grant — never auto-granted at install.
## Empty by owner decision: install IS the trust act, so every capability a
## manifest declares is granted at install (the user can revoke any of them
## afterward). Kept as a constant so a future cap can be re-quarantined here
## without touching the grant loop below.
const _NEVER_AUTO_GRANT: Array[String] = []


## Default-grant every capability declared in the plugin's manifest, skipping
## the privilege-escalation denylist. Idempotent: grant_capability is a no-op
## on already-granted caps. Safe to call at install + as a one-time migration
## on plugins installed before this behavior landed.
func _auto_grant_declared_capabilities(def) -> void:
	if def == null:
		return
	if _policy_ref == null:
		push_warning("[PluginManager] _auto_grant: no PluginPolicy reference; skipping for '%s'" % def.id)
		return
	for cap in def.host_capabilities:
		if cap in _NEVER_AUTO_GRANT:
			continue
		_policy_ref.grant_capability(def.id, cap)


## Return the PluginAuditLog instance (used by PluginMCPTools).
var _audit_log_ref = null  # PluginAuditLog
func get_audit_log():  # -> PluginAuditLog
	return _audit_log_ref


# ---------------------------------------------------------------------------
# Public API — bulk operations
# ---------------------------------------------------------------------------

## Enable or disable hot-reload for a plugin.
## When enabled, the plugin is restarted automatically when files in its
## data_directory change (2s poll, 500ms debounce).
func set_auto_reload(id: String, enabled: bool) -> bool:
	return _db.set_auto_reload(id, enabled)


## Start all plugins whose autostart flag is true.
## Called by Minerva on boot.
func start_autostart_plugins() -> void:
	var to_start = _db.get_autostart_plugins()
	print("[PluginManager] Autostarting %d plugin(s)..." % to_start.size())
	for def in to_start:
		var result := await start_plugin(def.id)
		if result.get("error"):
			push_error("[PluginManager] Autostart failed for '%s': %s" % [def.id, result.get("error")])


## Stop all running plugins.  Called by Minerva on exit.
func shutdown_all() -> void:
	print("[PluginManager] Shutting down all plugins...")
	var running = _db.get_by_status(S_RUNNING)
	var starting = _db.get_by_status(S_STARTING)
	for def in (running + starting):
		stop_plugin(def.id)
	print("[PluginManager] All plugins stopped")


# ---------------------------------------------------------------------------
# Crash-loop detection helpers
# ---------------------------------------------------------------------------

## Record a crash timestamp for `id` and return true if the plugin has now
## entered CRASH_LOOP (i.e., hit the threshold within the rolling window).
func _record_crash(id: String) -> bool:
	var rt := _ensure_runtime(id)
	var now := Time.get_unix_time_from_system()

	rt["crash_count"] = rt.get("crash_count", 0) + 1

	# Prune timestamps outside the rolling window.
	var crash_times: Array = rt.get("crash_times", [])
	var cutoff := now - CRASH_LOOP_WINDOW_SEC
	crash_times = crash_times.filter(func(t: float) -> bool: return t >= cutoff)
	crash_times.append(now)
	rt["crash_times"] = crash_times

	return crash_times.size() >= CRASH_LOOP_THRESHOLD


# ---------------------------------------------------------------------------
# Health-check sweep (called from _process)
# ---------------------------------------------------------------------------

func _run_health_checks() -> void:
	for def in _db.get_by_status(S_RUNNING):
		var rt: Dictionary = _runtime.get(def.id, {})
		var conn: MCPServerConnection = rt.get("connection", null)

		# If the connection object is gone or the subprocess is not running,
		# treat it as an unexpected exit.
		var alive := false
		if conn != null and conn.server_connected:
			if is_instance_valid(conn._subprocess) and conn._subprocess.is_running():
				alive = true

		if not alive:
			push_warning("[PluginManager] Health check: plugin '%s' process is gone" % def.id)
			_handle_unexpected_exit(def.id)


# ---------------------------------------------------------------------------
# File-watch sweep (called from _process)
# ---------------------------------------------------------------------------

## Check whether any watched files in installed plugins have been modified.
## Emits plugin_file_changed and starts a debounce timer for auto_reload plugins.
func _run_file_watch_checks() -> void:
	for def in _db.get_all():
		var plugin_dir: String = def.data_directory
		if plugin_dir.is_empty():
			continue

		var current := _scan_plugin_files(plugin_dir)
		if current.is_empty():
			continue

		var stored: Dictionary = _file_mtimes.get(def.id, {})

		# On first scan, just store the baseline — don't trigger a reload.
		if stored.is_empty():
			_file_mtimes[def.id] = current
			continue

		# Compare current times to stored times.
		var changed := false
		for path in current:
			if not stored.has(path) or stored[path] != current[path]:
				changed = true
				break
		# Also detect deletions
		if not changed:
			for path in stored:
				if not current.has(path):
					changed = true
					break

		if changed:
			# Collect the set of changed paths so the debounce handler can apply
			# the correct per-extension reload strategy (design §9.2).
			var changed_paths: Array[String] = []
			for path in current:
				if not stored.has(path) or stored[path] != current[path]:
					changed_paths.append(path)
			for path in stored:
				if not current.has(path):
					changed_paths.append(path)

			_file_mtimes[def.id] = current
			print("[PluginManager] Files changed for plugin '%s'" % def.id)
			plugin_file_changed.emit(def.id)

			if def.auto_reload:
				# Accumulate changed paths for the debounce window (union semantics).
				if not _pending_changed_paths.has(def.id):
					_pending_changed_paths[def.id] = []
				var acc: Array = _pending_changed_paths[def.id]
				for p in changed_paths:
					if not (p in acc):
						acc.append(p)

				if not _reload_pending.has(def.id):
					# Start debounce timer — reload after RELOAD_DEBOUNCE_SEC.
					var timer: SceneTreeTimer = Engine.get_main_loop().create_timer(RELOAD_DEBOUNCE_SEC)
					_reload_pending[def.id] = timer
					var id_copy: String = def.id
					timer.timeout.connect(func(): _on_reload_debounce_expired(id_copy))


## Called when the debounce timer fires for a plugin with auto_reload enabled.
## Implements the hot-reload decision tree (design §9.2):
##   .py/.js/.sh/.json → plugin stop + start (unchanged)
##   .gd → in-place GDScript.reload() if live panels exist; fallback stop+start
##   .tscn → in-place re-instantiate for each live panel using that scene
##   multiple extensions changed → union; tscn always in-place
func _on_reload_debounce_expired(id: String) -> void:
	_reload_pending.erase(id)

	# Collect and clear the accumulated changed paths for this plugin.
	var changed_paths: Array = _pending_changed_paths.get(id, [])
	_pending_changed_paths.erase(id)

	var def = _db.get_by_id(id)
	if def == null or not def.auto_reload:
		return
	# Only reload if the plugin is currently running or in error state.
	if def.state not in [S_RUNNING, S_STARTING, S_ERROR]:
		return

	# Classify changed extensions (union across all changed paths).
	var has_process_ext := false   # py/js/sh/json — always stop+start
	var gd_paths: Array[String] = []
	var tscn_paths: Array[String] = []

	for path in changed_paths:
		var ext: String = (path as String).get_extension().to_lower()
		match ext:
			"py", "js", "sh", "json":
				has_process_ext = true
			"gd":
				gd_paths.append(path)
			"tscn":
				tscn_paths.append(path)

	# If any process-layer file changed, fall back immediately to stop+start.
	if has_process_ext:
		print("[PluginManager] Auto-reloading plugin '%s' (process file change)" % id)
		await restart_plugin(id)
		return

	# Handle .gd changes.
	if not gd_paths.is_empty():
		# _hot_reload_gd is synchronous (no internal awaits) — don't `await` it.
		var gd_ok := _hot_reload_gd(id, gd_paths)
		if not gd_ok:
			# Fallback: full stop+start.
			print(("[PluginManager] hot_reload_gd_failed for '%s' — falling back to " +
				"stop+start") % id)
			await restart_plugin(id)
			return

	# Handle .tscn changes (always in-place, even if .gd was also changed).
	for tscn_path in tscn_paths:
		# _hot_reload_tscn is synchronous — don't `await` it.
		_hot_reload_tscn(id, tscn_path)


## Attempt in-place GDScript reload for all changed .gd paths belonging to plugin `id`.
## Returns true if all reloads succeeded and _on_hot_reload() was dispatched.
## Returns false if any reload failed (caller should fall back to stop+start).
func _hot_reload_gd(id: String, gd_paths: Array[String]) -> bool:
	# Check if there are any live scene panels for this plugin.
	var live_panels: Array = _live_scene_panels.get(id, [])

	if live_panels.is_empty():
		# No live panels — stop+start is safe and simpler.
		print(("[PluginManager] hot_reload_gd: plugin '%s' has no live panels, " +
			"using stop+start") % id)
		return false

	# Attempt GDScript.reload() for every changed .gd file.
	# We iterate ResourceLoader's cache by scanning live panels' scripts.
	# The safest approach: reload every GDScript loaded by the plugin.
	var all_ok := true
	for gd_path in gd_paths:
		# ResourceLoader.has_cached() tells us if the resource is in cache.
		if ResourceLoader.has_cached(gd_path):
			var script = ResourceLoader.load(gd_path, "GDScript", ResourceLoader.CACHE_MODE_REUSE)
			if script is GDScript:
				var reload_err: int = (script as GDScript).reload(true)
				if reload_err != OK:
					push_warning(("[PluginManager] GDScript.reload() failed for '%s' " +
						"(error %d)") % [gd_path, reload_err])
					all_ok = false
			# If it loaded but isn't GDScript (shouldn't happen for .gd), treat as failure.
			elif script == null:
				push_warning("[PluginManager] Could not load script for reload: '%s'" % gd_path)
				all_ok = false
		# If not cached, we can't reload it in-place — but it wasn't running either,
		# so this is not a failure for the hot-reload path.

	if not all_ok:
		return false

	# All reloads succeeded — notify each live panel.
	for entry in live_panels:
		var root: Control = entry.get("root", null)
		if root != null and is_instance_valid(root):
			if root.has_method("_on_hot_reload"):
				root._on_hot_reload()

	print("[PluginManager] hot_reload_gd_ok for plugin '%s'" % id)
	return true


## Perform in-place .tscn re-instantiate for any live panel whose entry_scene
## path matches `tscn_path`.
func _hot_reload_tscn(id: String, tscn_path: String) -> void:
	var live_panels: Array = _live_scene_panels.get(id, [])
	if live_panels.is_empty():
		# No live instance — next open picks up the new version automatically
		# (PluginScenePanelHost always uses CACHE_MODE_IGNORE).
		return

	# Get the broker for unregistration.
	var broker: PluginScenePanelBroker = _get_scene_panel_broker()

	# Work on a copy because we may modify the array during iteration.
	var panels_copy: Array = live_panels.duplicate()
	for entry in panels_copy:
		var entry_tscn: String = entry.get("tscn_path", "")
		if entry_tscn != tscn_path:
			continue

		var panel_name: String = entry.get("panel_name", "")
		var vbox: Control = entry.get("vbox", null)
		var old_root: Control = entry.get("root", null)
		var editor = entry.get("editor", null)

		# Step 1: Call _on_panel_unload() on the old root if it exists.
		if old_root != null and is_instance_valid(old_root):
			if old_root.has_method("_on_panel_unload"):
				old_root._on_panel_unload()

		# Step 2: Unregister old panel from broker.
		if broker != null:
			broker.unregister_panel(id, panel_name)

		# Step 3: Free the old scene.
		if old_root != null and is_instance_valid(old_root):
			old_root.queue_free()

		# Step 4: Re-run §3 scene loading flow in the same Editor wrapper.
		# PluginScenePanelHost.instantiate_into mounts the new instance into vbox
		# and fires _on_panel_loaded(ctx) itself.
		if vbox != null and is_instance_valid(vbox):
			var new_root: Control = PluginScenePanelHost.instantiate_into(
				vbox, id, panel_name, editor)
			# Update registry entry with new root.
			entry["root"] = new_root
			print(("[PluginManager] hot_reload_tscn_ok: re-instantiated panel '%s' " +
				"for plugin '%s'") % [panel_name, id])
		else:
			push_warning(("[PluginManager] hot_reload_tscn: vbox for panel '%s' plugin '%s' " +
				"is no longer valid — cannot re-instantiate") % [panel_name, id])
			# Remove dead entry from registry.
			_live_scene_panels[id].erase(entry)


# ---------------------------------------------------------------------------
# Public API — live scene panel registry
# ---------------------------------------------------------------------------

## Register a live scene panel so hot-reload can find and re-instantiate it.
##
## Called by Editor.create() (or equivalent) after a PLUGIN_SCENE panel is
## successfully mounted.  `tscn_path` is the absolute path to the .tscn file
## so _hot_reload_tscn can match changed paths to live instances.
func register_live_panel(
		plugin_id: String,
		panel_name: String,
		tscn_path: String,
		vbox: Control,
		root: Control,
		editor  # Editor — untyped to avoid circular dep
) -> void:
	if not _live_scene_panels.has(plugin_id):
		_live_scene_panels[plugin_id] = []
	var entry := {
		"panel_name": panel_name,
		"tscn_path":  tscn_path,
		"vbox":       vbox,
		"root":       root,
		"editor":     editor,
	}
	_live_scene_panels[plugin_id].append(entry)


## Unregister a live scene panel (called on tab close or plugin stop).
func unregister_live_panel(plugin_id: String, panel_name: String) -> void:
	if not _live_scene_panels.has(plugin_id):
		return
	var panels: Array = _live_scene_panels[plugin_id]
	for i in range(panels.size() - 1, -1, -1):
		if panels[i].get("panel_name", "") == panel_name:
			panels.remove_at(i)


## Return all live panel entries for a plugin (read-only copy).
func get_live_panels(plugin_id: String) -> Array:
	return _live_scene_panels.get(plugin_id, []).duplicate()


## Return a Dictionary of { absolute_path: modified_time_int } for all watched
## files (*.py, *.js, *.sh, *.json) found directly in plugin_dir.
## Does not recurse into sub-directories.
func _scan_plugin_files(plugin_dir: String) -> Dictionary:
	var result: Dictionary = {}
	var dir := DirAccess.open(plugin_dir)
	if dir == null:
		return result

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var ext := file_name.get_extension().to_lower()
			if ext in WATCH_EXTENSIONS:
				var full_path := plugin_dir.path_join(file_name)
				result[full_path] = FileAccess.get_modified_time(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()
	return result


# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

## Called when MCPServerConnection emits `disconnected` while we did NOT
## initiate the stop (i.e., no stop_plugin call is in progress).
func _on_plugin_disconnected(id: String) -> void:
	var def = _db.get_by_id(id)
	if def == null:
		return

	# If we are already stopping or the state is already STOPPED/ERROR/CRASH_LOOP
	# this signal is expected — ignore it.
	var rt: Dictionary = _runtime.get(id, {})
	if rt.get("stopping", false):
		return

	if def.state in [S_STOPPED,
					 S_ERROR,
					 S_CRASH_LOOP]:
		return

	push_warning("[PluginManager] Plugin '%s' disconnected unexpectedly" % id)
	_handle_unexpected_exit(id)


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Central handler for any unexpected process exit (from health-check or
## disconnect signal).  Updates state and emits signals.
func _handle_unexpected_exit(id: String) -> void:
	var rt := _ensure_runtime(id)

	# Avoid double-handling (health-check and signal may fire close together).
	if rt.get("stopping", false):
		return
	rt["stopping"] = true

	_cleanup_connection(id)
	rt["stopping"] = false
	rt["start_time"] = 0.0

	plugin_crashed.emit(id)

	var entered_crash_loop := _record_crash(id)
	if entered_crash_loop:
		push_error("[PluginManager] Plugin '%s' has crashed %d times in %ds — entering CRASH_LOOP" % [
			id, CRASH_LOOP_THRESHOLD, int(CRASH_LOOP_WINDOW_SEC)
		])
		_transition_state(id, S_CRASH_LOOP)
	else:
		_transition_state(id, S_ERROR)


## Update the DB state and emit plugin_state_changed.
func _transition_state(id: String, new_state: int) -> void:
	var def = _db.get_by_id(id)
	if def == null:
		return
	var old_state: int = def.state
	if old_state == new_state:
		return
	_db.update_state(id, new_state)
	plugin_state_changed.emit(id, old_state, new_state)


## Disconnect and free a connection, leaving the runtime entry intact.
func _cleanup_connection(id: String) -> void:
	var rt: Dictionary = _runtime.get(id, {})
	var conn: MCPServerConnection = rt.get("connection", null)
	if conn == null:
		return

	# Detach signal before disconnecting to avoid re-entrant crash handling.
	if conn.disconnected.is_connected(_on_plugin_disconnected.bind(id)):
		conn.disconnected.disconnect(_on_plugin_disconnected.bind(id))

	if conn.server_connected or is_instance_valid(conn._subprocess):
		conn.disconnect_from_server()

	rt["connection"] = null


## Delete a directory and all its contents recursively.
## Returns OK on success, or an error code.
func _delete_directory_recursive(path: String) -> Error:
	var abs_path := ProjectSettings.globalize_path(path) if path.begins_with("user://") else path
	var dir := DirAccess.open(abs_path)
	if dir == null:
		# Maybe it's a file or doesn't exist
		var fallback_dir := DirAccess.open(abs_path.get_base_dir())
		if fallback_dir != null:
			return fallback_dir.remove(abs_path)
		return DirAccess.get_open_error()
	# Remove all files and subdirectories first
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		var full := abs_path.path_join(entry)
		if dir.current_is_dir():
			_delete_directory_recursive(full)
		else:
			dir.remove(full)
		entry = dir.get_next()
	dir.list_dir_end()
	# Now remove the empty directory itself
	var cleanup_dir := DirAccess.open(abs_path.get_base_dir())
	if cleanup_dir != null:
		return cleanup_dir.remove(abs_path)
	return OK


## Return the CapabilityBroker from SingletonObject, or null if unavailable.
func _get_capability_broker():
	var root = Engine.get_main_loop().root if Engine.get_main_loop() else null
	if root == null:
		return null
	var so = root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	return so.get("plugin_capability_broker") if "plugin_capability_broker" in so else null


## Return the PluginEventBroker from SingletonObject, or null if unavailable.
func _get_event_broker():
	var root = Engine.get_main_loop().root if Engine.get_main_loop() else null
	if root == null:
		return null
	var so = root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	return so.get("plugin_event_broker") if "plugin_event_broker" in so else null


## Return the PluginScenePanelBroker from SingletonObject, or null if unavailable.
func _get_scene_panel_broker() -> PluginScenePanelBroker:
	var root = Engine.get_main_loop().root if Engine.get_main_loop() else null
	if root == null:
		return null
	var so = root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	return so.get("plugin_scene_panel_broker") if "plugin_scene_panel_broker" in so else null


## Return the runtime Dictionary for `id`, creating it if absent.
func _ensure_runtime(id: String) -> Dictionary:
	if not _runtime.has(id):
		_runtime[id] = {
			"connection": null,
			"start_time": 0.0,
			"crash_count": 0,
			"crash_times": [],
			"stopping": false,
		}
	return _runtime[id]
