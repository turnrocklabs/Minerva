extends SceneTree
## Runtime-loaded services allow --script to initialize autoloads first.
var _passed: int = 0
var _failed: int = 0
var _completed: bool = false


func _init() -> void:
	await process_frame
	await process_frame
	await _run()
	check("whole persistence scenario completed", _completed)
	print("=== Results: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed else 0)


func check(label: String, condition: bool) -> void:
	if condition:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		printerr("FAIL: " + label)


func fields(topic: String = "build", producer: String = "probe") -> Dictionary:
	return {"producer": producer, "topic": topic, "text": "Build complete\n日本語", "original_text": "Original reply",
		"summary": "Build complete", "origin": {"plugin_id": producer, "chat_id": "fixture_chat", "send_id": 7},
		"device": "plugin:probe:speaker", "voice_id": "fixture_voice", "voice_name": "Fixture Voice", "backend": "kokoro",
		"volume": 0.5, "error": "", "fallback_reason": ""}


func _run() -> void:
	var Log = load("res://Scripts/Services/Voice/SpeechLog.gd")
	var Delivery = load("res://Scripts/Services/Voice/SpeechDelivery.gd")
	var directory: String = ProjectSettings.globalize_path("user://speech-records-" + str(Time.get_ticks_usec()))
	var store = Log.new(directory)
	var fixture_file: FileAccess = FileAccess.open("res://test/fixtures/speech-log-bytes.json", FileAccess.READ)
	var fixture: Dictionary = JSON.parse_string(fixture_file.get_as_text())
	fixture_file.close()
	check("fixed payload bytes include sample extremes and canonical base64", Marshalls.base64_to_raw(fixture.base64) == PackedByteArray(fixture.pcm))
	var admission: Dictionary = fields()
	admission.text = fixture.text
	admission.summary = fixture.summary
	var first: Dictionary = store.admit(admission)
	check("admission saves original UTF-8 text and full voice parameters", first.success and first.record.text == "Build complete\n日本語" and first.record.volume == 0.5)
	var file: FileAccess = FileAccess.open(directory.path_join(first.record.log_id + ".json"), FileAccess.READ)
	var actual: PackedByteArray = file.get_buffer(file.get_length())
	file.close()
	check("persisted bytes preserve UTF-8 newline through JSON round trip", JSON.parse_string(actual.get_string_from_utf8()).text.to_utf8_buffer() == fields().text.to_utf8_buffer())
	var second: Dictionary = store.admit(fields())
	check("same producer/topic derives superseded without older-file rewrite", store.get_record(first.record.log_id).superseded and not second.record.superseded)
	var reopened = Log.new(directory)
	check("restart at new admission boundary has identical superseded state", reopened.get_record(first.record.log_id).superseded and reopened.list_records().size() == 2)
	var deleted: Dictionary = reopened.delete_record(second.record.log_id)
	check("explicit deletion hides content and preserves derived supersede", deleted.success and reopened.get_record(second.record.log_id).is_empty() and reopened.get_record(first.record.log_id).superseded)
	file = FileAccess.open(directory.path_join(second.record.log_id + ".json"), FileAccess.READ)
	var tombstone: Dictionary = JSON.parse_string(file.get_as_text())
	file.close()
	check("tombstone stores only admission metadata", tombstone.deleted and not tombstone.has("text") and not tombstone.has("backend") and not tombstone.has("origin"))
	var third: Dictionary = reopened.admit(fields("other"))
	var exemptions: Array[String] = [str(third.record.log_id)]
	var active: Dictionary = reopened.admit(fields("other"), exemptions)
	check("playing item is exempt from new admission supersede", not reopened.get_record(third.record.log_id).superseded and not active.record.superseded)
	reopened = Log.new(directory)
	check("active-item exemption survives restart", not reopened.get_record(third.record.log_id).superseded)
	var fourth: Dictionary = reopened.admit(fields("other"))
	check("later topic admission supersedes the formerly playing item", reopened.get_record(third.record.log_id).superseded and reopened.get_record(active.record.log_id).superseded and not fourth.record.superseded)
	var producer: Dictionary = reopened.admit(fields("other", "another"))
	check("producer producers cannot supersede each other", not reopened.get_record(fourth.record.log_id).superseded and not producer.record.superseded)
	var marked: Dictionary = reopened.update_record(fourth.record.log_id, {"heard": true})
	check("heard flag persists independently of playback attempts", marked.success and Log.new(directory).get_record(fourth.record.log_id).heard)
	var service = Delivery.new(reopened, null, null, Callable(), func(_message: String) -> void: pass, func(_delivery) -> void: pass)
	check("missed count derives from heard/superseded records", service.state().unheard == 1)
	var summarized: Dictionary = service.save_spoken(producer.record.log_id, "Final spoken summary", "summary fallback")
	check("saved replay text and default display summary follow final synthesis text", summarized.success and reopened.get_record(producer.record.log_id).text == "Final spoken summary" and reopened.get_record(producer.record.log_id).summary == "Final spoken summary")
	var list: Dictionary = await service.handle({"op": "list", "offset": 0.5, "limit": 20})
	check("fractional JSON paging boundary is rejected", not list.success)
	list = await service.handle(JSON.parse_string('{"op":"list","offset":0,"limit":2}'))
	check("JSON integer paging and display contract are exact", list.success and list.items.size() == 2 and list.items[0].keys().size() == 6 and list.items[0].summary == "Final spoken summary")
	var hidden: Dictionary = await service.handle({"op": "state", "log_id": producer.record.log_id}, "other_plugin")
	check("foreign endpoint content is unavailable", not hidden.success)
	var corrupt: String = directory.path_join("speech_500.json")
	file = FileAccess.open(corrupt, FileAccess.WRITE)
	file.store_string('{"version":99}')
	file.close()
	var broken = Log.new(directory)
	var continued: Dictionary = broken.admit(fields())
	check("unsupported record retained and surfaced while valid admissions continue", FileAccess.file_exists(corrupt) and not broken.errors.is_empty() and continued.success and continued.record.log_id == "speech_501")
	var broken_service = Delivery.new(broken, null, null, Callable(), func(_message: String) -> void: pass, func(_delivery) -> void: pass)
	check("corruption remains visible in state with valid records preserved", broken_service.state().success and not broken_service.state().errors.is_empty() and broken_service.state().total == reopened.list_records().size() + 1)
	var blocked: String = directory.path_join("not_a_directory")
	file = FileAccess.open(blocked, FileAccess.WRITE)
	file.store_string("collision")
	file.close()
	check("real filesystem admission failure cannot claim queued", not Log.new(blocked).admit(fields()).success)
	var unchanged: Dictionary = reopened.get_record(fourth.record.log_id)
	var blocked_record: String = directory.path_join(fourth.record.log_id + ".json.tmp")
	DirAccess.make_dir_absolute(blocked_record)
	check("failed atomic replace leaves previous durable record unchanged", not reopened.update_record(fourth.record.log_id, {"heard": false}).success and Log.new(directory)._records[fourth.record.log_id].heard == unchanged.heard)
	await _crash_recovery(Log, Delivery)
	_completed = true


func _crash_recovery(Log, Delivery) -> void:
	for phase: String in ["before", "after", "active"]:
		var directory: String = ProjectSettings.globalize_path("user://speech-kill-" + phase + "-" + str(Time.get_ticks_usec()))
		var store = Log.new(directory)
		if phase != "active":
			store.admit(fields())
		var pid: int = OS.create_process(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"--script", "res://test/fixtures/speech_log_crash.gd", "--", directory, phase])
		var checkpoint: String = directory.path_join("checkpoint.json")
		var deadline: int = Time.get_ticks_msec() + 10000
		while not FileAccess.file_exists(checkpoint) and Time.get_ticks_msec() < deadline and pid > 0 and OS.is_process_running(pid):
			await process_frame
		check("kill boundary reached: " + phase, pid > 0 and FileAccess.file_exists(checkpoint))
		if pid <= 0:
			continue
		var killed: Error = OS.kill(pid)
		check("owned child is terminated at boundary: " + phase, killed == OK)
		for frame in 3:
			await process_frame
		if not FileAccess.file_exists(checkpoint):
			continue
		var reopened = Log.new(directory)
		var recovered = Delivery.new(reopened, null, null, Callable(), func(_message: String) -> void: pass, func(_delivery) -> void: pass)
		var item: Dictionary = reopened.get_record("speech_1")
		if phase == "before":
			check("mid-commit temp remains while old admission/replay state survives", FileAccess.file_exists(directory.path_join("speech_1.json.tmp")) and recovered.state().unheard == 1 and item.text == fields().text and not item.heard)
		elif phase == "after":
			check("committed admission and heard state survive forced process death", recovered.state().unheard == 0 and item.text == "committed after replace" and item.heard)
		else:
			var observed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(checkpoint))
			check("crash recovers active playback as missed without inferred hearing", observed.unheard == 0 and recovered.state().unheard == 1 and not item.heard and item.text == "active before crash")
