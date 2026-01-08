class_name ToolCallBlock
extends PanelContainer

## Collapsible block for displaying tool call arguments and results.
## Used in MessageMarkdown to show tool execution details inline.

signal expanded_changed(is_expanded: bool)

@export_range(0.1, 2.0, 0.1) var expand_anim_duration: float = 0.5
@export var expand_transition_type: Tween.TransitionType = Tween.TRANS_SPRING
@export var expand_ease_type: Tween.EaseType = Tween.EASE_OUT
@export var expand_icon_color: Color = Color(0.16, 1.0, 1.0, 1.0)

@onready var expand_button: Button = %ExpandButton
@onready var status_label: Label = %StatusLabel
@onready var content_container: PanelContainer = %ContentContainer
@onready var tool_name_label: Label = %ToolNameLabel
@onready var arguments_section: VBoxContainer = %ArgumentsSection
@onready var arguments_expand_button: Button = %ArgumentsExpandButton
@onready var arguments_content: RichTextLabel = %ArgumentsContent
@onready var result_section: VBoxContainer = %ResultSection
@onready var result_expand_button: Button = %ResultExpandButton
@onready var result_content: RichTextLabel = %ResultContent

var tool_id: String = ""
var tool_name: String = ""
var arguments: Dictionary = {}
var result: String = ""
var status: String = "calling"  # "calling", "done", "error"
var expanded: bool = false
var arguments_expanded: bool = false
var result_expanded: bool = false

var content_size: float = 0.0
var expand_tween: Tween

static var _tool_call_block_scene: PackedScene = null


## Factory method to create a ToolCallBlock from execution data
static func create(execution_data: Dictionary) -> ToolCallBlock:
	# Lazy load to avoid circular dependency (scene references this script)
	if _tool_call_block_scene == null:
		_tool_call_block_scene = load("res://Scenes/ToolCallBlock.tscn")

	var block = _tool_call_block_scene.instantiate()
	block.tool_id = execution_data.get("call_id", "")
	block.tool_name = execution_data.get("tool_name", "")
	block.arguments = execution_data.get("arguments", {})
	block.result = execution_data.get("result", "")
	block.status = execution_data.get("status", "calling")
	return block


func _ready() -> void:
	_update_display()

	# Start collapsed
	await get_tree().create_timer(0.05).timeout
	_update_content_size()
	if not expanded:
		content_container.custom_minimum_size.y = 0
		expand_button.rotation = deg_to_rad(-90.0)
		expand_button.modulate = expand_icon_color
		content_container.hide()

	# Sub-collapse buttons start collapsed (rotation set in scene file)


func _update_content_size() -> void:
	await get_tree().process_frame
	content_size = content_container.size.y


## Update the visual display based on current state
func _update_display() -> void:
	# Update status label (short, no tool name)
	match status:
		"calling":
			status_label.text = "[Agent] Calling"
			status_label.modulate = Color.WHITE
		"done":
			status_label.text = "[Agent] Done"
			status_label.modulate = Color(0.6, 1.0, 0.6)  # Light green
		"error":
			status_label.text = "[Agent] Error"
			status_label.modulate = Color(1.0, 0.6, 0.6)  # Light red

	# Update tool name label (inside content area)
	tool_name_label.text = tool_name

	# Update arguments display - pretty print with 2-space indent
	var args_text = JSON.stringify(arguments, "  ")
	arguments_content.text = args_text

	# Update result display
	if result.is_empty():
		result_section.hide()
	else:
		result_section.show()
		# Try to parse as JSON for pretty printing
		var parsed = JSON.parse_string(result)
		if parsed != null:
			result_content.text = JSON.stringify(parsed, "  ")
		else:
			result_content.text = result


## Set the result and update display
func set_result(result_text: String, is_error: bool = false) -> void:
	result = result_text
	status = "error" if is_error else "done"
	_update_display()

	# Update content size after result is added
	await get_tree().process_frame
	_update_content_size()


func _on_expand_button_pressed() -> void:
	expanded = not expanded
	if expanded:
		expand_content()
	else:
		contract_content()
	expanded_changed.emit(expanded)


