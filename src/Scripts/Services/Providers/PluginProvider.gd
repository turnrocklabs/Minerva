class_name PluginProvider
extends BaseProvider
## A chat provider backed by a plugin's generate_tool (chat-passthrough W1).
##
## ONE class serves every plugin chat-provider entry; an instance is configured
## from a PluginChatProviderRegistry entry via configure_from_entry(). On
## generate_content it resolves the plugin's MCPServerConnection and dispatches
## the entry's generate_tool, mapping the plugin's structured reply
## ({kind:"answer"|"question"|"error"}) onto a BotResponse. A reply of
## {kind:"pending"} means the turn outlived one call; the same operation is
## resumed until it ends (see _dispatch_call).
##
## A plugin's generate tool may act (type into a terminal, run an agent), so
## each call of it, a resume included, is a governed plugin tool call: admitted
## by the policy in MinervaMCPServer, then checked and dispatched by
## PluginToolRegistry, in an execution context owned by this provider's chat
## whose timeout starts when the call is sent (see _generate). A stop, or a
## newer call, cancels that context, so a call still being admitted is never
## sent; the cancel and interrupt tools are called directly, so a stop always
## reaches an operation that was sent.
##
## This path is a DETERMINISTIC transport — there is NO LLM in it, ever. Token
## counts come from the plugin's reply if present, else 0.
##
## Cancellation: BaseProvider routes SingletonObject.stop_all_requests →
## cancel_active_resquests(); we override that hook to abandon an in-flight
## plugin call and (if a cancel_tool is configured) fire-and-forget it.

## How much sooner than the call timeout the plugin must answer, so a running
## turn comes back "pending" rather than as a transport timeout.
const RESUME_MARGIN_SEC := 10.0

## Told what became of a notification this chat carried (see _report_notify).
const NotifyDeliveryLedger := preload("res://Scripts/Services/Terminal/NotifyDeliveryLedger.gd")

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
var _active_operation_token: String = ""
var _active_interrupt_enabled: bool = false
var _active_cancel_tool: String = ""
var _active_plugin_id: String = ""
var _interrupt_requested: bool = false
var interrupt_error: String = ""

## The execution context of the governed call in flight (see _generate):
## cancelled by a stop and when a newer call starts.
var _active_context: MCPExecutionContext = null
## The latest generation whose operation was sent to the plugin.
var _sent_generation: int = 0
## A generation interrupted before its operation was sent.
var _interrupted_unsent: int = 0

## Fired by the async dispatch helper when a dispatch completes (success or
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
	entry_metadata = {}
	if entry.get("metadata", null) is Dictionary:
		entry_metadata = (entry["metadata"] as Dictionary).duplicate(true)
	var t: int = int(entry.get("timeout_sec", PluginChatProviderRegistry.DEFAULT_TIMEOUT_SEC))
	request_timeout = float(t if t > 0 else PluginChatProviderRegistry.DEFAULT_TIMEOUT_SEC)
	model_name = str(entry.get("display_name", "plugin"))
	display_name = str(entry.get("display_name", "plugin"))
	return self


# ---------------------------------------------------------------------------
# BaseProvider contract
# ---------------------------------------------------------------------------

