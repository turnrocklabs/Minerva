class_name AutocoderLogsViewer
extends VBoxContainer

signal entry_added

static var autocoder_logs_scene = preload("res://Scripts/UI/Controls/Autocoder/AutocoderLogsViewer.tscn")

static func create() -> AutocoderLogsViewer:
	return autocoder_logs_scene.instantiate()


var session_id: String = ""
var user_id: String = ""
var subscribed_topics: PackedStringArray = PackedStringArray()

var _store := AutocoderLogStore.new()
var _saved_snapshot: String = ""
var _status_override: String = ""
var _request_review_sent: bool = false
var _approve_sent: bool = false

const ACTION_ROW_SCENE = preload("res://Scripts/UI/Controls/Autocoder/AutocoderActionRow.tscn")
const ISSUE_ROW_SCENE = preload("res://Scripts/UI/Controls/Autocoder/AutocoderIssueRow.tscn")
const TOOL_ROW_SCENE = preload("res://Scripts/UI/Controls/Autocoder/AutocoderToolRow.tscn")
const RAW_ROW_SCENE = preload("res://Scripts/UI/Controls/Autocoder/AutocoderRawJsonRow.tscn")
const LLM_CARD_SCENE = preload("res://Scripts/UI/Controls/Autocoder/AutocoderLLMCard.tscn")

@onready var _session_label: Label = %SessionLabel
@onready var _status_label: Label = %StatusLabel
@onready var _spinner_label: Label = %SpinnerLabel
@onready var _advanced_toggle: CheckBox = %AdvancedToggle

@onready var _summary_panel: PanelContainer = %SummaryPanel
@onready var _review_state_label: Label = %ReviewStateLabel
@onready var _review_summary_label: Label = %ReviewSummaryLabel

@onready var _review_panel: PanelContainer = %ReviewPanel
@onready var _request_review_button: Button = %RequestReviewButton
@onready var _approve_button: Button = %ApproveButton

@onready var _artifacts_panel: PanelContainer = %ArtifactsPanel
@onready var _patch_value_label: Label = %PatchValueLabel
@onready var _archive_value_label: Label = %ArchiveValueLabel
@onready var _patch_copy_button: Button = %PatchCopyButton
@onready var _archive_copy_button: Button = %ArchiveCopyButton

@onready var _timeline_header: HBoxContainer = %TimelineHeader
@onready var _timeline_list: VBoxContainer = %TimelineList
@onready var _issues_header: HBoxContainer = %IssuesHeader
@onready var _issues_list: VBoxContainer = %IssuesList

@onready var _advanced_section: VBoxContainer = %AdvancedSection
@onready var _raw_list: VBoxContainer = %RawList
@onready var _llm_list: VBoxContainer = %LlmList

# Track active LLM requests for streaming updates
var _active_llm_cards: Dictionary = {}  # request_id -> AutocoderLLMCard

# Track action rows for status updates
var _action_rows: Dictionary = {}  # action_id -> AutocoderActionRow
var _tool_rows: Dictionary = {}  # action_id -> AutocoderToolRow


func _ready() -> void:
	# Null safety checks for @onready nodes
	if not _request_review_button:
		push_warning("AutocoderLogsViewer: _request_review_button not found")
	else:
		_request_review_button.pressed.connect(_on_request_review_pressed)
	
	if not _approve_button:
		push_warning("AutocoderLogsViewer: _approve_button not found")
	else:
		_approve_button.pressed.connect(_on_approve_pressed)
	
	if not _advanced_toggle:
		push_warning("AutocoderLogsViewer: _advanced_toggle not found")
	else:
		_advanced_toggle.toggled.connect(_on_advanced_toggled)
	
	if not _patch_copy_button:
		push_warning("AutocoderLogsViewer: _patch_copy_button not found")
	else:
		_patch_copy_button.pressed.connect(_on_patch_copy_pressed)
	
	if not _archive_copy_button:
		push_warning("AutocoderLogsViewer: _archive_copy_button not found")
	else:
		_archive_copy_button.pressed.connect(_on_archive_copy_pressed)

	_reset_view()


