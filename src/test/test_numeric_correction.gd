extends SceneTree
## Exact binary64 transport through the real plugin result boundary.
var failed: int = 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd").new("numeric-correction")
	connection.configure_stdio("python3", PackedStringArray([
		ProjectSettings.globalize_path("res://test/fixtures/stdio_timing_probe/stdio_timing_probe.py"),
		"--profile", "modern"]))
	var manager = load("res://test/helpers/plugin_tool_manager_fixture.gd").new()
	manager.connections["probe"] = connection
	var registry = load("res://Scripts/Services/Plugins/PluginToolRegistry.gd").new(manager)
	assert(await connection.connect_to_server() == OK)
	assert((await registry.register_backend_tools("probe", connection)).get("ok", false))
	var corrected = await registry.handle_tool_call_outcome("minerva_probe_canonical_decimal", {})
	print("CORRECTION_OUTCOME: ", corrected.application)
	# Encode the independently known IEEE-754 words: GDScript's decimal literal
	# parser can itself round this value, so a decimal literal is not an oracle.
	var expected := PackedByteArray()
	expected.resize(8)
	expected.encode_u64(0, 0x3f8948b0f90591e6)
	check("canonical decimal reaches application with exact source binary64",
		not corrected.application.has("error") and corrected.application.get("n") == expected.decode_double(0))
	var unsafe = await registry.handle_tool_call_outcome("minerva_probe_nested_precision_loss", {})
	check("noncanonical nested decimal remains unsupported_number",
		unsafe.application.get("error_code") == "unsupported_number"
		and unsafe.application.get("error_details", {}).get("pointer") == "/n")
	connection.disconnect_from_server()
	registry.plugin_manager = null
	manager.connections.clear()
	manager.free()
	print("=== Results: %d passed, %d failed ===" % [2 - failed, failed])
	quit(1 if failed else 0)

func check(label: String, ok: bool) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok:
		failed += 1
