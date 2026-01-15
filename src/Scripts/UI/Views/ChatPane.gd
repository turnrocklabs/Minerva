class_name ChatPane
extends TabContainer

const OpenAIImageProviderScript = preload("res://Scripts/Services/Providers/OpenAI/OpenAIImageProvider.gd")

var closed_chat_data: ChatHistory  # Store the data of the closed chat
var control: Control  # Store the tab control
var container: TabContainer  # Store the TabContainer

@onready var txt_main_user_input: TextEdit = %txtMainUserInput
@onready var _provider_option_button: ProviderOptionButton = %ProviderOptionButton
@onready var buffer_control_chats: Control = %BufferControlChats
@onready var audio_stop_1: IconsButton = %AudioStop1
@onready var _chat_button: Button = %btnChat
var _active_chat_requests: int = 0  # Ref count of active chat requests across all tabs

@onready var dynamic_ui_container: Container = %DynamicUIContainer

var _initializing_pane := false

## Debounce timer for token estimation to avoid expensive recalculation on every keystroke
var _token_estimation_timer: Timer

## Default max tool call rounds (fallback if per-chat setting is 0)
const DEFAULT_MAX_TOOL_CALL_ROUNDS: int = 10

## Agent mode context management constants
const AGENT_MAX_TOOL_RESULT_LENGTH: int = 8000  # Truncate tool results longer than this
const AGENT_CONTEXT_WARNING_THRESHOLD: int = 80000  # Warn when estimated tokens exceed this
const AGENT_CONTEXT_HARD_LIMIT: int = 100000  # Stop agent loop when exceeding this
const AGENT_SUMMARIZE_THRESHOLD: int = 60000  # Trigger summarization above this token count
const AGENT_KEEP_RECENT_MESSAGES: int = 6  # Keep this many recent messages when summarizing

## Base agent system prompt - tool-specific sections added dynamically
const AGENT_SYSTEM_PROMPT_BASE: String = """You are an AI assistant. You can only use tools that are explicitly provided to you in this conversation."""

const AGENT_SYSTEM_PROMPT_GENERAL: String = """
## General Principles
- Plan your approach before acting. Think about what information you need and the most efficient way to get it.
- Prefer targeted queries over broad data fetches. Getting specific data is better than getting everything.
- If a tool result is truncated, adapt your approach to use more targeted queries.
- Complete the task in as few tool calls as possible while being thorough.
"""

const AGENT_SYSTEM_PROMPT_COBROWSER: String = """
## Co-Browser Tool Guidelines (when browsing web pages)
- Start with `cobrowser_get_page_info` for quick page metadata.
- Use `cobrowser_query_all` with specific CSS selectors to understand page structure before reading content.
- AVOID `cobrowser_get_state` - it returns the entire DOM and is very expensive.
- AVOID `cobrowser_screenshot` unless specifically needed - it can be slow.
- Use `cobrowser_scroll` to find content below the fold or in infinite scroll containers.
- Look for patterns like `.infinite-scroll`, `[class*='feed']`, `[class*='post']` for dynamic content.
- When reading, use specific selectors rather than broad ones to get targeted content.
"""

const AGENT_SYSTEM_PROMPT_CODETOOLS: String = """
## File/Code Tool Guidelines (when working with files)
- Use `glob` to find files by pattern before reading them.
- Use `grep` to search for specific content rather than reading entire files.
- Read only the sections of files you need, not entire large files.
- When editing, make targeted changes rather than rewriting entire files.
"""

const AGENT_SYSTEM_PROMPT_ERROR: String = """
## Error Handling
- If a tool times out or fails, try a different approach rather than retrying the same thing.
- If results are truncated, use more specific queries to get the data you need.
"""

## Build the agent system prompt dynamically based on connected tools
func _build_agent_system_prompt() -> String:
	var mcp = SingletonObject.get_mcp_manager()
	if not mcp:
		return AGENT_SYSTEM_PROMPT_BASE

	var tools = mcp.get_available_tools()
	if tools.is_empty():
		return AGENT_SYSTEM_PROMPT_BASE + "\n\nNote: No tools are currently connected. You cannot use any tools until they are enabled."

	var prompt = AGENT_SYSTEM_PROMPT_BASE + AGENT_SYSTEM_PROMPT_GENERAL

	# Check which tool categories are available
	var has_cobrowser = false
	var has_codetools = false
	for tool in tools:
		var tool_name: String = tool.name if "name" in tool else ""
		if tool_name.begins_with("cobrowser"):
			has_cobrowser = true
		elif tool_name in ["glob", "grep", "read", "read_file", "write", "write_file", "edit"]:
			has_codetools = true

	if has_cobrowser:
		prompt += AGENT_SYSTEM_PROMPT_COBROWSER
	if has_codetools:
		prompt += AGENT_SYSTEM_PROMPT_CODETOOLS

	prompt += AGENT_SYSTEM_PROMPT_ERROR
	return prompt

# Script of the default provider to use when creating new chat tab
var default_provider_script: Script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[0]

var latest_msg: Control
var latest_usr_msg: MessageMarkdown

## Check if a path is within the allowed directories for a chat.
## Returns true if allowed (or no restrictions), false if blocked.
func is_path_allowed(path: String, allowed_dirs: Array[String]) -> bool:
	if allowed_dirs.is_empty():
		return true  # No restrictions
	for dir in allowed_dirs:
		if path.begins_with(dir):
			return true
	return false

## Truncate a tool result string if it exceeds the maximum length (agent mode only).
## Returns the truncated string with a marker indicating truncation.
## If max_length is 0 or negative, uses the default AGENT_MAX_TOOL_RESULT_LENGTH.
func truncate_tool_result(result_str: String, max_length: int = 0) -> String:
	var limit = max_length if max_length > 0 else AGENT_MAX_TOOL_RESULT_LENGTH
	if result_str.length() <= limit:
		return result_str
	var truncated = result_str.substr(0, limit)
	# Try to truncate at a natural boundary (newline or space)
	var last_newline = truncated.rfind("\n")
	var last_space = truncated.rfind(" ")
	var cut_point = max(last_newline, last_space)
	if cut_point > limit * 0.8:  # Only use natural boundary if it's not too far back
		truncated = truncated.substr(0, cut_point)
	# Add truncation notice with guidance
	var notice = """

...[TRUNCATED - Result was %d chars, showing first %d]

HINT: This result was too large and was truncated. To get the information you need:
- Use more specific CSS selectors with cobrowser_query_all or cobrowser_read
- For web pages, target specific elements rather than the whole page
- Avoid cobrowser_get_state (returns entire DOM) - use targeted queries instead
- Consider if you already have enough information to proceed""" % [result_str.length(), truncated.length()]
	return truncated + notice


## Estimate the current context size for a chat history in agent mode.
## Returns estimated token count.
func estimate_agent_context_size(history: ChatHistory) -> int:
	var total_tokens := 0
	for item in history.HistoryItemList:
		# Rough estimation: ~4 chars per token for English text
		total_tokens += ceili(item.Message.length() / 4.0)
		# Add extra for tool call metadata
		if item.IsToolCall:
			total_tokens += 50 * item.ToolCalls.size()
	return total_tokens


## Check if agent context is approaching limits. Returns status dict.
## {ok: bool, warning: bool, message: String, estimated_tokens: int, summarize_threshold: int}
## Uses per-chat settings if set, otherwise falls back to defaults.
func check_agent_context_limits(history: ChatHistory) -> Dictionary:
	var estimated = estimate_agent_context_size(history)

	# Use per-chat settings if set (> 0), otherwise fall back to defaults
	var hard_limit = history.AgentContextHardLimit if history.AgentContextHardLimit > 0 else AGENT_CONTEXT_HARD_LIMIT
	var warning_threshold = history.AgentContextWarningThreshold if history.AgentContextWarningThreshold > 0 else AGENT_CONTEXT_WARNING_THRESHOLD
	var summarize_threshold = history.AgentSummarizeThreshold if history.AgentSummarizeThreshold > 0 else AGENT_SUMMARIZE_THRESHOLD

	if estimated >= hard_limit:
		return {
			"ok": false,
			"warning": true,
			"message": "Context limit exceeded (%d tokens). Stopping agent." % estimated,
			"estimated_tokens": estimated,
			"summarize_threshold": summarize_threshold
		}
	elif estimated >= warning_threshold:
		return {
			"ok": true,
			"warning": true,
			"message": "Context getting large (%d tokens). Consider summarizing." % estimated,
			"estimated_tokens": estimated,
			"summarize_threshold": summarize_threshold
		}
	return {
		"ok": true,
		"warning": false,
		"message": "",
		"estimated_tokens": estimated,
		"summarize_threshold": summarize_threshold
	}


## Summarize older messages in the chat history to reduce context size.
## Keeps recent messages intact and replaces older ones with a summary.
func summarize_agent_history(history: ChatHistory) -> void:
	var item_count = history.HistoryItemList.size()
	if item_count <= AGENT_KEEP_RECENT_MESSAGES + 1:  # +1 for potential system prompt
		return  # Not enough messages to summarize

	# Find where to split: keep system prompt (if any) + last N messages
	var has_system_prompt = not history.HistoryItemList.is_empty() and \
		history.HistoryItemList[0].Role == ChatHistoryItem.ChatRole.SYSTEM

	var keep_from_end = AGENT_KEEP_RECENT_MESSAGES
	var summarize_start = 1 if has_system_prompt else 0
	var summarize_end = item_count - keep_from_end

	if summarize_end <= summarize_start:
		return  # Nothing to summarize

	# Build summary of old messages
	var summary_parts: PackedStringArray = []
	var tool_calls_count := 0
	var user_messages_count := 0
	var assistant_messages_count := 0

	for i in range(summarize_start, summarize_end):
		var item = history.HistoryItemList[i]
		match item.Role:
			ChatHistoryItem.ChatRole.USER:
				user_messages_count += 1
				# Include brief excerpt of user messages
				var excerpt = item.Message.substr(0, 200)
				if item.Message.length() > 200:
					excerpt += "..."
				summary_parts.append("User: %s" % excerpt)
			ChatHistoryItem.ChatRole.MODEL, ChatHistoryItem.ChatRole.ASSISTANT:
				assistant_messages_count += 1
				if item.IsToolCall:
					tool_calls_count += item.ToolCalls.size()
					for tc in item.ToolCalls:
						summary_parts.append("Called tool: %s" % tc.get("name", "unknown"))
			ChatHistoryItem.ChatRole.TOOL:
				# Just note that tool results were received
				summary_parts.append("Tool result received: %s" % item.ToolName)

	# Create summary message
	var summary_text = """### Conversation Summary ###
This summarizes %d earlier messages in this conversation.
- User messages: %d
- Assistant responses: %d
- Tool calls made: %d

Key points from earlier conversation:
%s
### End Summary ###""" % [
		summarize_end - summarize_start,
		user_messages_count,
		assistant_messages_count,
		tool_calls_count,
		"\n".join(summary_parts)
	]

	# Create summary item as a user message (so it's included in context)
	var summary_item = ChatHistoryItem.new()
	summary_item.Role = ChatHistoryItem.ChatRole.USER
	summary_item.Message = summary_text
	summary_item.provider = history.provider

	# Rebuild history: [system_prompt?] + [summary] + [recent messages]
	var new_history: Array[ChatHistoryItem] = []
	if has_system_prompt:
		new_history.append(history.HistoryItemList[0])
	new_history.append(summary_item)
	for i in range(summarize_end, item_count):
		new_history.append(history.HistoryItemList[i])

	# Replace history
	history.HistoryItemList = new_history

	print("[Agent] Summarized %d messages into 1. New history size: %d" % [
		summarize_end - summarize_start, new_history.size()
	])


