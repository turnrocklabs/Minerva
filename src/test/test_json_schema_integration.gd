extends SceneTree
## Opt-in real companion/supervisor boundary. The helper must already be built;
## this suite never downloads or compiles dependencies.

const Client = preload("res://Scripts/Services/MCP/JSONSchemaValidatorClient.gd")
const Schema = preload("res://Scripts/Services/MCP/MCPJSONSchema.gd")
const Wire = preload("res://Scripts/Services/MCP/MCPWireValue.gd")
const WireAdapter = preload("res://Scripts/Services/MCP/MCPWireAdapter.gd")
const JsonSerialization = preload("res://Scripts/Services/MCP/MCPJsonSerialization.gd")
const ToolResult = preload("res://Scripts/Services/MCP/MCPToolResult.gd")
const ToolResultAdapter = preload("res://Scripts/Services/MCP/MCPToolResultAdapter.gd")

const PASSTHROUGH_QUESTION_RAW := (
	'{"kind":"question","text":"Would you like to run the following command?\\r\\n' \
	+ '  › 1. Yes, proceed\\r\\n  2. Yes, and don’t ask again\\r\\n' \
	+ '  3. No, and tell Codex what to do differently","options":[' \
	+ '{"label":"Yes, proceed","keystroke":"y"},' \
	+ '{"label":"Yes, and don’t ask again","keystroke":"p"},' \
	+ '{"label":"No, and tell Codex what to do differently","keystroke":"\\u001b"}]}'
)

var passed := 0
var failed := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label, " — ", detail)

func _contains_c0(value: String) -> bool:
	for index in value.length():
		if value.unicode_at(index) < 0x20:
			return true
	return false

