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

# ── API ────────────────────────────────────────────────────────────────────

## Get or lazily create a buffer for path.
##
## On first access for an existing file, the buffer is loaded from disk.
## On first access for a path that does not exist on disk, an empty buffer
## is created (supports the "agent writes to a new path" case).
## Subsequent calls for the same resolved path return the same instance.
##
## Returns {ok: true, buffer: DocumentBuffer} or {ok: false, error: String}.
func get_or_create_buffer(path: String) -> Dictionary:
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
	return {"ok": true, "buffer": buffer}


## Whether a buffer currently exists for path.
func has_buffer(path: String) -> bool:
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
	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return
	_buffers.erase(resolved.path)


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
