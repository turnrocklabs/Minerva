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

# Layout — taller-than-wide so summary text wraps cleanly and the skill list
# scrolls when there are many skills. Default ConfirmationDialog auto-sizes
# its dialog_text Label to content width, producing a wide-and-short window
# with no scroll affordance; we render our own ScrollContainer body instead.
const _DIALOG_MIN_W := 520
const _DIALOG_MIN_H := 380

var _settled: bool = false
var _body_label: RichTextLabel = null


## Configure the dialog with the resolved skills for this plugin.
## Call this BEFORE add_child / popup_centered so the body is built.
##
## resolved: Array of {skill: Dictionary, unsatisfied: Array[String]} as returned
## by PluginSkillSeeder.resolve_deps.
func configure(plugin_display_name: String, resolved: Array) -> void:
	title = "Install plugin skills?"
	ok_button_text = "Install skills"
	cancel_button_text = "Skip skills"
	exclusive = false
	dialog_text = ""  # the built-in Label is replaced by our scroll body
	min_size = Vector2i(_DIALOG_MIN_W, _DIALOG_MIN_H)

	_ensure_body()
	if _body_label != null:
		_body_label.text = _build_body_bbcode(plugin_display_name, resolved)


## Build the scrollable body once. AcceptDialog adds children below its
## (now-empty) dialog_text Label, so the ScrollContainer fills the dialog.
func _ensure_body() -> void:
	if _body_label != null:
		return

	var scroll := ScrollContainer.new()
	scroll.name = "SkillBodyScroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	# Generous min so the dialog opens at a usable size before the user
	# has resized it — the outer min_size bound covers the window chrome.
	scroll.custom_minimum_size = Vector2(_DIALOG_MIN_W - 40, _DIALOG_MIN_H - 100)
	add_child(scroll)

	_body_label = RichTextLabel.new()
	_body_label.bbcode_enabled = true
	_body_label.fit_content = true
	_body_label.scroll_active = false  # outer ScrollContainer handles scrolling
	_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(_body_label)


func _build_body_bbcode(plugin_display_name: String, resolved: Array) -> String:
	var lines: Array[String] = []
	lines.append("[b]Plugin '%s'[/b] wants to install %d skill(s):" %
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

		lines.append("[b]• %s[/b]" % skill_title)
		if not skill_summary.is_empty():
			lines.append("    %s" % skill_summary)
		var tools_line := "    Tools: %d declared" % dep_count
		if not unsatisfied.is_empty():
			tools_line += " ([color=#dd6b6b]%d unsatisfied — skill hidden until resolved[/color])" % unsatisfied.size()
		lines.append(tools_line)
		lines.append("")  # blank line between skills
	return "\n".join(lines)


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
