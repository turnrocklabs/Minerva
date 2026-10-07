extends RefCounted
## One existing master vault's successful password, held only for this host session.
## Dropping String references is explicit; Godot does not guarantee zeroization.
var _password := ""
var _credential := {}
var _epoch := 0
var _busy := false
var _resume_pending := false
var _unlocked := {}
var message := "Vault: locked — unlock an existing vault for this session only."


func lost(host: Node, exiting: bool = false) -> void:
	_epoch += 1
	_busy = false
	_resume_pending = false
	_unlocked = {}
	if exiting:
		_password = ""
		_credential = {}
	message = "Vault: unavailable (session password retained)." if not _password.is_empty() else "Vault: unavailable."
	host.vault_changed.emit()


func status(host: Node) -> String:
	observe(host)
	return message


func observe(host: Node) -> void:
	if not _credential.is_empty() and _credential.path != host.master_path:
		_password = ""
		_credential = {}
	if not _unlocked.is_empty() and host._vault_identity() != _unlocked:
		_unlocked = {}
		message = "Vault: locked (session password retained)."
		host.vault_changed.emit()
		resume.call_deferred(host)


func resume(host: Node) -> void:
	if _password.is_empty() or not _unlocked.is_empty():
		return
	if _busy:
		_resume_pending = true
		return
	if not host._vault_binding().is_empty():
		await _operate(host, _password, false, "", true)


func _current(host: Node, binding: Dictionary, epoch: int) -> bool:
	return is_instance_valid(host) and epoch == _epoch and not binding.is_empty() \
		and host._vault_binding() == binding


func _descriptor(answer: Dictionary) -> Dictionary:
	var result = answer.get("result")
	if answer.has("error") or answer.has("error_code") or not result is Dictionary:
		return {}
	for field in ["path", "open_generation", "fingerprint"]:
		if not result.get(field) is String or result[field].is_empty():
			return {}
	if not result.get("initialized", true) is bool or not result.get("hint", "") is String: return {}
	return {"path": result.path, "open_generation": result.open_generation, "fingerprint": result.fingerprint,
		"initialized":result.get("initialized", true), "hint":result.get("hint", "")}


func details(host: Node) -> Dictionary:
	observe(host)
	var unavailable := {"mode":"unavailable", "message":message, "hint":"", "busy":_busy}
	var binding: Dictionary = host._vault_binding()
	if _busy or binding.is_empty(): return unavailable
	var epoch := _epoch
	var authority = host._plugin_manager.get_panel_authority(host.PLUGIN_ID)
	if authority == null: return unavailable
	var listed: String = await host._refresh(binding.process[0], binding.process[1])
	if not _current(host, binding, epoch) or not listed.is_empty(): return unavailable
	var answer: Dictionary = await authority.host_request("vault_challenge", {"path":host.master_path})
	if not _current(host, binding, epoch): return unavailable
	var descriptor := _descriptor(answer)
	if descriptor.is_empty() or descriptor.path != host.master_path or descriptor.open_generation != host.master_project().get("open_generation", ""): return unavailable
	return {"mode":"unlock" if descriptor.initialized else "create", "hint":descriptor.hint,
		"message":message if descriptor.initialized else "Vault: not created.", "busy":false}


func _finish(host: Node, epoch: int, text: String, invalidated: bool = false) -> String:
	if epoch != _epoch:
		return text if text.begins_with("Vault creation outcome") else "Vault request expired; try again."
	_busy = false
	var retry := invalidated and _resume_pending
	_resume_pending = false
	message = text
	host.vault_changed.emit()
	if retry:
		resume.call_deferred(host)
	return text


func unlock(host: Node, password: String) -> String:
	return await _operate(host, password)


func create(host: Node, password: String, hint: String) -> String:
	return await _operate(host, password, true, hint)


func _operate(host: Node, password: String, creating: bool = false, hint: String = "", resuming: bool = false) -> String:
	if _busy: return "Vault request already in progress."
	_epoch += 1
	var epoch := _epoch
	_busy = true
	_resume_pending = false
	_unlocked = {}
	if creating:
		_password = ""
		_credential = {}
	message = "Vault: creating master vault…" if creating else "Vault: unlocking existing master for this session…"
	host.vault_changed.emit()
	if password.is_empty() or password.to_utf8_buffer().size() > 1024:
		return _finish(host, epoch, "Vault refused: enter a password of at most 1024 UTF-8 bytes.")
	if creating and (hint.to_utf8_buffer().size() > 1024 or hint.contains(password)):
		return _finish(host, epoch, "Vault refused: use a hint of at most 1024 UTF-8 bytes that does not contain the password.")
	var binding: Dictionary = host._vault_binding()
	if binding.is_empty():
		return _finish(host, epoch, "Vault unavailable; wait for the Docket master to open.")
	var connection = binding.process[0]
	var generation: int = binding.process[1]
	var authority = host._plugin_manager.get_panel_authority(host.PLUGIN_ID)
	if authority == null:
		return _finish(host, epoch, "Vault unavailable: no private host channel.")
	var listed: String = await host._refresh(connection, generation)
	if not _current(host, binding, epoch) or not listed.is_empty():
		return _finish(host, epoch, "Vault request expired; try again.", true)
	var answer: Dictionary = await authority.host_request("vault_challenge", {"path": host.master_path})
	if not _current(host, binding, epoch):
		return _finish(host, epoch, "Vault request expired; try again.", true)
	var descriptor := _descriptor(answer)
	if descriptor.is_empty():
		return _finish(host, epoch, "Vault refused: a readable master vault is required.")
	if resuming and _credential != {"path":descriptor.path, "fingerprint":descriptor.fingerprint}:
		_password = ""
		_credential = {}
		return _finish(host, epoch, "Vault changed; enter its password explicitly.")
	if creating == descriptor.initialized:
		return _finish(host, epoch, "Vault already exists; unlock it." if creating else "Vault is not created; create it first.")
	listed = await host._refresh(connection, generation)
	if not _current(host, binding, epoch) or not listed.is_empty() \
			or descriptor.path != host.master_path or descriptor.open_generation != host.master_project().get("open_generation", ""):
		return _finish(host, epoch, "Vault request expired; try again.", true)
	var params := {"path":descriptor.path, "open_generation":descriptor.open_generation, "fingerprint":descriptor.fingerprint}
	params["password"] = password
	if creating: params["hint"] = hint
	answer = await authority.host_request("vault_init" if creating else "vault_unlock", params)
	params.clear()
	if not _current(host, binding, epoch):
		return _finish(host, epoch, "Vault creation outcome is uncertain; refresh and explicitly unlock." if creating else "Vault request expired; try again.", not creating)
	listed = await host._refresh(connection, generation)
	if not _current(host, binding, epoch) or not listed.is_empty():
		return _finish(host, epoch, "Vault creation outcome is uncertain; refresh and explicitly unlock." if creating else "Vault request expired; try again.", not creating)
	var settled := _descriptor(answer)
	var valid: bool = settled == descriptor if not creating else not settled.is_empty() and settled.initialized and settled.path == descriptor.path and settled.open_generation == descriptor.open_generation and settled.fingerprint != descriptor.fingerprint
	if not valid or answer.get("result", {}).get("unlocked") != true:
		return _finish(host, epoch, "Vault creation did not confirm success; refresh and explicitly unlock." if creating else "Vault unlock refused; check the existing vault password.")
	_password = password
	_credential = {"path":settled.path, "fingerprint":settled.fingerprint}
	_unlocked = host._vault_identity()
	return _finish(host, epoch, "Vault: unlocked for this session only (password kept in memory).")
