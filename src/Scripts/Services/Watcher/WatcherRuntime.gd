## WatcherRuntime — autoload Node that drives FileWatcherService and surfaces
## external-change conflicts to the user via the Reload/Keep dialog.
##
## Responsibilities:
##   1. Internal Timer ticks FileWatcherService.tick() at a configurable
##      interval (default 2s). Polling is the only available change-detection
##      strategy in stock Godot — no inotify/FSEvents binding.
##   2. Connects once to DocumentRegistry.external_change_pending and pops
##      the dialog for any buffered path that goes dirty + diverges from disk.
##   3. The dialog is a non-blocking ConfirmationDialog hosted at this Node so
##      it works for any buffer attachment (text editor, plugin render panel,
##      headless MCP-only — all the same path).
extends Node

const POLL_INTERVAL_SEC: float = 2.0

# absolute_path -> ConfirmationDialog (one dialog at a time per buffer; reused
# until the user picks Reload/Keep, then freed and removed from the map).
var _open_dialogs: Dictionary = {}


func _ready() -> void:
	var ticker := Timer.new()
	ticker.wait_time = POLL_INTERVAL_SEC
	ticker.autostart = true
	ticker.one_shot = false
	ticker.timeout.connect(_on_timer_timeout)
	add_child(ticker)

	# Lazy: wire to the registry only once it's referenced. Connecting in _ready
	# ensures the signal is hooked before any document is opened.
	var reg = DocumentRegistry.get_instance()
	if not reg.external_change_pending.is_connected(_on_external_change_pending):
		reg.external_change_pending.connect(_on_external_change_pending)
	if not reg.buffer_disposed.is_connected(_on_buffer_disposed):
		reg.buffer_disposed.connect(_on_buffer_disposed)


func _on_timer_timeout() -> void:
	FileWatcherService.get_instance().tick()


func _on_external_change_pending(path: String) -> void:
	if _open_dialogs.has(path):
		return  # registry already coalesces, but belt-and-suspenders here too
	var dialog := ConfirmationDialog.new()
	dialog.title = "File changed on disk"
	dialog.dialog_text = "%s\n\nThis file was modified outside Minerva while you have unsaved edits. Reload (drop your edits) or Keep your buffer (your next save will overwrite the disk change)?" % path
	dialog.ok_button_text = "Reload"
	dialog.add_cancel_button("Keep Buffer")
	dialog.exclusive = false  # non-blocking modal — DoD bullet 4
	dialog.confirmed.connect(_on_dialog_reload.bind(path))
	dialog.canceled.connect(_on_dialog_keep.bind(path))
	# Auto-cleanup when the dialog is dismissed by either path.
	dialog.tree_exited.connect(_on_dialog_dismissed.bind(path))
	add_child(dialog)
	_open_dialogs[path] = dialog
	dialog.popup_centered()


func _on_dialog_reload(path: String) -> void:
	# Clear the coalescing flag BEFORE reloading so any new external change
	# observed during the reload is allowed to fire a fresh prompt rather
	# than being silently dropped. (Godot signals are sync today, so the
	# window is effectively zero-width — but the order is free defense.)
	var reg = DocumentRegistry.get_instance()
	reg.clear_prompt_open(path)
	if reg.has_buffer(path):
		var r := reg.get_or_create_buffer(path)
		if r.ok:
			(r.buffer as DocumentBuffer).reload_from_disk()


func _on_dialog_keep(path: String) -> void:
	# Keep: leave buffer untouched. Next save_to_disk will overwrite the
	# external change. Just clear the coalescing flag so future external
	# changes can re-prompt.
	DocumentRegistry.get_instance().clear_prompt_open(path)


func _on_dialog_dismissed(path: String) -> void:
	if _open_dialogs.has(path):
		var d = _open_dialogs[path]
		_open_dialogs.erase(path)
		if is_instance_valid(d):
			d.queue_free()


## Force-dismiss any open dialog tied to a path. Called when the underlying
## buffer is disposed — an orphan dialog referencing a freed buffer would be
## a UI inconsistency.
func _on_buffer_disposed(path: String) -> void:
	if not _open_dialogs.has(path):
		return
	var d = _open_dialogs[path]
	_open_dialogs.erase(path)
	if is_instance_valid(d):
		d.hide()
		d.queue_free()
