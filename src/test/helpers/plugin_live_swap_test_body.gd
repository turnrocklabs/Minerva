extends Node
## Real script/scene files, two panels and same-process retries. Public host
## integration is a separate suite; this one isolates the swap transaction.

const Store := preload("res://Scripts/Services/Plugins/PluginGenerationStore.gd")
const Swapper := preload("res://Scripts/Services/Plugins/PluginLiveSwap.gd")
const Host := preload("res://Scripts/Services/Plugins/PluginScenePanelHost.gd")
const Atomic := preload("res://Scripts/Services/Plugins/AtomicFile.gd")
var failures: int = 0
var checks: int = 0
var swapper: PluginLiveSwap
var store: PluginGenerationStore
var entries: Array[Dictionary] = []
var fault: String = ""
var rename_blocked: bool = false
var metrics: Array[Dictionary] = []


signal completed(exit_code: int)


func _ready() -> void:
	_run.call_deferred()


func check(label: String, passed: bool) -> void:
	checks += 1
	if not passed:
		failures += 1
		printerr("FAIL: " + label)
	else:
		print("PASS: " + label)


func make_build(version: int, injected: String = "") -> Dictionary:
	var source := FileAccess.get_file_as_string("res://test/fixtures/live_reload/Panel.gd.template")
	source = source.replace("VERSION_TOKEN", str(version)).replace("FAULT_TOKEN", injected)
	if injected == "compile":
		source += "\nfunc invalid( -> void:\n"
	var scene := '[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="Panel.gd" id="1"]\n[node name="Panel" type="Control"]\nscript = ExtResource("1")\n[node name="Marker" type="Label" parent="."]\ntext = "%d"\n' % version
	if injected == "missing-node":
		scene = scene.replace('[node name="Marker" type="Label" parent="."]\ntext = "%d"\n' % version, "")
	if injected == "scene":
		scene = "not a Godot scene"
	return store.bundle({"Panel.gd": source.to_utf8_buffer(),
		"Dependency.gd": ("extends RefCounted\nstatic func operation(value: int) -> int:\n\treturn value * %d\n" % version).to_utf8_buffer(),
		"Child.tscn": ('[gd_scene format=3]\n[node name="Child" type="Label"]\ntext = "%d"\n' % version).to_utf8_buffer(),
		"Settings.gd": ("extends Resource\nfunc version() -> int:\n\treturn %d\n" % version).to_utf8_buffer(),
		"Settings.tres": '[gd_resource type="Resource" load_steps=2 format=3]\n[ext_resource type="Script" path="Settings.gd" id="1"]\n[resource]\nscript = ExtResource("1")\n'.to_utf8_buffer(),
		"Panel.tscn": scene.to_utf8_buffer()})


func wire(entry: Dictionary, panel: Control, _first_load: bool) -> bool:
	entry.root = panel
	if fault == "rename" and not rename_blocked and _first_load:
		check("prepare wrote selector temp before wiring", FileAccess.file_exists(store.selector_path() + ".tmp"))
		check("move old selector aside for actual rename fault", DirAccess.rename_absolute(store.selector_path(), store.selector_path() + ".saved") == OK)
		check("create blocking destination directory", DirAccess.make_dir_recursive_absolute(store.selector_path()) == OK)
		check("keep blocking directory nonempty", Atomic.write(store.selector_path().path_join("occupied"), "fault"))
		rename_blocked = true
	if rename_blocked and not _first_load:
		check("remove injected destination by preserving it elsewhere", DirAccess.rename_absolute(store.selector_path(), store.selector_path() + ".blocked-" + str(Time.get_ticks_usec())) == OK)
		check("restore selector after injected environment fault", DirAccess.rename_absolute(store.selector_path() + ".saved", store.selector_path()) == OK)
		rename_blocked = false
		fault = ""
	return true


func retire(_panel: Control) -> void:
	pass # This fixture has no host signal registrations; integration tests do.


