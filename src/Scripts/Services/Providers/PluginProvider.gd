class_name PluginProvider
extends BaseProvider
## A chat provider backed by a plugin's generate_tool (chat-passthrough W1).
##
## ONE class serves every plugin chat-provider entry; an instance is configured
## from a PluginChatProviderRegistry entry via configure_from_entry(). On
## generate_content it resolves the plugin's MCPServerConnection and dispatches
## the entry's generate_tool, mapping the plugin's structured reply
## ({kind:"answer"|"question"|"error"}) onto a BotResponse.
##
## This path is a DETERMINISTIC transport — there is NO LLM in it, ever. Token
## counts come from the plugin's reply if present, else 0.
##
## Cancellation: BaseProvider routes SingletonObject.stop_all_requests →
## cancel_active_resquests(); we override that hook to abandon an in-flight
## plugin call and (if a cancel_tool is configured) fire-and-forget it.

## Registry key this provider was configured from ("plugin:<plugin_id>:<entry_id>").
var entry_key: String = ""
var plugin_id: String = ""
var entry_id: String = ""
var generate_tool: String = ""
var history_mode: String = "newest_only"
var cancel_tool: String = ""
var entry_metadata: Dictionary = {}

## Per-call generation token. Each generate_content increments this; the value
## captured before the await identifies the call. If, after the await, the
## current generation has moved on (a newer call started, or this call was
## cancelled), the stale reply is discarded silently — no second emission.
var _call_generation: int = 0

## Generation that an outstanding cancel applies to. When a stop signal arrives
## while awaiting, this is set to the in-flight generation so generate_content
## can resolve promptly with a "cancelled" turn instead of blocking on call_tool.
var _cancelled_generation: int = -1

## Highest generation whose generate_content has already returned. Its late
## call_tool resolution must be a no-op even though _call_generation has not yet
## advanced (cancel resolves a turn before any new send bumps the token).
var _consumed_generation: int = 0

## Fired by the async call_tool helper when a dispatch completes (success or
## transport error). generate_content awaits EITHER this or the cancel hook.
signal _call_settled(generation: int)


func _init() -> void:
	provider_name = "Plugin"
	model_name = "plugin"
	short_name = "PL"
	# Plugin transport has no per-token billing in core.
	input_token_cost = 0.0
	output_token_cost = 0.0


## Configure this instance from a PluginChatProviderRegistry entry Dictionary.
## Returns self for chaining.
func configure_from_entry(entry: Dictionary) -> PluginProvider:
	entry_key = str(entry.get("key", ""))
	plugin_id = str(entry.get("plugin_id", ""))
	entry_id = str(entry.get("entry_id", ""))
	generate_tool = str(entry.get("generate_tool", ""))
	history_mode = str(entry.get("history_mode", "newest_only"))
	cancel_tool = str(entry.get("cancel_tool", ""))
	if entry.get("metadata", null) is Dictionary:
		entry_metadata = (entry["metadata"] as Dictionary).duplicate(true)
	var t: int = int(entry.get("timeout_sec", int(default_timeout)))
	if t > 0:
		request_timeout = float(t)
	model_name = str(entry.get("display_name", "plugin"))
	display_name = str(entry.get("display_name", "plugin"))
	return self


# ---------------------------------------------------------------------------
# BaseProvider contract
# ---------------------------------------------------------------------------

