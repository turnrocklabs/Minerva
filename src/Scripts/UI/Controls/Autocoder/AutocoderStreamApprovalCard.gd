class_name AutocoderStreamApprovalCard
extends PanelContainer

signal approved(session_id: String)
signal rejected(session_id: String, feedback: String)
signal extract_requested(session_id: String)

@onready var _title_label: Label = %TitleLabel
@onready var _file_count_label: Label = %FileCountLabel
@onready var _summary_label: Label = %SummaryLabel
@onready var _review_details_container: VBoxContainer = %ReviewDetailsContainer
@onready var _review_details_label: Label = %ReviewDetailsLabel
@onready var _buttons_container: HBoxContainer = %ButtonsContainer
@onready var _extract_button: Button = %ExtractButton
@onready var _approve_button: Button = %ApproveButton
@onready var _request_changes_button: Button = %RequestChangesButton
@onready var _feedback_container: VBoxContainer = %FeedbackContainer
@onready var _feedback_input: TextEdit = %FeedbackInput
@onready var _submit_changes_button: Button = %SubmitChangesButton
@onready var _cancel_changes_button: Button = %CancelChangesButton
@onready var _status_label: Label = %StatusLabel

var _session_id: String = ""
var _archive_uri: String = ""
var _patch_uri: String = ""

func _ready():
	if _extract_button:
		_extract_button.pressed.connect(_on_extract_pressed)
	if _approve_button:
		_approve_button.pressed.connect(_on_approve_pressed)
	if _request_changes_button:
		_request_changes_button.pressed.connect(_on_request_changes_pressed)
	if _submit_changes_button:
		_submit_changes_button.pressed.connect(_on_submit_changes_pressed)
	if _cancel_changes_button:
		_cancel_changes_button.pressed.connect(_on_cancel_changes_pressed)
	if _feedback_container:
		_feedback_container.visible = false
	if _status_label:
		_status_label.visible = false


func setup(session_id: String, archive_uri: String, patch_uri: String, review_summary: String, file_count: int, review_results: Array = []) -> void:
	_session_id = session_id
	_archive_uri = archive_uri
	_patch_uri = patch_uri

	if _file_count_label:
		_file_count_label.text = "%d files changed" % file_count if file_count > 0 else ""

	if _summary_label:
		_summary_label.text = review_summary if not review_summary.is_empty() else "Generation complete. Ready for your review."

	# Build review details from individual model results
	if _review_details_container and _review_details_label:
		if review_results.is_empty():
			_review_details_container.visible = false
		else:
			var lines: Array[String] = []
			for result in review_results:
				if result is Dictionary:
					var model_name = str(result.get("model", result.get("agent_name", "Unknown")))
					var verdict = str(result.get("verdict", result.get("approved", "")))
					var issues = int(result.get("issue_count", result.get("issues", 0)))
					var line = "%s: %s" % [model_name, verdict]
					if issues > 0:
						line += " (%d issues)" % issues
					lines.append(line)
			if lines.is_empty():
				_review_details_container.visible = false
			else:
				_review_details_label.text = "\n".join(lines)
				_review_details_container.visible = true


func set_state(new_state: String) -> void:
	if has_meta("acted"):
		return
	set_meta("acted", true)

	if _buttons_container:
		_buttons_container.visible = false
	if _feedback_container:
		_feedback_container.visible = false

	if _status_label:
		_status_label.visible = true
		match new_state:
			"approved":
				_status_label.text = "Approved"
				_status_label.add_theme_color_override("font_color", Color(0.4, 0.9, 0.4))
				_set_border_color(Color(0.3, 0.8, 0.3))
			"rejected":
				_status_label.text = "Revision requested"
				_status_label.add_theme_color_override("font_color", Color(0.95, 0.7, 0.3))
				_set_border_color(Color(0.95, 0.7, 0.3))


func _set_border_color(color: Color) -> void:
	var style = get("theme_override_styles/panel")
	if style is StyleBoxFlat:
		var new_style = style.duplicate() as StyleBoxFlat
		new_style.border_color = color
		add_theme_stylebox_override("panel", new_style)


func _on_extract_pressed() -> void:
	extract_requested.emit(_session_id)


func _on_approve_pressed() -> void:
	if has_meta("acted"):
		return
	approved.emit(_session_id)


func _on_request_changes_pressed() -> void:
	if has_meta("acted"):
		return
	if _feedback_container:
		_feedback_container.visible = true
	if _request_changes_button:
		_request_changes_button.visible = false


func _on_submit_changes_pressed() -> void:
	if has_meta("acted"):
		return
	var feedback_text = ""
	if _feedback_input:
		feedback_text = _feedback_input.text.strip_edges()
	if feedback_text.is_empty():
		SingletonObject.create_toast_notification("Please describe what needs to change", ToastNotification.Type.WARNING)
		return
	rejected.emit(_session_id, feedback_text)


func _on_cancel_changes_pressed() -> void:
	if _feedback_container:
		_feedback_container.visible = false
	if _request_changes_button:
		_request_changes_button.visible = true