func generate_content(prompt: Array[Variant], _additional_params: Dictionary = {}) -> BotResponse:
	# New call → new generation token. Any prior in-flight call's late reply now
	# has a stale token and will be discarded silently by its helper, and a
	# prior call not yet sent never is (its context is cancelled once the new
	# generation is in place, so it completes as superseded).
	var superseded := _active_context
	_active_context = null
	_call_generation += 1
	var generation: int = _call_generation
	if superseded != null:
		superseded.cancel()
	_clear_active_operation(generation)
	var bot := BotResponse.new()
	bot.provider = self
	# A running connection does not imply this particular entry still exists.
	var entry := ModelResolver.plugin_entry(entry_key)
	if entry.is_empty():
		bot.error = "Plugin chat entry '%s' is not registered." % entry_key
		_report_unsent(prompt, bot.error)
		SingletonObject.chat_completed.emit(bot)
		return bot
	configure_from_entry(entry)

	# Resolve the plugin connection.
	var pm = _get_plugin_manager()
	if pm == null:
		bot.error = "Plugin chat provider unavailable: plugin manager not found."
		_report_unsent(prompt, bot.error)
		SingletonObject.chat_completed.emit(bot)
		return bot

	var conn = pm.get_connection(plugin_id)
	if conn == null:
		bot.error = "Plugin '%s' is not running; cannot generate a response." % plugin_id
		_report_unsent(prompt, bot.error)
		SingletonObject.chat_completed.emit(bot)
		return bot
	var operation_token := "%s:%s:%s" % [str(get_instance_id()), str(Time.get_ticks_usec()), str(generation)]
	_active_operation_token = operation_token
	_active_interrupt_enabled = bool(entry_metadata.get("interrupt_in_place", false)) \
		and not cancel_tool.is_empty()
	_active_cancel_tool = cancel_tool
	_active_plugin_id = plugin_id

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
	if supports_in_place_interrupt():
		args["operation_token"] = operation_token
	if history_mode == "full":
		args["messages"] = prompt

	var timeout_sec: float = get_effective_timeout()
	# A resumable entry waits at most this long per call, so a still-running
	# turn comes back "pending" before the call itself times out. Other
	# plugins' generate tools never see the argument.
	if _resumable():
		args["wait_budget_ms"] = int(maxf(1.0, timeout_sec - RESUME_MARGIN_SEC) * 1000.0)

	# Dispatch via an async helper that stores the result on this provider and
	# fires _call_settled when call_tool resolves. generate_content then awaits
	# EITHER that completion OR the cancel hook, whichever comes first — so a
	# cancel returns promptly even when the plugin has no cancel_tool and the
	# underlying call_tool would otherwise block until its (long) timeout.
	_dispatch_call(args, timeout_sec, generation)

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
		_clear_active_operation(generation)
		_clear_pending(generation)
		bot.error = "Request cancelled."
		SingletonObject.chat_completed.emit(bot)
		return bot

	_consumed_generation = generation
	_clear_active_operation(generation)
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
func _dispatch_call(args: Dictionary, timeout_sec: float, generation: int) -> void:
	var raw = await _generate(args, timeout_sec, generation)
	if _interrupted_unsent == generation:
		raw = {"error": "Interrupted before the message was sent to the plugin; nothing was sent."}
	_report_notify(str(args.get("text", "")), raw, generation)
	# A turn longer than one call comes back "pending" under this call's own
	# operation token: keep waiting on that same operation (nothing is re-sent)
	# until it ends, while this generation is still the live, uncancelled one.
	# The chat's live status keeps updating throughout, since generate_content
	# is still waiting.
	var token := str(args.get("operation_token", ""))
	while _resumable() and _is_resumable_pending(raw, token) and _generation_live(generation):
		raw = await _generate({
			"chat_id": args.get("chat_id", ""),
			"entry_id": args.get("entry_id", ""),
			"operation_token": token,
			"text": "",
			"resume": true,
			"wait_budget_ms": args.get("wait_budget_ms", 0),
		}, timeout_sec, generation)
	if generation != _call_generation or generation <= _consumed_generation:
		# Stale: a newer call superseded us, OR this generation's turn already
		# resolved (e.g. via cancel). Discard silently — no stored result, no
		# second chat_completed.
		return
	_pending_results[generation] = raw
	_call_settled.emit(generation)


## One call of the plugin's generate tool with `args` for `generation`, as a
## governed plugin tool call (see the class comment), which may take
## `timeout_sec` once sent: its result, or {error} when it was not admitted,
## was stopped before it was sent, or cannot be governed because the plugin
## registers no such tool or the host's tool server is not running.
func _generate(args: Dictionary, timeout_sec: float, generation: int) -> Dictionary:
	var registry = SingletonObject.get("plugin_tool_registry")
	var tool_name: String = registry.tool_for(plugin_id, generate_tool) if registry != null else ""
	if tool_name.is_empty():
		return {"error": "Plugin '%s' registers no tool '%s', so its reply cannot be requested as a governed call." % [plugin_id, generate_tool]}
	var manager = SingletonObject.get("mcp_manager")
	var server = manager.get("minerva_server") if manager != null else null
	if server == null:
		return {"error": "The host's tool server is not running, so plugin '%s' cannot be asked for a reply." % plugin_id}
	if generation != _call_generation or _cancelled_generation == generation:
		return {"error": "Request cancelled."}
	var context := MCPExecutionContext.create("provider", owner_history_id)
	context.lifetime.dispatch_seconds = timeout_sec
	_active_context = context
	var result: Dictionary = await server.call_tool(tool_name, args, context)
	if context.lifetime.dispatched and generation > _sent_generation:
		_sent_generation = generation
	if _active_context == context:
		_active_context = null
	return result


# Cancelling completes the call synchronously, so the context is detached
# first and callers set the cancelled or superseded state before this.
func _cancel_active_context() -> void:
	var context := _active_context
	_active_context = null
	if context != null:
		context.cancel()


## The entry registered {metadata: {resumable: true}}: it answers "pending"
## for a turn that outlives one call, and takes resume:true to continue it.
func _resumable() -> bool:
	return bool(entry_metadata.get("resumable", false))


func _generation_live(generation: int) -> bool:
	return generation == _call_generation and generation > _consumed_generation \
		and _cancelled_generation != generation


## True for a "pending" reply carrying this call's own (non-empty) token. A
## pending reply for any other token is not resumed; it surfaces as an error.
func _is_resumable_pending(raw, token: String) -> bool:
	var reply := _unwrap_tool_result(raw)
	return not token.is_empty() and str(reply.get("kind", "")) == "pending" \
		and str(reply.get("operation_token", "")) == token


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
		"pending":
			bot.error = "Plugin reported a still-running turn this chat cannot resume."
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


