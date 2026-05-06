## FileWatcherService — pub/sub filesystem watcher.
##
## Generic platform-level capability: any caller (DocumentRegistry, plugins via
## host.fs.* broker channels, future code) registers paths and receives a
## `file_changed` signal when the underlying file's mtime or size changes.
##
## Implementation: refcounted watch list + polling. A path is watched as long
## as at least one owner_id is subscribed; the first watch() snapshots disk
## state, subsequent watch()es just add owners. `tick()` stats every watched
## path and emits `file_changed` for any diff. The Timer that drives `tick()`
## lives in a separate ticker Node so this service stays RefCounted and
## headless-testable (tests call `tick()` directly).
##
## Usage:
##   var fw := FileWatcherService.get_instance()
##   fw.watch("/abs/path", "doc_registry:/abs/path")
##   fw.file_changed.connect(func(path, mtime, size): ...)
##   ...
##   fw.unwatch("/abs/path", "doc_registry:/abs/path")
class_name FileWatcherService extends RefCounted

## Emitted when a watched path's mtime or size changes between ticks.
## - On first appearance of a non-existent watched path: emitted with current mtime/size.
## - On disappearance: NOT emitted (silent re-baseline to {0,0}).
signal file_changed(path: String, mtime: int, size: int)

# ── Singleton ──────────────────────────────────────────────────────────────

static var _instance: FileWatcherService = null

static func get_instance() -> FileWatcherService:
	if _instance == null:
		_instance = FileWatcherService.new()
	return _instance

## Reset the singleton. Used for testing.
static func reset_instance() -> void:
	_instance = null

# ── State ──────────────────────────────────────────────────────────────────

## absolute_path -> {mtime: int, size: int, owners: Dictionary[String, bool]}
var _watches: Dictionary = {}

# ── API ────────────────────────────────────────────────────────────────────

## Subscribe owner_id to changes on path. Path resolved through PathResolver.
## First subscriber to a path snapshots its current mtime/size. Subsequent
## subscribers just add to the owners set.
##
## Returns {ok: true} or {ok: false, error: String}.
func watch(path: String, owner_id: String) -> Dictionary:
	if owner_id.is_empty():
		return {"ok": false, "error": "owner_id_empty"}
	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return {"ok": false, "error": resolved.error}
	var abs_path: String = resolved.path

	if _watches.has(abs_path):
		_watches[abs_path].owners[owner_id] = true
		return {"ok": true}

	var snap := _stat_snapshot(abs_path)
	var owners := {owner_id: true}
	_watches[abs_path] = {
		"mtime": snap.mtime,
		"size": snap.size,
		"owners": owners,
	}
	return {"ok": true}


## Unsubscribe owner_id from path. When the last owner leaves, the watch is
## removed entirely. Unknown path or owner_id is a silent no-op.
func unwatch(path: String, owner_id: String) -> void:
	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return
	var abs_path: String = resolved.path
	if not _watches.has(abs_path):
		return
	var entry: Dictionary = _watches[abs_path]
	entry.owners.erase(owner_id)
	if entry.owners.is_empty():
		_watches.erase(abs_path)


## Remove every watch held by owner_id. Returns the number of watches removed.
## Used at plugin/panel teardown so subscriptions don't leak when an owner
## disappears without explicit unwatch calls.
func unwatch_all(owner_id: String) -> int:
	var removed := 0
	var paths_to_drop: Array[String] = []
	for abs_path in _watches.keys():
		var entry: Dictionary = _watches[abs_path]
		if entry.owners.has(owner_id):
			entry.owners.erase(owner_id)
			removed += 1
			if entry.owners.is_empty():
				paths_to_drop.append(str(abs_path))
	for p in paths_to_drop:
		_watches.erase(p)
	return removed


## Synchronously re-stat one path and emit file_changed if it differs from the
## stored snapshot. No-op when path is not watched. Used by `minerva_disk_write`
## to surface its own changes immediately rather than waiting for the next tick.
func poke(path: String) -> void:
	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return
	var abs_path: String = resolved.path
	if not _watches.has(abs_path):
		return
	_check_one(abs_path)


## Stat every watched path and emit file_changed for any diff. Returns the
## number of paths that changed in this tick. Headless tests call this
## directly; production drives it from a Timer in FileWatcherTicker.
func tick() -> int:
	var changed_count := 0
	for abs_path in _watches.keys():
		if _check_one(str(abs_path)):
			changed_count += 1
	return changed_count


## Whether a path is currently watched (by anyone).
func is_watched(path: String) -> bool:
	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return false
	return _watches.has(resolved.path)


## Number of distinct watched paths.
func watch_count() -> int:
	return _watches.size()


## Number of owners on a given path. Returns 0 if not watched.
func owner_count(path: String) -> int:
	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return 0
	if not _watches.has(resolved.path):
		return 0
	return (_watches[resolved.path].owners as Dictionary).size()

# ── Internals ──────────────────────────────────────────────────────────────

## Compare disk against snapshot for one watched path. Updates the snapshot
## and emits file_changed when there is a diff (and the file currently exists).
## Returns true if a change was detected.
func _check_one(abs_path: String) -> bool:
	var snap := _stat_snapshot(abs_path)
	var entry: Dictionary = _watches[abs_path]
	var prior_mtime: int = entry.mtime
	var prior_size: int = entry.size
	if snap.mtime == prior_mtime and snap.size == prior_size:
		return false

	# Always re-baseline so deletes don't fire repeatedly.
	entry.mtime = snap.mtime
	entry.size = snap.size

	# Suppress emission for disappearance (mtime drops to 0). Watchers care
	# about replacement / external edits, not deletion (out of T7 DoD scope).
	if snap.mtime == 0:
		return false

	file_changed.emit(abs_path, snap.mtime, snap.size)
	return true


func _stat_snapshot(abs_path: String) -> Dictionary:
	var s := DiskAccess.stat(abs_path)
	if not s.ok:
		return {"mtime": 0, "size": 0}
	return {"mtime": int(s.mtime), "size": int(s.size)}
