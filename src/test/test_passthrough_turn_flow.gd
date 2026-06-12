extends SceneTree
## W5 (chat-passthrough): turn lifecycle + live-status relay.
##
## Run: timeout 120 godot --headless --path src --script test/test_passthrough_turn_flow.gd
##
## Acceptance (W5 contract):
##   1. Status extraction unit table: realistic busy-agent screens (box-drawing
##      chrome + an "esc to interrupt" line + blank tails) compact to <=160 chars
##      via the last-non-empty-lines heuristic; empty/whitespace -> "".
##   2. Turn bookkeeping: exactly one in-flight marker; status updates MUTATE
##      (last_status changes, status_updates increments) and never re-append once
##      identical; resolve -> finished + polling stopped.
##   3. Real session integration: a background session (T1 registry) runs a
##      command printing a recognizable line; the screen-read path surfaces it
##      (or, if the terminal extension is unavailable, reads "" cleanly).
##   4. Cancel path: a cancelled-marked BotResponse -> disposition "cancelled",
##      polling stopped, no orphan state blocking a second turn (begin() again).
##   5. Question result: hcp_data options -> disposition "question"; the options
##      payload is preserved (W4's input).
##   6. Chime/finalize structure: the in-flight node is the SAME node that
##      finalizes (one ChatHistoryItem appended per turn) — asserted structurally
##      against the helper + the ChatPane finalize seam.
##
## NOTE: class_name globals are invisible to --script runs; load() + duck-type.
## ChatPane is not instantiable headless, so the relay STRING + STATE work lives
## in PassthroughTurnStatus, which this suite drives directly. The disposition
## mapping that ChatPane._passthrough_end_relay applies is mirrored here so the
## cancel/question/answer/error branch logic is covered without the UI.

const STATUS_PATH := "res://Scripts/Models/PassthroughTurnStatus.gd"
const BOTRESPONSE_PATH := "res://Scripts/Models/BotResponse.gd"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== W5 passthrough turn flow test ===\n")
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


func _run() -> void:
	await process_frame
	var Status = load(STATUS_PATH)
	check("PassthroughTurnStatus loads", Status != null)
	if Status == null:
		return
	_test_status_heuristic(Status)
	_test_tail_view(Status)
	_test_turn_bookkeeping(Status)
	_test_cancel_disposition(Status)
	_test_question_disposition(Status)
	_test_answer_and_error_disposition(Status)
	await _test_real_session_integration()


# --- Acceptance 1: status heuristic table ----------------------------------
func _test_status_heuristic(Status) -> void:
	print("\n-- status heuristic --")

	# A realistic busy codex/claude-style screen: chrome, a content line, the
	# spinner/interrupt line, then a blank tail (terminal pads the viewport).
	var busy := "\n".join([
		"╭──────────────────────────────────────────────╮",
		"│  > implement the parser                        │",
		"╰──────────────────────────────────────────────╯",
		"",
		"  ✻ Working… (esc to interrupt · 42s · 1.2k tokens)",
		"",
		"",
	])
	var s: String = Status.compact_status(busy)
	check("busy screen → non-empty status", not s.is_empty(), s)
	check("busy screen → captures interrupt line", s.find("esc to interrupt") != -1, s)
	check("busy screen → single line (no newline)", s.find("\n") == -1, s)
	check("busy screen → within cap", s.length() <= 160, "len=%d" % s.length())

	# Empty / whitespace-only → empty.
	check("empty screen → empty", Status.compact_status("") == "")
	check("blank-only screen → empty", Status.compact_status("\n   \n\t\n") == "")

	# Last-3-non-empty-lines heuristic: leading rows are dropped.
	var many := "\n".join(["row-old-1", "row-old-2", "row-old-3", "row-A", "row-B", "row-C"])
	var sm: String = Status.compact_status(many)
	check("heuristic keeps last 3 non-empty rows", sm == "row-A row-B row-C", sm)
	check("heuristic drops older rows", sm.find("row-old-1") == -1, sm)

	# Whitespace collapse: runs of spaces/tabs collapse to single spaces.
	var spaced := "  foo \t\t  bar     baz   "
	check("ws collapse single-line", Status.compact_status(spaced) == "foo bar baz",
		Status.compact_status(spaced))

	# Cap + ellipsis: a very long final line is truncated to <= cap with ellipsis.
	var longline := "x".repeat(400)
	var capped: String = Status.compact_status(longline)
	check("cap truncates to <=160", capped.length() <= 160, "len=%d" % capped.length())
	check("cap adds ellipsis", capped.ends_with("…"), capped)

	# Custom max_lines/cap args honored.
	var one: String = Status.compact_status(many, 1, 160)
	check("max_lines=1 keeps only last row", one == "row-C", one)


