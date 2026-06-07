## DocumentRegistry — singleton mapping path → DocumentBuffer.
##
## Ensures every editing surface (text editor, plugin render panel, MCP tool)
## that touches a given file path shares the same buffer instance. The buffer
## is the canonical source of truth; disk is loaded on first access and
## written only when save_to_disk() is called on a buffer.
##
## Usage:
##   var reg := DocumentRegistry.get_instance()
##   var r := reg.get_or_create_buffer("/abs/path/to/file.txt")
##   if r.ok:
##       var buf: DocumentBuffer = r.buffer
##       ...
class_name DocumentRegistry extends RefCounted

## Emitted whenever an external mutation lands on a buffered path while that
## buffer is dirty. UI consumers (e.g. the Reload/Keep dialog) connect once
## here instead of per-buffer. Coalesced with `_prompt_open[path]` — only one
## emission per buffer per prompt cycle until `clear_prompt_open(path)` is called.
signal external_change_pending(path: String)

## Emitted when a buffer is disposed. Lets UI consumers dismiss any open
## external-change dialog tied to the path so an orphan dialog can't outlive
## the buffer it referenced.
signal buffer_disposed(path: String)

## Emitted when a new real-path buffer is created. The change journal (work item
## 019ea01719a2) connects here to start tracking every file's edits. Fires once
## per path on creation, not on cache hits.
signal buffer_created(path: String, buffer: DocumentBuffer)

# ── Unbacked buffer support ────────────────────────────────────────────────
#
# An "unbacked" buffer is one with no file path — created for anonymous
# editors (e.g. minerva_create_plugin_editor on a paired_dsl panel).
# It uses a synthetic identity of the form "unbacked://<uid>" as its key in
# _buffers and its file_path. No disk read on creation, no watcher subscription.
# On Save-As (Editor.save_file_to_disc(real_path)), the editor calls
# rebind_buffer to atomically re-key the buffer to the real path — preserving
# its instance identity so other panels (e.g. paired_dsl render side) stay
# attached without the broker having to re-send attach_buffer.

const _UNBACKED_PREFIX := "unbacked://"


static func is_unbacked_path(path: String) -> bool:
	return path.begins_with(_UNBACKED_PREFIX)


# ── Singleton ───────────────────────────────────────────────────────────────

static var _instance: DocumentRegistry = null

## Returns the global registry instance.
static func get_instance() -> DocumentRegistry:
	if _instance == null:
		_instance = DocumentRegistry.new()
	return _instance

## Reset the singleton. Used for testing.
static func reset_instance() -> void:
	_instance = null

# ── State ──────────────────────────────────────────────────────────────────

## absolute_path -> DocumentBuffer
var _buffers: Dictionary = {}

## absolute_path -> bool. True while a Reload/Keep prompt is open for that
## buffer. Coalesces multiple external-change events so the user sees one
## dialog at a time per buffer (DCR DoD bullet 5).
var _prompt_open: Dictionary = {}

## Whether the watcher has been wired to FileWatcherService. Lazily initialized
## on the first buffer creation so tests that don't need the watcher (and run
## before the autoload exists) aren't disturbed.
var _watcher_connected: bool = false

# ── Owner ID for FileWatcherService subscriptions ──────────────────────────

const _WATCHER_OWNER_PREFIX := "doc_registry"

static func _watcher_owner_id_for(abs_path: String) -> String:
	return "%s:%s" % [_WATCHER_OWNER_PREFIX, abs_path]

# ── API ────────────────────────────────────────────────────────────────────

