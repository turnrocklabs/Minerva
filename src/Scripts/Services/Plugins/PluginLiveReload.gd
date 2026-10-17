extends Node
## Manager-owned integration for opt-in scene generations. Files/backend
## installation and scene activation remain two explicit durable operations.

const Store := preload("res://Scripts/Services/Plugins/PluginGenerationStore.gd")
const Swap := preload("res://Scripts/Services/Plugins/PluginLiveSwap.gd")
const Host := preload("res://Scripts/Services/Plugins/PluginScenePanelHost.gd")
const Atomic := preload("res://Scripts/Services/Plugins/AtomicFile.gd")
var _manager: Object
var _broker: PluginScenePanelBroker
var _notify: Callable
var _machines: Dictionary = {}
var _status: Dictionary = {}
var _staged: Dictionary = {}


func configure(manager: Object, broker: PluginScenePanelBroker, notify: Callable) -> void:
	_manager = manager
	_broker = broker
	_notify = notify


func supports(plugin_id: String) -> bool:
	var definition: PluginDefinition = _definition(plugin_id)
	return definition != null and "live_reload" in definition.capabilities


func _definition(plugin_id: String) -> PluginDefinition:
	var db: RefCounted = _manager.call("get_db")
	return db.call("get_by_id", plugin_id)


func status(plugin_id: String) -> Dictionary:
	return _status.get(plugin_id, {}).duplicate(true)


func _result(plugin_id: String, reply: Dictionary, installed: bool = false) -> Dictionary:
	var message := "Live reload complete" if reply.get("ok", false) else str(reply.get("error", "Live reload refused"))
	if installed and not reply.get("ok", false):
		message = "Update installed; live reload refused: " + message
		if not _status.get(plugin_id, {}).get("restart_pending", false):
			push_warning("[PluginLiveReload] Backend/panel version mismatch: " + message)
	_status[plugin_id] = {"ok": reply.get("ok", false), "message": message,
		"restart_pending": installed and not reply.get("ok", false)}
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


func _panel_definitions(build: Dictionary) -> Array[Dictionary]:
	var files: Dictionary = build.get("files", {})
	if not files.has("manifest.json"):
		return []
	var bytes: PackedByteArray = files["manifest.json"]
	var manifest: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not manifest is Dictionary:
		return []
	var parsed := PluginDefinition.from_dict(manifest)
	if parsed == null:
		return []
	var result: Array[Dictionary] = []
	for panel: Dictionary in parsed.ui_panels:
		if panel.get("kind") != "godot_scene":
			continue
		var scene := str(panel.get("entry_scene", ""))
		if not Store.safe_relative(scene) or not files.has(scene) or not panel.get("scripts") is Array:
			return []
		for script: Variant in panel.scripts:
			if not script is String:
				return []
			if not Store.safe_relative(str(script)) or not files.has(script):
				return []
		result.append(panel)
	return result


func _validate(build: Dictionary, machine: PluginLiveSwap, slot: String = "A") -> Dictionary:
	var definitions := _panel_definitions(build)
	if definitions.is_empty():
		return {"ok": false, "error": "No valid archive-local scene panels"}
	for filename: String in build.files:
		if filename.get_extension() in ["scn", "res"]:
			return {"ok": false, "error": "Live reload requires text scene/resource files"}
	var logger := Swap.PrepareLogger.new()
	OS.add_logger(logger)
	var reply := machine.compile_build(build, slot)
	if reply.get("ok", false):
		for definition: Dictionary in definitions:
			var path := machine.store.slot_path(slot).path_join(str(definition.entry_scene))
			var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
			var allowed := PackedStringArray()
			for script: String in definition.scripts:
				allowed.append(machine.store.slot_path(slot).path_join(script))
			if packed == null or not Host._audit_packed_scene(packed, allowed):
				reply = {"ok": false, "error": "Boot scene failed validation"}
				break
			var probe := packed.instantiate()
			if not probe is Control:
				if probe != null:
					probe.free()
				reply = {"ok": false, "error": "Boot panel root is not a Control"}
				break
			var panel: Control = probe
			panel.visible = false
			add_child(panel)
			var valid := Host.invoke_self_check(panel)
			valid = valid and is_instance_valid(panel)
			if is_instance_valid(panel):
				panel.free()
			if not valid:
				reply = {"ok": false, "error": "Boot self-check refused"}
				break
	OS.remove_logger(logger)
	if not logger.snapshot().is_empty():
		return {"ok": false, "error": "Boot validation reported errors"}
	return reply


