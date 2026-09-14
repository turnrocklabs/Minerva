extends SceneTree
## Opt-in production bridge probe. It never opens a microphone or contacts Core.

const OPT_IN := "MINERVA_TEST_PACKAGED_VOICE_BRIDGE"
const START_TIMEOUT_MSEC := 45000
const STOP_TIMEOUT_MSEC := 10000

var passed := 0
var failed := 0


func _init() -> void:
	await process_frame
	if OS.get_environment(OPT_IN) != "1":
		print("SKIP: set %s=1 to run the packaged voice production bridge" % OPT_IN)
		quit(0)
		return

	var BuiltinVoice = load("res://Scripts/Services/Voice/BuiltinVoicePlugin.gd")
	var runtime_dir: String = BuiltinVoice.runtime_directory()
	var python_name := "python.exe" if OS.get_name() == "Windows" else "bin/python3"
	check("opt-in runtime exists", not runtime_dir.is_empty() and FileAccess.file_exists(runtime_dir.path_join(python_name)))
	if failed:
		_finish()
		return

	var singleton = root.get_node_or_null("SingletonObject")
	var manager = singleton.get("plugin_manager") if singleton != null else null
	check("production PluginManager is available", manager != null)
	if failed:
		_finish()
		return

	var VoiceFeature = load("res://Scripts/Services/Voice/VoiceFeatureControl.gd")
	VoiceFeature.set_enabled(true)
	manager.get_db().register_builtin()
	var Adapter = load("res://Scripts/Services/Voice/BundledVoiceDetectorAdapter.gd")
	var adapter = Adapter.new()
	root.add_child(adapter)
	var state := {"connected": false, "failure": ""}
	adapter.connected.connect(func(): state.connected = true)
	adapter.disconnected.connect(func(): state.connected = false)
	adapter.start_failed.connect(func(reason: String): state.failure = reason)
	adapter.start({"vad_silence_ms": 1000})
	await _wait_until(func(): return state.connected or not state.failure.is_empty(), START_TIMEOUT_MSEC)
	check("production manager and adapter reach worker readiness", state.connected and state.failure.is_empty() and manager.get_connection(BuiltinVoice.ID) != null)

	if state.connected:
		var pcm := PackedByteArray()
		pcm.resize(1024)
		for sample in range(512):
			pcm.encode_s16(sample * 2, 1200 if sample % 2 == 0 else -1200)
		var all_enqueued := true
		for _chunk in range(8):
			if adapter.send_audio(pcm) != OK:
				all_enqueued = false
				break
		for _frame in range(30):
			await process_frame
		check("bounded synthetic PCM remains locally enqueued on a live WebSocket", all_enqueued and state.connected)

	var connection = manager.get_connection(BuiltinVoice.ID)
	var subprocess = connection._subprocess if connection != null else null
	adapter.stop()
	await _wait_until(func(): return manager.get_connection(BuiltinVoice.ID) == null and (not is_instance_valid(subprocess) or not subprocess.is_running()), STOP_TIMEOUT_MSEC)
	check("adapter stop releases its manager connection and owned process", manager.get_connection(BuiltinVoice.ID) == null and (not is_instance_valid(subprocess) or not subprocess.is_running()))
	adapter.free()
	_finish()


func _wait_until(predicate: Callable, timeout_msec: int) -> void:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame


func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: " + label)
	else:
		failed += 1
		printerr("FAIL: " + label)


func _finish() -> void:
	print("Voice Support production bridge: %d passed, %d failed" % [passed, failed])
	quit(1 if failed else 0)
