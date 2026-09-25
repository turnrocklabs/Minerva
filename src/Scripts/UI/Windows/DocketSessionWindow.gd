extends Window
## The Docket plugin's session as Minerva keeps it (DocketHost): Docket's
## state and problems, and the projects of the session that did not open,
## each of which a person can open again (Retry), replace by another project
## file (Locate) or leave out of the session (Forget; the file is not
## touched). The master and personal projects are not session entries: a
## master that is not available shows among the problems until it is.

@onready var _status: Label = %Status
@onready var _failed: ItemList = %Failed
@onready var _retry: Button = %Retry
@onready var _locate: Button = %Locate
@onready var _forget: Button = %Forget
@onready var _locate_dialog: FileDialog = %LocateDialog
@onready var _forget_confirm: ConfirmationDialog = %ForgetConfirm

# A change is under way; the buttons wait for it.
var _busy := false
# The entry a Locate or Forget dialog was opened for.
var _chosen := ""
# What the last change did, shown again when Docket's state changes.
var _outcome := ""


func _ready() -> void:
	close_requested.connect(hide)
	visibility_changed.connect(func() -> void:
		if visible:
			refresh())
	var host: DocketHost = SingletonObject.docket_host
	if host != null:
		host.state_changed.connect(func(_state: String) -> void:
			if visible and not _busy:
				refresh(_outcome))
	_failed.item_selected.connect(func(_index: int) -> void: _update_buttons())
	_retry.pressed.connect(_on_retry_pressed)
	_locate.pressed.connect(_on_locate_pressed)
	_locate_dialog.file_selected.connect(_on_located)
	_forget.pressed.connect(_on_forget_pressed)
	_forget_confirm.confirmed.connect(_on_forget_confirmed)


## Shows Docket's state and the session's failed projects, after `outcome`
## (what the last change did) when given.
func refresh(outcome := "") -> void:
	var host: DocketHost = SingletonObject.docket_host
	var lines := PackedStringArray()
	if not outcome.is_empty():
		lines.append(outcome)
	var selected := _selected()
	_failed.clear()
	if host == null or host.state == "inactive":
		lines.append("Docket runs inside Minerva here; there is no plugin session to repair.")
	else:
		lines.append("Docket: %s" % host.state)
		for problem in host.problems:
			lines.append("- %s" % problem)
		for failed in host.failed_projects():
			var index := _failed.add_item(str(failed.path))
			_failed.set_item_metadata(index, str(failed.path))
			_failed.set_item_tooltip(index, str(failed.error))
			if str(failed.path) == selected:
				_failed.select(index)
	_status.text = "\n".join(lines)
	_update_buttons()


func _selected() -> String:
	var selected := _failed.get_selected_items()
	return str(_failed.get_item_metadata(selected[0])) if not selected.is_empty() else ""


func _update_buttons() -> void:
	var none := _busy or _selected().is_empty()
	_retry.disabled = none
	_locate.disabled = none
	_forget.disabled = none


func _on_retry_pressed() -> void:
	var path := _selected()
	if not path.is_empty():
		_finish(path, "opened again", await _change(func() -> String:
			return await SingletonObject.docket_host.retry_project(path)))


func _on_locate_pressed() -> void:
	_chosen = _selected()
	if not _chosen.is_empty():
		_locate_dialog.popup_centered_ratio(0.6)


func _on_located(replacement: String) -> void:
	var path := _chosen
	if not path.is_empty():
		_finish(path, "replaced by %s" % replacement, await _change(func() -> String:
			return await SingletonObject.docket_host.locate_project(path, replacement)))


func _on_forget_pressed() -> void:
	_chosen = _selected()
	if not _chosen.is_empty():
		_forget_confirm.dialog_text = "Leave %s out of Docket's session?\nThe file itself is not deleted." % _chosen
		_forget_confirm.popup_centered()


func _on_forget_confirmed() -> void:
	var path := _chosen
	if not path.is_empty():
		_finish(path, "left out of the session", await _change(func() -> String:
			return await SingletonObject.docket_host.forget_project(path)))


# Runs `change` (a DocketHost change, answering "" or why not) with the
# buttons held.
func _change(change: Callable) -> String:
	_busy = true
	_update_buttons()
	var why: String = await change.call()
	_busy = false
	return why


func _finish(path: String, done: String, why: String) -> void:
	_outcome = "%s: %s" % [path, done] if why.is_empty() else "%s: %s" % [path, why]
	refresh(_outcome)
