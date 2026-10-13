extends SceneTree
## Synthetic response bytes exercise the actual callback and HCP file/UI owner.
var passed: int = 0
var failed: int = 0
const CANARY: String = "eyJ" + "hbGciOiJIUzI1NiJ9.eyJ" + "zdWIiOiJzeW50aGV0aWMifQ.synthetic_auth_canary"

func _init() -> void:
	if OS.get_cmdline_user_args().has("--auth-log-leak-probe"):
		print(CANARY)
		printerr(CANARY)
		quit()
	else:
		call_deferred("run" if OS.get_cmdline_user_args().has("--auth-log-child") else "check_capture")

func check_capture() -> void:
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://test/test_core_auth_logs.gd", "--"])
	var probe: Array = []
	var probe_args := args.duplicate()
	probe_args.append("--auth-log-leak-probe")
	check("stdout/stderr canary capture is live", OS.execute(OS.get_executable_path(), probe_args, probe, true) == 0 and CANARY in str(probe))
	var captured: Array = []
	args.append("--auth-log-child")
	var result: int = OS.execute(OS.get_executable_path(), args, captured, true)
	var output: String = str(captured)
	check("actual auth and binary log paths pass", result == 0 and "Results: 24 passed, 0 failed" in output)
	check("captured stdout/stderr contain no credential", not CANARY in output and not "synthetic_auth_canary" in output and not "eyJ" in output)
	check("captured child has no script errors", not "SCRIPT ERROR" in output)
	print("Results: %d passed, %d failed" % [passed, failed])
	quit(1 if failed else 0)

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: ", label)
	else:
		failed += 1
		printerr("FAIL: ", label)

func run() -> void:
	var so = root.get_node("SingletonObject")
	var core = root.get_node("Core")
	var prior = so.preferences_popup
	var preferences = load("res://Scripts/UI/Views/PreferencesPopup.gd").new()
	var logs = load("res://Scripts/UI/Views/HcpLogs.gd").new()
	var label := RichTextLabel.new()
	logs._rich_text_label = label
	preferences.logs_window = logs
	so.preferences_popup = preferences
	core.should_display_error = false
	var token: String = CANARY
	var cases: Array[Dictionary] = [
		{"status": 200, "body": {"data": {"token": token, "user": {"id": "synthetic-user"}}}, "ok": true},
		{"status": 401, "body": {"error": {"message": token}, "token": token}},
		{"status": 200, "raw": "invalid " + token},
		{"status": 200, "body": {"token": token}},
		{"status": 200, "body": {"data": {"echo": token}}},
		{"status": 200, "body": {"data": {"token": "", "echo": token}}},
		{"status": 200, "body": {"data": {"token": token}}},
		{"status": 200, "body": {"data": {"token": token, "user": {"id": ""}}}},
	]
	for index: int in range(cases.size()):
		var sample: Dictionary = cases[index]
		core.http_request = HTTPRequest.new()
		root.add_child(core.http_request)
		var body: String = sample.get("raw", JSON.stringify(sample.get("body", {})))
		core._on_auth_request_completed(HTTPRequest.RESULT_SUCCESS, sample.status, PackedStringArray(), body.to_utf8_buffer())
		check("auth outcome remains correct case %d" % index, core._jwt_token == (token if sample.get("ok", false) else ""))
		logs.log_fa.flush()
		var captured: String = FileAccess.get_file_as_string("user://hcp.log") + label.get_parsed_text() + JSON.stringify(logs._details_data)
		check("HCP file and UI contain no token case %d" % index, not token in captured and not "eyJ" in captured and not "synthetic_auth_canary" in captured)
	check("safe status and failure diagnostics retained", "401" in FileAccess.get_file_as_string("user://hcp.log") and "does not contain" in label.get_parsed_text() and "Auth response received" in label.get_parsed_text())
	await check_protocol_logs(token, so, logs, label)
	core._jwt_token = ""
	core._client_id = ""
	so.preferences_popup = prior
	preferences.free()
	logs.free()
	label.free()
	print("Results: %d passed, %d failed" % [passed, failed])
	quit(1 if failed else 0)