func configure_session(user: String, session: String, topics: PackedStringArray) -> void:
	user_id = user
	session_id = session
	subscribed_topics = topics.duplicate()

	_store.reset()
	_reset_view()
	_update_status_labels()


func add_iteration_entry(_topic: String, payload: Dictionary) -> void:
	if not payload:
		return

	_store.raw_events.append({"title": "Iteration", "data": payload})
	var updates = _store.apply_iteration(payload)

	for issue in updates.get("new_issues", []):
		_add_issue_row(issue)

	_update_summary_panel()
	_update_review_panel(payload)
	_update_artifacts_panel()
	_update_status_labels()

	if _advanced_toggle.button_pressed:
		_add_raw_row("Iteration", payload)

	entry_added.emit()


func add_action_entry(_topic: String, payload: Dictionary) -> void:
	if not payload:
		return

	var action_type = str(payload.get("action_type", ""))
	_store.raw_events.append({"title": "Action: %s" % action_type, "data": payload})

	var result = _store.register_action(payload)
	if not result.get("accepted", false):
		return

	match result.get("kind", "action"):
		"issue":
			_add_issue_row(result.get("issue", {}))
		"tool":
			_add_tool_row(payload)
		_:
			_add_action_row(payload)

	_update_status_labels()

	if _advanced_toggle.button_pressed:
		_add_raw_row("Action: %s" % action_type, payload)

	entry_added.emit()


func add_telemetry_entry(_topic: String, payload: Variant) -> void:
	if not (payload is Dictionary):
		return

	var event_type = str(payload.get("type", ""))

	# Handle different event types for live streaming display
	match event_type:
		"request":
			_handle_llm_request(payload)
		"response_chunk":
			_handle_llm_chunk(payload)
		"response_complete":
			_handle_llm_complete(payload)
		"error":
			_handle_llm_error(payload)
		"tool_call":
			_handle_llm_tool_call(payload)

	# Store non-chunk events for advanced view
	if event_type != "response_chunk":
		_store.llm_events.append(payload)

	if _advanced_toggle.button_pressed and event_type != "response_chunk":
		_add_llm_row(payload)

	entry_added.emit()


func mark_saved_snapshot() -> void:
	_saved_snapshot = _store.get_snapshot()


func is_saved() -> bool:
	return _saved_snapshot == _store.get_snapshot()


func export_text() -> String:
	var data = {
		"session_id": session_id,
		"user_id": user_id,
		"status": _store.current_status,
		"review_state": _store.review_state,
		"ai_review_summary": _store.ai_review_summary,
		"patch_uri": _store.patch_uri,
		"archive_uri": _store.archive_uri,
		"actions": _store.actions_by_id.values(),
		"issues": _store.issues,
		"raw_events": _store.raw_events,
		"llm_events": _store.llm_events
	}
	return JSON.stringify(data, "  ")


func _reset_view() -> void:
	if _session_label:
		_session_label.text = "Session: %s" % (session_id if not session_id.is_empty() else "-")
	if _status_label:
		_status_label.text = "Idle"
	if _spinner_label:
		_spinner_label.visible = false

	if _summary_panel:
		_summary_panel.visible = false
	if _review_panel:
		_review_panel.visible = false
	if _artifacts_panel:
		_artifacts_panel.visible = false

	if _advanced_toggle:
		_advanced_toggle.button_pressed = false
	if _advanced_section:
		_advanced_section.visible = false

	_request_review_sent = false
	_approve_sent = false
	_status_override = ""

	if _timeline_list:
		_clear_list(_timeline_list)
	if _issues_list:
		_clear_list(_issues_list)
	if _raw_list:
		_clear_list(_raw_list)
	if _llm_list:
		_clear_list(_llm_list)

	_active_llm_cards.clear()
	_action_rows.clear()
	_tool_rows.clear()

	_update_list_headers()


