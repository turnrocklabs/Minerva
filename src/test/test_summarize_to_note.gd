extends SceneTree
## W6 (chat-passthrough): summarize-to-note button.
##
## Run: timeout 120 godot --headless --path src --script test/test_summarize_to_note.gd
##
## Acceptance (W6 contract):
##   1. ChatHeader has a summarize button BETWEEN the editor and notes buttons;
##      visible only when history.PassthroughMode.
##   2. Summarize flow (stub provider): one LLM call over the attributed
##      transcript ("You:" / "<PassthroughName>:") -> note created with title
##      prefix "Passthrough summary: <name>" + content == distilled text,
##      linked to the chat (note.linked_chat_ids — the same structure
##      minerva_link_note_to_chat mutates).
##   3. Empty transcript -> friendly no-op, ZERO provider calls, no note.
##   4. Provider error -> error surfaced, no note created, button re-enabled.
##   5. Busy state: second press while in flight is a no-op (1 call total);
##      button disabled during flight, re-enabled after.
##   6. Zero spontaneous spend: header + passthrough chat idling -> 0 calls.
##
## NOTE: class_name globals are invisible to --script runs; load() + duck-type.

const CHAT_HISTORY_PATH := "res://Scripts/Models/ChatHistory.gd"
const CHAT_HISTORY_ITEM_PATH := "res://Scripts/Models/ChatHistoryItem.gd"
const CHAT_HEADER_PATH := "res://Scripts/UI/Controls/ChatHeader.gd"
const CHATPANE_PATH := "res://Scripts/UI/Views/ChatPane.gd"

## Injectable fake provider (compiled at runtime; path-extends so no
## class_name resolution is needed). Untyped overrides are accepted and the
## instance passes typed BaseProvider assignments.
const STUB_SRC := """
extends "res://Scripts/Services/Providers/BaseProvider.gd"

var calls := 0
var response_text := "DISTILLED SUMMARY"
var fail_error := ""
var delay_frames := 0
var last_prompt = null

func Format(chat) -> Variant:
	return {"text": chat.Message}

func generate_content(prompt, _additional_params = {}):
	calls += 1
	last_prompt = prompt
	var i := 0
	while i < delay_frames:
		await Engine.get_main_loop().process_frame
		i += 1
	var r = load("res://Scripts/Models/BotResponse.gd").new()
	if fail_error != "":
		r.error = fail_error
	else:
		r.text = response_text
	return r
"""

var _pass := 0
var _fail := 0
var _stub_script: GDScript


func _init() -> void:
	print("=== W6 summarize-to-note test ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s%s" % [label, (" — " + detail) if detail != "" else ""])


func _make_stub():
	if _stub_script == null:
		_stub_script = GDScript.new()
		_stub_script.source_code = STUB_SRC
		var err := _stub_script.reload()
		assert(err == OK)
	return _stub_script.new()


func _make_passthrough_history(hist_id: String, with_turns: bool = true):
	var CH = load(CHAT_HISTORY_PATH)
	var history = CH.new(null, hist_id)
	history.PassthroughMode = true
	history.PassthroughName = "Claude CLI"
	if with_turns:
		var CHI = load(CHAT_HISTORY_ITEM_PATH)
		var u = CHI.new()
		u.Role = 0  # ChatRole.USER
		u.Message = "hello from the human"
		history.HistoryItemList.append(u)
		var a = CHI.new()
		a.Role = 1  # ChatRole.ASSISTANT
		a.Message = "hi, this is the CLI replying"
		history.HistoryItemList.append(a)
	return history


func _run() -> void:
	await process_frame
	var so = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload present", so != null)
	if so == null:
		return

	await _test_button_placement_and_visibility(so)
	await _test_summarize_flow(so)
	await _test_empty_transcript(so)
	await _test_provider_error(so)
	await _test_busy_state_via_header(so)
	await _test_zero_spontaneous_spend(so)