func check_protocol_logs(token: String, so: Node, logs: Node, label: RichTextLabel) -> void:
	var server := TCPServer.new()
	var port: int = 19500 + OS.get_process_id() % 1000
	var listening: bool = server.listen(port, "127.0.0.1") == OK
	check("isolated loopback listener starts", listening)
	if not listening:
		return
	var client = load("res://Scripts/Services/Providers/Core/core_client.gd").new()
	root.add_child(client)
	var peer := WebSocketPeer.new()
	client._client.connect_to_url("ws://127.0.0.1:%d" % port)
	var accepted: bool = false
	var deadline: int = Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		if not accepted and server.is_connection_available():
			peer.accept_stream(server.take_connection())
			accepted = true
		client._client.poll()
		peer.poll()
		if client._client.get_ready_state() == WebSocketPeer.STATE_OPEN and peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			break
		await process_frame
	var prior_verbose: bool = so.verbose_logging
	so.verbose_logging = true
	check("verbose registration sends over actual WebSocket", client.register_with_core(token, "synthetic-user", "synthetic-request") == OK)
	deadline = Time.get_ticks_msec() + 1000
	while peer.get_available_packet_count() == 0 and Time.get_ticks_msec() < deadline:
		peer.poll()
		await process_frame
	var packet: Dictionary = JSON.parse_string(peer.get_packet().get_string_from_utf8()) if peer.get_available_packet_count() else {}
	check("diagnostic summary does not change authentication wire value", packet.get("params", {}).get("auth", "") == token)
	client.message_received.connect(logs._on_message_received)
	var auth_error: Dictionary = {"cmd": "error", "entity_type": "core", "params": {"error_code": "AUTH_FAILED_PROFILE_CMD_ERROR", "error": "token " + token, "auth": token}}
	client._handle_message(auth_error)
	logs._on_message_received({"cmd": "response", "params": {"token": token, "auth": token}})
	logs.log_fa.flush()
	var captured: String = FileAccess.get_file_as_string("user://hcp.log") + label.get_parsed_text() + JSON.stringify(logs._details_data)
	check("auth error and raw HCP signal retain no credential", not token in captured and not "eyJ" in captured and not "synthetic_auth_canary" in captured)
	check("safe operation and auth error code remain visible", "AUTH_FAILED_PROFILE_CMD_ERROR" in captured and "register" in JSON.stringify(client.log_summary(packet)))
	check_binary_logs(client, token)
	so.verbose_logging = prior_verbose
	client._client.close()
	peer.close()
	server.stop()
	client.free()

func check_binary_logs(client: Node, token: String) -> void:
	var id := PackedByteArray()
	id.resize(16)
	for command: String in [token, "response"]:
		var header: PackedByteArray = JSON.stringify({"cmd": command, "topic": "artifact/download", "params": {"request_id": token}}).to_utf8_buffer()
		var payload := PackedByteArray()
		payload.resize(8)
		payload.encode_u32(0, header.size())
		payload.encode_u32(4, 1)
		payload.append_array(header)
		client._handle_binary_frame(binary_frame(0, id, payload))
	check("binary request identifier remains unchanged on wire", client._current_binary_request_id == token)
	var name: PackedByteArray = "synthetic.bin".to_utf8_buffer()
	var info := PackedByteArray()
	info.resize(16)
	info.encode_u32(12, name.size())
	info.append_array(name)
	client._handle_binary_frame(binary_frame(1, id, info))
	var end := PackedByteArray()
	end.resize(4)
	client._handle_binary_frame(binary_frame(3, id, end))
	client._handle_message({"cmd": "response", "entity_type": "core", "params": {"request_id": token}})
	check("binary completion clears transfer state", client._current_binary_request_id.is_empty())

func binary_frame(kind: int, id: PackedByteArray, payload: PackedByteArray) -> PackedByteArray:
	var frame := PackedByteArray([kind])
	frame.append_array(id)
	frame.append_array(payload)
	return frame
