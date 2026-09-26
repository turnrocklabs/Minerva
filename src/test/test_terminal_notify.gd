extends SceneTree
## Wide headless test of minerva_terminal_notify: one line delivered from one
## harness to another through Minerva.
##
## Run: godot --headless --path src --script test/test_terminal_notify.gd
##
## WHAT IS REAL HERE
##   the real MCPTerminalTools tool module (resolution, validation, envelope,
##   receipt), real PluginProvider instances carrying the "terminal-<id>" entry
##   ids that ARE the chat <-> terminal binding, the real ChatOutgoingQueue and
##   the real ChatPane queue helpers (_queue_if_busy / _release_chat_turn /
##   _drain_outgoing_queue), real ChatHistory objects in the real
##   SingletonObject.ChatList, and the real shared submit path
##   MCPToolUtils.submit_user_message.
##
## WHAT IS FAKED, AND WHY
##   - the terminal listing: the module's _terminal_list is overridden in a
##     subclass so the test does not need live PTYs (no forkpty headless).
##   - the watch profile map: injected through the module's watch_profile_source
##     seam, so profile addressing is exercisable without the agent-relay plugin.
##   - the relay's send tool: injected through relay_send_source, recording the
##     arguments the direct path hands the plugin and answering with a scripted
##     reply, so the unbound-terminal path is exercisable without a PTY.
##   - the turn body: ChatPane's full UI turn path cannot boot headless, so the
##     harness pane replaces ONLY the body of execute_regular_chat with the same
##     gate/turn/release shape the real one has, driving a blocking fake
##     provider. Section G asserts by source inspection that notify really
##     routes through the shared submit path and writes no bytes of its own.
##
## THE ORACLE (section E): while the claude chat is mid-turn, a notify addressed
## by profile returns status "queued" with a position, and the envelope becomes
## that chat's NEXT user turn once the in-flight turn ends.


const TERMINAL_TOOLS_PATH := "res://Scripts/Services/MCP/Modules/MCPTerminalTools.gd"
const CHATPANE_PATH := "res://Scripts/UI/Views/ChatPane.gd"
const CHAT_HISTORY_ITEM_PATH := "res://Scripts/Models/ChatHistoryItem.gd"
const World := preload("res://test/helpers/notify_world.gd")
const FAKE_PROVIDER_SRC := World.FAKE_PROVIDER_SRC
const HARNESS_PANE_SRC := World.HARNESS_PANE_SRC

## Pane that keeps the REAL execute_regular_chat and replaces only its two
## network-facing calls, so section K measures what the real executor does with
## a promoted envelope rather than what the harness body would do.
const REAL_TURN_PANE_SRC := """
extends "res://Scripts/UI/Views/ChatPane.gd"

## Texts that reached a real request, in order.
var real_generates: PackedStringArray = PackedStringArray()
## The request never resolves, so the turn stays in flight and the test never
## depends on the UI-bound tail of execute_regular_chat.
var blocked := true

func _ready() -> void:
	pass

func _update_stop_button() -> void:
	pass

func _update_compact_button() -> void:
	pass

func create_prompt(append_item: ChatHistoryItem = null, refresh_detached := true, provider_fallback: BaseProvider = null, predicate: Callable = Callable(), history_override: ChatHistory = null, _turn_token: int = -1) -> Array[Variant]:
	await get_tree().process_frame
	return []

func generate_content_from_provider(history: ChatHistory, history_list: Array, request_options: Variant = null, provider_override: BaseProvider = null) -> Variant:
	var sent: ChatHistoryItem = history.HistoryItemList[history.HistoryItemList.size() - 1]
	real_generates.append(sent.Message)
	# Stands in for PluginProvider._report_notify: this request IS the harness
	# here, so reaching it is the harness taking the line.
	load("res://Scripts/Services/Terminal/NotifyDeliveryLedger.gd").shared().note_chat_outcome(
		history.HistoryId, sent.Message, "handed")
	while blocked:
		await get_tree().process_frame
	return null
"""


## Runs one notify call as a DETACHED coroutine, so the test can change the
## world (end the in-flight turn) while the tool is still inside wait_ms.
const NOTIFY_RUNNER_SRC := """
extends RefCounted
var result: Dictionary = {}
var done: bool = false

func run(module, args: Dictionary) -> void:
	result = await module.handle("minerva_terminal_notify", args)
	done = true
"""

var _pass := 0
var _fail := 0
## Autoloads register after this script is compiled, so SingletonObject is
## resolved as a node at runtime rather than by identifier.
var _so: Node = null
var _saved_chats = null
## Real PreferencesPopup + NotesContainers for the host fields the real render
## path reads; without them the production code renders against nulls.
var _host_render := preload("res://test/helpers/chat_host_render_fixture.gd").new()


func _init() -> void:
	print("=== minerva_terminal_notify ===\n")
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
		print("FAIL: %s%s" % [label, ("  — " + detail) if detail else ""])


func _make_script(source: String) -> GDScript:
	return World.make_script(source)


func _make_bound_chat(chat_name: String, terminal_id: String):
	return World.make_bound_chat(chat_name, terminal_id)


func _make_pane(chats: Array, source: String = HARNESS_PANE_SRC) -> Node:
	return World.make_pane(self, _so, chats, source)


func _teardown(pane: Node, chats: Array) -> void:
	World.teardown(_so, _saved_chats, pane, chats)


func _make_module(terminals: Array, profiles: Dictionary) -> Object:
	return World.make_module(terminals, profiles)


## The one-look host entry (notify): a held line comes back held and is not
## kept. The MCP tool's keeping of held lines is exercised end to end, against
## the real relay, in test_notify_e2e.
func _notify(module: Object, args: Dictionary) -> Dictionary:
	return await module.notify(args)


