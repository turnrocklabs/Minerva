extends Node
## Opt-in final-package check of the exported helper resolver and subprocess.

const Client = preload("res://Scripts/Services/MCP/JSONSchemaValidatorClient.gd")


func run() -> void:
	await get_tree().process_frame
	var client := Client.new()
	add_child(client)
	var resolved_path: String = client._resolved_helper_path()
	var target: String = Client._runtime_target(OS.get_name(), Engine.get_architecture_name())
	var normalized_path := resolved_path.replace("\\", "/")
	var path_is_packaged := not OS.has_feature("editor") and not target.is_empty() \
		and resolved_path.is_absolute_path() and FileAccess.file_exists(resolved_path) \
		and normalized_path.contains("/mcp-runtime/%s/" % target)
	var status: Error = await client.start()
	var compiled: Dictionary = {}
	var validated: Dictionary = {}
	if status == OK:
		compiled = await client.compile('{"type":"object","required":["ready"]}')
	if compiled.get("ok", false):
		validated = await client.validate_raw(compiled.handle, '{"ready":true}')
		await client.release(compiled.handle)
	var passed: bool = path_is_packaged and status == OK and compiled.get("ok", false) \
		and validated.get("ok", false) and validated.get("valid", false)
	client.stop()
	print("PACKAGED_MCP_HELPER_PATH=%s" % resolved_path)
	print("PACKAGED_MCP_HELPER_OK" if passed else "PACKAGED_MCP_HELPER_FAILED")
	get_tree().quit(0 if passed else 1)
