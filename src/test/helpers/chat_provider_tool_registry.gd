extends "res://Scripts/Services/Plugins/PluginToolRegistry.gd"
## Runtime-loaded because the real registry needs the initialized autoload context.
var conn = null
var tree: SceneTree = null
var hold := false
var hold_resumes := false
var holding := 0
var sent_budgets: Array = []

func tool_for(_plugin_id: String, backend_name: String) -> String:
	return backend_name

func is_plugin_tool(_tool_name: String) -> bool:
	return true

# A plugin started while this stands in learns no tools here.
func register_backend_tools(_plugin_id: String, _conn: MCPServerConnection) -> Dictionary:
	return {"ok": true, "registered": []}

func handle_tool_call_outcome(tool_name: String, args: Dictionary,
		context: MCPExecutionContext = null, _write_binding: Dictionary = {}):
	holding += 1
	while (hold or (hold_resumes and args.get("resume") == true)) and not context.is_stopped():
		await tree.process_frame
	holding -= 1
	var outcome = load("res://Scripts/Services/MCP/MCPToolCallOutcome.gd").new()
	if context.is_stopped():
		outcome.application = context.stopped_result()
		return outcome
	context.begin_dispatch()
	sent_budgets.append(context.remaining_seconds(0.0))
	outcome.application = await conn.call_tool(tool_name, args, context.remaining_seconds(0.0))
	return outcome