func _update_summary_panel() -> void:
	var review_state = _store.review_state
	var summary = _store.ai_review_summary
	var counts_line = _build_review_counts_line()

	if _review_state_label:
		_review_state_label.text = ""
	if _review_summary_label:
		_review_summary_label.text = ""

	if not review_state.is_empty() and _review_state_label:
		_review_state_label.text = "Review state: %s" % review_state

	var summary_lines: Array[String] = []
	if not summary.is_empty():
		summary_lines.append(summary)
	if not counts_line.is_empty():
		summary_lines.append(counts_line)

	if _review_summary_label:
		_review_summary_label.text = "\n".join(summary_lines)

	if _summary_panel:
		_summary_panel.visible = (not review_state.is_empty()) or (not summary_lines.is_empty())


func _update_review_panel(payload: Dictionary) -> void:
	if _store.review_state == "complete":
		_status_override = ""
		_request_review_sent = false
		_approve_sent = false
		if _review_panel:
			_review_panel.visible = false
		if _request_review_button:
			_request_review_button.disabled = true
		if _approve_button:
			_approve_button.disabled = true
		return

	if _store.review_state == "awaiting_user":
		if payload.has("review_result"):
			_request_review_sent = false

		if _review_panel:
			_review_panel.visible = true
		if _request_review_button:
			_request_review_button.disabled = _request_review_sent
		if _approve_button:
			_approve_button.disabled = _approve_sent
		return

	if _review_panel:
		_review_panel.visible = false
	if _request_review_button:
		_request_review_button.disabled = true
	if _approve_button:
		_approve_button.disabled = true


func _update_artifacts_panel() -> void:
	var has_patch = not _store.patch_uri.is_empty()
	var has_archive = not _store.archive_uri.is_empty()

	if not has_patch and not has_archive:
		if _artifacts_panel:
			_artifacts_panel.visible = false
		return

	if _artifacts_panel:
		_artifacts_panel.visible = true
	if _patch_value_label:
		_patch_value_label.text = _store.patch_uri if has_patch else "-"
	if _archive_value_label:
		_archive_value_label.text = _store.archive_uri if has_archive else "-"
	if _patch_copy_button:
		_patch_copy_button.disabled = not has_patch
	if _archive_copy_button:
		_archive_copy_button.disabled = not has_archive


func _update_status_labels() -> void:
	var is_running = _store.has_running_action()
	if _status_label:
		_status_label.text = AutocoderLogFormatter.format_status_label(
			_store.review_state,
			_store.current_status,
			is_running,
			_status_override
		)
	if _spinner_label:
		_spinner_label.visible = is_running


func _add_action_row(payload: Dictionary) -> void:
	var action_id = str(payload.get("action_id", ""))
	var action_type = str(payload.get("action_type", ""))
	var status = str(payload.get("status", ""))

	# Check if we already have a row for this action_id
	if not action_id.is_empty() and _action_rows.has(action_id):
		# Update existing row
		var existing_row: AutocoderActionRow = _action_rows[action_id]
		existing_row.update_status(status)
		return

	# Create new row
	var row: AutocoderActionRow = ACTION_ROW_SCENE.instantiate()
	var summary = AutocoderLogFormatter.format_action_summary(action_type, payload)
	var secondary = AutocoderLogFormatter.format_action_secondary(action_type, payload)
	if _timeline_list:
		_timeline_list.add_child(row)
	row.setup(summary, status, secondary)

	# Track the row by action_id for future updates
	if not action_id.is_empty():
		_action_rows[action_id] = row

	_update_list_headers()


