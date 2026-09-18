extends SceneTree
## Verifies reusable disconnect and non-owning module lifetimes.

var passed := 0
var failed := 0


class ParkedModule extends RefCounted:
	signal released

	var _server_ref: WeakRef
	var did_enter := false
	var server:
		get:
			return _server_ref.get_ref() if _server_ref != null else null
		set(value):
			_server_ref = weakref(value) if value != null else null

	func _init(owner: RefCounted) -> void:
		server = owner

	func can_handle(tool_name: String) -> bool:
		return tool_name == "minerva_lifecycle_parked"

	func handle(_tool_name: String, _arguments: Dictionary) -> Dictionary:
		did_enter = true
		await released
		return {"success": server != null}


class CallHarness extends Node:
	var completed_result: Dictionary = {}

	func invoke(server: RefCounted) -> void:
		# The suspended call owns its server argument until dispatch completes.
		completed_result = await server.call_tool("minerva_lifecycle_parked", {})


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	# Load after the autoload frame so this standalone fixture follows the same
	# initialization order as the application rather than eagerly compiling it.
	var manager: Variant = load("res://Scripts/Services/MCP/MCPManager.gd").new()
	root.add_child(manager)
	await process_frame
	var server: Variant = manager.minerva_server
	var parked := ParkedModule.new(server)
	server._modules.append(parked)
	server._register_tool("minerva_lifecycle_parked", "Lifecycle test operation.",
		{"type": "object", "properties": {}})
	var server_ref: WeakRef = weakref(server)
	var module_refs := _weak_refs(server._modules)

	manager.connect_minerva_server()
	manager.disconnect_minerva_server()
	manager.connect_minerva_server()
	check("ordinary disconnect reconnects the same internal server",
		manager.minerva_server == server and server.server_enabled
		and server._modules.back() == parked)

	var harness := CallHarness.new()
	root.add_child(harness)
	harness.invoke(server)
	for _frame: int in range(30):
		if parked.did_enter:
			break
		await process_frame
	check("server-mediated module dispatch reaches its awaited operation", parked.did_enter)
	server = null
	manager.free()
	manager = null
	await process_frame
	check("tree exit disconnects but an in-flight dispatch retains its server",
		server_ref.get_ref() != null and not server_ref.get_ref().server_enabled)
	check("the in-flight server retains every module", _all_refs_alive(module_refs))

	parked.released.emit()
	for _frame: int in range(30):
		if not harness.completed_result.is_empty():
			break
		await process_frame
	check("parked dispatch completes with its weak parent still valid",
		harness.completed_result.get("success", false))
	parked = null
	harness.free()
	await process_frame
	check("completion releases the server and every owned module",
		server_ref.get_ref() == null and _all_refs_released(module_refs))

	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)


func _weak_refs(objects: Array) -> Array[WeakRef]:
	var refs: Array[WeakRef] = []
	for item: Variant in objects:
		refs.append(weakref(item))
	return refs


func _all_refs_alive(refs: Array[WeakRef]) -> bool:
	for item: WeakRef in refs:
		if item.get_ref() == null:
			return false
	return true


func _all_refs_released(refs: Array[WeakRef]) -> bool:
	for item: WeakRef in refs:
		if item.get_ref() != null:
			return false
	return true


func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: ", label)
	else:
		failed += 1
		printerr("FAIL: ", label)
