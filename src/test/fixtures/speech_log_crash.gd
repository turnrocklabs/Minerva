extends SceneTree
## Disposable child process: pause real file I/O at the atomic replacement edge.


func marker(directory: String, phase: String, unheard: int) -> void:
	var file: FileAccess = FileAccess.open(directory.path_join("checkpoint.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"phase": phase, "unheard": unheard}))
	file.flush()
	file.close()


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 2 or args[1] not in ["before", "after", "active"]:
		quit(2)
		return
	var directory: String = args[0]
	var phase: String = args[1]
	var Log = load("res://Scripts/Services/Voice/SpeechLog.gd")
	var Atomic = load("res://Scripts/Services/Plugins/AtomicFile.gd")
	if phase == "active":
		var config = load("res://Scripts/Services/Voice/VoiceConfig.gd").new()
		config.output_device = "plugin:crash_fixture:speaker"
		var policy = load("res://Scripts/Services/Plugins/PluginPolicy.gd").new(null, null, false)
		policy.grant_capability("crash_fixture", "host.audio")
		var devices = load("res://Scripts/Services/Plugins/PluginAudioDevices.gd").new(config, policy,
			func(_plugin: String, _event: String, _payload: Dictionary) -> Error: return OK,
			func() -> void: await process_frame, func() -> String: return AudioServer.output_device,
			func(_device: String) -> void: pass, func(_message: String) -> void: pass)
		devices.handle("crash_fixture", {"op": "register", "device_id": "speaker", "label": "Crash fixture", "output": true})
		devices.handle("crash_fixture", {"op": "availability", "device_id": "speaker", "available": true})
		var active_store = Log.new(directory)
		var delivery = load("res://Scripts/Services/Voice/SpeechDelivery.gd").new(active_store, devices, null, Callable(),
			func(_message: String) -> void: pass, func(_delivery) -> void: pass)
		var operation = load("res://Scripts/Services/Voice/SpeechOperation.gd").new()
		delivery.prepare(operation, null, config, "active before crash", {}, true)
		var unheard: int = delivery.state().unheard
		marker(directory, phase, unheard)
		OS.delay_msec(60000)
		quit(3)
		return
	# The injected edge pauses only file transport, with the same flushed temp
	# file and real native/Unix AtomicFile.replace used by production writes.
	var writer := func(path: String, text: String) -> bool:
		var file: FileAccess = FileAccess.open(path + ".tmp", FileAccess.WRITE)
		if file == null:
			return false
		var written: bool = file.store_string(text)
		file.flush()
		file.close()
		if not written:
			return false
		if phase == "before":
			marker(directory, phase, 1)
			OS.delay_msec(60000)
		var replaced: bool = Atomic.replace(path + ".tmp", path)
		if phase == "after" and replaced:
			marker(directory, phase, 0)
			OS.delay_msec(60000)
		return replaced
	var store = Log.new(directory, writer)
	store.update_record("speech_1", {"heard": true, "text": "committed after replace"})
	quit(3)
