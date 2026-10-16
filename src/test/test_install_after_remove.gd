extends SceneTree
## Real removal journal and Marketplace transaction, with hosted cleanup held.
const ID := "reinstall_fixture"
const TXN := preload("res://Scripts/Services/Plugins/PluginInstallTransaction.gd")
var failed: int = 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	var helpers = load("res://test/marketplace_test_helpers.gd").new(self)
	var temp := ProjectSettings.globalize_path("user://reinstall-fixture")
	var pack := temp.path_join("pack")
	assert(helpers.mkdir_recursive(pack))
	var manifest_path := pack.path_join("manifest.json")
	var manifest := FileAccess.open(manifest_path, FileAccess.WRITE)
	manifest.store_string(JSON.stringify({"id": ID, "name": "Reinstall fixture", "version": "1.0.0",
		"host_api_version": "2", "backend": {"transport": "stdio", "entrypoint": "./probe"},
		"tools": [], "skills": [], "knowledge": [], "autostart": false}))
	manifest.close()
	var binary := FileAccess.open(pack.path_join("probe"), FileAccess.WRITE)
	binary.store_string("fixture-not-started")
	binary.close()
	assert(helpers.pack_plugin_dir(pack, temp.path_join("fixture.tar.gz")))
	var port: int = helpers.random_high_port()
	assert(await helpers.start_http_server(temp, port))
	var content = load("res://test/helpers/content_registry_fixture.gd").new(temp.path_join("master.dct"))
	var gate = load("res://test/helpers/removal_docket_gate.gd").new(content.host)
	var seeding = load("res://Scripts/Services/Plugins/PluginContentSeeding.gd")
	seeding.docket_override = gate
	var manager = load("res://Scripts/Services/Plugins/PluginManager.gd").new()
	manager._db = PluginDB.new()
	assert(manager._db.install(manifest_path) != null)
	var client := MarketplaceClient.new()
	root.add_child(client)
	var removal: Array[Dictionary] = []
	_remove(manager, removal)
	while not gate.waiting:
		await process_frame
	var op = load("res://Scripts/Services/Plugins/PluginInstallOperation.gd").new()
	var installed: Array[Dictionary] = []
	_install(client, "http://127.0.0.1:%d/fixture.tar.gz" % port, manager, op, installed)
	var deadline := Time.get_ticks_msec() + 5000
	while installed.is_empty() and op.stage != "wait" and Time.get_ticks_msec() < deadline:
		await process_frame
	# Allow the base to reach its pending-record refusal, or the fix to wait.
	await create_timer(0.15).timeout
	var waited: bool = installed.is_empty() and removal.is_empty()
	gate.released.emit()
	while (installed.is_empty() or removal.is_empty()) and Time.get_ticks_msec() < deadline:
		await process_frame
	check("immediate install waits for real removal and then succeeds",
		waited and installed.size() == 1 and installed[0].get("ok", false)
		and removal.size() == 1 and removal[0].get("ok", false) and manager._db.has_plugin(ID))
	# An abandoned repair cannot be made safe just by waiting. Preserve it.
	var staging := ProjectSettings.globalize_path(MarketplaceClient.STAGING_DIR)
	var pending: String = TXN.queue_cleanup(staging, ID,
		{"removal": true, "stale": true, "paths": {"": ""}, "enumerated": null}, "cleanup needs review")
	assert(not pending.is_empty())
	var stuck: Dictionary = await client.install_from_url("http://127.0.0.1:%d/fixture.tar.gz" % port, manager, true)
	var direct: Dictionary = await manager.install_plugin(manifest_path, true)
	var message := MarketplaceClient.format_install_error(stuck)
	check("stuck repair blocks both install gates with GUI-actionable guidance",
		stuck.get("error") == "content_repair_pending" and direct.has("error")
		and FileAccess.file_exists(pending) and "restart Minerva" in message
		and "delete" not in message and "content-pending" not in message)
	# The assertion above proves refusal preserves the journal. Teardown owns
	# only this fixture's journal and registration in the shared suite profile.
	TXN.content_done(pending)
	var fixture_removed: bool = manager._db.remove(ID) == true
	check("anti-case cleans up its own journal and fixture",
		fixture_removed and not FileAccess.file_exists(pending) and manager._db.has_plugin(ID) == false)
	seeding.docket_override = null
	client.free()
	manager.free()
	content.close()
	helpers.stop_http_server()
	print("=== Results: %d passed, %d failed ===" % [3 - failed, failed])
	quit(1 if failed else 0)

func _remove(manager, results: Array[Dictionary]) -> void:
	results.append(await manager.remove_plugin(ID))

func _install(client: MarketplaceClient, url: String, manager, op, results: Array[Dictionary]) -> void:
	results.append(await client.install_from_url(url, manager, true, op))

func check(label: String, ok: bool) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok:
		failed += 1
