## DocumentBuffer — shared text state for a single file path.
##
## The buffer is the canonical source of truth for the document at file_path.
## Disk is loaded once (when the buffer is created by DocumentRegistry) and
## written only when save_to_disk() is called.
##
## Mutate the buffer through apply_edit() / save_to_disk() / reload_from_disk().
## Direct writes to text/version/dirty bypass change tracking and signal emission;
## treat them as read-only by convention.
class_name DocumentBuffer extends RefCounted

## Emitted whenever buffer text changes via apply_edit() or reload_from_disk().
signal text_changed(text: String, version: int)

## Emitted when an external mutation to the underlying file is detected.
## Detection is wired by DocumentRegistry's watcher (Task 7); this signal is
## the connection point for UI consumers (e.g. the Reload/Keep prompt).
signal external_change_detected

## Emitted after save_to_disk() succeeds.
signal saved

var file_path: String = ""
var text: String = ""
var version: int = 0
var dirty: bool = false

## Filesystem snapshot at the moment the buffer last knew it was in sync with
## disk (construct, save, reload). DocumentRegistry's external-change watcher
## compares fresh stat results against these to detect external mutations.
## Both are 0 when the underlying file did not exist at snapshot time.
var loaded_mtime: int = 0
var loaded_size: int = 0

## Number of UI panels (text editor, plugin render panel, etc.) currently
## attached to this buffer. Owned by attach() / detach(). When it reaches
## zero, the caller of detach() may safely dispose the buffer from the
## registry — no other surface is reading or mirroring it.
##
## Refcount, not an attachment-list: panels don't currently need to know
## *who* else is attached, only *whether* they're the last to leave.
var attached_count: int = 0


func _init(path: String, initial_text: String) -> void:
	file_path = path
	text = initial_text
	version = 0
	dirty = false
	attached_count = 0
	_snapshot_disk_state()


## Increment the attachment refcount. Call when a UI surface starts mirroring
## this buffer (Editor.gd on file open, plugin render panel on attach_buffer).
func attach() -> void:
	attached_count += 1


## Decrement the attachment refcount. Returns the new count. Call when a UI
## surface stops mirroring (Editor.gd on tab close, plugin panel teardown).
## Returning 0 signals the caller "you were the last; safe to dispose."
func detach() -> int:
	if attached_count > 0:
		attached_count -= 1
	return attached_count


## Replace buffer text with new_text. No-op when text is unchanged
## (no signal, no version bump, dirty preserved).
##
## On change: bumps version, sets dirty=true, fires text_changed.
func apply_edit(new_text: String) -> void:
	if new_text == text:
		return
	text = new_text
	version += 1
	dirty = true
	text_changed.emit(text, version)


## Flush buffer to disk via DiskAccess. Clears dirty on success and fires saved.
##
## Returns {ok: true} or {ok: false, error: String}.
func save_to_disk() -> Dictionary:
	var result := DiskAccess.write(file_path, text)
	if not result.ok:
		return result
	dirty = false
	_snapshot_disk_state()
	saved.emit()
	return {"ok": true}


## Re-read text from disk, replacing buffer contents.
##
## If disk text differs from current buffer text, version bumps and text_changed fires.
## Dirty is cleared regardless (the user's pending edits are discarded by reload).
##
## Returns {ok: true} or {ok: false, error: String}.
func reload_from_disk() -> Dictionary:
	var result := DiskAccess.read(file_path)
	if not result.ok:
		return result
	var disk_text: String = result.text
	if disk_text != text:
		text = disk_text
		version += 1
		text_changed.emit(text, version)
	dirty = false
	_snapshot_disk_state()
	return {"ok": true}


## Notify that an external mutation was observed. Called by DocumentRegistry's
## watcher; emits external_change_detected for UI consumers to react to.
func notify_external_change() -> void:
	external_change_detected.emit()


## Whether the supplied {mtime, size} pair matches the buffer's last in-sync
## snapshot. DocumentRegistry uses this to decide whether a fresh stat counts
## as an external change.
func matches_disk_snapshot(mtime: int, size: int) -> bool:
	return loaded_mtime == mtime and loaded_size == size


## Refresh loaded_mtime / loaded_size from disk. Idempotent. Called at construct,
## save_to_disk, and reload_from_disk — any moment we believe the buffer is
## back in lockstep with disk.
func _snapshot_disk_state() -> void:
	var s := DiskAccess.stat(file_path)
	if s.ok:
		loaded_mtime = int(s.mtime)
		loaded_size = int(s.size)
	else:
		loaded_mtime = 0
		loaded_size = 0
