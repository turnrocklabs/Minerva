extends Node
## Manager-owned integration for opt-in scene generations. Files/backend
## installation and scene activation remain two explicit durable operations.

const Store := preload("res://Scripts/Services/Plugins/PluginGenerationStore.gd")
const Swap := preload("res://Scripts/Services/Plugins/PluginLiveSwap.gd")
const Host := preload("res://Scripts/Services/Plugins/PluginScenePanelHost.gd")
const Atomic := preload("res://Scripts/Services/Plugins/AtomicFile.gd")
const Cleanup := preload("res://Scripts/Services/Plugins/PluginGenerationCleanup.gd")
const InstallTransaction := preload("res://Scripts/Services/Plugins/PluginInstallTransaction.gd")
var _manager: Object
var _broker: PluginScenePanelBroker
var _notify: Callable
var _machines: Dictionary = {}
var _status: Dictionary = {}
# Session boundary: diagnostics can change; only a new service clears this.
var _restart_pending: Dictionary = {}


func configure(manager: Object, broker: PluginScenePanelBroker, notify: Callable) -> void:
	_manager = manager
	_broker = broker
	_notify = notify


func supports(plugin_id: String) -> bool:
	var definition: PluginDefinition = _definition(plugin_id)
	return _machines.has(plugin_id) or (definition != null and "live_reload" in definition.capabilities)


func _definition(plugin_id: String) -> PluginDefinition:
	var db: RefCounted = _manager.call("get_db")
	return db.call("get_by_id", plugin_id)


func _capture_installed(plugin_id: String, machine: PluginLiveSwap) -> Dictionary:
	var source := ProjectSettings.globalize_path(_definition(plugin_id).data_directory)
	if source != source.simplify_path() or Store._has_link(source):
		return {"ok": false, "error": "Plugin source path must be canonical and contain no symlinks"}
	return machine.store.capture(source)


func _pending_path(machine: PluginLiveSwap) -> String:
	var path := machine.store.directory.path_join("pending-install.json")
	return "" if Store._has_link(path) or Store._has_link(path + ".tmp") else path


func status(plugin_id: String) -> Dictionary:
	var current: Dictionary = _status.get(plugin_id, {})
	return current.duplicate(true)


func _result(plugin_id: String, reply: Dictionary, installed: bool = false) -> Dictionary:
	var message := str(reply.get("message", "Live reload complete" if reply.get("ok", false) else str(reply.get("error", "Live reload refused"))))
	if installed and not reply.get("ok", false):
		message = "Update installed; live reload refused: " + message
		var previous: Dictionary = _status.get(plugin_id, {})
		if not previous.get("restart_pending", false):
			push_warning("[PluginLiveReload] Backend/panel version mismatch: " + message)
	if reply.get("restart_pending", false) or (installed and not reply.get("ok", false)):
		_restart_pending[plugin_id] = true
	_status[plugin_id] = {"ok": reply.get("ok", false), "message": message,
		"restart_pending": _restart_pending.has(plugin_id)}
	if not reply.get("ok", false):
		push_warning("[PluginLiveReload] " + message)
		if _notify.is_valid():
			_notify.call(message)
	_manager.emit_signal("plugin_status_changed", plugin_id)
	reply["message"] = message
	return reply


func _machine(plugin_id: String) -> PluginLiveSwap:
	if not _machines.has(plugin_id):
		var machine := Swap.new()
		machine.configure(Store.new(plugin_id))
		add_child(machine)
		_machines[plugin_id] = machine
	return _machines[plugin_id]


