class_name Testpaireddsl_Panel
extends Control
## Stub paired_dsl render panel — echoes the attached DocumentBuffer's text
## into a Label. The whole point of this plugin is to exercise the broker's
## attach_buffer / text_changed / detach_buffer push channel, not to render
## a real DSL.

signal request(channel: String, payload: Dictionary, reply_id: String)

var _label: Label = null
var _path_label: Label = null
var _fs_changed_label: Label = null
var _attached_path: String = ""
## Path currently registered with host.fs.watch. Tracked so detach can unwatch.
var _fs_watched_path: String = ""
## Last text_changed version we have an eval "in flight" for. Cleared after
## we cancel via the cancel_eval IPC channel; lets us prove the broker round-
## trip end-to-end during HITL.
var _last_eval_version: int = -1
## Buffered attach payload when the broker fires before our scene runs _ready.
## PluginScenePanelHost.register_panel runs synchronously in Step 10 (before
## _ready), and the dispatcher attaches immediately after — so the very first
## attach_buffer push can arrive before $Vbox exists. Stash it and apply once
## _ready resolves the node refs.
var _pending_payload: Dictionary = {}
var _pending_channel: String = ""


func _ready() -> void:
	_label = $Vbox/EchoLabel
	_path_label = $Vbox/PathLabel
	_fs_changed_label = $Vbox/FsChangedLabel
	if not _pending_channel.is_empty():
		_apply(_pending_channel, _pending_payload)
		_pending_channel = ""
		_pending_payload = {}
	else:
		_label.text = "(no buffer attached)"
		_path_label.text = ""


## Broker delivers attach_buffer / text_changed / detach_buffer here.
## These are platform-reserved channels; they bypass the normal
## ipc_channels allowlist.
func receive(channel: String, payload: Dictionary) -> void:
	# Buffer pre-_ready arrivals so the synchronous initial attach_buffer push
	# from the broker doesn't null-deref on $Vbox.
	if _label == null or _path_label == null:
		_pending_channel = channel
		_pending_payload = payload.duplicate(true)
		return
	_apply(channel, payload)


func _apply(channel: String, payload: Dictionary) -> void:
	match channel:
		"attach_buffer":
			_attached_path = str(payload.get("path", ""))
			_path_label.text = "path: %s  (v%d)" % [
				_attached_path, int(payload.get("version", 0))
			]
			_label.text = str(payload.get("text", ""))
			# T7.5 HITL: subscribe to host.fs.* notifications for the buffer's
			# own path. The buffer-canonical pipeline already reflects external
			# edits as text_changed; the additional host.fs.changed proves the
			# plugin-facing watcher channel works end-to-end. Plugins watching
			# unrelated paths (e.g. sidecar configs) use the same mechanism.
			if not _attached_path.is_empty():
				if not _fs_watched_path.is_empty() and _fs_watched_path != _attached_path:
					request.emit("host.fs.unwatch", {"path": _fs_watched_path}, "")
				_fs_watched_path = _attached_path
				request.emit("host.fs.watch", {"path": _attached_path}, "")
		"text_changed":
			# A previous eval (if any) is now stale — cancel it via IPC so the
			# substrate's cancel_eval round-trip is exercised during HITL.
			if _last_eval_version >= 0:
				request.emit("test_paired_dsl.cancel_eval", {
					"request_id": "ver-%d" % _last_eval_version,
				}, "")
			_last_eval_version = int(payload.get("version", 0))
			_path_label.text = "path: %s  (v%d)" % [
				_attached_path, _last_eval_version
			]
			_label.text = str(payload.get("text", ""))
		"detach_buffer":
			if not _fs_watched_path.is_empty():
				request.emit("host.fs.unwatch", {"path": _fs_watched_path}, "")
				_fs_watched_path = ""
			_attached_path = ""
			_last_eval_version = -1
			_path_label.text = ""
			_label.text = "(buffer detached)"
			if _fs_changed_label != null:
				_fs_changed_label.text = "host.fs.changed: (none yet)"
		"host.fs.changed":
			if _fs_changed_label != null:
				_fs_changed_label.text = "host.fs.changed: %s  mtime=%d size=%d" % [
					str(payload.get("path", "")),
					int(payload.get("mtime", 0)),
					int(payload.get("size", 0)),
				]
