class_name ToolMemoryManager
extends RefCounted

## Centralized tool token lifecycle manager. One instance per ChatHistory.
## Owns: dehydration, floating summary, recovery index, compaction, retrieval dispatch.

# --- Master switch ---
var enabled: bool = false

# --- Analog dials (configurable thresholds) ---
var dehydrate_after_n_rounds: int = 1
var max_floating_summary_chars: int = 2000
var drop_refs_after_n_rounds: int = -1
var max_tool_schema_count: int = 0
var context_budget_tokens: int = 0
var max_index_entries: int = 50

# --- Summary provider ---
var summary_prompt: String = ""
var summary_provider_factory: Callable

# --- Per-chat state (hydrated from ServiceHistory on init) ---
var floating_summary_note_id: String = ""
var tool_memory_state: Dictionary = {}
var telemetry: Dictionary = {}

# --- Chat provider (DI'd for format/estimate/cache) ---
var _chat_provider: BaseProvider

# --- Recovery index (code-maintained, never LLM-summarized) ---
var _recovery_index: Array[Dictionary] = []

# --- Injectable Callables (set by ChatPane) ---
## Signature: (history: ServiceHistory, note_id: String, title: String, content: String, enabled: bool) -> String
var note_upsert_fn: Callable
## Signature: (provider_spec: Dictionary, settings: Dictionary, prompt_text: String) -> Dictionary
## Returns {ok: bool, text: String, error: String, provider_label: String}
var summary_call_fn: Callable
## Same signature as summary_call_fn, for fallback provider. May be empty Callable.
var fallback_summary_call_fn: Callable
## Cached settings from preferences (set via apply_config or _configure)
var summary_settings: Dictionary = {}

# --- Constants ---
const TOOL_WINDOW_LENGTH: int = 4000
const FLOATING_SUMMARY_PROMPT_LENGTH: int = 1200


func _init(history: ServiceHistory = null) -> void:
	if history:
		_hydrate_from_history(history)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Project history for API submission. Applies dehydration, injects memory header.
## When disabled, returns items unmodified.
func project(history: ServiceHistory, provider: BaseProvider) -> Array:
	if not enabled:
		return history.HistoryItemList
	_chat_provider = provider
	rebuild_recovery_index(history.HistoryItemList)
	return _project_history_for_prompt(history)


## Update floating summary after tool execution. Blocking per-chat.
## When disabled, skips summarization entirely (raw history preserved).
func fold_tool_result(history: ServiceHistory) -> void:
	if not enabled:
		return
	await _refresh_floating_tool_summary(history)


## Record telemetry update to both self.telemetry and history.AgentContextTelemetry.
func record_telemetry(history: ServiceHistory, update: Dictionary) -> void:
	_record_agent_context_telemetry(history, update)


## Build the recovery index from current history items.
## Code-maintained, lossless — never passes through LLM.
## Called by project() before building the memory header.
func rebuild_recovery_index(items: Array) -> void:
	_recovery_index.clear()
	var round_num := 0
	for item in items:
		if not (item is ChatHistoryItem):
			continue
		if item.IsToolCall:
			round_num += 1
		if item.Role == ChatHistoryItem.ChatRole.TOOL and not item.ToolArtifactNoteId.is_empty():
			_recovery_index.append({
				"note_id": item.ToolArtifactNoteId,
				"tool": item.ToolName,
				"round": round_num,
				"brief": item.ToolSummary.left(80) if not item.ToolSummary.is_empty() else item.ToolName,
			})
	# Enforce max_index_entries — oldest drop off
	if max_index_entries > 0 and _recovery_index.size() > max_index_entries:
		_recovery_index = _recovery_index.slice(-max_index_entries)


## Get the current recovery index (read-only view for memory header injection).
func get_recovery_index() -> Array[Dictionary]:
	return _recovery_index


