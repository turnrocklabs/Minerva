extends RefCounted
## The questions PluginManager asks about a plugin's skills and knowledge:
## whether to seed a new plugin's skills and knowledge (one question), and
## whether an update may overwrite each skill or knowledge record the user
## customised. The dialogs are parented to a `host` node.
##
## With no scene tree or no display there is no one to answer, so each
## question is declined rather than waiting forever; callers that want skills
## seeded headless pass auto_confirm instead.

const Seeder := preload("res://Scripts/Services/Plugins/PluginSkillSeeder.gd")
const Knowledge := preload("res://Scripts/Services/Plugins/PluginKnowledgeSeeder.gd")


## Ask now every skill question registering `manifest_path` would ask, so a
## marketplace install can wait for the user while nothing has changed and
## then register without stopping: seed consent for a new plugin, or one
## decision per customised skill or knowledge record (keyed by manifest id or
## key) an update would change. Pass the result to
## install_plugin / update_plugin as `consent`. Cancelling `op` closes an
## open dialog as a decline and asks nothing more; an unattended `op` asks
## nothing, so every skill the user customised keeps their version, and
## (seed_new false) skills the update adds are not seeded. A repair `op`
## (repair_only) likewise keeps every customised skill without asking, even
## with auto_confirm, and seeds only what is new. `available_tools` and
## `docket_caller` are as PluginSkillSeeder takes them; when Docket cannot be
## reached, nothing is asked about an update (it will not be applied).
static func collect(host: Node, db, available_tools: Dictionary, docket_caller, manifest_path: String,
		auto_confirm: bool, op = null) -> Dictionary:
	var consent := {"collected": true}
	var unattended: bool = op != null and bool(op.get("unattended"))
	var keep_customised: bool = unattended or (op != null and bool(op.get("repair_only")))
	var def = PluginDefinition.from_manifest(manifest_path, PluginDefinition.LANE_MARKETPLACE)
	if def == null:
		return consent
	if not db.has_plugin(def.id):
		if not (def.skills.is_empty() and def.knowledge.is_empty()) and not (op != null and op.cancelled):
			var resolved: Array = Seeder.resolve_deps(def, available_tools)
			consent["seed"] = not unattended and (auto_confirm or await ask_seed(host, def, resolved, op))
		return consent
	if not docket_caller.unavailable().is_empty():
		return consent
	var skill_plan: Dictionary = await Seeder.plan_reconcile(def, available_tools, docket_caller)
	var actions: Array = skill_plan.get("actions", [])
	if not (def.knowledge.is_empty() and db.get_by_id(def.id).knowledge.is_empty()):
		var knowledge_plan: Dictionary = await Knowledge.plan(def, docket_caller)
		actions += knowledge_plan.get("actions", [])
	var decisions := {}
	# What each item asked about held when it was shown: an acceptance applies
	# only while the record still holds it (PluginContentSeeding.update_decisions).
	var seen := {}
	for action in actions:
		if str(action.get("action", "")) == Seeder.RECONCILE_PROMPT_REQUIRED and not (op != null and op.cancelled):
			var item: Dictionary = action.get("entry", action.get("skill", {}))
			var item_id := str(action.get("id", item.get("id", "")))
			seen[item_id] = Knowledge.record_digest(str(item.get("type", "skill")) if action.has("entry") else "skill",
				action.get("existing", {}))
			decisions[item_id] = not keep_customised and (auto_confirm \
				or await ask_update(host, def, action.get("existing", {}), item, op))
	consent["update_decisions"] = decisions
	consent["update_seen"] = seen
	if unattended:
		consent["seed_new"] = false
	return consent


## Whether the user accepts seeding `resolved` (PluginSkillSeeder.resolve_deps)
## and `def`'s knowledge.
static func ask_seed(host: Node, def, resolved: Array, op = null) -> bool:
	if not _can_ask(host, "seed"):
		return false
	var dialog := PluginSkillSeedDialog.new()
	host.add_child(dialog)
	dialog.configure(_display_name(def), resolved, def.knowledge)
	return await _answer(dialog, dialog.seed_decision, op)


## Whether the user lets an update overwrite one customised skill or
## knowledge record.
static func ask_update(host: Node, def, existing_record: Dictionary, new_skill: Dictionary, op = null) -> bool:
	if not _can_ask(host, "update"):
		return false
	var dialog := PluginSkillUpdateDialog.new()
	host.add_child(dialog)
	dialog.configure(_display_name(def), existing_record, new_skill)
	return await _answer(dialog, dialog.update_decision, op)


static func _can_ask(host: Node, what: String) -> bool:
	if not host.is_inside_tree() or DisplayServer.get_name() == "headless":
		push_warning("[PluginSkillConsent] Skill %s dialog suppressed (no scene tree or display); declining" % what)
		return false
	return true


static func _display_name(def) -> String:
	return def.name if not def.name.is_empty() else def.id


## Show `dialog` and wait for `decision`; cancelling `op` answers it as declined.
static func _answer(dialog: Window, decision: Signal, op) -> bool:
	dialog.popup_centered()
	var close := func() -> void: decision.emit(false)
	if op != null:
		op.cancel_requested.connect(close, CONNECT_ONE_SHOT)
	var accepted: bool = await decision
	if op != null and op.cancel_requested.is_connected(close):
		op.cancel_requested.disconnect(close)
	dialog.queue_free()
	return accepted