func expand_content() -> void:
	if expand_tween and expand_tween.is_running():
		expand_tween.kill()
		return

	if content_size == 0:
		_update_content_size()

	content_container.show()
	expand_tween = create_tween().set_ease(expand_ease_type).set_trans(expand_transition_type)
	expand_tween.finished.connect(_enable_expand_button)
	expand_button.disabled = true

	expand_tween.tween_property(content_container, "custom_minimum_size:y", content_size, expand_anim_duration)
	expand_tween.parallel().tween_property(expand_button, "rotation", deg_to_rad(0.0), expand_anim_duration)
	expand_tween.parallel().tween_property(expand_button, "modulate", Color.WHITE, expand_anim_duration)


func contract_content() -> void:
	if expand_tween and expand_tween.is_running():
		expand_tween.kill()
		return

	if content_size == 0:
		_update_content_size()

	expand_tween = create_tween().set_ease(expand_ease_type).set_trans(expand_transition_type)
	expand_tween.finished.connect(_enable_expand_button)
	expand_button.disabled = true

	expand_tween.tween_property(content_container, "custom_minimum_size:y", 0, expand_anim_duration)
	expand_tween.parallel().tween_property(expand_button, "rotation", deg_to_rad(-90.0), expand_anim_duration)
	expand_tween.parallel().tween_property(expand_button, "modulate", expand_icon_color, expand_anim_duration)

	await get_tree().create_timer(expand_anim_duration - 0.1).timeout
	content_container.hide()


func _enable_expand_button() -> void:
	expand_button.disabled = false


## Toggle arguments section visibility
func _on_arguments_expand_pressed() -> void:
	arguments_expanded = not arguments_expanded
	_animate_sub_collapse(arguments_expand_button, arguments_content, arguments_expanded)


## Toggle result section visibility
func _on_result_expand_pressed() -> void:
	result_expanded = not result_expanded
	_animate_sub_collapse(result_expand_button, result_content, result_expanded)


## Animate a sub-collapse section
func _animate_sub_collapse(button: Button, content: Control, is_expanded: bool) -> void:
	var tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	var sub_collapse_color := Color(1.0, 1.0, 1.0, 1.0)  # White for collapsed
	var sub_expanded_color := Color(0.5, 1.0, 0.5, 1.0)  # Light green for expanded

	if is_expanded:
		content.show()
		tween.tween_property(button, "rotation", deg_to_rad(0.0), 0.2)
		tween.parallel().tween_property(button, "self_modulate", sub_expanded_color, 0.2)
	else:
		tween.tween_property(button, "rotation", deg_to_rad(-90.0), 0.2)
		tween.parallel().tween_property(button, "self_modulate", sub_collapse_color, 0.2)
		tween.tween_callback(content.hide)


## Get combined content of arguments and result for actions
func _get_combined_content() -> String:
	var content_parts: PackedStringArray = []
	content_parts.append("## Tool: %s\n" % tool_name)
	content_parts.append("### Arguments:\n```json\n%s\n```\n" % JSON.stringify(arguments, "  "))
	if not result.is_empty():
		content_parts.append("### Result:\n```json\n%s\n```" % result)
	return "\n".join(content_parts)


## Copy arguments and result to clipboard
func _on_copy_button_pressed() -> void:
	DisplayServer.clipboard_set(_get_combined_content())


## Create a note from the tool call
func _on_notes_button_pressed() -> void:
	var note_title = "Tool Call: %s" % tool_name
	var note_content = _get_combined_content()
	var new_note = Note.create_text_note(note_title, note_content)
	SingletonObject.notes_container.add_note(new_note)
	SingletonObject.main_ui.set_notes_pane_visible(true)


## Send to editor
func _on_editor_button_pressed() -> void:
	var ep: EditorPane = SingletonObject.editor_pane
	var content_text = _get_combined_content()

	# Get or create a text editor tab
	var active_tab: Editor
	if ep.Tabs.get_tab_count() > 0:
		active_tab = ep.Tabs.get_current_tab_control()
		if active_tab.type == Editor.Type.GRAPHICS:
			active_tab = ep.add(Editor.Type.TEXT, null, "Tool Call", null)
	else:
		active_tab = ep.add(Editor.Type.TEXT, null, "Tool Call", null)

	# Set the content
	if active_tab and active_tab.code_edit:
		active_tab.code_edit.text = content_text

	ep.update_tabs_icon()
