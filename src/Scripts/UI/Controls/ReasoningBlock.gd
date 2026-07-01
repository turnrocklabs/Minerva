class_name ReasoningBlock
extends PanelContainer

## Collapsible block for displaying a model reasoning/thinking segment.
## Mirrors ToolCallBlock's single outer-collapse pattern, minus the
## arguments/result sub-collapses (reasoning has no structured sub-parts).
## Reasoning is display-only metadata; this widget never feeds prompt history.

signal expanded_changed(is_expanded: bool)

@export_range(0.1, 2.0, 0.1) var expand_anim_duration: float = 0.5
@export var expand_transition_type: Tween.TransitionType = Tween.TRANS_SPRING
@export var expand_ease_type: Tween.EaseType = Tween.EASE_OUT
@export var expand_icon_color: Color = Color(0.7, 0.55, 1.0, 1.0)

@onready var expand_button: Button = %ExpandButton
@onready var status_label: Label = %StatusLabel
@onready var content_container: PanelContainer = %ContentContainer
@onready var reasoning_content: RichTextLabel = %ReasoningContent

var reasoning_text: String = ""
var kind: String = "thinking"  # "thinking" | "summary"
var redacted: bool = false
var expanded: bool = false

var content_size: float = 0.0
var expand_tween: Tween

static var _reasoning_block_scene: PackedScene = null


## Factory method to create a ReasoningBlock from a reasoning segment dict.
## Segment shape: {kind: String, text: String, redacted: bool, order: int}
static func create(segment: Dictionary) -> ReasoningBlock:
	# Lazy load to avoid circular dependency (scene references this script)
	if _reasoning_block_scene == null:
		_reasoning_block_scene = load("res://Scenes/ReasoningBlock.tscn")

	var block = _reasoning_block_scene.instantiate()
	block.reasoning_text = segment.get("text", "")
	block.kind = segment.get("kind", "thinking")
	block.redacted = segment.get("redacted", false)
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


## Update the visual display based on current state
func _update_display() -> void:
	var label_text := "Reasoning summary" if kind == "summary" else "Thinking"
	status_label.text = "💭 %s" % label_text
	status_label.modulate = Color(0.78, 0.72, 0.97)

	if redacted or reasoning_text.is_empty():
		reasoning_content.text = "[i](reasoning hidden by provider)[/i]"
	else:
		reasoning_content.text = reasoning_text


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