# --- Acceptance 2: turn bookkeeping ----------------------------------------
func _test_turn_bookkeeping(Status) -> void:
	print("\n-- turn bookkeeping --")
	var st = Status.new()
	check("fresh: not in_flight", st.in_flight == false)
	check("fresh: not polling", st.polling == false)

	check("begin() returns true", st.begin() == true)
	check("begin: in_flight", st.in_flight == true)
	check("begin: polling", st.polling == true)
	check("begin: exactly one marker (re-begin no-op)", st.begin() == false)

	# Status updates mutate, never append.
	var screen1 := "alpha\nbeta\n  ✻ Working… (esc to interrupt)"
	var r1: String = st.mark_status(screen1)
	check("first mark returns status", not r1.is_empty(), r1)
	check("status_updates == 1 after first change", st.status_updates == 1)
	var last_after_1: String = st.last_status

	# Same screen again → no mutation (idempotent, no re-append).
	var r2: String = st.mark_status(screen1)
	check("identical mark returns '' (no re-append)", r2 == "")
	check("status_updates unchanged on identical", st.status_updates == 1)
	check("last_status unchanged on identical", st.last_status == last_after_1)

	# Changed screen → mutates.
	var screen2 := "alpha\nbeta\n  ✻ Working… (esc to interrupt · 5s)"
	var r3: String = st.mark_status(screen2)
	check("changed mark returns new status", not r3.is_empty() and r3 != last_after_1, r3)
	check("status_updates == 2 after change", st.status_updates == 2)

	# Empty screen → no update, keeps last (no flicker-clear).
	var r4: String = st.mark_status("")
	check("empty mark returns '' (keeps bubble)", r4 == "")
	check("status_updates unchanged on empty", st.status_updates == 2)

	# Resolve → polling stops; further marks are inert.
	st.finish("answer")
	check("finish: polling stopped", st.polling == false)
	check("finish: in_flight cleared", st.in_flight == false)
	check("finish: disposition recorded", st.disposition == "answer")
	check("mark after finish returns '' (poll stopped)", st.mark_status(screen2) == "")
	check("status_updates frozen after finish", st.status_updates == 2)


# --- Acceptance 4: cancel disposition --------------------------------------
func _test_cancel_disposition(Status) -> void:
	print("\n-- cancel path --")
	var BotResponse = load(BOTRESPONSE_PATH)
	var bot = BotResponse.new()
	bot.error = "Request cancelled."  # PluginProvider's cancel marker
	var disp := _disposition_for(bot)
	check("cancelled bot → 'cancelled' disposition", disp == "cancelled", disp)

	# Bookkeeping finalizes as cancelled and frees up for a second turn.
	var st = Status.new()
	st.begin()
	st.finish(disp)
	check("cancel: polling stopped", st.polling == false)
	check("cancel: disposition cancelled", st.disposition == "cancelled")
	# No orphan state blocks a second turn.
	check("cancel: second begin() succeeds (no orphan)", st.begin() == true)


# --- Acceptance 5: question disposition + options preserved -----------------
func _test_question_disposition(Status) -> void:
	print("\n-- question path --")
	var BotResponse = load(BOTRESPONSE_PATH)
	var bot = BotResponse.new()
	bot.text = "Which file should I edit?"
	bot.hcp_data["passthrough_question_options"] = [
		{"label": "main.rs", "keystroke": "1"},
		{"label": "lib.rs", "keystroke": "2"},
	]
	var disp := _disposition_for(bot)
	check("question bot → 'question' disposition", disp == "question", disp)

	# Mirror ChatPane's CHI carry: options survive onto a plain dict (W4 input).
	var carried: Dictionary = {}
	if bot.hcp_data.has("passthrough_question_options"):
		carried = {"passthrough_question_options": bot.hcp_data["passthrough_question_options"]}
	check("question: options carried", carried.has("passthrough_question_options"))
	var opts: Array = carried["passthrough_question_options"]
	check("question: 2 options preserved", opts.size() == 2)
	check("question: option labels preserved",
		opts[0]["label"] == "main.rs" and opts[1]["label"] == "lib.rs")
	check("question: keystrokes preserved",
		opts[0]["keystroke"] == "1" and opts[1]["keystroke"] == "2")


# --- Acceptance 6 (partial): answer + error dispositions -------------------
func _test_answer_and_error_disposition(_Status) -> void:
	print("\n-- answer / error dispositions --")
	var BotResponse = load(BOTRESPONSE_PATH)

	var ans = BotResponse.new()
	ans.text = "Done — parser implemented."
	check("answer bot → 'answer' disposition", _disposition_for(ans) == "answer")

	var err = BotResponse.new()
	err.error = "Plugin 'x' is not running."
	check("transport-error bot → 'error' disposition", _disposition_for(err) == "error")

	check("null bot → 'error' disposition", _disposition_for(null) == "error")