func _run() -> void:
	await process_frame
	_so = root.get_node_or_null("/root/SingletonObject")
	check("S0: the SingletonObject autoload is live", _so != null)
	if _so == null:
		return
	_saved_chats = _so.Chats
	_host_render.install(_so)
	await _test_validation()
	await _test_resolution()
	await _test_no_match_and_ambiguity()
	await _test_renamed_tab_addressing()
	await _test_unbound_terminal()
	await _test_reply_address()
	await _test_queued_delivery_is_the_next_turn()
	await _test_wait_ms()
	await _test_receipt_follows_the_entry()
	await _test_a_notification_never_blocks_a_card_answer()
	await _test_a_notification_queued_mid_turn_stays_deferred()
	await _test_the_receipt_is_honest_on_an_unanswered_user_message()
	await _test_an_idle_chat_on_an_unanswered_user_message_is_still_notified()
	_test_wiring_is_present()
	_host_render.restore()


## The standing world: one claude and one codex terminal, each with a bound
## passthrough chat; a codex terminal with NO chat (the direct path); and a
## bare shell with nothing in the foreground.
func _world() -> Dictionary:
	var claude_chat = _make_bound_chat("Claude Session", "101")
	var codex_chat = _make_bound_chat("Codex Session", "202")
	var chats: Array = [claude_chat, codex_chat]
	var pane = _make_pane(chats)
	var provider = _make_script(FAKE_PROVIDER_SRC).new()
	provider.tree = self
	pane.provider = provider
	var terminals: Array = [
		{"id": "101", "name": "Claude Session", "harness": "claude"},
		{"id": "202", "name": "Codex Session", "harness": "codex"},
		{"id": "303", "name": "Scratch", "foreground_process": "bash"},
		{"id": "505", "name": "Codex Bare", "harness": "codex", "foreground_process": "codex"},
	]
	var module = _make_module(terminals, {"101": "claude", "202": "codex"})
	return {
		"pane": pane, "provider": provider, "module": module, "chats": chats,
		"claude": claude_chat, "codex": codex_chat,
	}


#region A — the line is a pointer, not a payload

func _test_validation() -> void:
	var w: = _world()
	var module: Object = w["module"]

	var newline: Dictionary = await _notify(module,
		{"to": "claude", "from": "codex", "text": "line one\nline two"})
	check("A1: a text with a newline is refused",
		not newline.get("success", true) and str(newline.get("error", "")).contains("ONE line"),
		str(newline))

	var long_text: = "x".repeat(module.NOTIFY_MAX_TEXT_LENGTH + 1)
	var too_long: Dictionary = await _notify(module,
		{"to": "claude", "from": "codex", "text": long_text})
	check("A2: a text over the cap is refused",
		not too_long.get("success", true) and str(too_long.get("error", "")).contains("cap"),
		str(too_long))

	var at_cap: Dictionary = await _notify(module, {"to": "claude", "from": "codex",
		"text": "y".repeat(module.NOTIFY_MAX_TEXT_LENGTH)})
	check("A3: a text exactly at the cap is accepted", at_cap.get("success", false),
		str(at_cap))

	var no_to: Dictionary = await _notify(module, {"to": "", "from": "codex", "text": "hi"})
	check("A4: an empty target is refused", not no_to.get("success", true))

	var no_from: Dictionary = await _notify(module, {"to": "claude", "from": "", "text": "hi"})
	check("A5: an empty from is refused", not no_from.get("success", true))

	var no_text: Dictionary = await _notify(module, {"to": "claude", "from": "codex", "text": "  "})
	check("A6: an empty text is refused", not no_text.get("success", true))

	# The envelope is typed into a terminal: a control byte in it is a
	# keystroke, not text. ESC is the one that steers the harness.
	for control: Array in [["\u001b", "ESC"], ["\u0007", "BEL"], ["\t", "TAB"],
			["\u007f", "DEL"]]:
		var in_text: Dictionary = await _notify(module, {"to": "claude", "from": "codex",
			"text": "look at the board" + str(control[0]) + "[2J"})
		check("A7: %s in text is refused" % control[1],
			not in_text.get("success", true)
				and str(in_text.get("error", "")).contains("control character"),
			str(in_text))
		# Mid-string: strip_edges() already removes an EDGE tab, and the point
		# is the byte surviving into the envelope.
		var in_from: Dictionary = await _notify(module, {"to": "claude",
			"from": "co" + str(control[0]) + "dex", "text": "look at the board"})
		check("A8: %s in from is refused" % control[1],
			not in_from.get("success", true)
				and str(in_from.get("error", "")).contains("control character"),
			str(in_from))
	check("A9: nothing with a control byte was delivered",
		w["provider"].texts_for("Claude Session").size() == 1, str(w["provider"].calls))

	# A3 really started a turn — release it so the harness tears down clean.
	w["provider"].release("Claude Session",
		"[MINERVA NOTIFY from codex] " + "y".repeat(module.NOTIFY_MAX_TEXT_LENGTH))
	for _i in range(4):
		await process_frame
	_teardown(w["pane"], w["chats"])

#endregion


#region B — resolution by name, profile and id

func _test_resolution() -> void:
	for addressing: Array in [["Claude Session", "tab name"],
			["claude session", "tab name, case-insensitive"],
			["claude", "harness"],
			["claude@Claude Session", "harness@tab name"],
			["101", "terminal id"]]:
		var w: = _world()
		var module: Object = w["module"]
		var provider = w["provider"]

		var receipt: Dictionary = await _notify(module,
			{"to": addressing[0], "from": "codex", "text": "board is green"})
		await process_frame
		check("B: '%s' resolves by %s" % [addressing[0], addressing[1]],
			receipt.get("success", false)
				and str(receipt.get("target", {}).get("terminal_id", "")) == "101"
				and str(receipt.get("target", {}).get("chat_id", ""))
					== str(w["claude"].HistoryId),
			str(receipt))
		check("B: an idle chat's harness takes it at once (%s)" % addressing[1],
			str(receipt.get("status", "")) == "handed_to_harness"
				and int(receipt.get("queue_position", -1)) == 0, str(receipt))
		check("B: the envelope is what the target receives (%s)" % addressing[1],
			str(provider.texts_for("Claude Session"))
				== str(PackedStringArray(["[MINERVA NOTIFY from codex] board is green"])),
			str(provider.calls))
		check("B: the other chat is untouched (%s)" % addressing[1],
			provider.texts_for("Codex Session").is_empty(), str(provider.calls))

		provider.release("Claude Session", "[MINERVA NOTIFY from codex] board is green")
		for _i in range(4):
			await process_frame
		_teardown(w["pane"], w["chats"])