func _add_tool_row(payload: Dictionary) -> void:
	var action_id = str(payload.get("action_id", ""))
	var details = payload.get("details", {})
	var tool = str(details.get("tool", ""))
	var description = str(details.get("description", ""))
	var command = str(details.get("command", ""))
	var path = str(details.get("path", ""))
	var status = str(payload.get("status", ""))
	var returncode = details.get("returncode", null)
	var stdout = str(details.get("stdout", ""))
	var stderr = str(details.get("stderr", ""))

	# Check if we already have a row for this action_id
	if not action_id.is_empty() and _tool_rows.has(action_id):
		# Update existing row with completion data
		var existing_row: AutocoderToolRow = _tool_rows[action_id]
		existing_row.update_completion(status, returncode, stdout, stderr)
		return

	# Format path for read_file
	if tool == "read_file":
		var start_line = details.get("start_line", "")
		var end_line = details.get("end_line", "")
		if not str(start_line).is_empty() and not str(end_line).is_empty():
			path = "%s:%s-%s" % [path, str(start_line), str(end_line)]

	# Create new row
	var row: AutocoderToolRow = TOOL_ROW_SCENE.instantiate()
	if _timeline_list:
		_timeline_list.add_child(row)
	row.setup(tool, description, command, path, status, returncode, stdout, stderr)

	# Track the row by action_id for future updates
	if not action_id.is_empty():
		_tool_rows[action_id] = row

	_update_list_headers()


func _add_issue_row(issue: Dictionary) -> void:
	var row: AutocoderIssueRow = ISSUE_ROW_SCENE.instantiate()
	var location = AutocoderLogFormatter.format_issue_title(issue)
	var severity = str(issue.get("severity", ""))
	var summary = str(issue.get("summary", ""))
	var excerpt = str(issue.get("code_excerpt", ""))
	var has_fix = bool(issue.get("has_fix", false))
	if _issues_list:
		_issues_list.add_child(row)
	row.setup(location, severity, summary, excerpt, has_fix)
	_update_list_headers()


func _add_raw_row(title: String, data: Variant) -> void:
	var row: AutocoderRawJsonRow = RAW_ROW_SCENE.instantiate()
	if _raw_list:
		_raw_list.add_child(row)
	row.setup(title, data)


func _add_llm_row(payload: Dictionary) -> void:
	var title = "LLM: %s" % str(payload.get("type", "event"))
	var row: AutocoderRawJsonRow = RAW_ROW_SCENE.instantiate()
	if _llm_list:
		_llm_list.add_child(row)
	row.setup(title, payload)


func _on_request_review_pressed() -> void:
	if session_id.is_empty() or user_id.is_empty():
		SingletonObject.ErrorDisplay("Review Request", "Missing session or user id.")
		return

	var adapter = _get_adapter()
	if not adapter:
		SingletonObject.ErrorDisplay("Review Request", "Autocoder not connected.")
		return

	# Show dialog to get custom prompt
	var dialog = _create_review_request_dialog()
	var prompt_edit: TextEdit = dialog.get_node("%CustomPromptEdit")

	# Use a dictionary to capture values from lambda
	var result = {"confirmed": false, "custom_prompt": ""}

	dialog.confirmed.connect(
		func():
			result["confirmed"] = true
			result["custom_prompt"] = prompt_edit.text.strip_edges()
	)

	dialog.canceled.connect(
		func():
			result["confirmed"] = false
	)

	dialog.popup_centered()

	# Wait for dialog to close
	await dialog.visibility_changed

	if not dialog.visible:
		dialog.queue_free()
		if not result["confirmed"]:
			return

	var custom_prompt = result["custom_prompt"]

	_request_review_button.disabled = true
	_status_override = "Review started"

	var ok = await adapter.request_review(user_id, session_id, custom_prompt)
	if not ok:
		_request_review_button.disabled = false
		_status_override = ""
		return

	_request_review_sent = true
	_update_status_labels()


func _on_approve_pressed() -> void:
	if session_id.is_empty() or user_id.is_empty():
		SingletonObject.ErrorDisplay("Approve", "Missing session or user id.")
		return

	var adapter = _get_adapter()
	if not adapter:
		SingletonObject.ErrorDisplay("Approve", "Autocoder not connected.")
		return

	_approve_button.disabled = true
	_status_override = "Approving..."

	var ok = await adapter.approve(user_id, session_id)
	if not ok:
		_approve_button.disabled = false
		_status_override = ""
		return

	_approve_sent = true
	_update_status_labels()


func _on_advanced_toggled(enabled: bool) -> void:
	_advanced_section.visible = enabled

	if not enabled:
		return

	_refresh_advanced_lists()


