class_name PluginLiveSwap
extends Node
## Owns candidate lifetime and the two reusable script caches. Host registration
## is injected: preparation never gives a candidate a public broker identity.

const Store := preload("res://Scripts/Services/Plugins/PluginGenerationStore.gd")
const Host := preload("res://Scripts/Services/Plugins/PluginScenePanelHost.gd")

class PrepareLogger extends Logger:
	var mutex := Mutex.new()
	var events: Array[Dictionary] = []

	func _log_error(function: String, file: String, line: int, code: String,
			rationale: String, _editor_notify: bool, error_type: int,
			_script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == 1: # Godot's warning category is not a fatal error.
			return
		mutex.lock()
		if events.size() < 100:
			events.append({"function": function, "file": file, "line": line,
				"code": code, "message": rationale, "type": error_type,
				"thread": OS.get_thread_caller_id()})
		mutex.unlock()

	func snapshot() -> Array[Dictionary]:
		mutex.lock()
		var result: Array[Dictionary] = events.duplicate(true)
		mutex.unlock()
		return result

var store: PluginGenerationStore
var record: Dictionary = {}
var active_slot: String = "A"
var busy: bool = false
var _slots: Dictionary = {}


func configure(generation_store: PluginGenerationStore) -> void:
	store = generation_store


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}


## Recompile dependencies before consumers at the inactive slot's fixed paths.
## Keep those Script objects across failures as well as successful reuse.
func compile_build(build: Dictionary, slot: String) -> Dictionary:
	var written := store.write_slot(slot, build)
	if not written.get("ok", false):
		return written
	if not _slots.has(slot):
		_slots[slot] = {"scripts": {}}
	var scripts: Dictionary = _slots[slot].scripts
	var files: Dictionary = build.files
	var order: Array[String] = []
	var visited: Dictionary = {}
	for name: String in files:
		if name.ends_with(".gd"):
			var ordered := _visit_script(name, files, visited, order)
			if not ordered.get("ok", false):
				return ordered
	# Assign every existing script's source first: a consumer preload must never
	# read a previous candidate's source while dependencies are being rebuilt.
	for name: String in order:
		if scripts.has(name):
			var previous: GDScript = scripts[name]
			previous.source_code = files[name].get_string_from_utf8()
	for name: String in order:
		var path := store.slot_path(slot).path_join(name)
		var script: GDScript = scripts.get(name)
		if script == null:
			script = ResourceLoader.load(path, "GDScript") as GDScript
			if script == null:
				return _failure("Candidate script failed to load: " + name)
			scripts[name] = script
		script.source_code = files[name].get_string_from_utf8()
		if script.reload(false) != OK or not script.can_instantiate():
			return _failure("Candidate script failed to compile: " + name)
	return {"ok": true}


static func _visit_script(name: String, files: Dictionary, visited: Dictionary, order: Array[String]) -> Dictionary:
	if visited.get(name, 0) == 2:
		return {"ok": true}
	if visited.get(name, 0) == 1:
		return _failure("Cyclic candidate preload: " + name)
	visited[name] = 1
	var bytes: PackedByteArray = files[name]
	for reference: String in Store.resource_references(bytes.get_string_from_utf8(), true):
		if not reference.ends_with(".gd") or reference.begins_with("res://"):
			continue # Store has already applied the public host API allowlist.
		var relative := name.get_base_dir().path_join(reference).simplify_path()
		if not files.has(relative):
			return _failure("Candidate dependency missing: " + relative)
		var result := _visit_script(relative, files, visited, order)
		if not result.get("ok", false):
			return result
	visited[name] = 2
	order.append(name)
	return {"ok": true}


