extends Node
## The GUI's observation edge. Dependencies enter _serve/_snapshot explicitly;
## only setup resolves the application's autoloads. No Core login or model turn.
var private_dir: String = OS.get_environment("MINERVA_SEED_PRIVATE")
var sequence: int = 0
var busy: bool = false
var host: DocketHost
# Concrete manager scripts depend on autoload identifiers unavailable to
# --script/--check-only. Resolve these existing objects at runtime instead.
var manager: Object
var plugins: Object

func _ready() -> void:
	_setup.call_deferred()

func _write(name_: String, value: Dictionary) -> void:
	var file: FileAccess = FileAccess.open(private_dir.path_join(name_ + ".json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()

func _setup() -> void:
	var singleton: Node = get_tree().root.get_node("SingletonObject")
	var until: int = Time.get_ticks_msec() + 180000
	while Time.get_ticks_msec() < until:
		host = singleton.get("docket_host")
		manager = singleton.get("mcp_manager")
		plugins = singleton.get("plugin_manager")
		if host != null and manager != null and plugins != null \
				and host.state in ["ready", "degraded", "failed"] \
				and plugins.call("get_plugin_status", "docket").get("running", false):
			break
		await get_tree().create_timer(0.1).timeout
	if host == null or manager == null or plugins == null or not host.state in ["ready", "degraded", "failed"]:
		_write("stop", {"reason": "docket_start_deadline"})
		return
	manager.call("connect_minerva_server")
	if not bool(manager.call("is_http_server_running")) and int(manager.call("start_http_server", 9315)) != OK:
		_write("stop", {"reason": "mcp_start_failed"})
		return
	_write("ready", {"port": int(manager.call("get_http_server_port")), "state": host.state,
		"attached": bool(plugins.call("is_attached", "docket"))})

func _process(_delta: float) -> void:
	if busy or host == null or not FileAccess.file_exists(private_dir.path_join("command.json")):
		return
	var command: Variant = JSON.parse_string(FileAccess.get_file_as_string(private_dir.path_join("command.json")))
	if command is Dictionary and int(command.get("sequence", 0)) > sequence:
		sequence = int(command.sequence)
		busy = true
		_serve.call_deferred(command, host, plugins)

func _serve(command: Dictionary, docket_host: DocketHost, plugin_manager: Object) -> void:
	var result: Dictionary
	if command.action == "reconnect":
		result = await plugin_manager.call("restart_plugin", "docket")
		var until: int = Time.get_ticks_msec() + 60000
		while docket_host.state in ["starting", "unavailable"] and Time.get_ticks_msec() < until:
			await get_tree().create_timer(0.1).timeout
	else:
		result = await _snapshot(docket_host)
	_write("answer", {"sequence": sequence, "result": result})
	busy = false

func _snapshot(docket_host: DocketHost) -> Dictionary:
	var prompt: Dictionary = await docket_host.system_prompt("agentic-base")
	return {"attached": docket_host.is_attached(), "state": docket_host.state, "master_path": docket_host.master_path,
		"expected_master_path": ProjectSettings.globalize_path("user://master.dct"),
		"problems": docket_host.problems.duplicate(), "master_report": docket_host.master_report.duplicate(true),
		"prompt": prompt, "chat_prompt_readable": not prompt.has("error") and not docket_host.master_project().is_empty()}