## Handle retrieval tool call (dispatched from MCP).
## Two modes:
##   Search (no note_id): filter _recovery_index by query, return compact entries
##   Retrieve (note_id provided): return full agent note content
func handle_recall(query: Dictionary) -> Dictionary:
	var note_id: String = str(query.get("note_id", ""))
	if not note_id.is_empty():
		# Retrieve mode — return full agent note content
		var content := _get_agent_note_text(note_id)
		if not content.is_empty():
			return {"content": content, "note_id": note_id}
		return {"error": "note not found", "note_id": note_id}

	# Search mode — filter and return index entries
	var search_term: String = str(query.get("query", "")).to_lower()
	var limit: int = int(query.get("limit", 10))
	var results: Array[Dictionary] = []
	for entry in _recovery_index:
		if search_term.is_empty() or search_term in str(entry.get("tool", "")).to_lower() or search_term in str(entry.get("brief", "")).to_lower():
			results.append(entry)
		if results.size() >= limit:
			break
	return {"count": results.size(), "entries": results, "total_archived": _recovery_index.size()}


## Compact chat history when budget exceeded.
func compact(items: Array, keep_recent: int) -> Array:
	if not enabled:
		return items
	# TODO: Phase 2 — migrate from ChatPane compact logic
	return items


## Get stats for telemetry/debugging.
func get_stats() -> Dictionary:
	return {
		"enabled": enabled,
		"floating_summary_chars": 0,
		"recovery_index_size": _recovery_index.size(),
		"telemetry": telemetry,
	}


## Apply configuration from Preferences UI.
func apply_config(config: Dictionary) -> void:
	enabled = config.get("enabled", false)
	dehydrate_after_n_rounds = config.get("dehydrate_after_n_rounds", 1)
	max_floating_summary_chars = config.get("max_floating_summary_chars", 2000)
	drop_refs_after_n_rounds = config.get("drop_refs_after_n_rounds", -1)
	max_tool_schema_count = config.get("max_tool_schema_count", 0)
	context_budget_tokens = config.get("context_budget_tokens", 0)
	max_index_entries = config.get("max_index_entries", 50)
	summary_prompt = config.get("summary_prompt", "")
	if config.has("summary_provider_factory"):
		summary_provider_factory = config["summary_provider_factory"]
	if config.has("summary_settings"):
		summary_settings = config["summary_settings"]


## Read existing state from a ServiceHistory instance.
func _hydrate_from_history(history: ServiceHistory) -> void:
	floating_summary_note_id = history.AgentFloatingSummaryNoteId
	tool_memory_state = history.AgentToolMemoryState
	telemetry = history.AgentContextTelemetry


## Write current state back to a ServiceHistory instance.
func persist_to_history(history: ServiceHistory) -> void:
	history.AgentFloatingSummaryNoteId = floating_summary_note_id
	history.AgentToolMemoryState = tool_memory_state
	history.AgentContextTelemetry = telemetry


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

static func build_tool_ref_message(tool_name: String, note_id: String, _folded_into_floating_summary: bool = false) -> String:
	var parts := PackedStringArray(["t:%s" % tool_name])
	if not note_id.is_empty():
		parts.append("n:%s" % note_id.left(8))
	return "[%s]" % " ".join(parts)


static func _hash_projection_fragment(text: String) -> String:
	if text.is_empty():
		return ""
	return text.sha256_text().left(12)


static func _set_prompt_item_fields(prompt_item: ChatHistoryItem, updates: Dictionary) -> void:
	prompt_item._suppress_save_state = true
	for key in updates.keys():
		prompt_item.set(key, updates[key])
	prompt_item._suppress_save_state = false


static func _trim_tool_memory_text(text: String, limit: int = 160) -> String:
	var trimmed := text.strip_edges().replace("\n", " ")
	if trimmed.length() <= limit:
		return trimmed
	return "%s..." % trimmed.left(limit - 3)


static func _provider_has_property(provider: Object, property_name: String) -> bool:
	for prop in provider.get_property_list():
		if str(prop.get("name", "")) == property_name:
			return true
	return false


func _get_tool_projection_message(item: ChatHistoryItem, floating_summary_active: bool) -> String:
	if floating_summary_active:
		return build_tool_ref_message(item.ToolName, item.ToolArtifactNoteId, true)
	if not item.ToolSummary.is_empty():
		return item.ToolSummary
	if not item.ToolArtifactNoteId.is_empty():
		return build_tool_ref_message(item.ToolName, item.ToolArtifactNoteId, false)
	return "[t:%s]" % item.ToolName


static func _build_collapsed_tool_use_message(tool_calls: Array[Dictionary]) -> String:
	var tool_names := PackedStringArray()
	for tool_call in tool_calls:
		var tool_name := str(tool_call.get("name", "tool"))
		if not tool_name.is_empty():
			tool_names.append(tool_name)
	if tool_names.is_empty():
		return "[tool-use summarized]"
	return "[tool-use summarized: %s]" % ", ".join(tool_names)


