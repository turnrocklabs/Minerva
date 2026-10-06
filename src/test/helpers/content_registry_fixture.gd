extends RefCounted
## Hermetic plugin protocol from the owner-seeding suite, behind the real
## DocketHost binding/settlement path. Canonical-file durability is exercised
## by minerva-plugins' real-child consumer suite.
var store
var host
var manager
var docket: PluginSeedingDocket

func _init(master_path: String = "/content-fixture/master.dct") -> void:
	var suite = load("res://test/test_plugin_owner_seeding.gd")
	store = _make(suite.STORE_SRC)
	store.create_defaults = {"customised": false, "deprecated": false}
	manager = _make(suite.HOST_MANAGER_SRC)
	host = load("res://Scripts/Services/DocketHost/DocketHost.gd").new()
	store.master.path = master_path
	store.projects = [store.master]
	manager.connection = store
	host._plugin_manager = manager
	host._connection = store
	host._generation = store.process_generation()
	host.projects = store.projects
	host.master_path = master_path
	host.state = "ready"
	docket = PluginSeedingDocket.new(host, true)

func add_project(name: String, path: String) -> void:
	store.projects.append({"name": name, "display_name": name, "path": path, "open_generation": "1"})

## Direct field assertions and apply_user_edit use the same protocol store.
func call_tool(tool: String, arguments: Dictionary) -> Dictionary:
	var args := arguments.duplicate(true)
	if str(args.get("project", "")).is_empty():
		args["project"] = "master"
	return store.call_tool(tool, args)

func close() -> void:
	host.free()
	manager.free()

func _make(source: String):
	var script := GDScript.new()
	script.source_code = source
	assert(script.reload() == OK)
	return script.new()