func _on_patch_copy_pressed() -> void:
	if _store.patch_uri.is_empty():
		return
	DisplayServer.clipboard_set(_store.patch_uri)
	SingletonObject.create_toast_notification("Patch URI copied.", ToastNotification.Type.SUCCESS)


func _on_archive_copy_pressed() -> void:
	if _store.archive_uri.is_empty():
		return
	DisplayServer.clipboard_set(_store.archive_uri)
	SingletonObject.create_toast_notification("Archive URI copied.", ToastNotification.Type.SUCCESS)


func _refresh_advanced_lists() -> void:
	_clear_list(_raw_list)
	_clear_list(_llm_list)

	for item in _store.raw_events:
		var title = str(item.get("title", "Raw"))
		var data = item.get("data", {})
		_add_raw_row(title, data)

	for item in _store.llm_events:
		_add_llm_row(item)


func _build_review_counts_line() -> String:
	if not (_store.review_result is Dictionary):
		return ""

	var parts: Array[String] = []
	var total_issues = _store.review_result.get("total_issues", null)
	var total_fixes = _store.review_result.get("total_fixes_applied", null)
	var all_approved = _store.review_result.get("all_approved", null)

	if total_issues != null:
		parts.append("issues: %s" % str(total_issues))
	if total_fixes != null:
		parts.append("fixes: %s" % str(total_fixes))
	if all_approved != null:
		parts.append("all approved: %s" % ("yes" if bool(all_approved) else "no"))

	return " | ".join(parts)


func _clear_list(container: VBoxContainer) -> void:
	for child in container.get_children():
		child.queue_free()


func _update_list_headers() -> void:
	if _timeline_header and _timeline_list:
		_timeline_header.visible = _timeline_list.get_child_count() > 0
	if _issues_header and _issues_list:
		_issues_header.visible = _issues_list.get_child_count() > 0


## LLM Event Handlers for live streaming display

func _handle_llm_request(payload: Dictionary) -> void:
	"""Handle LLM request start - create a new card"""
	var event_id = str(payload.get("event_id", ""))
	if event_id.is_empty():
		return

	var model = str(payload.get("model", "unknown"))
	var message_count = int(payload.get("message_count", 0))
	var messages = payload.get("messages", [])
	var tools = payload.get("tools", [])
	var raw_seq = payload.get("raw_sequence_id", null)
	var proxy_seq = payload.get("proxy_sequence_id", null)

	# Debug: Log what we're creating
	print("=== LLM REQUEST ===")
	print("  event_id: %s" % event_id)
	print("  model: %s" % model)
	print("  message_count: %d" % message_count)
	print("  tools: %d" % (tools.size() if tools is Array else 0))
	print("  raw_sequence_id: %s" % raw_seq)
	print("  proxy_sequence_id: %s" % proxy_seq)

	# Create new LLM card and add to TIMELINE (not separate section)
	var card: AutocoderLLMCard = LLM_CARD_SCENE.instantiate()
	if _timeline_list:
		_timeline_list.add_child(card)
	card.setup_request(event_id, model, message_count, messages if messages is Array else [])

	# Track the card by multiple identifiers for response correlation
	_active_llm_cards[event_id] = card
	if raw_seq != null:
		_active_llm_cards["raw_%s" % str(raw_seq)] = card
		_active_llm_cards["seq_%s" % str(raw_seq)] = card  # Also track by seq for chunks
	if proxy_seq != null:
		_active_llm_cards["proxy_%s" % str(proxy_seq)] = card


