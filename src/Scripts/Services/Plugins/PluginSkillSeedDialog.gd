## Confirmation dialog shown during plugin install when the manifest declares
## a skills[] array.  Lists each skill (title, summary, tool_deps count,
## unsatisfied_deps count) so the user can decide whether to seed them.
##
## Emits `seed_decision(accepted: bool)` when the user clicks OK or Cancel
## (or closes the dialog).  PluginManager awaits this signal before deciding
## whether to materialise records.
##
## DCR 019df57b T3.
class_name PluginSkillSeedDialog extends ConfirmationDialog

signal seed_decision(accepted: bool)

var _settled: bool = false


## Configure the dialog with the resolved skills for this plugin.
## Call this BEFORE add_child / popup_centered so dialog_text is set.
##
## resolved: Array of {skill: Dictionary, unsatisfied: Array[String]} as returned
## by PluginSkillSeeder.resolve_deps.
func configure(plugin_display_name: String, resolved: Array) -> void:
	title = "Install plugin skills?"
	ok_button_text = "Install skills"
	cancel_button_text = "Skip skills"
	exclusive = false

	var lines: Array[String] = []
	lines.append("Plugin '%s' wants to install %d skill(s):" %
		[plugin_display_name, resolved.size()])
	lines.append("")
	for entry in resolved:
		var skill = entry.get("skill", {})
		var unsatisfied: Array = entry.get("unsatisfied", [])
		var skill_title := str(skill.get("title", "(untitled)"))
		var skill_summary := str(skill.get("summary", ""))
		var dep_count := 0
		var deps_raw = skill.get("tool_deps", [])
		if deps_raw is Array:
			dep_count = (deps_raw as Array).size()

		var line := "• %s" % skill_title
		if not skill_summary.is_empty():
			line += "\n    %s" % skill_summary
		line += "\n    Tools: %d declared" % dep_count
		if not unsatisfied.is_empty():
			line += " (%d unsatisfied — skill will be hidden until resolved)" % unsatisfied.size()
		lines.append(line)

	dialog_text = "\n".join(lines)


func _ready() -> void:
	confirmed.connect(_on_confirmed)
	canceled.connect(_on_canceled)
	close_requested.connect(_on_close_requested)


func _on_confirmed() -> void:
	if _settled:
		return
	_settled = true
	seed_decision.emit(true)


func _on_canceled() -> void:
	if _settled:
		return
	_settled = true
	seed_decision.emit(false)


func _on_close_requested() -> void:
	# X button or escape key — treat as cancel.
	if _settled:
		return
	_settled = true
	seed_decision.emit(false)