# --- Acceptance 1: button placement + visibility ----------------------------
func _test_button_placement_and_visibility(so) -> void:
	print("\n-- ChatHeader: summarize button placement + visibility --")
	var Header = load(CHAT_HEADER_PATH)

	var pt_history = _make_passthrough_history("hist-w6-btn", false)
	var header = Header.new()
	header.setup(pt_history)
	check("summarize_button exists", header.summarize_button != null)
	if header.summarize_button != null:
		check("visible on passthrough chat", header.summarize_button.visible)
		check("tooltip is 'Summarize to note'",
			header.summarize_button.tooltip_text == "Summarize to note",
			header.summarize_button.tooltip_text)
		check("has an icon", header.summarize_button.icon != null)
		check("sits between editor and notes buttons",
			header.editor_button.get_index() < header.summarize_button.get_index()
				and header.summarize_button.get_index() < header.notes_button.get_index(),
			"editor=%d summarize=%d notes=%d" % [header.editor_button.get_index(),
				header.summarize_button.get_index(), header.notes_button.get_index()])
		check("enabled (not busy) at rest", not header.summarize_button.disabled)

	var CH = load(CHAT_HISTORY_PATH)
	var plain = CH.new(null, "hist-w6-plain")
	var header2 = Header.new()
	header2.setup(plain)
	check("hidden on non-passthrough chat",
		header2.summarize_button != null and not header2.summarize_button.visible)

	header.free()
	header2.free()


# --- Acceptance 2: summarize flow with stub provider ------------------------
func _test_summarize_flow(so) -> void:
	print("\n-- Engine: summarize flow creates + links the note --")
	var pane = load(CHATPANE_PATH).new()
	var history = _make_passthrough_history("hist-w6-flow")
	var stub = _make_stub()

	var result: Dictionary = await pane.summarize_passthrough_to_note(history, stub)
	check("result ok", result.get("ok", false) == true, str(result))
	check("exactly one provider call", stub.calls == 1, str(stub.calls))

	# Transcript attribution reaches the provider
	var prompt_str := str(stub.last_prompt)
	check("prompt attributes user turns as 'You:'",
		prompt_str.contains("You: hello from the human"))
	check("prompt attributes bot turns with PassthroughName",
		prompt_str.contains("Claude CLI: hi, this is the CLI replying"))

	var note_id := str(result.get("note_id", ""))
	check("note_id returned", not note_id.is_empty())
	var note = so.get_registered_object(note_id)
	check("note registered + findable", note != null)
	if note != null:
		check("title has the contract prefix",
			str(note.title).begins_with("Passthrough summary: Claude CLI"), str(note.title))
		var controls = note.get_controls_container()
		check("note content includes distilled text + provenance stamp",
			controls != null and str(controls.content).begins_with("DISTILLED SUMMARY")
				and str(controls.content).find("Summary model:") != -1,
			str(controls.content) if controls != null else "<no controls>")
		check("note linked to THIS chat (link_note_to_chat structure)",
			note.linked_chat_ids.has("hist-w6-flow"), str(note.linked_chat_ids))
		note.free()

	check("in-flight flag cleared after completion",
		not pane.is_summarize_in_flight(history))

	stub.free()
	pane.free()


# --- Acceptance 3: empty transcript = no-op, zero LLM calls -----------------
func _test_empty_transcript(so) -> void:
	print("\n-- Engine: empty transcript -> friendly no-op, no LLM call --")
	var pane = load(CHATPANE_PATH).new()
	var stub = _make_stub()

	var empty_history = _make_passthrough_history("hist-w6-empty", false)
	var result: Dictionary = await pane.summarize_passthrough_to_note(empty_history, stub)
	check("not ok on empty transcript", result.get("ok", true) == false)
	check("error is empty_transcript", str(result.get("error", "")) == "empty_transcript", str(result))
	check("friendly message present", not str(result.get("message", "")).is_empty())
	check("ZERO provider calls", stub.calls == 0, str(stub.calls))
	check("no note created", str(result.get("note_id", "x")).is_empty())

	# Whitespace-only messages count as empty too.
	var ws_history = _make_passthrough_history("hist-w6-ws", false)
	var CHI = load(CHAT_HISTORY_ITEM_PATH)
	var w = CHI.new()
	w.Role = 0
	w.Message = "   \n  "
	ws_history.HistoryItemList.append(w)
	var result2: Dictionary = await pane.summarize_passthrough_to_note(ws_history, stub)
	check("whitespace-only transcript is empty too",
		str(result2.get("error", "")) == "empty_transcript" and stub.calls == 0, str(result2))

	stub.free()
	pane.free()


