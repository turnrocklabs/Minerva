extends PluginSeedingDocket
## Hold one real hosted seeding call at its public boundary; storage semantics
## come from the existing hermetic content-registry fixture, not this gate.

signal released
var waiting: bool = false
var fetched: Array[String] = []


func _init(host: DocketHost) -> void:
	super(host)


func call_tool(tool: String, arguments: Dictionary) -> Dictionary:
	if tool == "docket_query" and not waiting:
		waiting = true
		await released
	if tool == "docket_get":
		fetched.append(str(arguments.get("id", "")))
	return await super.call_tool(tool, arguments)