## Check tool arguments for paths and validate against allowed directories.
## Returns error dict if blocked, null if allowed.
func check_tool_path_permissions(tool_name: String, tool_args: Dictionary, allowed_dirs: Array[String]) -> Variant:
	if allowed_dirs.is_empty():
		return null  # No restrictions

	# Tools that operate on paths
	var path_tools = ["read", "write", "edit", "glob", "grep", "bash"]
	if tool_name not in path_tools:
		return null  # Tool doesn't use paths

	# Check "path" argument
	if tool_args.has("path"):
		var path_arg = str(tool_args.get("path", ""))
		if not is_path_allowed(path_arg, allowed_dirs):
			return {"error": "Path not allowed: %s" % path_arg, "blocked_by": "AllowedDirectories"}

	# For bash, check if command might access restricted paths
	# (This is a basic check - bash commands are harder to restrict)
	if tool_name == "bash" and tool_args.has("command"):
		var _cmd = str(tool_args.get("command", ""))
		# Skip path checking for bash - it's too complex to parse reliably
		# The user should disable bash entirely if they want strict path control
		pass

	return null  # Allowed

# Extract common functionality for handling user history item creation
func create_user_history_item(text: String) -> ChatHistoryItem:
	return ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT,
							   ChatHistoryItem.ChatRole.USER,
							   text)

# Handle human provider message creation
func handle_human_provider_message(history: ChatHistory, user_history_item: ChatHistoryItem) -> void:
	# Get working memory/notes
	var working_memory: Array = await SingletonObject.notes_container.to_prompt(SingletonObject.ChatList[SingletonObject.Chats.current_tab].provider, )
	
	# Append working memory to the user history item
	if working_memory:
		user_history_item.InjectedNotes = working_memory
	
	# Handle and append user message
	history.HistoryItemList.append(user_history_item)
	var usr_msg_node: = history.VBox.add_history_item(user_history_item)
	usr_msg_node.regeneratable = true
	usr_msg_node.render()
	
	# Handle and add empty model message
	var mdl_history_item: = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT,
												ChatHistoryItem.ChatRole.MODEL,
												"")
	mdl_history_item.provider = history.provider
	# Also append working memory to the model's history item for context
	if working_memory:
		mdl_history_item.InjectedNotes = working_memory
	
	history.HistoryItemList.append(mdl_history_item)
	var mdl_msg_node: = history.VBox.add_history_item(mdl_history_item)
	mdl_msg_node.regeneratable = false
	mdl_msg_node.editable = true
	mdl_msg_node.render()
	mdl_msg_node.set_edit()

# Create and setup a model message node
func create_model_message_node(history: ChatHistory, dummy_item: ChatHistoryItem) -> Control:
	var model_msg_node = history.VBox.add_history_item(dummy_item)
	latest_msg = model_msg_node
	model_msg_node.loading = true
	return model_msg_node

# Generate content from provider
func generate_content_from_provider(history: ChatHistory, history_list: Array) -> Variant:
	var bot_response
	
	# Append the optional parameters for OpenAI models, send request and wait for the response
	if history.provider.PROVIDER == SingletonObject.API_PROVIDER.OPENAI and not history.provider is OpenAIImageProviderScript:
		var optional_params = {
			"temperature": history.Temperature,
			"top_p": history.TopP,
			"presence_penalty": history.PresencePenalty,
			"frequency_penalty": history.FrequencyPenalty,
		}
		bot_response = await history.provider.generate_content(history_list, optional_params)
	else:
		bot_response = await history.provider.generate_content(history_list)
	
	return bot_response

# Process bot response into chat history item
func process_bot_response(bot_response, _history_provider: BaseProvider) -> ChatHistoryItem:
	var chi = ChatHistoryItem.new()

	if bot_response != null:
		chi.Id = bot_response.id
		chi.Role = ChatHistoryItem.ChatRole.MODEL
		chi.provider = bot_response.provider
		chi.Message = bot_response.text
		chi.Error = bot_response.error
		chi.Complete = bot_response.complete
		chi.OutputTokens = bot_response.completion_tokens
		if bot_response.image:
			chi.Images = ([bot_response.image] as Array[Image])

	return chi

# Update UI after receiving bot response
func update_ui_after_response(user_history_item: ChatHistoryItem, user_msg_node: Control,
							 model_msg_node: Control, chi: ChatHistoryItem,
							 bot_response, history: ChatHistory) -> void:
	if bot_response != null:
		# Update user message node with input tokens (prompt tokens for this turn)
		user_history_item.InputTokens = bot_response.prompt_tokens
		user_msg_node.render()

		# Change the history item and the message node will update itself
		model_msg_node.history_item = chi
		history.HistoryItemList.append(chi)

		## Inform the user history item that the response has arrived
		user_history_item.response_arrived.emit(chi)

		await get_tree().process_frame
		history.VBox.ensure_node_is_visible(model_msg_node)
		model_msg_node.loading = false
		model_msg_node.first_time_message = true
	else:
		model_msg_node.queue_free()

	for i in SingletonObject.notes_container.get_tab_count():
		SingletonObject.notes_container.disable_notes(i)

	for i in SingletonObject.drawer_notes_container.get_tab_count():
		SingletonObject.drawer_notes_container.disable_notes(i)

	SingletonObject.detached_note_proxies.map(func(proxy: Note.Proxy): (await proxy.create_note(true)).enabled = false)
	SingletonObject.detached_note_proxies.clear()


## Same as update_ui_after_response but WITHOUT emitting response_arrived signal.
## Used for agent mode tool chains where we only want the signal at the end.
func update_ui_after_response_no_signal(user_history_item: ChatHistoryItem, user_msg_node: Control,
							 model_msg_node: Control, chi: ChatHistoryItem,
							 bot_response, history: ChatHistory) -> void:
	if bot_response != null:
		# Update user message node with input tokens (prompt tokens for this turn)
		user_history_item.InputTokens = bot_response.prompt_tokens
		user_msg_node.render()

		# Change the history item and the message node will update itself
		model_msg_node.history_item = chi
		history.HistoryItemList.append(chi)

		# NOTE: We intentionally do NOT emit response_arrived here
		# It will be emitted when the tool chain completes

		await get_tree().process_frame
		history.VBox.ensure_node_is_visible(model_msg_node)
		model_msg_node.loading = false
		model_msg_node.first_time_message = true
	else:
		model_msg_node.queue_free()

	# Don't disable notes during tool chain - they stay disabled until chain completes


## add new chat 
func _on_new_chat():
	var last_chat_number: int = -1

	# reverse loop and find last largest number after the Chat string literal
	for i in range(get_tab_count()-1, -1, -1):
		var tab_title: = get_tab_title(i)
		
		if tab_title == "Chat":
			last_chat_number = max(last_chat_number, 0)
		
		elif tab_title.begins_with("Chat"):
			var suffix = tab_title.right(-"Chat".length()).strip_edges()
			
			if suffix.is_valid_int():
				last_chat_number = max(last_chat_number, int(suffix))

	var tab_name: = "Chat" if last_chat_number == -1 else "Chat %s" % (last_chat_number+1)

	var provider_obj: = _provider_option_button.get_selected_provider()

	if not provider_obj:
		provider_obj = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[0].new()

	# use the provider currently set on this object
	var history: ChatHistory = ChatHistory.new(provider_obj)
	history.HistoryName = tab_name
	history.HistoryItemList = []
	# Set system prompt enabled based on whether provider requires it
	history.SystemPromptEnabled = provider_obj.requires_default_system_prompt
	SingletonObject.ChatList.append(history)
	render_history(history)

	current_tab = get_tab_count()-1

	# Inject default system prompt if provider requires it
	if provider_obj.requires_default_system_prompt:
		add_new_system_prompt_item(provider_obj.default_system_prompt)

	if get_tab_count() > 0:
		buffer_control_chats.hide()


## Opens a chat tab if one isn't open yet
func ensure_chat_open() -> void:
	if SingletonObject.ChatList.is_empty():
		_on_new_chat()