func generate_content(prompt: Array[Variant], _additional_params: Dictionary = {}) -> BotResponse:
	# New call → new generation token. Any prior in-flight call's late reply now
	# has a stale token and will be discarded silently by its helper.
	_call_generation += 1
	var generation: int = _call_generation
	var bot := BotResponse.new()
	bot.provider = self

	# Resolve the plugin connection.
	var pm = _get_plugin_manager()
	if pm == null:
		bot.error = "Plugin chat provider unavailable: plugin manager not found."
		SingletonObject.chat_completed.emit(bot)
		return bot

	var conn = pm.get_connection(plugin_id)
	if conn == null:
		bot.error = "Plugin '%s' is not running; cannot generate a response." % plugin_id
		SingletonObject.chat_completed.emit(bot)
		return bot

	# Build the dispatch args. chat_id = owner history id; text = newest user
	# message; entry_id tells the plugin WHICH of its registered entries this
	# generate targets (a plugin watching N terminals would otherwise have to
	# guess from chat_id); messages = full formatted history ONLY for
	# history_mode "full".
	var args: Dictionary = {
		"chat_id": owner_history_id,
		"text": _newest_user_text(prompt),
		"entry_id": entry_id,
	}
	if history_mode == "full":
		args["messages"] = prompt

	var timeout_sec: float = get_effective_timeout()

	# Dispatch via an async helper that stores the result on this provider and
	# fires _call_settled when call_tool resolves. generate_content then awaits
	# EITHER that completion OR the cancel hook, whichever comes first — so a
	# cancel returns promptly even when the plugin has no cancel_tool and the
	# underlying call_tool would otherwise block until its (long) timeout.
	_dispatch_call(conn, args, timeout_sec, generation)

	# If a stop already arrived for this generation (cancel raced ahead of the
	# await), short-circuit. Otherwise wait for settle-or-cancel.
	while _cancelled_generation != generation and not _result_ready_for(generation):
		var settled_gen: int = await _call_settled
		if settled_gen == generation:
			break
		# A stale helper settled (older generation); keep waiting for ours or a
		# cancel. The condition re-checks both.

	if _cancelled_generation == generation:
		# Cancelled: resolve promptly. The helper's call_tool may still resolve
		# later; the generation token makes that resolution a silent no-op.
		_cancelled_generation = -1
		_consumed_generation = generation
		_clear_pending(generation)
		bot.error = "Request cancelled."
		SingletonObject.chat_completed.emit(bot)
		return bot

	_consumed_generation = generation
	var raw = _take_pending(generation)

	var result: Dictionary = _unwrap_tool_result(raw)

	if result.get("__transport_error__", false):
		bot.error = str(result.get("__transport_message__", "Plugin call failed."))
		SingletonObject.chat_completed.emit(bot)
		return bot

	_apply_result_to_bot(result, bot)
	SingletonObject.chat_completed.emit(bot)
	return bot


# Pending-result store keyed by generation. Survives the await so the waiting
# generate_content can pick up its own reply once _call_settled fires.
var _pending_results: Dictionary = {}

func _result_ready_for(generation: int) -> bool:
	return _pending_results.has(generation)

func _take_pending(generation: int) -> Variant:
	var v: Variant = _pending_results.get(generation, null)
	_pending_results.erase(generation)
	return v

func _clear_pending(generation: int) -> void:
	_pending_results.erase(generation)


## Async helper: dispatch the plugin call, store its result under the call's
## generation, then signal. If the generation has been superseded by the time
## the call resolves (a newer generate_content started), the late reply is
## dropped silently — no stored result, no second chat_completed.
func _dispatch_call(conn, args: Dictionary, timeout_sec: float, generation: int) -> void:
	var raw = await conn.call_tool(generate_tool, args, timeout_sec)
	if generation != _call_generation or generation <= _consumed_generation:
		# Stale: a newer call superseded us, OR this generation's turn already
		# resolved (e.g. via cancel). Discard silently — no stored result, no
		# second chat_completed.
		return
	_pending_results[generation] = raw
	_call_settled.emit(generation)


## Map a plugin reply Dictionary onto a BotResponse per the W1 contract.
##   answer   → text
##   question → text + hcp_data["passthrough_question_options"] = options[]
##   error    → BotResponse.error
## Token fields (prompt_tokens/completion_tokens) copied through if present,
## else left at 0 (deterministic transport).
func _apply_result_to_bot(result: Dictionary, bot: BotResponse) -> void:
	var kind: String = str(result.get("kind", "")).strip_edges()

	# JSON ints arrive as floats; int() coerces both.
	bot.prompt_tokens = int(result.get("prompt_tokens", 0))
	bot.completion_tokens = int(result.get("completion_tokens", 0))

	match kind:
		"answer":
			bot.text = str(result.get("text", ""))
		"question":
			bot.text = str(result.get("text", ""))
			var options_raw: Variant = result.get("options", [])
			var options: Array = []
			if options_raw is Array:
				for o in options_raw:
					if o is Dictionary:
						options.append({
							"label": str(o.get("label", "")),
							"keystroke": str(o.get("keystroke", "")),
						})
			# Stash on the provider-specific metadata bag; do NOT add new
			# BotResponse fields (W1 contract).
			bot.hcp_data["passthrough_question_options"] = options
		"error":
			bot.error = str(result.get("text", "Plugin reported an error."))
		_:
			bot.error = "Plugin returned an unrecognised reply kind '%s'." % kind