func _panel_definitions(build: Dictionary) -> Dictionary:
	var files: Dictionary = build.get("files", {})
	if not files.has("manifest.json"):
		return {"ok": false, "error": "No valid archive-local scene panels"}
	var bytes: PackedByteArray = files["manifest.json"]
	var manifest: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not manifest is Dictionary:
		return {"ok": false, "error": "No valid archive-local scene panels"}
	var manifest_dict: Dictionary = manifest
	var parsed := PluginDefinition.from_dict(manifest_dict)
	if parsed == null:
		return {"ok": false, "error": "No valid archive-local scene panels"}
	var result: Array[Dictionary] = []
	var seen_names: Dictionary = {}
	for panel: Dictionary in parsed.ui_panels:
		var panel_name := str(panel.get("name", ""))
		if panel_name.is_empty():
			return {"ok": false, "error": "Panel name is empty"}
		if seen_names.has(panel_name):
			return {"ok": false, "error": "Duplicate panel name: " + panel_name}
		seen_names[panel_name] = true
		if panel.get("kind") != "godot_scene":
			continue
		var scene := str(panel.get("entry_scene", ""))
		if not Store.safe_relative(scene) or not files.has(scene) or not panel.get("scripts") is Array:
			return {"ok": false, "error": "No valid archive-local scene panels"}
		for script: Variant in panel.scripts:
			if not script is String:
				return {"ok": false, "error": "No valid archive-local scene panels"}
			if not Store.safe_relative(str(script)) or not files.has(script):
				return {"ok": false, "error": "No valid archive-local scene panels"}
		result.append(panel)
	return {"ok": true, "panels": result}


func _validate(build: Dictionary, machine: PluginLiveSwap, slot: String = "A") -> Dictionary:
	var logger := Swap.PrepareLogger.new()
	OS.add_logger(logger)
	var reply := machine.compile_build(build, slot)
	if reply.get("ok", false):
		reply = _validate_prepared(slot, build, machine, PackedStringArray())
	OS.remove_logger(logger)
	if reply.get("ok", false) and not logger.snapshot().is_empty():
		return {"ok": false, "error": "Generation validation reported errors"}
	return reply


func _validate_prepared(slot: String, build: Dictionary, machine: PluginLiveSwap, open_names: PackedStringArray) -> Dictionary:
	var parsed := _panel_definitions(build)
	if not parsed.get("ok", false):
		return parsed
	var definitions: Array[Dictionary] = parsed.panels
	if definitions.is_empty():
		return {"ok": false, "error": "No valid archive-local scene panels"}
	for definition: Dictionary in definitions:
		if str(definition.name) in open_names:
			continue
		var reply := _probe_panel(definition, machine, slot)
		if not reply.get("ok", false):
			return reply
	return {"ok": true}


func _probe_panel(definition: Dictionary, machine: PluginLiveSwap, slot: String) -> Dictionary:
	var logger := Swap.PrepareLogger.new()
	OS.add_logger(logger)
	var reply := _probe_control(definition, machine, slot)
	OS.remove_logger(logger)
	var errors := logger.snapshot()
	if not errors.is_empty():
		reply = {"ok": false, "error": str(reply.get("error", "Validation reported errors")) + "; " + JSON.stringify(errors)}
	if not reply.get("ok", false):
		reply.error = "Panel '%s': %s" % [definition.name, reply.get("error", "Validation refused")]
	return reply


func _probe_control(definition: Dictionary, machine: PluginLiveSwap, slot: String) -> Dictionary:
	var path := machine.store.slot_path(slot).path_join(str(definition.entry_scene))
	var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var allowed := PackedStringArray()
	for script: String in definition.scripts:
		allowed.append(machine.store.slot_path(slot).path_join(script))
	if packed == null or not Host._audit_packed_scene(packed, allowed):
		return {"ok": false, "error": "Scene failed validation"}
	var probe := packed.instantiate()
	if not probe is Control:
		if probe != null:
			probe.free()
		return {"ok": false, "error": "Panel root is not a Control"}
	var panel: Control = probe
	panel.visible = false
	add_child(panel)
	# Boot and unopened-panel probes use private keys and no real manager,
	# buffer or editor authority. Their loaded/unload lifecycle must balance.
	var probe_broker := PluginScenePanelBroker.new(null, _broker.plugin_policy, _broker.capability_broker)
	var plugin_id := machine.store.directory.get_file()
	var panel_name := str(definition.name)
	var probe_key := "generation-probe:%d" % panel.get_instance_id()
	var channels: Array = definition.get("ipc_channels", [])
	probe_broker.register_panel(panel, plugin_id, probe_key, PackedStringArray(channels), panel_name)
	if panel.has_method("_on_panel_loaded"):
		panel.call("_on_panel_loaded", Host._build_ctx(plugin_id, panel_name,
			_definition(plugin_id).data_directory, probe_broker, null, probe_key))
	var valid := is_instance_valid(panel) and Host.invoke_self_check(panel)
	if is_instance_valid(panel):
		Host.invoke_unload(panel)
	probe_broker.unregister_panel(plugin_id, probe_key)
	if is_instance_valid(panel):
		panel.free()
	return {"ok": true} if valid else {"ok": false, "error": "Self-check refused"}