#endregion


#region C — no match and ambiguity are errors, never a guess

func _test_no_match_and_ambiguity() -> void:
	var w: = _world()
	var module: Object = w["module"]

	var unknown: Dictionary = await _notify(module,
		{"to": "gemini", "from": "codex", "text": "hello"})
	check("C1: an unknown target is an error", not unknown.get("success", true))
	check("C2: the error lists the candidates",
		str(unknown.get("error", "")).contains("Claude Session")
			and str(unknown.get("error", "")).contains("Codex Session"),
		str(unknown.get("error", "")))
	check("C3: nothing was delivered", w["provider"].calls.is_empty())
	_teardown(w["pane"], w["chats"])

	# Two watched claude terminals: the profile no longer names one terminal.
	var first = _make_bound_chat("Claude One", "101")
	var second = _make_bound_chat("Claude Two", "404")
	var chats: Array = [first, second]
	var pane = _make_pane(chats)
	var provider = _make_script(FAKE_PROVIDER_SRC).new()
	provider.tree = self
	pane.provider = provider
	var module2 = _make_module([
		{"id": "101", "name": "Claude One"},
		{"id": "404", "name": "Claude Two"},
	], {"101": "claude", "404": "claude"})

	var ambiguous: Dictionary = await _notify(module2,
		{"to": "claude", "from": "codex", "text": "hello"})
	check("C4: a profile matching two terminals is an error",
		not ambiguous.get("success", true), str(ambiguous))
	check("C5: the error names BOTH candidates",
		str(ambiguous.get("error", "")).contains("101")
			and str(ambiguous.get("error", "")).contains("404"),
		str(ambiguous.get("error", "")))
	check("C6: an ambiguous notification is never guessed at", provider.calls.is_empty())

	var by_id: Dictionary = await _notify(module2,
		{"to": "404", "from": "codex", "text": "hello"})
	await process_frame
	check("C7: the terminal id disambiguates it",
		by_id.get("success", false)
			and str(by_id.get("target", {}).get("terminal_id", "")) == "404", str(by_id))
	provider.release("Claude Two", "[MINERVA NOTIFY from codex] hello")
	for _i in range(4):
		await process_frame
	_teardown(pane, chats)

#endregion


#region C2 — a renamed tab answers to the name its child still sees

## MINERVA_TERMINAL_NAME is fixed when the shell is spawned, so a harness that
## quotes its own name addresses a renamed tab by a name the tab bar no longer
## shows (the listing reports it as launch_name). Both names resolve, alone and
## after a harness@. Two tabs sharing one launch_name is an ambiguity, refused
## the same way a shared harness is. Delivery itself is section B's business —
## this drives the resolver, which is the part a rename can break.
func _test_renamed_tab_addressing() -> void:
	var renamed: Array = [
		{"id": "101", "name": "ops", "launch_name": "Terminal", "harness": "codex"},
		{"id": "202", "name": "notes", "harness": "claude"},
	]
	var module = _make_module(renamed, {})
	for address: String in ["Terminal", "ops", "codex@Terminal", "codex@ops"]:
		var target: Dictionary = await module._resolve_notify_target(address, renamed)
		check("C8: '%s' reaches the renamed tab" % address,
			target.get("success", false)
				and str(target.get("terminal_id", "")) == "101", str(target))

	var shared: Array = [
		{"id": "101", "name": "ops", "launch_name": "Terminal", "harness": "codex"},
		{"id": "404", "name": "logs", "launch_name": "Terminal", "harness": "codex"},
	]
	var module2 = _make_module(shared, {})
	var ambiguous: Dictionary = await module2._resolve_notify_target("Terminal", shared)
	check("C9: a launch_name shared by two tabs is refused, not guessed",
		not ambiguous.get("success", true), str(ambiguous))
	check("C10: the refusal names both terminal ids",
		str(ambiguous.get("error", "")).contains("101")
			and str(ambiguous.get("error", "")).contains("404"),
		str(ambiguous.get("error", "")))

#endregion


#region D — a terminal with no passthrough chat goes through the relay

