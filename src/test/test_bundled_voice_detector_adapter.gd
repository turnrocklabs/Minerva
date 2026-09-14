extends SceneTree
## Bundled adapter owns delayed worker lifecycle without network traffic.

var passed := 0
var failed := 0


func _init() -> void:
	await process_frame
	var Fixture = load("res://test/fixtures/bundled_voice_detector_adapter.gd")
	var adapter = Fixture.new()
	var manager = Fixture.FakeManager.new()
	var delayed = Fixture.FakeConnection.new()
	var replacement = Fixture.FakeConnection.new()
	manager.connection = delayed
	manager.next_connection = replacement
	adapter.manager = manager
	root.add_child(adapter)
	var failures: Array[String] = []
	var restart_on_failure := {"enabled": false, "connection": null}
	adapter.start_failed.connect(func(reason: String):
		failures.append(reason)
		if restart_on_failure.enabled:
			restart_on_failure.enabled = false
			manager.next_connection = restart_on_failure.connection
			adapter.start({"vad_silence_ms": 1000})
	)
	delayed.block_configure = true
	adapter.start({"vad_silence_ms": 1000})
	adapter.stop()
	adapter.start({"vad_silence_ms": 1200})
	delayed.release_configure.emit()
	await process_frame
	await process_frame
	check("stale delayed configure cannot fail or replace restarted adapter", failures.is_empty() and adapter.endpoints.size() == 1 and manager.stops == 1)
	var unavailable = Fixture.FakeConnection.new()
	unavailable.ready = false
	var recovered = Fixture.FakeConnection.new()
	restart_on_failure.connection = recovered
	restart_on_failure.enabled = true
	adapter.stop()
	manager.next_connection = unavailable
	adapter.start({"vad_silence_ms": 1000})
	await process_frame
	check("failed readiness cleans up before a synchronous listener starts replacement", failures.size() == 1 and manager.connection == recovered and adapter.endpoints.size() == 2)
	recovered.ready = false
	adapter._reconnect_audio(adapter._generation)
	await process_frame
	check("failed reconnect is visible and tears down its worker", failures.size() == 2 and manager.connection == null)
	var live = Fixture.FakeConnection.new()
	manager.next_connection = live
	adapter.start({"vad_silence_ms": 1000})
	await process_frame
	live.configure_error = true
	adapter.update_config({"vad_silence_ms": 900})
	await process_frame
	check("live configuration rejection is visible and terminal", failures.size() == 3 and manager.connection == null)
	adapter.free()
	print("Voice Support adapter: %d passed, %d failed" % [passed, failed])
	quit(1 if failed else 0)


func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: " + label)
	else:
		failed += 1
		printerr("FAIL: " + label)
