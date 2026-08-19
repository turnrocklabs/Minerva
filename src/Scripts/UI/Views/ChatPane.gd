class_name ChatPane
extends TabContainer

const OpenAIImageProviderScript = preload("res://Scripts/Services/Providers/OpenAI/OpenAIImageProvider.gd")
const VoiceGatewayClientScript = preload("res://Scripts/Services/Voice/VoiceGatewayClient.gd")
const PassthroughLaunchDialogScript = preload("res://Scripts/UI/Controls/PassthroughLaunchDialog.gd")
# Preload (not the class_name global) so a --script harness that loads ChatPane.gd
# before the global class cache is built still compiles (W5).
const PassthroughTurnStatusScript = preload("res://Scripts/Models/PassthroughTurnStatus.gd")
# W4 (chat-passthrough): reused AS-IS — the card is self-contained (zero
# autocoder coupling); ChatPane only hosts it and maps label → keystroke.
const PassthroughQuestionCardScene = preload("res://Scripts/UI/Controls/Autocoder/AutocoderStreamQuestionCard.tscn")

var closed_chat_data: ChatHistory  # Store the data of the closed chat
var control: Control  # Store the tab control
var container: TabContainer  # Store the TabContainer

@onready var txt_main_user_input: TextEdit = %txtMainUserInput
@onready var _provider_option_button: ProviderOptionButton = %ProviderOptionButton
@onready var buffer_control_chats: Control = %BufferControlChats
@onready var audio_stop_1: IconsButton = %AudioStop1
@onready var _chat_button: Button = %btnChat
## REMOVED: var _active_chat_requests — replaced by per-chat is_request_active on ServiceHistory

@onready var dynamic_ui_container: Container = %DynamicUIContainer

var _initializing_pane := false

## Debounce timer for token estimation to avoid expensive recalculation on every keystroke
var _token_estimation_timer: Timer

## Compact button in chat controls
var _compact_button: Button
## Whether archived chats are visible
var _showing_archived: bool = false
## Focused chat popup (lazy-instantiated)
var _focused_chat_popup: FocusedChatPopup = null

## Passthrough launch dialog (chat-passthrough W3 — replaced W2's placeholder
## picker; lazy-instantiated by the "⇅" top-bar button)
var _passthrough_launch_dialog: Window = null
## De-dupe ledger for agent-exit messages: "history_id|terminal_id" → true once
## the exit message for that (chat, session) pair has been shown.
var _passthrough_exit_seen: Dictionary = {}

## TTS playback for voice conversation mode (controlled by Voice Preferences)
var _tts_player: AudioStreamPlayer

## Voice gateway client for always-listening mode (wake word + VAD + state machine)
var _voice_gateway: Node = null

## Voice conversation flow control: one utterance → one response
var _voice_llm_busy := false
var _voice_utterance_queue: Array[String] = []
var _gpu_pre_warmed := false
var _engagement_toggle: CheckButton = null
var _engagement_state_label: Label = null

## Default max tool call rounds (fallback if per-chat setting is 0)
const DEFAULT_MAX_TOOL_CALL_ROUNDS: int = 25

## Agent mode context management constants
const AGENT_MAX_TOOL_RESULT_LENGTH: int = 8000  # Truncate tool results longer than this
const AGENT_CONTEXT_WARNING_THRESHOLD: int = 80000  # Warn when estimated tokens exceed this
const AGENT_CONTEXT_HARD_LIMIT: int = 100000  # Stop agent loop when exceeding this
const AGENT_SUMMARIZE_THRESHOLD: int = 60000  # Trigger summarization above this token count
const AGENT_KEEP_RECENT_MESSAGES: int = 6  # Keep this many recent messages when summarizing
const AGENT_NOTES_TAB_PREFIX: String = "Agent Notes"
const AGENT_TOOL_WINDOW_LENGTH: int = 4000
const AGENT_FLOATING_SUMMARY_PROMPT_LENGTH: int = 1200

## Base agent system prompt - tool-specific sections added dynamically
## Hardcoded fallback — only used if docket master prompt is unavailable.
const AGENT_SYSTEM_PROMPT_FALLBACK: String = "You are an AI assistant with access to tools.\n\nPhase 1 — SET UP (do this first):\n1. Call minerva_list_skills to see available guides.\n2. Call minerva_get_skill for each relevant skill. This auto-activates the tools you need — do NOT call minerva_tool_search for tools that a skill already activated.\n3. Only use minerva_tool_search for tools not covered by a skill.\n\nPhase 2 — EXECUTE:\nOnce your tools are ready, do the task. Do not search for more tools during execution."

## Build the agent system prompt.
## Loads from docket master (key: agentic-base), falls back to hardcoded.
## Skills provide all domain-specific guidance — the base prompt just bootstraps.
func _build_agent_system_prompt(history = null) -> String:
	# Load base prompt from docket (project override → master → fallback)
	var dm: DocketManager = SingletonObject.docket_manager
	var prompt: String = ""
	if dm:
		prompt = dm.get_system_prompt("agentic-base")
	if prompt.is_empty():
		prompt = AGENT_SYSTEM_PROMPT_FALLBACK

	# Inject skill instructions from active Minerva skills (note-based)
	var skill_manager = SingletonObject.get_skill_manager()
	if skill_manager and history:
		var chat_skills: Array[String] = []
		if not history.ActiveSkills.is_empty():
			chat_skills.assign(history.ActiveSkills)
		var agent_skills: Array[String] = []
		if not history.AgentDefinitionId.is_empty() and SingletonObject.agent_registry:
			for agent_def in SingletonObject.agent_registry.agents:
				if agent_def.id == history.AgentDefinitionId and not agent_def.skills.is_empty():
					agent_skills.assign(agent_def.skills)
					break

		var instructions = skill_manager.get_skill_instructions(chat_skills, agent_skills)
		if not instructions.is_empty():
			prompt += "\n\n" + instructions

		var fragments = skill_manager.get_prompt_fragments(chat_skills, agent_skills)
		for frag in fragments:
			prompt += "\n\n" + frag

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


func _build_windowed_tool_result_message(tool_name: String, full_result_str: String, note_id: String, include_retrieval_hint: bool, max_length: int = 0) -> Dictionary:
	var limit = max_length if max_length > 0 else AGENT_MAX_TOOL_RESULT_LENGTH
	if full_result_str.length() <= limit:
		var direct_result: Dictionary = {}
		direct_result["text"] = full_result_str
		direct_result["windowed"] = false
		direct_result["shown_chars"] = full_result_str.length()
		return direct_result
	if note_id.is_empty():
		var truncated_text := truncate_tool_result(full_result_str, limit)
		var truncated_result: Dictionary = {}
		truncated_result["text"] = truncated_text
		truncated_result["windowed"] = truncated_text.length() < full_result_str.length()
		truncated_result["shown_chars"] = min(truncated_text.length(), full_result_str.length())
		return truncated_result

	var window_limit: int = min(limit, AGENT_TOOL_WINDOW_LENGTH)
	var window_text := full_result_str.substr(0, window_limit)
	var last_newline := window_text.rfind("\n")
	var last_space := window_text.rfind(" ")
	var cut_point := maxi(last_newline, last_space)
	if cut_point > int(window_limit * 0.8):
		window_text = window_text.substr(0, cut_point)

	var windowed_result: Dictionary = {}
	if include_retrieval_hint:
		var ref_message := ToolMemoryManager.build_tool_ref_message(tool_name, note_id, false)
		var retrieval_hint: String = "[w %d/%d %s more:minerva_read_agent_note note_id=%s offset=%d limit=%d]" % [
			window_text.length(),
			full_result_str.length(),
			ref_message,
			note_id,
			window_text.length(),
			AGENT_TOOL_WINDOW_LENGTH,
		]
		windowed_result["text"] = "%s\n\n%s" % [window_text, retrieval_hint]
	else:
		windowed_result["text"] = window_text
	windowed_result["windowed"] = true
	windowed_result["shown_chars"] = window_text.length()
	return windowed_result


func _trim_prompt_context_tail(text: String, limit: int) -> String:
	var trimmed := text.strip_edges()
	if trimmed.length() <= limit:
		return trimmed

	var tail := trimmed.substr(trimmed.length() - limit, limit)
	var first_newline := tail.find("\n")
	var first_space := tail.find(" ")
	var cut_point := -1
	if first_newline >= 0 and first_space >= 0:
		cut_point = mini(first_newline, first_space)
	else:
		cut_point = maxi(first_newline, first_space)
	if cut_point >= 0 and cut_point < int(limit * 0.2):
		tail = tail.substr(cut_point + 1)
	return "...%s" % tail


func _filter_tool_result_text(result_str: String) -> String:
	var lines := result_str.split("\n")
	var filtered := PackedStringArray()
	var previous_line := ""
	var repeat_count := 0

	for raw_line in lines:
		var line := str(raw_line).rstrip("\r").strip_edges(false, true)
		var stripped := line.strip_edges()
		var is_separator := stripped.length() >= 5 and stripped.replace("-", "").is_empty()
		is_separator = is_separator or (stripped.length() >= 5 and stripped.replace("=", "").is_empty())
		if is_separator:
			continue
		if stripped.is_empty():
			if previous_line.is_empty():
				continue
			previous_line = ""
			filtered.append("")
			continue
		if line == previous_line:
			repeat_count += 1
			continue
		if repeat_count > 0:
			filtered.append("... repeated %d more times" % repeat_count)
			repeat_count = 0
		filtered.append(line)
		previous_line = line

	if repeat_count > 0:
		filtered.append("... repeated %d more times" % repeat_count)

	return "\n".join(filtered).strip_edges()


func _get_agent_notes_tab(history: ChatHistory) -> NoteVBox:
	if not SingletonObject.agent_notes_container:
		return null

	if not history.AgentNotesTabId.is_empty():
		for i in range(SingletonObject.agent_notes_container.get_tab_count()):
			if SingletonObject.agent_notes_container.get_tab_id(i) == history.AgentNotesTabId:
				return SingletonObject.agent_notes_container.get_tab_control(i) as NoteVBox

	var tab_name := history.HistoryName if not history.HistoryName.is_empty() else "Chat %s" % history.HistoryId.left(8)
	var agent_key := "chat:%s" % history.HistoryId
	var vbox := SingletonObject.agent_notes_container.find_or_create_agent_tab(tab_name, agent_key)
	if history.HistoryId not in vbox.default_linked_chat_ids:
		vbox.default_linked_chat_ids.append(history.HistoryId)
	var tab_idx := SingletonObject.agent_notes_container.get_tab_idx_from_control(vbox)
	if tab_idx >= 0:
		history.AgentNotesTabId = SingletonObject.agent_notes_container.get_tab_id(tab_idx)
	return vbox


func _sync_agent_notes_tab_title(history: ChatHistory) -> void:
	if history.AgentNotesTabId.is_empty() or not SingletonObject.agent_notes_container:
		return
	for i in range(SingletonObject.agent_notes_container.get_tab_count()):
		if SingletonObject.agent_notes_container.get_tab_id(i) == history.AgentNotesTabId:
			SingletonObject.agent_notes_container.set_tab_title(i, history.HistoryName)
			break


func _upsert_agent_note(history: ChatHistory, existing_note_id: String, title: String, content: String, enabled: bool = false) -> String:
	var tab := _get_agent_notes_tab(history)
	if not tab:
		return ""

	var note: Note = null
	if not existing_note_id.is_empty():
		for candidate in tab.get_notes():
			if candidate.uuid == existing_note_id:
				note = candidate
				break

	if not note:
		note = Note.create_text_note(title, content)
		note.link_to_chat(history.HistoryId)
		note.enabled = enabled
		tab.add_note(note)
		return note.uuid

	note.title = title
	var controls = note.get_controls_container()
	if controls and controls is NoteTextControls:
		controls.content = content
	note.enabled = enabled
	return note.uuid


## Read agent context summary settings from the preferences popup.
func _get_agent_context_summary_settings_local() -> Dictionary:
	if SingletonObject.preferences_popup and SingletonObject.preferences_popup.has_method("get_agent_context_summary_config"):
		return SingletonObject.preferences_popup.get_agent_context_summary_config()
	return {}


## Configure the ToolMemoryManager's injectable callables for a given chat history.
## Call this before any agent mode prompt building or tool execution.
func _configure_tool_memory_manager(history: ChatHistory) -> void:
	var tmm := history.tool_memory_manager
	var settings := _get_agent_context_summary_settings_local()
	var tool_memory_config: Dictionary = settings.get("tool_memory_manager", {})
	var manager_config := tool_memory_config.duplicate(true)
	manager_config["summary_prompt"] = str(settings.get("summary_prompt", ""))
	manager_config["summary_settings"] = settings
	tmm.apply_config(manager_config)
	tmm.summary_settings = settings
	tmm.note_upsert_fn = func(h, nid, title, content, en): return _upsert_agent_note(h, nid, title, content, en)
	tmm.summary_call_fn = func(spec, sett, prompt): return await _call_agent_context_summary_provider(spec, sett, prompt)
	if bool(settings.get("fallback_enabled", false)) and not (settings.get("fallback_provider", {}) as Dictionary).is_empty():
		tmm.fallback_summary_call_fn = func(spec, sett, prompt): return await _call_agent_context_summary_provider(spec, sett, prompt)
	else:
		tmm.fallback_summary_call_fn = Callable()


func _build_tool_summary(tool_name: String, result: Dictionary, note_id: String) -> String:
	var ref_suffix := ""
	if not note_id.is_empty() and bool(SingletonObject.get_config_file_value("ToolMemoryManager", "enabled") if SingletonObject.get_config_file_value("ToolMemoryManager", "enabled") != null else false):
		ref_suffix = " [agent-note:%s]" % note_id.left(8)

	match tool_name:
		"minerva_list_skills":
			var skills: Array = result.get("skills", [])
			return "[list_skills: %d skills]%s" % [skills.size(), ref_suffix]
		"minerva_tool_search":
			var activated: Array = result.get("activated", [])
			return "[tool_search: %d activated]%s" % [activated.size(), ref_suffix]
		"minerva_list_models":
			var models: Array = result.get("results", [])
			return "[list_models: %d models]%s" % [models.size(), ref_suffix]
		"minerva_get_skill":
			var skill_name: String = str(result.get("name", result.get("id", "skill")))
			var activated: Array = result.get("activated_tools", [])
			if activated.size() > 0:
				return "[get_skill: %s | activated: %s]%s" % [skill_name, ", ".join(PackedStringArray(activated)), ref_suffix]
			return "[get_skill: %s]%s" % [skill_name, ref_suffix]
		"minerva_spawn_worker":
			return "[spawn_worker: %s]%s" % [str(result.get("worker_id", "?")), ref_suffix]
		"minerva_check_worker":
			return "[check_worker: status=%s rounds=%s]%s" % [str(result.get("status", "?")), str(result.get("rounds_used", "?")), ref_suffix]

	if result.get("error", null) != null:
		return "[%s error]%s" % [tool_name, ref_suffix]

	var keys := result.keys()
	keys.sort()
	var preview := PackedStringArray()
	for key in keys:
		if preview.size() >= 3:
			break
		var value = result.get(key)
		if value is Array:
			preview.append("%s=%d items" % [str(key), value.size()])
		elif value is Dictionary:
			preview.append("%s=%d keys" % [str(key), value.size()])
		else:
			preview.append("%s=%s" % [str(key), str(value).left(40)])
	return "[%s: %s]%s" % [tool_name, ", ".join(preview), ref_suffix]


func _store_tool_artifact(history: ChatHistory, tool_name: String, tool_args: Dictionary, filtered_result_str: String, tool_id: String) -> String:
	var content_parts := PackedStringArray()
	content_parts.append("## Tool: %s" % tool_name)
	content_parts.append("### Call ID\n%s" % tool_id)
	content_parts.append("### Arguments\n```json\n%s\n```" % JSON.stringify(tool_args, "  "))
	content_parts.append("### Result\n```json\n%s\n```" % filtered_result_str)
	var title := "Tool Artifact: %s" % tool_name
	return _upsert_agent_note(history, "", title, "\n\n".join(content_parts), false)


func _create_agent_context_summary_provider(provider_spec: Dictionary, settings: Dictionary) -> Dictionary:
	var kind := str(provider_spec.get("kind", ""))
	var provider: BaseProvider = null
	var provider_label := ""

	match kind:
		"builtin", "dynamic":
			var model_id := int(provider_spec.get("model_id", -1))
			if model_id == SingletonObject.API_MODEL_PROVIDERS.HUMAN:
				return {"provider": null, "error": "human_provider_not_supported", "provider_label": "human"}
			if kind == "dynamic":
				provider = SingletonObject.create_dynamic_provider(model_id)
			elif SingletonObject.API_MODEL_PROVIDER_SCRIPTS.has(model_id):
				provider = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[model_id].new()
			provider_label = str(model_id)
		"core_action":
			var service_client_id := str(provider_spec.get("service_client_id", ""))
			var action_name := str(provider_spec.get("action_name", ""))
			var matched_service: Service = null
			var matched_action: Action = null
			for service in Core.services:
				if service.client_id != service_client_id:
					continue
				matched_service = service
				for action in service.actions:
					if action.name == action_name:
						matched_action = action
						break
				if matched_action:
					break
			if matched_service and matched_action:
				provider = CoreProvider.new(matched_service, matched_action)
				provider_label = "%s:%s" % [service_client_id, action_name]
			else:
				return {
					"provider": null,
					"error": "core_action_not_found:%s:%s" % [service_client_id, action_name],
					"provider_label": "%s:%s" % [service_client_id, action_name],
				}
		_:
			return {"provider": null, "error": "invalid_provider_spec", "provider_label": ""}

	if not provider:
		return {"provider": null, "error": "provider_creation_failed", "provider_label": provider_label}

	if ToolMemoryManager._provider_has_property(provider, "system_prompt"):
		provider.system_prompt = str(settings.get("system_prompt", ""))
	if ToolMemoryManager._provider_has_property(provider, "reasoning_effort"):
		provider.reasoning_effort = str(settings.get("reasoning_effort", ""))
	if provider.supports_num_ctx and int(settings.get("context_size", 0)) > 0:
		provider.default_context = int(settings.get("context_size", 0))
	provider.request_timeout = float(settings.get("summary_timeout", 30.0))
	return {"provider": provider, "error": "", "provider_label": provider.model_name}


func _call_agent_context_summary_provider(provider_spec: Dictionary, settings: Dictionary, prompt_text: String) -> Dictionary:
	var provider_result := _create_agent_context_summary_provider(provider_spec, settings)
	var provider: BaseProvider = provider_result.get("provider", null)
	if not provider:
		return {
			"ok": false,
			"text": "",
			"error": str(provider_result.get("error", "provider_creation_failed")),
			"provider_label": str(provider_result.get("provider_label", "")),
		}

	add_child(provider)

	var user_item := ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.USER, prompt_text)
	user_item.provider = provider
	var prompt: Array[Variant] = []
	var formatted = provider.Format(user_item)
	if formatted != null:
		prompt.append(formatted)

	var additional_params: Dictionary = {}
	if provider.supports_temperature:
		additional_params["temperature"] = float(settings.get("temperature", 0.2))

	var response: BotResponse = await provider.generate_content(prompt, additional_params)
	provider.queue_free()
	if not response:
		return {"ok": false, "text": "", "error": "no_response", "provider_label": provider.model_name}
	if not response.error.is_empty():
		return {"ok": false, "text": "", "error": response.error, "provider_label": provider.model_name}
	var response_text := response.text.strip_edges()
	if response_text.is_empty():
		return {"ok": false, "text": "", "error": "empty_response_text", "provider_label": provider.model_name}
	return {"ok": true, "text": response_text, "error": "", "provider_label": provider.model_name}



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