# ---------------------------------------------------------------------------
# Agent note text helper
# ---------------------------------------------------------------------------

func _get_agent_note_text(note_id: String) -> String:
	if note_id.is_empty():
		return ""
	# Late-bind SingletonObject to avoid compile-time dependency (it's an autoload).
	var singleton = Engine.get_singleton("SingletonObject") if Engine.has_singleton("SingletonObject") else null
	if not singleton:
		singleton = (Engine.get_main_loop() as SceneTree).root.get_node_or_null("SingletonObject") if Engine.get_main_loop() is SceneTree else null
	if not singleton or not singleton.has_method("get_registered_object"):
		return ""
	var note = singleton.get_registered_object(note_id)
	if not note or not (note is Note):
		return ""
	var controls = note.get_controls_container()
	if controls is NoteTextControls:
		return controls.content
	return ""


# ---------------------------------------------------------------------------
# Summary helpers
# ---------------------------------------------------------------------------

func _build_floating_summary_source(item: ChatHistoryItem) -> String:
	var section := PackedStringArray()
	section.append("Tool: %s" % item.ToolName)
	if not item.ToolSummary.is_empty():
		section.append("Compact summary: %s" % item.ToolSummary)
	if not item.ToolArtifactNoteId.is_empty():
		section.append("Artifact note: %s" % item.ToolArtifactNoteId)
		var artifact_text := _get_agent_note_text(item.ToolArtifactNoteId)
		if not artifact_text.is_empty():
			section.append("Artifact excerpt:\n%s" % artifact_text.left(TOOL_WINDOW_LENGTH))
	return "\n".join(section)


func _build_deterministic_floating_summary(existing_summary: String, source_text: String) -> String:
	var parts := PackedStringArray()
	if not existing_summary.is_empty():
		parts.append(existing_summary.strip_edges())
	if not source_text.is_empty():
		parts.append(source_text.strip_edges())
	var joined := "\n\n---\n\n".join(parts)
	if joined.length() <= TOOL_WINDOW_LENGTH:
		return joined
	return joined.substr(joined.length() - TOOL_WINDOW_LENGTH, TOOL_WINDOW_LENGTH)


# ---------------------------------------------------------------------------
# Telemetry
# ---------------------------------------------------------------------------

func _record_agent_context_telemetry(history: ServiceHistory, update: Dictionary) -> void:
	var telem := history.AgentContextTelemetry.duplicate(true)
	for key in update.keys():
		telem[key] = update[key]
	history.AgentContextTelemetry = telem
	# Mirror to local telemetry cache
	for key in update.keys():
		telemetry[key] = update[key]


# ---------------------------------------------------------------------------
# State builders
# ---------------------------------------------------------------------------

func _build_knowledge_injection_text(history: ServiceHistory) -> String:
	if history.AcquiredKnowledge.is_empty():
		return ""

	var entries: Array[Dictionary] = []
	entries.assign(history.AcquiredKnowledge)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ak := "%s:%s" % [str(a.get("type", "")), str(a.get("id", ""))]
		var bk := "%s:%s" % [str(b.get("type", "")), str(b.get("id", ""))]
		return ak < bk
	)

	var sections := PackedStringArray()
	sections.append("Here is potentially useful knowledge for this chat. Confirm receipt implicitly and use it when relevant.")
	for entry in entries:
		var header := "[%s %s]" % [str(entry.get("type", "knowledge")).to_upper(), str(entry.get("id", ""))]
		var body := PackedStringArray()
		if not str(entry.get("title", "")).is_empty():
			body.append("Title: %s" % str(entry.get("title", "")))
		if not str(entry.get("description", "")).is_empty():
			body.append("Description: %s" % str(entry.get("description", "")))
		if not str(entry.get("content", "")).is_empty():
			body.append(str(entry.get("content", "")))
		sections.append("%s\n%s" % [header, "\n".join(body)])
	return "\n\n".join(sections)