func _test_unbound_terminal() -> void:
	var w: = _world()
	var module: Object = w["module"]
	var now: int = int(Time.get_unix_time_from_system() * 1000.0)

	var shell: Dictionary = await _notify(module,
		{"to": "Scratch", "from": "codex", "text": "hello"})
	check("D1: a bare shell is refused — the line would run as a command",
		not shell.get("success", true) and str(shell.get("error", "")).contains("harness"),
		str(shell))
	check("D2: nothing was delivered anywhere",
		w["provider"].calls.is_empty() and module.relay_calls.is_empty())
	# A readable shell prompt stays a shell even where a watch once ran.
	var stale_watch = _make_module(module.terminals, {"303": "claude"})
	var watched_shell: Dictionary = await _notify(stale_watch,
		{"to": "Scratch", "from": "codex", "text": "hello"})
	check("D2b: a stale watch profile does not turn a readable shell into a harness",
		not watched_shell.get("success", true) and stale_watch.relay_calls.is_empty(),
		str(watched_shell))
	# A foreground the platform reports but could not read just now is a hold,
	# never "no harness" and never a write.
	var unreadable: Array = module.terminals.duplicate(true)
	unreadable[3].erase("harness")
	unreadable[3]["foreground_process"] = ""
	var blind = _make_module(unreadable, {})
	var unknown: Dictionary = await _notify(blind,
		{"to": "Codex Bare", "from": "claude", "text": "hello"})
	check("D2d: an unreadable foreground holds with reason foreground_unknown",
		not unknown.get("success", true) and str(unknown.get("hold_reason", "")) == "foreground_unknown"
			and blind.relay_calls.is_empty(), str(unknown))
	# A bound chat does not exempt a shell: the chat's relay would type into it.
	var chat_shell: Array = module.terminals.duplicate(true)
	chat_shell[0].erase("harness")
	chat_shell[0]["foreground_process"] = "bash"
	var bound_shell = _make_module(chat_shell, {})
	var chat_refused: Dictionary = await _notify(bound_shell,
		{"to": "Claude Session", "from": "codex", "text": "hello"})
	check("D2c: a chat-bound terminal whose harness has exited is refused on the chat path too",
		not chat_refused.get("success", true) and str(chat_refused.get("error", "")).contains("harness")
			and w["provider"].calls.is_empty(), str(chat_refused))

	var direct: Dictionary = await _notify(module,
		{"to": "Codex Bare", "from": "claude", "text": "review posted", "wait_ms": 1500})
	check("D3: an unbound codex terminal is written through the relay",
		direct.get("success", false) and str(direct.get("status", "")) == "handed_to_harness"
			and str(direct.get("submit", "")) == "submitted", str(direct))
	check("D4: the relay is told the harness, no arming, ONE look, and the write-time typing guard",
		module.relay_calls.size() == 1
			and str(module.relay_calls[0].get("terminal_id", "")) == "505"
			and str(module.relay_calls[0].get("profile", "")) == "codex"
			and module.relay_calls[0].get("arm", true) == false
			and int(module.relay_calls[0].get("gate_budget_ms", -1)) == 0
			and int(module.relay_calls[0].get("human_guard_ms", -1)) == 5000
			and str(module.relay_calls[0].get("expect_harness", "")) == "codex",
		str(module.relay_calls))
	check("D5: the relay types the host-built envelope",
		module.relay_calls.size() == 1
			and str(module.relay_calls[0].get("text", ""))
				== "[MINERVA NOTIFY from claude] review posted", str(module.relay_calls))
	check("D6: no chat was involved", w["provider"].calls.is_empty()
		and not direct.get("target", {}).has("chat_id"), str(direct))

	# The relay refusing to write is a HOLD the sender can retry, not a failure;
	# with a wait the host keeps looking, one look at a time, until the budget
	# lapses.
	module.relay_reply = {"error": "terminal 505 is showing a permission dialog that wants a keystroke; nothing was written", "held": true}
	var looks_before: int = module.relay_calls.size()
	var started: int = Time.get_ticks_msec()
	var held: Dictionary = await _notify(module,
		{"to": "505", "from": "claude", "text": "again", "wait_ms": 600})
	check("D7: a screen that owns the keyboard holds the notification",
		not held.get("success", true) and str(held.get("status", "")) == "held"
			and str(held.get("hold_reason", "")) == "screen", str(held))
	var looks: int = module.relay_calls.size() - looks_before
	check("D7b: the host keeps looking within the wait, one-shot each time, and never after it",
		looks >= 2 and looks <= 3
			and int(module.relay_calls[-1].get("gate_budget_ms", -1)) == 0
			and int(module.relay_call_times[-1]) <= started + 600,
		"%d looks, last at +%d ms" % [looks, int(module.relay_call_times[-1]) - started])
	module.relay_reply = {"error": "terminal write failed: boom"}
	var looks_at_error: int = module.relay_calls.size()
	var broken: Dictionary = await _notify(module,
		{"to": "505", "from": "claude", "text": "again", "wait_ms": 600})
	check("D7c: an unmarked relay error is an error, not a hold, and is not retried",
		not broken.get("success", true) and str(broken.get("status", "")) == "error"
			and module.relay_calls.size() == looks_at_error + 1, str(broken))
	# The relay's refusal names the guard that refused it. The hold reason is
	# read from those keys, so a message with no recognisable prose still
	# classifies — the composer hold no longer depends on its phrase.
	module.relay_reply = {"error": "refused", "held": true,
		"outcome": "refused_composer_not_empty"}
	var composer_held: Dictionary = await _notify(module,
		{"to": "505", "from": "claude", "text": "again"})
	check("D7d: a structured refusal names the hold reason without any prose",
		not composer_held.get("success", true)
			and str(composer_held.get("status", "")) == "held"
			and str(composer_held.get("hold_reason", "")) == "composer_not_empty",
		str(composer_held))
	module.relay_reply = {"ok": true, "submit": {"state": "submitted", "evidence": "echo"}}

	# A person typing in the target outranks any agent, on BOTH paths.
	module.terminals[3]["last_input_ms"] = now - 1000
	module.terminals[0]["last_input_ms"] = now - 1000
	var calls_before: int = module.relay_calls.size()
	var typing_direct: Dictionary = await _notify(module,
		{"to": "Codex Bare", "from": "claude", "text": "hello"})
	var typing_chat: Dictionary = await _notify(module,
		{"to": "Claude Session", "from": "codex", "text": "hello"})
	check("D8: a keystroke 1 s ago holds the direct path with reason human_typing",
		not typing_direct.get("success", true)
			and str(typing_direct.get("hold_reason", "")) == "human_typing"
			and module.relay_calls.size() == calls_before, str(typing_direct))
	check("D9: and holds the chat path the same way",
		not typing_chat.get("success", true)
			and str(typing_chat.get("hold_reason", "")) == "human_typing"
			and w["provider"].calls.is_empty(), str(typing_chat))
	module.terminals[3]["last_input_ms"] = now - 30000
	var later: Dictionary = await _notify(module,
		{"to": "Codex Bare", "from": "claude", "text": "hello"})
	check("D10: a keystroke 30 s ago is nobody typing", later.get("success", false)
		and module.relay_calls.size() == calls_before + 1, str(later))
	# A wait outlasts the typing window: the keystroke was 4.5 s ago, the
	# guard is 5 s, the caller waits 2 s — one delivery, after the guard clears.
	module.terminals[3]["last_input_ms"] = int(Time.get_unix_time_from_system() * 1000.0) - 4500
	var before_wait: int = module.relay_calls.size()
	var t0: int = Time.get_ticks_msec()
	var waited: Dictionary = await _notify(module,
		{"to": "Codex Bare", "from": "claude", "text": "hello", "wait_ms": 2000})
	check("D11: a direct wait outlasts a recent keystroke and delivers exactly once",
		waited.get("success", false) and module.relay_calls.size() == before_wait + 1
			and Time.get_ticks_msec() - t0 >= 400, "%s after %d ms" % [str(waited), Time.get_ticks_msec() - t0])

	_teardown(w["pane"], w["chats"])

