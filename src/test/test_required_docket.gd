extends SceneTree
## Required-plugin index case with the actual signed child and local release archives.
var helpers
var manager
var host
var fixture := ""
var port := 0
var failed := 0
var passed := 0
var progress: Array[String] = []
const OLD := "0.3.0-rc.23"
const NEW := "0.3.0-rc.24"

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, ok: bool) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func until(ready: Callable) -> void:
	var deadline := Time.get_ticks_msec() + 120000
	while not ready.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	check("operation completed within deadline", ready.call())

func offer(version: String) -> void:
	var asset := "docket-%s-%s.tar.gz" % [version, MarketplaceClient.resolve_platform_target()]
	var file := FileAccess.open(fixture.path_join("releases.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify([{"tag_name": "docket-v" + version, "assets": [{"name": asset,
		"browser_download_url": "http://127.0.0.1:%d/%s" % [port, asset]}]}]))
	file.close()

func _run() -> void:
	helpers = load("res://test/marketplace_test_helpers.gd").new(self)
	fixture = OS.get_environment("MINERVA_REQUIRED_DOCKET_FIXTURE")
	manager = await helpers.bootstrap_plugin_manager(true)
	if manager == null or fixture.is_empty():
		check("actual manager and explicit release fixture exist", false)
		await finish()
		return
	host = root.get_node("SingletonObject").docket_host
	check("fresh profile has no Docket registration", not manager.get_db().has_plugin("docket"))
	check("unavailable message names required plugin and recovery", host.availability_message().contains("required Docket") and host.availability_message().contains("Install required plugins"))
	host.state_changed.connect(func(_state: String): progress.append(host.availability_message()))
	port = helpers.random_high_port()
	if not await helpers.start_http_server(fixture, port):
		check("local release server started", false)
		await finish()
		return
	RequiredPlugins.releases_url = "http://127.0.0.1:%d/releases.json" % port
	offer(OLD)
	var queued: Dictionary = await RequiredPlugins.ensure(manager)
	check("launch pickup queues Docket from official-format release", queued.has("docket"))
	if not queued.has("docket"):
		await finish()
		return
	await until(func(): return queued.docket.state == queued.docket.State.DONE and host.state == "ready")
	var definition = manager.get_db().get_by_id("docket")
	check("first install is marketplace, autostarts and enables updates", definition != null and definition.version == OLD and definition.autostart and definition.auto_update and definition.install_lane == PluginDefinition.LANE_MARKETPLACE)
	check("starting was visible and ready clears the message", progress.any(func(text: String): return text.contains("Docket is starting")) and host.availability_message().is_empty())
	if definition == null or host.state != "ready":
		await finish()
		return
	var before = manager.get_connection("docket")
	var created: Dictionary = await host.call_tool("docket_create", {"project": host.master_project().name, "type": "kb", "title": "Required update marker"})
	check("real child wrote marker", not str(created.get("id", "")).is_empty())
	await host.call_tool("docket_flush", {"project": host.master_project().name})
	offer(NEW)
	var updates: Dictionary = await load("res://Scripts/Services/Plugins/PluginAutoUpdater.gd").run(manager, "http://127.0.0.1:%d/registry.json" % port)
	check("existing auto-updater queues newer required release", updates.has("docket"))
	if updates.has("docket"):
		await until(func(): return updates.docket.state == updates.docket.State.DONE and host.state == "ready")
	definition = manager.get_db().get_by_id("docket")
	check("new version committed with restarted actual child", definition.version == NEW and definition.state == PluginDefinition.State.RUNNING and manager.get_connection("docket") != before)
	var recovered: Dictionary = await host.call_tool("docket_get", {"project": host.master_project().name, "id": created.get("id", "")})
	check("update preserves real master data", recovered.get("title") == "Required update marker")
	check("required Docket cannot be removed", (await manager.remove_plugin("docket")).has("error"))
	await finish()

func finish() -> void:
	if manager != null and manager.get_db().has_plugin("docket"):
		await manager.stop_plugin("docket", true)
	if helpers != null:
		helpers.teardown()
	RequiredPlugins.releases_url = "https://api.github.com/repos/%s/releases" % RequiredPlugins.REPO
	if failed == 0:
		print("REAL_REQUIRED_DOCKET_COMPLETE")
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)