func _build_tool_memory_projection_state(history: ServiceHistory, floating_summary_text: String) -> Dictionary:
	var latest_tool_idx := -1
	var total_tool_results := 0
	var first_user_message := ""

	for i in range(history.HistoryItemList.size()):
		var item := history.HistoryItemList[i]
		if first_user_message.is_empty() and item.Role == ChatHistoryItem.ChatRole.USER and not item.Message.strip_edges().is_empty():
			first_user_message = _trim_tool_memory_text(item.Message, 180)
		if item.Role != ChatHistoryItem.ChatRole.TOOL:
			continue
		total_tool_results += 1
		latest_tool_idx = i

	var latest_tool_call_ids := {}
	var latest_tool_name := ""
	var latest_tool_note_id := ""
	if latest_tool_idx >= 0:
		var latest_tool: ChatHistoryItem = history.HistoryItemList[latest_tool_idx]
		latest_tool_name = latest_tool.ToolName
		latest_tool_note_id = latest_tool.ToolArtifactNoteId
		if not latest_tool.ToolCallId.is_empty():
			latest_tool_call_ids[latest_tool.ToolCallId] = true

	var state := {
		"version": 4,
		"active": {
			"task": first_user_message,
			"latest_tool": latest_tool_name,
			"latest_tool_note_id": latest_tool_note_id,
			"floating_summary_note_id": history.AgentFloatingSummaryNoteId,
		},
		"status": {
			"floating_summary_active": not floating_summary_text.is_empty(),
			"knowledge_items": history.AcquiredKnowledge.size(),
			"stale_tool_results": maxi(0, total_tool_results - 1),
			"tool_result_count": total_tool_results,
		},
	}
	if history.AgentToolMemoryState != state:
		history.AgentToolMemoryState = state

	return {
		"latest_tool_idx": latest_tool_idx,
		"latest_tool_call_ids": latest_tool_call_ids,
		"state": state,
	}


func _build_tool_memory_header_text(state: Dictionary) -> String:
	if state.is_empty():
		return ""

	var active: Dictionary = state.get("active", {})
	var status: Dictionary = state.get("status", {})
	var floating_summary_active := bool(status.get("floating_summary_active", false))
	if not floating_summary_active:
		return ""

	var lines := PackedStringArray(["[tm v4]"])
	var task := str(active.get("task", ""))
	if not task.is_empty():
		lines.append("task=%s" % task)
	var latest_tool := str(active.get("latest_tool", ""))
	if not latest_tool.is_empty():
		lines.append("latest=%s" % latest_tool)
	var floating_note_id := str(active.get("floating_summary_note_id", ""))
	if not floating_note_id.is_empty():
		lines.append("floating=%s" % floating_note_id.left(8))
	var latest_tool_note_id := str(active.get("latest_tool_note_id", ""))
	if not latest_tool_note_id.is_empty():
		lines.append("latest_note=%s" % latest_tool_note_id.left(8))
	var archived_count := _recovery_index.size()
	if archived_count > 0:
		lines.append("archived=%d (use minerva_tool_memory_search to browse/retrieve)" % archived_count)
	lines.append("stats=tools:%d stale:%d knowledge:%d" % [
		int(status.get("tool_result_count", 0)),
		int(status.get("stale_tool_results", 0)),
		int(status.get("knowledge_items", 0)),
	])
	return "\n".join(lines)


func _get_latest_tool_chain_state(items: Array[ChatHistoryItem]) -> Dictionary:
	var latest_tool_call_message_idx := -1
	for i in range(items.size() - 1, -1, -1):
		var item := items[i]
		var is_tool_call_message := item.IsToolCall and (item.Role == ChatHistoryItem.ChatRole.ASSISTANT or item.Role == ChatHistoryItem.ChatRole.MODEL)
		if is_tool_call_message:
			latest_tool_call_message_idx = i
			break

	var retained_tool_result_indices := {}
	var latest_tool_idx := -1
	if latest_tool_call_message_idx >= 0:
		for i in range(latest_tool_call_message_idx + 1, items.size()):
			var item := items[i]
			if item.Role != ChatHistoryItem.ChatRole.TOOL:
				break
			retained_tool_result_indices[i] = true
			latest_tool_idx = i
	else:
		for i in range(items.size() - 1, -1, -1):
			if items[i].Role == ChatHistoryItem.ChatRole.TOOL:
				latest_tool_idx = i
				retained_tool_result_indices[i] = true
				break

	return {
		"latest_tool_call_message_idx": latest_tool_call_message_idx,
		"retained_tool_result_indices": retained_tool_result_indices,
		"latest_tool_idx": latest_tool_idx,
	}