# --- Acceptance 4: provider error -> error path, no note --------------------
func _test_provider_error(so) -> void:
	print("\n-- Engine: provider error -> surfaced, no note --")
	var pane = load(CHATPANE_PATH).new()
	var history = _make_passthrough_history("hist-w6-err")
	var stub = _make_stub()
	stub.fail_error = "ChatGPT not connected. Please connect via Preferences."

	var result: Dictionary = await pane.summarize_passthrough_to_note(history, stub)
	check("not ok on provider error", result.get("ok", true) == false)
	check("error propagated", str(result.get("error", "")).contains("not connected"), str(result))
	check("no note created on error", str(result.get("note_id", "x")).is_empty())
	check("one call attempted", stub.calls == 1, str(stub.calls))
	check("in-flight flag cleared after error", not pane.is_summarize_in_flight(history))

	stub.free()
	pane.free()


# --- Acceptance 5: busy state via the header button --------------------------
func _test_busy_state_via_header(so) -> void:
	print("\n-- ChatHeader: busy state — no double-spend --")
	var pane = load(CHATPANE_PATH).new()
	var history = _make_passthrough_history("hist-w6-busy")
	var stub = _make_stub()
	stub.delay_frames = 8
	pane.distill_provider_override = stub
	so.Chats = pane

	var Header = load(CHAT_HEADER_PATH)
	var header = Header.new()
	header.setup(history)

	# First press: runs synchronously up to the stub's first await.
	header.summarize_button.pressed.emit()
	check("button disabled while in flight", header.summarize_button.disabled)
	check("engine reports in-flight", pane.is_summarize_in_flight(history))
	check("one call started", stub.calls == 1, str(stub.calls))

	# Second press mid-flight: no-op — call count must stay 1, and the early
	# return must NOT re-enable the button.
	header.summarize_button.pressed.emit()
	check("second press is a no-op (calls stay 1)", stub.calls == 1, str(stub.calls))
	check("button still disabled after second press", header.summarize_button.disabled)

	# Let the flight land.
	var guard := 0
	while pane.is_summarize_in_flight(history) and guard < 60:
		await process_frame
		guard += 1
	await process_frame
	check("flight completed", not pane.is_summarize_in_flight(history))
	check("button re-enabled after completion", not header.summarize_button.disabled)
	check("still exactly one call total", stub.calls == 1, str(stub.calls))

	# Error flight also re-enables the button (acceptance 4 tail).
	stub.delay_frames = 0
	stub.fail_error = "boom"
	header.summarize_button.pressed.emit()
	guard = 0
	while pane.is_summarize_in_flight(history) and guard < 60:
		await process_frame
		guard += 1
	await process_frame
	check("button re-enabled after error flight", not header.summarize_button.disabled)

	header.free()
	so.Chats = null
	pane.distill_provider_override = null
	stub.free()
	pane.free()


# --- Acceptance 6: zero spontaneous spend ------------------------------------
func _test_zero_spontaneous_spend(so) -> void:
	print("\n-- Invariant: no LLM call without the press --")
	var pane = load(CHATPANE_PATH).new()
	var stub = _make_stub()
	pane.distill_provider_override = stub
	so.Chats = pane

	var history = _make_passthrough_history("hist-w6-idle")
	var Header = load(CHAT_HEADER_PATH)
	var header = Header.new()
	header.setup(history)
	root.add_child(header)

	for i in range(12):
		await process_frame

	check("ZERO provider calls after construction + idle", stub.calls == 0, str(stub.calls))

	header.queue_free()
	so.Chats = null
	pane.distill_provider_override = null
	stub.free()
	pane.free()
	await process_frame
