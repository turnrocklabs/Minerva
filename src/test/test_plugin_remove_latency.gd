extends SceneTree
## One happy-path removal: real manager, PluginDB, panel and cleanup journal;
## existing hermetic Docket protocol store behind the real hosted binding.

const SEEDING := preload("res://Scripts/Services/Plugins/PluginContentSeeding.gd")
const TXN := preload("res://Scripts/Services/Plugins/PluginInstallTransaction.gd")
const PLUGIN_ID := "remove_latency_fixture"
const REMOVED_TOOL := "remove_latency_fixture_tool"

var passed: int = 0
var failed: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var registry = load("res://test/helpers/content_registry_fixture.gd").new(
		ProjectSettings.globalize_path("user://remove_latency_master.dct"))
	for index in range(124):
		var unrelated := REMOVED_TOOL + "_suffix" if index == 0 else "other_tool_%d" % index
		registry.call_tool("docket_create", {"type": "skill", "title": "Unrelated %d" % index,
			"source": "user", "tool_deps": [unrelated], "unsatisfied_deps": [unrelated]})
	var affected: Dictionary = registry.call_tool("docket_create", {"type": "skill",
		"title": "Depends on removed tool", "source": "user",
		"tool_deps": [REMOVED_TOOL], "unsatisfied_deps": []})
	var affected_id: String = str(affected.id)
	var gate = load("res://test/helpers/removal_docket_gate.gd").new(registry.host)
	SEEDING.docket_override = gate
	# Runtime loading keeps the real manager's autoload context intact.
	var manager = load("res://Scripts/Services/Plugins/PluginManager.gd").new()
	manager._db = PluginDB.new()
	var manifest_path := "user://remove_latency_manifest.json"
	var manifest := FileAccess.open(manifest_path, FileAccess.WRITE)
	manifest.store_string(JSON.stringify({"id": PLUGIN_ID, "name": "Removal fixture",
		"version": "1.0.0", "backend": {"transport": "stdio", "entrypoint": "unused"},
		"tools": [{"name": REMOVED_TOOL, "description": "Fixture tool",
			"inputSchema": {"type": "object", "properties": {}}}], "skills": [], "knowledge": []}))
	manifest.close()
	var installed: PluginDefinition = manager._db.install(manifest_path)
	check("fixture record is installed through the real database", installed != null)
	var panel = load("res://Scenes/PluginManagerPanel.tscn").instantiate()
	panel._pm_override = manager
	root.add_child(panel)
	await process_frame
	var completed: Array[bool] = []
	panel._pending_remove_id = PLUGIN_ID
	_remove(panel, completed)
	await process_frame
	var listed := false
	for index in range(panel._plugin_list.item_count):
		listed = listed or panel._plugin_list.get_item_metadata(index) == PLUGIN_ID
	check("list refreshes while cleanup is still held", gate.waiting and completed.is_empty()
		and not manager._db.has_plugin(PLUGIN_ID) and not listed
		and "Cleaning up Removal fixture's skills" in panel._status_label.text)
	var staging := ProjectSettings.globalize_path(MarketplaceClient.STAGING_DIR)
	check("the cleanup journal remains pending while work is held", not TXN.content_pending(staging).is_empty())
	gate.released.emit()
	var deadline := Time.get_ticks_msec() + 3000
	while completed.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	check("only the intersecting skill is fetched; no per-skill gets for 124 unrelated records",
		completed.size() == 1 and gate.fetched == [affected_id])
	var changed: Dictionary = registry.call_tool("docket_get", {"id": affected_id})
	check("the dependent skill becomes unsatisfied", changed.get("unsatisfied_deps", []) == [REMOVED_TOOL])
	check("successful cleanup settles its existing journal", TXN.content_pending(staging).is_empty())
	SEEDING.docket_override = null
	panel.free()
	manager.free()
	registry.close()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _remove(panel, completed: Array[bool]) -> void:
	await panel._on_remove_confirmed()
	completed.append(true)


func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: " + label)
	else:
		failed += 1
		printerr("FAIL: " + label)