# ---------------------------------------------------------------------------
# Main orchestrators
# ---------------------------------------------------------------------------

func _project_history_for_prompt(history: ServiceHistory) -> Array:
	var projected: Array[ChatHistoryItem] = []
	var knowledge_text := _build_knowledge_injection_text(history)
	var floating_summary_text := _get_agent_note_text(history.AgentFloatingSummaryNoteId)
	var projection_state := _build_tool_memory_projection_state(history, floating_summary_text)
	var latest_tool_chain := _get_latest_tool_chain_state(history.HistoryItemList)
	var latest_tool_idx := int(latest_tool_chain.get("latest_tool_idx", -1))
	var latest_tool_call_message_idx := int(latest_tool_chain.get("latest_tool_call_message_idx", -1))
	var retained_tool_result_indices: Dictionary = latest_tool_chain.get("retained_tool_result_indices", {})
	var tool_memory_text := _build_tool_memory_header_text(projection_state.get("state", {}))
	var injected_knowledge := false
	var dehydrated_items := 0
	var chars_removed := 0
	var collapsed_tool_use_items := 0
	var collapsed_tool_result_items := 0

	for i in range(history.HistoryItemList.size()):
		var item := history.HistoryItemList[i]
		var prompt_item := item
		var mutated := false

		if item.Role == ChatHistoryItem.ChatRole.USER and not injected_knowledge and not knowledge_text.is_empty():
			prompt_item = item.duplicate_for_prompt()
			var notes_copy: Array[Variant] = prompt_item.InjectedNotes.duplicate()
			notes_copy.append(knowledge_text)
			if not tool_memory_text.is_empty():
				notes_copy.append(tool_memory_text)
			_set_prompt_item_fields(prompt_item, {"InjectedNotes": notes_copy})
			injected_knowledge = true
			mutated = true
		elif item.Role == ChatHistoryItem.ChatRole.USER and not injected_knowledge and not tool_memory_text.is_empty():
			prompt_item = item.duplicate_for_prompt()
			var tool_notes_copy: Array[Variant] = prompt_item.InjectedNotes.duplicate()
			tool_notes_copy.append(tool_memory_text)
			_set_prompt_item_fields(prompt_item, {"InjectedNotes": tool_notes_copy})
			injected_knowledge = true
			mutated = true

		if item.IsToolCall and (item.Role == ChatHistoryItem.ChatRole.ASSISTANT or item.Role == ChatHistoryItem.ChatRole.MODEL):
			if i != latest_tool_call_message_idx:
				if not mutated:
					prompt_item = item.duplicate_for_prompt()
					mutated = true
				_set_prompt_item_fields(prompt_item, {
					"IsToolCall": false,
					"ToolCalls": [],
					"ToolExecutions": [],
					"Message": _build_collapsed_tool_use_message(item.ToolCalls),
				})
				collapsed_tool_use_items += 1
				chars_removed += maxi(0, item.Message.length() - prompt_item.Message.length())

		if item.Role == ChatHistoryItem.ChatRole.TOOL and not retained_tool_result_indices.has(i):
			var compact_message := _get_tool_projection_message(item, not floating_summary_text.is_empty())
			if not mutated:
				prompt_item = item.duplicate_for_prompt()
				mutated = true
			_set_prompt_item_fields(prompt_item, {
				"Role": ChatHistoryItem.ChatRole.USER,
				"ToolCallId": "",
				"ToolName": "",
				"ToolCalls": [],
				"IsToolCall": false,
				"ToolExecutions": [],
				"Message": compact_message,
			})
			dehydrated_items += 1
			collapsed_tool_result_items += 1
			chars_removed += maxi(0, item.Message.length() - compact_message.length())

			if item.Role == ChatHistoryItem.ChatRole.TOOL and i == latest_tool_idx and not floating_summary_text.is_empty():
				if not mutated:
					prompt_item = item.duplicate_for_prompt()
					mutated = true
				_set_prompt_item_fields(prompt_item, {
					"Message": "[tm]\n%s\n\n[cur]\n%s" % [floating_summary_text, prompt_item.Message],
				})
				mutated = true

		projected.append(prompt_item)

	var prefix_parts := PackedStringArray()
	if not knowledge_text.is_empty():
		prefix_parts.append(knowledge_text)
	if not tool_memory_text.is_empty():
		prefix_parts.append(tool_memory_text)

	_record_agent_context_telemetry(history, {
		"last_projection_items_dehydrated": dehydrated_items,
		"last_projection_chars_removed": chars_removed,
		"knowledge_items": history.AcquiredKnowledge.size(),
		"floating_summary_active": not floating_summary_text.is_empty(),
		"tool_memory_header_chars": tool_memory_text.length(),
		"knowledge_hash": _hash_projection_fragment(knowledge_text),
		"tool_memory_hash": _hash_projection_fragment(tool_memory_text),
		"floating_summary_hash": _hash_projection_fragment(floating_summary_text),
		"floating_summary_prompt_chars": floating_summary_text.length(),
		"projection_prefix_hash": _hash_projection_fragment("\n".join(prefix_parts)),
		"collapsed_tool_use_items": collapsed_tool_use_items,
		"collapsed_tool_result_items": collapsed_tool_result_items,
	})
	return projected