#endregion


#region I — the reply address rides inside the envelope

func _test_reply_address() -> void:
	var w: = _world()
	var module: Object = w["module"]

	var bad: Dictionary = await _notify(module,
		{"to": "Codex Bare", "from": "claude@Claude Session", "text": "look at 1234",
			"reply_to": "999"})
	check("I1: a reply_to that is no terminal is refused",
		not bad.get("success", true) and str(bad.get("error", "")).contains("reply_to"), str(bad))
	check("I2: and nothing was written", module.relay_calls.is_empty())

	var forged: Dictionary = await _notify(module,
		{"to": "Codex Bare", "from": "claude (reply to: 999)", "text": "look at 1234"})
	check("I2b: a reply address smuggled into from is refused",
		not forged.get("success", true) and module.relay_calls.is_empty(), str(forged))

	var good: Dictionary = await _notify(module,
		{"to": "Codex Bare", "from": "claude@Claude Session", "text": "look at 1234",
			"reply_to": "101"})
	check("I3: the envelope carries the sender's name and reply address",
		good.get("success", false) and module.relay_calls.size() == 1
			and str(module.relay_calls[0].get("text", ""))
				== "[MINERVA NOTIFY from claude@Claude Session (reply to: 101)] look at 1234",
		str(module.relay_calls))

	_teardown(w["pane"], w["chats"])

#endregion


#region E — THE ORACLE: a busy target queues, then takes the envelope next

func _test_queued_delivery_is_the_next_turn() -> void:
	var w: = _world()
	var module: Object = w["module"]
	var pane = w["pane"]
	var provider = w["provider"]
	var claude_chat = w["claude"]

	pane.current_tab = _so.ChatList.find(claude_chat)
	pane.execute_regular_chat("mid-turn work")
	await process_frame
	check("E1: the claude chat is mid-turn",
		claude_chat.is_request_active
			and str(provider.texts_for("Claude Session"))
				== str(PackedStringArray(["mid-turn work"])), str(provider.calls))

	var receipt: Dictionary = await _notify(module,
		{"to": "claude", "from": "codex", "text": "review is red on P2.T4"})
	await process_frame
	check("E2: the receipt says QUEUED with a position",
		receipt.get("success", false) and str(receipt.get("status", "")) == "queued"
			and int(receipt.get("queue_position", 0)) == 1, str(receipt))
	check("E3: the receipt names the target terminal and chat",
		str(receipt.get("target", {}).get("terminal_id", "")) == "101"
			and str(receipt.get("target", {}).get("name", "")) == "Claude Session"
			and str(receipt.get("target", {}).get("chat_id", ""))
				== str(claude_chat.HistoryId), str(receipt))
	check("E4: no second turn started alongside the in-flight one",
		provider.texts_for("Claude Session").size() == 1, str(provider.calls))

	var envelope: = "[MINERVA NOTIFY from codex] review is red on P2.T4"
	check("E5: the envelope is what sits in the outgoing queue",
		str(pane._outgoing_queue.pending_texts(claude_chat.HistoryId))
			== str(PackedStringArray([envelope])),
		str(pane._outgoing_queue.pending_texts(claude_chat.HistoryId)))

	provider.release("Claude Session", "mid-turn work")
	for _i in range(6):
		await process_frame
	check("E6: the envelope becomes the chat's NEXT user turn",
		str(provider.texts_for("Claude Session"))
			== str(PackedStringArray(["mid-turn work", envelope])), str(provider.calls))
	check("E7: the queue is empty again",
		not pane._outgoing_queue.has_pending(claude_chat.HistoryId))

	provider.release("Claude Session", envelope)
	for _i in range(4):
		await process_frame
	_teardown(pane, w["chats"])

#endregion


#region F — wait_ms

func _test_wait_ms() -> void:
	var w: = _world()
	var module: Object = w["module"]
	var pane = w["pane"]
	var provider = w["provider"]
	var claude_chat = w["claude"]

	pane.current_tab = _so.ChatList.find(claude_chat)
	pane.execute_regular_chat("mid-turn work")
	await process_frame

	# Run the notify as a detached coroutine so the test can end the in-flight
	# turn WHILE the tool is still waiting for its entry to be dispatched.
	var runner = _make_script(NOTIFY_RUNNER_SRC).new()
	runner.run(module, {"to": "claude", "from": "codex", "text": "come look",
		"wait_ms": 5000})
	await process_frame
	check("F1: the tool is still waiting while the target is busy", not runner.done)

	provider.release("Claude Session", "mid-turn work")
	for _i in range(20):
		if runner.done:
			break
		await process_frame
	check("F2: wait_ms returns once the queued line is taken by the harness",
		runner.done and str(runner.result.get("status", "")) == "handed_to_harness"
			and int(runner.result.get("queue_position", -1)) == 0,
		str(runner.result))
	check("F3: and the line really did become the next turn",
		str(provider.texts_for("Claude Session"))
			== str(PackedStringArray(["mid-turn work",
				"[MINERVA NOTIFY from codex] come look"])), str(provider.calls))

	provider.release("Claude Session", "[MINERVA NOTIFY from codex] come look")
	for _i in range(4):
		await process_frame
	_teardown(pane, w["chats"])

