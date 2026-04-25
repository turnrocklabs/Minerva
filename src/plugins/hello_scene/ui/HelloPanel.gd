class_name Helloscene_HelloPanel
extends Control
## Hello Scene panel — Phase 1B integration-validation plugin (§2.6 MVP scope).
##
## Exercises every plugin-platform surface:
##   - scene contract (request signal, receive method)
##   - lifecycle hooks (_on_panel_loaded, _on_panel_unload,
##     _on_panel_save_request, _on_panel_load_request)
##   - IPC round-trip via $_MinervaIPC.await_reply
##   - content_changed signal for unsaved-flag tracking
##   - on_progress for scene-panel progress routing
##
## class_name prefix "Helloscene" = canonical_prefix("hello_scene")
## per design §6.1: plugin_id.replace("_","").lower() → first-upper.


# ---------------------------------------------------------------------------
# Scene-contract signals (design §4.2)
# ---------------------------------------------------------------------------

## Emitted when the scene wants to call a plugin IPC channel.
## reply_id is a unique string generated per request; broker routes the
## result back via $_MinervaIPC._reply(reply_id, result).
signal request(channel: String, payload: Dictionary, reply_id: String)

## Emitted when the document text changes; drives Editor.is_modified flag
## (design §7.5, host_owned save mode).
signal content_changed()


# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _ctx: Dictionary = {}
var _reply_counter: int = 0

# Node references — set in _ready() after scene tree is available.
var _label: Label = null
var _line_edit: LineEdit = null
var _greet_button: Button = null


# ---------------------------------------------------------------------------
# Godot lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	# Wire up child node refs.  The scene is built in the .tscn file, so nodes
	# are guaranteed to exist by the time _ready() fires.
	_label = $VBoxContainer/Label
	_line_edit = $VBoxContainer/LineEdit
	_greet_button = $VBoxContainer/Button

	# Wire signals.
	_greet_button.pressed.connect(_on_greet_pressed)
	_line_edit.text_changed.connect(_on_text_changed)

	_label.text = "Hello Scene ready. Type something and press Greet."


# ---------------------------------------------------------------------------
# Plugin platform lifecycle hooks (design §5.1)
# ---------------------------------------------------------------------------

## Called after scene is added to tree and broker is wired (design §5.3 step 12).
## ctx shape: {plugin_id, panel_name, data_directory, broker, file_path,
##              associated_object, editor, host_api_version}
func _on_panel_loaded(ctx: Dictionary) -> void:
	_ctx = ctx
	var plugin_id: String = ctx.get("plugin_id", "")
	var panel_name: String = ctx.get("panel_name", "")
	_label.text = ("Hello Scene loaded — plugin: %s, panel: %s") % [plugin_id, panel_name]


## Called before scene is removed / freed (design §5.3 step before queue_free).
## Must NOT initiate new IPC from inside this hook.
func _on_panel_unload() -> void:
	# Disconnect signals to prevent orphan callbacks after free.
	if _greet_button != null and _greet_button.pressed.is_connected(_on_greet_pressed):
		_greet_button.pressed.disconnect(_on_greet_pressed)
	if _line_edit != null and _line_edit.text_changed.is_connected(_on_text_changed):
		_line_edit.text_changed.disconnect(_on_text_changed)


## Called by the host to serialise document state for host_owned save (design §7.5).
## Returns a Dictionary that is written to the .hello file as JSON.
func _on_panel_save_request() -> Dictionary:
	var text: String = ""
	if _line_edit != null:
		text = _line_edit.text
	return {"text": text}


## Called by the host to restore document state after loading a .hello file.
## document is the Dictionary previously returned by _on_panel_save_request.
func _on_panel_load_request(document: Dictionary) -> void:
	var text: String = str(document.get("text", ""))
	if _line_edit != null:
		_line_edit.text = text
	if _label != null:
		_label.text = "Loaded: " + text


# ---------------------------------------------------------------------------
# Scene-contract: inbound push from broker (design §4.2)
# ---------------------------------------------------------------------------

## Called by the broker when the plugin pushes an async message to this panel.
func receive(channel: String, payload: Dictionary) -> void:
	push_warning("[HelloPanel] receive: channel='%s' (unexpected push in this MVP)" % channel)


# ---------------------------------------------------------------------------
# Progress routing (design §7 scene-panel progress)
# ---------------------------------------------------------------------------

## Called by the platform if a progress event is routed to this panel.
## Updates the label with phase/fraction info.
func on_progress(request_id: String, phase: String, fraction: float) -> void:
	if _label != null:
		_label.text = ("Progress [%s] %s: %.0f%%") % [request_id, phase, fraction * 100.0]


# ---------------------------------------------------------------------------
# UI event handlers
# ---------------------------------------------------------------------------

func _on_greet_pressed() -> void:
	if $_MinervaIPC == null:
		_label.text = "Error: $_MinervaIPC not attached (broker not wired?)"
		return

	var message: String = ""
	if _line_edit != null:
		message = _line_edit.text

	# Generate a unique reply_id (simple counter; sufficient for MVP).
	_reply_counter += 1
	var reply_id: String = "hello_greet_%d" % _reply_counter

	# Emit the request signal — broker routes it to the plugin backend.
	request.emit("hello.greet", {"message": message}, reply_id)

	# Await the reply via the MinervaIPC helper node (design §4.2).
	var result: Dictionary = await $_MinervaIPC.await_reply(reply_id)

	if result.get("success", false):
		# result.result is the payload dict from the server.
		var payload: Dictionary = result.get("result", {})
		var text_content: String = payload.get("text", "(no text in response)")
		if _label != null:
			_label.text = text_content
	else:
		var err: String = result.get("error_message", "unknown error")
		if _label != null:
			_label.text = "Greet failed: " + err


func _on_text_changed(new_text: String) -> void:
	# Fire content_changed so the Editor wrapper flips is_modified (design §7.5).
	content_changed.emit()
