class_name PluginDependencyContract
extends RefCounted
## Plain manifest requirements and graph validation; no runtime lifecycle.

static func parse(raw: Variant, owner: String, enabled: bool, providers: Array[String]) -> Dictionary:
	if not raw is Array:
		return {"error": "requires_plugins must be an Array"}
	var entries: Array = raw
	if not entries.is_empty() and not enabled:
		return {"error": "requires_plugins must be an Array and requires plugin_dependencies capability"}
	var requirements: Array[Dictionary] = []
	var seen: Array[String] = []
	var version := RegEx.new()
	var number := "(?:0|[1-9][0-9]*)"
	var label := "(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
	version.compile("^%s[.]%s[.]%s(?:-%s(?:[.]%s)*)?(?:[+][0-9A-Za-z-]+(?:[.][0-9A-Za-z-]+)*)?$" % [number, number, number, label, label])
	var tool := RegEx.new()
	tool.compile("^minerva_[A-Za-z0-9_]+$")
	for value: Variant in entries:
		if not value is Dictionary:
			return {"error": "requires_plugins entries must be objects"}
		var entry: Dictionary = value
		var id_value: Variant = entry.get("id")
		var minimum: Variant = entry.get("min_version")
		var actions: Variant = entry.get("actions")
		if not id_value is String or id_value not in providers or id_value == owner or id_value in seen:
			return {"error": "requires_plugins id must name a unique required provider other than itself"}
		if not minimum is String or not actions is Array:
			return {"error": "requires_plugins needs a semantic min_version and actions Array"}
		var minimum_text: String = minimum
		if minimum_text != minimum_text.strip_edges() or version.search(minimum_text) == null:
			return {"error": "invalid dependency min_version"}
		var action_values: Array = actions
		var id: String = id_value
		var names: Array[String] = []
		for action: Variant in action_values:
			if not action is String:
				return {"error": "dependency actions must be canonical provider tool names"}
			var name: String = action
			var prefix := "minerva_" + id + "_"
			if not name.begins_with(prefix) or name.length() == prefix.length() or name in names or name != name.strip_edges() or tool.search(name) == null:
				return {"error": "dependency actions must uniquely name tools owned by " + id}
			names.append(name)
		requirements.append({"id": id, "min_version": minimum_text, "actions": names})
		seen.append(id)
	return {"ok": true, "requirements": requirements}


static func cycle_issue(graph: Dictionary, id: String, path: Array[String] = []) -> String:
	if id in path:
		var cycle := path.duplicate()
		cycle.append(id)
		return "plugin_dependency_cycle: " + " -> ".join(cycle)
	var branch := path.duplicate()
	branch.append(id)
	var edges: Array = graph.get(id, [])
	for target: String in edges:
		var issue := cycle_issue(graph, target, branch)
		if not issue.is_empty():
			return issue
	return ""


## Stable Kahn order; unresolved nodes are cycles or depend on one.
static func startup_order(definitions: Array) -> Dictionary:
	var pending: Dictionary = {}
	for def: PluginDefinition in definitions:
		var edges: Array[String] = []
		for requirement: Dictionary in def.requires_plugins:
			edges.append(requirement.id)
		pending[def.id] = edges
	var order: Array[String] = []
	while not pending.is_empty():
		var ids: Array = pending.keys()
		ids.sort()
		var selected := ""
		for id: String in ids:
			var blocked := false
			for provider: String in pending[id]:
				blocked = blocked or pending.has(provider)
			if not blocked:
				selected = id
				break
		if selected.is_empty():
			break
		order.append(selected)
		pending.erase(selected)
	return {"order": order, "cycles": pending.keys()}
