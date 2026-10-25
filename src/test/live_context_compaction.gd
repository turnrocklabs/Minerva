extends Node
## Observer for the single live Context e2e; sends are driven over HTTP MCP.
const PRIVATE: String = "/tmp/live-context/"
const MODEL: String = "glm-5.3-flash"
var core
var singleton
var history
var busy: bool = false
var sequence: int = 0
var usage: Dictionary = {}
var jobs: Dictionary = {}
var times: Dictionary = {}
var summary_glm: bool = false
var glm_topic: String = ""
var prior_entries: Array[String] = []
var compactions: Array[Dictionary] = []
var saw_activity: bool = false
var dialog_seen: bool = false
var last_sample_ms: int = 0

func _ready() -> void:
	_setup.call_deferred()

func _write(name_: String, value: Dictionary) -> void:
	var file: FileAccess = FileAccess.open(PRIVATE + name_ + ".json", FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()

func _setup() -> void:
	await get_tree().process_frame
	singleton = get_tree().root.get_node("SingletonObject")
	core = get_tree().root.get_node("Core")
	var main: Node = get_tree().current_scene
	singleton.preferences_popup = main.get_node("PreferencesPopup")
	var until: int = Time.get_ticks_msec() + 150000
	while Time.get_ticks_msec() < until:
		if singleton.docket_host != null and singleton.docket_host.state in ["ready", "degraded"] \
				and singleton.plugin_manager.get_plugin_status("docket").get("running", false):
			break
		await get_tree().create_timer(0.25).timeout
	if singleton.docket_host == null or not singleton.plugin_manager.get_plugin_status("docket").get("running", false):
		_write("stop", {"reason": "policy_unavailable"})
		get_tree().quit(3)
		return
	singleton.set_provider_enabled(singleton.provider_from_key("turnrock"), true)
	var authenticated: bool = await core.start("wss://www.turnrock.ai:27500/connect",
		"https://www.turnrock.ai:4040/v1/login", OS.get_environment("MINERVA_TEST_USERNAME"),
		OS.get_environment("MINERVA_TEST_PASSWORD"), false)
	if not authenticated or not core.registered:
		_write("stop", {"reason": "authentication_failed"})
		get_tree().quit(4)
		return
	await core.fetch_services(false)
	var async_advertised: bool = false
	var max_output: Dictionary = {}
	for service in core.services:
		if service.client_id == "model-chat":
			for action in service.actions:
				async_advertised = async_advertised or action.topic == "model-chat/jobs/submit"
				if action.name.to_lower() == MODEL:
					glm_topic = action.topic
					var rule: Dictionary = action.model_metadata.get("generation_settings", {}).get("parameters", {}).get("max_tokens", {})
					for key: String in ["minimum", "maximum", "default", "default_source"]:
						if rule.has(key):
							max_output[key] = rule[key]
	var catalog: GDScript = load("res://Scripts/Services/Providers/Core/CoreModelCatalog.gd")
	var selected: Dictionary = {}
	for entry: Dictionary in catalog.list_models(core, singleton):
		if entry.model_spec.get("service_client_id") == "model-chat" and entry.model_name.to_lower() == MODEL and entry.available:
			selected = entry
	if selected.is_empty() or not async_advertised:
		_write("stop", {"reason": "glm_or_async_unavailable"})
		get_tree().quit(5)
		return
	await main.find_child("ProjectManagement", true, false)._new_project()
	core.client.message_received.connect(_wire)
	singleton.mcp_manager.connect_minerva_server()
	if not singleton.mcp_manager.is_http_server_running():
		if singleton.mcp_manager.start_http_server(9315) != OK:
			_write("stop", {"reason": "mcp_unavailable"})
			get_tree().quit(6)
			return
	_write("ready", {"model_spec": selected.model_spec, "max_output": max_output,
		"async_advertised": async_advertised, "port": singleton.mcp_manager.get_http_server_port()})

func _nodes(root: Node) -> Array[Node]:
	var found: Array[Node] = [root]
	for child: Node in root.get_children():
		found.append_array(_nodes(child))
	return found

func _input_estimate() -> int:
	# This is the production owner, never a parallel test estimator.
	return singleton.Chats.estimate_agent_context_size(history)

func _ledger_ids() -> Array[String]:
	var ids: Array[String] = []
	for entry in singleton.ledger_manager.get_entries_for_chat(history.HistoryId):
		ids.append(entry.id)
	return ids

func _sample() -> Dictionary:
	if history == null:
		return {}
	saw_activity = saw_activity or history.is_request_active
	for node: Node in _nodes(get_tree().current_scene):
		if node is ConfirmationDialog and node.visible and node.title == "Large Context":
			dialog_seen = true
	for id: String in _ledger_ids():
		if id in prior_entries:
			continue
		prior_entries.append(id)
		var linked: bool = false
		var summary: bool = false
		var entry = singleton.ledger_manager.get_entry(id)
		for item in history.HistoryItemList:
			for note: String in item.InjectedNotes:
				linked = linked or ("[Ledger:%s]" % id) in note
				summary = summary or (entry != null and not entry.summary_text.is_empty() and entry.summary_text in note)
		compactions.append({"at": Time.get_unix_time_from_system(), "input_after": _input_estimate(),
			"ledger_id": id, "ledger_exists": singleton.ledger_manager.get_entry(id) != null,
			"summary_present": summary, "ledger_link_present": linked, "summarizer_glm": summary_glm})
	var complete: bool = false
	var reply: Dictionary = {}
	var item_script = load("res://Scripts/Models/ChatHistoryItem.gd")
	if saw_activity and not history.is_request_active and not history.HistoryItemList.is_empty():
		var item = history.HistoryItemList[-1]
		complete = item.Role == item_script.ChatRole.MODEL and (item.Complete or not item.Error.is_empty())
		if complete:
			reply = {"error": not item.Error.is_empty(), "chars": item.Message.length(), "sha256": item.Message.sha256_text()}
	return {"input_estimate": _input_estimate(), "output_reserve": 4000, "total_budget": _input_estimate() + 4000,
		"complete": complete, "reply": reply, "usage": usage, "job_ids": jobs.keys(), "times": times,
		"compactions": compactions, "large_context_dialog": dialog_seen}

func _process(_delta: float) -> void:
	if history != null and Time.get_ticks_msec() - last_sample_ms >= 100:
		last_sample_ms = Time.get_ticks_msec()
		_sample()
	if busy or not FileAccess.file_exists(PRIVATE + "command.json"):
		return
	var command: Variant = JSON.parse_string(FileAccess.get_file_as_string(PRIVATE + "command.json"))
	if command is Dictionary and int(command.get("sequence", 0)) > sequence:
		busy = true
		sequence = int(command.sequence)
		_command.call_deferred(command)

func _command(command: Dictionary) -> void:
	var result: Dictionary = {}
	if command.action == "bind":
		for candidate in singleton.ChatList:
			if candidate.HistoryId == command.chat_id:
				history = candidate
				singleton.Chats.current_tab = singleton.Chats.get_tab_count() - 1
		result = {"bound": history != null, "async_supported": history != null and history.provider.supports_async_chat()}
	elif command.action == "settings":
		var dialog = singleton.Chats.get_node("%AISettings")
		dialog.load_current_chat_settings()
		dialog.popup_centered()
		await get_tree().process_frame
		await get_tree().process_frame
		var model_group: Node = dialog.get_node("%ModelSettings")
		var tab: Node = model_group
		while tab.get_parent() != null and not tab.get_parent() is TabContainer:
			tab = tab.get_parent()
		if tab.get_parent() is TabContainer:
			tab.get_parent().current_tab = tab.get_index()
		await get_tree().process_frame
		var values: Dictionary = {}
		for node: Node in _nodes(model_group):
			if node is Label and node.text in ["Context window", "Auto-compact at", "Max output tokens (per turn)"]:
				var spins: Array[SpinBox] = []
				for control: Node in _nodes(node.get_parent()):
					if control is SpinBox:
						spins.append(control)
				if spins.size() == 1:
					values[node.text] = spins[0].value
			if node is Label and node.text == "Context":
				result["context_heading"] = true
		var reasoning: Node = dialog.get_node("%ModelReasoningSettings")
		result["reasoning_low"] = reasoning.get_node("Selection").text == "Low"
		result["values"] = values
		result["visible"] = dialog.visible
		dialog.hide()
	elif command.action == "begin":
		usage = {}
		jobs = {}
		times = {"begin": Time.get_unix_time_from_system()}
		saw_activity = false
		summary_glm = false
		result = _sample()
	elif command.action == "state":
		result = _sample()
	elif command.action == "local_safety":
		var local_script = load("res://Scripts/Services/Providers/LocalProvider.gd")
		var provider = local_script.new()
		result = {"default_num_ctx": provider.default_context, "effective_num_ctx": provider.get_effective_context()}
		provider.BASE_URL = OS.get_environment("MINERVA_LIVE_LOCAL_URL")
		await provider.generate_content([{"role": "user", "content": "hi"}])
		provider.free()
	_write("answer", {"sequence": sequence, "result": result})
	busy = false

func _wire(message: Dictionary) -> void:
	var topic: String = str(message.get("topic", ""))
	if not topic.begins_with("model-chat/"):
		return
	var params: Dictionary = message.get("params", {})
	var body: Dictionary = params.get("result", {}) if params.get("result") is Dictionary else {}
	var code: String = str(params.get("code", params.get("error_code", body.get("error_code", ""))))
	if code in ["BACKEND_UNAVAILABLE", "NO_NODES_AVAILABLE", "RESOURCE_UNKNOWN", "ASYNC_PEERS_UNCONFIGURED"]:
		_write("stop", {"reason": "node_unavailable", "code": code})
		get_tree().quit(7)
	if topic == "model-chat/jobs/submit" and body.has("job_id"):
		jobs[str(body.job_id)] = true
		times["accepted"] = Time.get_unix_time_from_system()
	if topic == "model-chat/jobs/events":
		for event: Variant in body.get("events", []):
			if event is Dictionary:
				if not times.has("first_event"):
					times["first_event"] = Time.get_unix_time_from_system()
				if event.get("channel") == "answer" and not times.has("first_answer"):
					times["first_answer"] = Time.get_unix_time_from_system()
		if body.get("status", {}).get("state") in ["completed", "failed", "cancelled", "stalled", "abandoned", "interrupted"]:
			times["terminal"] = Time.get_unix_time_from_system()
	var response: Dictionary = body.get("response", body) if body.get("response", body) is Dictionary else {}
	if topic == glm_topic and response.get("choices") is Array:
		# Summarization uses the discovered GLM action; normal turns use jobs.
		summary_glm = not response.has("model") or str(response.model).to_lower() == MODEL
	if topic == "model-chat/jobs/result" and response.get("usage") is Dictionary:
		for key: String in ["prompt_tokens", "completion_tokens", "reasoning_tokens"]:
			if response.usage.get(key) is int or response.usage.get(key) is float:
				usage[key] = int(response.usage[key])
		var details: Dictionary = response.usage.get("completion_tokens_details", {})
		if details.get("reasoning_tokens") is int or details.get("reasoning_tokens") is float:
			usage["reasoning_tokens"] = int(details.reasoning_tokens)