func initialize(plugin_id: String) -> Dictionary:
	return _ensure_current(plugin_id, _machine(plugin_id))


func _ensure_current(plugin_id: String, machine: PluginLiveSwap) -> Dictionary:
	if machine.busy:
		return {"ok": false, "error": "Live reload is already preparing"}
	if machine.record.is_empty():
		if _install_pending(plugin_id) and not FileAccess.file_exists(machine.store.selector_path()):
			return _result(plugin_id, {"ok": false, "error": "Scene initialization waits for the installed backend to commit"})
		var recovered := machine.store.recover(_validate.bind(machine))
		if not recovered.get("ok", false):
			if FileAccess.file_exists(machine.store.selector_path()) \
				or FileAccess.file_exists(machine.store.directory.path_join("recovery.json")):
				return _result(plugin_id, recovered)
			var initial := _capture_installed(plugin_id, machine)
			if not initial.get("ok", false):
				return _result(plugin_id, initial)
			var archived := machine.store.archive(initial)
			if not archived.get("ok", false):
				return _result(plugin_id, archived)
			var validated := _validate(initial, machine)
			if not validated.get("ok", false):
				return _result(plugin_id, validated)
			var selector := machine.store.prepare_selector(str(initial.digest), {})
			if not selector.get("ok", false) or not machine.store.publish_selector().get("ok", false):
				return _result(plugin_id, {"ok": false, "error": machine.store.error_message()})
			machine.record = selector.record
		else:
			machine.record = recovered.record
		machine.active_slot = "A"
		_boot_pending(plugin_id, machine)
	return {"ok": true}


func resolve(plugin_id: String, panel_name: String) -> Dictionary:
	var machine := _machine(plugin_id)
	var initialized := _ensure_current(plugin_id, machine)
	if not initialized.get("ok", false):
		return initialized
	var build := machine.store.read_archive(str(machine.record.active))
	if not build.get("ok", false):
		return _result(plugin_id, build)
	var parsed := _panel_definitions(build)
	if not parsed.get("ok", false):
		return _result(plugin_id, parsed)
	for definition: Dictionary in parsed.panels:
		if definition.get("name", "") == panel_name:
			return {"ok": true, "directory": machine.store.slot_path(machine.active_slot), "panel": definition}
	return _result(plugin_id, {"ok": false, "error": "Panel absent from selected build: " + panel_name})