func _refresh_floating_tool_summary(history: ServiceHistory) -> void:
	if not summary_call_fn.is_valid():
		_record_agent_context_telemetry(history, {"floating_summary_enabled": false})
		return

	var tool_items: Array[ChatHistoryItem] = []
	for item in history.HistoryItemList:
		if item.Role == ChatHistoryItem.ChatRole.TOOL:
			tool_items.append(item)

	if tool_items.size() <= 1:
		_record_agent_context_telemetry(history, {"floating_summary_enabled": true, "floating_summary_items": 0})
		return

	var settings := summary_settings
	var existing_summary := _get_agent_note_text(history.AgentFloatingSummaryNoteId)
	var previous_latest: ChatHistoryItem = tool_items[tool_items.size() - 2]
	var latest_source := _build_floating_summary_source(previous_latest)
	var configured_prompt: String = str(settings.get("summary_prompt", "")).strip_edges()
	if configured_prompt.is_empty():
		configured_prompt = "Create a compact rolling summary of prior tool activity for an agent chat. Preserve important IDs, failures, file paths, item IDs, note IDs, and decisions. Omit chatter. Keep it concise but information-dense."
	var prompt_text := "%s\n\nExisting floating summary:\n%s\n\n---\n\nNewest completed tool to fold in:\n%s" % [configured_prompt, existing_summary, latest_source]
	var primary_result: Dictionary = await summary_call_fn.call(settings.get("primary_provider", {}), settings, prompt_text)
	var summary_text := str(primary_result.get("text", ""))
	var fallback_result: Dictionary = {}

	if summary_text.is_empty() and fallback_summary_call_fn.is_valid():
		fallback_result = await fallback_summary_call_fn.call(settings.get("fallback_provider", {}), settings, prompt_text)
		summary_text = str(fallback_result.get("text", ""))

	var used_deterministic_fallback := false
	if summary_text.is_empty():
		summary_text = _build_deterministic_floating_summary(existing_summary, latest_source)
		used_deterministic_fallback = not summary_text.is_empty()
	if summary_text.is_empty():
		_record_agent_context_telemetry(history, {
			"floating_summary_enabled": true,
			"floating_summary_error": "summary_generation_failed",
			"floating_summary_primary_error": str(primary_result.get("error", "")),
			"floating_summary_primary_provider": str(primary_result.get("provider_label", "")),
			"floating_summary_fallback_error": str(fallback_result.get("error", "")),
			"floating_summary_fallback_provider": str(fallback_result.get("provider_label", "")),
		})
		return

	if note_upsert_fn.is_valid():
		history.AgentFloatingSummaryNoteId = note_upsert_fn.call(history, history.AgentFloatingSummaryNoteId, "Floating Tool Summary", summary_text, false)
	_record_agent_context_telemetry(history, {
		"floating_summary_enabled": true,
		"floating_summary_items": tool_items.size() - 1,
		"floating_summary_note_id": history.AgentFloatingSummaryNoteId,
		"floating_summary_primary_error": str(primary_result.get("error", "")),
		"floating_summary_primary_provider": str(primary_result.get("provider_label", "")),
		"floating_summary_fallback_error": str(fallback_result.get("error", "")),
		"floating_summary_fallback_provider": str(fallback_result.get("provider_label", "")),
		"floating_summary_mode": "deterministic" if used_deterministic_fallback else ("fallback" if not fallback_result.is_empty() and str(fallback_result.get("text", "")).length() > 0 else "primary"),
	})