## Tell the notify ledger whether the harness took the text this call carried,
## from the call's FIRST reply: a running (pending), answered or questioning
## turn means the relay wrote it and the harness took it; a refusal marked
## held means nothing was written; any other error, or a transport failure
## after the call was sent, proves neither. The ledger ignores text that no
## notification of this chat is waiting on.
func _report_notify(text: String, raw, generation: int) -> void:
	var result: Dictionary = _unwrap_tool_result(raw)
	var ledger = NotifyDeliveryLedger.shared()
	if result.get("__transport_error__", false):
		var why: String = str(result.get("__transport_message__", ""))
		ledger.note_chat_outcome(owner_history_id, text,
			NotifyDeliveryLedger.CHAT_UNCONFIRMED if _sent_generation >= generation \
				else NotifyDeliveryLedger.CHAT_FAILED, why)
		return
	match str(result.get("kind", "")).strip_edges():
		"answer", "question", "pending":
			ledger.note_chat_outcome(owner_history_id, text, NotifyDeliveryLedger.CHAT_HANDED)
		"error":
			if bool(result.get("held", false)):
				ledger.note_chat_outcome(owner_history_id, text, NotifyDeliveryLedger.CHAT_HELD,
					str(result.get("text", "")), str(result.get("hold_reason", "")))
			else:
				ledger.note_chat_outcome(owner_history_id, text, NotifyDeliveryLedger.CHAT_UNCONFIRMED,
					str(result.get("text", "")))
		_:
			ledger.note_chat_outcome(owner_history_id, text, NotifyDeliveryLedger.CHAT_UNCONFIRMED,
				"unrecognised reply")


## A generate that ended before anything was sent to the plugin.
func _report_unsent(prompt: Array, why: String) -> void:
	NotifyDeliveryLedger.shared().note_chat_outcome(owner_history_id, _newest_user_text(prompt),
		NotifyDeliveryLedger.CHAT_FAILED, why)


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
	# Settling clears the active operation synchronously, so its token is read
	# first: a plugin that interrupts by operation (the terminal relay) needs
	# it to stop that turn, which may be parked between calls and will not be
	# resumed after this cancel.
	var args := {"chat_id": owner_history_id}
	if supports_in_place_interrupt():
		args["operation_token"] = _active_operation_token
	if _call_generation > 0:
		_cancelled_generation = _call_generation
	_cancel_active_context()
	if _call_generation > 0:
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
	conn.call_tool(cancel_tool, args)


## Opt-in passthrough interruption keeps the provider request alive while the
## plugin interrupts only the operation token that generated it.
func supports_in_place_interrupt() -> bool:
	return _active_interrupt_enabled \
		and _call_generation > _consumed_generation \
		and not _active_operation_token.is_empty()


func interrupt_active_request() -> bool:
	if not supports_in_place_interrupt():
		return false
	if _interrupt_requested:
		return true
	_interrupt_requested = true
	var generation := _call_generation
	var operation_token := _active_operation_token
	# Not sent yet (still being admitted): the plugin does not know the
	# operation, so it is stopped here and never sent.
	if _sent_generation != generation and _active_context != null and not _active_context.lifetime.dispatched:
		_interrupted_unsent = generation
		_cancel_active_context()
		return true
	var pm = _get_plugin_manager()
	if pm == null:
		_set_interrupt_error(generation, "Plugin manager unavailable; terminal interrupt was not sent.")
		return true
	var conn = pm.get_connection(_active_plugin_id)
	if conn == null:
		_set_interrupt_error(generation, "Plugin connection unavailable; terminal interrupt was not sent.")
		return true
	_dispatch_interrupt(conn, _active_cancel_tool, operation_token, generation)
	return true


func _dispatch_interrupt(conn, tool_name: String, operation_token: String, generation: int) -> void:
	var reply = await conn.call_tool(tool_name, {
		"chat_id": owner_history_id,
		"operation_token": operation_token,
	})
	if generation != _call_generation or operation_token != _active_operation_token:
		return
	if reply is Dictionary and (reply.has("error") or reply.get("isError", false)):
		_set_interrupt_error(generation, "Terminal interrupt failed: %s" % str(reply.get("error", reply)))


func _set_interrupt_error(generation: int, message: String) -> void:
	if generation != _call_generation:
		return
	interrupt_error = message
	_interrupt_requested = false
	push_error(message)
	SingletonObject.create_toast_notification(message, ToastNotification.Type.WARNING)


func _clear_active_operation(generation: int) -> void:
	if generation != _call_generation:
		return
	_active_operation_token = ""
	_active_interrupt_enabled = false
	_active_cancel_tool = ""
	_active_plugin_id = ""
	_interrupt_requested = false
	interrupt_error = ""


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


## Test-only injection of a stub plugin manager exposing get_connection(),
## used for the running check and the cancel and interrupt tools; the generate
## call itself goes through the registry and the host's tool server
## (_generate).
var _test_plugin_manager = null