## Generates the full turn prompt using the history of the active chat and the selected provider.
## `append_item` will be present in the prompt, but WON'T be added to chat history inside this function.[br]
## If [param refresh_detached] is `true`, [method NotesContainer.to_prompt] will regenerate the editor notes.[br]
## If there's no active history [parameter provider_fallback] can be used to determine which provider to use.[br]
## Check `History.to_prompt` for explanation on `predicate`.
func create_prompt(append_item: ChatHistoryItem = null, refresh_detached: = true, provider_fallback: BaseProvider = null, predicate: Callable = Callable()) -> Array[Variant]:

	# if we don't have any chats history_list will be empty
	var history_list: Array[Variant] = []
	var provider: BaseProvider = provider_fallback
	var history: ChatHistory = null

	if not SingletonObject.ChatList.is_empty():
		history = SingletonObject.ChatList[current_tab]
		if not provider:
			provider = history.provider

		# Handle agentic system prompt: use it instead of regular system prompt when agent mode is on
		var effective_system_prompt: String = ""
		if history.AgentModeEnabled:
			# In agent mode: use custom agentic prompt if enabled, or fall back to dynamically built agent prompt
			if history.AgenticSystemPromptEnabled:
				if not history.AgenticSystemPrompt.is_empty():
					effective_system_prompt = history.AgenticSystemPrompt
				else:
					effective_system_prompt = _build_agent_system_prompt()
			# Append any existing regular system prompt to give additional context (if enabled)
			if history.SystemPromptEnabled and history.HasUsedSystemPrompt and not history.HistoryItemList.is_empty():
				if history.HistoryItemList[0].Role == ChatHistoryItem.ChatRole.SYSTEM:
					if effective_system_prompt.is_empty():
						effective_system_prompt = history.HistoryItemList[0].Message
					else:
						effective_system_prompt += "\n\n## Additional Instructions\n" + history.HistoryItemList[0].Message
		elif history.SystemPromptEnabled and history.HasUsedSystemPrompt and not history.HistoryItemList.is_empty():
			# Not in agent mode: use regular system prompt if it's a system prompt and enabled
			if history.HistoryItemList[0].Role == ChatHistoryItem.ChatRole.SYSTEM:
				effective_system_prompt = history.HistoryItemList[0].Message

		# Set system_prompt property on provider (used by Anthropic, Google)
		if "system_prompt" in provider and provider.supports_system_prompt:
			provider.system_prompt = effective_system_prompt

		# Build history list, handling system prompt based on provider support
		history_list = _build_history_list_with_system_prompt(history, provider, effective_system_prompt, predicate, history.AgentModeEnabled)

	if not provider:
		return []

	# any notes container `to_prompt` will go over both standard and drawer notes
	var working_memory: Array = await SingletonObject.notes_container.to_prompt(provider, refresh_detached)

	# If we don't have a new item but we have active notes, we still need new item to add the notes in there
	if not append_item and working_memory:
		append_item = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.USER)

	# append the working memory
	if append_item:
		append_item.InjectedNotes = working_memory
		# also append the new item since it's not in the history yet
		var item = provider.Format(append_item)
		if item: history_list.append(item)

	return history_list


## Build request metadata dictionary for debugging display in user message expand block
func _build_request_metadata(history: ChatHistory, history_list: Array[Variant]) -> Dictionary:
	var metadata: Dictionary = {}

	# Model info
	metadata["model"] = history.provider.model_name if history.provider else "Unknown"
	metadata["message_count"] = history_list.size()

	# System prompt - get from provider if available
	if "system_prompt" in history.provider and not history.provider.system_prompt.is_empty():
		metadata["system_prompt"] = history.provider.system_prompt

	# Agent mode and tools
	metadata["agent_mode"] = history.AgentModeEnabled
	if history.AgentModeEnabled and "available_tools" in history.provider:
		metadata["tools"] = history.provider.available_tools
		metadata["tool_count"] = history.provider.available_tools.size()
	else:
		metadata["tools"] = []
		metadata["tool_count"] = 0

	# Generation parameters (if available)
	if history.Temperature > 0:
		metadata["temperature"] = history.Temperature

	return metadata


## Build history list with proper handling of system prompt based on provider capabilities.
## If provider doesn't support system prompts, prepends system prompt to first user message.
func _build_history_list_with_system_prompt(history: ChatHistory, provider: BaseProvider, system_prompt: String, predicate: Callable, agent_mode: bool = false) -> Array[Variant]:
	var history_list: Array[Variant] = []
	var system_prompt_prepended := false

	for chat: ChatHistoryItem in history.HistoryItemList:
		# Apply predicate if provided
		if predicate.is_valid():
			var results = predicate.call(chat)
			var should_add: bool = results[0]
			var should_continue: bool = results[1]

			if not should_add:
				if not should_continue:
					break
				continue

			if not should_continue:
				# Add this item and then stop
				var break_item: Variant = _format_with_system_prompt_handling(chat, provider, system_prompt, system_prompt_prepended, agent_mode)
				if break_item:
					if chat.Role == ChatHistoryItem.ChatRole.USER and not system_prompt_prepended:
						system_prompt_prepended = true
					history_list.append(break_item)
				break

		var item: Variant = _format_with_system_prompt_handling(chat, provider, system_prompt, system_prompt_prepended, agent_mode)
		if item:
			if chat.Role == ChatHistoryItem.ChatRole.USER and not system_prompt_prepended and not provider.supports_system_prompt:
				system_prompt_prepended = true
			history_list.append(item)

	return history_list


## Format a chat item, handling system prompt injection for providers that don't support system prompts.
func _format_with_system_prompt_handling(chat: ChatHistoryItem, provider: BaseProvider, system_prompt: String, already_prepended: bool, agent_mode: bool = false) -> Variant:
	# Skip system prompt messages when agent mode is enabled OR provider doesn't support system prompts
	# (in agent mode, we set provider.system_prompt separately)
	if chat.Role == ChatHistoryItem.ChatRole.SYSTEM:
		if agent_mode or not provider.supports_system_prompt:
			return null  # Don't include system message in history, we handle it separately

	# If provider doesn't support system prompts and this is the first user message, prepend system prompt
	if not provider.supports_system_prompt and chat.Role == ChatHistoryItem.ChatRole.USER and not already_prepended and not system_prompt.is_empty():
		# Create a modified chat item with prepended system prompt
		var modified_chat := ChatHistoryItem.new()
		modified_chat.Role = chat.Role
		modified_chat.Message = "### System Instructions ###\n%s\n### End System Instructions ###\n\n%s" % [system_prompt, chat.Message]
		modified_chat.InjectedNotes = chat.InjectedNotes
		modified_chat.Images = chat.Images
		return provider.Format(modified_chat)

	return provider.Format(chat)


func _on_btn_inspect_pressed():
	var new_history_item: ChatHistoryItem = ChatHistoryItem.new()
	new_history_item.Message = %txtMainUserInput.text
	new_history_item.Role = ChatHistoryItem.ChatRole.USER

	## generate the dictionary we would send to the model.
	var history_list: Array[Variant] = await create_prompt(new_history_item)

	# we wont add the message to the history

	ensure_chat_open()

	var history: ChatHistory = SingletonObject.ChatList[current_tab]

	# Build full request body like the provider would
	var request_body: Dictionary = {
		"model": history.provider.api_model_id if "api_model_id" in history.provider else "unknown",
		"messages": history_list,
		"max_tokens": history.provider.max_tokens if "max_tokens" in history.provider else 4096,
	}

	# Add system prompt if available
	if "system_prompt" in history.provider and history.provider.system_prompt:
		request_body["system"] = history.provider.system_prompt

	# Add tools if agent mode is enabled for this chat
	print("[Inspector] AgentModeEnabled=%s, has_set_tools=%s" % [history.AgentModeEnabled, history.provider.has_method("set_tools")])
	if history.AgentModeEnabled and history.provider.has_method("set_tools"):
		var mcp = SingletonObject.get_mcp_manager()
		var mcp_tools = mcp.get_tools_for_anthropic()
		print("[Inspector] Got %d tools from MCP" % mcp_tools.size())
		if not mcp_tools.is_empty():
			request_body["tools"] = mcp_tools

	var stringified_history:String = JSON.stringify(request_body, "\t")
	%cdePrompt.text = stringified_history

	## show the inspector popup
	var target_size = %tcChats.size
	%InspectorPopup.exclusive = true
	%InspectorPopup.borderless = false
	%InspectorPopup.size = target_size
	%InspectorPopup.popup_centered()


## Takes a chat history item and regenerates the prompt for it.
## Regenerates response will be placed in next
func regenerate_response(chi: ChatHistoryItem):
	
	if chi.Role != ChatHistoryItem.ChatRole.USER:
		push_warning("Tried to regenerate response for history item %s who's Role is not user" % chi)
		return

	var history: ChatHistory
	
	for h in SingletonObject.ChatList:
		if h.HistoryItemList.has(chi):
			history = h
			break

	if not history:
		push_warning("Trying to regenerate response for history item %s not present in any history item list" % chi)
		return
	
	var index = history.HistoryItemList.find(chi)

	var existing_response: ChatHistoryItem

	for item in history.HistoryItemList.slice(index):
		if item.Role == ChatHistoryItem.ChatRole.MODEL:
			existing_response = item
			break

	if not existing_response:
		existing_response = ChatHistoryItem.new()
		existing_response.Role = ChatHistoryItem.ChatRole.MODEL
		existing_response.provider = SingletonObject.ChatList[current_tab].provider
		history.HistoryItemList.append(existing_response)
		history.VBox.add_history_item(existing_response)

	# We format items until we get to the user response
	var predicate = func(item: ChatHistoryItem) -> Array:
		return [
			history.HistoryItemList.find(item) < index,
			history.HistoryItemList.find(item) < index,
		]

	var history_list = await create_prompt(chi, false, null, predicate)

	existing_response.rendered_node.loading = true

	var bot_response = await history.provider.generate_content(history_list)

	# if there was an error with the request
	if not bot_response: return
	
	if bot_response.id: existing_response.Id = bot_response.id
	existing_response.Role = ChatHistoryItem.ChatRole.MODEL
	existing_response.Message = bot_response.text
	existing_response.Error = bot_response.error
	existing_response.provider = history.provider
	existing_response.Complete = bot_response.complete
	existing_response.OutputTokens = bot_response.completion_tokens
	if bot_response.image:
		existing_response.Images = ([bot_response.image] as Array[Image])

	existing_response.rendered_node.render()

	existing_response.rendered_node.loading = false

	# Emit response_arrived signal to trigger notification sound
	chi.response_arrived.emit(existing_response)
	
	for i in SingletonObject.notes_container.get_tab_count():
		SingletonObject.notes_container.disable_notes(i)

	for i in SingletonObject.drawer_notes_container.get_tab_count():
		SingletonObject.drawer_notes_container.disable_notes(i)
	
	SingletonObject.detached_note_proxies.map(func(proxy: Note.Proxy): (await proxy.create_note(true)).enabled = false)
	SingletonObject.detached_note_proxies.clear()


func _on_chat_pressed():
	_on_send_message_button_item_selected(0)


func _on_send_message_button_item_selected(index: int) -> void:

	# Ensure we have open chat so we can get its history and disable the notes
	ensure_chat_open()
	%SendMessageButton.selected = -1

	# Clear any leftover cancelled flag from previous requests
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	SingletonObject.clear_cancelled(history.HistoryId)

	#replacing All underscores to avoid but that transform all text to itelic when we using underscors (_text_text)
	var filteredInput: String = %txtMainUserInput.text#.replace("_",r"\_")
	%txtMainUserInput.text = ""
	audio_stop_1.disabled = false
	_active_chat_requests += 1
	match index:
		0:
			execute_regular_chat(filteredInput)
		1:
			execute_parallel_chat(filteredInput)
		2:
			execute_sequential_chat(filteredInput)

