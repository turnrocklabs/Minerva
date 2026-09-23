extends Node
## Opt-in final-package check of the exported helper resolver and subprocess.

const Client = preload("res://Scripts/Services/MCP/JSONSchemaValidatorClient.gd")


func run() -> void:
	_phase("entry")
	var client := Client.new()
	add_child(client)
	client.startup_progress.connect(func(stage: String, elapsed_msec: int) -> void:
		_phase("%s:%dms" % [stage, elapsed_msec]))
	var resolved_path: String = client._resolved_helper_path()
	print("PACKAGED_MCP_HELPER_PATH=%s" % resolved_path)
	var target: String = Client._runtime_target(OS.get_name(), Engine.get_architecture_name())
	var normalized_path := resolved_path.replace("\\", "/")
	var path_is_packaged := not OS.has_feature("editor") and not target.is_empty() \
		and resolved_path.is_absolute_path() and FileAccess.file_exists(resolved_path) \
		and normalized_path.contains("/mcp-runtime/%s/" % target)
	var status: Error = await client.start()
	_phase("start:%s" % error_string(status))
	print("PACKAGED_MCP_HELPER_STARTUP=%s" % JSON.stringify(client.startup_diagnostic()))
	var compiled: Dictionary = {}
	var validated: Dictionary = {}
	if status == OK:
		_phase("compile:begin")
		compiled = await client.compile('{"type":"object","required":["ready"]}')
	_phase("compile:%s" % str(compiled.get("ok", false)))
	if compiled.get("ok", false):
		_phase("validate:begin")
		validated = await client.validate_raw(compiled.handle, '{"ready":true}')
		_phase("validate:%s" % str(validated.get("valid", false)))
		await client.release(compiled.handle)
	var passed: bool = path_is_packaged and status == OK and compiled.get("ok", false) \
		and validated.get("ok", false) and validated.get("valid", false)
	client.stop()
	_phase("stopped")
	print("PACKAGED_MCP_HELPER_OK" if passed else "PACKAGED_MCP_HELPER_FAILED")
	get_tree().quit(0 if passed else 1)


# Phases go to stderr, which is not buffered, so the last one survives a hung
# app that is killed (stdout can be buffered). Each carries the engine's
# uptime, so a timeout shows whether startup or the helper used the time.
func _phase(text: String) -> void:
	printerr("PACKAGED_MCP_HELPER_PHASE=%s uptime=%dms" % [text, Time.get_ticks_msec()])
