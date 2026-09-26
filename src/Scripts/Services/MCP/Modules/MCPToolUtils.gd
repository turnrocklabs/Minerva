class_name MCPToolUtils
extends RefCounted
## Shared utilities for MCP tool modules.
## Provides standardized response builders, argument validation,
## type coercion, and common lookups used across all domains.


#region Response Builders

## Build a success response with optional extra fields merged in.
static func success(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


## Build an error response.
static func error(msg: String) -> Dictionary:
	return {"error": msg, "success": false}

#endregion


#region Argument Validation

## Validate that required keys are present in args.
## Returns empty string if valid, or an error message naming the first missing key.
static func require_args(args: Dictionary, keys: Array[String]) -> String:
	for key in keys:
		if not args.has(key) or (args[key] is String and args[key].is_empty()):
			return "%s is required" % key
	return ""


## Validate required args and return error dict immediately if missing.
## Returns null if all args are present (caller should check for null).
static func check_required(args: Dictionary, keys: Array[String]) -> Variant:
	var msg := require_args(args, keys)
	if not msg.is_empty():
		return error(msg)
	return null

#endregion


#region Type Coercion

## Safely coerce a value to int. Handles JSON floats, strings, and nulls.
static func coerce_int(value, default: int = 0) -> int:
	if value == null:
		return default
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is String and value.is_valid_int():
		return value.to_int()
	return default


## Safely coerce a value to float. Handles JSON ints, strings, and nulls.
static func coerce_float(value, default: float = 0.0) -> float:
	if value == null:
		return default
	if value is float:
		return value
	if value is int:
		return float(value)
	if value is String and value.is_valid_float():
		return value.to_float()
	return default


## Safely coerce a value to Color. Accepts Color objects, HTML hex strings,
## and named colors. Returns default on failure instead of opaque black.
static func coerce_color(value, default: Color = Color.TRANSPARENT) -> Color:
	if value == null:
		return default
	if value is Color:
		return value
	if value is String:
		var s: String = value.strip_edges()
		if s.is_empty():
			return default
		# Try HTML hex format (with or without #)
		if Color.html_is_valid(s):
			return Color.html(s)
		# Try named color
		if Color.html_is_valid(s.to_lower()):
			return Color.html(s.to_lower())
	return default


## Safely coerce a value to bool. Handles JSON booleans, strings ("true"/"false"),
## and numeric values (0/1).
static func coerce_bool(value, default: bool = false) -> bool:
	if value == null:
		return default
	if value is bool:
		return value
	if value is String:
		return value.to_lower() == "true"
	if value is int or value is float:
		return value != 0
	return default

## Coerce a JSON string to a Dictionary. If value is already a Dictionary, return as-is.
## If it's a string that parses as JSON object, return the parsed dict. Otherwise return default.
static func coerce_object(value, default: Dictionary = {}) -> Dictionary:
	if value == null:
		return default
	if value is Dictionary:
		return value
	if value is String:
		var parsed = JSON.parse_string(value)
		if parsed is Dictionary:
			return parsed
	return default


## Coerce tool arguments to match declared schema types.
## LLMs (especially Sonnet) often send objects as JSON strings, integers as strings,
## and integers as floats. This function uses the tool's input_schema to fix these
## before forwarding to external MCP servers that expect correct types.
static func coerce_args_to_schema(arguments: Dictionary, schema: Dictionary) -> Dictionary:
	# Tool discovery stores the Anthropic wrapper; direct callers also pass
	# bare JSON Schema. Normalize once at this shared boundary.
	var input_schema: Dictionary = schema.get("input_schema", schema)
	var properties: Dictionary = input_schema.get("properties", {})
	if properties.is_empty():
		return arguments
	for key in arguments.keys():
		if not properties.has(key):
			continue
		var declared_type: String = str(properties[key].get("type", ""))
		var value = arguments[key]
		match declared_type:
			"object":
				if value is String:
					var parsed = JSON.parse_string(value)
					if parsed is Dictionary:
						arguments[key] = parsed
			"integer":
				# Leave invalid values for the tool's validator; never silently
				# turn a fractional dimension or malformed input into zero.
				if value is float and is_finite(value) and float(int(value)) == value:
					arguments[key] = int(value)
				elif value is String and value.is_valid_int():
					arguments[key] = value.to_int()
			"number":
				if value is String and value.is_valid_float():
					arguments[key] = value.to_float()
			"boolean":
				if value is String and value.to_lower() in ["true", "false"]:
					arguments[key] = coerce_bool(value)
				elif (value is int or value is float) and value in [0, 1]:
					arguments[key] = coerce_bool(value)
	return arguments

#endregion


#region Editor Finders

## Find an editor tab by name. Returns the Editor node or null.
static func find_editor_by_name(name_: String) -> Variant:
	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return null

	var clean_name := name_.strip_edges()

	var matches: Array = []
	for i in range(editor_pane.Tabs.get_tab_count()):
		var editor = editor_pane.Tabs.get_tab_control(i)
		if DocumentIdentity.handle(editor, "view") == clean_name:
			return editor
		if editor_pane.Tabs.get_tab_title(i) == clean_name:
			matches.append(editor)
	# A duplicate title must not silently select the first document.
	return matches[0] if matches.size() == 1 else null


## Find an editor of a specific type by name. Returns the Editor node or null.
## Pass Editor.Type.SPREADSHEET, Editor.Type.GRAPHICS, etc.
static func find_typed_editor(name_: String, editor_type: int) -> Variant:
	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return null

	var clean_name := name_.strip_edges()

	# Exact match with type filter
	for editor in editor_pane.get_open_editors():
		if editor.type == editor_type and editor.tab_title == clean_name:
			return editor

	# Case-insensitive fallback
	var lower_name := clean_name.to_lower()
	for editor in editor_pane.get_open_editors():
		if editor.type == editor_type and editor.tab_title.to_lower() == lower_name:
			return editor

	return null


## Find a typed editor and return its inner panel (e.g. .spreadsheet_editor).
## property_name is the Editor property that holds the domain-specific panel.
## Returns the inner panel or null.
static func find_editor_panel(name_: String, editor_type: int, property_name: String) -> Variant:
	var editor = find_typed_editor(name_, editor_type)
	if editor and editor.get(property_name):
		return editor.get(property_name)
	return null


## Convenience: find spreadsheet editor panel by name.
static func find_spreadsheet(name_: String) -> Variant:
	return find_typed_editor(name_, _get_editor_type("SPREADSHEET"))


## Convenience: find video editor panel by name.
static func find_video(name_: String) -> Variant:
	return find_editor_panel(name_, _get_editor_type("VIDEO_EDITOR"), "video_editor_panel")


## Convenience: find webview editor by name.
static func find_webview(name_: String) -> Variant:
	return find_typed_editor(name_, _get_editor_type("WEBVIEW"))


## Convenience: find kanban board panel by name (with partial match fallback).
static func find_kanban(name_: String) -> Variant:
	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return null

	var clean_name := name_.strip_edges()
	var kanban_type := _get_editor_type("KANBAN")

	# Exact match
	for editor in editor_pane.get_open_editors():
		if editor.type == kanban_type and editor.tab_title == clean_name:
			return editor.kanban_board

	# Case-insensitive
	var lower_name := clean_name.to_lower()
	for editor in editor_pane.get_open_editors():
		if editor.type == kanban_type and editor.tab_title.to_lower() == lower_name:
			return editor.kanban_board

	# Partial/contains match
	for editor in editor_pane.get_open_editors():
		if editor.type == kanban_type:
			if editor.tab_title.to_lower().contains(lower_name) or lower_name.contains(editor.tab_title.to_lower()):
				return editor.kanban_board

	return null


## Get Editor.Type enum value by name string, avoiding direct const dependency.
static func _get_editor_type(type_name: String) -> int:
	var editor_script = load("res://Scripts/UI/Controls/Editor.gd")
	return editor_script.Type.get(type_name, -1)

#endregion


#region Chat Finders

## Find a ServiceHistory (chat) by its HistoryId. Returns the history or null.
static func find_chat_by_id(chat_id: String) -> Variant:
	for history in SingletonObject.ChatList:
		if history.HistoryId == chat_id:
			return history
	return null


## Find a chat's tab index by HistoryId. Returns -1 if not found.
static func find_chat_tab_index(chat_id: String) -> int:
	for i in range(SingletonObject.ChatList.size()):
		if SingletonObject.ChatList[i].HistoryId == chat_id:
			return i
	return -1


## Submit `text` to a chat as a user turn through the SAME path the send button
## uses: switch the pane to that chat's tab, call execute_regular_chat, then
## restore the caller's tab. Every MCP entry point that starts a turn goes
## through here, so none of them can miss the per-chat outgoing queue that
## execute_regular_chat gates on.
##
## The tab restore is DEFERRED on purpose: execute_regular_chat reads
## current_tab during setup, so switching back in the same frame would hand the
## turn the caller's provider instead of the target chat's.
##
## Returns {"success": true, "queued": bool} — queued is true when the chat was
## already mid-request, so the message was enqueued rather than started now.
## `defer_when_question_pending` marks this a BACKGROUND message (a notify
## envelope, not something a human typed). Such a message never starts a turn
## while the chat is waiting for the answer to a question card: the agent
## behind the chat is blocked on that answer, and a turn taken now would make
## the human's answer queue behind it — neither could then reach the agent.
## It is queued as a deferred entry instead and drains once a turn ends with no
## question pending. The same holds when the chat is merely BUSY: the turn in
## flight may end in a question, so a background message queued now is deferred
## too, rather than being promoted ahead of the answer the agent is waiting on.
## `urgent` (background messages only): a queued entry is moved ahead of the
## routine background entries in front of it (ChatOutgoingQueue.promote_urgent),
## its pending bubble with it.
static func submit_user_message(history, text: String,
		generation_options: Dictionary = {},
		defer_when_question_pending: bool = false, urgent: bool = false) -> Dictionary:
	if history == null:
		return error("Chat not available")
	var chat_pane = SingletonObject.Chats
	if chat_pane == null:
		return error("Chat pane not available")
	var tab_idx: int = find_chat_tab_index(history.HistoryId)
	if tab_idx == -1:
		return error("Chat tab not found")
	# A background message is queued as DEFERRED whenever it is queued at all,
	# the in-flight turn included: that turn can itself end in a question, and
	# an ordinary entry would then be promoted by the drain ahead of the
	# human's answer — the deadlock this deferral exists to prevent.
	if defer_when_question_pending and (history.is_awaiting_question_answer()
			or history.is_request_active):
		var deferred = chat_pane.enqueue_background_message(history, text, generation_options)
		if urgent:
			_promote_urgent(chat_pane._outgoing_queue, deferred)
		return {"success": true, "queued": true, "entry_id": deferred.id}
	var was_busy: bool = history.is_request_active
	var original_tab: int = chat_pane.current_tab
	chat_pane.current_tab = tab_idx
	# Sent as promoted: an MCP submission IS the next user message of that chat,
	# so the executor's trailing-USER guard does not apply to it. That guard
	# stops a second DIRECT send from stacking onto an unanswered question; here
	# the receipt below already reports the message as delivered, so a guard bail
	# would lose it and say it ran.
	chat_pane.execute_regular_chat(text, generation_options, true)
	chat_pane.call_deferred("set_current_tab", original_tab)
	# The gate runs before execute_regular_chat's first await, so a busy chat
	# has already queued this message: its entry is the newest one, and its id
	# is what a receipt follows (the text cannot identify it — two identical
	# messages are two entries).
	var entry_id: int = 0
	if was_busy:
		entry_id = chat_pane._outgoing_queue.newest_id(history.HistoryId)
	return {"success": true, "queued": was_busy, "entry_id": entry_id}


## Move an urgent queued entry ahead of routine ones, and its pending bubble
## in front of the bubble of the entry it now precedes.
static func _promote_urgent(queue: ChatOutgoingQueue, entry: ChatOutgoingQueue.Entry) -> void:
	var passed: ChatOutgoingQueue.Entry = queue.promote_urgent(entry)
	if entry.bubble is Control:
		(entry.bubble as Control).tooltip_text = "Urgent notification: runs ahead of the routine notifications queued here, after this chat's current turn."
	if passed == null or not is_instance_valid(entry.bubble) or not is_instance_valid(passed.bubble):
		return
	var parent: Node = passed.bubble.get_parent()
	if parent != null and parent == entry.bubble.get_parent():
		parent.move_child(entry.bubble, passed.bubble.get_index())


## Pending entries of a chat's outgoing queue, oldest first. Read-only view for
## tool receipts that must report where a queued message sits.
static func pending_outgoing_texts(history) -> PackedStringArray:
	var chat_pane = SingletonObject.Chats
	if history == null or chat_pane == null:
		return PackedStringArray()
	return chat_pane._outgoing_queue.pending_texts(history.HistoryId)


## Where a queued entry sits, 1-based, or 0 once it has left the queue.
static func outgoing_queue_position(entry_id: int) -> int:
	var chat_pane = SingletonObject.Chats
	if chat_pane == null or entry_id <= 0:
		return 0
	return chat_pane._outgoing_queue.position_of(entry_id)


## Take a still-queued entry back out, bubble and all, as removing its bubble
## does. False when it is no longer queued.
static func withdraw_outgoing(entry_id: int) -> bool:
	var chat_pane = SingletonObject.Chats
	if chat_pane == null or entry_id <= 0:
		return false
	var entry = chat_pane._outgoing_queue.find(entry_id)
	if entry == null:
		return false
	chat_pane._on_pending_bubble_removal_requested(entry.bubble, entry)
	return true


## What became of an entry that has left the queue: a ChatOutgoingQueue.Outcome.
static func outgoing_queue_outcome(entry_id: int) -> int:
	var chat_pane = SingletonObject.Chats
	if chat_pane == null or entry_id <= 0:
		return ChatOutgoingQueue.Outcome.UNKNOWN
	return chat_pane._outgoing_queue.outcome_of(entry_id)

#endregion


#region Provider Helpers

## Get a provider name string for an API_MODEL_PROVIDERS enum value.
static func get_provider_name(enum_value: int) -> String:
	for key in SingletonObject.API_MODEL_PROVIDERS:
		if SingletonObject.API_MODEL_PROVIDERS[key] == enum_value:
			return key
	return "unknown"


## Get the MCPManager for the provider name string (e.g. "chatgpt", "claude").
## Returns a provider instance or null.
static func get_provider_for_name(provider_name: String) -> Variant:
	var lower := provider_name.strip_edges().to_lower()
	for key in SingletonObject.API_MODEL_PROVIDERS:
		if str(key).to_lower() == lower:
			var enum_val: int = SingletonObject.API_MODEL_PROVIDERS[key]
			if SingletonObject.API_MODEL_PROVIDER_SCRIPTS.has(enum_val):
				return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[enum_val].new()
	return null

#endregion