func _run() -> void:
	var path := OS.get_environment("MINERVA_JSON_SCHEMA_HELPER")
	if path.is_empty() or not FileAccess.file_exists(path):
		printerr("MINERVA_JSON_SCHEMA_HELPER must name the source-built helper")
		quit(2)
		return
	var client := Client.new()
	client.helper_path = path
	root.add_child(client)
	var schema = Schema.create(client,
		"{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"number\"}")
	var compiled: Dictionary = await schema.compile()
	check("real supervisor compiles through the source-built companion", compiled.get("ok", false))
	var exact: Dictionary = await schema.validate_for_application("0.5", 0.5)
	var binary64_spelling: Dictionary = await client.compare_application_numbers(
		'{"mesh":{"vertices":[[0.1]]}}', {"mesh": {"vertices": [[0.1]]}})
	var changed: Dictionary = await schema.validate_for_application("0.10000000000000001", 0.1)
	var changed_details: Dictionary = await client.compare_application_numbers(
		"0.10000000000000001", 0.1)
	var unsafe: Dictionary = await schema.validate_for_application("9007199254740992", 9007199254740992)
	var cad_raw := '{"result":{"edges":[{"polyline":[[0.0],[99.80267284282715]]}]}}'
	var cad_wire = Wire.create(cad_raw, JSON.parse_string(cad_raw))
	WireAdapter._validator = client
	var cad_decode: Dictionary = await WireAdapter.validate_for_application(cad_wire)
	var cad_verified: Dictionary = await client.compare_application_numbers(
		cad_raw, cad_wire.parsed)
	var question_parsed: Variant = JSON.parse_string(PASSTHROUGH_QUESTION_RAW)
	var question_encoded: Dictionary = JsonSerialization.encode(question_parsed)
	var every_control := ""
	# Godot String cannot represent NUL; it substitutes U+FFFD. The separate
	# raw-wire assertion below verifies that this conversion remains fail-closed.
	for code in range(1, 0x20):
		every_control += String.chr(code)
	var controls_value := {
		every_control: every_control,
		"mixed": 'quoted "text", slash \\, numeric-looking 0.10000000000000001',
		"literal_backslash_v": "\\v",
	}
	var controls_encoded: Dictionary = JsonSerialization.encode(controls_value)
	var controls_round_trip: Variant = JSON.parse_string(str(controls_encoded.get("raw", "")))
	var outer_control_request: Dictionary = await client._request({
		"op": "unknown_control_probe", "probe": every_control,
	})
	var nul_raw := '{"nul":"\\u0000"}'
	var nul_rejected: Dictionary = await client.prepare_application_numbers(
		nul_raw, JSON.parse_string(nul_raw))
	var question_numeric: Dictionary = await client.prepare_application_numbers(
		PASSTHROUGH_QUESTION_RAW, question_parsed)
	var question_envelope = ToolResult.from_mcp({
		"content": [{"type": "text", "text": PASSTHROUGH_QUESTION_RAW}],
		"resultType": "complete",
	}, true)
	var question_outcome = await ToolResultAdapter.adapt(question_envelope)
	WireAdapter._validator = null
	check("exact fractions survive the application adapter", exact.get("valid", false))
	check("equivalent shortest and full-precision binary64 spellings interoperate",
		binary64_spelling.get("ok", false))
	check("changed fractions and unsafe integers are rejected before application dispatch",
		changed.get("error", {}).get("code") == "unsupported_number"
		and unsafe.get("error", {}).get("code") == "unsupported_number"
		and changed_details.get("error", {}).get("details", {}).get("original") \
			== "0.10000000000000001")
	check("CAD worker decimals decode to their source binary64 value",
		cad_decode.get("ok", false) and cad_verified.get("ok", false))
	check("number-free passthrough question crosses the real numeric boundary unchanged",
		question_encoded.get("ok", false)
		and not str(question_encoded.get("raw", "")).contains("\u001b")
		and JSON.parse_string(question_encoded.raw) == question_parsed
		and question_numeric.get("ok", false)
		and question_outcome.application.get("kind") == "question"
		and question_outcome.application.get("options", []).size() == 3
		and question_outcome.application.options[2].get("keystroke") == "\u001b",
		"numeric=%s application=%s" % [question_numeric, question_outcome.application])
	check("JSON serialization escapes native C0 controls in keys and values",
		controls_encoded.get("ok", false)
		and not _contains_c0(str(controls_encoded.get("raw", "")))
		and controls_round_trip == controls_value
		and outer_control_request.get("error", {}).get("code") == "unknown_operation",
		str(controls_encoded))
	check("wire NUL remains rejected when Godot cannot represent its decoded value",
		nul_rejected.get("error", {}).get("code") == "unsupported_number"
		and nul_rejected.get("error", {}).get("details", {}).get("reason") == "value_changed",
		str(nul_rejected))
	var old_handle = schema.handle
	var old_process = client._process
	var old_generation: int = client._generation
	client._on_process_exited(9, old_process, old_generation)
	var stale: Dictionary = await client.validate_raw(old_handle, "1")
	check("real process loss invalidates compiled handles", stale.get("error", {}).get("code") == "invalid_handle")
	var rebuilt: Dictionary = await schema.compile()
	check("retained raw schema recompiles after process replacement", rebuilt.get("ok", false)
		and schema.handle.generation != old_handle.generation)
	var hostile = Schema.create(client,
		"{\"type\":\"string\",\"pattern\":\"^(a+)+$\"}")
	var hostile_compile: Dictionary = await hostile.compile()
	var began := Time.get_ticks_msec()
	var hostile_result: Dictionary = await hostile.validate_raw('"' + "a".repeat(30000) + 'b"')
	var elapsed := Time.get_ticks_msec() - began
	check("pathological validation returns or loses its isolated helper within the hard deadline",
		hostile_compile.get("ok", false) and elapsed < 3000
		and (hostile_result.has("valid") or hostile_result.get("error", {}).get("code") \
			in ["deadline_exceeded", "process_lost", "operation_failed"]))
	var after_hostile = Schema.create(client, "{\"type\":\"boolean\"}")
	var after_compile: Dictionary = await after_hostile.compile()
	var after_validate: Dictionary = await after_hostile.validate_raw("true")
	check("validator remains usable through the same process or a supervised replacement",
		after_compile.get("ok", false) and after_validate.get("valid", false))
	client.stop()
	client.queue_free()
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)