#endregion


#region I — a notification never blocks the answer to a live question card

## THE DEADLOCK THIS PREVENTS: a passthrough turn that ended in a question
## leaves the chat IDLE with a card under the last bot message — the agent in
## the terminal is blocked, waiting for the answer. A notification that started
## a turn there would be held by the relay's send gate until the card clears,
## while the human's answer — a plain message on the same chat — would queue
## BEHIND the notification and never reach the relay's bypass. Both sides then
## wait for a timeout.
##
## The rule: a notify is a BACKGROUND message. While a question is pending it
## starts no turn at all; it is queued as a deferred entry, the human's answer
## runs first, and the notification follows once a turn ends with no question.
func _test_a_notification_never_blocks_a_card_answer() -> void:
	var w: = _world()
	var module: Object = w["module"]
	var pane = w["pane"]
	var provider = w["provider"]
	var claude_chat = w["claude"]

	# A turn that ends in a question, finalized: the chat is idle, with an
	# unanswered card.
	pane.current_tab = _so.ChatList.find(claude_chat)
	provider.mark_question("Claude Session", "run the migration")
	pane.execute_regular_chat("run the migration")
	await process_frame
	provider.release("Claude Session", "run the migration")
	for _i in range(6):
		await process_frame
	check("I1: the chat is idle, waiting for the answer to a question card",
		not claude_chat.is_request_active and claude_chat.is_awaiting_question_answer(),
		"active=%s awaiting=%s items=%d" % [claude_chat.is_request_active,
			claude_chat.is_awaiting_question_answer(), claude_chat.HistoryItemList.size()])

	var receipt: Dictionary = await _notify(module,
		{"to": "claude", "from": "codex", "text": "board is red"})
	for _i in range(3):
		await process_frame
	var envelope: = "[MINERVA NOTIFY from codex] board is red"
	check("I2: the notify is QUEUED, not run — the blocked agent keeps its turn",
		receipt.get("success", false) and str(receipt.get("status", "")) == "queued"
			and int(receipt.get("queue_position", 0)) == 1, str(receipt))
	check("I3: no generate started for the notification",
		not provider.texts_for("Claude Session").has(envelope),
		str(provider.calls))

	# The human answers the card in the ordinary way: a plain message.
	pane.current_tab = _so.ChatList.find(claude_chat)
	pane.execute_regular_chat("1")
	await process_frame
	check("I4: the human's answer starts AT ONCE — it is not behind the notify",
		claude_chat.is_request_active
			and provider.texts_for("Claude Session").has("1"), str(provider.calls))
	check("I5: and the notification is still waiting its turn",
		int(pane._outgoing_queue.position_of(int(receipt["entry_id"]))) == 1,
		str(pane._outgoing_queue.pending_texts(claude_chat.HistoryId)))

	provider.release("Claude Session", "1")
	for _i in range(6):
		await process_frame
	check("I6: once the turn ends with no question pending, the notify runs",
		provider.texts_for("Claude Session").has(envelope)
			and not claude_chat.is_awaiting_question_answer(), str(provider.calls))
	check("I7: the queue is empty again",
		not pane._outgoing_queue.has_pending(claude_chat.HistoryId))

	provider.release("Claude Session", envelope)
	for _i in range(6):
		await process_frame
	_teardown(pane, w["chats"])

#endregion


#region J — a notification queued MID-TURN is still deferred when that turn
#           ends in a question

## Section I covers the notify that arrives AFTER the question card exists.
## The harder case is the notify that arrives while the turn is still running
## and that turn then ends in a question: at the moment it was queued there was
## no card to see. If it were queued as an ordinary entry, the drain at the end
## of that turn would promote it — the relay would hold it behind the dialog and
## the human's answer would queue behind the notification's live request, which
## is the same deadlock. So a notify is queued as a BACKGROUND entry whenever it
## is queued at all, in-flight turn included.
func _test_a_notification_queued_mid_turn_stays_deferred() -> void:
	var w: = _world()
	var module: Object = w["module"]
	var pane = w["pane"]
	var provider = w["provider"]
	var claude_chat = w["claude"]

	# A turn that will end in a question is IN FLIGHT — no card exists yet.
	pane.current_tab = _so.ChatList.find(claude_chat)
	provider.mark_question("Claude Session", "run the migration")
	pane.execute_regular_chat("run the migration")
	await process_frame
	check("J1: the chat is mid-turn and no card is pending yet",
		claude_chat.is_request_active and not claude_chat.is_awaiting_question_answer())

	var receipt: Dictionary = await _notify(module,
		{"to": "claude", "from": "codex", "text": "board is red"})
	await process_frame
	var envelope: = "[MINERVA NOTIFY from codex] board is red"
	check("J2: the notify queues behind the in-flight turn",
		receipt.get("success", false) and str(receipt.get("status", "")) == "queued"
			and int(receipt.get("queue_position", 0)) == 1, str(receipt))

	# The turn ends AS A QUESTION. The drain must pass the notification over.
	provider.release("Claude Session", "run the migration")
	for _i in range(8):
		await process_frame
	check("J3: the turn left a pending question card",
		not claude_chat.is_request_active and claude_chat.is_awaiting_question_answer(),
		"active=%s awaiting=%s" % [claude_chat.is_request_active,
			claude_chat.is_awaiting_question_answer()])
	check("J4: the drain did NOT promote the notification",
		not provider.texts_for("Claude Session").has(envelope), str(provider.calls))
	check("J5: it kept its place in the queue",
		int(pane._outgoing_queue.position_of(int(receipt["entry_id"]))) == 1,
		str(pane._outgoing_queue.pending_texts(claude_chat.HistoryId)))

	# The human answers the card: their plain message starts at once.
	pane.current_tab = _so.ChatList.find(claude_chat)
	pane.execute_regular_chat("1")
	await process_frame
	check("J6: the human's answer starts a turn immediately",
		claude_chat.is_request_active
			and provider.texts_for("Claude Session").has("1"), str(provider.calls))

	provider.release("Claude Session", "1")
	for _i in range(8):
		await process_frame
	check("J7: the notification follows once that turn ends with no question",
		provider.texts_for("Claude Session").has(envelope)
			and not claude_chat.is_awaiting_question_answer(), str(provider.calls))
	check("J8: the queue is empty again",
		not pane._outgoing_queue.has_pending(claude_chat.HistoryId))

	provider.release("Claude Session", envelope)
	for _i in range(6):
		await process_frame
	_teardown(pane, w["chats"])

