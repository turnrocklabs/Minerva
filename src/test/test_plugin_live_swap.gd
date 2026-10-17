extends SceneTree
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


func _initialize() -> void:
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
		check("remove injected destination by preserving it elsewhere", DirAccess.rename_absolute(store.selector_path(), store.selector_path() + ".blocked") == OK)
		check("restore selector after injected environment fault", DirAccess.rename_absolute(store.selector_path() + ".saved", store.selector_path()) == OK)
		rename_blocked = false
		fault = ""
	return true


func retire(_panel: Control) -> void:
	pass # This fixture has no host signal registrations; integration tests do.


func _run() -> void:
	await process_frame
	store = Store.new("fixture", "user://live-swap-contract-" + str(Time.get_ticks_usec()))
	swapper = Swapper.new()
	swapper.configure(store)
	root.add_child(swapper)
	var initial := make_build(1)
	check("initial archive", store.archive(initial).ok)
	check("initial script compilation", swapper.compile_build(initial, "A").ok)
	check("initial selector", store.prepare_selector(initial.digest, {}).ok and store.publish_selector().ok)
	swapper.record = {"version": 1, "active": initial.digest, "lkg": ""}
	for index: int in 2:
		var box := VBoxContainer.new()
		root.add_child(box)
		var packed := load(store.slot_path("A").path_join("Panel.tscn")) as PackedScene
		var panel := packed.instantiate() as Control
		box.add_child(panel)
		var state := {"text": "unsaved-" + str(index), "undo": ["before", "after"], "large": 9007199254740993, "view": {"scroll": 42.5}}
		Host.invoke_load(panel, state)
		entries.append({"root": panel, "vbox": box, "panel_definition": {"entry_scene": "Panel.tscn", "scripts": ["Dependency.gd", "Panel.gd"]}})
	for version: int in range(2, 10):
		check("warm swap %d" % version, (await swapper.swap(make_build(version), entries, wire, retire)).ok)
	check("changed marker and operation", entries[0].root.get_node("Marker").text == "9" and entries[0].root.call("operation", 3) == 27)
	var version := 10
	for injected: String in ["compile", "scene", "import", "missing-node", "self-check", "rename"]:
		var ids: Array[int] = []
		var states: Array[PackedByteArray] = []
		for entry: Dictionary in entries:
			ids.append(entry.root.get_instance_id())
			states.append(var_to_bytes(Host.invoke_save(entry.root, {})))
		var selector := FileAccess.get_file_as_bytes(store.selector_path())
		fault = injected
		var result: Dictionary = await swapper.swap(make_build(version, injected), entries, wire, retire)
		check(injected + " refuses visibly", not result.ok and not str(result.get("error", "")).is_empty())
		for index: int in entries.size():
			check(injected + " keeps same old panel " + str(index), entries[index].root.get_instance_id() == ids[index])
			check(injected + " preserves exact state " + str(index), var_to_bytes(Host.invoke_save(entries[index].root, {})) == states[index])
		check(injected + " selector bytes preserved", FileAccess.get_file_as_bytes(store.selector_path()) == selector)
		fault = ""
		version += 1
		check(injected + " followed by successful same-process reuse", (await swapper.swap(make_build(version), entries, wire, retire)).ok)
		await process_frame
		await process_frame
		var statm := FileAccess.get_file_as_string("/proc/self/statm").split(" ")
		metrics.append({"fault": injected, "objects": Performance.get_monitor(Performance.OBJECT_COUNT),
			"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT), "rss_pages": int(statm[1]) if statm.size() > 1 else -1})
		version += 1
	check("newer data and integer precision retained", Host.invoke_save(entries[0].root, {}).large == 9007199254740993)
	print("SWAP_MEMORY ", JSON.stringify(metrics))
	for entry: Dictionary in entries:
		entry.vbox.free()
	swapper.free()
	print("Plugin live swap: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