func execute_hcp_chat():
	ensure_chat_open()

	var history: ChatHistory = SingletonObject.ChatList[current_tab]

	if not history.provider is CoreProvider:
		push_error("'execute_hcp_chat' called while current provider is not CoreProvider")
		return

	var provider: CoreProvider = history.provider

	var input_data: = Core.dynamic_ui_generator.get_user_input(dynamic_ui_container)

	for field_name in provider.action.input_parameters.keys():
		var f_params: Dictionary = provider.action.input_parameters[field_name]
		if not f_params.get("required", false): continue
		
		if input_data[field_name] is String:
			if input_data[field_name].is_empty():
				return

	var user_history_item: = ChatHistoryItem.new()
	user_history_item.HcpData = input_data
	user_history_item.HcpStructure = provider.action.input_parameters
	user_history_item.Role = ChatHistoryItem.ChatRole.USER
	user_history_item.Type = ChatHistoryItem.PartType.TEXT

	Core.dynamic_ui_generator.clear_output(dynamic_ui_container)

	var user_msg_node: = history.VBox.add_history_item(user_history_item)
	
	history.HistoryItemList.append(user_history_item)
	
	var history_list: = await create_prompt(user_history_item)

	# rerender the message since we changed the history item
	user_msg_node.first_time_message = true
	history.VBox.ensure_node_is_visible(user_msg_node)
	user_msg_node.render()

	var dummy_item = ChatHistoryItem.new()
	dummy_item.Role = ChatHistoryItem.ChatRole.MODEL
	dummy_item.provider = history.provider
	var model_msg_node = history.VBox.add_history_item(dummy_item)
	
	model_msg_node.loading = true 

	var hcp_provider: CoreProvider = history.provider

	var bot_response = await hcp_provider.generate_content(history_list)


	var chi = ChatHistoryItem.new()
	if bot_response != null:
		chi.Id = bot_response.id
		chi.Role = ChatHistoryItem.ChatRole.MODEL
		chi.HcpStructure = provider.action.output_parameters
		chi.HcpData = bot_response.hcp_data
		chi.Error = bot_response.error
		chi.provider = history.provider
		chi.Complete = bot_response.complete
		chi.OutputTokens = bot_response.completion_tokens
		if bot_response.image:
			chi.Images = ([bot_response.image] as Array[Image])

		# Update user message node with input tokens (prompt tokens for this turn)
		user_history_item.InputTokens = bot_response.prompt_tokens
		user_msg_node.render()

		# Change the history item and the message node will update itself
		model_msg_node.history_item = chi

		## Inform the user history item that the response has arrived
		user_history_item.response_arrived.emit(chi)
		
		await get_tree().process_frame
		history.VBox.ensure_node_is_visible(model_msg_node)
		model_msg_node.loading = false
		model_msg_node.first_time_message = true
		update_ui_after_response(user_history_item, user_msg_node, model_msg_node, chi, bot_response, history)
	else:
		model_msg_node.queue_free()

func execute_regular_chat(text: String) -> void:
	# Check if it's a CoreProvider that requires HCP-style execution
	if SingletonObject.ChatList[current_tab].provider is CoreProvider:
		var core_provider := SingletonObject.ChatList[current_tab].provider as CoreProvider
		# Only use HCP chat for non-OpenAI services (ETSU, etc.)
		if not core_provider._is_openai_compatible_service():
			execute_hcp_chat()
			return

	if text.is_empty(): return

	ensure_chat_open()

	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	var last_msg = history.HistoryItemList.back() if not history.HistoryItemList.is_empty() else null

	var user_history_item = create_user_history_item(text)
	user_history_item.provider = history.provider
	# if we're using the human provider, handle it here
	if user_history_item.provider is HumanProvider:
		handle_human_provider_message(history, user_history_item)
		for i in SingletonObject.notes_container.get_tab_count():
			SingletonObject.notes_container.disable_notes(i)

		for i in SingletonObject.drawer_notes_container.get_tab_count():
			SingletonObject.drawer_notes_container.disable_notes(i)

		SingletonObject.detached_note_proxies.map(func(proxy: Note.Proxy): (await proxy.create_note(true)).enabled = false)
		SingletonObject.detached_note_proxies.clear()

		return # if user is using Human provider we finish here

	# Check is the last message is a user message and not do anything if true
	if last_msg and last_msg.Role == ChatHistoryItem.ChatRole.USER: return

	# Setup agent mode tools if enabled for this chat
	print("[Chat] Checking agent mode: AgentModeEnabled=%s, has_set_tools=%s, history_id=%s" % [history.AgentModeEnabled, history.provider.has_method("set_tools"), history.HistoryId])
	if history.AgentModeEnabled and history.provider.has_method("set_tools"):
		var mcp = SingletonObject.get_mcp_manager()
		var mcp_tools = mcp.get_tools_for_anthropic()
		# Filter out disabled tools for this chat
		var filtered_tools = mcp_tools.filter(func(tool):
			return tool.get("name", "") not in history.DisabledTools
		)
		print("[Agent] Setting up tools: %d available, %d after filtering" % [mcp_tools.size(), filtered_tools.size()])
		for t in filtered_tools:
			print("[Agent]   - %s" % t.get("name", "?"))
		history.provider.set_tools(filtered_tools)
		print("[Agent] Provider tools_enabled: %s" % history.provider.tools_enabled)

	# make a chat request
	var history_list: = await create_prompt(user_history_item)
	# first pass `user_history_item` to `create_prompt` so it gets all the notes, and now add it to history
	history.HistoryItemList.append(user_history_item)
	user_history_item.EstimatedTokenCost = int(history.provider.estimate_tokens_from_prompt(history_list))

	# Capture request metadata for debugging expandable block
	user_history_item.RequestMetadata = _build_request_metadata(history, history_list)

	# rerender the message since we changed the history item
	var user_msg_node: = history.VBox.add_history_item(user_history_item)
	user_msg_node.first_time_message = true
	history.VBox.ensure_node_is_visible(user_msg_node)
	user_msg_node.render()
	latest_usr_msg = user_msg_node
	# Add empty history item, to show the loading state
	var dummy_item = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT,
										ChatHistoryItem.ChatRole.MODEL,
										"")
	dummy_item.provider = history.provider

	var model_msg_node = create_model_message_node(history, dummy_item)
	var bot_response = await generate_content_from_provider(history, history_list)

	# Create history item from bot response
	var chi = process_bot_response(bot_response, history.provider)

	# Handle tool calls if agent mode is enabled for this chat and response has tool calls
	if history.AgentModeEnabled and bot_response and bot_response.has_tool_calls():
		# Store tool calls in the chat history item
		chi.IsToolCall = true
		chi.ToolCalls = bot_response.tool_calls

		# Update UI with the assistant's response (but DON'T emit response_arrived yet)
		# We'll emit it when the tool chain completes
		update_ui_after_response_no_signal(user_history_item, user_msg_node, model_msg_node, chi, bot_response, history)

		# Handle tool execution and continue conversation
		# Pass the initial model CHI as accumulator and user_history_item for final signal
		await handle_tool_calls(history, bot_response.tool_calls, 0, chi, user_history_item)
	else:
		update_ui_after_response(user_history_item, user_msg_node, model_msg_node, chi, bot_response, history)

	_active_chat_requests -= 1
	if _active_chat_requests <= 0:
		_active_chat_requests = 0  # Ensure non-negative
		audio_stop_1.disabled = true


## Get the last MODEL/ASSISTANT history item (the one that made the tool calls)
func _get_last_model_history_item(history: ChatHistory) -> ChatHistoryItem:
	for i in range(history.HistoryItemList.size() - 1, -1, -1):
		var item = history.HistoryItemList[i]
		if item.Role == ChatHistoryItem.ChatRole.MODEL or item.Role == ChatHistoryItem.ChatRole.ASSISTANT:
			return item
	return null


## Add tool_result blocks for tools that were not executed (due to cancellation, limits, etc.)
## This ensures the conversation can continue without API errors about missing tool_results.
func _add_unexecuted_tool_results(history: ChatHistory, tool_calls: Array, reason: String) -> void:
	var model_chi = _get_last_model_history_item(history)
	var error_result = JSON.stringify({"error": "Tool not executed: %s" % reason})

	for tool_call in tool_calls:
		var tool_id: String = tool_call.get("id", "")
		var tool_name: String = tool_call.get("name", "")
		var tool_args: Dictionary = tool_call.get("arguments", {})

		# Add to ToolExecutions for UI display
		if model_chi:
			var execution_entry = {
				"call_id": tool_id,
				"tool_name": tool_name,
				"arguments": tool_args,
				"status": "error",
				"result": error_result
			}
			model_chi.ToolExecutions.append(execution_entry)
			if model_chi.rendered_node:
				model_chi.rendered_node.update_tool_execution(tool_id, error_result, true)

		# Create hidden tool result history item for API continuity
		var tool_result_item = ChatHistoryItem.new()
		tool_result_item.Role = ChatHistoryItem.ChatRole.TOOL
		tool_result_item.ToolCallId = tool_id
		tool_result_item.ToolName = tool_name
		tool_result_item.Message = error_result
		tool_result_item.provider = history.provider
		tool_result_item.Visible = false  # Hidden - shown in parent message

		history.HistoryItemList.append(tool_result_item)
		print("[Agent] Added unexecuted tool_result for: %s (reason: %s)" % [tool_name, reason])


## Clean up UI state after agent mode finishes (success or error).
## Re-enables notes and decrements active request counter.
func _finish_agent_mode() -> void:
	# Disable notes in containers
	for i in SingletonObject.notes_container.get_tab_count():
		SingletonObject.notes_container.disable_notes(i)
	for i in SingletonObject.drawer_notes_container.get_tab_count():
		SingletonObject.drawer_notes_container.disable_notes(i)

	# Clear detached note proxies (editor "Send to LLM" toggles)
	SingletonObject.detached_note_proxies.map(func(proxy: Note.Proxy): (await proxy.create_note(true)).enabled = false)
	SingletonObject.detached_note_proxies.clear()

	# Decrement active requests and update stop button
	_active_chat_requests -= 1
	if _active_chat_requests <= 0:
		_active_chat_requests = 0
		audio_stop_1.disabled = true