## Entry dictionaries come from the manager's live registry. Their originals
## are left untouched until the host wire callback accepts the whole swap.
func _prepare(build: Dictionary, slot: String, entries: Array[Dictionary]) -> Dictionary:
	var compiled := compile_build(build, slot)
	if not compiled.get("ok", false):
		return compiled
	var candidates: Array[Dictionary] = []
	var staging := Control.new()
	staging.visible = false
	add_child(staging)
	for entry: Dictionary in entries:
		var old: Control = entry.root
		var state: Variant = Host.invoke_save(old, {})
		if not state is Dictionary:
			staging.free()
			return _failure("Panel save hook must return a Dictionary")
		var envelope := {"encoding": "godot-variant-hex-v1", "bytes": var_to_bytes(state).hex_encode()}
		# A JSON boundary with a byte encoding preserves large integer values.
		var decoded: Dictionary = JSON.parse_string(JSON.stringify(envelope))
		var copied: Variant = bytes_to_var(str(decoded.bytes).hex_decode())
		var definition: Dictionary = entry.panel_definition
		var scene_path := store.slot_path(slot).path_join(str(definition.entry_scene))
		var packed := ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		if packed == null:
			staging.free()
			return _failure("Candidate scene failed to load: " + scene_path)
		var allowed := PackedStringArray()
		for name: String in definition.scripts:
			allowed.append(store.slot_path(slot).path_join(name))
		if not Host._audit_packed_scene(packed, allowed):
			staging.free()
			return _failure("Candidate scene references undeclared scripts")
		var instance := packed.instantiate()
		if not instance is Control:
			if instance != null:
				instance.free()
			staging.free()
			return _failure("Candidate panel root must be a Control")
		var panel: Control = instance
		staging.add_child(panel)
		if not Host.invoke_load(panel, copied) or not Host.invoke_self_check(panel):
			staging.free()
			return _failure("Candidate import or self-check refused")
		if var_to_bytes(Host.invoke_save(panel, {})) != var_to_bytes(state):
			staging.free()
			return _failure("Candidate did not preserve the complete transient state")
		candidates.append({"entry": entry, "root": panel, "state": copied,
			"old": old, "visible": old.visible})
	return {"ok": true, "candidates": candidates, "staging": staging}


## wire(entry, root, first_load) -> bool owns broker/buffer/editor wiring.
## It must restore an old root without firing its loaded lifecycle again.
## retire(root) disconnects the old panel's plugin-owned signals on success.
func swap(build: Dictionary, entries: Array[Dictionary], wire: Callable, retire: Callable) -> Dictionary:
	if busy or store == null or not wire.is_valid() or not retire.is_valid():
		return _failure("Scene reload is unavailable or already in progress")
	busy = true
	var archived := store.archive(build)
	if not archived.get("ok", false):
		busy = false
		return archived
	var target := "B" if active_slot == "A" else "A"
	var logger := PrepareLogger.new()
	OS.add_logger(logger)
	var prepared := _prepare(build, target, entries)
	if prepared.get("ok", false):
		await get_tree().process_frame
		await get_tree().process_frame
		for candidate: Dictionary in prepared.candidates:
			if not Host.invoke_self_check(candidate.root) \
				or var_to_bytes(Host.invoke_save(candidate.root, {})) != var_to_bytes(candidate.state):
				prepared.ok = false
				prepared.error = "Candidate deferred initialization changed state or failed self-check"
	var errors := logger.snapshot()
	if not errors.is_empty():
		prepared.ok = false
		prepared.error = "Candidate preparation reported errors: " + JSON.stringify(errors)
	if not prepared.get("ok", false):
		OS.remove_logger(logger)
		if prepared.has("staging"):
			prepared.staging.free()
		busy = false
		return prepared
	var selector := store.prepare_selector(str(build.digest), record)
	if not selector.get("ok", false):
		OS.remove_logger(logger)
		prepared.staging.free()
		busy = false
		return selector
	# No awaits from the first public registration through publication/rollback.
	var wired: Array[Dictionary] = []
	var success := true
	for candidate: Dictionary in prepared.candidates:
		var panel: Control = candidate.root
		var entry: Dictionary = candidate.entry
		panel.reparent(entry.vbox)
		panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		wired.append(candidate)
		candidate.old.visible = false
		panel.visible = candidate.visible
		if not wire.call(entry, panel, true) or not Host.invoke_load(panel, candidate.state) \
			or not Host.invoke_self_check(panel):
			success = false
			break
		if var_to_bytes(Host.invoke_save(panel, {})) != var_to_bytes(candidate.state):
			success = false
			break
	errors = logger.snapshot()
	OS.remove_logger(logger)
	if not errors.is_empty():
		success = false
	var publication := store.publish_selector() if success else _failure("Candidate host wiring refused")
	if not publication.get("ok", false):
		for candidate: Dictionary in wired:
			wire.call(candidate.entry, candidate.old, false)
			Host.invoke_load(candidate.old, candidate.state)
			candidate.old.visible = candidate.visible
		for candidate: Dictionary in prepared.candidates:
			retire.call(candidate.root)
			candidate.root.free()
		prepared.staging.free()
		busy = false
		return _failure(str(publication.get("error", "Selector publication failed")) + "; previous panels retained")
	record = selector.record
	active_slot = target
	for candidate: Dictionary in prepared.candidates:
		retire.call(candidate.old)
		candidate.old.free()
	prepared.staging.free()
	busy = false
	return {"ok": true, "digest": build.digest}
