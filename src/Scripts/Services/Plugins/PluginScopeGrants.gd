class_name PluginScopeGrants
extends RefCounted
## Persistence layer for runtime filesystem scope grants.
##
## Stores per-plugin runtime grants that expand a plugin's filesystem_paths
## beyond what was declared in the manifest.  Grants are written on every
## grant_path() call so they survive a Minerva restart.
##
## Storage: user://plugins/scoped_paths_grants.json
## Shape:   { "plugin_id": ["path", "path", ...], ... }
##
## Usage: PluginManager merges get_granted_paths(plugin_id) into
## def.filesystem_paths on start_plugin() so the paths are in scope for
## the session.  CapabilityBroker calls grant_path() when the user confirms
## a host.permissions.grant_scope request.

const GRANTS_PATH := "user://plugins/scoped_paths_grants.json"

## In-memory store: plugin_id -> Array[String] of granted paths
var _grants: Dictionary = {}


func _init() -> void:
	_ensure_data_dir()
	_load()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Return a copy of all persisted scope-grant paths for a plugin.
## Returns an empty Array if no grants exist for the plugin.
func get_granted_paths(plugin_id: String) -> Array[String]:
	if not _grants.has(plugin_id):
		return []
	var result: Array[String] = []
	for p in _grants[plugin_id]:
		result.append(str(p))
	return result


## Append a path to the persisted grants for a plugin.
## Idempotent — calling with an already-granted path is a no-op.
func grant_path(plugin_id: String, path: String) -> void:
	if plugin_id.is_empty() or path.is_empty():
		push_warning("[PluginScopeGrants] grant_path: empty plugin_id or path")
		return

	if not _grants.has(plugin_id):
		_grants[plugin_id] = []

	var paths: Array = _grants[plugin_id]
	if path not in paths:
		paths.append(path)
		_save()
		print("[PluginScopeGrants] Granted path '%s' to plugin '%s'" % [path, plugin_id])


## Remove a path from the persisted grants for a plugin.
## Idempotent — revoking a non-existent grant is a no-op.
func revoke_path(plugin_id: String, path: String) -> void:
	if plugin_id.is_empty() or path.is_empty():
		return

	if not _grants.has(plugin_id):
		return

	var paths: Array = _grants[plugin_id]
	var idx := paths.find(path)
	if idx >= 0:
		paths.remove_at(idx)
		_save()
		print("[PluginScopeGrants] Revoked path '%s' from plugin '%s'" % [path, plugin_id])


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

func _load() -> void:
	if not FileAccess.file_exists(GRANTS_PATH):
		return

	var file := FileAccess.open(GRANTS_PATH, FileAccess.READ)
	if not file:
		push_error("[PluginScopeGrants] Cannot open %s" % GRANTS_PATH)
		return

	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("[PluginScopeGrants] Failed to parse %s" % GRANTS_PATH)
		return

	var root: Variant = json.data
	if not root is Dictionary:
		return

	_grants.clear()
	for pid in (root as Dictionary).keys():
		var paths = (root as Dictionary)[pid]
		if paths is Array:
			_grants[str(pid)] = paths.duplicate()


func _save() -> void:
	var out: Dictionary = {}
	for pid in _grants.keys():
		out[pid] = _grants[pid].duplicate()

	var json := JSON.stringify(out, "\t")
	var file := FileAccess.open(GRANTS_PATH, FileAccess.WRITE)
	if not file:
		push_error("[PluginScopeGrants] Cannot write %s: %s" % [GRANTS_PATH, FileAccess.get_open_error()])
		return

	file.store_string(json)
	file.close()


func _ensure_data_dir() -> void:
	var dir := DirAccess.open("user://")
	if dir and not dir.dir_exists("plugins"):
		dir.make_dir("plugins")
