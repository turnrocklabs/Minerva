## Confirmation dialog shown during plugin update reconciliation when a
## customised skill record's pristine_hash differs from the new manifest entry.
##
## DCR 019df57b T4: the user has edited a plugin-seeded skill since install;
## the upstream plugin author has now shipped a new version of that skill.
## Asking before overwriting their edits.
##
## Emits `update_decision(accepted: bool)` on confirm/cancel/close.
##   accepted=true  → overwrite with new content, keep customised flag
##   accepted=false → leave user edits untouched (pristine_content refreshed
##                    so user can diff later if curious)
class_name PluginSkillUpdateDialog extends ConfirmationDialog

signal update_decision(accepted: bool)

var _settled: bool = false


## Configure with both the existing customised record and the new manifest entry.
## Renders a side-by-side text diff of the content fields (steps, summary, etc.)
## so the user can decide whether the upstream change is worth losing their edits.
##
## Call BEFORE add_child / popup_centered.
func configure(plugin_display_name: String, existing_record: Dictionary, new_skill: Dictionary) -> void:
	title = "Plugin update — review skill changes"
	ok_button_text = "Apply update (overwrite my edits)"
	cancel_button_text = "Keep my edits"
	exclusive = false

	var skill_title := str(new_skill.get("title", existing_record.get("title", "(untitled)")))
	var lines: Array[String] = []
	lines.append("Plugin '%s' updated the skill '%s'." % [plugin_display_name, skill_title])
	lines.append("You have customised this skill since installing it.")
	lines.append("")
	lines.append("─── Your version ───")
	lines.append(_field_summary(existing_record))
	lines.append("")
	lines.append("─── Upstream's new version ───")
	lines.append(_field_summary(new_skill))
	lines.append("")
	lines.append("• Apply update — overwrites your edits with upstream's version (your fork is lost).")
	lines.append("• Keep my edits — leaves your version intact; upstream's content is saved for diffing later.")

	dialog_text = "\n".join(lines)


func _field_summary(entry: Dictionary) -> String:
	# Compact preview: title + summary + first line of steps + tool_deps count.
	var bits: Array[String] = []
	bits.append("title: %s" % str(entry.get("title", "")))
	var summary := str(entry.get("summary", ""))
	if not summary.is_empty():
		bits.append("summary: %s" % summary)
	var steps := str(entry.get("steps", ""))
	if not steps.is_empty():
		var first_line := steps.split("\n")[0] if steps.contains("\n") else steps
		if first_line.length() > 80:
			first_line = first_line.substr(0, 80) + "…"
		bits.append("steps[0]: %s" % first_line)
	var deps_count := 0
	var deps_raw = entry.get("tool_deps", [])
	if deps_raw is Array:
		deps_count = (deps_raw as Array).size()
	bits.append("tool_deps: %d" % deps_count)
	return "  " + "\n  ".join(bits)


func _ready() -> void:
	confirmed.connect(_on_confirmed)
	canceled.connect(_on_canceled)
	close_requested.connect(_on_close_requested)


func _on_confirmed() -> void:
	if _settled:
		return
	_settled = true
	update_decision.emit(true)


func _on_canceled() -> void:
	if _settled:
		return
	_settled = true
	update_decision.emit(false)


func _on_close_requested() -> void:
	if _settled:
		return
	_settled = true
	update_decision.emit(false)
