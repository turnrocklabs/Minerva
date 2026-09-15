extends Node
## Opt-in final-package check of the exported helper resolver and subprocess.

const Client = preload("res://Scripts/Services/MCP/JSONSchemaValidatorClient.gd")


func run() -> void:
	print("PACKAGED_MCP_HELPER_PHASE=entry")
	var client := Client.new()
	add_child(client)
	var resolved_path: String = client._resolved_helper_path()
	print("PACKAGED_MCP_HELPER_PATH=%s" % resolved_path)
	var target: String = Client._runtime_target(OS.get_name(), Engine.get_architecture_name())
	var normalized_path := resolved_path.replace("\\", "/")
	var path_is_packaged := not OS.has_feature("editor") and not target.is_empty() \
		and resolved_path.is_absolute_path() and FileAccess.file_exists(resolved_path) \
		and normalized_path.contains("/mcp-runtime/%s/" % target)
	var status: Error = await client.start()
	print("PACKAGED_MCP_HELPER_PHASE=start:%s" % error_string(status))
	var compiled: Dictionary = {}
	var validated: Dictionary = {}
	if status == OK:
		compiled = await client.compile('{"type":"object","required":["ready"]}')
	print("PACKAGED_MCP_HELPER_PHASE=compile:%s" % str(compiled.get("ok", false)))
	if compiled.get("ok", false):
		validated = await client.validate_raw(compiled.handle, '{"ready":true}')
		print("PACKAGED_MCP_HELPER_PHASE=validate:%s" % str(validated.get("valid", false)))
		await client.release(compiled.handle)
	var passed: bool = path_is_packaged and status == OK and compiled.get("ok", false) \
		and validated.get("ok", false) and validated.get("valid", false)
	client.stop()
	print("PACKAGED_MCP_HELPER_PHASE=stopped")
	print("PACKAGED_MCP_HELPER_OK" if passed else "PACKAGED_MCP_HELPER_FAILED")
	get_tree().quit(0 if passed else 1)
