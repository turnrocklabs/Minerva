extends SceneTree
## Actual Core APIs with a synchronous socket seam and real incoming frame routing.
var _passed := 0
var _failed := 0
var _completed := false

func _init() -> void:
	await process_frame
	await process_frame
	await _run()
	check("whole lifecycle scenario completed", _completed)
	print("=== Results: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed else 0)

func check(label: String, value: bool) -> void:
	if value:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		printerr("FAIL: " + label)

func _u32(value: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, value)
	return bytes

func _id(value: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(16)
	bytes.encode_u32(0, value)
	return bytes

func _frame(kind: int, stream: PackedByteArray, payload: PackedByteArray) -> PackedByteArray:
	return PackedByteArray([kind]) + stream + payload

func _begin(client, request_id: String, stream: PackedByteArray, topic: String = "voice/tts/synthesize", count: int = 1) -> void:
	var json := JSON.stringify({"cmd": "response", "topic": topic, "params": {"request_id": request_id}, "binary_framing": {"data": "raw", "completion": "stream_end"}}).to_utf8_buffer()
	client._handle_binary_frame(_frame(0, stream, _u32(json.size()) + _u32(count) + json))

func _info(client, stream: PackedByteArray, size: int) -> void:
	var path := "test.wav".to_utf8_buffer()
	client._handle_binary_frame(_frame(1, stream, _u32(path.size()) + _u32(size) + path))

func _audio(client, request_id: String, stream: PackedByteArray, bytes: PackedByteArray) -> void:
	_begin(client, request_id, stream)
	_info(client, stream, bytes.size())
	client._handle_binary_frame(_frame(2, stream, bytes))
	client._handle_binary_frame(_frame(3, stream, PackedByteArray()))

func _capture_provider(provider, output: Dictionary) -> void:
	output["result"] = await provider.generate_content([{"role": "user", "content": "test"}])

func _capture_fetch(core, output: Dictionary) -> void:
	output["result"] = await core.fetch_services(false)

func _legacy_registration_listener(core, client, pending, output: Dictionary) -> void:
	await pending.receive()
	output["ready"] = core.registered and not core.connecting
	client.behavior = "subscribe"
	output["subscribed"] = await core.subscribe("legacy-listener")

func _run() -> void:
	var core = root.get_node("Core")
	var singleton = root.get_node("SingletonObject")
	var old_client = core.client
	var old_registered: bool = core.registered
	var old_services: Array = core.services.duplicate()
	var old_enabled: Dictionary = singleton._enabled_providers.duplicate()
	var old_verbose: bool = singleton.verbose_logging
	singleton.verbose_logging = false
	var client = load("res://test/fixtures/core_lifecycle_client.gd").new()
	root.add_child(client)
	core.client = client
	core.registered = true
	var service = load("res://Scripts/Services/Providers/Core/scripts/service.gd").new({"client_id": "voice-service", "name": "Voice", "actions": []})
	var action = load("res://Scripts/Services/Providers/Core/scripts/action.gd").new({"name": "test", "topic": "voice/tts/synthesize"})
	var baseline_connections: int = client.message_received.get_connections().size()
	var audio := PackedByteArray([82, 73, 70, 70, 1, 2, 3, 4, 87, 65, 86, 69])

	client.behavior = "json"
	var immediate = core.send_message(service, action, {})
	check("request owns response before synchronous send", client.owner_present_at_send and immediate.result.success)
	check("receive preserves already-completed reply", (await immediate.receive()).params.result.value == "immediate")
	check("completion detaches pending entry and signals", client._pending_requests.is_empty() and client.message_received.get_connections().size() == baseline_connections)
	client.behavior = "failure"
	var failed = core.send_message(service, action, {})
	check("send failure resolves immediately without retry", failed.result.error_code == "send_failed" and client._message_queue.is_empty())
	check("failed legacy receive remains nullable", await failed.receive() == null)
	core.registered = false
	var before: int = client.sent.size()
	check("authentication-in-progress refuses service requests", core.send_message(service, action, {}).result.error_code == "core_offline" and client.sent.size() == before)
	var registration = core.await_message().with_topic("system").with_cmd("registration_confirmed")
	registration.start()
	client.behavior = "registration"
	client.register_with_core("test", "client")
	check("registration listener works before registered state", (await registration.receive()).cmd == "registration_confirmed")
	var legacy_registration = core.await_message().with_topic("system").with_cmd("registration_confirmed")
	var legacy_result := {}
	core._connecting = true
	_legacy_registration_listener(core, client, legacy_registration, legacy_result)
	check("production registration owns echoed request ID", await core._register_client())
	check("earlier registration listeners observe readiness even on synchronous reply", legacy_result.get("ready", false) and legacy_result.get("subscribed", false))
	core._connecting = true
	client.behavior = "auth_failure"
	check("registration error promptly resets readiness and connecting", not await core._register_client() and not core.registered and not core._connecting)
	core.registered = true
	client.behavior = "subscribe"
	check("Core.subscribe catches synchronous acknowledgement", await core.subscribe("publication/test"))
	client.behavior = "discovery"
	check("Core discovery catches synchronous empty inventory", (await core.fetch_services(false)).is_empty() and not core._services_fetch_in_flight and client.owner_present_at_send)

	var saved_token: String = core._jwt_token
	var saved_client_id: String = core._client_id
	core._jwt_token = "test"
	core._client_id = "client"
	core.registered = false
	core._connecting = false
	client.behavior = "registration"
	await core._on_socket_reconnected()
	check("socket reconnect registers before allowing service work", core.registered and not core._connecting)
	core._jwt_token = saved_token
	core._client_id = saved_client_id
	client.behavior = "hold"
	var nullable = core.send_message(service, action, {})
	client.reply(nullable.request_id, {"error": null, "text": "ok"})
	check("null error field is a successful reply", nullable.result.success)
	var closed_events := []
	var record_close = func(): closed_events.append(true)
	client.connection_closed.connect(record_close)
	client._drop_connection_state()
	client._drop_connection_state()
	check("already-closed transport does not emit a false disconnect", closed_events.size() == 1)
	client.connection_closed.disconnect(record_close)
	client._connected = true
	core.registered = true
	var first = core.send_message(service, action, {})
	var second = core.send_message(service, action, {})
	client.reply(first.request_id, {"progress": 1}, "publication")
	check("correlated progress cannot complete an owned service request", first.result.is_empty())
	client.reply(second.request_id, {"seat": 2})
	check("concurrent request IDs remain isolated", first.result.is_empty() and second.result.json.params.result.seat == 2)
	client.reply(first.request_id, {"seat": 1})
	check("opposite response order completes both exact owners", first.result.json.params.result.seat == 1 and client._pending_requests.is_empty())
	for mode in ["binary", "either", "both"]:
		for binary_first in [false, true]:
			var request = core.send_message(service, action, {}, mode)
			var stream := _id(10 + _passed)
			if not binary_first:
				client.reply(request.request_id, {"transfer_mode": "binary"})
				check(mode + " announcement waits for audio", request.result.is_empty())
			_audio(client, request.request_id, stream, audio)
			if binary_first and mode == "both":
				check("both mode retains one completed audio while awaiting JSON", request.result.is_empty() and not request.accepts_binary() and client._voice_streams.is_empty())
			if binary_first:
				client.reply(request.request_id, {"transfer_mode": "binary"})
			check(mode + " completes in either delivery order", request.result.success and request.result.binary == audio)
			client._handle_binary_frame(_frame(3, stream, PackedByteArray()))
			check(mode + " completion leaves no request or stream state", client._pending_requests.is_empty() and client._voice_streams.is_empty())
	var json_audio = core.send_message(service, action, {}, "either")
	client.reply(json_audio.request_id, {"audio_base64": Marshalls.raw_to_base64(audio)})
	_audio(client, json_audio.request_id, _id(99), audio)
	check("usable JSON wins once and late binary cannot recreate state", json_audio.result.kind == "json" and client._voice_streams.is_empty())

	var error_request = core.send_message(service, action, {}, "binary")
	client._handle_message({"cmd": "error", "entity_type": "core", "params": {"request_id": error_request.request_id, "error_code": "AUTH_FAILED_PROFILE_CMD_ERROR", "error": "token expired"}})
	check("auth recovery does not swallow correlated errors", error_request.result.error_code == "AUTH_FAILED_PROFILE_CMD_ERROR")
	check("remote error retains legacy JSON response", (await error_request.receive()).cmd == "error")
	var malformed = core.await_message().with_cmd("response")
	malformed.start()
	for invalid in [[], 3, "text"]:
		client._handle_message(invalid)
	check("nonobject top-level JSON is ignored before dictionary access", malformed.result.is_empty())
	client._handle_message({"cmd": "response", "params": null})
	check("malformed uncorrelated params cannot throw before delivery", malformed.result.success)
	for body in [null, []]:
		var empty = core.send_message(service, action, {})
		client.reply(empty.request_id, body)
		check("nonobject response data preserves envelope safely", empty.result.success)

	var cancelled = core.send_message(service, action, {}, "either")
	client.reply(cancelled.request_id, {"transfer_mode": "binary"})
	_begin(client, cancelled.request_id, _id(100))
	_info(client, _id(100), audio.size())
	cancelled.cancel()
	check("cancellation clears admitted audio immediately", cancelled.result.error_code == "cancelled" and client._voice_streams.is_empty())
	check("cancel after announcement stays nullable for legacy callers", await cancelled.receive() == null)
	var timed = core.send_message(service, action, {}, "binary", 0.05)
	_begin(client, timed.request_id, _id(101))
	await create_timer(0.2).timeout
	check("timeout reclaims admitted stream and request", timed.result.error_code == "timeout" and client._pending_requests.is_empty() and client._voice_streams.is_empty())
	var disconnected = core.send_message(service, action, {}, "binary")
	_begin(client, disconnected.request_id, _id(102))
	var during_close := {}
	disconnected.finished.connect(func(_result): during_close["request"] = core.send_message(service, action, {}))
	client.close_connection("test")
	check("explicit disconnect terminates immediately", disconnected.result.error_code == "core_disconnected" and client._voice_streams.is_empty())
	check("disconnect clears readiness before waking callers", during_close.request.result.error_code == "core_offline" and client._pending_requests.is_empty())
	client._connected = true

	# Late voice frames cannot mutate an independently active artifact collector.
	client.prepare_binary_artifact_download("artifact-live")
	_begin(client, "artifact-live", _id(200), "artifact/download")
	client._binary_files[0] = {"buffer": PackedByteArray([9]), "size": 100, "received": 1}
	var before_artifact: Dictionary = client._binary_files.duplicate(true)
	_audio(client, cancelled.request_id, _id(100), audio)
	client._handle_binary_frame(_frame(2, _id(101), audio))
	client._handle_binary_frame(_frame(3, _id(102), _u32(0)))
	check("late voice NEW/DATA/END cannot enter artifact collector", client._binary_files == before_artifact and client._voice_streams.is_empty())
	var collision = core.send_message(service, action, {}, "binary")
	_begin(client, collision.request_id, _id(200))
	check("voice cannot steal artifact stream ID", collision.result.error_code == "invalid_binary" and client._binary_files == before_artifact)
	client._reset_binary_transfer_state()
	var owner = core.send_message(service, action, {}, "binary")
	_begin(client, owner.request_id, _id(201))
	var newcomer = core.send_message(service, action, {}, "binary")
	_begin(client, newcomer.request_id, _id(201))
	_begin(client, "artifact", _id(201), "artifact/download")
	check("conflicting voice/nonvoice headers preserve original owner", newcomer.result.error_code == "invalid_binary" and client._voice_streams[_id(201).hex_encode()].request_id == owner.request_id and client._binary_stream_id.is_empty())
	_begin(client, owner.request_id, _id(202))
	check("duplicate streams cannot grow one request's state", owner.result.error_code == "invalid_binary" and client._voice_streams.is_empty())
	for corruption in ["truncated", "overflow", "count", "header"]:
		var request = core.send_message(service, action, {}, "binary")
		var stream := _id(300)
		_begin(client, request.request_id, stream, "voice/tts/synthesize", 2 if corruption == "count" else 1)
		if corruption != "count":
			_info(client, stream, 3)
			if corruption == "header":
				_info(client, stream, 3)
			elif corruption == "overflow":
				client._handle_binary_frame(_frame(2, stream, audio))
			else:
				client._handle_binary_frame(_frame(3, stream, PackedByteArray()))
		check("malformed voice " + corruption + " refuses and cleans up", request.result.error_code == "invalid_binary" and client._voice_streams.is_empty())
	for header in ["null", "[]", "{\"params\":null}", "{"]:
		var bytes: PackedByteArray = header.to_utf8_buffer()
		client._handle_binary_frame(_frame(0, _id(301), _u32(bytes.size()) + _u32(1) + bytes))
	check("malformed binary envelopes allocate no stream", client._voice_streams.is_empty())

	var mutable = core.send_message(service, action, {})
	mutable.with_request_id("replacement")
	check("active request identity cannot leak registered owner", mutable.result.error_code == "invalid_request" and client._pending_requests.is_empty())
	var mode_change = core.send_message(service, action, {})
	mode_change.with_completion("binary")
	check("completion mode cannot change after send", mode_change.result.error_code == "invalid_completion" and client._pending_requests.is_empty())
	var subscription_change = core.send_message(service, action, {})
	subscription_change.receive_all()
	check("active requests cannot become unbounded subscriptions", subscription_change.result.error_code == "invalid_request" and client._pending_requests.is_empty())
	var subscription = core.await_message().with_topic("events").with_timeout(0.05)
	var publications := []
	subscription.receive_all().connect(func(message): publications.append(message))
	await create_timer(0.2).timeout
	client._handle_message({"cmd": "publication", "topic": "events", "params": {}})
	client._handle_message({"cmd": "publication", "topic": "events", "params": {}})
	check("publication subscriptions remain live without request timeout", publications.size() == 2 and subscription._timer == null)
	subscription.cancel()
	client._handle_message({"cmd": "publication", "topic": "events", "params": {}})
	check("subscription cancellation disconnects deterministically", publications.size() == 2 and client.message_received.get_connections().size() == baseline_connections)
	for i in range(40):
		var request = core.send_message(service, action, {}, "binary")
		_begin(client, request.request_id, _id(400 + i))
		request.cancel()
	await process_frame
	await process_frame
	check("repeated cancellation has bounded requests, streams, timers and signals", client._pending_requests.is_empty() and client._voice_streams.is_empty() and client.get_child_count() == 0 and client.message_received.get_connections().size() == baseline_connections)

	# The actual BaseProvider global Stop signal must reach CoreProvider's await.
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://test/fixtures/model_chat_registration.json"))
	var model_service = load("res://Scripts/Services/Providers/Core/scripts/service.gd").new(fixture.params)
	core.services.assign([model_service])
	singleton._enabled_providers[singleton.API_PROVIDER.TURNROCK] = true
	var provider = load("res://Scripts/Services/Providers/Core/CoreProvider.gd").new(model_service, model_service.actions[0])
	provider.owner_history_id = "stop-target"
	root.add_child(provider)
	var output := {}
	_capture_provider(provider, output)
	check("Core chat starts an owned request", provider._active_core_requests.size() == 1)
	singleton.stop_all_requests.emit("other-history")
	check("Stop respects owning history", output.is_empty())
	singleton.stop_all_requests.emit("stop-target")
	check("actual chat Stop ends Core await without timeout", output.has("result") and output.result.get_meta("error_code") == "cancelled" and provider._active_core_requests.is_empty() and client._pending_requests.is_empty())
	output.clear()
	_capture_provider(provider, output)
	root.remove_child(provider)
	check("provider tree exit releases active Core request", output.has("result") and output.result.get_meta("error_code") == "cancelled" and client._pending_requests.is_empty())
	provider.free()

	core.client = old_client
	core.registered = old_registered
	core.services.assign(old_services)
	singleton._enabled_providers = old_enabled
	singleton.verbose_logging = old_verbose
	client.free()
	_completed = true
