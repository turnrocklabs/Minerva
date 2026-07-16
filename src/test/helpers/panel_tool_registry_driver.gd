## Test helper: build a real PluginToolRegistry + PluginScenePanelBroker rig
## and register a live scene panel under an editor name so tests can dispatch
## panel-executed tools (executor == "panel") through the REAL dispatch path
## (PluginToolRegistry.handle_tool_call), mirroring test_panel_executed_tools.gd's
## fixture wiring (DCR 019f6c3d0e3d, C1 dispatcher round).
##
## Used by the wave-1 pcb migration round (C2, docket 019f6c45f09e) so suites
## that used to call a core MCP module's handle() directly can instead prove
## the tool answers through the same path production traffic takes, without
## every suite re-deriving the registry/broker/manifest-shaped-tool-dict
## plumbing test_panel_executed_tools.gd established.
##
## Usage:
##   var driver = preload("res://test/helpers/panel_tool_registry_driver.gd").new()
##   var registry: PluginToolRegistry = driver.build(panel, "pcb", editor_name, [
##       "minerva_pcb_pin_info",
##   ])
##   var result: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", args)
##
## No class_name: plain script, loaded via preload()/load() like every other
## test helper in this directory (matches plugin_panel_driver.gd's convention
## — this one is fully in-tree so it COULD carry a class_name, but staying
## const-free avoids any chance of colliding with a future top-level name).
extends RefCounted


## Build a PluginToolRegistry wired to a fresh PluginScenePanelBroker with
## `panel` registered as `editor_name`, owned by `plugin_id`, and every name in
## `tool_names` registered with executor "panel" (manifest-shaped fixture
## dicts — name/description/input_schema/executor, mirroring what
## PluginDefinition.tools would carry). Returns the ready-to-dispatch
## registry, or null if registration failed (printed to stderr for the
## caller's SETUP FAILED path).
func build(panel: Node, plugin_id: String, editor_name: String, tool_names: Array) -> PluginToolRegistry:
	var broker := PluginScenePanelBroker.new(null, null, null, null)
	broker.register_panel(panel, plugin_id, editor_name, PackedStringArray())

	var registry := PluginToolRegistry.new()
	registry.scene_panel_broker = broker

	var tools: Array = []
	for tool_name in tool_names:
		tools.append({
			"name": str(tool_name),
			"description": "test fixture tool %s" % str(tool_name),
			"input_schema": {"type": "object", "properties": {}},
			"executor": "panel",
		})

	var result: Dictionary = registry.register_plugin_tools(plugin_id, tools)
	if result.has("error"):
		printerr("[panel_tool_registry_driver] register_plugin_tools failed: %s" % str(result))
		return null
	return registry
