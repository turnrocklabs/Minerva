class_name AutocoderLLMCard
extends PanelContainer

## Live streaming LLM response card
## Shows real-time generation with model info, streaming text, and tool calls

var request_id: String = ""
var _is_complete: bool = false
var _accumulated_text: String = ""
var _tool_calls: Array[Dictionary] = []
var _is_expanded: bool = true
var _pulse_tween: Tween

@onready var _header_label: Label = %HeaderLabel
@onready var _expand_button: Button = %ExpandButton
@onready var _copy_button: Button = %CopyButton
@onready var _status_label: Label = %StatusLabel
@onready var _content_label: RichTextLabel = %ContentLabel
@onready var _content_container: VBoxContainer = $MarginContainer/VBoxContainer/ContentContainer
@onready var _generating_overlay: ColorRect = %GeneratingOverlay
@onready var _tool_calls_container: VBoxContainer = %ToolCallsContainer
@onready var _usage_label: Label = %UsageLabel


func _ready() -> void:
	_expand_button.pressed.connect(_on_expand_toggled)
	_copy_button.pressed.connect(_on_copy_pressed)


func setup_request(req_id: String, model: String, message_count: int, messages: Array = []) -> void:
	"""Initialize card with request information"""
	request_id = req_id
	_is_complete = false
	_accumulated_text = ""
	_tool_calls.clear()

	# Extract short model name
	var model_short = model
	if "/" in model:
		model_short = model.split("/")[-1]

	_header_label.text = "🤖 %s (%d messages)" % [model_short, message_count]
	_status_label.text = "⏳ Generating..."
	_content_label.clear()
	_usage_label.text = ""
	_usage_label.visible = false

	# Clear any existing tool call displays
	for child in _tool_calls_container.get_children():
		child.queue_free()

	# Start pulsating overlay animation
	_start_pulse_animation()

	# Show initial request context (NO TRUNCATION)
	if messages.size() > 0:
		var context_text = "[b]Request Context:[/b]\n"
		for msg in messages:
			if msg is Dictionary:
				var role = str(msg.get("role", "unknown"))
				var content = str(msg.get("content", ""))
				context_text += "[color=gray]%s:[/color] %s\n\n" % [role, content]
		_accumulated_text = context_text
		_update_content_display()


func append_chunk(content_delta: String) -> void:
	"""Append streaming text chunk"""
	if _is_complete:
		return

	_accumulated_text += content_delta
	_update_content_display()


func add_tool_call(tool_name: String, tool_input: Variant) -> void:
	"""Add a tool call to the display"""
	var tool_info = {
		"name": tool_name,
		"input": tool_input
	}
	_tool_calls.append(tool_info)

	# Create a visual row for the tool call
	var tool_row = HBoxContainer.new()
	_tool_calls_container.add_child(tool_row)

	var icon_label = Label.new()
	icon_label.text = "🔧"
	tool_row.add_child(icon_label)

	var tool_label = Label.new()
	tool_label.text = tool_name
	tool_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tool_row.add_child(tool_label)

	# Show abbreviated input if it's a dictionary
	if tool_input is Dictionary:
		var input_str = JSON.stringify(tool_input)
		if input_str.length() > 100:
			input_str = input_str.substr(0, 100) + "..."
		var input_label = Label.new()
		input_label.text = input_str
		input_label.modulate = Color(0.7, 0.7, 0.7)
		tool_row.add_child(input_label)


func mark_complete(finish_reason: String, usage: Dictionary) -> void:
	"""Mark the generation as complete"""
	_is_complete = true

	# Stop pulsating animation
	_stop_pulse_animation()

	# Update status based on finish reason
	match finish_reason:
		"end_turn", "stop":
			_status_label.text = "✅ Complete"
		"max_tokens":
			_status_label.text = "⚠️ Max tokens reached"
		"tool_use":
			_status_label.text = "🔧 Tool calls"
		_:
			_status_label.text = "✅ Done (%s)" % finish_reason

	# Show usage stats if available
	if usage and not usage.is_empty():
		var input_tokens = usage.get("input_tokens", 0)
		var output_tokens = usage.get("output_tokens", 0)
		_usage_label.text = "Tokens: %d in / %d out" % [input_tokens, output_tokens]
		_usage_label.visible = true


func mark_error(error_message: String) -> void:
	"""Mark the generation as errored"""
	_is_complete = true
	_status_label.text = "❌ Error"

	# Append error to content
	_accumulated_text += "\n\n[ERROR] %s" % error_message
	_update_content_display()


func _update_content_display() -> void:
	"""Update the rich text display with accumulated content"""
	_content_label.clear()

	if _accumulated_text.is_empty():
		_content_label.append_text("[i]Waiting for response...[/i]")
		return

	# Display the accumulated text (basic BBCode support)
	_content_label.append_text(_accumulated_text)


func _start_pulse_animation() -> void:
	"""Start pulsating overlay animation while generating"""
	_generating_overlay.visible = true

	if _pulse_tween:
		_pulse_tween.kill()

	_pulse_tween = create_tween()
	_pulse_tween.set_loops()
	_pulse_tween.tween_property(_generating_overlay, "modulate:a", 0.3, 1.0).from(0.05)
	_pulse_tween.tween_property(_generating_overlay, "modulate:a", 0.05, 1.0).from(0.3)


func _stop_pulse_animation() -> void:
	"""Stop pulsating animation when complete"""
	if _pulse_tween:
		_pulse_tween.kill()
		_pulse_tween = null
	_generating_overlay.visible = false


func _on_expand_toggled() -> void:
	"""Toggle expand/collapse of content"""
	_is_expanded = !_is_expanded
	_content_container.visible = _is_expanded
	_tool_calls_container.visible = _is_expanded
	_usage_label.visible = _is_expanded and not _usage_label.text.is_empty()
	_expand_button.text = "▼" if _is_expanded else "▶"


func _on_copy_pressed() -> void:
	"""Copy all content to clipboard"""
	var copy_text = ""

	# Add header info
	copy_text += _header_label.text + " - " + _status_label.text + "\n"
	copy_text += "=".repeat(50) + "\n\n"

	# Add main content
	copy_text += _accumulated_text + "\n\n"

	# Add tool calls
	if _tool_calls.size() > 0:
		copy_text += "Tool Calls:\n"
		for tool in _tool_calls:
			copy_text += "- %s: %s\n" % [tool.get("name", ""), JSON.stringify(tool.get("input", {}))]
		copy_text += "\n"

	# Add usage stats
	if _usage_label.visible:
		copy_text += _usage_label.text + "\n"

	DisplayServer.clipboard_set(copy_text)

	# Visual feedback
	_copy_button.text = "✅ Copied!"
	await get_tree().create_timer(1.5).timeout
	_copy_button.text = "📋 Copy"