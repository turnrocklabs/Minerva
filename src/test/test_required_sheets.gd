extends SceneTree
## Public catalog, real packaged provider, real host manager and file handoff.
var passed := 0
var failed := 0
var helpers
var manager
var host

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, ok: bool) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func until(ready: Callable) -> void:
	var deadline := Time.get_ticks_msec() + 60000
	while not ready.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	check("operation completed before deadline", ready.call())

func offer(root_dir: String, repo: String, entries: Array) -> void:
	var directory := root_dir.path_join("repos").path_join(repo)
	DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(directory.path_join("releases"), FileAccess.WRITE)
	file.store_string(JSON.stringify(entries))
	file.close()

func _run() -> void:
	helpers = load("res://test/marketplace_test_helpers.gd").new(self)
	manager = await helpers.bootstrap_plugin_manager(true)
	host = root.get_node("SingletonObject")
	var fixture := OS.get_environment("MINERVA_REQUIRED_SHEETS_FIXTURE")
	check("isolated fixture and real manager exist", manager != null and not fixture.is_empty())
	if manager == null or fixture.is_empty():
		quit(1)
		return
	check("fresh profile has no Sheets provider", not manager.get_db().has_plugin("sheets"))
	var published := OS.get_environment("MINERVA_REQUIRED_SHEETS_PUBLISHED") == "1"
	if published:
		RequiredPlugins.releases_url = OS.get_environment("MINERVA_REQUIRED_SHEETS_BASE")
		check("published probe uses an exported app", not OS.has_feature("editor"))
	else:
		var port: int = helpers.random_high_port()
		var target := MarketplaceClient.resolve_platform_target()
		var asset := "sheets-0.1.0-%s.tar.gz" % target
		offer(fixture, RequiredPlugins.REPO, [{"tag_name": "voice-v9.8.7", "assets": [{
			"name": "voice-9.8.7-unrelated-target.tar.gz", "browser_download_url": "https://example.invalid/voice"}]}])
		offer(fixture, "imrans-lab/minerva-plugins", [{"tag_name": "sheets-v0.1.0", "assets": [{
			"name": asset, "browser_download_url": "http://127.0.0.1:%d/%s" % [port, asset]}]}])
		if not await helpers.start_http_server(fixture, port):
			check("HTTP fixture started", false)
			quit(1)
			return
		RequiredPlugins.releases_url = "http://127.0.0.1:%d" % port
	var entries: Dictionary = await RequiredPlugins.fetch_entries(manager)
	check("public catalog fetches both declared repositories", not entries.get("voice", {}).is_empty()
		and entries.get("sheets", {}).get("version") == "0.1.0")
	check("Sheets release link belongs to its own repository", RequiredPlugins.release_page("sheets") == "https://github.com/imrans-lab/minerva-plugins/releases")
	if published and OS.get_name() == "macOS":
		check("published macOS arm64 selects the universal release asset", Engine.get_architecture_name() == "arm64"
			and MarketplaceClient.download_target(entries.get("sheets", {}).get("downloads", {})) == "macos-universal")
	var jobs: Dictionary = await RequiredPlugins.ensure(manager)
	check("required pickup queues real Sheets archive", jobs.has("sheets"))
	if not jobs.has("sheets"):
		await finish()
		return
	await until(func() -> bool: return jobs.sheets.state == jobs.sheets.State.DONE)
	await until(func() -> bool:
		var definition = manager.get_db().get_by_id("sheets")
		return definition != null and definition.state == PluginDefinition.State.RUNNING)
	var definition = manager.get_db().get_by_id("sheets")
	check("installed required provider starts with first-install choices", definition != null and definition.version == "0.1.0"
		and definition.install_lane == PluginDefinition.LANE_MARKETPLACE and definition.autostart and definition.auto_update)
	if definition == null or definition.state != PluginDefinition.State.RUNNING:
		await finish()
		return
	# The standalone runner has no main editor scene; host-owned pane/brokers stay real.
	var ui := preload("res://test/helpers/chat_host_render_fixture.gd").new()
	ui.install(host)
	var pane = load("res://Scripts/UI/Views/EditorPane.gd").new()
	var tabs := TabContainer.new()
	root.add_child(tabs)
	pane.Tabs = tabs
	pane.buffer_control_editor = Control.new()
	host.editor_pane = pane
	# A readable empty policy owner isolates provider pickup from an unrelated Docket release.
	host.mcp_manager.minerva_server.policy_engine = load("res://test/helpers/hosted_policy_fixture.gd").new()
	var csv := fixture.path_join("required-source.csv")
	var csv_bytes := "Name,Value\nZoë,5\n李,7".to_utf8_buffer()
	var file := FileAccess.open(csv, FileAccess.WRITE)
	file.store_buffer(csv_bytes)
	file.close()
	var opened: Dictionary = await host.plugin_tool_registry.handle_tool_call("minerva_sheets_create_editor", {"name": "Required CSV provider", "file_path": csv})
	var data: Dictionary = await host.plugin_tool_registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": opened.get("editor_name", ""), "format": "json"})
	print("REQUIRED_SHEETS_CSV ", JSON.stringify([opened, data]))
	check("installed release opens real CSV through canonical host path", opened.get("success") == true
		and data.get("data") == [["Name", "Value"], ["Zoë", 5.0], ["李", 7.0]] and FileAccess.get_file_as_bytes(csv) == csv_bytes)
	var native_path := fixture.path_join("required-native.minsheet")
	check("stage immutable native fixture", DirAccess.copy_absolute(ProjectSettings.globalize_path("res://test/fixtures/spreadsheet_contract/baseline.minsheet"), native_path) == OK)
	var native_open: Dictionary = await host.plugin_tool_registry.handle_tool_call("minerva_sheets_create_editor", {"name": "Required native provider", "file_path": native_path})
	print("REQUIRED_SHEETS_NATIVE ", JSON.stringify(native_open))
	check("installed release opens native format as a second live editor", native_open.get("success") == true
		and native_open.get("editor_name") != opened.get("editor_name") and tabs.get_tab_count() == 2)
	check("required Sheets cannot be removed", (await manager.remove_plugin("sheets")).has("error"))
	await finish()

func finish() -> void:
	if manager != null and manager.get_db().has_plugin("sheets"):
		await manager.stop_plugin("sheets", true)
	if helpers != null:
		helpers.teardown()
	if failed == 0:
		print("PACKAGED_REQUIRED_SHEETS_OK" if OS.get_environment("MINERVA_REQUIRED_SHEETS_PUBLISHED") == "1" else "SOURCE_REQUIRED_SHEETS_OK")
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)