func resolve(plugin_id: String, panel_name: String) -> Dictionary:
	var machine := _machine(plugin_id)
	if machine.busy:
		return {"ok": false, "error": "Live reload is preparing; retry opening this panel"}
	if machine.record.is_empty():
		var recovered := machine.store.recover(_validate.bind(machine))
		if not recovered.get("ok", false):
			if FileAccess.file_exists(machine.store.selector_path()) \
				or FileAccess.file_exists(machine.store.directory.path_join("recovery.json")):
				return _result(plugin_id, recovered)
			var definition := _definition(plugin_id)
			var initial := machine.store.capture(definition.data_directory)
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
	var build := machine.store.read_archive(str(machine.record.active))
	if not build.get("ok", false):
		return _result(plugin_id, build)
	for definition: Dictionary in _panel_definitions(build):
		if definition.get("name", "") == panel_name:
			return {"ok": true, "directory": machine.store.slot_path(machine.active_slot), "panel": definition}
	return _result(plugin_id, {"ok": false, "error": "Panel absent from selected build: " + panel_name})


func reload(plugin_id: String, supplied: Dictionary = {}, installed: bool = false) -> Dictionary:
	if not supports(plugin_id):
		return {"ok": false, "error": "Plugin has not opted into live reload"}
	var machine := _machine(plugin_id)
	installed = installed or bool(_status.get(plugin_id, {}).get("restart_pending", false))
	var build := supplied if not supplied.is_empty() else machine.store.capture(_definition(plugin_id).data_directory)
	if not build.get("ok", false):
		return _result(plugin_id, build, installed)
	var definitions := _panel_definitions(build)
	var entries: Array[Dictionary] = []
	for original: Dictionary in _manager.call("get_live_panels", plugin_id):
		if not is_instance_valid(original.root) or not original.root.get_meta("_minerva_plugin_panel_load_ok", false):
			continue
		var entry: Dictionary = original.duplicate()
		entry["plugin_id"] = plugin_id
		entry["vbox"] = original.root.get_parent()
		entry["buffer"] = _broker.get_attached_buffer(plugin_id, str(entry.panel_key)) if _broker != null else null
		var selected: Dictionary = {}
		for definition: Dictionary in definitions:
			if definition.get("name", "") == entry.panel_name:
				selected = definition
		if selected.is_empty():
			return _result(plugin_id, {"ok": false, "error": "Updated build omits an open panel"}, installed)
		entry["panel_definition"] = selected
		entries.append(entry)
	if entries.is_empty():
		# A closed plugin still validates the entire build before publication.
		var checked := _validate(build, machine, "B" if machine.active_slot == "A" else "A")
		if not checked.get("ok", false):
			return _result(plugin_id, checked, installed)
	var reply := await machine.swap(build, entries, _wire, _retire)
	if reply.get("ok", false):
		Atomic.write(machine.store.directory.path_join("pending-install.json"), "{}")
	return _result(plugin_id, reply, installed)