## Get or lazily create a buffer for path.
##
## On first access for an existing file, the buffer is loaded from disk.
## On first access for a path that does not exist on disk, an empty buffer
## is created (supports the "agent writes to a new path" case).
## Subsequent calls for the same resolved path return the same instance.
##
## For unbacked paths (begin with "unbacked://"), this is a lookup-only call —
## returns the existing buffer if one was minted via create_unbacked_buffer,
## otherwise an error. Unbacked buffers must be created explicitly.
##
## Returns {ok: true, buffer: DocumentBuffer} or {ok: false, error: String}.
func get_or_create_buffer(path: String) -> Dictionary:
	if is_unbacked_path(path):
		if _buffers.has(path):
			return {"ok": true, "buffer": _buffers[path]}
		return {"ok": false, "error": "unbacked buffer not found: %s (use create_unbacked_buffer to mint one)" % path}

	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return {"ok": false, "error": resolved.error}
	var abs_path: String = resolved.path

	if _buffers.has(abs_path):
		return {"ok": true, "buffer": _buffers[abs_path]}

	var initial_text := ""
	if FileAccess.file_exists(abs_path):
		var read_result := DiskAccess.read(abs_path)
		if not read_result.ok:
			return {"ok": false, "error": read_result.error}
		initial_text = read_result.text

	var buffer := DocumentBuffer.new(abs_path, initial_text)
	_buffers[abs_path] = buffer
	_subscribe_to_watcher(abs_path)
	buffer_created.emit(abs_path, buffer)
	return {"ok": true, "buffer": buffer}


## Mint a new unbacked buffer with a synthetic identity.
##
## Used for anonymous editors (created via minerva_create_plugin_editor on
## paired_dsl panels, etc.) that have no file path yet. The buffer's
## file_path is "unbacked://<uid>" until Save-As re-keys it via rebind_buffer.
##
## Returns {ok: true, buffer: DocumentBuffer}.
func create_unbacked_buffer() -> Dictionary:
	var uid: String = "%d-%d" % [Time.get_ticks_usec(), randi()]
	var synthetic: String = _UNBACKED_PREFIX + uid
	# Collision is extremely unlikely but cheap to guard against.
	while _buffers.has(synthetic):
		uid = "%d-%d" % [Time.get_ticks_usec(), randi()]
		synthetic = _UNBACKED_PREFIX + uid
	var buf := DocumentBuffer.new(synthetic, "")
	_buffers[synthetic] = buf
	# Intentionally NOT subscribed to FileWatcherService — no real file.
	return {"ok": true, "buffer": buf}


## Atomically re-key a buffer from old_path to new_path. Used by Save-As on
## unbacked editors — promotes the synthetic identity to a real path while
## preserving the buffer instance so already-attached panels stay attached.
##
## new_path must not already have a buffer (other than old_path itself) — a
## collision would mean two distinct buffers want the same canonical path,
## which is unsafe to merge silently.
##
## Returns {ok: true, buffer: DocumentBuffer} or {ok: false, error: String}.
func rebind_buffer(old_path: String, new_path: String) -> Dictionary:
	if not _buffers.has(old_path):
		return {"ok": false, "error": "no buffer for path: %s" % old_path}

	var resolved_new: String = new_path
	if not is_unbacked_path(new_path):
		var resolved := PathResolver.resolve(new_path)
		if not resolved.ok:
			return {"ok": false, "error": resolved.error}
		resolved_new = resolved.path

	if resolved_new == old_path:
		return {"ok": true, "buffer": _buffers[old_path]}
	if _buffers.has(resolved_new):
		return {"ok": false, "error": "buffer already exists for: %s" % resolved_new}

	var buf: DocumentBuffer = _buffers[old_path]
	_buffers.erase(old_path)
	_buffers[resolved_new] = buf
	buf.file_path = resolved_new

	# Adjust watcher subscriptions — only real paths are watched.
	if not is_unbacked_path(old_path):
		FileWatcherService.get_instance().unwatch(old_path, _watcher_owner_id_for(old_path))
	if not is_unbacked_path(resolved_new):
		_subscribe_to_watcher(resolved_new)

	return {"ok": true, "buffer": buf}


## Whether a buffer currently exists for path.
func has_buffer(path: String) -> bool:
	if is_unbacked_path(path):
		return _buffers.has(path)
	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return false
	return _buffers.has(resolved.path)


