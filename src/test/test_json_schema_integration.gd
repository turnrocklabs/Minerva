extends SceneTree
## Opt-in real companion/supervisor boundary. The helper must already be built;
## this suite never downloads or compiles dependencies.

const Client = preload("res://Scripts/Services/MCP/JSONSchemaValidatorClient.gd")
const Schema = preload("res://Scripts/Services/MCP/MCPJSONSchema.gd")

var passed := 0
var failed := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

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
	var changed: Dictionary = await schema.validate_for_application("0.10000000000000001", 0.1)
	var unsafe: Dictionary = await schema.validate_for_application("9007199254740992", 9007199254740992)
	check("exact fractions survive the application adapter", exact.get("valid", false))
	check("changed fractions and unsafe integers are rejected before application dispatch",
		changed.get("error", {}).get("code") == "unsupported_number"
		and unsafe.get("error", {}).get("code") == "unsupported_number")
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
			in ["deadline_exceeded", "process_lost"]))
	var after_hostile = Schema.create(client, "{\"type\":\"boolean\"}")
	var after_compile: Dictionary = await after_hostile.compile()
	var after_validate: Dictionary = await after_hostile.validate_raw("true")
	check("validator remains usable through the same process or a supervised replacement",
		after_compile.get("ok", false) and after_validate.get("valid", false))
	client.stop()
	client.queue_free()
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)