## Handle tool calls from an LLM response in agentic mode.
## Executes tools, adds results to history, and continues the conversation.
## All responses are accumulated into a single message box (accumulator_chi).
## @param history: The chat history
## @param tool_calls: Array of tool calls to execute
## @param current_round: Current round number (for recursion)
## @param accumulator_chi: The first MODEL ChatHistoryItem that accumulates all display content
## @param user_history_item: The user's message, for emitting response_arrived at the end
func handle_tool_calls(history: ChatHistory, tool_calls: Array, current_round: int = 0,
					   accumulator_chi: ChatHistoryItem = null,
					   user_history_item: ChatHistoryItem = null) -> void:
	var max_rounds = history.MaxToolCallRounds if history.MaxToolCallRounds > 0 else DEFAULT_MAX_TOOL_CALL_ROUNDS

	# Helper to finish with signal emission
	var finish_with_signal = func():
		_finish_agent_mode()
		# Emit response_arrived to trigger completion sound
		if user_history_item and accumulator_chi:
			user_history_item.response_arrived.emit(accumulator_chi)

	if current_round >= max_rounds:
		push_warning("Agent mode: Max tool call rounds (%d) reached, stopping." % max_rounds)
		# Add tool_result blocks for unexecuted tools so conversation can continue
		_add_unexecuted_tool_results(history, tool_calls, "Max tool call rounds (%d) reached" % max_rounds)
		finish_with_signal.call()
		return

	# Check for cancellation at start
	if SingletonObject.is_cancelled(history.HistoryId):
		SingletonObject.clear_cancelled(history.HistoryId)
		# Add tool_result blocks for unexecuted tools so conversation can continue
		_add_unexecuted_tool_results(history, tool_calls, "Cancelled by user")
		finish_with_signal.call()
		return

	var mcp_manager = SingletonObject.get_mcp_manager()

	print("[Agent] Round %d: Processing %d tool calls" % [current_round, tool_calls.size()])

	# Use accumulator if provided, otherwise get the last MODEL item
	var model_chi: ChatHistoryItem = accumulator_chi if accumulator_chi else _get_last_model_history_item(history)

	# Execute each tool call and collect results
	for i in range(tool_calls.size()):
		var tool_call = tool_calls[i]

		# Check for cancellation before each tool
		if SingletonObject.is_cancelled(history.HistoryId):
			SingletonObject.clear_cancelled(history.HistoryId)
			# Add tool_results for remaining unexecuted tools (current + rest)
			var remaining_tools = tool_calls.slice(i)
			_add_unexecuted_tool_results(history, remaining_tools, "Cancelled by user")
			finish_with_signal.call()
			return

		var tool_id: String = tool_call.get("id", "")
		var tool_name: String = tool_call.get("name", "")
		var tool_args: Dictionary = tool_call.get("arguments", {})

		print("[Agent] Executing tool: %s (id=%s)" % [tool_name, tool_id])

		# Add execution entry to model_chi BEFORE executing (status: "calling")
		var execution_entry = {
			"call_id": tool_id,
			"tool_name": tool_name,
			"arguments": tool_args,
			"status": "calling",
			"result": ""
		}
		model_chi.ToolExecutions.append(execution_entry)

		# Update the rendered node to show this tool call
		if model_chi.rendered_node:
			model_chi.rendered_node.update_tool_execution(tool_id, "", false)

		# Check path permissions before executing
		var path_error = check_tool_path_permissions(tool_name, tool_args, history.AllowedDirectories)
		var result: Dictionary
		if path_error != null:
			print("[Agent] Tool blocked by AllowedDirectories: %s" % tool_name)
			result = path_error
		else:
			# Execute the tool
			result = await mcp_manager.execute_tool(tool_name, tool_args)

		print("[Agent] Tool result: %s" % str(result).left(200))

		# Stringify and truncate the result to prevent context explosion
		var result_str = JSON.stringify(result)
		var original_len = result_str.length()
		result_str = truncate_tool_result(result_str, history.AgentMaxToolResultLength)
		if result_str.length() < original_len:
			print("[Agent] Truncated tool result from %d to %d chars" % [original_len, result_str.length()])

		# Update execution entry with result
		var is_error = result.get("error") != null
		execution_entry["result"] = result_str
		execution_entry["status"] = "error" if is_error else "done"

		# Update the rendered node with the result
		if model_chi.rendered_node:
			model_chi.rendered_node.update_tool_execution(tool_id, result_str, is_error)

		# Create tool result history item (hidden - for API continuity only)
		var tool_result_item = ChatHistoryItem.new()
		tool_result_item.Role = ChatHistoryItem.ChatRole.TOOL
		tool_result_item.ToolCallId = tool_id
		tool_result_item.ToolName = tool_name
		tool_result_item.Message = result_str
		tool_result_item.provider = history.provider
		tool_result_item.Visible = false  # Don't render separately - shown in parent message

		# Add to history (this is critical - must happen before continuation)
		history.HistoryItemList.append(tool_result_item)

	# Add tool block marker to message for proper interleaving during render
	# Format: {{TOOL_BLOCK:count}} where count is the number of tool executions for this round
	var tool_count = tool_calls.size()
	if not model_chi.Message.is_empty():
		model_chi.Message += "\n\n{{TOOL_BLOCK:%d}}" % tool_count
	else:
		model_chi.Message = "{{TOOL_BLOCK:%d}}" % tool_count

	# Check context limits before continuing
	var context_status = check_agent_context_limits(history)
	if not context_status.ok:
		# Hard limit exceeded - stop the agent loop
		push_warning("Agent mode: %s" % context_status.message)
		finish_with_signal.call()
		return
	elif context_status.warning:
		# Warning threshold - try to summarize
		if context_status.estimated_tokens >= context_status.summarize_threshold:
			summarize_agent_history(history)
			var new_size = estimate_agent_context_size(history)
			print("[Agent] Context reduced to ~%d tokens" % new_size)

	# Ensure tools are still enabled for continuation request (with filtering)
	if history.provider.has_method("set_tools"):
		var mcp_tools = mcp_manager.get_tools_for_anthropic()
		var filtered_tools = mcp_tools.filter(func(tool):
			return tool.get("name", "") not in history.DisabledTools
		)
		history.provider.set_tools(filtered_tools)

	# Check for cancellation before continuation
	if SingletonObject.is_cancelled(history.HistoryId):
		SingletonObject.clear_cancelled(history.HistoryId)
		finish_with_signal.call()
		return

	# Build continuation prompt with tool results
	# Use create_prompt() to properly handle system messages (filters them from messages array
	# and sets provider.system_prompt for Anthropic/Google)
	# NOTE: Use refresh_detached=false to use cached notes (created when tool enabled "Send to LLM")
	# instead of calling the initializer again, which can cause issues with graphics composition
	var continuation_list = await create_prompt(null, false)

	print("[Agent] Sending continuation with %d messages" % continuation_list.size())

	# Show loading state at bottom of message (append mode - doesn't hide content)
	if model_chi.rendered_node:
		model_chi.rendered_node.loading_append = true

	# Get LLM's response to tool results
	var continuation_response = await generate_content_from_provider(history, continuation_list)

	if not continuation_response:
		print("[Agent] ERROR: No continuation response received")
		if model_chi.rendered_node:
			model_chi.rendered_node.loading_append = false
		finish_with_signal.call()
		return

	# Check for errors in response
	if continuation_response.error:
		print("[Agent] ERROR in response: %s" % continuation_response.error)
		# Append error message to accumulator
		model_chi.Message += "\n\n[Agent Error: %s]" % continuation_response.error
		if model_chi.rendered_node:
			model_chi.rendered_node.loading_append = false
			model_chi.rendered_node.render()
		finish_with_signal.call()
		return

	# Process the continuation response
	var continuation_chi = process_bot_response(continuation_response, history.provider)

	print("[Agent] Continuation has tool_calls: %s" % continuation_response.has_tool_calls())

	# Append continuation text to accumulator (if any)
	if not continuation_chi.Message.is_empty():
		if model_chi.Message.is_empty():
			model_chi.Message = continuation_chi.Message
		else:
			model_chi.Message += "\n\n" + continuation_chi.Message

	# Check if there are more tool calls
	if continuation_response.has_tool_calls():
		continuation_chi.IsToolCall = true
		continuation_chi.ToolCalls = continuation_response.tool_calls
		continuation_chi.Visible = false  # Don't render separately - shown in accumulator

		# Add to history for API continuity (but hidden from UI)
		history.HistoryItemList.append(continuation_chi)

		# NOTE: Do NOT update model_chi.ToolCalls - that would corrupt the API history!
		# The ToolCalls stay with their respective ChatHistoryItems for proper API serialization.
		# We only use ToolExecutions for UI display (which is already being updated correctly).

		# Update the accumulator's rendered node
		if model_chi.rendered_node:
			model_chi.rendered_node.loading_append = false
			model_chi.rendered_node.render()
			await get_tree().process_frame
			# Use bottom scroll to follow the growing content (tool calls)
			history.VBox.ensure_node_bottom_is_visible(model_chi.rendered_node)

		# Check for cancellation before recursion
		if SingletonObject.is_cancelled(history.HistoryId):
			SingletonObject.clear_cancelled(history.HistoryId)
			# Add tool_results for unexecuted tools so conversation can continue
			_add_unexecuted_tool_results(history, continuation_response.tool_calls, "Cancelled by user")
			finish_with_signal.call()
			return

		# Recursively handle more tool calls (keep same accumulator)
		await handle_tool_calls(history, continuation_response.tool_calls, current_round + 1,
							   model_chi, user_history_item)
	else:
		# No more tool calls, finalize the response
		print("[Agent] Final response (no more tool calls)")
		continuation_chi.Visible = false  # Don't render separately

		# Add to history for API continuity (but hidden from UI)
		history.HistoryItemList.append(continuation_chi)

		# Final update to accumulator
		# NOTE: Do NOT clear IsToolCall - the accumulator must retain its tool_calls
		# for API serialization so subsequent requests see the proper message sequence
		if model_chi.rendered_node:
			model_chi.rendered_node.loading_append = false
			model_chi.rendered_node.first_time_message = true
			model_chi.rendered_node.render()
			await get_tree().process_frame
			# Use bottom scroll to show the final response at the end
			history.VBox.ensure_node_bottom_is_visible(model_chi.rendered_node)

		finish_with_signal.call()


