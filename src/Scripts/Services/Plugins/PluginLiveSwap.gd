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
	if not build.get("ok", false):
		return _failure("Invalid candidate build")
	for filename: String in build.files:
		if filename.get_extension() in ["scn", "res"]:
			return _failure("Live reload requires text scene/resource files: " + filename)
	var written := store.write_slot(slot, build)
	if not written.get("ok", false):
		return written
	if not _slots.has(slot):
		_slots[slot] = {"scripts": {}, "order": []}
	var scripts: Dictionary = _slots[slot].scripts
	# Retained constants can own scripted Resource instances. Release consumers
	# before their resource scripts; there are no live panels in this slot.
	var retained_order: Array = _slots[slot].order
	var previous_order: Array = retained_order.duplicate()
	previous_order.reverse()
	for filename: String in previous_order:
		if not scripts.has(filename):
			continue
		var previous: GDScript = scripts[filename]
		var native_base := previous.get_instance_base_type()
		if native_base.is_empty():
			previous.source_code = "extends RefCounted\n"
		else:
			previous.source_code = "extends %s\n" % native_base
		if previous.reload(false) != OK:
			return _failure("Inactive script still has live dependents: " + filename)
	var files: Dictionary = build.files
	var order: Array[String] = []
	var visited: Dictionary = {}
	for filename: String in files:
		if filename.get_extension() in ["gd", "tscn", "tres"]:
			var ordered := _visit_script(filename, files, visited, order)
			if not ordered.get("ok", false):
				return ordered
	_slots[slot].order = order.duplicate()
	# Assign every existing script's source first: a consumer preload must never
	# read a previous candidate's source while dependencies are being rebuilt.
	for filename: String in order:
		if filename.ends_with(".gd") and scripts.has(filename):
			var previous: GDScript = scripts[filename]
			var source_bytes: PackedByteArray = files[filename]
			previous.source_code = source_bytes.get_string_from_utf8()
	for filename: String in order:
		var path := store.slot_path(slot).path_join(filename)
		if not filename.ends_with(".gd"):
			# Refresh nested scenes/resources before consumers recompile preloads.
			if ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE_DEEP) == null:
				return _failure("Candidate dependency failed to load: " + filename)
			continue
		var script: GDScript = scripts.get(filename)
		if script == null:
			script = ResourceLoader.load(path, "GDScript") as GDScript
			if script == null:
				return _failure("Candidate script failed to load: " + filename)
			scripts[filename] = script
		var source_bytes: PackedByteArray = files[filename]
		script.source_code = source_bytes.get_string_from_utf8()
		if script.reload(false) != OK or not script.can_instantiate():
			return _failure("Candidate script failed to compile: " + filename)
	return {"ok": true}


static func _visit_script(filename: String, files: Dictionary, visited: Dictionary, order: Array[String]) -> Dictionary:
	if visited.get(filename, 0) == 2:
		return {"ok": true}
	if visited.get(filename, 0) == 1:
		return _failure("Cyclic candidate preload: " + filename)
	visited[filename] = 1
	var bytes: PackedByteArray = files[filename]
	var references: Array[String] = []
	if filename.get_extension() in ["gd", "tscn", "tres"]:
		references = Store.resource_references(bytes.get_string_from_utf8(), filename.ends_with(".gd"))
	for reference: String in references:
		if reference.begins_with("res://"):
			continue # Store has already applied the public host API allowlist.
		var relative := filename.get_base_dir().path_join(reference).simplify_path()
		if not files.has(relative):
			return _failure("Candidate dependency missing: " + relative)
		var result := _visit_script(relative, files, visited, order)
		if not result.get("ok", false):
			return result
	visited[filename] = 2
	order.append(filename)
	return {"ok": true}


## Entry dictionaries come from the manager's live registry. Their originals
## are left untouched until the host wire callback accepts the whole swap.
func _prepare(build: Dictionary, slot: String, entries: Array[Dictionary], validate_prepared: Callable) -> Dictionary:
	var compiled := compile_build(build, slot)
	if not compiled.get("ok", false):
		return compiled
	if validate_prepared.is_valid():
		var validated: Dictionary = validate_prepared.call(slot)
		if not validated.get("ok", false):
			return validated
	var candidates: Array[Dictionary] = []
	var staging := Control.new()
	staging.visible = false
	add_child(staging)
	for entry: Dictionary in entries:
		var old: Control = entry.root
		var state: Variant = Host.invoke_capture_live_state(old)
		if not state is Dictionary:
			staging.free()
			return _failure("Panel live-state capture must return a Dictionary")
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
		for filename: String in definition.scripts:
			allowed.append(store.slot_path(slot).path_join(filename))
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
		if not Host.invoke_restore_live_state(panel, copied) or not Host.invoke_self_check(panel):
			staging.free()
			return _failure("Candidate import or self-check refused")
		if var_to_bytes(Host.invoke_capture_live_state(panel)) != var_to_bytes(state):
			staging.free()
			return _failure("Candidate did not preserve the complete transient state")
		candidates.append({"entry": entry, "root": panel, "expected": var_to_bytes(state),
			"old": old, "visible": old.visible})
	return {"ok": true, "candidates": candidates, "staging": staging}