func reload(plugin_id: String, supplied: Dictionary = {}, installed: bool = false) -> Dictionary:
	if not supports(plugin_id):
		return {"ok": false, "error": "Plugin has not opted into live reload"}
	var machine := _machine(plugin_id)
	if reload_blocked(plugin_id):
		return _reload_refusal(plugin_id)
	var current_status: Dictionary = _status.get(plugin_id, {})
	var pending: bool = current_status.get("restart_pending", false)
	installed = installed or pending
	if machine.busy:
		return _result(plugin_id, {"ok": false, "error": "Live reload is already preparing"}, installed)
	var initialized := _ensure_current(plugin_id, machine)
	if not initialized.get("ok", false):
		return _result(plugin_id, initialized, installed)
	var build := supplied if not supplied.is_empty() else _capture_installed(plugin_id, machine)
	if not build.get("ok", false):
		return _result(plugin_id, build, installed)
	# Re-publishing identical bytes would replace the distinct LKG with itself.
	if str(build.digest) == str(machine.record.active):
		return _result(plugin_id, {"ok": true, "digest": build.digest, "message": "Scene sources unchanged"})
	var parsed := _panel_definitions(build)
	if not parsed.get("ok", false):
		return _result(plugin_id, parsed, installed)
	var definitions: Array[Dictionary] = parsed.panels
	var old_definitions: Array[Dictionary] = []
	if not machine.record.is_empty():
		var old_parsed := _panel_definitions(machine.store.read_archive(str(machine.record.active)))
		if not old_parsed.get("ok", false):
			return _result(plugin_id, old_parsed, installed)
		old_definitions = old_parsed.panels
	var entries: Array[Dictionary] = []
	for original: Dictionary in _manager.call("get_live_panels", plugin_id):
		if not is_instance_valid(original.root):
			continue
		var old: Control = original.root
		if not old.get_meta("_minerva_plugin_panel_load_ok", false):
			continue
		var entry: Dictionary = original.duplicate()
		entry["plugin_id"] = plugin_id
		entry["vbox"] = old.get_parent()
		entry["buffer"] = _broker.get_attached_buffer(plugin_id, str(entry.panel_key)) if _broker != null else null
		var selected: Dictionary = {}
		for definition: Dictionary in definitions:
			if definition.get("name", "") == entry.panel_name:
				selected = definition
		if selected.is_empty():
			return _result(plugin_id, {"ok": false, "error": "Updated build omits an open panel"}, installed)
		var editor: Object = entry.editor
		if is_instance_valid(editor) and editor.has_method("accepts_scene_panel_definition") \
			and not editor.call("accepts_scene_panel_definition", selected):
			return _result(plugin_id, {"ok": false, "error": "Restart to update: open panel save or chrome policy changed"}, installed)
		entry["panel_definition"] = selected
		entry["old_panel_definition"] = selected
		for old_definition: Dictionary in old_definitions:
			if old_definition.get("name", "") == entry.panel_name:
				entry.old_panel_definition = old_definition
		entries.append(entry)
	var open_names := PackedStringArray()
	for entry: Dictionary in entries:
		open_names.append(str(entry.panel_name))
	var validator := _validate_prepared.bind(build, machine, open_names)
	var reply := await machine.swap(build, entries, _wire, _retire, validator)
	if reply.get("ok", false):
		var pending_path := _pending_path(machine)
		if pending_path.is_empty() or not Atomic.write(pending_path, "{}"):
			reply["message"] = "Live reload complete; pending-update metadata could not be cleared"
			push_warning("[PluginLiveReload] " + str(reply.message))
	if reply.get("ok", false):
		var cleaned := _cleanup(machine)
		if not cleaned.get("ok", false):
			reply["message"] = "Live reload complete; " + str(cleaned.error)
			push_warning("[PluginLiveReload] " + str(reply.message))
	return _result(plugin_id, reply, installed)


func revert(plugin_id: String) -> Dictionary:
	if reload_blocked(plugin_id):
		return _reload_refusal(plugin_id)
	if not supports(plugin_id):
		return _result(plugin_id, {"ok": false, "error": "Plugin has not opted into live reload"})
	var machine := _machine(plugin_id)
	var initialized := _ensure_current(plugin_id, machine)
	if not initialized.get("ok", false):
		return _result(plugin_id, initialized)
	var previous := str(machine.record.get("lkg", ""))
	if previous.is_empty():
		return _result(plugin_id, {"ok": false, "error": "No retained previous scene version"})
	var build := machine.store.read_archive(previous)
	if not build.get("ok", false):
		return _result(plugin_id, build)
	var reply := await reload(plugin_id, build)
	if reply.get("ok", false):
		reply["message"] = "Previous scene version restored"
		return _result(plugin_id, reply)
	return reply