#endregion


#region G — the wiring the harness stands in for

func _test_wiring_is_present() -> void:
	var source: = FileAccess.get_file_as_string(TERMINAL_TOOLS_PATH)
	check("G1: MCPTerminalTools.gd is readable", not source.is_empty())
	check("G2: the tool is declared and registered",
		source.find('"minerva_terminal_notify",') != -1
			and source.find('server._register_tool("minerva_terminal_notify"') != -1)

	var body_start: = source.find("func _terminal_notify(")
	var body_end: = source.find("\nfunc ", body_start + 10)
	var body: = source.substr(body_start, body_end - body_start)
	check("G3: notify submits through the SHARED send path, not its own",
		body.find("MCPToolUtils.submit_user_message(history, envelope") != -1)
	check("G3b: notify submits as a BACKGROUND message (deferred while a card waits)",
		body.find("submit_user_message(history, envelope, {}, true, urgent)") != -1, body)
	check("G4: notify owns no delivery code of its own",
		body.find("write_input") == -1 and body.find("session.") == -1, body)
	check("G5: the envelope is built by the host, from the shared prefix",
		body.find("NOTIFY_ENVELOPE_PREFIX, from, reply_suffix, text") != -1
			and source.find('const NOTIFY_ENVELOPE_PREFIX := "[MINERVA NOTIFY from "') != -1)

	# The chat tool must keep using the same submit path, or the two MCP send
	# entry points drift and only one of them honours the outgoing queue.
	var chat_source: = FileAccess.get_file_as_string(
		"res://Scripts/Services/MCP/Modules/MCPChatTools.gd")
	check("G6: minerva_send_message uses the same submit path",
		chat_source.find("MCPToolUtils.submit_user_message(") != -1)

	# That shared path is the one that reaches ChatPane's queue gate.
	var utils_source: = FileAccess.get_file_as_string(
		"res://Scripts/Services/MCP/Modules/MCPToolUtils.gd")
	check("G7: the submit path goes through execute_regular_chat, as promoted",
		utils_source.find("chat_pane.execute_regular_chat(text, generation_options, true)") != -1)
	check("G7b: and defers a background message while a question card is pending —",
		utils_source.find("defer_when_question_pending and (history.is_awaiting_question_answer()") != -1
			and utils_source.find("chat_pane.enqueue_background_message(") != -1)
	check("G7c: — and while a turn that could END in a question is in flight",
		utils_source.find("or history.is_request_active)") != -1, "")

	var pane_source: = FileAccess.get_file_as_string(CHATPANE_PATH)
	check("G8: execute_regular_chat still gates on the outgoing queue",
		pane_source.find("_queue_if_busy(history, text") != -1)

#endregion


#region H — the receipt follows the queue ENTRY, not the text

## Two things the envelope text cannot tell the sender: whether the line it
## queued actually RAN (a cancelled line also leaves the queue), and which of
## two identical lines is which. The queue entry's id answers both.
func _test_receipt_follows_the_entry() -> void:
	# ── a cancelled line is reported as dropped, never as dispatched ──
	var w: = _world()
	var module: Object = w["module"]
	var pane = w["pane"]
	var provider = w["provider"]
	var claude_chat = w["claude"]

	pane.current_tab = _so.ChatList.find(claude_chat)
	pane.execute_regular_chat("mid-turn work")
	await process_frame

	var runner = _make_script(NOTIFY_RUNNER_SRC).new()
	runner.run(module, {"to": "claude", "from": "codex", "text": "come look",
		"wait_ms": 5000})
	await process_frame
	check("H1: the notify is queued behind the in-flight turn", not runner.done)

	# The user presses stop: the cancel rule discards the queued line, so it
	# never runs.
	pane._cancel_chat_turn(claude_chat)
	for _i in range(20):
		if runner.done:
			break
		await process_frame
	check("H2: a cancelled line is reported as DROPPED, not dispatched",
		runner.done and str(runner.result.get("status", "")) == "dropped",
		str(runner.result))
	check("H3: and it really never became a turn",
		not provider.texts_for("Claude Session").has(
			"[MINERVA NOTIFY from codex] come look"), str(provider.calls))

	provider.release("Claude Session", "mid-turn work")
	for _i in range(4):
		await process_frame
	_teardown(pane, w["chats"])

	# ── two identical lines are two entries, in order ──
	var w2: = _world()
	var module2: Object = w2["module"]
	var pane2 = w2["pane"]
	var provider2 = w2["provider"]
	var claude2 = w2["claude"]

	pane2.current_tab = _so.ChatList.find(claude2)
	pane2.execute_regular_chat("busy")
	await process_frame

	var same: Dictionary = {"to": "claude", "from": "codex", "text": "same line"}
	var first: Dictionary = await _notify(module2, same)
	var second: Dictionary = await _notify(module2, same)
	check("H4: identical lines queue as separate entries",
		int(first.get("entry_id", 0)) > 0
			and int(second.get("entry_id", 0)) > 0
			and int(first["entry_id"]) != int(second["entry_id"]),
		"%s / %s" % [str(first), str(second)])
	check("H5: and hold positions 1 and 2, not the same one",
		int(first.get("queue_position", -1)) == 1
			and int(second.get("queue_position", -1)) == 2,
		"%s / %s" % [str(first), str(second)])

	provider2.release("Claude Session", "busy")
	for _i in range(8):
		await process_frame
	check("H6: the first entry is the one that ran",
		provider2.texts_for("Claude Session").has("[MINERVA NOTIFY from codex] same line"),
		str(provider2.calls))
	provider2.release("Claude Session", "[MINERVA NOTIFY from codex] same line")
	for _i in range(8):
		await process_frame
	_teardown(pane2, w2["chats"])

	# ── an entry whose outcome has been EVICTED is not reported as dispatched ──
	# The outcome record is a fixed-size ring, so a burst of queue traffic pushes
	# older entries out of it. "Dispatched" is the one answer a sender acts on,
	# so it must never be a guess: an id the queue can no longer speak for is
	# reported as unknown.
	var w3: = _world()
	var module3: Object = w3["module"]
	var pane3 = w3["pane"]
	var claude3 = w3["claude"]
	var queue3 = pane3._outgoing_queue

	var first_entry = queue3.enqueue(claude3.HistoryId, "evicted line")
	var first_id: int = first_entry.id
	queue3.pop_next(claude3.HistoryId)
	check("H7: a freshly promoted entry no delivery follows is reported as sending, never as taken",
		module3.notify_status(first_id, 0) == "sending")

	# Push it out of the ring: OUTCOME_HISTORY newer outcomes.
	for _i in range(queue3.OUTCOME_HISTORY):
		queue3.enqueue(claude3.HistoryId, "burst")
		queue3.pop_next(claude3.HistoryId)
	check("H8: the ring really evicted it",
		queue3.outcome_of(first_id) == queue3.Outcome.UNKNOWN)
	check("H9: an evicted entry is NOT reported as sending",
		module3.notify_status(first_id, 0) == "unknown",
		module3.notify_status(first_id, 0))

	_teardown(pane3, w3["chats"])

