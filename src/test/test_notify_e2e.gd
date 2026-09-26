extends SceneTree
## End-to-end test of minerva_terminal_notify between two harness tabs that
## are NOT passthroughs: the real agent-relay plugin, two real PTYs each
## running the mock codex CLI under the name `codex`, the real terminal
## registry and listing, and the real MCPTerminalTools module with no seams.
##
## Run: godot --headless --path src --script test/test_notify_e2e.gd
## SKIPs (exit 0) when the plugin, python3 or the PTY extension is missing.
##
## The relay under test is the one in MINERVA_AGENT_RELAY_PLUGIN_DIR, which
## must hold the reviewed release archive extracted (a build stage has no
## manifest.json); unset, the run SKIPs. A profile whose agent_relay record points anywhere
## else fails rather than testing some other relay.
##
## The mock is launched through a shim NAMED codex, so the PTY's foreground
## process is what the listing classifies as the codex harness — the same
## thing the real CLI looks like from the host.
##
## ORACLES
##   - the envelope, reply address included, is echoed on the peer's screen
##     and answered by the mock (it reverses its prompt), with no watch and no
##     chat ever created for either terminal;
##   - a bare "codex" with two codex tabs is refused, naming both ids;
##   - a keystroke injected WHILE a notification is being delivered lands after
##     that line's Enter, as its own separate input.
##
## BLOCKED DELIVERIES (E6 dialog, E10 busy turn, E11 human draft; E7 typing).
## The oracle is the target's TRANSCRIPT and, for the draft, the DRAFT'S
## BYTES — never the receipt alone:
##   - the mock answers every line it is given with the line reversed, so an
##     envelope answered in the scrollback is an envelope the harness took,
##     and a draft answered exactly is a draft nothing was typed into;
##   - while blocked, the receipt says held (retained, with a delivery_id) and
##     the transcript holds no answer to the envelope;
##   - once the block clears, the ledger reads handed_to_harness and the
##     transcript holds exactly ONE answer to the envelope.

const TERMINAL_TOOLS_PATH := "res://Scripts/Services/MCP/Modules/MCPTerminalTools.gd"
const TerminalInputArbiter := preload("res://Scripts/Services/Terminal/TerminalInputArbiter.gd")
const LAUNCH_DIALOG_PATH := "res://Scripts/UI/Controls/PassthroughLaunchDialog.gd"
const MOCK_PATH := "res://test/fixtures/passthrough_e2e/mock_codex.py"

const AGENT_RELAY_MANIFEST := "/manifest.json"
const PLUGIN_ID := "agent_relay"
const S_RUNNING := 2
const CAPS := [
	"host.terminal.list", "host.terminal.read", "host.terminal.write",
	"host.terminal.wait", "host.chat_providers.register", "host.providers.chat",
]

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== terminal_notify E2E (real relay, two mock-codex PTYs, no passthrough) ===\n")
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