func _wire(entry: Dictionary, panel: Control, first_load: bool) -> bool:
	if _broker == null:
		return false
	var definition: Dictionary = entry.panel_definition
	_broker.register_panel(panel, entry.plugin_id, entry.panel_key,
		PackedStringArray(definition.get("ipc_channels", [])), entry.panel_name, entry.editor)
	if entry.buffer != null and not _broker.attach_buffer_to_panel(entry.plugin_id, entry.panel_key, entry.buffer):
		return false
	var editor: Object = entry.editor
	if is_instance_valid(editor):
		if panel.has_signal("content_changed") and not panel.is_connected("content_changed", editor._on_editor_changed):
			panel.connect("content_changed", editor._on_editor_changed)
		editor.call("remount_plugin_surface", panel)
	_manager.call("repoint_live_panel", entry.plugin_id, entry.panel_key, panel)
	entry.root = panel
	panel.set_meta("_minerva_plugin_panel_load_ok", true)
	if first_load and panel.has_method("_on_panel_loaded"):
		panel.call("_on_panel_loaded", Host._build_ctx(entry.plugin_id, entry.panel_name,
			_definition(entry.plugin_id).data_directory, _broker, editor, entry.panel_key))
	return _broker.is_panel_registered(entry.panel_key, entry.plugin_id)


func _retire(panel: Control) -> void:
	if panel.get_meta("_minerva_plugin_panel_load_ok", false):
		Host.invoke_unload(panel)


func can_replace(plugin_id: String) -> Dictionary:
	return {"error": "reload_in_progress", "message": "Wait for live reload to finish"} \
		if _machine(plugin_id).busy else {"ok": true}


## Stage before installation changes files. A crash only admits this pending
## archive at boot when the installed source digest matches it exactly.
func stage_update(plugin_id: String, candidate_directory: String) -> Dictionary:
	var source := ProjectSettings.globalize_path(candidate_directory)
	if source != source.simplify_path() or Store._has_link(source):
		return {"ok": false, "error": "Update staging path must be canonical and contain no symlinks"}
	var machine := _machine(plugin_id)
	if machine.busy:
		return {"ok": false, "error": "Live reload is already preparing"}
	var build := machine.store.capture(source)
	if not build.get("ok", false) or _panel_definitions(build).is_empty():
		return {"ok": false, "error": str(build.get("error", "Invalid staged scene manifest"))}
	var manifest_bytes: PackedByteArray = build.files["manifest.json"]
	var next_definition := PluginDefinition.from_dict(JSON.parse_string(manifest_bytes.get_string_from_utf8()))
	if next_definition == null or next_definition.id != plugin_id or "live_reload" not in next_definition.capabilities:
		return {"ok": false, "error": "Restart to update: live-reload identity or capability changed"}
	next_definition.data_directory = source
	if not next_definition.validate_capabilities().is_empty():
		return {"ok": false, "error": "Restart to update: updated panel state hooks are invalid"}
	var archive := machine.store.archive(build)
	if not archive.get("ok", false):
		return archive
	if not Atomic.write(machine.store.directory.path_join("pending-install.json"), JSON.stringify({"digest": build.digest})):
		return {"ok": false, "error": "Cannot retain staged update identity"}
	_staged[plugin_id] = build
	return {"ok": true, "staged": true}


func activate_update(plugin_id: String) -> Dictionary:
	if not _staged.has(plugin_id):
		return {"ok": false, "error": "No staged live generation"}
	var build: Dictionary = _staged[plugin_id]
	_staged.erase(plugin_id)
	return await reload(plugin_id, build, true)


func _boot_pending(plugin_id: String, machine: PluginLiveSwap) -> void:
	var path := machine.store.directory.path_join("pending-install.json")
	if not FileAccess.file_exists(path):
		return
	var pending: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not pending is Dictionary or not Store.valid_digest(str(pending.get("digest", ""))):
		return
	var installed := machine.store.capture(_definition(plugin_id).data_directory)
	if not installed.get("ok", false) or installed.digest != pending.digest:
		return # The install did not commit, or a later install superseded it.
	if machine.record.active == pending.digest:
		return
	var archive := machine.store.read_archive(str(pending.digest))
	var checked := _validate(archive, machine, "B") if archive.get("ok", false) else archive
	if not checked.get("ok", false):
		_result(plugin_id, checked, true)
		return
	var selector := machine.store.prepare_selector(str(archive.digest), machine.record)
	if selector.get("ok", false) and machine.store.publish_selector().get("ok", false):
		machine.record = selector.record
		machine.active_slot = "B"
	else:
		_result(plugin_id, {"ok": false, "error": machine.store.error_message()}, true)


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