## wire(entry, root, first_load) -> bool owns broker/buffer/editor wiring.
## It must restore an old root without firing its loaded lifecycle again.
## retire(root) disconnects the old panel's plugin-owned signals on success.
## validate_prepared(slot) is synchronous and checks unopened panel definitions
## under this preparation logger, using the slot that was just compiled.
func swap(build: Dictionary, entries: Array[Dictionary], wire: Callable, retire: Callable, validate_prepared: Callable = Callable()) -> Dictionary:
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
	var prepared := _prepare(build, target, entries, validate_prepared)
	var staged_root: Control = prepared.get("staging")
	if prepared.get("ok", false):
		await get_tree().process_frame
		await get_tree().process_frame
		for candidate: Dictionary in prepared.candidates:
			if not _participant_alive(candidate):
				prepared.ok = false
				prepared.error = "A participating panel closed during preparation"
				break
			var panel: Control = candidate.root
			var old: Control = candidate.old
			var expected: PackedByteArray = candidate.expected
			if not Host.invoke_self_check(panel) \
				or var_to_bytes(Host.invoke_capture_live_state(panel)) != expected:
				prepared.ok = false
				prepared.error = "Candidate deferred initialization changed state or failed self-check"
				break
			# Old panels stayed editable during the waits. Capture their CURRENT
			# state now, then give the candidate a separate decoded copy. Expected
			# bytes are never supplied to a plugin or aliased to its dictionary.
			var latest: Variant = Host.invoke_capture_live_state(old)
			if not latest is Dictionary:
				prepared.ok = false
				prepared.error = "Current panel state could not be captured"
				break
			candidate.expected = var_to_bytes(latest)
			expected = candidate.expected
			if not Host.invoke_restore_live_state(panel, bytes_to_var(expected)) \
				or not Host.invoke_self_check(panel) \
				or var_to_bytes(Host.invoke_capture_live_state(panel)) != expected:
				prepared.ok = false
				prepared.error = "Candidate refused the latest panel state"
				break
	var errors := logger.snapshot()
	if not errors.is_empty():
		prepared.ok = false
		prepared.error = str(prepared.get("error", "Candidate initialization reported errors")) + "; " + JSON.stringify(errors)
	if not prepared.get("ok", false):
		OS.remove_logger(logger)
		if prepared.has("staging"):
			staged_root.free()
		busy = false
		return prepared
	var selector := store.prepare_selector(str(build.digest), record)
	if not selector.get("ok", false):
		OS.remove_logger(logger)
		staged_root.free()
		busy = false
		return selector
	# No awaits from the first public registration through publication/rollback.
	var wired: Array[Dictionary] = []
	var success := true
	for candidate: Dictionary in prepared.candidates:
		var panel: Control = candidate.root
		var entry: Dictionary = candidate.entry
		var parent: Node = entry.vbox
		var old: Control = candidate.old
		var expected: PackedByteArray = candidate.expected
		panel.reparent(parent)
		panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		wired.append(candidate)
		old.visible = false
		panel.visible = candidate.visible
		if not wire.call(entry, panel, true) or not Host.invoke_restore_live_state(panel, bytes_to_var(expected)) \
			or not Host.invoke_self_check(panel):
			success = false
			break
		if var_to_bytes(Host.invoke_capture_live_state(panel)) != expected:
			success = false
			break
	OS.remove_logger(logger)
	errors = logger.snapshot()
	if not errors.is_empty():
		success = false
	var publication := store.publish_selector() if success else _failure("Candidate host wiring refused")
	if not publication.get("ok", false):
		for candidate: Dictionary in wired:
			var old: Control = candidate.old
			var expected: PackedByteArray = candidate.expected
			wire.call(candidate.entry, old, false)
			Host.invoke_restore_live_state(old, bytes_to_var(expected))
			old.visible = candidate.visible
		for candidate: Dictionary in prepared.candidates:
			var panel: Control = candidate.root
			retire.call(panel)
			panel.free()
		staged_root.free()
		busy = false
		return _failure(str(publication.get("error", "Selector publication failed")) + "; previous panels retained")
	record = selector.record
	active_slot = target
	for candidate: Dictionary in prepared.candidates:
		var old: Control = candidate.old
		retire.call(old)
		old.free()
	staged_root.free()
	busy = false
	return {"ok": true, "digest": build.digest}


static func _participant_alive(candidate: Dictionary) -> bool:
	if not is_instance_valid(candidate.root) or not is_instance_valid(candidate.old):
		return false
	var entry: Dictionary = candidate.entry
	if not is_instance_valid(entry.vbox):
		return false
	var old: Control = candidate.old
	return entry.root == old and old.get_parent() == entry.vbox
