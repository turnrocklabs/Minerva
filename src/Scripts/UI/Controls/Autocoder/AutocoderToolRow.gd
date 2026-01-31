class_name AutocoderToolRow
extends PanelContainer

@onready var _tool_label: Label = %ToolLabel
@onready var _status_label: RichTextLabel = %StatusLabel
@onready var _description_label: Label = %DescriptionLabel
@onready var _command_label: Label = %CommandLabel
@onready var _output_toggle: Button = %OutputToggleButton
@onready var _output_container: VBoxContainer = %OutputContainer
@onready var _return_code_label: Label = %ReturnCodeLabel
@onready var _stdout_label: Label = %StdoutLabel
@onready var _stderr_label: Label = %StderrLabel


func _ready() -> void:
	_output_toggle.pressed.connect(_on_output_toggle_pressed)


func setup(tool: String, description: String, command: String, path: String, status: String, returncode: Variant, stdout: String, stderr: String) -> void:
	_tool_label.text = tool if not tool.is_empty() else "tool_call"
	_apply_status_style(status)
	_description_label.text = description
	_description_label.visible = not description.is_empty()

	var detail_line = command if not command.is_empty() else path
	_command_label.text = detail_line
	_command_label.visible = not detail_line.is_empty()

	var has_output = false
	if returncode != null and str(returncode) != "":
		_return_code_label.text = "Return code: %s" % str(returncode)
		_return_code_label.visible = true
		has_output = true
	else:
		_return_code_label.visible = false

	_stdout_label.text = stdout
	_stdout_label.visible = not stdout.is_empty()
	if _stdout_label.visible:
		has_output = true

	_stderr_label.text = stderr
	_stderr_label.visible = not stderr.is_empty()
	if _stderr_label.visible:
		has_output = true

	_output_toggle.visible = has_output
	_output_container.visible = has_output and _output_toggle.button_pressed


func update_completion(status: String, returncode: Variant, stdout: String, stderr: String) -> void:
	"""Update tool row with completion data (status, output, etc)"""
	_apply_status_style(status)

	var has_output = false
	if returncode != null and str(returncode) != "":
		_return_code_label.text = "Return code: %s" % str(returncode)
		_return_code_label.visible = true
		has_output = true
	else:
		_return_code_label.visible = false

	_stdout_label.text = stdout
	_stdout_label.visible = not stdout.is_empty()
	if _stdout_label.visible:
		has_output = true

	_stderr_label.text = stderr
	_stderr_label.visible = not stderr.is_empty()
	if _stderr_label.visible:
		has_output = true

	_output_toggle.visible = has_output
	_output_container.visible = has_output and _output_toggle.button_pressed


func _apply_status_style(status: String) -> void:
	_status_label.clear()

	var status_text = status.replace("_", " ")  # Remove underscores

	match status.to_lower():
		"in_progress":
			# Pulsing blue text for in progress
			_status_label.append_text("[pulse freq=2.0 color=#7fddff ease=-2.0]%s[/pulse]" % status_text)
		"complete", "completed", "success":
			# Green text for complete
			_status_label.push_color(Color(0.4, 1.0, 0.4))
			_status_label.append_text(status_text)
			_status_label.pop()
		"error", "failed":
			# Red text for errors
			_status_label.push_color(Color(1.0, 0.4, 0.4))
			_status_label.append_text(status_text)
			_status_label.pop()
		_:
			# Gray text for other states
			_status_label.push_color(Color(0.6, 0.6, 0.6))
			_status_label.append_text(status_text)
			_status_label.pop()


func _on_output_toggle_pressed() -> void:
	_output_container.visible = _output_toggle.button_pressed
