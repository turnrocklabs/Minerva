extends VBoxContainer
class_name HostedVaultPanel
## Master-only session credentials. This scene never reads password preferences.
@onready var _password: LineEdit = %leVaultPassword
@onready var _confirm: LineEdit = %leVaultConfirm
@onready var _hint: LineEdit = %leVaultHint
@onready var _button: Button = %SetVaultPasswordButton
@onready var _message: Label = %VaultMessageLabel
var _host: Node
var _mode := "unavailable"
var _busy := false
var _view_epoch := 0


func _ready() -> void:
	_button.pressed.connect(_submit)
	get_window().visibility_changed.connect(_window_visibility_changed)


func bind_host(host: Node) -> void:
	if _host == host: return
	if is_instance_valid(_host) and _host.vault_changed.is_connected(refresh):
		_host.vault_changed.disconnect(refresh)
	_host = host
	if is_instance_valid(_host): _host.vault_changed.connect(refresh)
	clear_inputs()


func clear_inputs() -> void:
	_view_epoch += 1
	_password.clear()
	_confirm.clear()
	_hint.clear()


func _window_visibility_changed() -> void:
	if not get_window().visible: clear_inputs()


func refresh() -> void:
	_view_epoch += 1
	var epoch := _view_epoch
	var host := _host
	var details: Dictionary = await host.vault_details() if is_instance_valid(host) else {"mode":"unavailable", "message":"Vault: unavailable."}
	if not is_instance_valid(self) or epoch != _view_epoch or host != _host: return
	var mode := str(details.get("mode", "unavailable"))
	# Ambient status changes preserve unfinished input; a mode/host change does not.
	if mode != _mode: clear_inputs()
	_mode = mode
	%VaultStatusLabel.text = str(details.get("message", "Vault: unavailable."))
	_confirm.get_parent().visible = mode == "create"
	_hint.get_parent().visible = mode == "create"
	_button.text = "Create Vault" if mode == "create" else "Unlock for Session"
	_button.disabled = _busy or bool(details.get("busy", false)) or mode == "unavailable"
	_password.editable = not _button.disabled
	_confirm.editable = not _button.disabled and mode == "create"
	_hint.editable = not _button.disabled and mode == "create"
	if mode == "unlock" and not str(details.get("hint", "")).is_empty():
		%VaultStatusLabel.text += "\nHint (plain text): " + str(details.hint)


func _submit() -> void:
	if _busy or _mode == "unavailable": return
	var password := _password.text
	var confirmation := _confirm.text
	var hint := _hint.text
	var creating := _mode == "create"
	clear_inputs()
	if password.is_empty():
		_message.text = "Enter a nonempty password."
		return
	if creating and password != confirmation:
		_message.text = "Passwords do not match."
		return
	confirmation = ""
	_busy = true
	_button.disabled = true
	_password.editable = false
	_confirm.editable = false
	_hint.editable = false
	var host := _host
	var result := "Vault: unavailable."
	if is_instance_valid(host):
		result = await host.create_vault(password, hint) if creating else await host.unlock_vault(password)
	password = ""
	hint = ""
	if not is_instance_valid(self): return
	_busy = false
	refresh()
	_message.text = result