func _cleanup(machine: PluginLiveSwap) -> Dictionary:
	var pending_digest := ""
	var path := _pending_path(machine)
	if path.is_empty():
		return {"ok": false, "error": "Generation cleanup refused linked pending metadata"}
	if FileAccess.file_exists(path):
		var pending: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if pending is Dictionary:
			var pending_record: Dictionary = pending
			pending_digest = str(pending_record.get("digest", ""))
	return Cleanup.collect(machine.store, machine.record, pending_digest)


func _wire(entry: Dictionary, panel: Control, first_load: bool) -> bool:
	if _broker == null:
		return false
	var definition: Dictionary = entry.panel_definition if first_load else entry.old_panel_definition
	var plugin_id: String = entry.plugin_id
	var panel_key: String = entry.panel_key
	var panel_name: String = entry.panel_name
	var buffer: DocumentBuffer = entry.buffer
	var channels: Array = definition.get("ipc_channels", [])
	var editor: Object = entry.editor
	if first_load and _broker.get_attached_buffer(plugin_id, panel_key) != buffer:
		# Refuse this snapshot, retaining the CURRENT attachment for rollback.
		entry.buffer = _broker.get_attached_buffer(plugin_id, panel_key)
		return false
	_broker.register_panel(panel, plugin_id, panel_key, PackedStringArray(channels), panel_name, editor)
	if buffer != null and not _broker.attach_buffer_to_panel(plugin_id, panel_key, buffer):
		return false
	if is_instance_valid(editor):
		var old: Control = entry.root
		old.set_meta("_minerva_actions_editor", weakref(editor))
		panel.set_meta("_minerva_actions_editor", weakref(editor))
		var changed := Callable(editor, "_on_editor_changed")
		if panel.has_signal("content_changed") and not panel.is_connected("content_changed", changed):
			panel.connect("content_changed", changed)
		editor.call("remount_plugin_surface", panel)
	_manager.call("repoint_live_panel", entry.plugin_id, entry.panel_key, panel)
	entry.root = panel
	panel.set_meta("_minerva_plugin_panel_load_ok", true)
	if first_load and panel.has_method("_on_panel_loaded"):
		panel.call("_on_panel_loaded", Host._build_ctx(plugin_id, panel_name,
			_definition(plugin_id).data_directory, _broker, editor, panel_key))
	if is_instance_valid(editor):
		editor.call("refresh_plugin_surface_actions")
	return _broker.is_panel_registered(panel_key, plugin_id)


func _retire(panel: Control) -> void:
	if panel.get_meta("_minerva_plugin_panel_load_ok", false):
		Host.invoke_unload(panel)
	if not panel.has_meta("_minerva_actions_editor"):
		return
	var owner_ref: WeakRef = panel.get_meta("_minerva_actions_editor")
	var editor: Object = owner_ref.get_ref() if owner_ref != null else null
	if is_instance_valid(editor):
		editor.call("discard_plugin_surface_actions", panel)


func can_replace(plugin_id: String) -> Dictionary:
	var machine := _machine(plugin_id)
	if machine.busy:
		return {"error": "reload_in_progress", "message": "Wait for live reload to finish"}
	# Retain the previous immutable generation before installed files move.
	var initialized := _ensure_current(plugin_id, machine)
	return {"ok": true} if initialized.get("ok", false) else {"error": "generation_unavailable", "message": initialized.get("message", initialized.get("error", "Scene unavailable"))}


func _install_pending(plugin_id: String) -> bool:
	var staging_root := ProjectSettings.globalize_path(MarketplaceClient.STAGING_DIR)
	return InstallTransaction.pending_for(staging_root, plugin_id) != null \
		or InstallTransaction.has_unfinished(staging_root, plugin_id)


func has_generation(plugin_id: String) -> bool:
	return _machines.has(plugin_id)


func _reload_refusal(plugin_id: String) -> Dictionary:
	var pending := _restart_pending.has(plugin_id)
	return _result(plugin_id, {"ok": false, "restart_pending": pending,
		"message": "Update installed; restart to load the new panels" if pending else "Scene reload waits for the installed backend to commit"})