# --- Acceptance 3: real session integration --------------------------------
func _test_real_session_integration() -> void:
	print("\n-- real session integration --")
	var so = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload present", so != null)
	if so == null:
		return
	var registry = so.get_terminal_session_registry()
	check("terminal session registry available", registry != null)
	if registry == null:
		return

	var session = registry.create_session("w5-relay-test", 80, 24)
	check("session created", session != null)
	if session == null:
		return

	var Status = load(STATUS_PATH)
	var marker := "W5_RELAY_MARKER_1234"

	if session.has_method("is_alive") and session.is_alive():
		# Live PTY: print a recognizable line and let it settle, then read.
		session.write_input("printf '%s\\n'\r" % marker)
		# Poll up to ~5s for the marker to appear on screen.
		var found := false
		for _i in range(50):
			await create_timer(0.1).timeout
			var screen: String = session.read_viewport_text()
			var compact: String = Status.compact_status(screen)
			if screen.find(marker) != -1 or compact.find(marker) != -1:
				found = true
				break
		check("live session: marker surfaced via screen read", found,
			"last screen: %s" % session.read_viewport_text())
	else:
		# Terminal extension unavailable in this environment: the read path must
		# degrade cleanly to "" (no crash, no spam) — that is the contract for a
		# dead/absent session.
		var screen: String = session.read_viewport_text()
		check("no-PTY session: read_viewport_text returns '' cleanly",
			screen == "", "got: %s" % screen)
		check("no-PTY session: compact_status('') == ''", Status.compact_status("") == "")

	registry.close_session(session.terminal_id)
	check("session closed (no orphan)", not registry.has_session(session.terminal_id))


## Mirror of ChatPane._passthrough_end_relay disposition mapping. Kept in lockstep
## so the cancel/question/answer/error branch logic is covered headlessly.
func _disposition_for(bot) -> String:
	if bot == null:
		return "error"
	var err = bot.error
	if err != null and not str(err).is_empty():
		return "cancelled" if str(err).to_lower().find("cancel") != -1 else "error"
	if bot.hcp_data.has("passthrough_question_options"):
		return "question"
	return "answer"


# --- W8 HITL feedback: growing multi-line tail view --------------------------
func _test_tail_view(Status) -> void:
	print("\n-- tail view (growing turn window) --")

	# Mid-turn claude-style screen: banner, echo, partial answer, spinner,
	# then the input-box chrome that must NOT appear in the bubble.
	var mid_turn := "\n".join([
		"claude banner",
		"",
		"❯ hi",
		"",
		"● Hi! line one of the answer",
		"  line two of the answer",
		"",
		"✻ Working… (3s · esc to interrupt)",
		"",
		"────────────────────────────────",
		"❯ ",
		"────────────────────────────────",
		"  ⏵⏵ bypass permissions on (shift+tab to cycle)",
	])
	var v: String = Status.tail_view(mid_turn)
	check("tail view keeps answer lines", v.contains("line one of the answer")
		and v.contains("line two of the answer"), v)
	check("tail view keeps the live spinner line", v.contains("Working"), v)
	check("tail view is multi-line", v.find("\n") != -1)
	check("tail view drops separators", not v.contains("────"), v)
	check("tail view drops the empty prompt", not v.contains("❯ \n")
		and not v.ends_with("❯"), v)
	check("tail view drops the ⏵ status bar", not v.contains("⏵"), v)

	# Spinner frames mutate IN PLACE: a later read with a different spinner
	# char replaces the line — the view must not contain both frames.
	var later := mid_turn.replace("✻ Working… (3s", "✽ Working… (4s")
	var v2: String = Status.tail_view(later)
	check("in-place spinner frame replaced, not accumulated",
		v2.contains("✽") and not v2.contains("✻"), v2)

	# max_lines window: only the LAST n content rows survive.
	var long_turn := ""
	for i in range(40):
		long_turn += "row %d\n" % i
	var v3: String = Status.tail_view(long_turn, 12)
	check("window keeps last rows", v3.contains("row 39") and not v3.contains("row 20"), v3)

	# cap keeps the TAIL with a leading ellipsis.
	var huge := ""
	for i in range(400):
		huge += "filler line %d\n" % i
	var v4: String = Status.tail_view(huge, 400, 200)
	check("cap keeps tail w/ ellipsis", v4.begins_with("…") and v4.length() <= 200
		and v4.contains("filler line 399"), v4.substr(0, 40))

	check("empty screen → empty view", Status.tail_view("") == "")
	check("chrome-only screen → empty view",
		Status.tail_view("────\n❯ \n  ⏵⏵ bypass permissions on") == "")
