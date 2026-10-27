extends Node
## Read-only observer for the Tooling e2e's real GUI. Python owns the HTTP driver.
const PRIVATE: String = "/tmp/live-tooling/"
var singleton
var spawned_versions: Array[String] = []

func _ready() -> void:
	_setup.call_deferred()

func _write(name_: String, value: Dictionary) -> void:
	var file: FileAccess = FileAccess.open(PRIVATE + name_ + ".json", FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()

func _setup() -> void:
	singleton = get_tree().root.get_node("SingletonObject")
	var until: int = Time.get_ticks_msec() + 180000
	while singleton.plugin_manager == null and Time.get_ticks_msec() < until:
		await get_tree().process_frame
	if singleton.plugin_manager == null:
		_write("stop", {"reason": "plugin_manager_missing"})
		return
	singleton.plugin_manager.plugin_started.connect(_plugin_started)
	while Time.get_ticks_msec() < until:
		if singleton.docket_host != null and singleton.docket_host.state == "ready":
			break
		await get_tree().create_timer(0.1).timeout
	if singleton.docket_host == null or singleton.docket_host.state != "ready":
		_write("stop", {"reason": "docket_host_not_ready"})
		return
	var core = get_tree().root.get_node("Core")
	var authenticated: bool = await core.start("wss://www.turnrock.ai:27500/connect",
		"https://www.turnrock.ai:4040/v1/login", OS.get_environment("MINERVA_TEST_USERNAME"),
		OS.get_environment("MINERVA_TEST_PASSWORD"), false)
	if not authenticated or not core.registered:
		_write("stop", {"reason": "authentication_failed"})
		return
	singleton.preferences_popup = get_tree().current_scene.get_node("PreferencesPopup")
	await get_tree().current_scene.find_child("ProjectManagement", true, false)._new_project()
	singleton.mcp_manager.connect_minerva_server()
	if not singleton.mcp_manager.is_http_server_running():
		if singleton.mcp_manager.start_http_server(9315) != OK:
			_write("stop", {"reason": "mcp_missing"})
			return
	_write("ready", {"port": singleton.mcp_manager.get_http_server_port()})

func _plugin_started(id: String) -> void:
	if id == "docket":
		spawned_versions.append(str(singleton.plugin_manager.get_plugin_status(id).get("version", "")))

func _process(_delta: float) -> void:
	if singleton == null or singleton.mcp_manager == null or singleton.mcp_manager.minerva_server == null:
		return
	var schemas: Array[Dictionary] = singleton.mcp_manager.minerva_server.tool_budget_manager.get_active_schemas()
	var active: Array[String] = []
	for schema: Dictionary in schemas:
		active.append(str(schema.get("name", "")))
	active.sort()
	_write("observed", {"active": active, "started_versions": spawned_versions})
