extends SceneTree
## "Start with Minerva" for a host-owned plugin, end to end.
##
## The oracle is the boot sequence singleton_object.gd runs: a PluginDB that
## has loaded its file, register_internal(), prepare_internal_plugins(), then
## start_autostart_plugins(). The setting is written through the same
## PluginDB.set_autostart the plugin-manager panel's Auto-start toggle calls —
## no second switch, no second boot path.
##
## Host-owned definitions are rebuilt from res:// each launch and never reach
## the plugins[] array, so the flag rides in the file's internal_autostart
## record; the reload assertions are what prove it survives a relaunch.
##
## agent_relay only reaches RUNNING on a host whose runtime is staged. Where
## InternalPlugins.runtime_issue() reports damage, the oracle flips: autostart
## must NOT start it, and the failure the loop reports is that same sentence.

var _passed := 0
var _failed := 0

const PLUGIN_ID := "agent_relay"


func _init() -> void:
	await process_frame
	var DB = load("res://Scripts/Services/Plugins/PluginDB.gd")
	var Definition = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	var Policy = load("res://Scripts/Services/Plugins/PluginPolicy.gd")

	if InternalPlugins.definition_for(PLUGIN_ID) == null:
		print("SKIP: %s has no runtime on this platform" % PLUGIN_ID)
		quit(0)
		return

	# --- The setting, written the way the panel writes it -------------------
	var db = DB.new()
	db.register_internal()
	check("the host-owned plugin is in the catalog", db.has_plugin(PLUGIN_ID))
	check("auto-start is off until the user asks for it",
		not db.get_by_id(PLUGIN_ID).autostart)
	check("the panel's toggle is accepted for a host-owned plugin",
		db.set_autostart(PLUGIN_ID, true))
	check("the flag is live on the loaded definition",
		db.get_by_id(PLUGIN_ID).autostart)

	# --- It survives a relaunch: a fresh store reads it back ----------------
	var reloaded = DB.new()
	reloaded.register_internal()
	check("the setting survives a store reload",
		reloaded.get_by_id(PLUGIN_ID).autostart)
	var autostart_ids: Array[String] = []
	for def in reloaded.get_autostart_plugins():
		autostart_ids.append(def.id)
	check("the boot query returns it with no user action",
		autostart_ids.has(PLUGIN_ID))

	# A host-owned identity still never reaches the persisted plugins[] array.
	var saved: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("user://plugins/plugins.json"))
	var saved_ids: Array[String] = []
	for record in saved.get("plugins", []):
		saved_ids.append(str(record.get("id", "")))
	check("the definition is still absent from plugins.json",
		not saved_ids.has(PLUGIN_ID))

	# --- Boot, exactly as singleton_object.gd does it -----------------------
	# Which leg is the oracle depends on this host's staged runtime, so the run
	# SAYS which one it took: a leg that silently ran neither would otherwise
	# look like a pass.
	var issue: String = InternalPlugins.runtime_issue(PLUGIN_ID)
	print("auto-start leg: %s (runtime_issue: %s)" % [
		"healthy runtime" if issue.is_empty() else "damaged runtime",
		issue if not issue.is_empty() else "none"])
	var legs_run: int = 0
	var manager = _boot(reloaded, Policy)
	await manager.start_autostart_plugins()
	var state: int = reloaded.get_by_id(PLUGIN_ID).state
	if issue.is_empty():
		legs_run += 1
		check("a fresh boot reaches RUNNING with no user action",
			state == Definition.State.RUNNING)
	else:
		legs_run += 1
		check("a damaged runtime is not started by auto-start",
			state != Definition.State.RUNNING and state != Definition.State.STARTING)
		check("start_plugin reports the member's repair sentence",
			(await manager.start_plugin(PLUGIN_ID)).get("error", "") == issue)
	check("exactly one auto-start leg ran", legs_run == 1)
	_teardown(manager)

	# --- Clearing it keeps the plugin stopped -------------------------------
	check("the panel's toggle clears the setting",
		reloaded.set_autostart(PLUGIN_ID, false))
	var cleared = DB.new()
	cleared.register_internal()
	check("the cleared setting also survives a store reload",
		not cleared.get_by_id(PLUGIN_ID).autostart)
	var cleared_ids: Array[String] = []
	for def in cleared.get_autostart_plugins():
		cleared_ids.append(def.id)
	check("the boot query no longer returns it", not cleared_ids.has(PLUGIN_ID))

	var stopped_manager = _boot(cleared, Policy)
	await stopped_manager.start_autostart_plugins()
	check("a fresh boot leaves it stopped",
		cleared.get_by_id(PLUGIN_ID).state != Definition.State.RUNNING
			and cleared.get_by_id(PLUGIN_ID).state != Definition.State.STARTING)
	_teardown(stopped_manager)

	print("=== Results: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed else 0)


## Wire a PluginManager over an already-loaded db and run the preparation step
## that establishes internal directories and grants, mirroring the order
## singleton_object.gd uses before it starts auto-start plugins.
##
## The db and the policy are injected BEFORE the manager enters the tree, so
## _ready() adopts them instead of building a second store; the manager is a
## Node and singleton_object.gd adds it to the tree, which is what gives it its
## _ready() (runtime records, the chat-provider registry) and its _process.
## The brokers and the tool registry SingletonObject also wires are absent
## here: start_plugin only warns for each, and the subprocess it spawns parents
## itself to the tree root, so the RUNNING leg does not depend on them.
func _boot(db, Policy):
	var manager = load("res://Scripts/Services/Plugins/PluginManager.gd").new()
	manager.name = "PluginManager"
	manager._db = db
	manager._policy_ref = Policy.new(db, null, false)
	root.add_child(manager)
	manager.prepare_internal_plugins()
	return manager


## Undo _boot: stop everything it started and take the manager back out of the
## tree before freeing it.
func _teardown(manager) -> void:
	manager.shutdown_all()
	root.remove_child(manager)
	manager.free()


func check(label: String, condition: bool) -> void:
	if condition:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		printerr("FAIL: " + label)
