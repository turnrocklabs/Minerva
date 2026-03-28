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
const WATCH_EXTENSIONS := ["py", "js", "sh", "json"]

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
## Returns {"ok": true, "id": "..."} or {"error": "..."}.
func install_plugin(manifest_path: String) -> Dictionary:
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

	print("[PluginManager] Installed plugin '%s' v%s" % [def.id, def.version])
	return {"ok": true, "id": def.id}


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


## Stop the plugin if running, then remove it from the DB.
## If delete_data is true, also remove the plugin's data directory.
## Returns {"ok": true} or {"error": "..."}.
func remove_plugin(id: String, delete_data: bool = false) -> Dictionary:
	if not _db.has_plugin(id):
		return {"error": "Plugin '%s' not found" % id}

	var def = _db.get_by_id(id)
	if def.state in [S_RUNNING, S_STARTING]:
		var stop_result := await stop_plugin(id)
		if stop_result.get("error"):
			return {"error": "Could not stop plugin before removal: %s" % stop_result.get("error")}

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
	return {"ok": true}


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

	# Clean up any leftover connection from a previous run.
	_cleanup_connection(id)

	_transition_state(id, S_STARTING)

	# Build command + args from the manifest.
	# SubProcess doesn't support chdir, so resolve relative script paths to
	# absolute paths based on the plugin's data_directory.
	var command: String = def.entrypoint
	var plugin_dir: String = def.data_directory
	if plugin_dir.begins_with("res://"):
		plugin_dir = ProjectSettings.globalize_path(plugin_dir)

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
	plugin_started.emit(id)
	print("[PluginManager] Plugin '%s' is RUNNING" % id)
	return {"ok": true}


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

	var stop_result := await stop_plugin(id)
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
		await stop_plugin(def.id)
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
			_file_mtimes[def.id] = current
			print("[PluginManager] Files changed for plugin '%s'" % def.id)
			plugin_file_changed.emit(def.id)

			if def.auto_reload and not _reload_pending.has(def.id):
				# Start debounce timer — reload after RELOAD_DEBOUNCE_SEC.
				var timer: SceneTreeTimer = Engine.get_main_loop().create_timer(RELOAD_DEBOUNCE_SEC)
				_reload_pending[def.id] = timer
				var id_copy: String = def.id
				timer.timeout.connect(func(): _on_reload_debounce_expired(id_copy))


## Called when the debounce timer fires for a plugin with auto_reload enabled.
func _on_reload_debounce_expired(id: String) -> void:
	_reload_pending.erase(id)
	var def = _db.get_by_id(id)
	if def == null or not def.auto_reload:
		return
	# Only reload if the plugin is currently running or in error state.
	if def.state not in [S_RUNNING, S_STARTING, S_ERROR]:
		return
	print("[PluginManager] Auto-reloading plugin '%s' due to file change" % id)
	await restart_plugin(id)


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
		var parent := DirAccess.open(abs_path.get_base_dir())
		if parent != null:
			return parent.remove(abs_path)
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
	var parent := DirAccess.open(abs_path.get_base_dir())
	if parent != null:
		return parent.remove(abs_path)
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
