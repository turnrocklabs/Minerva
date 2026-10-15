extends SceneTree
## Real plugin/stdio/LAN fixtures are driven by the paired Rust integration test.

var _so: Node
var _connection: RefCounted
var _ensure_calls: int = 0
var _captured: bool = false
var _startup_selection_preserved: bool = false
var _mode: String

func _initialize() -> void:
	_run.call_deferred()

func _capability(plugin: String, capability: String, args: Dictionary) -> Dictionary:
	if capability == "host.chat.input" and args.get("op") == "ensure_chat":
		_ensure_calls += 1
	var broker = _so.plugin_capability_broker
	var result: Dictionary = await broker.dispatch(plugin, capability, args)
	if capability == "host.audio" and args.get("op") == "input_chunk" and result.get("success", false):
		_captured = broker.audio_input._active != null and broker.audio_input._active.bytes >= 640
	return result

func _run() -> void:
	await process_frame
	_so = root.get_node("SingletonObject")
	_mode = OS.get_environment("SMART_REMOTE_SETUP_MODE")
	var deadline: int = Time.get_ticks_msec() + 15000
	while _so.plugin_capability_broker == null and Time.get_ticks_msec() < deadline:
		await process_frame
	var saved = _so.get_voice_config()
	var expected: String = "plugin:smart_remote:remote_a4cf12b03e5d"
	_startup_selection_preserved = saved.input_device == expected and saved.output_device == expected
	var render = load("res://test/helpers/chat_host_render_fixture.gd").new()
	render.install(_so)
	var chat_scene: Node = load("res://Scenes/Chat.tscn").instantiate()
	root.add_child(chat_scene)
	await process_frame
	var pane = chat_scene.find_child("tcChats", true, false)
	pane.clear_all_chats()
	_so.ChatList.clear()
	_so.get_voice_config().stt_transport = 0 # Buffered: the test never sends audio to a service.
	var definition_type = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	var definition = definition_type.from_manifest(OS.get_environment("SMART_REMOTE_PLUGIN_ROOT").path_join("manifest.json"))
	definition.state = definition_type.State.RUNNING
	var manager = _so.plugin_manager
	manager.get_db()._plugins[definition.id] = definition
	for capability: String in definition.host_capabilities:
		_so.plugin_policy.grant_capability(definition.id, capability)
	for event: String in definition.host_events:
		_so.plugin_policy.grant_capability(definition.id, "host_event:" + event)
	_connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd").new(definition.id)
	_connection.plugin_id = definition.id
	_connection.capability_request_handler = _capability
	_connection.configure_stdio(OS.get_environment("SMART_REMOTE_PLUGIN_BIN"), PackedStringArray([
		"--data-dir", OS.get_environment("SMART_REMOTE_SETUP_DATA"), "--bind", "127.0.0.1", "--port", OS.get_environment("SMART_REMOTE_SETUP_PORT"), "--no-mdns"]))
	manager._runtime[definition.id] = {"connection": _connection}
	if await _connection.connect_to_server() != OK:
		quit(1)
		return
	print("SETUP_HOST_READY")
	deadline = Time.get_ticks_msec() + 15000
	var passed: bool = false
	while Time.get_ticks_msec() < deadline:
		if _mode == "notification" and FileAccess.file_exists(OS.get_environment("SMART_REMOTE_SETUP_READY")):
			passed = await _completion_tone()
			break
		if _mode == "audio" and FileAccess.file_exists(OS.get_environment("SMART_REMOTE_SETUP_READY")):
			passed = _audio_picker()
			break
		if _mode == "ptt" and _captured:
			passed = _so.ChatList.size() == 1 and _ensure_calls == 1 \
				and pane.active_chat_payload().get("chat_id") == _so.plugin_capability_broker.audio_input._active.chat_id
			break
		await process_frame
	_connection.disconnect_from_server()
	manager._runtime.erase(definition.id)
	manager.get_db()._plugins.erase(definition.id)
	chat_scene.free()
	render.restore()
	print("SETUP_PASS" if passed else "SETUP_FAIL")
	quit(0 if passed else 1)

func _completion_tone() -> bool:
	var devices = _so.plugin_audio_devices
	var player: AudioStreamPlayer = _so.chat_notification_player
	var key: String = "plugin:smart_remote:remote_a4cf12b03e5d"
	if not devices.select("output", key).get("success", false):
		return false
	var speech = devices.speech_output(player, {}, true)
	var opened: Dictionary = speech.begin("pcm_s16le", 16000, 1.0)
	if not opened.success or not speech.append(PackedByteArray([0, 0, 0, 0])):
		return false
	speech.end()
	var speech_id: int = devices.output_stream_id(key)
	_so.play_chat_notification()
	_so.play_chat_notification()
	await create_timer(0.4).timeout
	if player.playing or devices.output_stream_id(key) != speech_id:
		return false
	var queued: FileAccess = FileAccess.open(OS.get_environment("SMART_REMOTE_SETUP_READY") + ".queued", FileAccess.WRITE)
	queued.store_string("queued")
	queued.close()
	var deadline: int = Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline and devices.output_stream_id(key) in [0, speech_id]:
		await process_frame
	if devices.output_stream_id(key) in [0, speech_id] or player.playing:
		return false
	while devices.output_busy(key) and Time.get_ticks_msec() < deadline:
		await process_frame
	await create_timer(0.2).timeout
	if devices.output_busy(key) or player.playing:
		return false
	if not devices.select("output", "os:" + AudioServer.output_device).get("success", false):
		return false
	await _so.play_chat_notification()
	var passed: bool = player.playing
	player.stop()
	print("NOTIFICATION_REMOTE_QUEUE_AND_OS_PASS" if passed else "NOTIFICATION_OS_FAIL")
	return passed

func _audio_picker() -> bool:
	# Detached real preferences retain the exact production callbacks without
	# launching unrelated dialogs, auth setup or platform audio capture.
	var popup = load("res://Scripts/UI/Views/PreferencesPopup.gd").new()
	popup.microphones = OptionButton.new()
	popup.output_device_button = OptionButton.new()
	popup._voice_input_devices = OptionButton.new()
	popup._voice_output_devices = OptionButton.new()
	var devices = _so.plugin_audio_devices
	devices.changed.connect(popup._refresh_voice_devices)
	popup.set_microphone_option_menu(null)
	popup.populate_output_devices_button()
	var key: String = "plugin:smart_remote:remote_a4cf12b03e5d"
	var input_index: int = -1
	var output_index: int = -1
	for index: int in range(popup.microphones.item_count):
		if popup.microphones.get_item_metadata(index) == key:
			input_index = index
	for index: int in range(popup.output_device_button.item_count):
		if popup.output_device_button.get_item_metadata(index) == key:
			output_index = index
	var passed: bool = input_index >= 0 and output_index >= 0
	if passed:
		popup._on_microphones_item_selected(input_index)
		popup._on_output_device_button_item_selected(output_index)
		_so._restore_audio_devices()
		var restored = load("res://Scripts/Services/Voice/VoiceConfig.gd").new()
		restored.load_from_config()
		passed = _startup_selection_preserved and restored.input_device == key and restored.output_device == key 			and devices.selected_input() == key and devices.selected_output() == key \
			and popup._voice_input_devices.get_item_metadata(popup._voice_input_devices.selected) == key \
			and popup._voice_output_devices.get_item_metadata(popup._voice_output_devices.selected) == key
	devices.changed.disconnect(popup._refresh_voice_devices)
	popup.microphones.free()
	popup.output_device_button.free()
	popup._voice_input_devices.free()
	popup._voice_output_devices.free()
	popup.free()
	return passed