## Extract the newest user message text from the formatted prompt array. The
## prompt is the provider-formatted history (Format() output per item); the
## last entry with a "text" field is the newest user turn. Falls back to "".
func _newest_user_text(prompt: Array) -> String:
	for i in range(prompt.size() - 1, -1, -1):
		var item: Variant = prompt[i]
		if item is Dictionary and item.has("text"):
			return str(item["text"])
		if item is String:
			return item
	return ""


## Normalize call_tool output. Returns the plugin's payload Dictionary, OR a
## sentinel {__transport_error__: true, __transport_message__: "..."} when the
## call itself failed (MCP error envelope or dead connection).
func _unwrap_tool_result(raw) -> Dictionary:
	if not (raw is Dictionary):
		return {"__transport_error__": true,
			"__transport_message__": "Plugin returned a non-object result."}
	var d: Dictionary = raw
	# call_tool returns {"error": "..."} on transport / RPC failure.
	if d.has("error") and not d.has("kind"):
		return {"__transport_error__": true,
			"__transport_message__": str(d["error"])}
	# Standard MCP envelope {content:[{type:"text",text:"<JSON>"}]} — unwrap.
	if d.has("content"):
		var content_raw: Variant = d.get("content", [])
		if content_raw is Array and content_raw.size() > 0 and content_raw[0] is Dictionary:
			var item: Dictionary = content_raw[0]
			if item.get("type", "") == "text":
				var parsed: Variant = JSON.parse_string(str(item.get("text", "{}")))
				if parsed is Dictionary:
					return parsed
				return {"__transport_error__": true,
					"__transport_message__": "Plugin reply was not a JSON object."}
	return d


# ---------------------------------------------------------------------------
# Cancellation
# ---------------------------------------------------------------------------

## Override BaseProvider's cancel hook. We have no HTTPRequest to cancel; mark
## the turn cancelled so the awaiting generate_content abandons its wait, and
## fire-and-forget the plugin's cancel_tool when configured.
func cancel_active_resquests() -> void:
	# Mark the in-flight generation cancelled and wake the awaiting
	# generate_content so it resolves promptly (it awaits _call_settled OR this).
	# A late call_tool resolution is neutralised by the generation token.
	if _call_generation > 0:
		_cancelled_generation = _call_generation
		_call_settled.emit(_call_generation)
	if cancel_tool.is_empty():
		return
	var pm = _get_plugin_manager()
	if pm == null:
		return
	var conn = pm.get_connection(plugin_id)
	if conn == null:
		return
	# Fire-and-forget; we do not await the cancellation acknowledgement.
	conn.call_tool(cancel_tool, {"chat_id": owner_history_id})


# ---------------------------------------------------------------------------
# Minimal Format / token helpers (mirrors HumanProvider — deterministic)
# ---------------------------------------------------------------------------

func wrap_memory(item: Note) -> Variant:
	if item.type == Note.Type.TEXT:
		var c = item.get_controls_container() as NoteTextControls
		return c.content
	elif item.type == Note.Type.IMAGE:
		var c = item.get_controls_container() as NoteImageControls
		return c.caption
	return ""


func Format(chat_item: ChatHistoryItem) -> Variant:
	var text_notes := PackedStringArray()
	for note: Variant in chat_item.InjectedNotes:
		if note is String:
			text_notes.append(note)

	var notes_section := ""
	if not text_notes.is_empty():
		notes_section = "### Reference Information ###\n"
		notes_section += "\n\n".join(text_notes)
		notes_section += "\n### End Reference Information ###\n\n"

	var full_text := "%s%s" % [notes_section, chat_item.Message]
	return {"text": full_text.strip_edges()}


func estimate_tokens(_input: String) -> int:
	return 0


func estimate_tokens_from_prompt(_input: Array[Variant]) -> float:
	return 0


func continue_partial_response(_partial_chi: ChatHistoryItem):
	return null


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _get_plugin_manager():
	# Runtime resolution via SingletonObject (compile-time refs poison isolated
	# harnesses; tests inject _test_plugin_manager instead).
	if _test_plugin_manager != null:
		return _test_plugin_manager
	var so = SingletonObject
	if so != null and "plugin_manager" in so:
		return so.plugin_manager
	return null


## Test-only injection of a stub plugin manager exposing get_connection().
var _test_plugin_manager = null