func execute_sequential_chat(text_input: String) -> void:
	if text_input.is_empty(): return
	ensure_chat_open()
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	var last_msg = history.HistoryItemList.back() if not history.HistoryItemList.is_empty() else null
	# Check if we need to do chain of messages
	_inputs = get_separated_messages(text_input)
	
	for i in _inputs:
		if SingletonObject.is_cancelled(history.HistoryId):
			SingletonObject.clear_cancelled(history.HistoryId)
			return
		var user_history_item = create_user_history_item(i)
		
		# In execute_sequential_chat function, update this part:
		if user_history_item.provider is HumanProvider:
			handle_human_provider_message(history, user_history_item)
			for j in SingletonObject.notes_container.get_tab_count():
				SingletonObject.notes_container.disable_notes(j)

			for j in SingletonObject.drawer_notes_container.get_tab_count():
				SingletonObject.drawer_notes_container.disable_notes(j)
			
			SingletonObject.detached_note_proxies.map(func(proxy: Note.Proxy): (await proxy.create_note(true)).enabled = false)
			SingletonObject.detached_note_proxies.clear()

			return # if user is using Human provider we finish here
		
		# Check is the last message is a user message and not do anything if true
		if last_msg and last_msg.Role == ChatHistoryItem.ChatRole.USER: return
		
		# make a chat request
		var history_list: = await create_prompt(user_history_item)
		# first pass `user_history_item` to `create_prompt` so it gets all the notes, and now add it to history
		history.HistoryItemList.append(user_history_item)
		user_history_item.EstimatedTokenCost = int(history.provider.estimate_tokens_from_prompt(history_list))
		
		# rerender the message since we changed the history item
		var user_msg_node: = history.VBox.add_history_item(user_history_item)
		user_msg_node.first_time_message = true
		history.VBox.ensure_node_is_visible(user_msg_node)
		user_msg_node.render()
		# Add empty history item, to show the loading state
		var dummy_item: = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT,
											ChatHistoryItem.ChatRole.MODEL,
											"")
		dummy_item.provider = history.provider
		
		var model_msg_node = create_model_message_node(history, dummy_item)
		var bot_response = await generate_content_from_provider(history, history_list)
		
		var chi = process_bot_response(bot_response, history.provider)
		update_ui_after_response(user_history_item, user_msg_node, model_msg_node, chi, bot_response, history)
	_active_chat_requests -= 1
	if _active_chat_requests <= 0:
		_active_chat_requests = 0
		audio_stop_1.disabled = true

	for i in SingletonObject.notes_container.get_tab_count():
		SingletonObject.notes_container.disable_notes(i)

	for i in SingletonObject.drawer_notes_container.get_tab_count():
		SingletonObject.drawer_notes_container.disable_notes(i)
	
	SingletonObject.detached_note_proxies.map(func(proxy: Note.Proxy): (await proxy.create_note(true)).enabled = false)
	SingletonObject.detached_note_proxies.clear()

var parallel_loading: = preload("res://Scenes/multi_message_loading.tscn")
var _mutex: Mutex = Mutex.new()
var _inputs: Array[String] = []
var _usr_messages_container: SliderContainer
var _mdl_messages_container: SliderContainer
var _usr_chat_hist_items: Array[ChatHistoryItem] = []
var _bot_responses: Array[ChatHistoryItem] = []
var _user_parallel_chat_UUID: String = ""
var _parallel_chat_UUID: String = ""
var _multi_slider_container_UUID: String = ""
func execute_parallel_chat(text_input: String) -> void:
	if text_input.is_empty(): return
	ensure_chat_open()
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	# Check if we need to do chain of messages
	_inputs = get_separated_messages(text_input)
	var multi_message_container:  = MultiSliderContainer.new()
	_usr_messages_container = SliderContainer.new()
	_mdl_messages_container = SliderContainer.new()
	multi_message_container.add_child(_usr_messages_container)
	multi_message_container.add_child(_mdl_messages_container)
	var parallel_message_loading: = parallel_loading.instantiate()
	history.VBox.add_child(parallel_message_loading)
	history.VBox.scroll_to_bottom()
	history.VBox.add_child(multi_message_container)
	
	_user_parallel_chat_UUID = SingletonObject.generate_UUID()
	_parallel_chat_UUID = SingletonObject.generate_UUID()
	_multi_slider_container_UUID = SingletonObject.generate_UUID()
	var task_id = WorkerThreadPool.add_group_task(create_message_new, _inputs.size())
	
	WorkerThreadPool.wait_for_group_task_completion(task_id)


func _on_thread_bot_response_arrived(chat_hist_item: ChatHistoryItem = null) -> void:
	if chat_hist_item == null:
		return
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	var user_msg: ChatHistoryItem = _usr_chat_hist_items.pop_front()
	var bot_response: ChatHistoryItem = chat_hist_item
	
	for i in get_tree().get_nodes_in_group("parallelLoadingNode"):
		i.queue_free()
	
	user_msg.SliderContainerId = _user_parallel_chat_UUID
	bot_response.SliderContainerId = _parallel_chat_UUID
	user_msg.MultiSliderContainerId = _multi_slider_container_UUID
	bot_response.MultiSliderContainerId = _multi_slider_container_UUID
	if _bot_responses.is_empty() and _usr_chat_hist_items.is_empty():
		_user_parallel_chat_UUID = ""
		_parallel_chat_UUID = ""
		_multi_slider_container_UUID = ""
		_active_chat_requests -= 1
		if _active_chat_requests <= 0:
			_active_chat_requests = 0
			audio_stop_1.disabled = true

	if SingletonObject.is_cancelled(history.HistoryId):
		SingletonObject.clear_cancelled(history.HistoryId)
		return
	var usr_msg_node: = history.VBox.add_history_item(user_msg, false)
	var mdl_msg_node: = history.VBox.add_history_item(bot_response, false)
	if user_msg.provider is HumanProvider:
		
		_usr_messages_container.add_child(usr_msg_node)
		usr_msg_node.regeneratable = false
		usr_msg_node.render()
		
		_mdl_messages_container.add_child(mdl_msg_node)
		mdl_msg_node.regeneratable = false
		mdl_msg_node.render()
		mdl_msg_node.set_edit()
	else:
		usr_msg_node.render()
		_usr_messages_container.add_child(usr_msg_node)
		_mdl_messages_container.add_child(mdl_msg_node)


func create_message_new(inputs_idx: int) -> void:
	print("paralel messages idx:" + str(inputs_idx))
	_mutex.lock()
	var message = _inputs.pop_front()
	_mutex.unlock()
	print("message from thread #%d: %s" % [inputs_idx, message])
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	var user_history_item = create_user_history_item(message)
	
	user_history_item.response_arrived.connect(_on_thread_bot_response_arrived)
	
	if user_history_item.provider is HumanProvider:
		var mdl_history_item: = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT,
													ChatHistoryItem.ChatRole.MODEL,
													"")
		_mutex.lock()
		_usr_chat_hist_items.append(user_history_item)
		_bot_responses.append(mdl_history_item)
		_mutex.unlock()
		return
	
	# make a chat request
	var history_list: = await create_prompt(user_history_item)
	
	user_history_item.EstimatedTokenCost = int(history.provider.estimate_tokens_from_prompt(history_list))
	
	
	var bot_response = await generate_content_from_provider(history, history_list)
	
	# Create history item from bot response
	var chi = process_bot_response(bot_response, history.provider)

	# Update user message node with input tokens (prompt tokens for this turn)
	if bot_response != null:
		user_history_item.InputTokens = bot_response.prompt_tokens

	_mutex.lock()
	_usr_chat_hist_items.append(user_history_item)
	history.HistoryItemList.append(user_history_item)
	history.HistoryItemList.append(chi)
	_bot_responses.append(chi)
	_mutex.unlock()
	
	## Inform the user history item that the response has arrived
	user_history_item.response_arrived.emit(chi)


func check_for_create_files(input: String) -> bool:
	if input.split("\n")[0].to_lower().contains("create"):
		return true
	else:
		return false


func get_separated_messages(input: String) -> Array[String]:
	var _inputs_to_return : Array[String] = []
	for i in input.strip_edges().split("\n"):
		_inputs_to_return.append(i)
	return _inputs_to_return

# TODO: check if changing the active tab during the request causes any trouble
#signal my_signal(value)

	
## This function takes `partial_chi` and prompts model to finish the response
## merging the new and the initial response into one and returning it.
func continue_response(partial_chi: ChatHistoryItem) -> ChatHistoryItem:
	# make a chat request with temporary chat history item
	var temp_chi = partial_chi.provider.continue_partial_response(partial_chi)

	var history_list: Array[Variant] = await SingletonObject.Chats.create_prompt(temp_chi)
	
	# remove_chat_history_item(partial_chi, SingletonObject.ChatList[current_tab])

	var bot_response = await partial_chi.provider.generate_content(history_list)

	# if there was an error just return the partial response
	if not bot_response: return partial_chi

	partial_chi.Message += " %s" % bot_response.text
	partial_chi.Complete = bot_response.complete

	# set the history item for the rendered node so it gets rerendered
	partial_chi.rendered_node.history_item = partial_chi

	# var chi = ChatHistoryItem.new()
	# chi.Role = ChatHistoryItem.ChatRole.MODEL
	# # merge the two responses
	# chi.Message = "%s %s" % [partial_chi.Message, bot_response.text]

	# ## Inform the user history item that the response has arrived
	# partial_chi.response_arrived.emit(partial_chi)

	return partial_chi

## Render a full chat history response
func render_single_chat(item: ChatHistoryItem):
	SingletonObject.ChatList[current_tab].HistoryItemList.append(item)

	# Ask the Vbox to add the message
	# and save the rendered node to the chat history item, si we can delete it if needed
	item.rendered_node = SingletonObject.ChatList[current_tab].VBox.add_history_item(item)
	


## Will remove the chat history item from the history and remove the rendered node.
## if `auto_merge` is false, this function will only delete the given history item and it's rendered node,
## otherwise, it will automatically merge next message with previous so preserve the user/model turn
func remove_chat_history_item(item: ChatHistoryItem, history: ChatHistory = null, auto_merge:= true):
	if item.rendered_node:
		item.rendered_node.queue_free()
	else:
		push_warning("Trying to delete chat history item %s with no rendered node attached to it" % item)
		return
	
	# if `auto_merge` is true, keep the item until we find previous and next history items
	# and delete it at the end
	if not auto_merge:
		history.HistoryItemList.erase(item)
		return

	if not history:
		for h in SingletonObject.ChatList:
			if h.HistoryItemList.has(item):
				history = h
				break

	if not history:
		push_error("Trying to remove history item %s not present in any history item list" % item)
		return

	var item_index = history.HistoryItemList.find(item)

	var previous: ChatHistoryItem
	var next: ChatHistoryItem

	if item_index > 0:
		previous = history.HistoryItemList[item_index-1]

	if item_index < history.HistoryItemList.size()-1:
		next = history.HistoryItemList[item_index+1]

	# Removing this conditional check causes issues with instruction tuning, 
	# violating the expected User/Assistant/User/Assistant order.  
	# This block ensures that adjacent messages from the same role are merged,  
	# maintaining structured conversation flow.  
	#  
	# TODO: Implement an Unsplit function to reverse the merging process,  
	# allowing split messages to be recombined into a single entry.
	
	if previous and next and previous.Role == next.Role:
		previous.merge(next)
		previous.rendered_node.find_child("UnsplitButton").visible = true
		remove_chat_history_item(next, history, false)
		previous.rendered_node.history_item = previous
			
	history.HistoryItemList.erase(item)