func _handle_llm_chunk(payload: Dictionary) -> void:
	"""Handle streaming response chunk - append to existing card"""
	print("=== RESPONSE CHUNK ===")

	# Response chunks correlation - try all possible matching strategies
	var seq = payload.get("seq", null)
	var raw_seq = payload.get("raw_sequence_id", null)
	var proxy_seq = payload.get("proxy_sequence_id", null)
	var event_id = str(payload.get("event_id", ""))
	var content_delta = str(payload.get("content_delta", ""))

	print("  seq: %s, raw_seq: %s, proxy_seq: %s, event_id: %s" % [seq, raw_seq, proxy_seq, event_id])
	print("  content_delta: '%s'" % content_delta)

	# Try multiple ways to find the matching card
	var card = null
	var match_method = ""

	# Try by seq (response_chunk uses this!)
	if seq != null and _active_llm_cards.has("seq_%s" % str(seq)):
		card = _active_llm_cards["seq_%s" % str(seq)]
		match_method = "seq"
	# Try by raw_sequence_id
	elif raw_seq != null and _active_llm_cards.has("raw_%s" % str(raw_seq)):
		card = _active_llm_cards["raw_%s" % str(raw_seq)]
		match_method = "raw_seq"
	# Try by proxy_sequence_id
	elif proxy_seq != null and _active_llm_cards.has("proxy_%s" % str(proxy_seq)):
		card = _active_llm_cards["proxy_%s" % str(proxy_seq)]
		match_method = "proxy_seq"
	# Try by event_id
	elif not event_id.is_empty() and _active_llm_cards.has(event_id):
		card = _active_llm_cards[event_id]
		match_method = "event_id"
	# Try the last active card as fallback
	elif _active_llm_cards.size() > 0:
		var last_card = null
		for key in _active_llm_cards.keys():
			last_card = _active_llm_cards[key]
		card = last_card
		match_method = "fallback_last"

	if card == null:
		print("  ❌ No matching card found!")
		print("  Active cards: %s" % _active_llm_cards.keys())
		return

	print("  ✓ Matched card using: %s" % match_method)

	# Use content_delta from top (already extracted)
	# Check if there's delta structure for additional content
	var delta = payload.get("delta", {})
	if delta is Dictionary:
		var delta_type = str(delta.get("type", ""))
		print("  Delta type: %s" % delta_type)

		if delta_type == "text_delta":
			var delta_text = str(delta.get("text", ""))
			if not delta_text.is_empty():
				content_delta = delta_text
		elif delta_type == "input_json_delta":
			var partial_json = str(delta.get("partial_json", ""))
			if not partial_json.is_empty():
				content_delta = partial_json
		elif delta_type == "content_block_start":
			var content_block = delta.get("content_block", {})
			if content_block is Dictionary:
				var block_type = str(content_block.get("type", ""))
				if block_type == "tool_use":
					var tool_id = str(content_block.get("id", ""))
					var tool_name = str(content_block.get("name", ""))
					if not tool_name.is_empty():
						print("  🔧 Tool use started: %s" % tool_name)
						card.add_tool_call(tool_name, {"id": tool_id, "streaming": true})

	if not content_delta.is_empty():
		print("  📝 Appending text: '%s'" % content_delta)
		card.append_chunk(content_delta)
	else:
		print("  ⚠️ No content to append")


func _handle_llm_complete(payload: Dictionary) -> void:
	"""Handle LLM completion - mark card as done"""
	print("=== RESPONSE COMPLETE ===")
	print("  Full payload: %s" % JSON.stringify(payload))

	var raw_seq = payload.get("raw_sequence_id", null)
	var proxy_seq = payload.get("proxy_sequence_id", null)
	var event_id = str(payload.get("event_id", ""))

	# Try multiple ways to find the matching card
	var card = null

	# Try by raw_sequence_id
	if raw_seq != null and _active_llm_cards.has("raw_%s" % str(raw_seq)):
		card = _active_llm_cards["raw_%s" % str(raw_seq)]
	# Try by proxy_sequence_id
	elif proxy_seq != null and _active_llm_cards.has("proxy_%s" % str(proxy_seq)):
		card = _active_llm_cards["proxy_%s" % str(proxy_seq)]
	# Try by event_id
	elif not event_id.is_empty() and _active_llm_cards.has(event_id):
		card = _active_llm_cards[event_id]

	if card == null:
		print("  ❌ No matching card for complete!")
		print("  raw_seq: %s, proxy_seq: %s, event_id: %s" % [raw_seq, proxy_seq, event_id])
		return

	var finish_reason = str(payload.get("finish_reason", ""))
	var usage = payload.get("usage", {})

	# Check if there's response content in the complete event
	var response = payload.get("response", null)
	if response is Dictionary:
		var content = response.get("content", [])
		if content is Array:
			for block in content:
				if block is Dictionary:
					var block_type = str(block.get("type", ""))
					if block_type == "text":
						var text = str(block.get("text", ""))
						if not text.is_empty():
							print("  📝 Complete event has text content: %s" % text.substr(0, 100))
							card.append_chunk(text)
					elif block_type == "tool_use":
						var tool_name = str(block.get("name", ""))
						var tool_input = block.get("input", {})
						print("  🔧 Complete event has tool_use: %s" % tool_name)
						card.add_tool_call(tool_name, tool_input)

	print("  ✓ Marking card complete, reason: %s" % finish_reason)
	card.mark_complete(finish_reason, usage)

	# Remove ALL references to this card from active tracking
	var keys_to_remove = []
	for key in _active_llm_cards.keys():
		if _active_llm_cards[key] == card:
			keys_to_remove.append(key)

	for key in keys_to_remove:
		_active_llm_cards.erase(key)