func _run() -> void:
	await get_tree().process_frame
	# Performance counts include the real application's autoload startup jobs.
	# Settle those before the warmed baseline; keep the equality oracle strict.
	await get_tree().create_timer(3.0).timeout
	await get_tree().process_frame
	if "--live-swap-baseline" in OS.get_cmdline_user_args():
		print("BASELINE_DONE")
		completed.emit(0)
		return
	store = Store.new("fixture", "user://live-swap-contract-" + str(Time.get_ticks_usec()))
	swapper = Swapper.new()
	swapper.configure(store)
	get_tree().root.add_child(swapper)
	var initial := make_build(1)
	check("initial archive", store.archive(initial).ok)
	check("initial script compilation", swapper.compile_build(initial, "A").ok)
	check("initial selector", store.prepare_selector(initial.digest, {}).ok and store.publish_selector().ok)
	swapper.record = {"version": 1, "active": initial.digest, "lkg": ""}
	for index: int in 2:
		var box := VBoxContainer.new()
		get_tree().root.add_child(box)
		var packed := load(store.slot_path("A").path_join("Panel.tscn")) as PackedScene
		var panel := packed.instantiate() as Control
		box.add_child(panel)
		var state := {"text": "unsaved-" + str(index), "undo": ["before", "after"], "large": 9007199254740993, "view": {"scroll": 42.5}}
		Host.invoke_load(panel, state)
		entries.append({"root": panel, "vbox": box, "panel_definition": {"entry_scene": "Panel.tscn", "scripts": ["Dependency.gd", "Panel.gd"]}})
	for version: int in range(2, 10):
		check("warm swap %d" % version, (await swapper.swap(make_build(version), entries, wire, retire)).ok)
		check("nested scene and preloaded resource refreshed %d" % version, entries[0].root.call("nested_version") == version * 2)
	check("changed marker and operation", entries[0].root.get_node("Marker").text == "9" and entries[0].root.call("operation", 3) == 27)
	var version := 10
	await get_tree().process_frame
	await get_tree().process_frame
	_sample("warmed-baseline")
	for cycle: int in 3:
		for injected: String in ["compile", "scene", "import", "missing-node", "self-check", "alias", "rename"]:
			var ids: Array[int] = []
			var states: Array[PackedByteArray] = []
			for entry: Dictionary in entries:
				ids.append(entry.root.get_instance_id())
				states.append(var_to_bytes(Host.invoke_save(entry.root, {})))
			var selector := FileAccess.get_file_as_bytes(store.selector_path())
			fault = injected
			var result: Dictionary = await swapper.swap(make_build(version, injected), entries, wire, retire)
			check(injected + " refuses visibly", not result.ok and not str(result.get("error", "")).is_empty())
			var causes := {"compile": "failed to compile", "scene": "dependency failed to load", "import": "complete transient state", "missing-node": "Marker", "self-check": "self-check refused", "alias": "deferred initialization", "rename": "Cannot publish generation selector"}
			check(injected + " has its intended refusal cause", str(result.get("error", "")).contains(causes[injected]))
			for index: int in entries.size():
				check(injected + " keeps same old panel " + str(index), entries[index].root.get_instance_id() == ids[index])
				check(injected + " preserves exact state " + str(index), var_to_bytes(Host.invoke_save(entries[index].root, {})) == states[index])
			check(injected + " selector bytes preserved", FileAccess.get_file_as_bytes(store.selector_path()) == selector)
			fault = ""
			version += 1
			check(injected + " followed by successful same-process reuse", (await swapper.swap(make_build(version), entries, wire, retire)).ok)
			await get_tree().process_frame
			await get_tree().process_frame
			_sample(injected + "-" + str(cycle))
			version += 1
	check("newer data and integer precision retained", Host.invoke_save(entries[0].root, {}).large == 9007199254740993)
	# Edits during the two yielded preparation frames must be recaptured.
	for publish_fails: bool in [false, true]:
		var before_edit: Dictionary = Host.invoke_save(entries[0].root, {})
		before_edit.text = "before-edit"
		Host.invoke_load(entries[0].root, before_edit)
		_edit_old.call_deferred()
		fault = "rename" if publish_fails else ""
		var edited_result: Dictionary = await swapper.swap(make_build(version), entries, wire, retire)
		check("publication outcome for concurrent edit", edited_result.ok != publish_fails)
		check("edit during prepare survives success or rollback", Host.invoke_save(entries[0].root, {}).text == "edited-during-prepare")
		await get_tree().process_frame
		await get_tree().process_frame
		_sample("edit-rename-refusal" if publish_fails else "edit-success")
		version += 1
	# A tab can close while the candidate waits for deferred initialization.
	entries[1].vbox.call_deferred("free")
	var closed: Dictionary = await swapper.swap(make_build(version), entries, wire, retire)
	check("closed participant refuses without stranding busy", not closed.ok and not swapper.busy)
	entries.remove_at(1)
	check("swap remains usable after tab closure", (await swapper.swap(make_build(version + 1), entries, wire, retire)).ok)
	# Restore the same two-tab measurement shape: freeing a tab must not mask
	# resource or RSS growth in the closure path.
	var reopened_box := VBoxContainer.new()
	get_tree().root.add_child(reopened_box)
	var reopened: Control = entries[0].root.duplicate()
	reopened_box.add_child(reopened)
	Host.invoke_load(reopened, Host.invoke_save(entries[0].root, {}))
	var reopened_entry: Dictionary = entries[0].duplicate()
	reopened_entry.root = reopened
	reopened_entry.vbox = reopened_box
	entries.append(reopened_entry)
	for next_version: int in [version + 2, version + 3]:
		check("two-tab reuse after closure", (await swapper.swap(make_build(next_version), entries, wire, retire)).ok)
	await get_tree().process_frame
	await get_tree().process_frame
	_sample("closure-reopened-two-tabs")
	print("SWAP_MEMORY ", JSON.stringify(metrics))
	var objects: Array[float] = []
	var resources: Array[float] = []
	var rss: Array[int] = []
	for sample: Dictionary in metrics:
		objects.append(sample.objects)
		resources.append(sample.resources)
		rss.append(sample.rss_pages)
	check("fault-path object count is flat", objects.max() == objects.min())
	check("fault-path resource count is flat", resources.max() == resources.min())
	check("RSS was measured", rss.min() > 0)
	check("fault-path RSS remains bounded after warmup", rss.max() - rss.min() <= 256)
	for entry: Dictionary in entries:
		entry.vbox.free()
	swapper.free()
	print("Plugin live swap: %d checks, %d failures" % [checks, failures])
	completed.emit(1 if failures else 0)


func _edit_old() -> void:
	var panel: Control = entries[0].root
	var state: Dictionary = Host.invoke_save(panel, {})
	state.text = "edited-during-prepare"
	Host.invoke_load(panel, state)


func _sample(label: String) -> void:
	var stat_file := FileAccess.open("/proc/self/statm", FileAccess.READ)
	var statm := stat_file.get_line().split(" ") if stat_file != null else PackedStringArray()
	metrics.append({"fault": label, "objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"orphans": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		"rss_pages": int(statm[1]) if statm.size() > 1 else -1})