func reload_blocked(plugin_id: String) -> bool:
	return _install_pending(plugin_id) or _restart_pending.has(plugin_id)


## Called after installation commits. Never activate scenes in this session:
## retain the installed identity for validation after the application restarts.
func installed_update(plugin_id: String) -> Dictionary:
	var machine := _machine(plugin_id)
	var build := _capture_installed(plugin_id, machine)
	var reply := {"ok": true, "restart_pending": true,
		"message": "Update installed; restart to load the new panels"}
	if not build.get("ok", false) or not machine.store.archive(build).get("ok", false):
		reply["ok"] = false
		reply.message += "; installed scene archive could not be retained"
	else:
		var pending_path := _pending_path(machine)
		if pending_path.is_empty() or not Atomic.write(pending_path, JSON.stringify({"digest": build.digest})):
			reply["ok"] = false
			reply.message += "; installed identity could not be retained"
	return _result(plugin_id, reply)


func _boot_pending(plugin_id: String, machine: PluginLiveSwap) -> void:
	if _restart_pending.has(plugin_id):
		return
	if _install_pending(plugin_id):
		_result(plugin_id, {"ok": false, "message": "Installed backend awaits its first successful start; using the previous scene"})
		return
	var path := _pending_path(machine)
	if path.is_empty():
		_boot_refused(plugin_id, machine, "Pending-update symlink refused", "metadata access")
		return
	if not FileAccess.file_exists(path):
		return
	var pending: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not pending is Dictionary:
		return
	var pending_record: Dictionary = pending
	if not Store.valid_digest(str(pending_record.get("digest", ""))):
		return
	var installed := _capture_installed(plugin_id, machine)
	if not installed.get("ok", false) or installed.digest != pending.digest:
		return # The install did not commit, or a later install superseded it.
	if machine.record.active == pending.digest:
		return
	var archive := machine.store.read_archive(str(pending.digest))
	var checked := _validate(archive, machine, "B") if archive.get("ok", false) else archive
	if not checked.get("ok", false):
		_boot_refused(plugin_id, machine, str(checked.get("error", "Boot validation refused")))
		return
	var selector := machine.store.prepare_selector(str(archive.digest), machine.record)
	if selector.get("ok", false) and machine.store.publish_selector().get("ok", false):
		machine.record = selector.record
		machine.active_slot = "B"
	else:
		_boot_refused(plugin_id, machine, machine.store.error_message(), "selector publication")


func _boot_refused(plugin_id: String, machine: PluginLiveSwap, reason: String, stage: String = "validation") -> void:
	# A restart already happened. Retain the selected build and allow repair
	# through Reload, rather than asking for an endless sequence of restarts.
	var path := _pending_path(machine)
	if path.is_empty() or not Atomic.write(path, "{}"):
		reason += "; pending identity could not be cleared"
	_result(plugin_id, {"ok": false, "message": "Installed update failed " + stage + "; using the previous version: " + reason})


## Hash opt-in source content recursively; nested scripts and same-second
## writes must trigger the same generation transaction as explicit reload.
func scan_files(plugin_id: String, extensions: PackedStringArray) -> Dictionary:
	var source := ProjectSettings.globalize_path(_definition(plugin_id).data_directory)
	if source != source.simplify_path() or Store._has_link(source):
		return {}
	return _scan_tree(source, extensions)


func _scan_tree(directory: String, extensions: PackedStringArray) -> Dictionary:
	var result: Dictionary = {}
	var dir := DirAccess.open(directory)
	if dir == null:
		return result
	for child: String in dir.get_directories():
		if not child.begins_with(".") and not dir.is_link(child):
			result.merge(_scan_tree(directory.path_join(child), extensions))
	for child: String in dir.get_files():
		if child.begins_with(".") or dir.is_link(child):
			continue
		if child.get_extension() in extensions or child.ends_with(".tres"):
			var path := directory.path_join(child)
			result[path] = FileAccess.get_sha256(path)
	return result