## Will hide the chat history item. If `remove_pair` is true
## and the item is user message it will also hide the answer or 
## the question if the item is bot message if the item is present in any chat history.
func hide_chat_history_item(item: ChatHistoryItem, history: ChatHistory = null, remove_pair: = true):	
	item.Visible = false
	item.rendered_node.render()

	if not remove_pair: return
	
	if not history:
		for h in SingletonObject.ChatList:
			if h.HistoryItemList.has(item):
				history = h
				break

	if not history:
		push_warning("Hiding history item %s not present in any history item list" % item)
		return
		
	var item_index = history.HistoryItemList.find(item)
	## if the item is user message, check if there's next message that's model and hide it
	if item.Role == ChatHistoryItem.ChatRole.USER:
		if history.HistoryItemList.size() > item_index:
			var next_item = history.HistoryItemList[item_index+1]
			if next_item.Role == ChatHistoryItem.ChatRole.MODEL:
				next_item.Visible = false
				next_item.rendered_node.render()
	## if the item is user message, check if there's previous message that's user and hide it
	elif item.Role == ChatHistoryItem.ChatRole.MODEL:
		if item_index > 0:
			var previous_item = history.HistoryItemList[item_index-1]
			if previous_item.Role == ChatHistoryItem.ChatRole.USER:
				previous_item.Visible = false
				previous_item.rendered_node.render()


func render_history(chat_history: ChatHistory):

	# Create wrapper VBoxContainer to hold header and scroll container
	var wrapper = VBoxContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Create and setup ChatHeader at top of each tab
	var ChatHeaderScript = load("res://Scripts/UI/Controls/ChatHeader.gd")
	var header = ChatHeaderScript.new()
	header.setup(chat_history)
	header.agent_mode_toggled.connect(_on_chat_header_agent_mode_toggled.bind(chat_history))
	wrapper.add_child(header)

	# Create a ScrollContainer and set flags
	var scroll_container = ScrollContainer.new()
	#scroll_container.follow_focus
	scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# create a derived VBoxContainer for chats and add to the scroll container
	var vboxChat: VBoxChat = VBoxChat.new(self)
	vboxChat.chat_history = chat_history
	chat_history.VBox = vboxChat

	scroll_container.add_child(vboxChat)
	wrapper.add_child(scroll_container)

	# set the scroll container name and add it to the pane.
	var _name = chat_history.HistoryName
	#scroll_container.name = _name
	%tcChats.add_child(wrapper)
	var tab_idx = %tcChats.get_tab_idx_from_control(wrapper)
	%tcChats.set_tab_title(tab_idx, _name)
	
	var multi_slider_containers: = {}
	var slider_containers: = {}
	for item in chat_history.HistoryItemList:
		# if the SliderContainerId if empty it means is a stand alone item and we just add it
		if item.SliderContainerId == "" and item.MultiSliderContainerId == "": 
			vboxChat.add_history_item(item)
		elif multi_slider_containers.has(item.MultiSliderContainerId):
			if slider_containers.has(item.SliderContainerId):
				var slider: = slider_containers.get(item.SliderContainerId) as SliderContainer
				slider.add_child(vboxChat.add_history_item(item, false))
			else:
				var new_slider_cont = SliderContainer.new()
				new_slider_cont.add_child(vboxChat.add_history_item(item, false))
				var multi_slider: = multi_slider_containers.get(item.MultiSliderContainerId) as MultiSliderContainer
				multi_slider.add_child(new_slider_cont)
				slider_containers.set(item.SliderContainerId, new_slider_cont)
		else:
			var new_multi_slider_cont: = MultiSliderContainer.new()
			var slider: SliderContainer = SliderContainer.new()
			new_multi_slider_cont.add_child(slider)
			slider.add_child(vboxChat.add_history_item(item, false))
			slider_containers.set(item.SliderContainerId, slider)
			multi_slider_containers.set(item.MultiSliderContainerId, new_multi_slider_cont)
			vboxChat.add_child(new_multi_slider_cont)


# Called when the node enters the scene tree for the first time.
func _ready():
	self.get_tab_bar().tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	self.get_tab_bar().tab_close_pressed.connect(_on_close_tab.bind(self))

	# SingletonObject.initialize_chats(self)
	%AISettings.create_system_prompt_message.connect(add_new_system_prompt_item)

	# Hide old AgentModeToggle in chat controls - agent mode is now per-chat via ChatHeader
	%AgentModeToggle.hide()

	#this is for overriding the separation in the open file dialog
	#this seems to be the only way I can access it
	var hbox: HBoxContainer = %AttachFileDialog.get_vbox().get_child(0)
	hbox.set("theme_override_constants/separation", 12)

	SingletonObject.note_toggled.connect(_on_note_toggled)
	SingletonObject.note_changed.connect(_on_note_changed)

	SingletonObject.Chats = self

	# Setup debounce timer for token estimation (300ms delay)
	_token_estimation_timer = Timer.new()
	_token_estimation_timer.one_shot = true
	_token_estimation_timer.wait_time = 0.3
	_token_estimation_timer.timeout.connect(_on_token_estimation_timer_timeout)
	add_child(_token_estimation_timer)


## Handle global input - ESC key triggers stop
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _active_chat_requests > 0:
			_on_audio_stop_1_pressed()
			get_viewport().set_input_as_handled()


# if a note is enabled/disabled recalculate the token cost
func _on_note_toggled(_note: Note, _on: bool):
	update_token_estimation()

# if a note is changed recalculate the token cost
func _on_note_changed(_note: Note,):
	update_token_estimation()

func _on_close_tab(tab: int, closed_tab_container: TabContainer):
	self.control = closed_tab_container.get_tab_control(tab)
	self.container = closed_tab_container 
	SingletonObject.undo.store_deleted_tab(tab, control,"left")
	closed_tab_container.remove_child(control)
	
	if get_tab_count() < 1 :
		buffer_control_chats.show()
	

# Function to restore a deleted tab
func restore_deleted_tab(tab_name: String):
	if tab_name in SingletonObject.undo.deleted_tabs:
		var data = SingletonObject.undo.deleted_tabs[tab_name]
		var tab = data["tab"]
		var control_ = data["control"]
		#var history = data["history"]
		data["timer"].stop()
		#Add the control back to the TabContainer
		%tcChats.call_deferred("add_child", control_)#add_child(control_)
		
		# Set the tab index and restore the history
		if tab != 0:
			control_.name = "Chat " + str(tab)
		else:
			control_.name = "Chat"
		set_current_tab(tab)
		# Clear the deleted tab from the dictionary
		SingletonObject.undo.deleted_tabs.erase(tab_name)

## Feature development -- create a button and add it to the upper chat vbox?
func _on_btn_test_pressed():
	if len(SingletonObject.ChatList) <= current_tab:
		_on_new_chat()

	# Pretend we did a chat like "Write hello world in python" and got a BotResponse that made sense.
	var item:= ChatHistoryItem.new()
	#test_response.FullText = "Here is how you write hello world in python:\n```python\nprint (\"Hello World\")\n```"
	item.Message = """
		## Markdown
		Here is how you write hello world in python:
		print ("Hello World")
	"""
	self.render_single_chat(item)
	pass # Replace with function body.


func clear_all_chats():
	for child in get_children():
		remove_child(child)
		child.queue_free()


func update_token_estimation(provider: BaseProvider = null):

	if not provider:
		# if we don't have any chats use the selected provider from the dropdown
		if SingletonObject.ChatList.is_empty():

			provider = _provider_option_button.get_selected_provider()
		else:
			provider = SingletonObject.ChatList[current_tab].provider

	# Use fast estimation that avoids expensive base64 encoding
	var token_count = await _estimate_tokens_fast(provider)

	%EstimatedTokensLabel.text = "%s¢" % [snapped( (provider.token_cost * token_count) * 100, 0.01)]
	if (provider.token_cost * token_count) * 100 < 0.01:
		%EstimatedTokensLabel.text = "%s¢" % 0.01


## Fast token estimation that avoids expensive operations like base64 encoding.
## Only does the full create_prompt() when actually sending messages.
func _estimate_tokens_fast(provider: BaseProvider) -> float:
	var token_count: float = 0.0

	# Estimate tokens from user input text
	token_count += provider.estimate_tokens(%txtMainUserInput.text)

	# Estimate tokens from chat history (text and images)
	if not SingletonObject.ChatList.is_empty():
		var history: ChatHistory = SingletonObject.ChatList[current_tab]
		for chat: ChatHistoryItem in history.HistoryItemList:
			token_count += provider.estimate_tokens(chat.Message)
			# Also count images in chat history
			for img: Image in chat.Images:
				if img:
					var tiles_x = ceil(img.get_width() / 512.0)
					var tiles_y = ceil(img.get_height() / 512.0)
					token_count += (tiles_x * tiles_y) * 170.0 + 85.0

	# Estimate tokens from enabled notes (text notes directly, images by dimensions)
	for i in SingletonObject.notes_container.get_tab_count():
		for note: Note in SingletonObject.notes_container.get_notes(i):
			if note.enabled:
				token_count += _estimate_note_tokens(note)

	for i in SingletonObject.drawer_notes_container.get_tab_count():
		for note: Note in SingletonObject.drawer_notes_container.get_notes(i):
			if note.enabled:
				token_count += _estimate_note_tokens(note)

	# Estimate tokens from detached notes (editor notes with "send to chat" enabled)
	for proxy_note in SingletonObject.detached_note_proxies:
		var note: Note = await proxy_note.create_note(true)  # use_cached=true
		if note:
			token_count += _estimate_note_tokens(note)

	return token_count


## Estimate tokens for a note without expensive encoding
func _estimate_note_tokens(note: Note) -> float:
	match note.type:
		Note.Type.TEXT:
			var controls = note.get_controls_container() as NoteTextControls
			if controls:
				return float(controls.content.length()) / 4.0  # Rough estimate: 4 chars per token
		Note.Type.IMAGE:
			var controls = note.get_controls_container() as NoteImageControls
			if controls:
				# Use cached image property (no GPU copy, no encoding)
				var img: Image = controls.image
				if img:
					# Estimate image tokens from dimensions (OpenAI formula)
					var tiles_x = ceil(img.get_width() / 512.0)
					var tiles_y = ceil(img.get_height() / 512.0)
					return (tiles_x * tiles_y) * 170.0 + 85.0
	return 0.0

