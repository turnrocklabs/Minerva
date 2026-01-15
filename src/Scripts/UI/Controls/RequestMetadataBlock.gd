class_name RequestMetadataBlock
extends PanelContainer

## Collapsible block for displaying outgoing request metadata.
## Shows system prompt, tools, and other request details for debugging.

signal expanded_changed(is_expanded: bool)

@export_range(0.1, 2.0, 0.1) var expand_anim_duration: float = 0.5
@export var expand_transition_type: Tween.TransitionType = Tween.TRANS_SPRING
@export var expand_ease_type: Tween.EaseType = Tween.EASE_OUT
@export var expand_icon_color: Color = Color(0.16, 0.8, 0.4, 1.0)  # Greenish for outgoing

@onready var expand_button: Button = %ExpandButton
@onready var status_label: Label = %StatusLabel
@onready var content_container: PanelContainer = %ContentContainer

# Section controls
@onready var system_prompt_section: VBoxContainer = %SystemPromptSection
@onready var system_prompt_expand_button: Button = %SystemPromptExpandButton
@onready var system_prompt_scroll: ScrollContainer = %SystemPromptScrollContainer
@onready var system_prompt_content: RichTextLabel = %SystemPromptContent

@onready var tools_section: VBoxContainer = %ToolsSection
@onready var tools_expand_button: Button = %ToolsExpandButton
@onready var tools_scroll: ScrollContainer = %ToolsScrollContainer
@onready var tools_content: RichTextLabel = %ToolsContent

@onready var details_section: VBoxContainer = %DetailsSection
@onready var details_expand_button: Button = %DetailsExpandButton
@onready var details_scroll: ScrollContainer = %DetailsScrollContainer
@onready var details_content: RichTextLabel = %DetailsContent

var metadata: Dictionary = {}
var expanded: bool = false
var system_prompt_expanded: bool = false
var tools_expanded: bool = false
var details_expanded: bool = false

var content_size: float = 0.0
var expand_tween: Tween

static var _block_scene: PackedScene = null


## Factory method to create a RequestMetadataBlock from metadata
static func create(request_metadata: Dictionary) -> RequestMetadataBlock:
	# Lazy load to avoid circular dependency
	if _block_scene == null:
		_block_scene = load("res://Scenes/RequestMetadataBlock.tscn")

	var block = _block_scene.instantiate()
	block.metadata = request_metadata
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


func _update_content_size() -> void:
	await get_tree().process_frame
	content_size = content_container.size.y


## Update the visual display based on metadata
func _update_display() -> void:
	var tool_count = metadata.get("tool_count", 0)
	var model_name = metadata.get("model", "Unknown")

	# Update header label
	if tool_count > 0:
		status_label.text = "[Request] %s + %d tools" % [model_name, tool_count]
	else:
		status_label.text = "[Request] %s" % model_name
	status_label.modulate = Color(0.8, 1.0, 0.8)  # Light green

	# System Prompt section
	var system_prompt = metadata.get("system_prompt", "")
	if system_prompt.is_empty():
		system_prompt_section.hide()
	else:
		system_prompt_section.show()
		system_prompt_content.text = system_prompt

	# Tools section
	var tools: Array = metadata.get("tools", [])
	if tools.is_empty():
		tools_section.hide()
	else:
		tools_section.show()
		var tools_text = ""
		for tool in tools:
			var tool_name = tool.get("name", tool.get("function", {}).get("name", "unknown"))
			tools_text += "- %s\n" % tool_name
		tools_content.text = tools_text.strip_edges()

	# Details section
	var details_parts: PackedStringArray = []
	details_parts.append("Model: %s" % metadata.get("model", "Unknown"))
	details_parts.append("Messages: %d" % metadata.get("message_count", 0))
	if metadata.has("temperature"):
		details_parts.append("Temperature: %.1f" % metadata.get("temperature"))
	if metadata.has("max_tokens"):
		details_parts.append("Max Tokens: %d" % metadata.get("max_tokens"))
	if metadata.has("agent_mode"):
		details_parts.append("Agent Mode: %s" % ("Enabled" if metadata.get("agent_mode") else "Disabled"))

	details_content.text = "\n".join(details_parts)


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


## Toggle system prompt section visibility
func _on_system_prompt_expand_pressed() -> void:
	system_prompt_expanded = not system_prompt_expanded
	_animate_sub_collapse(system_prompt_expand_button, system_prompt_scroll, system_prompt_expanded)


## Toggle tools section visibility
func _on_tools_expand_pressed() -> void:
	tools_expanded = not tools_expanded
	_animate_sub_collapse(tools_expand_button, tools_scroll, tools_expanded)


## Toggle details section visibility
func _on_details_expand_pressed() -> void:
	details_expanded = not details_expanded
	_animate_sub_collapse(details_expand_button, details_scroll, details_expanded)


## Animate a sub-collapse section
func _animate_sub_collapse(button: Button, content: Control, is_expanded: bool) -> void:
	var tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	var sub_collapse_color := Color(1.0, 1.0, 1.0, 1.0)
	var sub_expanded_color := Color(0.5, 1.0, 0.5, 1.0)

	if is_expanded:
		content.show()
		tween.tween_property(button, "rotation", deg_to_rad(0.0), 0.2)
		tween.parallel().tween_property(button, "self_modulate", sub_expanded_color, 0.2)
	else:
		tween.tween_property(button, "rotation", deg_to_rad(-90.0), 0.2)
		tween.parallel().tween_property(button, "self_modulate", sub_collapse_color, 0.2)
		tween.tween_callback(content.hide)


## Get combined content for clipboard
func _get_combined_content() -> String:
	var parts: PackedStringArray = []
	parts.append("## Request Metadata\n")

	if metadata.has("system_prompt") and not metadata.get("system_prompt", "").is_empty():
		parts.append("### System Prompt:\n```\n%s\n```\n" % metadata.get("system_prompt"))

	var tools: Array = metadata.get("tools", [])
	if not tools.is_empty():
		parts.append("### Tools (%d):\n" % tools.size())
		for tool in tools:
			var tool_name = tool.get("name", tool.get("function", {}).get("name", "unknown"))
			parts.append("- %s" % tool_name)
		parts.append("")

	parts.append("### Details:\n")
	parts.append("- Model: %s" % metadata.get("model", "Unknown"))
	parts.append("- Messages: %d" % metadata.get("message_count", 0))

	return "\n".join(parts)


## Copy to clipboard
func _on_copy_button_pressed() -> void:
	DisplayServer.clipboard_set(_get_combined_content())


## Create a note from the metadata
func _on_notes_button_pressed() -> void:
	var note_title = "Request: %s" % metadata.get("model", "Unknown")
	var note_content = _get_combined_content()
	var new_note = Note.create_text_note(note_title, note_content)
	SingletonObject.notes_container.add_note(new_note)
	SingletonObject.main_ui.set_notes_pane_visible(true)