func _handle_llm_error(payload: Dictionary) -> void:
	"""Handle LLM error - mark card as errored"""
	var request_id = str(payload.get("event_id", ""))
	if request_id.is_empty():
		request_id = str(payload.get("request_id", ""))

	var error_message = str(payload.get("error", payload.get("message", "Unknown error")))

	# If we have an active card, mark it as errored
	if not request_id.is_empty() and _active_llm_cards.has(request_id):
		var existing_card = _active_llm_cards[request_id]
		existing_card.mark_error(error_message)
		_active_llm_cards.erase(request_id)
		return

	# Otherwise create a new error card in timeline
	var error_card = LLM_CARD_SCENE.instantiate()
	if _timeline_list:
		_timeline_list.add_child(error_card)
	error_card.setup_request(request_id, "Error", 0, [])
	error_card.mark_error(error_message)


func _handle_llm_tool_call(payload: Dictionary) -> void:
	"""Handle tool call - add to the current active card"""
	var request_id = str(payload.get("event_id", ""))
	if request_id.is_empty():
		request_id = str(payload.get("request_id", ""))

	if request_id.is_empty() or not _active_llm_cards.has(request_id):
		return

	var card: AutocoderLLMCard = _active_llm_cards[request_id]
	var tool_name = str(payload.get("name", "unknown_tool"))
	var tool_input = payload.get("input", {})

	card.add_tool_call(tool_name, tool_input)


func _create_review_request_dialog() -> AcceptDialog:
	var dialog := AcceptDialog.new()
	dialog.title = "Request Another Review"
	dialog.dialog_text = ""
	dialog.min_size = Vector2i(600, 300)
	dialog.ok_button_text = "Request Review"

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	dialog.add_child(vbox)

	# Instructions
	var instructions := Label.new()
	instructions.text = "Enter optional custom instructions for the review agents:"
	vbox.add_child(instructions)

	vbox.add_child(HSeparator.new())

	# Custom prompt text edit
	var prompt_label := Label.new()
	prompt_label.text = "Custom Prompt (optional):"
	vbox.add_child(prompt_label)

	var prompt_edit := TextEdit.new()
	prompt_edit.unique_name_in_owner = true
	prompt_edit.name = "CustomPromptEdit"
	prompt_edit.placeholder_text = "e.g., Focus on security issues and performance bottlenecks"
	prompt_edit.custom_minimum_size = Vector2(0, 120)
	prompt_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	vbox.add_child(prompt_edit)

	# Info label
	var info := Label.new()
	info.text = "Leave blank to use default review behavior."
	info.add_theme_font_size_override("font_size", 11)
	vbox.add_child(info)

	SingletonObject.add_child(dialog)
	return dialog


func _get_adapter() -> AutocoderAdapter:
	if not SingletonObject.autocoder_manager:
		return null
	return SingletonObject.autocoder_manager.autocoder_adapter