## Remove the buffer from the registry without saving.
##
## The caller is responsible for handling dirty state (e.g. prompting Save /
## Discard / Cancel) before calling this. dispose_buffer is intentionally
## low-level so tests and force-close paths can use it without policy.
func dispose_buffer(path: String) -> void:
	var abs_path: String
	if is_unbacked_path(path):
		abs_path = path
	else:
		var resolved := PathResolver.resolve(path)
		if not resolved.ok:
			return
		abs_path = resolved.path
	_buffers.erase(abs_path)
	_prompt_open.erase(abs_path)
	if not is_unbacked_path(abs_path):
		FileWatcherService.get_instance().unwatch(abs_path, _watcher_owner_id_for(abs_path))
	buffer_disposed.emit(abs_path)


## Whether a Reload/Keep prompt is currently open for the given buffer.
## Used by the dialog UI to coalesce — second external change while a prompt
## is up should not stack a second dialog.
func is_prompt_open(path: String) -> bool:
	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return false
	return _prompt_open.get(resolved.path, false)


## Mark the prompt as closed for the given buffer. Called by the dialog UI
## after the user picks Reload or Keep, so the next external change can fire
## a fresh prompt.
func clear_prompt_open(path: String) -> void:
	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return
	_prompt_open.erase(resolved.path)


## Trigger an immediate watcher check for a path. Used by `minerva_disk_write`
## after a successful write to a buffered path so the prompt fires without
## waiting for the next polling tick.
func poke_path(path: String) -> void:
	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return
	FileWatcherService.get_instance().poke(resolved.path)


## All currently-tracked buffer paths, absolute.
func list_buffer_paths() -> Array[String]:
	var result: Array[String] = []
	for key in _buffers.keys():
		result.append(str(key))
	return result


## Paths of buffers whose dirty flag is true. Useful for Save All and
## close-time prompts.
func list_dirty_buffer_paths() -> Array[String]:
	var result: Array[String] = []
	for key in _buffers.keys():
		var buf: DocumentBuffer = _buffers[key]
		if buf.dirty:
			result.append(str(key))
	return result


# ── External-change watcher integration ───────────────────────────────────
#
# DocumentRegistry is one client of FileWatcherService — the others (plugins
# via host.fs.* broker channels per Task 7.5) follow the same shape. Each
# created buffer subscribes its path with a unique owner_id; on dispose, it
# unsubscribes. The single connection to file_changed dispatches per-path:
#
#   * Buffer is clean         → silent reload_from_disk()
#   * Buffer is dirty         → notify_external_change() (UI shows Reload/Keep)
#   * Buffer matches the new  → no-op (covers the case where Minerva itself
#     snapshot already           wrote the file via save_to_disk; the watcher
#                                fires anyway and the snapshot now matches)

func _subscribe_to_watcher(abs_path: String) -> void:
	var fw := FileWatcherService.get_instance()
	if not _watcher_connected:
		fw.file_changed.connect(_on_file_changed)
		_watcher_connected = true
	fw.watch(abs_path, _watcher_owner_id_for(abs_path))


func _on_file_changed(path: String, _mtime: int, _size: int) -> void:
	if not _buffers.has(path):
		return
	var buf: DocumentBuffer = _buffers[path]

	# Note: we deliberately do NOT short-circuit on a "self-save" (mtime,size)
	# match here. The dirty/clean branch below handles every case correctly:
	#
	#   * Clean buffer → reload_from_disk reads disk and only emits text_changed
	#     if disk content differs from buffer text. Our own save leaves them
	#     identical, so reload is a silent no-op.
	#   * Dirty buffer → user has unsaved edits that, by definition, diverge
	#     from anything on disk; a watcher emission must always be treated as
	#     an external change. (save_to_disk clears dirty, so a dirty buffer
	#     cannot have caused this emission via Minerva itself.)
	#
	# Avoiding the (mtime,size) suppression also dodges the second-resolution
	# race where an external write inside the same second as our save produces
	# colliding stats and would otherwise be silently absorbed.
	if not buf.dirty:
		buf.reload_from_disk()
		return

	# Dirty buffer — surface the conflict. Coalesce: only one prompt at a time
	# per buffer (DCR DoD bullet 5).
	if _prompt_open.get(path, false):
		return
	_prompt_open[path] = true
	buf.notify_external_change()
	external_change_pending.emit(path)