#endregion


#region K — the receipt against the REAL executor

## Leaving the queue is written on the queue's record before the executor has
## done anything with the entry, so the receipt reads handed_to_harness only
## once the request itself has the line (the stand-in for PluginProvider's
## report). The receipt is only honest if the executor really sends it. The
## case that broke it: the target chat's newest history item is a USER message
## (its previous turn errored or was cancelled after that item landed), which
## execute_regular_chat's "last item is user" guard used to bail on.
func _test_the_receipt_is_honest_on_an_unanswered_user_message() -> void:
	var claude_chat = _make_bound_chat("Claude Session", "101")
	var pane = _make_pane([claude_chat], REAL_TURN_PANE_SRC)
	var module = _make_module([{"id": "101", "name": "Claude Session"}], {"101": "claude"})
	pane.current_tab = _so.ChatList.find(claude_chat)

	var item_script: = load(CHAT_HISTORY_ITEM_PATH)
	var orphan = item_script.new()
	orphan._suppress_save_state = true
	orphan.Role = item_script.ChatRole.USER
	orphan.Message = "the turn that never answered"
	claude_chat.HistoryItemList.append(orphan)

	# A turn is in flight, so the envelope queues rather than starting one.
	var token: int = pane._begin_chat_turn(claude_chat)
	var runner = _make_script(NOTIFY_RUNNER_SRC).new()
	runner.run(module, {"to": "claude", "from": "codex", "text": "come look",
		"wait_ms": 5000})
	await process_frame
	check("K1: the tool waits while the target is busy", not runner.done)

	pane._release_chat_turn(claude_chat, token)
	for _i in range(30):
		if runner.done:
			break
		await process_frame
	var envelope: = "[MINERVA NOTIFY from codex] come look"
	check("K2: the envelope really became a request",
		str(pane.real_generates) == str(PackedStringArray([envelope])),
		str(pane.real_generates))
	check("K3: and the receipt that says handed_to_harness is telling the truth",
		runner.done and str(runner.result.get("status", "")) == "handed_to_harness"
			and int(runner.result.get("queue_position", -1)) == 0,
		str(runner.result))

	pane.blocked = false
	_teardown(pane, [claude_chat])

#endregion


#region L — the IDLE target on an unanswered user message

## The queued case (section K) reaches the executor through the drain, which
## marks the message promoted. An IDLE target does not: submit_user_message
## calls the executor directly, and the "last item is user" guard sees the same
## orphaned USER item. The receipt is written either way, so a guard bail here
## is a notification reported as delivered that no chat ever saw.
func _test_an_idle_chat_on_an_unanswered_user_message_is_still_notified() -> void:
	var claude_chat = _make_bound_chat("Claude Session", "101")
	var pane = _make_pane([claude_chat], REAL_TURN_PANE_SRC)
	var module = _make_module([{"id": "101", "name": "Claude Session"}], {"101": "claude"})
	pane.current_tab = _so.ChatList.find(claude_chat)

	var item_script: = load(CHAT_HISTORY_ITEM_PATH)
	var orphan = item_script.new()
	orphan._suppress_save_state = true
	orphan.Role = item_script.ChatRole.USER
	orphan.Message = "the turn that never answered"
	claude_chat.HistoryItemList.append(orphan)

	check("L0: the target is idle, so nothing queues", not claude_chat.is_request_active)
	var receipt: Dictionary = await _notify(module,
		{"to": "claude", "from": "codex", "text": "come look"})
	for _i in range(10):
		await process_frame
	var envelope: = "[MINERVA NOTIFY from codex] come look"
	check("L1: the envelope really became a request",
		str(pane.real_generates) == str(PackedStringArray([envelope])),
		str(pane.real_generates))
	check("L2: the receipt said sending when it returned, before the request was reached",
		str(receipt.get("status", "")) == "sending", str(receipt))
	var record: Dictionary = module._notify_status_tool(
		{"delivery_id": str(receipt.get("delivery_id", ""))}).get("delivery", {})
	check("L2b: and the ledger reads handed_to_harness once the request had the line",
		str(record.get("state", "")) == "handed_to_harness", str(record))
	check("L3: the chat is busy with that turn, not left idle",
		claude_chat.is_request_active)

	pane.blocked = false
	_teardown(pane, [claude_chat])

#endregion
