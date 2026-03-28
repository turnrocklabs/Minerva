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
	print("[PluginManager] Installed plugin '%s' v%s" % [def.id, def.version])
	return {"ok": true, "id": def.id}


## Stop the plugin if running, then remove it from the DB.
## Returns {"ok": true} or {"error": "..."}.
func remove_plugin(id: String) -> Dictionary:
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