## Compact a chat history by summarizing older messages and keeping recent ones.
## Works for both agent mode and regular chats. Returns true if compaction occurred.
## Tries LLM summarization first if a provider is available, falls back to naive.
func compact_chat(history: ChatHistory, keep_recent: int = AGENT_KEEP_RECENT_MESSAGES) -> bool:
	var item_count = history.HistoryItemList.size()
	if item_count <= keep_recent + 1:  # +1 for potential system prompt
		return false  # Not enough messages to compact

	# Find where to split: keep system prompt (if any) + last N messages
	var has_system_prompt = not history.HistoryItemList.is_empty() and \
		history.HistoryItemList[0].Role == ChatHistoryItem.ChatRole.SYSTEM

	var summarize_start = 1 if has_system_prompt else 0
	var summarize_end = item_count - keep_recent

	# Adjust summarize_end to avoid splitting tool_calls from their tool_results.
	# If a kept assistant message references tool_call IDs whose TOOL results are
	# in the compacted portion, move the boundary back to include them.
	var adjusted := true
	while adjusted:
		adjusted = false
		# Collect all tool_call IDs referenced by kept assistant messages
		var needed_call_ids: Dictionary = {}  # call_id -> true
		for i in range(summarize_end, item_count):
			var item = history.HistoryItemList[i]
			if (item.Role == ChatHistoryItem.ChatRole.MODEL or item.Role == ChatHistoryItem.ChatRole.ASSISTANT) and item.IsToolCall:
				for tc in item.ToolCalls:
					var cid: String = tc.get("id", "")
					if not cid.is_empty():
						needed_call_ids[cid] = true
		# Check if any TOOL results for those IDs are in the compacted portion
		if not needed_call_ids.is_empty():
			for i in range(summarize_start, summarize_end):
				var item = history.HistoryItemList[i]
				if item.Role == ChatHistoryItem.ChatRole.TOOL and needed_call_ids.has(item.ToolCallId):
					# This tool_result would be compacted but its tool_call is kept — move boundary
					summarize_end = i
					adjusted = true
					break

	if summarize_end <= summarize_start:
		return false  # Nothing to summarize

	# Build conversation text for LLM summarization and naive fallback
	var conversation_text: PackedStringArray = []
	var summary_parts: PackedStringArray = []
	var tool_calls_count := 0
	var user_messages_count := 0
	var assistant_messages_count := 0

	for i in range(summarize_start, summarize_end):
		var item = history.HistoryItemList[i]
		match item.Role:
			ChatHistoryItem.ChatRole.USER:
				user_messages_count += 1
				conversation_text.append("User: %s" % item.Message.substr(0, 1000))
				var excerpt = item.Message.substr(0, 200)
				if item.Message.length() > 200:
					excerpt += "..."
				summary_parts.append("User: %s" % excerpt)
			ChatHistoryItem.ChatRole.MODEL, ChatHistoryItem.ChatRole.ASSISTANT:
				assistant_messages_count += 1
				conversation_text.append("Assistant: %s" % item.Message.substr(0, 1000))
				if item.IsToolCall:
					tool_calls_count += item.ToolCalls.size()
					for tc in item.ToolCalls:
						summary_parts.append("Called tool: %s" % tc.get("name", "unknown"))
						conversation_text.append("  [Tool call: %s]" % tc.get("name", "unknown"))
			ChatHistoryItem.ChatRole.TOOL:
				summary_parts.append("Tool result received: %s" % item.ToolName)
				conversation_text.append("Tool result (%s): %s" % [item.ToolName, item.Message.substr(0, 500)])

	# Try LLM summarization, fall back to naive
	var summary_text := await _try_llm_summarize(conversation_text, summarize_end - summarize_start)
	if summary_text.is_empty():
		# Naive fallback
		summary_text = """### Conversation Summary ###
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

	# Store originals in Ledger before discarding
	var ledger_entry: LedgerEntry = null
	if SingletonObject.ledger_manager:
		ledger_entry = LedgerEntry.new()
		ledger_entry.chat_id = history.HistoryId
		ledger_entry.chat_name = history.HistoryName
		ledger_entry.timestamp = Time.get_datetime_string_from_system(false)
		ledger_entry.message_range = "messages %d-%d" % [summarize_start + 1, summarize_end]
		ledger_entry.summary_text = summary_text
		for i in range(summarize_start, summarize_end):
			var item = history.HistoryItemList[i]
			ledger_entry.original_messages.append({
				"role": item.Role,
				"message": item.Message.substr(0, 4000),
				"is_tool_call": item.IsToolCall,
				"tool_name": item.ToolName,
			})
		SingletonObject.ledger_manager.add_entry(ledger_entry)

	# Inject summary as reference information on the first USER message in kept history,
	# using the same InjectedNotes pattern as note injection to avoid user-user turns.
	var ledger_ref := ""
	if ledger_entry:
		ledger_ref = "\nOriginals archived: [Ledger:%s]" % ledger_entry.id
	var injection_text: String = summary_text + ledger_ref

	# Rebuild history: [system_prompt?] + [recent messages with summary injected]
	var new_history: Array[ChatHistoryItem] = []
	if has_system_prompt:
		new_history.append(history.HistoryItemList[0])
	var injected := false
	for i in range(summarize_end, item_count):
		var item = history.HistoryItemList[i]
		if not injected and item.Role == ChatHistoryItem.ChatRole.USER:
			item.InjectedNotes.append(injection_text)
			injected = true
		new_history.append(item)
	# If no USER message found in kept history, create one to carry the summary
	if not injected:
		var summary_item = ChatHistoryItem.new()
		summary_item.Role = ChatHistoryItem.ChatRole.USER
		summary_item.Message = ""
		summary_item.InjectedNotes.append(injection_text)
		summary_item.provider = history.provider
		new_history.insert(1 if has_system_prompt else 0, summary_item)

	history.HistoryItemList = new_history

	var compacted_count = summarize_end - summarize_start
	print("[Compact] Compacted %d messages into 1. New history size: %d%s" % [
		compacted_count, new_history.size(),
		" (Ledger: %s)" % ledger_entry.id if ledger_entry else ""
	])
	SingletonObject.create_toast_notification(
		"Compacted %d messages" % compacted_count,
		ToastNotification.Type.SUCCESS
	)
	return true


## Legacy wrapper: calls compact_chat for agent mode.
func summarize_agent_history(history: ChatHistory) -> void:
	await compact_chat(history)


## Attempt LLM-powered summarization. Returns empty string on failure (triggers naive fallback).
func _try_llm_summarize(conversation_parts: PackedStringArray, msg_count: int) -> String:
	# Use the current chat's provider if available
	if SingletonObject.ChatList.is_empty():
		return ""
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	if not history.provider or not is_instance_valid(history.provider):
		return ""

	var result := await _summarize_conversation_with_provider(
		history.provider, conversation_parts, msg_count, history.HistoryId)

	if not result.get("ok", false):
		print("[Compact] LLM summarization failed (%s), falling back to naive" % str(result.get("error", "")))
		return ""

	var summary_text := str(result.get("text", ""))
	print("[Compact] LLM summarization succeeded (%d chars)" % summary_text.length())
	return "### Conversation Summary (LLM) ###\n%s\n### End Summary ###" % summary_text


## Shared summarization core — ONE generate_content call over a prepared
## transcript. Extracted from _try_llm_summarize (compact_chat path) so the
## summarize-to-note flow (chat-passthrough W6) reuses the exact same engine
## with a different provider instead of duplicating a parallel path.
## Returns {ok: bool, text: String, error: String}.
func _summarize_conversation_with_provider(provider: BaseProvider, conversation_parts: PackedStringArray, msg_count: int, cost_history_id: String = "", prompt_override: String = "") -> Dictionary:
	var transcript := "\n".join(conversation_parts)
	var prompt_text: String
	if prompt_override.is_empty():
		prompt_text = "Summarize this conversation segment of %d messages. Preserve: key decisions, facts learned, action items, important code snippets, and any unresolved questions. Be concise but complete.\n\n%s" % [msg_count, transcript]
	else:
		# User-editable prompt: append the transcript instead of %-formatting it,
		# so a prompt without %d/%s placeholders can't break the call.
		prompt_text = "%s\n\n%s" % [prompt_override, transcript]

	# Build a minimal prompt for the provider
	var prompt_item = ChatHistoryItem.new()
	prompt_item.Role = ChatHistoryItem.ChatRole.USER
	prompt_item.Message = prompt_text
	prompt_item.provider = provider

	var prompt_list: Array[Variant] = []
	var formatted = provider.Format(prompt_item)
	if formatted:
		prompt_list.append(formatted)

	if prompt_list.is_empty():
		return {"ok": false, "text": "", "error": "prompt_format_failed"}

	# Disable tools for this request — summarization is a plain completion.
	# (Tools are re-set on the next regular chat call.)
	if provider.has_method("set_tools"):
		var empty_tools: Array[Dictionary] = []
		provider.set_tools(empty_tools)

	var bot_response = await provider.generate_content(prompt_list)

	if not bot_response:
		return {"ok": false, "text": "", "error": "no_response"}
	if not bot_response.error.is_empty():
		return {"ok": false, "text": "", "error": bot_response.error}
	if bot_response.text.is_empty():
		return {"ok": false, "text": "", "error": "empty_response_text"}

	# Record cost against the originating chat
	if SingletonObject.cost_tracker and not cost_history_id.is_empty():
		SingletonObject.cost_tracker.record_chat_cost(bot_response, cost_history_id)

	return {"ok": true, "text": bot_response.text, "error": ""}


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
	var current_history = SingletonObject.ChatList[SingletonObject.Chats.current_tab]
	var working_memory: Array = await SingletonObject.notes_container.to_prompt(current_history.provider, false, current_history.HistoryId)
	
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
	print("[ChatPane] generate_content_from_provider called, provider: %s" % history.provider.provider_name)
	var bot_response

	# Set chat_id on provider for budget enforcement
	history.provider.chat_id = history.HistoryId

	# Build request params: OpenAI sampling params (as before) plus per-chat
	# reasoning options for any provider that supports the effort picker.
	var optional_params := {}
	if history.provider.PROVIDER == SingletonObject.API_PROVIDER.OPENAI and not history.provider is OpenAIImageProviderScript:
		optional_params = {
			"temperature": history.Temperature,
			"top_p": history.TopP,
			"presence_penalty": history.PresencePenalty,
			"frequency_penalty": history.FrequencyPenalty,
		}

	# Per-chat reasoning effort → provider-native request params. Applied only
	# when the user configured reasoning for this chat (ReasoningEffort != "");
	# apply_reasoning_options is a no-op for providers without an override.
	if history.ReasoningEffort != "":
		var reasoning_enabled := history.ReasoningEffort != "off"
		var reasoning_level := history.ReasoningEffort if reasoning_enabled else "medium"
		history.provider.apply_reasoning_options(optional_params, reasoning_level, reasoning_enabled)

	# Reasoning-summary preference (ChatGPT). Duck-typed so only providers that
	# expose the field react — no provider-type coupling in ChatPane.
	if "request_reasoning_summary" in history.provider:
		history.provider.request_reasoning_summary = history.ReasoningSummary

	bot_response = await history.provider.generate_content(history_list, optional_params)

	# Record cost with chat context
	if bot_response and SingletonObject.cost_tracker:
		SingletonObject.cost_tracker.record_chat_cost(bot_response, history.HistoryId)

	print("[ChatPane] generate_content_from_provider returning bot_response (null=%s)" % (bot_response == null))
	return bot_response

# Process bot response into chat history item
func process_bot_response(bot_response, _history_provider: BaseProvider) -> ChatHistoryItem:
	var chi = ChatHistoryItem.new()

	if bot_response != null:
		chi.Id = bot_response.id
		chi.Role = ChatHistoryItem.ChatRole.MODEL
		chi.provider = _history_provider  # Use the chat's provider, not the response's — prevents format contamination across providers
		chi.Message = bot_response.text
		chi.Error = bot_response.error
		chi.Complete = bot_response.complete
		chi.OutputTokens = bot_response.completion_tokens
		if bot_response.has_reasoning():
			chi.Reasoning = bot_response.reasoning
		# Transient raw reasoning for same-model replay in the agent tool loop.
		chi.ReasoningRaw = bot_response.reasoning_raw
		if bot_response.image:
			chi.Images = ([bot_response.image] as Array[Image])

	return chi

# Update UI after receiving bot response
func _accumulate_cache_telemetry(bot_response: BotResponse, history: ChatHistory) -> void:
	if bot_response.cache_creation_tokens > 0 or bot_response.cache_read_tokens > 0:
		var telemetry := history.AgentContextTelemetry.duplicate(true)
		telemetry["cache_creation_tokens"] = int(telemetry.get("cache_creation_tokens", 0)) + bot_response.cache_creation_tokens
		telemetry["cache_read_tokens"] = int(telemetry.get("cache_read_tokens", 0)) + bot_response.cache_read_tokens
		history.AgentContextTelemetry = telemetry


## Bug 019e5bc8: when a user stops a hung chat and dispatches a new one,
## _on_audio_stop_1_pressed queue_free's the loading model_msg_node, but
## the awaiting coroutine in execute_regular_chat / execute_hcp_chat /
## worker chat keeps a stale reference. Late provider responses then
## resume the zombie coroutine, which calls update_ui_after_response with
## freed UI args → exception. Centralize the freed-node check here.
static func _are_ui_args_valid(user_history_item, user_msg_node, model_msg_node) -> bool:
	return is_instance_valid(user_history_item) \
		and is_instance_valid(user_msg_node) \
		and is_instance_valid(model_msg_node)


func update_ui_after_response(user_history_item: ChatHistoryItem, user_msg_node: Control,
							 model_msg_node: Control, chi: ChatHistoryItem,
							 bot_response, history: ChatHistory) -> void:
	if not _are_ui_args_valid(user_history_item, user_msg_node, model_msg_node):
		push_warning("[ChatPane] update_ui_after_response: late response dropped — UI node freed (bug 019e5bc8, likely stop+redispatch)")
		return
	if bot_response != null:
		# Update user message node with input tokens (prompt tokens for this turn)
		user_history_item.InputTokens = bot_response.prompt_tokens
		_accumulate_cache_telemetry(bot_response, history)
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

		# Voice mode: speak the response via TTS (if enabled in Voice Preferences)
		if chi and not chi.Message.is_empty():
			_voice_speak_response(chi.Message, user_history_item.Message, model_msg_node)
	else:
		model_msg_node.queue_free()

	for i in SingletonObject.notes_container.get_tab_count():
		SingletonObject.notes_container.disable_notes(i)

	for i in SingletonObject.drawer_notes_container.get_tab_count():
		SingletonObject.drawer_notes_container.disable_notes(i)

	SingletonObject.clear_consumed_proxies(history.HistoryId)


## Same as update_ui_after_response but WITHOUT emitting response_arrived signal.
## Used for agent mode tool chains where we only want the signal at the end.
func update_ui_after_response_no_signal(user_history_item: ChatHistoryItem, user_msg_node: Control,
							 model_msg_node: Control, chi: ChatHistoryItem,
							 bot_response, history: ChatHistory) -> void:
	if not _are_ui_args_valid(user_history_item, user_msg_node, model_msg_node):
		push_warning("[ChatPane] update_ui_after_response_no_signal: late response dropped — UI node freed (bug 019e5bc8, likely stop+redispatch)")
		return
	if bot_response != null:
		# Update user message node with input tokens (prompt tokens for this turn)
		user_history_item.InputTokens = bot_response.prompt_tokens
		_accumulate_cache_telemetry(bot_response, history)
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
	# Check if the selected model defaults to static tool mode → redirect to focused chat
	var selected_id := _provider_option_button.get_selected_id()
	if selected_id >= SingletonObject.DYNAMIC_MODEL_ID_BASE:
		var manager = SingletonObject.get_model_manager_for_id(selected_id)
		if manager and manager.get_tool_mode(selected_id) == "static":
			_on_focused_chat_pressed()
			return

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


## Open the Focused Chat popup to create a static-tool-mode chat.
func _on_focused_chat_pressed() -> void:
	if not _focused_chat_popup:
		_focused_chat_popup = FocusedChatPopup.new()
		add_child(_focused_chat_popup)
		_focused_chat_popup.focused_chat_requested.connect(_on_focused_chat_create)
	_focused_chat_popup.refresh()
	_focused_chat_popup.popup_centered()


## Create a focused chat from the popup's resolved config.
func _on_focused_chat_create(config: Dictionary) -> void:
	# Generate tab name with "Focused" prefix
	# Use same "Chat N" naming as normal chats
	var last_chat_number: int = -1
	for i in range(get_tab_count() - 1, -1, -1):
		var tab_title := get_tab_title(i)
		if tab_title == "Chat":
			last_chat_number = max(last_chat_number, 0)
		elif tab_title.begins_with("Chat"):
			var suffix = tab_title.right(-"Chat".length()).strip_edges()
			if suffix.is_valid_int():
				last_chat_number = max(last_chat_number, int(suffix))
	var tab_name := "Chat" if last_chat_number == -1 else "Chat %s" % (last_chat_number + 1)

	var provider_obj := _provider_option_button.get_selected_provider()
	if not provider_obj:
		provider_obj = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[0].new()

	var history: ChatHistory = ChatHistory.new(provider_obj)
	history.HistoryName = tab_name
	history.HistoryItemList = []
	history.SystemPromptEnabled = provider_obj.requires_default_system_prompt
	history.AgentModeEnabled = true

	# Static tool mode
	history.StaticToolMode = true
	var resolved_tools: Array[String] = []
	resolved_tools.assign(config.get("resolved_tools", []))
	history.ConfiguredTools = resolved_tools
	var skill_names: Array[String] = []
	skill_names.assign(config.get("skills", []))
	history.ConfiguredSkills = skill_names

	# Compute DisabledTools: everything NOT in ConfiguredTools + discovery tools
	var mcp = SingletonObject.get_mcp_manager()
	if mcp:
		var discovery_tools := ["minerva_tool_search", "minerva_list_skills", "minerva_get_skill"]
		var disabled: Array[String] = []
		for tool_def in mcp.get_available_tools():
			var tool_name: String = str(tool_def.name)
			if tool_name not in resolved_tools or tool_name in discovery_tools:
				disabled.append(tool_name)
		history.DisabledTools = disabled

	# Inject skill instructions into agentic system prompt
	var instructions: String = config.get("instructions", "")
	if not instructions.is_empty():
		history.AgenticSystemPrompt = instructions

	SingletonObject.ChatList.append(history)
	render_history(history)
	current_tab = get_tab_count() - 1

	if provider_obj.requires_default_system_prompt:
		add_new_system_prompt_item(provider_obj.default_system_prompt)

	if get_tab_count() > 0:
		buffer_control_chats.hide()


#region Passthrough chat (chat-passthrough W2)

## Next "Chat N" tab name, mirroring the numbering used by _on_new_chat.
func _next_chat_tab_name() -> String:
	var last_chat_number: int = -1
	for i in range(get_tab_count() - 1, -1, -1):
		var tab_title := get_tab_title(i)
		if tab_title == "Chat":
			last_chat_number = max(last_chat_number, 0)
		elif tab_title.begins_with("Chat"):
			var suffix = tab_title.right(-"Chat".length()).strip_edges()
			if suffix.is_valid_int():
				last_chat_number = max(last_chat_number, int(suffix))
	return "Chat" if last_chat_number == -1 else "Chat %s" % (last_chat_number + 1)


## Build (model only, no UI) a passthrough ChatHistory bound to a registered
## plugin chat-provider entry. Returns null when the entry can't be resolved —
## the binding is contractual, so there is NO fallback provider here.
func _build_passthrough_history(entry_key: String, display_name: String, bound_terminal_id: String = "") -> ChatHistory:
	var cpr = SingletonObject.plugin_chat_provider_registry if "plugin_chat_provider_registry" in SingletonObject else null
	if cpr == null or not cpr.has_method("get_entry"):
		push_warning("[ChatPane] start_passthrough_chat: no plugin chat-provider registry available")
		return null
	var entry: Dictionary = cpr.get_entry(entry_key)
	if entry.is_empty():
		push_warning("[ChatPane] start_passthrough_chat: entry '%s' is not registered" % entry_key)
		return null

	var PluginProviderScript = load("res://Scripts/Services/Providers/PluginProvider.gd")
	var provider_obj: BaseProvider = PluginProviderScript.new()
	provider_obj.configure_from_entry(entry)

	var history: ChatHistory = ChatHistory.new(provider_obj)
	# The chat tab carries the launch dialog's session name — same name as the
	# terminal session/tab — so the pair is recognisable across panes. Generic
	# "Chat N" numbering is the no-name fallback only.
	history.HistoryName = display_name.strip_edges() if not display_name.strip_edges().is_empty() \
			else _next_chat_tab_name()
	history.HistoryItemList = []
	history.SystemPromptEnabled = provider_obj.requires_default_system_prompt
	history.PassthroughMode = true
	history.BoundTerminalId = bound_terminal_id
	history.PassthroughName = display_name if not display_name.is_empty() \
			else str(entry.get("display_name", "Passthrough"))
	return history


## Create a new passthrough chat bound to a plugin chat-provider entry (W2 stub
## flow; W3's launch dialog drives this API). The provider chooser ends up
## showing the bound entry and locked on it; the header shows the badge.
func start_passthrough_chat(entry_key: String, display_name: String, bound_terminal_id: String = "") -> ChatHistory:
	var history := _build_passthrough_history(entry_key, display_name, bound_terminal_id)
	if history == null:
		SingletonObject.ErrorDisplay("Passthrough unavailable",
			"Provider entry '%s' is not registered — is the plugin running?" % entry_key)
		return null

	SingletonObject.ChatList.append(history)
	render_history(history)
	current_tab = get_tab_count() - 1

	if history.provider.requires_default_system_prompt:
		add_new_system_prompt_item(history.provider.default_system_prompt)

	if get_tab_count() > 0:
		buffer_control_chats.hide()

	# Chooser must show + lock on the bound entry (tab-change glue also covers
	# later switches back to this tab).
	_update_passthrough_chooser_lock(current_tab)
	return history


## Lock/unlock the provider chooser based on whether the given tab is a
## passthrough chat. Called on tab changes and right after passthrough creation.
func _update_passthrough_chooser_lock(tab: int) -> void:
	if _provider_option_button == null:
		return
	if tab < 0 or tab >= SingletonObject.ChatList.size():
		if _provider_option_button.is_locked():
			_provider_option_button.set_locked(false)
		return
	var history = SingletonObject.ChatList[tab]
	if history.PassthroughMode:
		var entry_key := ""
		if history.provider != null and "entry_key" in history.provider:
			entry_key = str(history.provider.entry_key)
		_provider_option_button.lock_to_entry(entry_key, history.PassthroughName,
			"Passthrough chat — provider is fixed for this chat's life")
	elif _provider_option_button.is_locked():
		_provider_option_button.set_locked(false)


## Full launch path behind the W3 dialog: create/bind the chat (W2 core), store
## the relaunch affordance fields (T3 contract: restart = stored command + cwd
## into a FRESH session), and wire agent-exit surfacing at bind time.
func launch_passthrough_chat(entry_key: String, display_name: String,
		terminal_id: String, command: String = "", cwd: String = "") -> ChatHistory:
	var history := start_passthrough_chat(entry_key, display_name, terminal_id)
	if history == null:
		return null
	history.PassthroughCommand = command
	history.PassthroughCwd = cwd
	_wire_passthrough_exit(history)
	return history


## Wire agent-exit surfacing for a bound passthrough chat. The signal lives on
## the SESSION object (TerminalSession.shell_exited), so this survives
## view-less/background terminals — no TerminalNew tab needed. De-duped via
## _passthrough_exit_seen: one message per (chat, session) exit.
func _wire_passthrough_exit(history: ChatHistory) -> void:
	if history == null or history.BoundTerminalId.is_empty():
		return
	var registry = SingletonObject.get_terminal_session_registry()
	if registry == null or not registry.has_session(history.BoundTerminalId):
		return
	var session = registry.get_session(history.BoundTerminalId)
	# Already dead at bind time (raced an instant exit) → surface immediately.
	if session.shell_exit_code != null:
		_append_passthrough_exit_message(history, str(session.terminal_id),
			int(session.shell_exit_code))
		return
	var tid := str(session.terminal_id)
	session.shell_exited.connect(func(exit_code: int):
		_append_passthrough_exit_message(history, tid, exit_code))


## Surface "the terminal agent died" in the bound chat, once per
## (chat, session) pair, using the program-message idiom (transient label —
## not saved with the project, same as provider-change notices).
func _append_passthrough_exit_message(history: ChatHistory, terminal_id: String,
		exit_code: int) -> void:
	var dedupe_key := "%s|%s" % [history.HistoryId, terminal_id]
	if _passthrough_exit_seen.get(dedupe_key, false):
		return
	_passthrough_exit_seen[dedupe_key] = true
	if history.VBox != null and is_instance_valid(history.VBox):
		history.VBox.add_program_message(
			"terminal agent exited (code %d) — press ⇅ to relaunch" % exit_code)


## Top-bar "new passthrough chat" button handler (chat-passthrough W3): opens
## the launch dialog (new background session OR bind-to-existing terminal).
func _on_passthrough_chat_pressed() -> void:
	if _passthrough_launch_dialog == null:
		_passthrough_launch_dialog = PassthroughLaunchDialogScript.new()
		_passthrough_launch_dialog.chat_starter = launch_passthrough_chat
		add_child(_passthrough_launch_dialog)
	_passthrough_launch_dialog.popup_launch()


# --- Summarize to note (chat-passthrough W6) --------------------------------
# Passthrough chats have NO LLM in their transport (DCR comment #479). The
# summarize-to-note button is THE one deliberate token-spend gesture: a single
# explicit LLM call that distills the transcript into a note linked to the
# chat (notes-as-context is the transfer mechanism into other chats). Nothing
# below may run without that explicit gesture.

## Built-in default distill model — the fallback when the "core" summarization
## preference is unset. NOT the chat's provider; passthrough providers are
## terminal transports, not LLMs.
const PASSTHROUGH_DISTILL_MODEL := PluginSettingsStore.DEFAULT_SUMMARIZATION_MODEL

## Test seam / future per-user override: when set, summarize_passthrough_to_note
## uses this provider instead of constructing the fixed distill model.
var distill_provider_override: BaseProvider = null

## Double-spend guard: history_id -> true while a summarize is in flight.
var _summarize_in_flight: Dictionary = {}


## Is a summarize currently in flight for this chat? (UI busy-state hook.)
func is_summarize_in_flight(history) -> bool:
	return history != null and _summarize_in_flight.get(history.HistoryId, false)


## Build the attributed transcript for a passthrough chat: "You:" for the user,
## "<PassthroughName>:" for the other side. Skips empty messages. Partial
## mid-session transcripts are fine — we summarize whatever exists.
func _build_passthrough_transcript(history) -> PackedStringArray:
	var parts: PackedStringArray = []
	var other_name: String = history.PassthroughName if not history.PassthroughName.is_empty() else "Assistant"
	for item in history.HistoryItemList:
		if item.Message.strip_edges().is_empty():
			continue
		match item.Role:
			ChatHistoryItem.ChatRole.USER:
				parts.append("You: %s" % item.Message)
			ChatHistoryItem.ChatRole.MODEL, ChatHistoryItem.ChatRole.ASSISTANT:
				parts.append("%s: %s" % [other_name, item.Message])
	return parts


## Resolved summarization model: the "core" preference, else the built-in default.
func _distill_model() -> String:
	var store = SingletonObject.plugin_settings_store
	if store != null:
		var m = store.get_value("core", "model")
		if m != null and str(m) != "":
			return str(m)
	return PASSTHROUGH_DISTILL_MODEL


## Resolved summarization provider key: the "core" preference, else chatgpt.
func _distill_provider_key() -> String:
	var store = SingletonObject.plugin_settings_store
	if store != null:
		var p = store.get_value("core", "model_provider")
		if p != null and str(p) != "":
			return str(p)
	return "chatgpt"


## Resolved summarization prompt: the "core" preference, else the built-in default.
func _summarization_prompt() -> String:
	var store = SingletonObject.plugin_settings_store
	if store != null:
		var p = store.get_value("core", "prompt")
		if p != null and str(p) != "":
			return str(p)
	return PluginSettingsStore.DEFAULT_SUMMARIZATION_PROMPT


## Construct the distill provider for the configured (provider, model) via the
## brokered catalog. On a catalog miss (e.g. the model isn't discovered yet) it
## falls back to the ChatGPT factory with the bare model name. Credentials are
## NOT touched here — generate_content surfaces a clear "not connected" error.
func _create_passthrough_distill_provider() -> BaseProvider:
	var model_name := _distill_model()
	var provider := SingletonObject.create_provider_for(_distill_provider_key(), model_name)
	if provider != null:
		return provider
	return ChatGPTProvider.create_from_config({
		"model_name": model_name,
		"display_name": "%s (distill)" % model_name,
		"short_name": "CG",
	})


## Surface a summarize failure. ErrorDisplay when the popup exists (normal app),
## error toast otherwise (headless — create_toast_notification logs and bails).
func _surface_summarize_error(message: String) -> void:
	if SingletonObject.errorPopup != null:
		SingletonObject.ErrorDisplay("Summarize failed", message)
	else:
		SingletonObject.create_toast_notification("Summarize failed: %s" % message, ToastNotification.Type.ERROR)


## W6 engine: distill a passthrough chat's transcript into a note linked to
## this chat, via ONE explicit LLM call on the fixed cheap distill model.
## Reuses the compact_chat summarization core (_summarize_conversation_with_provider).
## provider_override is the injectable seam for tests.
## Returns {ok: bool, note_id: String, error: String, message: String}.
func summarize_passthrough_to_note(history, provider_override: BaseProvider = null) -> Dictionary:
	if history == null:
		return {"ok": false, "note_id": "", "error": "no_history", "message": ""}

	# Busy guard — no double-spend, even if a second press sneaks through.
	if _summarize_in_flight.get(history.HistoryId, false):
		return {"ok": false, "note_id": "", "error": "busy",
			"message": "A summarize is already in flight for this chat."}

	# Empty transcript → friendly no-op, NO LLM call.
	var transcript := _build_passthrough_transcript(history)
	if transcript.is_empty():
		SingletonObject.create_toast_notification("Nothing to summarize yet — the chat is empty.")
		return {"ok": false, "note_id": "", "error": "empty_transcript",
			"message": "Nothing to summarize yet — the chat is empty."}

	var provider: BaseProvider = provider_override if provider_override != null else distill_provider_override
	var owns_provider := false
	if provider == null:
		provider = _create_passthrough_distill_provider()
		owns_provider = true
	if provider == null:
		_surface_summarize_error("Could not construct the distill model (%s)." % _distill_model())
		return {"ok": false, "note_id": "", "error": "provider_unavailable", "message": ""}

	_summarize_in_flight[history.HistoryId] = true
	if owns_provider:
		add_child(provider)  # providers need the tree for timers/auth

	var prompt_used := _summarization_prompt()
	var result: Dictionary = await _summarize_conversation_with_provider(
		provider, transcript, transcript.size(), history.HistoryId, prompt_used)

	if owns_provider:
		provider.queue_free()
	_summarize_in_flight.erase(history.HistoryId)

	if not result.get("ok", false):
		var err := str(result.get("error", "unknown error"))
		_surface_summarize_error(err)
		return {"ok": false, "note_id": "", "error": err, "message": ""}

	# Note creation + linking: same underlying path as minerva_create_note +
	# minerva_link_note_to_chat (user-visible notes pane = the notes-as-context
	# bus into other chats; the agent-notes tab is per-chat hidden context, so
	# _upsert_agent_note is the wrong home for this).
	var distilled := str(result.get("text", ""))
	# Stamp provenance so the note records which model and prompt produced it.
	var prompt_label := "default" if prompt_used == PluginSettingsStore.DEFAULT_SUMMARIZATION_PROMPT else "custom"
	var note_body := "%s\n\n---\n_Summary model: %s/%s · prompt: %s_" % [distilled, _distill_provider_key(), _distill_model(), prompt_label]
	var timestamp := Time.get_datetime_string_from_system(false, true)
	var note_title := "Passthrough summary: %s — %s" % [history.PassthroughName, timestamp]
	var note: Note = Note.create_text_note(note_title, note_body)
	note.link_to_chat(history.HistoryId)
	if SingletonObject.notes_container != null:
		SingletonObject.notes_container.add_note(note)
		if SingletonObject.main_ui and SingletonObject.main_ui.has_method("set_notes_pane_visible"):
			SingletonObject.main_ui.set_notes_pane_visible(true)

	SingletonObject.create_toast_notification("Summarized to note: %s" % note_title,
		ToastNotification.Type.SUCCESS)
	return {"ok": true, "note_id": note.uuid, "error": "", "message": note_title}

#endregion


func _connect_mcp_signals() -> void:
	var mcp = SingletonObject.get_mcp_manager()
	if mcp and not mcp.server_connected.is_connected(_on_mcp_server_connected):
		mcp.server_connected.connect(_on_mcp_server_connected)


## Recompute DisabledTools for focused chats after MCP (re)connects.
## Tool registry may have changed between sessions or after reconnection.
func _on_mcp_server_connected(server_name: String) -> void:
	if server_name != "minerva":
		return
	var mcp = SingletonObject.get_mcp_manager()
	if not mcp:
		return
	var discovery_tools := ["minerva_tool_search", "minerva_list_skills", "minerva_get_skill"]
	for history in SingletonObject.ChatList:
		if not history.StaticToolMode or history.ConfiguredTools.is_empty():
			continue
		var disabled: Array[String] = []
		for tool_def in mcp.get_available_tools():
			var tool_name: String = str(tool_def.name)
			if tool_name not in history.ConfiguredTools or tool_name in discovery_tools:
				disabled.append(tool_name)
		history.DisabledTools = disabled


## Guarantee there is a chat the user can actually SEE before a send writes to
## `ChatList[current_tab]`.
##
## THE BUG THIS FIXES: this used to ask only "is ChatList empty?". Once the
## strip could be filtered, a non-empty list stopped meaning there was a chat on
## screen — so typing into an empty group delivered the message to whichever
## chat happened to be current, silently, in a group the user was not looking
## at. They heard the completion and saw nothing appear. Writing into the wrong
## conversation is worse than showing nothing, which is why this is decided here
## rather than at the seven call sites.
func ensure_chat_open() -> void:
	if SingletonObject.ChatList.is_empty():
		_create_visible_chat()
		return

	# Prefer an existing VISIBLE chat, moving off a hidden current tab if the
	# filter left one selected.
	var first_visible := -1
	for i in range(get_tab_count()):
		if not is_tab_hidden(i):
			first_visible = i
			break
	if first_visible >= 0:
		if current_tab < 0 or current_tab >= get_tab_count() or is_tab_hidden(current_tab):
			current_tab = first_visible
		return

	# Nothing is visible: the active view is an empty group (or everything is
	# archived/deleted). Make a chat the user can see rather than typing into the
	# dark.
	_create_visible_chat()


## Create a chat and make sure the active view can actually show it.
##
## The Deleted view cannot host one — a new chat is never deleted — so creating
## without leaving it produces a chat that is invisible the moment it exists.
## Every other view can: a fresh chat is neither archived nor grouped elsewhere,
## so it shows under All, Ungrouped, or the selected group unaided.
func _create_visible_chat() -> void:
	if _active_group_id == ChatGroupRegistry.VIEW_DELETED:
		set_active_group(ChatGroupRegistry.VIEW_ALL)
	_on_new_chat()
	_apply_tab_filters()

## Generates the full turn prompt using the history of the active chat and the selected provider.
## `append_item` will be present in the prompt, but WON'T be added to chat history inside this function.[br]
## If [param refresh_detached] is `true`, [method NotesContainer.to_prompt] will regenerate the editor notes.[br]
## If there's no active history [parameter provider_fallback] can be used to determine which provider to use.[br]
## Check `History.to_prompt` for explanation on `predicate`.
func create_prompt(append_item: ChatHistoryItem = null, refresh_detached: = true, provider_fallback: BaseProvider = null, predicate: Callable = Callable(), history_override: ChatHistory = null) -> Array[Variant]:

	# if we don't have any chats history_list will be empty
	var history_list: Array[Variant] = []
	var provider: BaseProvider = provider_fallback
	var history: ChatHistory = null

	if history_override:
		# Use explicitly passed history — critical for agent mode tool call loops
		# where current_tab may point to a different chat (e.g., sub-agent)
		history = history_override
		if not provider:
			provider = history.provider
	elif not SingletonObject.ChatList.is_empty():
		history = SingletonObject.ChatList[current_tab]
		if not provider:
			provider = history.provider

	if not provider:
		return []

	if history:
		# Handle agentic system prompt: use it instead of regular system prompt when agent mode is on
		var effective_system_prompt: String = ""
		if history.AgentModeEnabled:
			# In agent mode: use custom agentic prompt if enabled, or fall back to dynamically built agent prompt
			if history.AgenticSystemPromptEnabled:
				if not history.AgenticSystemPrompt.is_empty():
					effective_system_prompt = history.AgenticSystemPrompt
				else:
					effective_system_prompt = _build_agent_system_prompt(history)
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

		# Ensure tool memory manager callables are configured before prompt projection
		_configure_tool_memory_manager(history)

		# Build history list, handling system prompt based on provider support
		history_list = _build_history_list_with_system_prompt(history, provider, effective_system_prompt, predicate, history.AgentModeEnabled)

	# any notes container `to_prompt` will go over both standard and drawer notes
	var history_id_for_filter: String = history.HistoryId if history else ""
	var working_memory: Array = await SingletonObject.notes_container.to_prompt(provider, refresh_detached, history_id_for_filter)

	# Immediately consume proxies after collection to prevent leaking into
	# other chats that may run during this turn (e.g., sub-agents).
	# The notes are already captured in working_memory for this turn.
	if history and not working_memory.is_empty():
		SingletonObject.clear_consumed_proxies(history.HistoryId)

	# If we don't have a new item but we have active notes, we still need new item to add the notes in there
	if not append_item and working_memory:
		append_item = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.USER)

	# append the working memory + any cited annotation refs (C7) resolved to their
	# current re-anchored code + intent (DCR 019e9f602391 P4).
	if append_item:
		append_item.InjectedNotes = working_memory + _resolve_cited_refs(append_item)
		# also append the new item since it's not in the history yet
		var item = provider.Format(append_item)
		if item: history_list.append(item)

	return history_list


## Resolve citeable annotation refs ("C7") cited in the message to plain-text
## reference notes (current code + intent + status). DCR 019e9f602391 P4.
func _resolve_cited_refs(item: ChatHistoryItem) -> Array:
	if item == null or not SingletonObject.project_identity:
		return []
	return AnnotationRefResolver.resolve_for_chat(str(item.Message), SingletonObject.project_identity.project_id)


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

	if not history.AgentContextTelemetry.is_empty():
		metadata["agent_context"] = history.AgentContextTelemetry

	if not history.AcquiredKnowledge.is_empty():
		metadata["knowledge_items"] = history.AcquiredKnowledge.size()

	if not history.AgentToolMemoryState.is_empty():
		metadata["tool_memory_state"] = history.AgentToolMemoryState

	return metadata


## Build history list with proper handling of system prompt based on provider capabilities.
## If provider doesn't support system prompts, prepends system prompt to first user message.
func _build_history_list_with_system_prompt(history: ChatHistory, provider: BaseProvider, system_prompt: String, predicate: Callable, agent_mode: bool = false) -> Array[Variant]:
	var history_list: Array[Variant] = []
	var system_prompt_prepended := false
	var projected_history := history.tool_memory_manager.project(history, provider)

	for chat: ChatHistoryItem in projected_history:
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
		if agent_mode or provider.supports_system_prompt:
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

	# Clean up all items after the user message (orphaned tool-call chains from previous responses)
	var items_to_remove: Array[ChatHistoryItem] = []
	for i in range(index + 1, history.HistoryItemList.size()):
		items_to_remove.append(history.HistoryItemList[i])
	for item in items_to_remove:
		if is_instance_valid(item.rendered_node):
			item.rendered_node.queue_free()
		history.HistoryItemList.erase(item)

	# Create a fresh response item
	var existing_response = ChatHistoryItem.new()
	existing_response.Role = ChatHistoryItem.ChatRole.MODEL
	existing_response.provider = history.provider
	history.HistoryItemList.append(existing_response)
	history.VBox.add_history_item(existing_response)

	# We format items until we get to the user response
	var predicate = func(item: ChatHistoryItem) -> Array:
		return [
			history.HistoryItemList.find(item) < index,
			history.HistoryItemList.find(item) < index,
		]

	# Setup agent mode tools if enabled for this chat (same as execute_regular_chat)
	print("[regenerate] Checking agent mode: AgentModeEnabled=%s, has_set_tools=%s" % [history.AgentModeEnabled, history.provider.has_method("set_tools")])
	if history.AgentModeEnabled and history.provider.has_method("set_tools"):
		var mcp = SingletonObject.get_mcp_manager()
		var filtered_tools: Array[Dictionary] = mcp.get_tools_for_chat(history)
		print("[regenerate] Setting up tools: %d after filtering" % [filtered_tools.size()])
		history.provider.set_tools(filtered_tools)
		print("[regenerate] Provider tools_enabled: %s" % history.provider.tools_enabled)

	var history_list = await create_prompt(chi, false, null, predicate)

	# Track this request so the stop button works
	history.is_request_active = true
	_update_stop_button()

	# Ensure rendered_node exists (may have been freed if message was deleted)
	if not is_instance_valid(existing_response.rendered_node):
		existing_response.rendered_node = history.VBox.add_history_item(existing_response)
	if existing_response.rendered_node:
		existing_response.rendered_node.loading = true

	var bot_response = await history.provider.generate_content(history_list)

	# if there was an error with the request
	if not bot_response:
		history.is_request_active = false
		_update_stop_button()
		return

	if bot_response.id: existing_response.Id = bot_response.id
	existing_response.Role = ChatHistoryItem.ChatRole.MODEL
	existing_response.Message = bot_response.text
	existing_response.Error = bot_response.error
	existing_response.provider = history.provider
	existing_response.Complete = bot_response.complete
	existing_response.OutputTokens = bot_response.completion_tokens
	if bot_response.image:
		existing_response.Images = ([bot_response.image] as Array[Image])

	# Handle tool calls if agent mode is enabled and response has tool calls
	print("[regenerate] Tool call check: AgentModeEnabled=%s, has_tool_calls=%s" % [
		history.AgentModeEnabled,
		bot_response.has_tool_calls() if bot_response else false
	])
	if history.AgentModeEnabled and bot_response and bot_response.has_tool_calls():
		print("[regenerate] Entering tool call handling branch")
		existing_response.IsToolCall = true
		existing_response.ToolCalls = bot_response.tool_calls

		if not is_instance_valid(existing_response.rendered_node):
			existing_response.rendered_node = history.VBox.add_history_item(existing_response)
		if is_instance_valid(existing_response.rendered_node):
			existing_response.rendered_node.render()
			existing_response.rendered_node.loading = false

		# Reuse the same tool call handling as execute_regular_chat
		await handle_tool_calls(history, bot_response.tool_calls, 0, existing_response, chi)
	else:
		if not is_instance_valid(existing_response.rendered_node):
			existing_response.rendered_node = history.VBox.add_history_item(existing_response)
		if is_instance_valid(existing_response.rendered_node):
			existing_response.rendered_node.render()
			existing_response.rendered_node.loading = false

		# Emit response_arrived signal to trigger notification sound
		chi.response_arrived.emit(existing_response)

		for i in SingletonObject.notes_container.get_tab_count():
			SingletonObject.notes_container.disable_notes(i)

		for i in SingletonObject.drawer_notes_container.get_tab_count():
			SingletonObject.drawer_notes_container.disable_notes(i)

		SingletonObject.clear_consumed_proxies(history.HistoryId)

	history.is_request_active = false
	_update_stop_button()
	_update_compact_button()


func _on_chat_pressed():
	_on_send_message_button_item_selected(0)


## Public entry point for triggering a chat submit from an external source
## (e.g. Stream Deck plugin). `mode` mirrors SendMessageButton indices:
## 0 = regular, 1 = parallel, 2 = sequential.
func submit_chat(mode: int = 0) -> void:
	_on_send_message_button_item_selected(mode)


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

	match index:
		0:
			execute_regular_chat(filteredInput)
		1:
			history.is_request_active = true
			_update_stop_button()
			execute_parallel_chat(filteredInput)
		2:
			history.is_request_active = true
			_update_stop_button()
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
	
	var history_list: = await create_prompt(user_history_item, true, null, Callable(), history)

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

	# Bug 019e5bc8: stop+redispatch can free model_msg_node / user_msg_node
	# during the await above. Guard before touching them directly below.
	if not _are_ui_args_valid(user_history_item, user_msg_node, model_msg_node):
		push_warning("[ChatPane] execute_hcp_chat: late response dropped — UI node freed (bug 019e5bc8)")
		return

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
	print("[ChatPane] execute_regular_chat called, text length: %d" % text.length())
	var _history = SingletonObject.ChatList[current_tab]
	print("[ChatPane] current_tab=%d, AgentModeEnabled=%s, provider=%s" % [current_tab, _history.AgentModeEnabled, _history.provider.provider_name if _history.provider else "null"])

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

	# Track this request so the stop button works
	# (callers like AgentSpawner, TriggerManager, and MCP tools bypass the UI button handler)
	history.is_request_active = true
	_update_stop_button()
	var last_msg = history.HistoryItemList.back() if not history.HistoryItemList.is_empty() else null

	# Reset termination tracking for this new turn
	history.termination_reason = ""
	history.termination_message = ""

	var user_history_item = create_user_history_item(text)
	user_history_item.provider = history.provider
	# if we're using the human provider, handle it here
	if user_history_item.provider is HumanProvider:
		handle_human_provider_message(history, user_history_item)
		for i in SingletonObject.notes_container.get_tab_count():
			SingletonObject.notes_container.disable_notes(i)

		for i in SingletonObject.drawer_notes_container.get_tab_count():
			SingletonObject.drawer_notes_container.disable_notes(i)

		SingletonObject.clear_consumed_proxies(history.HistoryId)

		return # if user is using Human provider we finish here

	# Check is the last message is a user message and not do anything if true
	if last_msg and last_msg.Role == ChatHistoryItem.ChatRole.USER: return

	# Setup agent mode tools if enabled for this chat
	print("[Chat] Checking agent mode: AgentModeEnabled=%s, has_set_tools=%s, history_id=%s" % [history.AgentModeEnabled, history.provider.has_method("set_tools"), history.HistoryId])
	if history.AgentModeEnabled and history.provider.has_method("set_tools"):
		var mcp = SingletonObject.get_mcp_manager()
		var filtered_tools: Array[Dictionary] = mcp.get_tools_for_chat(history)
		print("[Agent] Setting up tools: %d after filtering" % [filtered_tools.size()])
		for t in filtered_tools:
			print("[Agent]   - %s" % t.get("name", "?"))
		history.provider.set_tools(filtered_tools)
		print("[Agent] Provider tools_enabled: %s" % history.provider.tools_enabled)

	# Configure tool memory manager callables before prompt building
	_configure_tool_memory_manager(history)

	# Check token threshold — offer compaction for large regular chat contexts
	if not history.AgentModeEnabled:
		var compact_threshold = history.AgentSummarizeThreshold if history.AgentSummarizeThreshold > 0 else AGENT_SUMMARIZE_THRESHOLD
		var est_tokens = estimate_agent_context_size(history)
		if est_tokens >= compact_threshold and history.HistoryItemList.size() > AGENT_KEEP_RECENT_MESSAGES + 1:
			var dialog := ConfirmationDialog.new()
			dialog.title = "Large Context"
			dialog.dialog_text = "This chat is ~%d tokens (threshold: %d).\nCompact to reduce context?" % [est_tokens, compact_threshold]
			dialog.ok_button_text = "Compact"
			dialog.cancel_button_text = "Skip"
			add_child(dialog)
			dialog.popup_centered()
			# ConfirmationDialog emits confirmed or canceled
			var compacted := {"value": false}
			dialog.confirmed.connect(func(): compacted["value"] = true)
			await dialog.visibility_changed  # Wait for dialog to close
			dialog.queue_free()
			if compacted["value"]:
				await compact_chat(history)
				if history.VBox:
					history.VBox.render_history(history)

	# make a chat request
	var history_list: = await create_prompt(user_history_item, true, null, Callable(), history)
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

	# W5 (chat-passthrough): for passthrough chats the generate is a zero-token
	# plugin transport while the bound terminal's agent works. Relay the agent's
	# own mechanical status (read straight off the PTY screen) into THIS node so
	# the turn looks alive, until the generate resolves. The relay reuses the
	# accumulator idiom: content lives on dummy_item, the wave shows via
	# loading_append, and the SAME node finalizes below.
	var _pt_status = _passthrough_begin_relay(history, model_msg_node, dummy_item)

	print("[ChatPane] About to call generate_content_from_provider...")
	var bot_response = await generate_content_from_provider(history, history_list)
	print("[ChatPane] generate_content_from_provider returned: %s" % (bot_response != null))

	# Stop the status relay the instant the generate resolves (success/error/cancel).
	_passthrough_end_relay(_pt_status, bot_response, model_msg_node, dummy_item)

	# Create history item from bot response
	print("[ChatPane] Calling process_bot_response...")
	var chi = process_bot_response(bot_response, history.provider)
	print("[ChatPane] process_bot_response returned, chi.Message length: %d" % chi.Message.length())

	# W5: carry passthrough question options (W1 contract) onto the finalized CHI
	# so W4 can render cards on the NEXT round. Nothing here renders cards.
	if bot_response != null and bot_response.hcp_data.has("passthrough_question_options"):
		chi.HcpData = {"passthrough_question_options": bot_response.hcp_data["passthrough_question_options"]}

	# W8 round 4 (owner request): preserve the flying text. The agent ERASES its
	# busy/preview output at turn end, so the relay's tail frames are the only
	# record of what flew by — attach them to the finalized message as a
	# collapsed tool-call-style block (the agentic idiom; ToolCalls stays empty,
	# every IsToolCall consumer iterates that, so this is render+persist only).
	_passthrough_attach_activity_log(chi, _pt_status)

	# Handle tool calls if agent mode is enabled for this chat and response has tool calls
	print("[ChatPane] Tool call check: AgentModeEnabled=%s, bot_response=%s, has_tool_calls=%s" % [
		history.AgentModeEnabled,
		bot_response != null,
		bot_response.has_tool_calls() if bot_response else false
	])
	if history.AgentModeEnabled and bot_response and bot_response.has_tool_calls():
		print("[ChatPane] Entering tool call handling branch")
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
		print("[ChatPane] NOT entering tool call branch - skipping tool execution")
		if history.AgentModeEnabled:
			history.termination_reason = "completed"
			history.termination_message = ""
		update_ui_after_response(user_history_item, user_msg_node, model_msg_node, chi, bot_response, history)
		# W4 (chat-passthrough): a question turn (terminal agent hit a permission
		# dialog or an AskUserQuestion chooser) gets a clickable option card right
		# under the bot message.
		var _q_card := _passthrough_add_question_card(history, chi, model_msg_node)
		# Safety net: the plugin flagged a question (terminal agent is BLOCKED on a
		# choice) but we couldn't parse clickable options. Never render nothing —
		# that strands the user silently while the agent waits. Show a visible
		# notice telling them how to answer (typing the digit/letter still routes
		# through as a keystroke via the plugin's pending-question state).
		if _q_card == null and chi.HcpData.has("passthrough_question_options"):
			_passthrough_add_waiting_notice(history, model_msg_node)

	# Notify trigger system that this agent chat is fully done (all tool rounds complete)
	if history.IsAgentChat:
		SingletonObject.agent_chat_finished.emit(history.HistoryId, history.AgentDefinitionId)

	history.is_request_active = false
	_update_stop_button()
	_update_compact_button()


## W5 (chat-passthrough): how often to re-read the bound terminal screen while a
## passthrough turn is in flight. ~1Hz — a SceneTree timer, never per-frame.
const PASSTHROUGH_STATUS_POLL_SEC := 1.0


## Begin the live-status relay for a passthrough turn. Returns a
## PassthroughTurnStatus bookkeeper (null for non-passthrough chats, so the
## generic path is untouched). Switches the loading node into loading_append
## mode (content visible + ●●● wave, like the accumulator) and kicks a ~1Hz
## SceneTree poll loop that relays the bound session's screen into the node.
## No bound session (background session died / id empty) → keep the plain ●●●
## bubble (loading stays true), no relay, no errors.
func _passthrough_begin_relay(history: ChatHistory, model_msg_node: Control,
		dummy_item: ChatHistoryItem):
	if history == null or not history.PassthroughMode:
		return null
	var status = PassthroughTurnStatusScript.new()
	if not status.begin():
		return null
	# Switch the bubble from "hide-everything loading" to "content + wave" so the
	# relayed status text is visible. loading must go false or content is hidden.
	if is_instance_valid(model_msg_node):
		model_msg_node.loading = false
		model_msg_node.loading_append = true
	# Drive the poll loop as a detached coroutine; it self-terminates when
	# status.polling clears (set by _passthrough_end_relay) or the node dies.
	_passthrough_poll_loop(status, history, model_msg_node, dummy_item)
	return status


## Detached ~1Hz poll loop. Reads the bound session screen, compacts it, and —
## if it changed — grows the in-flight node IN PLACE (no new ChatHistoryItem)
## using the agentic-accumulator idiom (handle_tool_calls): drop the wave, grow
## the content, re-add the ●●● wave at the BOTTOM of the new content, then
## follow with a bottom-scroll. Order matters twice over: render() rebuilds the
## label stack (freeing the old wave label), so loading_append must be re-set
## AFTER it to land under the fresh content; and the scroll must run after a
## frame so layout has the new height (otherwise the tween chases a stale
## bottom — the W8 grow-then-scroll-tick jitter). Stops when polling clears.
func _passthrough_poll_loop(status, history: ChatHistory, model_msg_node: Control,
		dummy_item: ChatHistoryItem) -> void:
	while status != null and status.polling:
		if not is_instance_valid(model_msg_node) or not is_instance_valid(dummy_item):
			return
		var screen := _passthrough_read_session_screen(history)
		var compact: String = status.mark_status(screen)
		if not compact.is_empty():
			dummy_item.Message = compact
			if is_instance_valid(model_msg_node) and model_msg_node.has_method("render"):
				model_msg_node.loading_append = false
				model_msg_node.render()
				await get_tree().process_frame
				# The generate may have resolved while we yielded — the finalize
				# path owns the node now; re-adding the wave would strand it on
				# the finished message.
				if not status.polling or not is_instance_valid(model_msg_node):
					return
				model_msg_node.loading_append = true
				if history.VBox != null and is_instance_valid(history.VBox):
					history.VBox.ensure_node_bottom_is_visible(model_msg_node)
		await get_tree().create_timer(PASSTHROUGH_STATUS_POLL_SEC).timeout


## Read the bound terminal's viewport text, or "" when there is no live session.
## Pure-ish: all the string work lives in PassthroughTurnStatus.compact_status.
func _passthrough_read_session_screen(history: ChatHistory) -> String:
	if history == null or history.BoundTerminalId.is_empty():
		return ""
	var registry = SingletonObject.get_terminal_session_registry()
	if registry == null or not registry.has_session(history.BoundTerminalId):
		return ""
	var session = registry.get_session(history.BoundTerminalId)
	if session == null or not session.has_method("read_viewport_text"):
		return ""
	return str(session.read_viewport_text())


## W8 round 4: attach the turn's flying-text log to the finalized CHI as one
## ToolExecutions entry (rendered by ToolCallBlock, collapsed). No frames → no
## block. ToolExecutions is a TYPED Array[Dictionary] — build through a typed
## local; a plain Array literal fails the property assignment at runtime.
func _passthrough_attach_activity_log(chi: ChatHistoryItem, status) -> void:
	if chi == null or status == null:
		return
	if not ("frames" in status) or status.frames.is_empty():
		return
	var execs: Array[Dictionary] = [{
		"call_id": "passthrough-live-%s" % str(chi.Id),
		"tool_name": "Terminal live view (%d frames)" % status.frames.size(),
		"arguments": {"frames": status.frames.size()},
		"result": status.activity_log(),
		"status": "done",
	}]
	chi.IsToolCall = true
	chi.ToolExecutions = execs


## End the relay when the generate resolves. Stops polling, records the
## disposition (for the cancelled/answer/question distinction), and drops the
## append-wave so the SAME node can finalize cleanly via update_ui_after_response.
func _passthrough_end_relay(status, bot_response, model_msg_node: Control,
		_dummy_item: ChatHistoryItem) -> void:
	if status == null:
		return
	var disposition := "answer"
	if bot_response == null:
		disposition = "error"
	elif bot_response.error != null and not str(bot_response.error).is_empty():
		# PluginProvider stamps "Request cancelled." on a stop; any other error
		# string is a transport/plugin error. Both end the relay; the finalize
		# path renders the error text like other providers.
		disposition = "cancelled" if str(bot_response.error).to_lower().find("cancel") != -1 else "error"
	elif bot_response.hcp_data.has("passthrough_question_options"):
		disposition = "question"
	status.finish(disposition)
	if is_instance_valid(model_msg_node):
		model_msg_node.loading_append = false


## W4 (chat-passthrough): question text shown on the option card. The full
## terminal dialog is already visible in the bot message right above the card,
## so the card carries a short action prompt, not a duplicate of the screen.
const PASSTHROUGH_QUESTION_PROMPT := "The terminal agent is waiting — click an option, or type your own answer in the message box:"


## W4 (chat-passthrough): render a clickable option card under a finalized
## question turn. Reuses AutocoderStreamQuestionCard AS-IS: the card shows the
## option LABELS and emits answer_submitted(question_id, answer, session_id);
## the label → keystroke mapping lives here, bound onto the connection.
##
## Persistence choice (v1): cards are live-turn affordances ONLY. They are
## plain VBox children — never ChatHistoryItems — so project save (which
## serializes HistoryItemList) never captures them and render_history never
## rebuilds them. After a reload the card is simply ABSENT: the dialog state
## on the terminal is likely gone after a restart, and the options still live
## on the CHI's HcpData if anyone ever wants to resurrect them.
##
## Lifecycle: the card is parented to the chat's VBox, so closing the chat
## frees it; its answer_submitted connection is owned by the card and dies
## with it (no dangling connections on ChatPane).
##
## Returns the card, or null when there are no usable options (req: no card,
## zero new UI — the user types free text in the normal input).
func _passthrough_add_question_card(history: ChatHistory, chi: ChatHistoryItem,
		model_msg_node: Control) -> Control:
	if history == null or chi == null:
		return null
	var raw = chi.HcpData.get("passthrough_question_options", [])
	if not (raw is Array) or raw.is_empty():
		return null
	# Parse {label, keystroke} dicts. Values are JSON round-tripped, so coerce
	# with str() (survives ints-as-floats etc.). Options without a label are
	# dropped; an empty keystroke (Cancel per the locked contract) is kept —
	# the click is then a no-send (see _on_passthrough_question_answered).
	var labels: Array = []
	var keystroke_by_label: Dictionary = {}
	for opt in raw:
		if not (opt is Dictionary):
			continue
		var label := str(opt.get("label", "")).strip_edges()
		if label.is_empty():
			continue
		if not keystroke_by_label.has(label):
			labels.append(label)
		keystroke_by_label[label] = str(opt.get("keystroke", ""))
	if labels.is_empty():
		return null
	var vbox = history.VBox
	if vbox == null or not is_instance_valid(vbox):
		return null
	var card = PassthroughQuestionCardScene.instantiate()
	# add_child BEFORE setup(): the card resolves its %nodes via @onready
	# (AutocoderActionStream hosts it the same way).
	vbox.add_child(card)
	if is_instance_valid(model_msg_node) and model_msg_node.get_parent() == vbox:
		vbox.move_child(card, model_msg_node.get_index() + 1)
	# The card prepends each option button (move_child(btn, 0)), which displays
	# the options REVERSED. Compensate here (read-only reuse — don't touch the
	# card) so the user sees them in the contract's order: Yes / … / Cancel.
	var display_labels := labels.duplicate()
	display_labels.reverse()
	card.setup(chi.Id, PASSTHROUGH_QUESTION_PROMPT, display_labels, history.HistoryId)
	# The card owns this connection — it dies when the card is freed with the
	# VBox, so a closed chat leaves nothing dangling on ChatPane.
	card.answer_submitted.connect(
		_on_passthrough_question_answered.bind(history, keystroke_by_label, card))
	return card


## Safety net for a question turn whose options couldn't be parsed into buttons
## (an unfamiliar dialog/chooser layout). Without this the chat shows the raw
## dialog text and nothing else, so the user can't tell the agent is BLOCKED
## waiting — they have to discover the terminal. This renders a visible, live-turn
## notice (same parenting/lifecycle as the option card: a plain VBox child, never
## a ChatHistoryItem, freed with the chat). Typing the digit/letter in the normal
## message box still answers — the plugin's pending-question state forwards it as
## a raw keystroke — so the notice tells the user exactly that.
func _passthrough_add_waiting_notice(history: ChatHistory, model_msg_node: Control) -> Control:
	if history == null:
		return null
	var vbox = history.VBox
	if vbox == null or not is_instance_valid(vbox):
		return null
	var notice := Label.new()
	notice.text = "⚠ The terminal agent is waiting on a choice. I couldn't turn its options into buttons — type the number or letter of your choice in the message box below, or answer in the terminal."
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	notice.add_theme_color_override("font_color", Color(0.96, 0.74, 0.22))
	vbox.add_child(notice)
	if is_instance_valid(model_msg_node) and model_msg_node.get_parent() == vbox:
		vbox.move_child(notice, model_msg_node.get_index() + 1)
	return notice


## W4: an option was clicked. The card already guards re-submission internally
## (meta "submitted"); additionally grey out its buttons so the answered state
## is visible AND unclickable. Then send the mapped keystroke as the next user
## turn on the ORIGINATING history. Answering a stale card whose terminal
## dialog is long gone is harmless — the keystroke hits the PTY like any
## typed text (terminal-honest).
func _on_passthrough_question_answered(_question_id: String, answer: String, _session_id: String,
		history: ChatHistory, keystroke_by_label: Dictionary, card: Control) -> void:
	if is_instance_valid(card):
		for btn in card.find_children("*", "Button", true, false):
			btn.disabled = true
	var keystroke := str(keystroke_by_label.get(answer, ""))
	# Locked contract: an EMPTY keystroke (Cancel = "" → ESC, handled plugin-
	# side) is never sent as a user turn — sending "" would be an empty
	# message; core does nothing special beyond not sending.
	if keystroke.is_empty():
		return
	_passthrough_send_question_answer(history, keystroke)


## W4: send a keystroke as a normal user turn on a SPECIFIC history (not
## whatever tab is current). Mirrors MCPChatTools._send_message: switch to the
## originating tab, reuse the UNCHANGED send path, restore the tab deferred
## (execute_regular_chat reads current_tab during setup — switching back too
## early causes provider mismatch).
func _passthrough_send_question_answer(history: ChatHistory, keystroke: String) -> void:
	var tab_idx := SingletonObject.ChatList.find(history)
	if tab_idx == -1:
		return  # chat closed under us; its card was freed with the VBox anyway
	var original_tab := current_tab
	current_tab = tab_idx
	execute_regular_chat(keystroke)
	call_deferred("set_current_tab", original_tab)


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
## Re-enables notes and cleans up detached proxies.
## Note: Does NOT touch is_request_active — that is managed by the request lifecycle
## (incremented in execute_regular_chat, decremented after await handle_tool_calls returns).
func _finish_agent_mode() -> void:
	# Disable notes in containers
	for i in SingletonObject.notes_container.get_tab_count():
		SingletonObject.notes_container.disable_notes(i)
	for i in SingletonObject.drawer_notes_container.get_tab_count():
		SingletonObject.drawer_notes_container.disable_notes(i)

	var _history: ChatHistory = SingletonObject.ChatList[current_tab]
	SingletonObject.clear_consumed_proxies(_history.HistoryId)


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
		history.termination_reason = "quota_exhausted"
		history.termination_message = "Max tool call rounds (%d) reached" % max_rounds
		finish_with_signal.call()
		return

	# Check for cancellation at start
	if SingletonObject.is_cancelled(history.HistoryId):
		SingletonObject.clear_cancelled(history.HistoryId)
		# Add tool_result blocks for unexecuted tools so conversation can continue
		_add_unexecuted_tool_results(history, tool_calls, "Cancelled by user")
		history.termination_reason = "cancelled"
		history.termination_message = "Cancelled by user"
		finish_with_signal.call()
		return

	var mcp_manager = SingletonObject.get_mcp_manager()

	print("[Agent] Round %d: Processing %d tool calls" % [current_round, tool_calls.size()])

	# Use accumulator if provided, otherwise get the last MODEL item
	var model_chi: ChatHistoryItem = accumulator_chi if accumulator_chi else _get_last_model_history_item(history)

	# Execute each tool call and collect results
	# Batch-level dedup: identical tool+args within the same round reuse cached result
	var _batch_cache: Dictionary = {}

	for i in range(tool_calls.size()):
		var tool_call = tool_calls[i]

		# Check for cancellation before each tool
		if SingletonObject.is_cancelled(history.HistoryId):
			SingletonObject.clear_cancelled(history.HistoryId)
			# Add tool_results for remaining unexecuted tools (current + rest)
			var remaining_tools = tool_calls.slice(i)
			_add_unexecuted_tool_results(history, remaining_tools, "Cancelled by user")
			history.termination_reason = "cancelled"
			history.termination_message = "Cancelled by user during tool execution"
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
		if is_instance_valid(model_chi.rendered_node):
			model_chi.rendered_node.update_tool_execution(tool_id, "", false)

		# Check path permissions before executing
		var path_error = check_tool_path_permissions(tool_name, tool_args, history.AllowedDirectories)
		var result: Dictionary
		if path_error != null:
			print("[Agent] Tool blocked by AllowedDirectories: %s" % tool_name)
			result = path_error
		else:
			# Batch dedup: skip if identical tool+args already executed this round
			var call_hash: String = (tool_name + JSON.stringify(tool_args)).sha256_text()
			if _batch_cache.has(call_hash):
				result = _batch_cache[call_hash].duplicate()
				result["_deduped"] = true
				print("[Agent] Dedup: reusing result for %s" % tool_name)
			else:
				# Execute the tool — pass caller_chat_id so tools like spawn_worker know who called
				result = await mcp_manager.execute_tool(tool_name, tool_args, history.HistoryId)
				_batch_cache[call_hash] = result

		print("[Agent] Tool result: %s" % str(result).left(200))

		# Capture and store the filtered full result before truncation so later
		# prompt projection can dehydrate older tool payloads safely.
		var full_result_str := _filter_tool_result_text(JSON.stringify(result))
		var artifact_note_id := _store_tool_artifact(history, tool_name, tool_args, full_result_str, tool_id)

		# Store a compact window in chat history while keeping the full artifact in agent notes.
		var windowed_result := _build_windowed_tool_result_message(
			tool_name,
			full_result_str,
			artifact_note_id,
			history.tool_memory_manager.enabled,
			history.AgentMaxToolResultLength
		)
		var result_str: String = str(windowed_result.get("text", full_result_str))
		var was_windowed := bool(windowed_result.get("windowed", false))
		var shown_chars := int(windowed_result.get("shown_chars", result_str.length()))
		var original_len = full_result_str.length()
		if was_windowed:
			print("[Agent] Windowed tool result from %d to %d chars" % [original_len, shown_chars])
		elif result_str.length() < original_len:
			print("[Agent] Truncated tool result from %d to %d chars" % [original_len, result_str.length()])

		# Update execution entry with result
		var is_error = result.get("error") != null
		execution_entry["result"] = result_str
		execution_entry["status"] = "error" if is_error else "done"

		# Update the rendered node with the result
		if is_instance_valid(model_chi.rendered_node):
			model_chi.rendered_node.update_tool_execution(tool_id, result_str, is_error)

		# Create tool result history item (hidden - for API continuity only)
		var tool_result_item = ChatHistoryItem.new()
		tool_result_item.Role = ChatHistoryItem.ChatRole.TOOL
		tool_result_item.ToolCallId = tool_id
		tool_result_item.ToolName = tool_name
		tool_result_item.Message = result_str
		tool_result_item.ToolSummary = _build_tool_summary(tool_name, result, artifact_note_id)
		tool_result_item.ToolArtifactNoteId = artifact_note_id
		tool_result_item.provider = history.provider
		tool_result_item.Visible = false  # Don't render separately - shown in parent message

		# Add to history (this is critical - must happen before continuation)
		history.HistoryItemList.append(tool_result_item)
		history.tool_memory_manager.record_telemetry(history, {
			"last_tool_name": tool_name,
			"last_tool_artifact_note_id": artifact_note_id,
			"last_tool_result_chars": original_len,
			"last_tool_result_windowed": was_windowed,
			"last_tool_result_shown_chars": shown_chars,
		})
		# Keep the normal append-loading indicator visible while we wait on
		# floating-summary generation so blocked parent chats still show work.
		if is_instance_valid(model_chi.rendered_node):
			model_chi.rendered_node.loading_append = true
		await history.tool_memory_manager.fold_tool_result(history)

		# Yield one frame so Godot can render/process input between tool calls.
		# Most tool handlers are synchronous, so `await execute_tool()` completes
		# instantly — without this, the entire for-loop runs in one frame and walls the CPU.
		await get_tree().process_frame

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
		history.termination_reason = "quota_exhausted"
		history.termination_message = context_status.message
		finish_with_signal.call()
		return
	elif context_status.warning:
		# Warning threshold - try to summarize
		if context_status.estimated_tokens >= context_status.summarize_threshold:
			await summarize_agent_history(history)
			var new_size = estimate_agent_context_size(history)
			print("[Agent] Context reduced to ~%d tokens" % new_size)

	# Ensure tools are still enabled for continuation request (with filtering)
	if history.provider.has_method("set_tools"):
		var filtered_tools: Array[Dictionary] = mcp_manager.get_tools_for_chat(history)
		history.provider.set_tools(filtered_tools)

	# Check for cancellation before continuation
	if SingletonObject.is_cancelled(history.HistoryId):
		SingletonObject.clear_cancelled(history.HistoryId)
		history.termination_reason = "cancelled"
		history.termination_message = "Cancelled by user before continuation"
		finish_with_signal.call()
		return

	# Build continuation prompt with tool results
	# Use create_prompt() to properly handle system messages (filters them from messages array
	# and sets provider.system_prompt for Anthropic/Google)
	# NOTE: Use refresh_detached=false to use cached notes (created when tool enabled "Send to LLM")
	# instead of calling the initializer again, which can cause issues with graphics composition
	# Pass history explicitly to avoid current_tab race with concurrent sub-agent chats
	var continuation_list = await create_prompt(null, false, null, Callable(), history)

	print("[Agent] Sending continuation with %d messages" % continuation_list.size())

	# Show loading state at bottom of message (append mode - doesn't hide content)
	if is_instance_valid(model_chi.rendered_node):
		model_chi.rendered_node.loading_append = true

	# Get LLM's response to tool results
	var continuation_response = await generate_content_from_provider(history, continuation_list)

	if not continuation_response:
		print("[Agent] ERROR: No continuation response received")
		if is_instance_valid(model_chi.rendered_node):
			model_chi.rendered_node.loading_append = false
		history.termination_reason = "error"
		history.termination_message = "No continuation response received"
		finish_with_signal.call()
		return

	# Check for errors in response — retry once for transient empty-response errors
	if continuation_response.error:
		print("[Agent] ERROR in response: %s" % continuation_response.error)
		# Retry once for empty/transient errors (e.g., Gemini returning empty content)
		if current_round > 0 and "empty response" in continuation_response.error.to_lower():
			print("[Agent] Retrying continuation after empty response (round %d)..." % current_round)
			await get_tree().create_timer(1.0).timeout
			continuation_response = await generate_content_from_provider(history, continuation_list)
			if continuation_response and not continuation_response.error:
				# Retry succeeded — continue processing below
				pass
			else:
				var err_msg = continuation_response.error if continuation_response else "No response on retry"
				print("[Agent] Retry also failed: %s" % err_msg)
				model_chi.Message += "\n\n[Agent Error: %s (retry also failed)]" % err_msg
				if is_instance_valid(model_chi.rendered_node):
					model_chi.rendered_node.loading_append = false
					model_chi.rendered_node.render()
				history.termination_reason = "error"
				history.termination_message = err_msg
				finish_with_signal.call()
				return
		else:
			# Non-retryable error
			model_chi.Message += "\n\n[Agent Error: %s]" % continuation_response.error
			if is_instance_valid(model_chi.rendered_node):
				model_chi.rendered_node.loading_append = false
				model_chi.rendered_node.render()
			history.termination_reason = "error"
			history.termination_message = continuation_response.error
			finish_with_signal.call()
			return

	# Process the continuation response
	var continuation_chi = process_bot_response(continuation_response, history.provider)
	_accumulate_cache_telemetry(continuation_response, history)

	print("[Agent] Continuation has tool_calls: %s" % continuation_response.has_tool_calls())

	# Append continuation text to accumulator (if any)
	if not continuation_chi.Message.is_empty():
		if model_chi.Message.is_empty():
			model_chi.Message = continuation_chi.Message
		else:
			model_chi.Message += "\n\n" + continuation_chi.Message

	# Accumulate this round's reasoning onto the accumulator so multi-round agent
	# thinking all renders (otherwise only round 1's reasoning would show).
	if not continuation_chi.Reasoning.is_empty():
		model_chi.Reasoning.append_array(continuation_chi.Reasoning)

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
		if is_instance_valid(model_chi.rendered_node):
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
			history.termination_reason = "cancelled"
			history.termination_message = "Cancelled by user before continuation"
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
		if not is_instance_valid(model_chi.rendered_node):
			model_chi.rendered_node = history.VBox.add_history_item(model_chi)
		if is_instance_valid(model_chi.rendered_node):
			model_chi.rendered_node.loading_append = false
			model_chi.rendered_node.first_time_message = true
			model_chi.rendered_node.render()
			await get_tree().process_frame
			# Use bottom scroll to show the final response at the end
			history.VBox.ensure_node_bottom_is_visible(model_chi.rendered_node)

		# Voice mode: speak the final response via TTS (agentic mode)
		# Use continuation_chi.Message (clean final text) not model_chi.Message
		# (which has accumulated tool block markers from all rounds)
		var final_text: String = continuation_chi.Message if continuation_chi else model_chi.Message
		if not final_text.is_empty() and is_instance_valid(model_chi.rendered_node):
			var user_text := user_history_item.Message if user_history_item else ""
			_voice_speak_response(final_text, user_text, model_chi.rendered_node)

		history.termination_reason = "completed"
		history.termination_message = ""
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
			
			SingletonObject.clear_consumed_proxies(history.HistoryId)

			return # if user is using Human provider we finish here
		
		# Check is the last message is a user message and not do anything if true
		if last_msg and last_msg.Role == ChatHistoryItem.ChatRole.USER: return
		
		# make a chat request
		var history_list: = await create_prompt(user_history_item, true, null, Callable(), history)
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
	history.is_request_active = false
	_update_stop_button()
	_update_compact_button()

	for i in SingletonObject.notes_container.get_tab_count():
		SingletonObject.notes_container.disable_notes(i)

	for i in SingletonObject.drawer_notes_container.get_tab_count():
		SingletonObject.drawer_notes_container.disable_notes(i)
	
	SingletonObject.clear_consumed_proxies(history.HistoryId)

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
		history.is_request_active = false
		_update_stop_button()
		_update_compact_button()

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
	var history_list: = await create_prompt(user_history_item, true, null, Callable(), history)
	
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
	wrapper.name = chat_history.HistoryName if not chat_history.HistoryName.is_empty() else "Chat"
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

	# A chat created while a group is selected lands in that group. Otherwise the
	# filter hides it the instant it appears and the chat looks like it was never
	# created — worst for agent-spawned chats the user did not initiate.
	# _initializing_pane marks the load path, where memberships are already set.
	if not _initializing_pane and str(chat_history.ChatGroupId).is_empty() and not chat_history.Deleted:
		chat_history.ChatGroupId = default_group_for_new_chat()

	# set the scroll container name and add it to the pane.
	var _name = chat_history.HistoryName
	#scroll_container.name = _name
	%tcChats.add_child(wrapper)
	var tab_idx = %tcChats.get_tab_idx_from_control(wrapper)
	%tcChats.set_tab_title(tab_idx, _name)

	# Re-run the filter now that a tab exists. Adding a chat changes what the
	# strip should show — and, since the pane hides itself when nothing matches,
	# it is also what brings the pane BACK after the first chat is created.
	# Deferred so the new tab is fully registered first.
	call_deferred("_apply_tab_filters")
	call_deferred("_refresh_group_dock")

	# Eagerly create the agent-notes tab for agent chats so it's visible
	# before any tool calls happen.
	if chat_history.AgentModeEnabled or chat_history.IsAgentChat:
		_get_agent_notes_tab(chat_history)
	
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

	# The tab bar forwards all three drag callbacks here. The drop side already
	# handled note-onto-chat linking; the SOURCE slot was empty (Callable()) and
	# now supplies the chat-tab payload the group dock accepts.
	#
	# Supplying custom drag data supersedes TabBar.drag_to_rearrange_enabled, and
	# reordering is load-bearing — _on_child_order_changed() derives ChatList
	# from child order. So rather than lose it, the drop side below reimplements
	# reordering for our own payload: drop on a group card = regroup, drop on the
	# tab bar = reorder. Both gestures survive.
	self.get_tab_bar().mouse_filter = MOUSE_FILTER_PASS
	self.get_tab_bar().set_drag_forwarding(_get_chat_tab_drag_data, _can_drop_note_on_chat, _drop_note_on_chat)

	# Right-click a tab for group actions. Cleaner than overloading the
	# double-click timer, which already means "rename this chat".
	self.get_tab_bar().tab_rmb_clicked.connect(_on_tab_rmb_clicked)

	# SingletonObject.initialize_chats(self)
	%AISettings.create_system_prompt_message.connect(add_new_system_prompt_item)

	# Hide old AgentModeToggle in chat controls - agent mode is now per-chat via ChatHeader
	%AgentModeToggle.hide()

	# Recompute DisabledTools for focused chats when MCP connects (tool registry may differ).
	# IMPORTANT: Do NOT call get_mcp_manager() here — it would create the MCPManager before
	# initialize_mcp() runs, causing it to skip connect_minerva_server(). Defer the connection.
	call_deferred("_connect_mcp_signals")

	# Add Compact button to chat controls (before the stop button)
	_compact_button = Button.new()
	_compact_button.text = "C"
	_compact_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_compact_button.tooltip_text = "Compact chat history to reduce context size"
	_compact_button.pressed.connect(_on_compact_pressed)
	_compact_button.disabled = true
	audio_stop_1.get_parent().add_child(_compact_button)
	audio_stop_1.get_parent().move_child(_compact_button, audio_stop_1.get_index())

	# TTS playback player for voice conversation mode
	_tts_player = AudioStreamPlayer.new()
	add_child(_tts_player)

	# Connect transcription signal for voice mode auto-send + TTS
	SingletonObject.AtT.transcription_completed.connect(_on_voice_transcription_completed)

	# Voice gateway client (always-listening mode)
	_voice_gateway = VoiceGatewayClientScript.new()
	add_child(_voice_gateway)
	_voice_gateway.engagement_changed.connect(_on_engagement_changed)
	_voice_gateway.transcription_ready.connect(_on_gateway_transcription_ready)
	_voice_gateway.connected_to_gateway.connect(_on_gateway_connected)
	_voice_gateway.disconnected_from_gateway.connect(_on_gateway_disconnected)
	_voice_gateway.gateway_start_failed.connect(_on_gateway_start_failed)
	_voice_gateway.wake_word_detected.connect(func(conf: float):
		print("[ChatPane] Wake word detected (%.3f)" % conf)
		_lazy_pre_warm()
	)

	# TTS finished → notify gateway
	_tts_player.finished.connect(_on_tts_playback_finished)

	# Always-listening toggle switch with state label — top bar
	var listen_hbox := HBoxContainer.new()
	listen_hbox.add_theme_constant_override("separation", 4)

	_engagement_toggle = CheckButton.new()
	_engagement_toggle.text = ""
	_engagement_toggle.tooltip_text = "Toggle always-listening voice mode"
	_engagement_toggle.toggled.connect(_on_engagement_toggle_changed)
	listen_hbox.add_child(_engagement_toggle)

	_engagement_state_label = Label.new()
	_engagement_state_label.text = "Voice Off"
	_engagement_state_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_engagement_state_label.add_theme_font_size_override("font_size", 11)
	listen_hbox.add_child(_engagement_state_label)

	# Place in top bar, left of CloneChatButton
	var vbox3: Node = get_parent().get_parent().get_parent()
	if vbox3:
		var clone_btn: Node = vbox3.find_child("CloneChatButton", true, false)
		if clone_btn and clone_btn.get_parent():
			var parent_hbox: Node = clone_btn.get_parent()
			parent_hbox.add_child(listen_hbox)
			parent_hbox.move_child(listen_hbox, clone_btn.get_index())

			# "Focused Chat" button — creates a chat with a fixed tool set
			var new_chat_btn: Node = vbox3.find_child("btnNewChat", true, false)
			if new_chat_btn and new_chat_btn.get_parent():
				var focused_btn := Button.new()
				focused_btn.tooltip_text = "Create a focused chat with a fixed tool set (no dynamic tool discovery)"
				focused_btn.focus_mode = Control.FOCUS_NONE
				var bot_icon = load("res://assets/icons/robot_AI.png")
				if bot_icon:
					focused_btn.icon = bot_icon
				focused_btn.pressed.connect(_on_focused_chat_pressed)
				new_chat_btn.get_parent().add_child(focused_btn)
				new_chat_btn.get_parent().move_child(focused_btn, new_chat_btn.get_index())

				# "Passthrough Chat" button — chat bound to a terminal-backed plugin
				# provider (chat-passthrough W2). No vertical-swap icon exists in
				# assets/, so a "⇅" text glyph stands in this round (W3 may refine).
				var passthrough_btn := Button.new()
				passthrough_btn.text = "⇅"
				passthrough_btn.tooltip_text = "New passthrough chat"
				passthrough_btn.focus_mode = Control.FOCUS_NONE
				passthrough_btn.pressed.connect(_on_passthrough_chat_pressed)
				new_chat_btn.get_parent().add_child(passthrough_btn)
				new_chat_btn.get_parent().move_child(passthrough_btn, new_chat_btn.get_index())

	# Auto-start voice gateway if always_listening was previously enabled
	var cfg := SingletonObject.get_voice_config()
	if cfg.always_listening:
		_engagement_toggle.set_pressed_no_signal(true)
		call_deferred("_auto_start_voice")

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

	# Apply the group/archive/delete filter after all chats are loaded (deferred
	# so the tabs exist).
	call_deferred("_apply_tab_filters")

	# Mount the group dock above the tab strip.
	call_deferred("_ensure_group_dock")


## Accept drops on the chat tab bar: a Note (links it to that chat) or a chat
## tab (reorders it, replacing the built-in rearrange that our drag source
## supersedes).
func _can_drop_note_on_chat(at_position: Vector2, data: Variant) -> bool:
	if data is Note:
		return get_tab_idx_at_point(at_position) != -1
	if data is Dictionary and str((data as Dictionary).get("kind", "")) == "chat_tab":
		return true
	return false


func _drop_note_on_chat(at_position: Vector2, data: Variant) -> void:
	if data is Dictionary and str((data as Dictionary).get("kind", "")) == "chat_tab":
		_reorder_chat_tab(at_position, data as Dictionary)
		return
	if not data is Note:
		return
	var tab_idx: int = get_tab_idx_at_point(at_position)
	if tab_idx < 0 or tab_idx >= SingletonObject.ChatList.size():
		return
	var history: ChatHistory = SingletonObject.ChatList[tab_idx]
	(data as Note).link_to_chat(history.HistoryId)
	SingletonObject.create_toast_notification("Linked \"%s\" to %s" % [(data as Note).title, history.HistoryName])


## Reorder a chat tab dropped back onto the tab bar.
##
## Moving the child is what actually reorders: _on_child_order_changed() then
## rebuilds ChatList from child order, which is why the payload's HistoryId is
## resolved to a CURRENT index here rather than trusting the index captured when
## the drag began.
func _reorder_chat_tab(at_position: Vector2, payload: Dictionary) -> void:
	var history := find_chat_by_id(str(payload.get("chat_id", "")))
	if history == null:
		return
	var from_idx := SingletonObject.ChatList.find(history)
	if from_idx < 0 or from_idx >= get_tab_count():
		return
	var to_idx: int = get_tab_idx_at_point(at_position)
	if to_idx < 0:
		to_idx = get_tab_count() - 1
	if to_idx == from_idx:
		return
	var moving := get_tab_control(from_idx)
	var target := get_tab_control(to_idx)
	if moving == null or target == null:
		return
	# A tab index is NOT a child index: _ready() also parents lifetime-of-pane
	# infrastructure here (the TTS player, the voice gateway, the token-estimation
	# timer), so child N and tab N diverge. Passing the tab index straight to
	# move_child() drops the chat somewhere among those nodes and leaves the tab
	# order unchanged. Translate through the TARGET tab's real child index, the
	# way TabContainer's own rearrange does.
	move_child(moving, target.get_index())
	_apply_tab_filters()
	_refresh_group_dock()


## Handle global input - ESC key triggers stop
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		var esc_history: ChatHistory = SingletonObject.ChatList[current_tab] if current_tab >= 0 and current_tab < SingletonObject.ChatList.size() else null
		if esc_history and esc_history.is_request_active:
			_on_audio_stop_1_pressed()
			get_viewport().set_input_as_handled()


# if a note is enabled/disabled recalculate the token cost
func _on_note_toggled(_note: Note, _on: bool):
	update_token_estimation()

# if a note is changed recalculate the token cost
func _on_note_changed(_note: Note,):
	update_token_estimation()

## Closing a chat tab soft-deletes it (DCR 01a017494904).
##
## Previously this handed the Control to Undo.gd's 180-second timer and called
## remove_child(), so undo was time-limited, pinned a live Control in memory,
## and was lost on restart. Now the chat stays in ChatList with Deleted = true
## and the filter hides it, which makes undo unlimited and save/load-durable.
func _on_close_tab(tab: int, closed_tab_container: TabContainer):
	self.control = closed_tab_container.get_tab_control(tab)
	self.container = closed_tab_container
	if tab < 0 or tab >= SingletonObject.ChatList.size():
		# Nothing to soft-delete (index out of step with ChatList) — fall back to
		# the old removal so a stray tab can still be closed.
		if self.control:
			closed_tab_container.remove_child(self.control)
		if get_tab_count() < 1:
			buffer_control_chats.show()
		return
	delete_chat(SingletonObject.ChatList[tab])

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
	# This pane (the tcChats TabContainer) holds the chat tabs AS its children, but
	# _ready() also parents lifetime-of-pane infrastructure here: the TTS player and
	# the always-listening voice gateway. Those are created ONCE in _ready and never
	# rebuilt, so freeing them on a chat wipe (which runs on New/Open/Load Project)
	# leaves voice TTS and wake-word listening silently dead for the rest of the
	# session. Wipe only the chat tabs; preserve the infrastructure nodes.
	for child in get_children():
		if child == _tts_player or child == _voice_gateway:
			continue
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
	%EditTitleDialog.set_meta("mode", "chat")
	%EditTitleDialog.set_meta("tab", tab)
	%EditTitleDialog.title = "Change Chat Title"
	%LineEdit.text = get_tab_title(tab)
	%LineEdit.select_all()
	%LineEdit.call_deferred("grab_focus")
	%EditTitleDialog.popup_centered()


func _on_edit_title_dialog_confirmed():
	# The dialog is shared with group renames; "mode" says which. Absent meta
	# means a chat retitle, so pre-existing callers keep working unchanged.
	if str(%EditTitleDialog.get_meta("mode", "chat")) == "group":
		var gid := str(%EditTitleDialog.get_meta("group_id", ""))
		var proposed: String = %LineEdit.text
		if not gid.is_empty() and rename_group(gid, proposed):
			_refresh_group_dock()
		return

	var tab = %EditTitleDialog.get_meta("tab")
	var new_name: String = %LineEdit.text
	if tab == null or int(tab) < 0 or int(tab) >= SingletonObject.ChatList.size():
		return
	set_tab_title(tab, new_name)
	var history: ChatHistory = SingletonObject.ChatList[tab]
	history.HistoryName = new_name
	_sync_agent_notes_tab_title(history)


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


func _on_compact_pressed() -> void:
	if SingletonObject.ChatList.is_empty():
		return
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	if await compact_chat(history):
		# Re-render the chat after compaction: clear VBox children and re-add from history
		if history.VBox:
			for child in history.VBox.get_children():
				if child != history.provider:
					child.queue_free()
			await get_tree().process_frame
			for item in history.HistoryItemList:
				history.VBox.add_history_item(item)
		_update_compact_button()
	else:
		SingletonObject.create_toast_notification(
			"Not enough messages to compact (need more than %d)" % (AGENT_KEEP_RECENT_MESSAGES + 1),
			ToastNotification.Type.INFO
		)


func open_ledger_browser() -> void:
	%LedgerBrowser.open(false)


func archive_current_chat() -> void:
	if SingletonObject.ChatList.is_empty():
		return
	var idx: int = current_tab
	if idx < 0 or idx >= SingletonObject.ChatList.size():
		return
	var history: ServiceHistory = SingletonObject.ChatList[idx]
	if history.Archived:
		history.Archived = false
		SingletonObject.create_toast_notification("Chat restored: %s" % history.HistoryName)
	else:
		history.Archived = true
		SingletonObject.create_toast_notification("Chat archived: %s" % history.HistoryName)
	_apply_archive_filter()


func set_show_archived(show_archived: bool) -> void:
	_showing_archived = show_archived
	_apply_archive_filter()


#region Chat groups + tab filtering (DCR 01a017494904)

## Emitted whenever group membership, the active group, or the deleted set
## changes — the dock re-renders from this rather than polling.
signal chat_groups_changed()

## Currently selected group VIEW. Either a ChatGroupRegistry sentinel
## (VIEW_ALL / VIEW_UNGROUPED / VIEW_DELETED) or a real group id.
var _active_group_id: String = ChatGroupRegistry.VIEW_ALL


func get_active_group_id() -> String:
	return _active_group_id


## Drop all per-project group state.
##
## MUST run whenever the project changes. The registry is replaced on load, but
## _active_group_id and the group-delete snapshot are NOT part of it, and a
## stale `grp_N` id survives into the next project: it either filters every chat
## out (the id is absent there) or — worse, because it looks like it worked —
## silently selects an UNRELATED group that happens to have been minted with the
## same ordinal. A carried-over undo snapshot can likewise recreate the previous
## project's group inside this one.
func reset_group_state() -> void:
	_active_group_id = ChatGroupRegistry.VIEW_ALL
	_last_dissolved_group = {}


## Select a group view and re-filter. Unknown ids fall back to All rather than
## stranding the user in a view that can never contain a tab.
func set_active_group(group_id: String) -> void:
	var target := group_id
	if not ChatGroupRegistry.is_view_sentinel(target) and not SingletonObject.chat_groups.has_group(target):
		target = ChatGroupRegistry.VIEW_ALL
	if target == _active_group_id:
		return
	_active_group_id = target
	_apply_tab_filters()
	chat_groups_changed.emit()


## The group a chat effectively belongs to. A ChatGroupId that no longer names a
## live group (project edited by hand, group pruned mid-flight) resolves to
## ungrouped instead of leaving the chat unreachable in every view.
func _effective_group_id(history: ServiceHistory) -> String:
	if history == null:
		return ChatGroupRegistry.UNGROUPED
	var gid := str(history.ChatGroupId)
	if gid.is_empty() or not SingletonObject.chat_groups.has_group(gid):
		return ChatGroupRegistry.UNGROUPED
	return gid


## The single visibility predicate. All THREE axes — group, archived, deleted —
## are combined in ChatGroupRegistry.should_show(), which is static and
## dependency-free so the full matrix is testable without a live pane.
func _tab_should_be_visible(history: ServiceHistory) -> bool:
	if history == null:
		return false
	return ChatGroupRegistry.should_show(
		_active_group_id,
		_effective_group_id(history),
		history.Archived,
		history.Deleted,
		_showing_archived
	)


## Apply the 3-axis filter to the tab strip.
##
## Filters by HIDING, never by reparenting: set_tab_hidden() drops a tab from
## the strip while its child stays in place, so the ChatList[i] <-> tab i
## coupling that 58 index sites and _on_child_order_changed() depend on
## survives untouched.
func _apply_tab_filters() -> void:
	var any_visible := false
	var current_is_visible := false
	var tab_count := get_tab_count()
	for i in range(SingletonObject.ChatList.size()):
		if i >= tab_count:
			break
		var visible_now := _tab_should_be_visible(SingletonObject.ChatList[i])
		set_tab_hidden(i, not visible_now)
		if visible_now:
			any_visible = true
			if i == current_tab:
				current_is_visible = true

	if not current_is_visible and any_visible:
		for i in range(tab_count):
			if not is_tab_hidden(i):
				current_tab = i
				break

	# The gap inherited from the old archive-only filter: when NOTHING is
	# visible the "switch to first visible" loop silently did nothing, leaving
	# the last chat's content on screen under an empty tab strip. An empty group
	# hits this immediately, so surface the buffer control instead.
	if buffer_control_chats:
		if any_visible:
			buffer_control_chats.hide()
		else:
			buffer_control_chats.show()

	_set_pane_empty_state(not any_visible)


## Show the whole tab container, or the empty-state placeholder instead.
##
## THE BUG THIS FIXES — reported as "making a group loses the chat": create a
## chat, create a group (which selects the new, empty group), then click All.
## The tab comes back but the pane under it is blank.
##
## Cause: when EVERY tab is hidden, `current_tab` still names one of them, and
## TabContainer keeps that control on screen — it does not consult the tab's
## hidden flag. So an empty group leaves the filtered-out chat rendering, and
## the container's own repaint then races the filter on the way back, resolving
## the contradiction by showing nothing.
##
## Trying to own child visibility directly loses that race: TabContainer
## re-shows the current tab's control right after. Hiding the CONTAINER is
## unambiguous, needs no cooperation from the engine's bookkeeping, and reuses
## the placeholder the pane already had for "no chats".
func _set_pane_empty_state(is_empty: bool) -> void:
	if buffer_control_chats:
		buffer_control_chats.visible = is_empty
	if _empty_group_label:
		_empty_group_label.visible = is_empty
		if is_empty:
			_empty_group_label.text = _empty_state_text()
	# Guard the self-hide: an invisible TabContainer stops laying out, so only
	# toggle when it actually changes.
	if visible == is_empty:
		visible = not is_empty


## What to say when the strip is empty — an empty GROUP is a very different
## situation from having no chats at all, and looking identical is what made
## this read as data loss.
func _empty_state_text() -> String:
	if SingletonObject.ChatList.is_empty():
		return ""
	if _active_group_id == ChatGroupRegistry.VIEW_DELETED:
		return "No deleted chats."
	if _active_group_id == ChatGroupRegistry.VIEW_UNGROUPED:
		return "Every chat is in a group.  ·  Pick All above to see them."
	if not ChatGroupRegistry.is_view_sentinel(_active_group_id):
		return "\"%s\" has no chats yet.\n\nDrag a chat tab onto its card to move it in, or pick All above." % SingletonObject.chat_groups.get_name(_active_group_id)
	if not _showing_archived:
		return "Every chat is archived.  ·  Turn on Show Archived to see them."
	return ""


## Back-compat alias. External callers (MainScene's ledger menu) and the
## deferred call in _ready still name the archive filter.
func _apply_archive_filter() -> void:
	_apply_tab_filters()


## Ids of groups still referenced by a LIVE chat. Deleted chats park their group
## in PreDeleteGroupId and so do not keep an empty group alive.
func _live_group_ids() -> Array:
	var ids: Array = []
	for history in SingletonObject.ChatList:
		if history == null or history.Deleted:
			continue
		var gid := str(history.ChatGroupId)
		if not gid.is_empty() and not ids.has(gid):
			ids.append(gid)
	return ids


## Drop groups whose last chat has left, then make sure the active view still
## points at something that exists.
func prune_empty_groups() -> void:
	var removed := SingletonObject.chat_groups.prune_empty(_live_group_ids())
	if removed.is_empty():
		return
	# Pruning changes the registry, which no ServiceHistory setter covers.
	SingletonObject.save_state(false)
	if removed.has(_active_group_id):
		_active_group_id = ChatGroupRegistry.VIEW_ALL
		_apply_tab_filters()


## Move a chat into a group ("" = ungrouped). Returns false if the id names no
## known group, so a caller cannot silently strand a chat.
func set_chat_group(history: ServiceHistory, group_id: String) -> bool:
	if history == null:
		return false
	if not group_id.is_empty() and not SingletonObject.chat_groups.has_group(group_id):
		return false
	if history.Deleted:
		# A deleted chat's membership lives in PreDeleteGroupId; writing
		# ChatGroupId here would resurrect an empty group.
		history.PreDeleteGroupId = group_id
	else:
		history.ChatGroupId = group_id
	if not group_id.is_empty():
		# Arms the group for implicit destruction. Until a chat has joined, a new
		# empty group is left alone so it can be filled by dragging.
		SingletonObject.chat_groups.mark_populated(group_id)
	prune_empty_groups()
	_apply_tab_filters()
	chat_groups_changed.emit()
	return true


func set_chat_group_by_index(tab_idx: int, group_id: String) -> bool:
	if tab_idx < 0 or tab_idx >= SingletonObject.ChatList.size():
		return false
	return set_chat_group(SingletonObject.ChatList[tab_idx], group_id)


func find_chat_by_id(history_id: String) -> ServiceHistory:
	for history in SingletonObject.ChatList:
		if history != null and str(history.HistoryId) == history_id:
			return history
	return null


## Create a group and select it. Optionally moves `history` in as its first
## member, which is what dropping a tab on the "+" card does.
func create_group(name: String = ChatGroupRegistry.DEFAULT_GROUP_NAME, history: ServiceHistory = null) -> String:
	var gid := SingletonObject.chat_groups.create_group(name)
	if history != null:
		set_chat_group(history, gid)
	set_active_group(gid)
	# The registry is not a ServiceHistory, so nothing auto-marks the project
	# dirty here. Without this an empty group — the one case deliberately kept
	# alive until explicitly deleted — is lost with no save prompt.
	SingletonObject.save_state(false)
	chat_groups_changed.emit()
	return gid


## Snapshot of the last group dissolved by delete_group(), so the destruction is
## undoable. Holds {id, name, chat_ids} — one group deep, which is what an
## accidental delete needs; older ones are recoverable by recreating and
## reassigning, and keeping a full stack would outlive the ids it references.
var _last_dissolved_group: Dictionary = {}


## Explicitly delete a group. Its chats are NOT deleted — they move to
## `reassign_to` ("" = ungrouped), which must name a real group if non-empty.
##
## Groups also die implicitly when their last chat leaves (prune_empty_groups);
## this is the deliberate version, for dissolving a group whose chats you want
## to keep. Undoable via undo_group_delete().
func delete_group(group_id: String, reassign_to: String = ChatGroupRegistry.UNGROUPED) -> Dictionary:
	if not SingletonObject.chat_groups.has_group(group_id):
		return {"ok": false, "error": "Unknown group: %s" % group_id}
	if not reassign_to.is_empty():
		if reassign_to == group_id:
			return {"ok": false, "error": "Cannot reassign a group's chats to itself"}
		if not SingletonObject.chat_groups.has_group(reassign_to):
			return {"ok": false, "error": "Unknown reassign target: %s" % reassign_to}

	var moved: Array[String] = []
	for history in SingletonObject.ChatList:
		if history == null:
			continue
		var touched := false
		# Deleted chats park their membership in PreDeleteGroupId; rewrite that
		# too, or restoring one later would resurrect a group that is gone. It
		# must ALSO be recorded — a chat whose only reference was the parked one
		# would otherwise never be reattached by undo.
		if str(history.PreDeleteGroupId) == group_id:
			history.PreDeleteGroupId = reassign_to
			touched = true
		if str(history.ChatGroupId) == group_id:
			history.ChatGroupId = reassign_to
			touched = true
		if touched:
			moved.append(str(history.HistoryId))

	_last_dissolved_group = {
		"id": group_id,
		"name": SingletonObject.chat_groups.get_name(group_id),
		"chat_ids": moved,
		# Undo must be able to tell "this chat is where the delete left it" from
		# "the user has since moved it somewhere else".
		"reassigned_to": reassign_to,
		"was_populated": SingletonObject.chat_groups.is_populated(group_id),
	}
	SingletonObject.chat_groups.remove_group(group_id)
	if _active_group_id == group_id:
		_active_group_id = ChatGroupRegistry.VIEW_ALL
	_apply_tab_filters()
	chat_groups_changed.emit()
	SingletonObject.save_state(false)
	return {"ok": true, "group_id": group_id, "reassigned_to": reassign_to, "chat_ids": moved}


## Which field currently holds a chat's group membership. A deleted chat's live
## ChatGroupId is cleared and its membership parked, so the authoritative field
## depends on the chat's state — and it can change between a delete_group() and
## its undo, if the chat is deleted or restored in between.
static func _membership_of(history: ServiceHistory) -> String:
	if history == null:
		return ""
	return str(history.PreDeleteGroupId) if history.Deleted else str(history.ChatGroupId)


static func _set_membership(history: ServiceHistory, group_id: String) -> void:
	if history == null:
		return
	if history.Deleted:
		history.PreDeleteGroupId = group_id
	else:
		history.ChatGroupId = group_id


## Undo the last delete_group(): recreate it with its original id and name, and
## put back the members that are still where the delete left them.
##
## A chat the user has moved elsewhere since the delete is LEFT ALONE — undoing
## a group must not silently yank chats out of wherever they now live. The test
## is whether the chat's current membership still equals the reassign target;
## that also covers chats deleted or restored in the interim, because
## _membership_of() follows the state change.
func undo_group_delete() -> Dictionary:
	if _last_dissolved_group.is_empty():
		return {"ok": false, "error": "No group deletion to undo"}

	var gid := str(_last_dissolved_group.get("id", ""))
	if SingletonObject.chat_groups.has_group(gid):
		# Something has re-minted this id. Keep the snapshot rather than
		# discarding it on a failed attempt.
		return {"ok": false, "error": "Group %s already exists" % gid}

	var snapshot: Dictionary = _last_dissolved_group.duplicate(true)
	_last_dissolved_group = {}
	var reassigned_to := str(snapshot.get("reassigned_to", ""))

	# forced_id keeps every chat's stored ChatGroupId meaningful without a
	# rewrite, which is the same reason chats store ids rather than names.
	var restored := SingletonObject.chat_groups.create_group(str(snapshot.get("name", "")), gid)

	var reattached: Array[String] = []
	var skipped: Array[String] = []
	for raw_id in snapshot.get("chat_ids", []):
		var history := find_chat_by_id(str(raw_id))
		if history == null:
			continue
		if _membership_of(history) != reassigned_to:
			skipped.append(str(raw_id))
			continue
		_set_membership(history, restored)
		reattached.append(str(raw_id))

	# Restore the prunable-or-not state rather than inferring it: a group that
	# was populated before the delete stays prunable even if every one of its
	# chats has since been moved away.
	if bool(snapshot.get("was_populated", not reattached.is_empty())):
		SingletonObject.chat_groups.mark_populated(restored)

	# A group that comes back with no members and WAS populated would be pruned
	# by the next sweep, so run one now rather than leaving a doomed card up.
	prune_empty_groups()
	_apply_tab_filters()
	chat_groups_changed.emit()
	SingletonObject.save_state(false)
	return {
		"ok": true,
		"group_id": restored,
		"name": SingletonObject.chat_groups.get_name(restored),
		"chat_ids": reattached,
		"skipped_chat_ids": skipped,
	}


func can_undo_group_delete() -> bool:
	return not _last_dissolved_group.is_empty()


func rename_group(group_id: String, name: String) -> bool:
	if not SingletonObject.chat_groups.rename_group(group_id, name):
		return false
	SingletonObject.save_state(false)
	chat_groups_changed.emit()
	return true


## Live (non-deleted, non-archived-unless-shown) chat count for a group card.
func count_in_group(group_id: String) -> int:
	var n := 0
	for history in SingletonObject.ChatList:
		if history == null:
			continue
		if group_id == ChatGroupRegistry.VIEW_DELETED:
			if history.Deleted:
				n += 1
			continue
		if history.Deleted:
			continue
		if history.Archived and not _showing_archived:
			continue
		if group_id == ChatGroupRegistry.VIEW_ALL:
			n += 1
		elif group_id == ChatGroupRegistry.VIEW_UNGROUPED:
			if _effective_group_id(history) == ChatGroupRegistry.UNGROUPED:
				n += 1
		elif _effective_group_id(history) == group_id:
			n += 1
	return n


## Group a newly created chat should land in.
##
## Without this, creating a chat while a group is selected drops it into
## Ungrouped and the filter hides it instantly — the chat looks like it never
## appeared. Matters most for agent-spawned chats, which the user did not
## initiate and would not think to go looking for.
func default_group_for_new_chat() -> String:
	if ChatGroupRegistry.is_view_sentinel(_active_group_id):
		return ChatGroupRegistry.UNGROUPED
	return _active_group_id


#region Delete-as-state

## Soft-delete a chat: hide it and park its group, rather than removing the tab.
##
## Nothing leaves ChatList, so _on_child_order_changed() has nothing to rebuild
## and every index stays valid. Undo is therefore unlimited in time and survives
## save/load, because the state serialises with the chat like Archived does.
func delete_chat(history: ServiceHistory) -> bool:
	if history == null or history.Deleted:
		return false
	history.PreDeleteGroupId = str(history.ChatGroupId)
	history.ChatGroupId = ChatGroupRegistry.UNGROUPED
	history.DeletedAt = int(Time.get_unix_time_from_system())
	history.DeletedSeq = _next_delete_seq()
	history.Deleted = true
	prune_empty_groups()
	_apply_tab_filters()
	chat_groups_changed.emit()
	SingletonObject.create_toast_notification("Chat deleted: %s (restore from the Deleted group)" % history.HistoryName)
	return true


## Restore a soft-deleted chat to the group it came from, or to Ungrouped if
## that group has since been pruned.
func restore_chat(history: ServiceHistory) -> bool:
	if history == null or not history.Deleted:
		return false
	var target := str(history.PreDeleteGroupId)
	if not target.is_empty() and not SingletonObject.chat_groups.has_group(target):
		target = ChatGroupRegistry.UNGROUPED
	history.Deleted = false
	history.DeletedAt = 0
	history.DeletedSeq = 0
	history.ChatGroupId = target
	history.PreDeleteGroupId = ""
	_apply_tab_filters()
	chat_groups_changed.emit()
	SingletonObject.create_toast_notification("Chat restored: %s" % history.HistoryName)
	# Bring the restored chat back on screen.
	var idx := SingletonObject.ChatList.find(history)
	if idx >= 0 and idx < get_tab_count() and not is_tab_hidden(idx):
		current_tab = idx
	return true


## Next monotonic deletion sequence number.
##
## Derived from the live set rather than a member counter so it survives project
## load without a separate restore step: whatever the highest stored sequence
## is, the next delete beats it.
func _next_delete_seq() -> int:
	var highest := 0
	for history in SingletonObject.ChatList:
		if history != null and int(history.DeletedSeq) > highest:
			highest = int(history.DeletedSeq)
	return highest + 1


## Most-recently-deleted chat first — what Ctrl+Z restores.
##
## Ordered by DeletedSeq, NOT DeletedAt: two chats closed in the same second
## share a timestamp, and an untied sort then picks an arbitrary one. HistoryId
## breaks any residual tie (chats deleted before DeletedSeq existed all carry 0)
## so the order is at least stable rather than sort-implementation-defined.
func list_deleted_chats() -> Array[ServiceHistory]:
	var out: Array[ServiceHistory] = []
	for history in SingletonObject.ChatList:
		if history != null and history.Deleted:
			out.append(history)
	out.sort_custom(func(a, b):
		var sa := int(a.DeletedSeq)
		var sb := int(b.DeletedSeq)
		if sa != sb:
			return sa > sb
		var ta := int(a.DeletedAt)
		var tb := int(b.DeletedAt)
		if ta != tb:
			return ta > tb
		return str(a.HistoryId) > str(b.HistoryId)
	)
	return out


func restore_last_deleted_chat() -> bool:
	var deleted := list_deleted_chats()
	if deleted.is_empty():
		return false
	return restore_chat(deleted[0])


## Permanently drop soft-deleted chats.
##
## NOTHING is purged automatically: a deleted chat keeps its full
## HistoryItemList, so the Deleted group grows the .minproj without bound, but
## silently discarding a user's chat is the worse failure. Purging is an
## explicit action; `older_than_days` < 0 empties the whole Deleted group.
## Returns the number of chats freed.
func purge_deleted_chats(older_than_days: int = -1) -> int:
	var cutoff := 0
	if older_than_days >= 0:
		cutoff = int(Time.get_unix_time_from_system()) - older_than_days * 86400
	var doomed: Array[ServiceHistory] = []
	for history in SingletonObject.ChatList:
		if history == null or not history.Deleted:
			continue
		if older_than_days < 0 or int(history.DeletedAt) <= cutoff:
			doomed.append(history)
	if doomed.is_empty():
		return 0
	# Remove the tab controls back-to-front so the indices of the not-yet-removed
	# entries stay valid; _on_child_order_changed then rebuilds ChatList from
	# what is left.
	var indices: Array[int] = []
	for history in doomed:
		var idx := SingletonObject.ChatList.find(history)
		if idx >= 0:
			indices.append(idx)
	indices.sort()
	indices.reverse()
	for idx in indices:
		if idx < get_tab_count():
			var tab_control := get_tab_control(idx)
			if tab_control:
				remove_child(tab_control)
				tab_control.queue_free()
	prune_empty_groups()
	_apply_tab_filters()
	chat_groups_changed.emit()
	SingletonObject.save_state(false)
	return doomed.size()

#endregion Delete-as-state


#region Group dock

const ChatGroupDockScript = preload("res://Scripts/UI/Controls/ChatGroupDock/ChatGroupDock.gd")
const ChatGroupCardScript = preload("res://Scripts/UI/Controls/ChatGroupDock/ChatGroupCard.gd")

var _group_dock: ChatGroupDock = null
## Placeholder shown in place of the tab strip when the active filter matches
## nothing. Explains WHY it is empty; a blank pane reads as lost data.
var _empty_group_label: Label = null


## Mount the dock directly above the tab strip, inside the chats pane.
##
## Built in code rather than in Chat.tscn so the dock has no scene-order
## coupling: it is inserted at this TabContainer's own index in its parent, so
## it lands above the tabs wherever the pane is placed.
func _ensure_group_dock() -> void:
	if is_instance_valid(_group_dock):
		return
	var host := get_parent()
	if host == null:
		return
	_group_dock = ChatGroupDockScript.new()
	_group_dock.name = "ChatGroupDock"
	host.add_child(_group_dock)
	host.move_child(_group_dock, get_index())

	_empty_group_label = Label.new()
	_empty_group_label.name = "ChatGroupEmptyState"
	_empty_group_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_group_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_group_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_group_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_empty_group_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty_group_label.add_theme_color_override("font_color", Color("#8fb2bc"))
	_empty_group_label.visible = false
	host.add_child(_empty_group_label)
	host.move_child(_empty_group_label, get_index() + 1)

	_group_dock.group_selected.connect(_on_dock_group_selected)
	_group_dock.group_rename_requested.connect(_on_dock_group_rename_requested)
	_group_dock.chat_dropped_on_group.connect(_on_dock_chat_dropped)
	_group_dock.create_group_requested.connect(_on_dock_create_group_requested)
	_group_dock.card_context_menu_requested.connect(_on_dock_card_context_menu)

	apply_default_dock_state()

	if not chat_groups_changed.is_connected(_refresh_group_dock):
		chat_groups_changed.connect(_refresh_group_dock)
	if not SingletonObject.chat_groups.groups_changed.is_connected(_refresh_group_dock):
		SingletonObject.chat_groups.groups_changed.connect(_refresh_group_dock)

	_refresh_group_dock()


func get_group_dock() -> ChatGroupDock:
	return _group_dock


## Set the dock's collapse state to suit the project that just opened.
##
## A project with no groups gets a COLLAPSED dock: the owner runs 1-3 chats most
## of the time and wants no grouping chrome at all then, so 68px of a 545px pane
## should not be spent advertising a feature nothing is using. A project that
## HAS groups opens expanded, because the groups are the navigation.
##
## Called only at project-open boundaries, never on refresh — otherwise it would
## keep overriding a collapse the user performed by hand.
func apply_default_dock_state() -> void:
	if not is_instance_valid(_group_dock):
		return
	_group_dock.set_collapsed(SingletonObject.chat_groups.size() == 0)


## Build the card row: All, Ungrouped (only when non-empty), every group in
## creation order, Deleted (only when non-empty), then "+".
##
## Ungrouped and Deleted are hidden while empty so the common case — a few
## chats, no groups — costs no horizontal room beyond "All" and "+".
func build_group_card_snapshot() -> Array[Dictionary]:
	var cards: Array[Dictionary] = []
	cards.append({
		"kind": ChatGroupCardScript.Kind.ALL,
		"id": ChatGroupRegistry.VIEW_ALL,
		"name": "All",
		"color": ChatGroupRegistry.NEUTRAL_COLOR,
		"count": count_in_group(ChatGroupRegistry.VIEW_ALL),
	})

	var ungrouped_count := count_in_group(ChatGroupRegistry.VIEW_UNGROUPED)
	if ungrouped_count > 0 and SingletonObject.chat_groups.size() > 0:
		cards.append({
			"kind": ChatGroupCardScript.Kind.UNGROUPED,
			"id": ChatGroupRegistry.VIEW_UNGROUPED,
			"name": "Ungrouped",
			"color": ChatGroupRegistry.NEUTRAL_COLOR,
			"count": ungrouped_count,
		})

	for g in SingletonObject.chat_groups.list_groups():
		cards.append({
			"kind": ChatGroupCardScript.Kind.GROUP,
			"id": str(g["id"]),
			"name": str(g["name"]),
			"color": g["color"],
			"count": count_in_group(str(g["id"])),
		})

	var deleted_count := count_in_group(ChatGroupRegistry.VIEW_DELETED)
	if deleted_count > 0:
		cards.append({
			"kind": ChatGroupCardScript.Kind.DELETED,
			"id": ChatGroupRegistry.VIEW_DELETED,
			"name": "Deleted",
			"color": Color("#ff7a7a"),
			"count": deleted_count,
		})

	cards.append({
		"kind": ChatGroupCardScript.Kind.ADD,
		"id": ChatGroupDockScript.ADD_CARD_ID,
		"name": "+",
		"color": ChatGroupRegistry.NEUTRAL_COLOR,
		"count": 0,
	})
	return cards


func _refresh_group_dock() -> void:
	if not is_instance_valid(_group_dock):
		return
	_group_dock.render_cards(build_group_card_snapshot(), _active_group_id)


func _on_dock_group_selected(group_id: String) -> void:
	set_active_group(group_id)
	_refresh_group_dock()


func _on_dock_group_rename_requested(group_id: String) -> void:
	show_group_rename_dialog(group_id)


func _on_dock_chat_dropped(group_id: String, chat_id: String) -> void:
	var history := find_chat_by_id(chat_id)
	if history == null:
		return
	var target := group_id
	if target == ChatGroupRegistry.VIEW_UNGROUPED:
		target = ChatGroupRegistry.UNGROUPED
	if set_chat_group(history, target):
		var label := SingletonObject.chat_groups.get_name(target)
		SingletonObject.create_toast_notification(
			"Moved \"%s\" to %s" % [history.HistoryName, label if not label.is_empty() else "Ungrouped"]
		)
	_refresh_group_dock()


## "+" pressed, or a chat dropped on it. A dropped chat becomes the new group's
## first member and the rename editor opens immediately, so naming is the next
## keystroke rather than a separate act.
func _on_dock_create_group_requested(chat_id: String) -> void:
	var history := find_chat_by_id(chat_id) if not chat_id.is_empty() else null
	var gid := create_group(ChatGroupRegistry.DEFAULT_GROUP_NAME, history)
	_refresh_group_dock()
	show_group_rename_dialog(gid)


## Right-click menu for a dock card. The pane builds it because the available
## actions depend on pane state the card cannot see (whether a group delete is
## waiting to be undone).
var _card_menu: PopupMenu = null
var _card_menu_group_id: String = ""

const _CARD_MENU_RENAME := 1
const _CARD_MENU_DELETE := 2
const _CARD_MENU_UNDO_DELETE := 3
const _CARD_MENU_PURGE := 4


func _on_dock_card_context_menu(group_id: String, kind: int) -> void:
	_card_menu_group_id = group_id
	if _card_menu == null:
		_card_menu = PopupMenu.new()
		_card_menu.id_pressed.connect(_on_card_menu_selected)
		add_child(_card_menu)
	_card_menu.clear()

	if kind == ChatGroupCardScript.Kind.GROUP:
		_card_menu.add_item("Rename group…", _CARD_MENU_RENAME)
		_card_menu.add_item("Delete group (keeps its chats)", _CARD_MENU_DELETE)
	elif kind == ChatGroupCardScript.Kind.DELETED:
		_card_menu.add_item("Empty Deleted — permanent", _CARD_MENU_PURGE)

	if can_undo_group_delete():
		if _card_menu.item_count > 0:
			_card_menu.add_separator()
		_card_menu.add_item("Undo group delete", _CARD_MENU_UNDO_DELETE)

	if _card_menu.item_count == 0:
		return
	_card_menu.popup(Rect2i(get_viewport().get_mouse_position(), Vector2i.ZERO))


func _on_card_menu_selected(id: int) -> void:
	match id:
		_CARD_MENU_RENAME:
			show_group_rename_dialog(_card_menu_group_id)
		_CARD_MENU_DELETE:
			var group_name := SingletonObject.chat_groups.get_name(_card_menu_group_id)
			var res := delete_group(_card_menu_group_id, ChatGroupRegistry.UNGROUPED)
			if bool(res.get("ok", false)):
				SingletonObject.create_toast_notification(
					"Group deleted: %s — its chats are now ungrouped (right-click to undo)" % group_name
				)
		_CARD_MENU_UNDO_DELETE:
			var undone := undo_group_delete()
			if bool(undone.get("ok", false)):
				SingletonObject.create_toast_notification("Group restored: %s" % str(undone.get("name", "")))
		_CARD_MENU_PURGE:
			var n := purge_deleted_chats(-1)
			if n > 0:
				SingletonObject.create_toast_notification("Purged %d deleted chat%s — permanently" % [n, "" if n == 1 else "s"])
	_refresh_group_dock()


## Reuse %EditTitleDialog for group renames. The dialog carries a "mode" meta so
## the shared confirm handler knows whether it is retitling a chat or a group.
func show_group_rename_dialog(group_id: String) -> void:
	%EditTitleDialog.set_meta("mode", "group")
	%EditTitleDialog.set_meta("group_id", group_id)
	%EditTitleDialog.title = "Rename Group"
	%LineEdit.text = SingletonObject.chat_groups.get_name(group_id)
	%LineEdit.select_all()
	%LineEdit.call_deferred("grab_focus")
	%EditTitleDialog.popup_centered()

#endregion Group dock


#region Chat-tab drag source

## Drag payload for a chat tab. Carries HistoryId, NEVER the tab index — indices
## shift as the filter hides and shows tabs, so an index would move a different
## chat than the one the user picked up.
func _get_chat_tab_drag_data(at_position: Vector2) -> Variant:
	var tab := get_tab_bar().get_tab_idx_at_point(at_position)
	if tab < 0 or tab >= SingletonObject.ChatList.size():
		return null
	var history: ServiceHistory = SingletonObject.ChatList[tab]
	if history == null:
		return null

	var preview := Label.new()
	preview.text = get_tab_title(tab)
	preview.add_theme_color_override("font_color", Color("#eaf6ff"))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#1e2024")
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", sb)
	wrap.add_child(preview)
	set_drag_preview(wrap)

	return {"kind": "chat_tab", "chat_id": str(history.HistoryId), "tab": tab}

#endregion Chat-tab drag source


#region Tab context menu

var _tab_context_menu: PopupMenu = null
## Menu item id -> group id for the current popup. Rebuilt on every open, since
## groups come and go.
var _tab_menu_targets: Dictionary = {}
var _tab_menu_chat_id: String = ""

const _TAB_MENU_NEW_GROUP := 9000
const _TAB_MENU_DELETE := 9001
const _TAB_MENU_RESTORE := 9002


func _on_tab_rmb_clicked(tab: int) -> void:
	if tab < 0 or tab >= SingletonObject.ChatList.size():
		return
	var history: ServiceHistory = SingletonObject.ChatList[tab]
	if history == null:
		return
	_tab_menu_chat_id = str(history.HistoryId)

	if _tab_context_menu == null:
		_tab_context_menu = PopupMenu.new()
		_tab_context_menu.id_pressed.connect(_on_tab_menu_selected)
		add_child(_tab_context_menu)

	_tab_context_menu.clear()
	_tab_menu_targets.clear()

	var current := _effective_group_id(history)
	var next_id := 0
	_tab_context_menu.add_radio_check_item("Ungrouped", next_id)
	_tab_context_menu.set_item_checked(_tab_context_menu.get_item_index(next_id), current == ChatGroupRegistry.UNGROUPED)
	_tab_menu_targets[next_id] = ChatGroupRegistry.UNGROUPED
	next_id += 1

	for g in SingletonObject.chat_groups.list_groups():
		var gid := str(g["id"])
		_tab_context_menu.add_radio_check_item(str(g["name"]), next_id)
		_tab_context_menu.set_item_checked(_tab_context_menu.get_item_index(next_id), current == gid)
		_tab_menu_targets[next_id] = gid
		next_id += 1

	_tab_context_menu.add_separator()
	_tab_context_menu.add_item("New group with this chat…", _TAB_MENU_NEW_GROUP)
	_tab_context_menu.add_separator()
	if history.Deleted:
		_tab_context_menu.add_item("Restore chat", _TAB_MENU_RESTORE)
	else:
		_tab_context_menu.add_item("Delete chat", _TAB_MENU_DELETE)

	_tab_context_menu.popup(Rect2i(get_viewport().get_mouse_position(), Vector2i.ZERO))


func _on_tab_menu_selected(id: int) -> void:
	var history := find_chat_by_id(_tab_menu_chat_id)
	if history == null:
		return
	match id:
		_TAB_MENU_NEW_GROUP:
			_on_dock_create_group_requested(_tab_menu_chat_id)
		_TAB_MENU_DELETE:
			delete_chat(history)
		_TAB_MENU_RESTORE:
			restore_chat(history)
		_:
			if _tab_menu_targets.has(id):
				set_chat_group(history, str(_tab_menu_targets[id]))
	_refresh_group_dock()

#endregion Tab context menu


#endregion Chat groups + tab filtering



## Update stop button state based on current tab's active request status.
func _update_stop_button() -> void:
	if current_tab >= 0 and current_tab < SingletonObject.ChatList.size():
		var h: ChatHistory = SingletonObject.ChatList[current_tab]
		audio_stop_1.disabled = not h.is_request_active
	else:
		audio_stop_1.disabled = true


func _update_compact_button() -> void:
	if not _compact_button:
		return
	if SingletonObject.ChatList.is_empty():
		_compact_button.disabled = true
		return
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	var threshold = history.AgentSummarizeThreshold if history.AgentSummarizeThreshold > 0 else AGENT_SUMMARIZE_THRESHOLD
	var estimated = estimate_agent_context_size(history) if not history.HistoryItemList.is_empty() else 0
	_compact_button.disabled = (history.HistoryItemList.size() <= AGENT_KEEP_RECENT_MESSAGES + 1)
	if estimated > 0:
		_compact_button.tooltip_text = "Compact chat (~%d tokens, threshold: %d)" % [estimated, threshold]


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
		# Eagerly create agent-notes tab so it's visible immediately
		_get_agent_notes_tab(history)
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
		if _token_estimation_timer != null:
			_token_estimation_timer.stop()
		return
	# Restart debounce timer - actual estimation runs after 300ms of no typing
	if _token_estimation_timer != null:
		_token_estimation_timer.start()

func _on_txt_main_user_input_text_set():
	# Direct call for programmatic text setting (not continuous typing)
	update_token_estimation()

## Called when debounce timer expires - actually run the expensive token estimation
func _on_token_estimation_timer_timeout():
	update_token_estimation()

func _on_btn_microphone_pressed():
	var req := AudioToTexts.PTTRequest.new()
	req.target = %txtMainUserInput
	req.mic_button = %btnMicrophone
	req.stop_button = %AudioStop1
	req.voice_gateway = _voice_gateway
	var err: int = SingletonObject.AtT.start_ptt(req)
	if err != OK:
		push_warning("ChatPane PTT failed: %s" % error_string(err))


## After transcription completes, auto-send if configured in Voice Preferences.
func _on_voice_transcription_completed(text: String) -> void:
	SingletonObject.AtT.stop_ptt()

	if text.is_empty():
		return

	var cfg := SingletonObject.get_voice_config()
	if cfg.auto_send_transcription:
		_on_send_message_button_item_selected(0)


## Create a voice status label placed outside the collapsible area so it remains visible when collapsed.
func _create_voice_status_label(msg_node: Control) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.selection_enabled = true
	label.fit_content = true
	label.scroll_active = false
	# Dark muted color readable against green model-message background
	label.add_theme_color_override("default_color", Color(0.2, 0.25, 0.2, 0.7))
	label.add_theme_font_size_override("normal_font_size", 12)
	# Place in the main VBox (parent of ResizeScrollContainer) so it stays visible when collapsed
	var scroll: ScrollContainer = msg_node.find_child("ResizeScrollContainer", true, false)
	if scroll and scroll.get_parent():
		var vbox: VBoxContainer = scroll.get_parent()
		vbox.add_child(label)
		vbox.move_child(label, scroll.get_index() + 1)
	else:
		msg_node.add_child(label)
	return label


## Speak the assistant's response via TTS based on Voice Preferences speak mode.
## Serialized: only one TTS at a time. New requests cancel the pending one.
var _tts_busy := false
var _tts_cancel := false


## Cancel any in-flight TTS (synthesis or playback). Non-blocking.
## Public entry so PTT surfaces can call it before binding the mic — ending
## output playback before mic capture starts avoids the audio-driver duplex-entry
## race that leaves mic streams zombied until app restart.
##
## Sets _tts_cancel so in-flight _voice_speak_response bails at its next checkpoint,
## and stops the player immediately if playing. The flag stays set until the NEXT
## _voice_speak_response clears it on entry — that ensures a slow synthesize_auto
## WebSocket round-trip still sees the cancel when it wakes up.
## Only cancels CURRENT work; future TTS requests play normally.
func cancel_tts() -> void:
	if _tts_busy:
		_tts_cancel = true
	if _tts_player:
		_tts_player.stop()  # no-op if not playing; fires finished → _tts_busy = false


## Dismiss a status label with a terminal message; auto-free after hold_seconds.
## Safe to call with null or freed labels. Fire-and-forget.
func _dismiss_status_label(label: RichTextLabel, final_text: String, hold_seconds: float = 2.0) -> void:
	if not is_instance_valid(label):
		return
	label.text = final_text
	var timer := get_tree().create_timer(hold_seconds)
	timer.timeout.connect(func():
		if is_instance_valid(label):
			label.queue_free()
	, CONNECT_ONE_SHOT)

func _voice_speak_response(response_text: String, user_text: String = "", msg_node: Control = null) -> void:
	var cfg := SingletonObject.get_voice_config()
	if cfg.speak_mode == VoiceConfig.SpeakMode.OFF:
		_voice_on_response_complete()
		return

	var effective_tts := cfg.get_effective_tts_provider()
	if effective_tts == VoiceConfig.TTSProvider.NONE:
		_voice_on_response_complete()
		return

	# Cancel any in-flight TTS and wait for it to finish
	if _tts_busy:
		print("[ChatPane] TTS busy — cancelling previous, queuing new")
		_tts_cancel = true
		while _tts_busy:
			await get_tree().create_timer(0.1).timeout
	# Always clear — handles external cancel_tts() that left the flag set.
	# Without this, a slow-synth cancel by PTT would stick the flag and silently
	# suppress every future summary.
	_tts_cancel = false

	_tts_busy = true

	# Create inline status label on the message node
	var status_label: RichTextLabel = null
	if msg_node:
		status_label = _create_voice_status_label(msg_node)

	var text_to_speak := response_text
	if cfg.speak_mode == VoiceConfig.SpeakMode.SUMMARIZE:
		if cfg.summary_model.is_empty():
			push_warning("[ChatPane] Summarize mode active but no summary model configured")
			_dismiss_status_label(status_label, "Voice: No summary model configured", 3.0)
			_tts_busy = false
			return
		if status_label:
			status_label.text = "Voice: Summarizing via %s..." % cfg.summary_model
		print("[ChatPane] TTS: summarizing via %s..." % cfg.summary_model)
		var client := SingletonObject.get_voice_client()
		text_to_speak = await client.summarize_for_speech(user_text, response_text, cfg.summary_model, cfg.summary_timeout)
		if _tts_cancel:
			print("[ChatPane] TTS: cancelled after summarize")
			_dismiss_status_label(status_label, "Voice: cancelled", 1.5)
			_tts_busy = false
			return
		print("[ChatPane] TTS: summary ready: %s" % text_to_speak.substr(0, 80))

	if status_label:
		status_label.text = "Voice: Synthesizing speech..."
	print("[ChatPane] TTS: synthesizing %d chars..." % text_to_speak.length())
	var voice_client := SingletonObject.get_voice_client()
	var wav_data: PackedByteArray = await voice_client.synthesize_auto(text_to_speak, cfg)

	if _tts_cancel:
		print("[ChatPane] TTS: cancelled after synthesize")
		_dismiss_status_label(status_label, "Voice: cancelled", 1.5)
		_tts_busy = false
		return

	if wav_data.is_empty():
		print("[ChatPane] TTS: synthesis returned empty audio!")
		_dismiss_status_label(status_label, "Voice: TTS synthesis failed", 3.0)
		_tts_busy = false
		_voice_on_response_complete()
		return

	print("[ChatPane] TTS: got %d bytes, playing..." % wav_data.size())

	# The synthesize await above is a real network round-trip; during it the pane
	# (and its child _tts_player) can be torn down by a project reload / tab close.
	# Bail out rather than assign .stream on a freed node.
	if not is_instance_valid(_tts_player):
		print("[ChatPane] TTS: player freed during synthesis, aborting playback")
		_tts_busy = false
		return

	# Collapse after successful synthesis — only in summarize mode
	if cfg.speak_mode == VoiceConfig.SpeakMode.SUMMARIZE:
		if is_instance_valid(msg_node) and msg_node is MessageMarkdown and msg_node._expanded:
			msg_node._expanded = false
			msg_node.contract_message()

	var stream := AudioStreamWAV.new()
	VoiceServiceClient.load_audio_into_stream(stream, wav_data)
	_tts_player.stream = stream
	_tts_player.volume_db = linear_to_db(cfg.tts_volume)
	_tts_player.play()
	# Notify gateway: TTS playing (barge-in detection active)
	if _voice_gateway:
		_voice_gateway.notify_tts_started()

	# Release TTS busy flag and voice conversation gate when playback finishes
	_tts_player.finished.connect(func():
		_tts_busy = false
		_voice_on_response_complete()
	, CONNECT_ONE_SHOT)

	if status_label:
		if cfg.speak_mode == VoiceConfig.SpeakMode.SUMMARIZE:
			status_label.text = "Voice: %s" % text_to_speak
		else:
			status_label.text = "Voice: Speaking..."
		_tts_player.finished.connect(func():
			if cfg.speak_mode == VoiceConfig.SpeakMode.SUMMARIZE:
				status_label.text = "Voice: %s" % text_to_speak
			else:
				status_label.queue_free()
		, CONNECT_ONE_SHOT)


## Load raw WAV bytes into an AudioStreamWAV resource.

## Toggle always-listening mode via CheckButton
func _on_engagement_toggle_changed(enabled: bool) -> void:
	var cfg := SingletonObject.get_voice_config()
	if enabled:
		# Ensure voice gateway container is running
		var manager: RefCounted = SingletonObject.get_docker_manager()
		if manager.is_available():
			var defs: Array = manager.get_definitions()
			for def in defs:
				if def.image_name == "minerva-voice-gateway":
					if not manager.is_running(def):
						if manager.is_image_built(def):
							manager.start_container(def)
						else:
							push_warning("[ChatPane] Voice gateway image not built")
							_engagement_toggle.set_pressed_no_signal(false)
							return
					break
		cfg.always_listening = true
		cfg.save()
		start_voice_gateway()
		# Pre-warm gpu-node: load STT/TTS/LLM models to eliminate cold start
		var voice_client := SingletonObject.get_voice_client()
		voice_client.pre_warm()
		_gpu_pre_warmed = true
	else:
		cfg.always_listening = false
		cfg.save()
		stop_voice_gateway()


## Voice gateway: connection state
func _on_gateway_connected() -> void:
	if _engagement_state_label:
		_engagement_state_label.text = "STANDBY"
		_engagement_state_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))


func _on_gateway_disconnected() -> void:
	if _engagement_state_label:
		_engagement_state_label.text = "No Gateway"
		_engagement_state_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))


## Voice gateway: failed to connect after max retries
func _on_gateway_start_failed(reason: String) -> void:
	push_warning("[ChatPane] Voice gateway failed: %s" % reason)
	if _engagement_state_label:
		_engagement_state_label.text = "Failed"
		_engagement_state_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
	SingletonObject.create_toast_notification(
		"Voice gateway failed: %s" % reason, ToastNotification.Type.ERROR)
	_engagement_toggle.set_pressed_no_signal(false)
	var cfg := SingletonObject.get_voice_config()
	cfg.always_listening = false
	cfg.save()
	stop_voice_gateway()


## Voice gateway: engagement state changed
func _on_engagement_changed(state: String) -> void:
	if _engagement_state_label:
		_engagement_state_label.text = state
		if state == "ENGAGED":
			_engagement_state_label.add_theme_color_override("font_color", Color(0.2, 0.9, 0.2))
		else:
			_engagement_state_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))


## Voice gateway: VAD-endpointed audio ready for STT
func _on_gateway_transcription_ready(audio_wav: PackedByteArray) -> void:
	if audio_wav.is_empty():
		return

	_lazy_pre_warm()

	var cfg := SingletonObject.get_voice_config()
	var client := SingletonObject.get_voice_client()

	# Send to STT
	var text: String = await client.transcribe_auto(audio_wav, cfg)
	if text.is_empty():
		return

	# T6: Check for dismiss phrase
	if _voice_gateway and _voice_gateway.check_dismiss_phrase(text):
		return  # "stop listening" — don't send to chat

	print("[ChatPane] Voice transcription: '%s' (llm_busy=%s)" % [text, _voice_llm_busy])

	# Queue utterance — only send when LLM is idle (one utterance → one response)
	if _voice_llm_busy:
		_voice_utterance_queue.append(text)
		print("[ChatPane] Queued utterance (%d in queue)" % _voice_utterance_queue.size())
		return

	_voice_send_utterance(text)


func _voice_send_utterance(text: String) -> void:
	_voice_llm_busy = true
	%txtMainUserInput.text = text
	_on_send_message_button_item_selected(0)


func _voice_on_response_complete() -> void:
	"""Call after LLM response + TTS playback complete to process next queued utterance."""
	_voice_llm_busy = false
	if _voice_utterance_queue.size() > 0:
		var next_text: String = _voice_utterance_queue.pop_front()
		print("[ChatPane] Dequeuing utterance: '%s'" % next_text)
		_voice_send_utterance(next_text)


## TTS playback finished — notify gateway for idle timer
func _on_tts_playback_finished() -> void:
	if _voice_gateway:
		_voice_gateway.notify_tts_finished()


## Start the voice gateway (called when always-listening is enabled)
func start_voice_gateway() -> void:
	if _voice_gateway:
		if _engagement_state_label:
			_engagement_state_label.text = "Connecting..."
			_engagement_state_label.add_theme_color_override("font_color", Color(0.9, 0.7, 0.2))
		_voice_gateway.start()
		print("[ChatPane] Voice gateway started")


func _auto_start_voice() -> void:
	# Ensure gateway container is running on auto-start
	var manager: RefCounted = SingletonObject.get_docker_manager()
	if manager.is_available():
		var defs: Array = manager.get_definitions()
		for def in defs:
			if def.image_name == "minerva-voice-gateway":
				if not manager.is_running(def):
					if manager.is_image_built(def):
						manager.start_container(def)
					else:
						push_warning("[ChatPane] Voice gateway image not built — skipping auto-start")
						_engagement_toggle.set_pressed_no_signal(false)
						if _engagement_state_label:
							_engagement_state_label.text = "Not Built"
							_engagement_state_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
						return
				break
	start_voice_gateway()


## Lazy GPU pre-warm: reserves GPU on first voice interaction, not at startup.
func _lazy_pre_warm() -> void:
	if _gpu_pre_warmed:
		return
	_gpu_pre_warmed = true
	if not Core.client._connected:
		_gpu_pre_warmed = false
		return
	await Core.fetch_services(true)
	var voice_client := SingletonObject.get_voice_client()
	voice_client.pre_warm()


## Stop the voice gateway
func stop_voice_gateway() -> void:
	if _voice_gateway:
		_voice_gateway.stop()
		if _engagement_state_label:
			_engagement_state_label.text = "Voice Off"
			_engagement_state_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		print("[ChatPane] Voice gateway stopped")


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

	# Passthrough chats are contractually bound to their terminal provider —
	# the chooser is locked in the UI, and this guard backstops every other
	# selection route (keyboard, programmatic select, late signals).
	var bound_key: String = history.provider.entry_key if history.provider is PluginProvider else ""
	if history.PassthroughMode and not (provider_ is PluginProvider and provider_.entry_key == bound_key):
		sync_provider_picker_to_chat(history.HistoryId)
		return

	history.provider = provider_
	if not provider_.is_inside_tree():
		history.VBox.add_child(provider_)

	# If provider requires a default system prompt and none is set, add it
	# This makes it visible in the chat settings so the user can see/edit it
	if provider_.requires_default_system_prompt and not history.HasUsedSystemPrompt:
		add_new_system_prompt_item(provider_.default_system_prompt)
		print("[Chat] Added default system prompt for %s" % provider_.model_name)

	history.VBox.add_program_message("Changed provider to %s %s" % [provider_.provider_name, provider_.display_name])


# when tab changes, set the provider picker to the provider that chat tab is using
func _on_tab_changed(tab: int):
	sync_provider_picker_to_chat(tab)

	# Passthrough chats lock the chooser onto their bound entry; switching to a
	# normal chat unlocks it (chat-passthrough W2).
	_update_passthrough_chooser_lock(tab)

	_update_compact_button()
	_update_stop_button()


## Sync the visible model picker to a chat tab without changing that chat's provider.
## Used by tab changes and MCP-driven provider mutations.
func sync_provider_picker_to_chat(tab_or_chat_id: Variant = -1) -> void:
	var tab: int = current_tab
	if tab_or_chat_id is int:
		tab = int(tab_or_chat_id)
	elif tab_or_chat_id is String and not str(tab_or_chat_id).is_empty():
		tab = -1
		for i in range(SingletonObject.ChatList.size()):
			if SingletonObject.ChatList[i].HistoryId == str(tab_or_chat_id):
				tab = i
				break

	if tab < 0 or tab >= SingletonObject.ChatList.size():
		return

	# The picker describes the currently visible chat. If an MCP call changes a
	# background chat, the picker will update when that tab becomes active.
	if tab != current_tab:
		return

	var history: ChatHistory = SingletonObject.ChatList[tab]
	var active_provider: BaseProvider = history.provider
	if not is_instance_valid(active_provider):
		return

	var item_index = _provider_option_button.get_item_index_for_provider(active_provider)
	if item_index >= 0:
		_provider_option_button.select(item_index)
	else:
		item_index = _add_temporary_provider_picker_item(active_provider)
		if item_index >= 0:
			_provider_option_button.select(item_index)

	SingletonObject.last_tab_index = tab
	update_token_estimation(active_provider)


func _add_temporary_provider_picker_item(active_provider: BaseProvider) -> int:
	var item_id: int = 100000
	while _provider_option_button.get_item_index(item_id) != -1:
		item_id += 1

	_provider_option_button.add_item(active_provider.display_name, item_id)
	var item_index: int = _provider_option_button.get_item_count() - 1

	if active_provider is CoreProvider:
		var core_provider := active_provider as CoreProvider
		if core_provider.service and core_provider.action:
			_provider_option_button.set_item_metadata(item_index, [core_provider.service, core_provider.action])
			return item_index

	var enum_id: int = _resolve_provider_enum_id(active_provider)
	if enum_id >= 0:
		_provider_option_button.set_item_id(item_index, enum_id)
		return item_index

	_provider_option_button.remove_item(item_index)
	return -1


## Resolve a provider's enum ID by matching its script against API_MODEL_PROVIDER_SCRIPTS.
func _resolve_provider_enum_id(provider: BaseProvider) -> int:
	var provider_script = provider.get_script()
	for key in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
		if SingletonObject.API_MODEL_PROVIDER_SCRIPTS[key] == provider_script:
			return key
	# Dynamic models
	if "enum_id" in provider:
		return provider.enum_id
	return -1


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
	if current_tab >= 0 and current_tab < SingletonObject.ChatList.size():
		var history: ChatHistory = SingletonObject.ChatList[current_tab]
		if not history.is_request_active:
			SingletonObject.AtT._StopConverting()
			return

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

		# Notify trigger/batch system that this agent chat was stopped
		# (the zombie coroutine in execute_regular_chat will never reach
		# the agent_chat_finished emit at line 1036, so we emit it here)
		if history.IsAgentChat and not history.AgentDefinitionId.is_empty():
			SingletonObject.agent_chat_finished.emit(history.HistoryId, history.AgentDefinitionId)

		# Mark request as stopped
		history.is_request_active = false

		# Cascade stop to all workers spawned by this chat
		var registry = SingletonObject.worker_registry
		if registry:
			var workers = registry.get_workers_for_parent(history.HistoryId)
			for worker in workers:
				if not registry.is_terminal_status(worker.status):
					SingletonObject.cancelled_history_ids.append(worker.worker_chat_id)
					SingletonObject.stop_all_requests.emit(worker.worker_chat_id)
					registry.update_worker_status(worker.worker_id, "cancelled", "Parent supervisor stopped")
					print("[ChatPane] Cascade stop: cancelled worker '%s'" % worker.worker_name)

		_update_stop_button()


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
	new_chat_history.AgentModeEnabled = chat_to_clone.AgentModeEnabled
	new_chat_history.AgenticSystemPrompt = chat_to_clone.AgenticSystemPrompt
	new_chat_history.DisabledTools = chat_to_clone.DisabledTools.duplicate()
	new_chat_history.StaticToolMode = chat_to_clone.StaticToolMode
	new_chat_history.ConfiguredTools = chat_to_clone.ConfiguredTools.duplicate()
	new_chat_history.ConfiguredSkills = chat_to_clone.ConfiguredSkills.duplicate()
	# A clone belongs beside its original, not in whatever group happens to be
	# selected — so set membership explicitly rather than letting render_history
	# apply the active-view default.
	new_chat_history.ChatGroupId = chat_to_clone.ChatGroupId

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


## Returns the currently-selected chat model descriptor.
## Used by plugin panels (e.g. scansort) that want their LLM calls to
## inherit chat's model selection without forcing the user to configure
## a separate model per plugin.
##
## Returns: {model_name: String, provider: String} or {} if no selection.
## - model_name: the string passed to host.providers.chat (e.g. "claude-opus-4-7", "default")
## - provider: lowercase provider hint for disambiguation (e.g. "anthropic", "openrouter")
func get_active_model_descriptor() -> Dictionary:
	if _provider_option_button == null:
		return {}
	var selected_id: int = _provider_option_button.get_selected_id()
	if selected_id < 0:
		return {}
	var provider_obj = _provider_option_button.get_selected_provider()
	if not is_instance_valid(provider_obj):
		return {}
	var model_name: String = str(provider_obj.model_name) if "model_name" in provider_obj else ""
	if model_name.is_empty():
		return {}
	var provider_name: String = str(provider_obj.provider_name).to_lower() if "provider_name" in provider_obj else ""
	return {"model_name": model_name, "provider": provider_name}


## Returns the full provider spec for the currently-selected model in chat's
## ProviderOptionButton — the same shape as get_item_provider_spec() returns
## ({kind, ...}). Empty Dictionary if no chat is initialized, no selection,
## or the selected item is a sentinel/separator with no backing spec.
##
## Plugins that want to inherit the chat model's exact routing target should
## use this; get_active_model_descriptor() returns only the model name, which
## isn't enough to address Core-action / model-chat models.
func get_active_model_spec() -> Dictionary:
	if _provider_option_button == null:
		return {}
	var idx: int = _provider_option_button.get_selected()
	if idx < 0:
		return {}
	return _provider_option_button.get_item_provider_spec(idx)


## Returns the full list of provider/model items currently shown in chat's
## ProviderOptionButton, suitable for plugin panels that want to mirror the
## chat dropdown.
##
## Returns: Array of Dictionaries, one per dropdown item:
##   { id: int, display_name: String, spec: Dictionary, selected: bool }
## where `spec` is the same shape as ProviderOptionButton.get_item_provider_spec()
## ({kind, ...}), and `selected` is true on the currently-selected item.
## Returns [] if no chat is initialized or button has no items.
func get_available_models() -> Array:
	if _provider_option_button == null:
		return []
	var count: int = _provider_option_button.get_item_count()
	if count <= 0:
		return []
	var result: Array = []
	var selected_index: int = _provider_option_button.get_selected()
	for i in range(count):
		var spec: Dictionary = _provider_option_button.get_item_provider_spec(i)
		# Skip sentinel/separator rows that have no backing provider spec.
		if spec.is_empty():
			continue
		result.append({
			"id": _provider_option_button.get_item_id(i),
			"display_name": _provider_option_button.get_item_text(i),
			"spec": spec,
			"selected": (i == selected_index),
		})
	return result