func _wait_until(predicate: Callable, timeout_ms: int = 20000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await create_timer(0.1).timeout
	return bool(predicate.call())


func _idle(session) -> bool:
	for line in session.read_viewport_text().split("\n"):
		if line.begins_with("› "):
			return true
	return false


func _run() -> void:
	var plugin_dir: String = OS.get_environment("MINERVA_AGENT_RELAY_PLUGIN_DIR")
	if plugin_dir == "":
		print("SKIP: MINERVA_AGENT_RELAY_PLUGIN_DIR is unset; point it at the reviewed agent_relay release")
		return
	var manifest_path: String = plugin_dir + AGENT_RELAY_MANIFEST
	var mock_path: String = ProjectSettings.globalize_path(MOCK_PATH)
	if not FileAccess.file_exists(mock_path):
		check("mock_codex.py fixture exists", false, mock_path)
		return
	if OS.execute("python3", ["--version"], [], true) != OK:
		print("SKIP: python3 not available")
		return
	# No watch persistence: a crashed earlier run must not resume a phantom watch.
	OS.set_environment("AGENT_RELAY_STATE_FILE", "")

	await process_frame
	var so = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload present", so != null)
	if so == null:
		return
	if not ClassDB.class_exists("Terminal"):
		print("SKIP: Terminal GDExtension not available")
		return
	var reg_deadline := Time.get_ticks_msec() + 12000
	while so.get("plugin_tool_registry") == null and Time.get_ticks_msec() < reg_deadline:
		await create_timer(0.1).timeout

	# ── the real plugin, on the singleton manager ─────────────────────────
	var pm = so.get("plugin_manager")
	check("singleton PluginManager available", pm != null and pm._db != null)
	if pm == null or pm._db == null:
		return
	var def = pm._db.get_by_id(PLUGIN_ID)
	if def != null and ProjectSettings.globalize_path(def.data_directory).simplify_path() != plugin_dir.simplify_path():
		check("agent_relay under test comes from MINERVA_AGENT_RELAY_PLUGIN_DIR", false,
			"%s is installed from %s" % [PLUGIN_ID, def.data_directory])
		return
	if def == null:
		if not FileAccess.file_exists(manifest_path):
			print("SKIP: no agent_relay plugin under %s" % plugin_dir)
			return
		var install_res = await pm.install_plugin(manifest_path, true)
		check("install_plugin ok", install_res.get("ok", false), str(install_res))
		def = pm._db.get_by_id(PLUGIN_ID)
	if def == null:
		check("agent_relay definition loaded", false)
		return
	var policy = so.get("plugin_policy")
	if policy != null:
		for cap in CAPS:
			policy.grant_capability(PLUGIN_ID, cap)
	if def.state == S_RUNNING:
		await pm.stop_plugin(PLUGIN_ID)
	var start_res = await pm.start_plugin(PLUGIN_ID)
	check("agent-relay running", start_res.get("ok", false) and def.state == S_RUNNING, str(start_res))
	print("agent-relay started from: %s (%s)" % [def.data_directory, def.entrypoint])
	if def.state != S_RUNNING:
		return

	# ── a shim named codex, so the foreground process reads as the harness ─
	var shim_dir: String = OS.get_user_data_dir() + "/notify_e2e"
	DirAccess.make_dir_recursive_absolute(shim_dir)
	var shim_path: String = shim_dir + "/codex"
	var shim := FileAccess.open(shim_path, FileAccess.WRITE)
	shim.store_string("#!/usr/bin/env python3\nimport runpy\nrunpy.run_path(%s, run_name='__main__')\n" % var_to_str(mock_path))
	shim.close()
	OS.execute("chmod", ["+x", shim_path])

	var sessions = so.get_terminal_session_registry()
	var a = sessions.create_session("notify-a", 80, 24)
	var b = sessions.create_session("notify-b", 80, 24)
	check("two background sessions started", a != null and b != null and a.started and b.started)
	if a == null or b == null or not a.started or not b.started:
		await _teardown(pm, sessions, [a, b])
		return
	var tid_a: String = str(a.terminal_id)
	var tid_b: String = str(b.terminal_id)
	for s in [a, b]:
		s.write_input("'%s'\r" % shim_path)
	var both_idle: bool = await _wait_until(func() -> bool: return _idle(a) and _idle(b))
	check("both mocks reached their idle prompt", both_idle,
		"a: %s\nb: %s" % [a.read_viewport_text().right(200), b.read_viewport_text().right(200)])

	var tools = load(TERMINAL_TOOLS_PATH).new(null)
	var LaunchDialog = load(LAUNCH_DIALOG_PATH)

	# ── E1: the listing sees a codex harness in both, and nothing else ─────
	var seen: bool = await _wait_until(func() -> bool:
		return _harness_of(tools, tid_a) == "codex" and _harness_of(tools, tid_b) == "codex", 5000)
	check("E1: terminal_list reports harness codex for both tabs", seen,
		str(tools._terminal_list({})))

	# ── E2: a bare harness name with two candidates is refused ────────────
	var ambiguous: Dictionary = await tools.handle("minerva_terminal_notify",
		{"to": "codex", "from": "claude", "text": "hello"})
	check("E2: bare 'codex' is ambiguous and names both ids",
		not ambiguous.get("success", true)
			and str(ambiguous.get("error", "")).contains(tid_a)
			and str(ambiguous.get("error", "")).contains(tid_b), str(ambiguous))

	# ── E3: a → b, no watch, no chat: typed, echoed, answered ─────────────
	var line := "review posted: docket 01a0bfe6 comment 1910"
	var receipt: Dictionary = await tools.handle("minerva_terminal_notify",
		{"to": "notify-b", "from": "codex@notify-a", "reply_to": tid_a,
			"text": line, "wait_ms": 8000})
	check("E3: the harness took the notification", receipt.get("success", false)
		and str(receipt.get("status", "")) == "handed_to_harness", str(receipt))
	var expected := "[MINERVA NOTIFY from codex@notify-a (reply to: %s)] %s" % [tid_a, line]
	# The answer has scrolled above the viewport by the time the idle screen
	# is back, so the whole scrollback is read; its echo wraps at the PTY's 80
	# columns, so row breaks are dropped before the answer is looked for.
	var answered: bool = await _wait_until(func() -> bool:
		return _scrollback(b).find("MOCK-ANSWER: " + _reverse(expected)) != -1)
	check("E3: the peer received exactly the host-built envelope (its answer is the reversal)",
		answered, b.get_plain_text().right(400))
	var status_b: Dictionary = LaunchDialog._classify_watch_result(
		await tools._call_relay_tool("minerva_agent_relay_watch_status", {"terminal_id": tid_b}))
	check("E4: no watch was started on the target", status_b.get("ok", false)
		and (status_b.get("result", {}) as Dictionary).get("status", null) == null, str(status_b))
	check("E4: no chat was bound to either terminal",
		tools._find_passthrough_chat(tid_a) == null and tools._find_passthrough_chat(tid_b) == null)

	# ── E5: b → a by harness@name ─────────────────────────────────────────
	var back_idle: bool = await _wait_until(func() -> bool: return _idle(b))
	check("E5: the peer is idle again", back_idle)
	var reply: Dictionary = await tools.handle("minerva_terminal_notify",
		{"to": "codex@notify-a", "from": "codex@notify-b", "reply_to": tid_b,
			"text": "seen, thanks", "wait_ms": 8000})
	check("E5: harness@name reaches the other tab", reply.get("success", false)
		and str(reply.get("target", {}).get("terminal_id", "")) == tid_a, str(reply))
	var seen_a: bool = await _wait_until(func() -> bool:
		return a.get_plain_text().find("(reply to: %s)" % tid_b) != -1)
	check("E5: its envelope shows on that screen", seen_a, a.get_plain_text().right(300))

	# ── E6: a dialog on the target holds the line; answering it releases ──
	var a_idle: bool = await _wait_until(func() -> bool: return _idle(a))
	check("E6: sender tab idle before the dialog leg", a_idle)
	b.write_input("trigger-dialog\r")
	var dialog_up: bool = await _wait_until(func() -> bool:
		return b.read_viewport_text().find("Yes, proceed") != -1)
	check("E6: the mock shows its permission dialog", dialog_up, b.read_viewport_text().right(300))
	var held: Dictionary = await tools.handle("minerva_terminal_notify",
		{"to": tid_b, "from": "codex@notify-a", "text": "held-line"})
	check("E6: the notification is kept, held with the screen as the reason",
		held.get("success", false) and str(held.get("status", "")) == "held"
			and bool(held.get("retained", false)) and not str(held.get("delivery_id", "")).is_empty()
			and str(held.get("hold_reason", "")) == "screen", str(held))
	await _check_block_clears(tools, b, "E6", held, "held-line",
		func() -> void: b.write_input("y"))
	# The held line's turn has redrawn the screen since, so the answer is in
	# the scrollback, not the viewport.
	check("E6: the dialog was answered by the person's keystroke, not by the relay",
		_scrollback(b).find("DIALOG-ANSWERED: y") != -1, _rows_containing(b, "DIALOG-ANSWERED"))

	# ── E7: a person typing in the target outranks the agent ──────────────
	var b_idle: bool = await _wait_until(func() -> bool: return _idle(b))
	check("E7: target idle before the typing leg", b_idle)
	b.note_human_input()
	var typing: Dictionary = await tools.handle("minerva_terminal_notify",
		{"to": tid_b, "from": "codex@notify-a", "text": "while-typing"})
	check("E7: a keystroke moments ago holds with reason human_typing, and the line is kept",
		typing.get("success", false) and str(typing.get("status", "")) == "held"
			and bool(typing.get("retained", false))
			and str(typing.get("hold_reason", "")) == "human_typing", str(typing))
	check("E7: and nothing reached the terminal", b.get_plain_text().find("while-typing") == -1)
	# The same keystroke stops the RELAY's own write: the host refuses the
	# body at write time and the relay reports it as a hold.
	var relay_held: Dictionary = LaunchDialog._classify_watch_result(
		await tools._call_relay_tool("minerva_agent_relay_send",
			{"terminal_id": tid_b, "text": "guard-probe", "arm": false, "profile": "codex",
				"gate_budget_ms": 0, "human_guard_ms": 5000}))
	check("E7b: the relay's write-time guard holds too, through the real plugin",
		not relay_held.get("ok", true) and str(relay_held.get("error", "")).contains("nothing was written"),
		str(relay_held))
	check("E7c: and typed nothing", b.get_plain_text().find("guard-probe") == -1)
	# The expected harness is checked by the host at the write itself: a send
	# that expects claude in a codex tab is held through the real plugin.
	# Both typing stamps are cleared: the notify loop reads the wall-clock one,
	# the arbiter's admission the monotonic one.
	b.last_input_ms = 0
	b.last_input_ticks_ms = 0
	var wrong: Dictionary = LaunchDialog._classify_watch_result(
		await tools._call_relay_tool("minerva_agent_relay_send",
			{"terminal_id": tid_b, "text": "wrong-harness", "arm": false, "profile": "codex",
				"gate_budget_ms": 0, "expect_harness": "claude"}))
	check("E8: a write expecting the wrong harness is held at the write boundary",
		not wrong.get("ok", true) and str(wrong.get("error", "")).contains("not claude"), str(wrong))
	check("E8: and typed nothing", b.get_plain_text().find("wrong-harness") == -1)
	# The typing stamps are clear now, so the line E7 kept is delivered; it
	# must have landed before the interleave leg starts on the same terminal.
	var e7_taken: bool = await _wait_until(func() -> bool:
		return _delivery_state(tools, str(typing.get("delivery_id", ""))) == "handed_to_harness" \
			and _answered_count(b, "while-typing") == 1 and _idle(b))
	check("E7: once the person stopped typing, the kept line was taken exactly once", e7_taken,
		"%s | %s" % [_delivery_state(tools, str(typing.get("delivery_id", ""))),
			_rows_containing(b, "MOCK-ANSWER")])

	# ── E9: a keystroke DURING a delivery lands after that line's Enter ───
	# The synchronisation is the arbiter's own phase signal, never a sleep:
	# body_written means the envelope is on the PTY and the Enter has not gone
	# out yet, which is the only window where a keystroke could be submitted
	# with the line. The keystroke goes in through write_human_input, the same
	# entry a terminal view uses for a key.
	var race_idle: bool = await _wait_until(func() -> bool: return _idle(b))
	check("E9: target idle before the interleave leg", race_idle)
	b.last_input_ms = 0
	b.last_input_ticks_ms = 0
	var arbiter = b.get_input_arbiter()
	check("E9: the target session exposes its input arbiter", arbiter != null)
	if arbiter == null:
		await _teardown(pm, sessions, [a, b])
		return
	# A Dictionary, so the lambda and this scope share the one state.
	var race := {"txn_id": 0, "injected": false, "receipt": {}}
	var on_phase := func(txn_id: int, phase: String) -> void:
		if phase != TerminalInputArbiter.PHASE_BODY_WRITTEN or bool(race["injected"]):
			return
		race["txn_id"] = txn_id
		race["injected"] = true
		race["receipt"] = b.write_human_input("x\r")
	arbiter.transaction_phase.connect(on_phase)
	var race_line := "arbiter leg: a keystroke arrives mid-delivery"
	var raced: Dictionary = await tools.handle("minerva_terminal_notify",
		{"to": tid_b, "from": "codex@notify-a", "reply_to": tid_a,
			"text": race_line, "wait_ms": 8000})
	check("E9: the harness took the notification", raced.get("success", false)
		and str(raced.get("status", "")) == "handed_to_harness", str(raced))
	check("E9: the keystroke was queued by the arbiter mid-transaction",
		bool(race["injected"]) and bool((race["receipt"] as Dictionary).get("queued", false)),
		str(race))
	var race_expected := "[MINERVA NOTIFY from codex@notify-a (reply to: %s)] %s" % [tid_a, race_line]
	# Oracle 1: the mock reverses its prompt, so its answer is the envelope
	# reversed EXACTLY — an "x" anywhere inside the submitted line would show.
	var intact: bool = await _wait_until(func() -> bool:
		return _scrollback(b).find("MOCK-ANSWER: " + _reverse(race_expected)) != -1)
	check("E9: the mock answered the envelope exactly, so no keystroke was inside the line",
		intact, _scrollback(b).right(400))
	# Oracle 2: the keystroke is then answered as the NEXT prompt of its own
	# (the reversal of "x" is "x"), which is only reachable after the Enter.
	var separate: bool = await _wait_until(func() -> bool: return _has_row_ending(b, "MOCK-ANSWER: x"))
	check("E9: the keystroke was answered afterwards as its own separate prompt",
		separate, _rows_containing(b, "MOCK-ANSWER"))
	arbiter.transaction_phase.disconnect(on_phase)
	# Oracle 3: the record outlives the transaction and says how it ended.
	var record: Dictionary = arbiter.get_transaction(int(race["txn_id"]))
	check("E9: the transaction committed and released exactly the one keystroke",
		str(record.get("phase", "")) == TerminalInputArbiter.PHASE_FINISHED
			and str(record.get("outcome", "")) == TerminalInputArbiter.OUTCOME_COMMITTED
			and int(record.get("released", -1)) == 1, str(record))

	# ── E10: a busy turn holds the line; the turn's end releases it ───────
	var busy_idle: bool = await _wait_until(func() -> bool:
		return _idle(b) and _has_row_ending(b, "MOCK-ANSWER: x"))
	check("E10: target idle before the busy leg", busy_idle)
	# E9's keystroke stamped both typing clocks; clear them so the busy turn
	# is the only block.
	b.last_input_ms = 0
	b.last_input_ticks_ms = 0
	b.write_input("slow-turn\r")
	var busy_up: bool = await _wait_until(func() -> bool:
		return b.read_viewport_text().find("esc to interrupt") != -1, 5000)
	check("E10: the mock shows its busy screen", busy_up, b.read_viewport_text().right(300))
	var busy: Dictionary = await tools.handle("minerva_terminal_notify",
		{"to": tid_b, "from": "codex@notify-a", "text": "busy-line"})
	check("E10: a turn in progress holds the line with reason busy_turn, and it is kept",
		busy.get("success", false) and str(busy.get("status", "")) == "held"
			and bool(busy.get("retained", false))
			and str(busy.get("hold_reason", "")) == "busy_turn", str(busy))
	# Nothing is done to clear it: the mock's own turn ends.
	await _check_block_clears(tools, b, "E10", busy, "busy-line", Callable())
	check("E10: the turn it waited for was answered first",
		_rows_containing(b, "MOCK-ANSWER").find("MOCK-ANSWER: nrut-wols") != -1,
		_rows_containing(b, "MOCK-ANSWER"))

	# ── E11: a person's unsent draft holds the line; submitting it releases
	# The draft is typed as a person types it and left in the input line (the
	# PTY echoes it, drawn plain, where the composer guard reads). The typing
	# stamps are then cleared: the person has stopped typing, so only the
	# draft itself is left to hold the line.
	var draft_idle: bool = await _wait_until(func() -> bool: return _idle(b))
	check("E11: target idle before the draft leg", draft_idle)
	var draft := "keep my draft exactly"
	b.write_human_input(draft)
	var draft_shown: bool = await _wait_until(func() -> bool:
		return b.read_viewport_text().find(draft) != -1, 5000)
	check("E11: the draft shows in the target", draft_shown, b.read_viewport_text().right(300))
	b.last_input_ms = 0
	b.last_input_ticks_ms = 0
	var drafted: Dictionary = await tools.handle("minerva_terminal_notify",
		{"to": tid_b, "from": "codex@notify-a", "text": "draft-line"})
	check("E11: the draft holds the line with reason composer_not_empty, and it is kept",
		drafted.get("success", false) and str(drafted.get("status", "")) == "held"
			and bool(drafted.get("retained", false))
			and str(drafted.get("hold_reason", "")) == "composer_not_empty", str(drafted))
	await _check_block_clears(tools, b, "E11", drafted, "draft-line",
		func() -> void: b.write_human_input("\r"))
	# Oracle: the draft's bytes. The mock answers the submitted line reversed,
	# so an answer that is exactly the draft reversed proves nothing was typed
	# into it or after it before its Enter.
	check("E11: the draft was submitted byte for byte, with nothing stapled to it",
		_has_row_ending(b, "MOCK-ANSWER: " + _reverse(draft)), _rows_containing(b, "MOCK-ANSWER"))

	await _teardown(pm, sessions, [a, b])


## One blocked delivery, from held to taken. While the block stands, the
## receipt's record must say held and the transcript must hold no answer to
## the line; `clear` (when valid) is what a person does to lift the block;
## afterwards the record must read handed_to_harness and the transcript must
## answer the line exactly once.
func _check_block_clears(tools, session, leg: String, receipt: Dictionary, line: String,
		clear: Callable) -> void:
	var id: String = str(receipt.get("delivery_id", ""))
	await create_timer(1.5).timeout
	var still_held: bool = _delivery_state(tools, id) == "held" and _answered_count(session, line) == 0
	check("%s: while blocked the record says held and the transcript has no answer to the line" % leg,
		still_held, "%s | %s" % [_delivery_state(tools, id), _rows_containing(session, "MOCK-ANSWER")])
	if clear.is_valid():
		clear.call()
	var taken: bool = await _wait_until(func() -> bool:
		return _delivery_state(tools, id) == "handed_to_harness" and _answered_count(session, line) == 1,
		30000)
	check("%s: once the block cleared the record says handed_to_harness and the transcript answers the line once" % leg,
		taken, "%s | %s" % [_delivery_state(tools, id), _rows_containing(session, "MOCK-ANSWER")])
	await _wait_until(func() -> bool: return _idle(session))


## The ledger's state for a delivery, as minerva_terminal_notify_status reports
## it (its handler, called directly so predicates can stay synchronous).
func _delivery_state(tools, delivery_id: String) -> String:
	var got: Dictionary = tools._notify_status_tool({"delivery_id": delivery_id})
	return str((got.get("delivery", {}) as Dictionary).get("state", ""))


## How many of the mock's answers are the reversal of an envelope whose text
## ends with `line`: the envelope reversed starts with the line reversed.
func _answered_count(session, line: String) -> int:
	var count: int = 0
	var needle: String = "MOCK-ANSWER: " + _reverse(line)
	var text: String = _scrollback(session)
	var at: int = text.find(needle)
	while at != -1:
		count += 1
		at = text.find(needle, at + needle.length())
	return count


func _harness_of(tools, tid: String) -> String:
	for e: Dictionary in tools._terminal_list({}).get("terminals", []):
		if str(e.get("id", "")) == tid:
			return str(e.get("harness", ""))
	return ""


## Every row the terminal still holds, joined without row breaks.
func _scrollback(session) -> String:
	var rows: Array[String] = []
	for row in range(int(session.get_scroll_info().get("total_rows", 0))):
		rows.append(session.extract_row_text_screen(row))
	return "".join(rows)


## Whether any row the terminal still holds is exactly this text. Used where a
## substring of a longer answer line would be ambiguous.
## A row that ENDS with the text: the mock writes its answer at the cursor,
## which may sit after the previous idle screen's prompt marker, so an exact
## row match would miss it; the long envelope answer never ends this way.
func _has_row_ending(session, text: String) -> bool:
	for row in range(int(session.get_scroll_info().get("total_rows", 0))):
		if session.extract_row_text_screen(row).strip_edges().ends_with(text):
			return true
	return false


func _rows_containing(session, text: String) -> String:
	var out: PackedStringArray = PackedStringArray()
	for row in range(int(session.get_scroll_info().get("total_rows", 0))):
		var line: String = session.extract_row_text_screen(row)
		if line.find(text) != -1:
			out.append(line.strip_edges())
	return " | ".join(out)


func _reverse(text: String) -> String:
	var out := ""
	for i in range(text.length() - 1, -1, -1):
		out += text[i]
	return out


func _teardown(pm, sessions, list: Array) -> void:
	for s in list:
		if s != null and sessions.has_session(str(s.terminal_id)):
			sessions.close_session(str(s.terminal_id))
	if pm != null:
		var def = pm._db.get_by_id(PLUGIN_ID) if pm._db != null else null
		if def != null and def.state == S_RUNNING:
			await pm.stop_plugin(PLUGIN_ID)