# region Edit provider Title

func show_title_edit_dialog(tab: int):
	%EditTitleDialog.set_meta("tab", tab)
	%LineEdit.text = get_tab_title(tab)
	%LineEdit.select_all()
	%LineEdit.call_deferred("grab_focus")
	%EditTitleDialog.popup_centered()


func _on_edit_title_dialog_confirmed():
	var tab = %EditTitleDialog.get_meta("tab")
	set_tab_title(tab, %LineEdit.text)
	SingletonObject.ChatList[tab].HistoryName = %LineEdit.text


func _on_line_edit_text_submitted(_new_text: String) -> void:
	_on_edit_title_dialog_confirmed()
	%EditTitleDialog.hide()


# Detect the double click and open the title edit popup
var clicked:= false
func _on_tab_clicked(tab: int):
	if clicked: show_title_edit_dialog(tab)
	clicked = true
	get_tree().create_timer(0.4).timeout.connect(func(): clicked = false)

# endregion

## Function:
# Loads a file and raises a signal to the singleton for the memory tabs
# to attach a file.
func _on_btn_attach_file_pressed():
	var size_x: = get_viewport_rect().size.x * 0.70
	var size_y: = 500
	
	%AttachFileDialog.popup_centered(Vector2(size_x, size_y))

func _on_attach_file_dialog_files_selected(paths: PackedStringArray):
	%AttachFileDialog.exclusive = false
	for fp in paths:
		var note: = Note.create_file_note(fp.get_file(), fp)
		note.initialized.connect(func(): note.expanded = false)
		SingletonObject.notes_container.add_note(note)


func _on_btn_chat_settings_pressed():
	%AISettings.sync_provider_to_current_chat()
	%AISettings.load_current_chat_settings()
	%AISettings.popup_centered()


func _on_btn_clear_pressed():
	%txtMainUserInput.text = ""


## Handle Agent Mode toggle from ChatHeader (per-chat)
func _on_chat_header_agent_mode_toggled(toggled_on: bool, history: ChatHistory) -> void:
	if toggled_on:
		# Initialize MCP manager if not already done
		var mcp = SingletonObject.get_mcp_manager()
		var tools = mcp.get_available_tools()
		print("[Agent Mode] Enabled for '%s' with %d tools available" % [history.HistoryName, tools.size()])
		if tools.is_empty():
			push_warning("Agent Mode enabled but no MCP tools are available. Connect to MCP servers first.")
	else:
		print("[Agent Mode] Disabled for '%s'" % history.HistoryName)


## Handle Agent Mode toggle (legacy - kept for compatibility)
func _on_agent_mode_toggled(_toggled_on: bool) -> void:
	# Legacy handler - agent mode is now per-chat via ChatHeader
	pass


## When user types in the chat box, estimate tokens count based on selected provider
## Uses debouncing to avoid expensive recalculation on every keystroke
func _on_txt_main_user_input_text_changed():
	if %txtMainUserInput.text == "":
		%EstimatedTokensLabel.text = "%s¢" % 0.00
		_token_estimation_timer.stop()
		return
	# Restart debounce timer - actual estimation runs after 300ms of no typing
	_token_estimation_timer.start()

func _on_txt_main_user_input_text_set():
	# Direct call for programmatic text setting (not continuous typing)
	update_token_estimation()

## Called when debounce timer expires - actually run the expensive token estimation
func _on_token_estimation_timer_timeout():
	update_token_estimation()

func _on_btn_microphone_pressed():
	if SingletonObject.AtT._StartConverting() != OK: return
	SingletonObject.AtT.FieldForFilling = %txtMainUserInput
	SingletonObject.AtT.btn = %btnMicrophone
	%btnMicrophone.modulate = Color(Color.LIME_GREEN)
	SingletonObject.AtT.btnStop = %AudioStop1


func _on_child_order_changed():
	if _initializing_pane: return

	# Update ChatList in the SingletonObject
	# Each tab is now a VBoxContainer wrapper containing [ChatHeader, ScrollContainer]
	SingletonObject.ChatList = []
	for child in get_children():
		if child is VBoxContainer:
			# New structure: VBoxContainer wrapper > ChatHeader + ScrollContainer
			for sub_child in child.get_children():
				if sub_child is ScrollContainer:
					var vbox_chat = sub_child.get_child(0)
					if vbox_chat is VBoxChat:
						SingletonObject.ChatList.append(vbox_chat.chat_history)
					break
		elif child is ScrollContainer:
			# Legacy structure for backwards compatibility
			var vbox_chat = child.get_child(0)
			if vbox_chat is VBoxChat:
				SingletonObject.ChatList.append(vbox_chat.chat_history)


func _on_system_button_pressed() -> void:
	%SystemPrompt.popup()



func _on_provider_option_button_provider_selected(provider_: BaseProvider):
	update_token_estimation(provider_)

	if provider_ is CoreProvider:
		var core_provider := provider_ as CoreProvider

		# Check if this is an OpenAI-compatible chat service (like model-chat)
		# These should use the normal text input, not dynamic UI
		if core_provider._is_openai_compatible_service():
			txt_main_user_input.visible = true
			dynamic_ui_container.visible = false
		else:
			# HCP services use dynamic UI based on input_parameters
			var o_params: = core_provider.action.input_parameters

			var controls: = Core.dynamic_ui_generator.process_parameters(o_params)

			for ch in dynamic_ui_container.get_children():
				ch.queue_free()

			for ctrl in controls:
				dynamic_ui_container.add_child(ctrl)

			txt_main_user_input.visible = false
			dynamic_ui_container.visible = true

			_chat_button.enabled = false
			_chat_button.hide_overhang_button()
	else:
		txt_main_user_input.visible = true
		dynamic_ui_container.visible = false
		_chat_button.enabled = true

	if SingletonObject.ChatList.is_empty(): return

	var history = SingletonObject.ChatList[current_tab]

	history.provider = provider_
	if not provider_.is_inside_tree():
		history.VBox.add_child(provider_)

	# If provider requires a default system prompt and none is set, add it
	# This makes it visible in the chat settings so the user can see/edit it
	if provider_.requires_default_system_prompt and not history.HasUsedSystemPrompt:
		add_new_system_prompt_item(provider_.default_system_prompt)
		print("[Chat] Added default system prompt for %s" % provider_.model_name)

	history.VBox.add_program_message("Changed provider to %s %s" % [provider_.provider_name, provider_.display_name])


# when tab changes, set the provider to one that that chat tab is using
func _on_tab_changed(tab: int):
	var active_provider = _provider_option_button.get_provider_for_tab(tab)

	if is_instance_valid(active_provider):
		var item_index = _provider_option_button.get_item_index_for_provider(active_provider)

		_provider_option_button.select(item_index)

		SingletonObject.last_tab_index = tab

## if enter is pressed, accept the event and trigger chat
func _on_txt_main_user_input_gui_input(event: InputEvent):
	if event.is_action_pressed("control_enter"):
		_on_chat_pressed()
		accept_event()


#region Add New HistoryItem

func add_new_system_prompt_item(message: String):
	ensure_chat_open() # we check if their a chat open first
	
	var new_chat_history_item: ChatHistoryItem = ChatHistoryItem.new()# we create the chat item
	new_chat_history_item.Message = message
	new_chat_history_item.Role = ChatHistoryItem.ChatRole.SYSTEM
	
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	
	# we check if there is already a System prompt item in the history and remove it if so
	if history.HistoryItemList.size() > 0:
		if history.HasUsedSystemPrompt: #history.HistoryItemList[0].Role == ChatHistoryItem.ChatRole.SYSTEM:
			history.HistoryItemList.pop_front()
	
	# we add the system prompt to the first place in the chat
	history.HasUsedSystemPrompt = true #we save the state so we can replace the chat item
	history.HistoryItemList.insert(0,new_chat_history_item)


func get_first_chat_item() -> ChatHistoryItem:
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	return history.HistoryItemList.front()

#endregion Add New HistoryItem

func _on_audio_stop_1_pressed() -> void:
	if _active_chat_requests > 0:
		var history: ChatHistory = SingletonObject.ChatList[current_tab]

		# Track this history as cancelled so agentic loops can check
		SingletonObject.cancelled_history_ids.append(history.HistoryId)

		# Emit signal with current tab's identity - only matching providers will cancel
		SingletonObject.stop_all_requests.emit(history.HistoryId)

		# Clean up loading messages only in current tab
		for child in history.VBox.get_children():
			if child is MessageMarkdown:
				# Clear loading animation (used during initial response)
				if child.loading:
					child.loading = false
					history.VBox.remove_child(child)
					child.queue_free()
				# Clear loading_append animation (used during agent mode)
				elif child.loading_append:
					child.loading_append = false

		# Finish agent mode if active
		_finish_agent_mode()

		# Decrement ref count for the stopped request
		_active_chat_requests -= 1
		if _active_chat_requests <= 0:
			_active_chat_requests = 0
			audio_stop_1.disabled = true
	else:
		SingletonObject.AtT._StopConverting()


func clone_chat(tab_idx: int) -> void:
	var chat_to_clone: ChatHistory = SingletonObject.ChatList[tab_idx]
	
	# Clone using the live provider reference, not serialization
	var new_provider = chat_to_clone.provider.get_script().new()
	var new_chat_history: ChatHistory = ChatHistory.new(new_provider)
	new_chat_history.HistoryName = chat_to_clone.HistoryName + " clone"
	new_chat_history.Temperature = chat_to_clone.Temperature
	new_chat_history.TopP = chat_to_clone.TopP
	new_chat_history.PresencePenalty = chat_to_clone.PresencePenalty
	new_chat_history.FrequencyPenalty = chat_to_clone.FrequencyPenalty
	new_chat_history.SystemPromptEnabled = chat_to_clone.SystemPromptEnabled
	new_chat_history.AgenticSystemPromptEnabled = chat_to_clone.AgenticSystemPromptEnabled

	# Deep clone history items
	for item in chat_to_clone.HistoryItemList:
		var serialized = item.Serialize()
		var cloned_item = ChatHistoryItem.Deserialize(serialized)
		new_chat_history.HistoryItemList.append(cloned_item)
	
	SingletonObject.ChatList.append(new_chat_history)
	render_history(new_chat_history)


func _on_clone_chat_button_pressed() -> void:
	if %tcChats.current_tab < 0:
		return
	clone_chat(%tcChats.current_tab)
