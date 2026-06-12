extends SceneTree
## W7 (chat-passthrough): the autonomy keystone — a headless, token-free,
## CI-runnable E2E test of the ENTIRE chat-passthrough loop.
##
## Run: timeout 180 godot --headless --path src --script test/test_passthrough_e2e.gd
##
## Tracks DCR: minerva 019eb7f329 (chat-passthrough). W7 task.
##
## THE STACK UNDER TEST (all real, no stubs in the transport path):
##   real SingletonObject autoload
##   + real PluginManager / CapabilityBroker / PluginChatProviderRegistry
##   + the REAL agent-relay plugin binary (minerva-plugins/agent-relay)
##   + a background TerminalSession (T1 registry) running a mock codex CLI
##     (fixtures/passthrough_e2e/mock_codex.py) in a REAL PTY.
## Possible because the passthrough transport has NO LLM (DCR #479) — the mock
## CLI impersonates codex's SCREEN BEHAVIOUR and the plugin's turn-detector
## drives it verbatim. Zero token spend; no credentials anywhere.
##
## CHAT-LAYER LEVEL ACHIEVED: model layer. ChatPane's full UI turn path
## (execute_regular_chat → render_history → rendered nodes) cannot boot
## headless, so this drives the REAL PluginProvider (history.provider) directly
## — the same object start_passthrough_chat builds — and polls the live session
## itself for the status-relay assertion. The PluginProvider → real plugin →
## real PTY → mock CLI path is exercised end to end. The W5 disposition mapping
## is mirrored exactly (see _disposition_for) so the question/answer branch is
## the same logic ChatPane._passthrough_end_relay applies.
##
## CI: registered in scripts/run-functional-tests.sh PLUGIN_TESTS (the
## machine-local --all tier). SKIPS cleanly (exit 0) when the plugin dir or its
## binary is absent, so a CI checkout without minerva-plugins stays green.
##
## NOTE: class_name globals are invisible to --script runs; load() + duck-type.
## SingletonObject autoload registers lazily; resolve at runtime via the `so`
## node. Plugin-dir override: MINERVA_AGENT_RELAY_PLUGIN_DIR.

const PM_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const PROVIDER_PATH := "res://Scripts/Services/Providers/PluginProvider.gd"
const CHATPANE_PATH := "res://Scripts/UI/Views/ChatPane.gd"
const CHAT_HISTORY_ITEM_PATH := "res://Scripts/Models/ChatHistoryItem.gd"
const STATUS_PATH := "res://Scripts/Models/PassthroughTurnStatus.gd"

const AGENT_RELAY_DIR_REL := "/github/minerva-plugins/agent-relay"
const AGENT_RELAY_BINARY := "/agent-relay-plugin"
const AGENT_RELAY_MANIFEST := "/manifest.json"
const PLUGIN_ID := "agent_relay"
const PROFILE := "codex"
const S_RUNNING := 2
const S_STOPPED := 3

# Every host capability the manifest declares — grant them all so the real
# plugin's watch loop + passthrough_generate can read/write the PTY and register
# its provider entry without a policy denial poisoning the loop.
const CAPS := [
	"host.terminal.list", "host.terminal.read", "host.terminal.write",
	"host.terminal.wait", "host.chat_providers.register", "host.providers.chat",
]

## Injectable stub distill provider for the W6 summarize-to-note leg. Path-extends
## BaseProvider so it passes the typed assignment; no class_name resolution.
const DISTILL_STUB_SRC := """
extends "res://Scripts/Services/Providers/BaseProvider.gd"
var calls := 0
var response_text := "E2E-DISTILLED-SUMMARY"
func Format(chat) -> Variant:
	return {"text": chat.Message}
func generate_content(prompt, _p = {}):
	calls += 1
	var r = load("res://Scripts/Models/BotResponse.gd").new()
	r.text = response_text
	return r
"""

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== W7 chat-passthrough E2E (real plugin + mock CLI in a real PTY) ===\n")
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


## Bounded poll: call predicate() until true or timeout. Never an unbounded await.
func _wait_until(predicate: Callable, timeout_ms: int = 20000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await create_timer(0.1).timeout
	return bool(predicate.call())


## Mirror of ChatPane._passthrough_end_relay disposition mapping (W5 lockstep).
func _disposition_for(bot) -> String:
	if bot == null:
		return "error"
	var err = bot.error
	if err != null and not str(err).is_empty():
		return "cancelled" if str(err).to_lower().find("cancel") != -1 else "error"
	if bot.hcp_data.has("passthrough_question_options"):
		return "question"
	return "answer"


func _run() -> void:
	# ── Locate the real plugin; SKIP (exit 0) cleanly if missing ────────────
	var plugin_dir: String = OS.get_environment("MINERVA_AGENT_RELAY_PLUGIN_DIR")
	if plugin_dir == "":
		var home: String = OS.get_environment("HOME")
		if home == "":
			print("SKIP: $HOME unset and MINERVA_AGENT_RELAY_PLUGIN_DIR unset — cannot locate plugin.")
			return
		plugin_dir = home + AGENT_RELAY_DIR_REL
	var binary_path: String = plugin_dir + AGENT_RELAY_BINARY
	var manifest_path: String = plugin_dir + AGENT_RELAY_MANIFEST

	if not FileAccess.file_exists(binary_path):
		print("SKIP: agent-relay binary not found at %s" % binary_path)
		print("      Set MINERVA_AGENT_RELAY_PLUGIN_DIR or build the plugin.")
		return
	if not FileAccess.file_exists(manifest_path):
		print("SKIP: agent-relay manifest not found at %s" % manifest_path)
		return

	var mock_path: String = ProjectSettings.globalize_path(
		"res://test/fixtures/passthrough_e2e/mock_codex.py")
	if not FileAccess.file_exists(mock_path):
		check("mock_codex.py fixture exists", false, mock_path)
		return

	if OS.execute("python3", ["--version"], [], true) != OK:
		print("SKIP: python3 not available — cannot run the mock CLI.")
		return

	# Disable the plugin's on-disk watch-session persistence so a prior crashed
	# run can't resume a phantom watch (re-registering a dead provider entry and
	# polling a closed terminal forever). The plugin honours an empty
	# AGENT_RELAY_STATE_FILE as "no persistence" (state.rs:3-4). The subprocess
	# inherits this process's environment, so set it before start_plugin.
	OS.set_environment("AGENT_RELAY_STATE_FILE", "")

	print("agent-relay dir:  %s" % plugin_dir)
	print("agent-relay bin:  %s" % binary_path)
	print("mock codex CLI:   %s\n" % mock_path)

	await process_frame
	var so = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload present", so != null)
	if so == null:
		return
	if not ClassDB.class_exists("Terminal"):
		print("SKIP: Terminal GDExtension not available — live PTY tests skipped.")
		return

	# Wait for the wired plugin_tool_registry (late-init; see CAD smoke test).
	var reg_deadline := Time.get_ticks_msec() + 12000
	while so.get("plugin_tool_registry") == null and Time.get_ticks_msec() < reg_deadline:
		await create_timer(0.1).timeout

	# ── (a) install + start the REAL agent-relay plugin ─────────────────────
	# Use the SINGLETON's PluginManager so the plugin's def, the policy that
	# gates host capabilities, the CapabilityBroker the live connection routes
	# through, and the chat-provider registry the broker writes to are all the
	# SAME wired objects. (A fresh PM.new() would split def/policy from the
	# singleton broker the connection actually calls — registration would be
	# denied silently.)
	print("-- (a) install + start the real agent-relay plugin (singleton PM) --")
	var pm = so.get("plugin_manager")
	check("singleton PluginManager available", pm != null and pm._db != null)
	if pm == null or pm._db == null:
		return

	var db = pm._db
	var def = db.get_by_id(PLUGIN_ID)
	if def == null:
		var install_res = await pm.install_plugin(manifest_path, true)
		check("install_plugin ok", install_res.get("ok", false), str(install_res))
		def = db.get_by_id(PLUGIN_ID)
	check("agent_relay definition loaded into DB", def != null)
	if def == null:
		return

	# The broker's chat-provider registry is already wired to the singleton
	# registry; grant every host capability the manifest declares so the real
	# watch loop can register the entry and drive the PTY.
	var registry = pm.get_chat_provider_registry()
	check("PluginManager exposes chat-provider registry", registry != null)
	var policy = so.get("plugin_policy")
	check("plugin policy available", policy != null)
	if policy != null:
		for cap in CAPS:
			policy.grant_capability(PLUGIN_ID, cap)

	if def.state == S_RUNNING:
		await pm.stop_plugin(PLUGIN_ID)
	var start_res = await pm.start_plugin(PLUGIN_ID)
	check("start_plugin ok", start_res.get("ok", false), str(start_res))
	check("plugin state == RUNNING", def.state == S_RUNNING,
		"got state=%d" % def.state)
	var conn = pm.get_connection(PLUGIN_ID)
	check("plugin connection exists", conn != null)
	if conn == null:
		return

	# ── (b) background terminal session running the mock codex CLI ──────────
	print("\n-- (b) background terminal + launch mock codex --")
	var sessions = so.get_terminal_session_registry()
	check("terminal session registry available", sessions != null)
	if sessions == null:
		await _teardown(pm, registry, null)
		return
	var session = sessions.create_session("w7-e2e-codex", 80, 24)
	check("background session created", session != null and session.started)
	if session == null or not session.started or not session.terminal_available:
		print("SKIP: PTY unavailable (forkpty failed) — cannot run the live loop.")
		await _teardown(pm, registry, session)
		return
	var tid: String = str(session.terminal_id)
	var entry_key := "plugin:%s:terminal-%s" % [PLUGIN_ID, tid]

	session.write_input("python3 -u '%s'\r" % mock_path)
	# Wait for the mock's idle prompt screen (^› line) — the turn-end baseline.
	var idle_seen: bool = await _wait_until(func() -> bool:
		return _has_prompt_line(session.read_viewport_text()))
	check("mock CLI idle prompt screen appeared", idle_seen,
		session.read_viewport_text().right(300))

	# ── (c) watch_start via the plugin tool → provider entry registered ─────
	print("\n-- (c) watch_start → chat-provider entry registered --")
	var watch_res = await _call_plugin_tool(so, conn,
		"minerva_agent_relay_watch_start", {"terminal_id": tid, "profile": PROFILE})
	check("watch_start dispatched without transport error",
		watch_res is Dictionary and not watch_res.has("error"), str(watch_res))
	var entry_present: bool = await _wait_until(func() -> bool:
		return registry != null and registry.has_entry(entry_key), 15000)
	check("provider entry '%s' appeared in the registry" % entry_key, entry_present,
		"entries: %s" % str(registry.list_entries() if registry != null else []))
	if not entry_present:
		await _teardown(pm, registry, session)
		return

	# ── (d) drive the CHAT layer (model level): real PluginProvider turns ───
	# Build the passthrough history exactly as start_passthrough_chat does — its
	# .provider is the REAL PluginProvider configured from the live entry.
	var pane = load(CHATPANE_PATH).new()
	so.plugin_chat_provider_registry = registry
	var history = pane._build_passthrough_history(entry_key, "", tid)
	check("passthrough history built from live entry", history != null)
	if history == null:
		so.plugin_chat_provider_registry = null
		await _teardown(pm, registry, session)
		pane.free()
		return
	var provider = history.provider
	check("history.provider is a real PluginProvider (entry-bound)",
		provider != null and "entry_key" in provider and str(provider.entry_key) == entry_key,
		str(provider.entry_key) if provider != null else "<null>")
	provider.owner_history_id = history.HistoryId

	await _turn_one(so, provider, session)
	await _turn_two_dialog(so, pane, provider, session, tid)
	await _summarize_leg(so, pane, history)

	so.plugin_chat_provider_registry = null
	pane.free()

	# ── (e) teardown: watch_stop → entry gone; session closed ───────────────
	# The provider entry is unregistered on the watch LOOP's cleanup pass, not
	# synchronously inside watch_stop: the loop must wake from its in-flight
	# host.terminal.wait (timeout_ms 20000) before it tears down and dispatches
	# host.chat_providers.unregister. So the entry can take up to ~one wait cycle
	# to vanish — poll generously (25s) before declaring an orphan.
	print("\n-- (e) teardown: watch_stop + session close --")
	await _call_plugin_tool(so, conn, "minerva_agent_relay_watch_stop", {"terminal_id": tid})
	var entry_gone: bool = await _wait_until(func() -> bool:
		return registry != null and not registry.has_entry(entry_key), 25000)
	check("provider entry vanishes after watch_stop (watch-loop cleanup pass)", entry_gone,
		"entries: %s" % str(registry.list_entries() if registry != null else []))

	await _teardown(pm, registry, session)
	check("session closed (no orphan)", not sessions.has_session(tid))


# ── Turn 1: "hello mock" → MOCK-ANSWER, status relay, chime ────────────────
func _turn_one(so, provider, session) -> void:
	print("\n-- (d.1) Turn 1: 'hello mock' answer + status relay + chime --")
	var Status = load(STATUS_PATH)

	# Chime: count chat_completed emissions for this turn (the completion signal
	# reachable at the model level; ChatPane wires response_arrived off it).
	var chimes := [0]
	var sig := func(_b): chimes[0] += 1
	so.chat_completed.connect(sig)

	# Status relay: poll the live session in parallel with the in-flight turn and
	# capture whether the Working/"esc to interrupt" line ever shows.
	var status = Status.new()
	status.begin()
	var saw_busy := [false]
	var poll_running := [true]
	var poller := func():
		while poll_running[0]:
			var compact: String = Status.compact_status(session.read_viewport_text())
			if compact.find("esc to interrupt") != -1:
				saw_busy[0] = true
			await create_timer(0.2).timeout
	poller.call()

	var t0 := Time.get_ticks_msec()
	var bot = await provider.generate_content([{"text": "hello mock"}])
	poll_running[0] = false
	var elapsed := Time.get_ticks_msec() - t0

	check("turn 1 returned a BotResponse", bot != null)
	check("turn 1 no transport error", bot != null and str(bot.error).is_empty(),
		str(bot.error) if bot != null else "<null>")
	check("turn 1 text contains MOCK-ANSWER (verbatim passthrough)",
		bot != null and str(bot.text).find("MOCK-ANSWER") != -1,
		str(bot.text).left(200) if bot != null else "<null>")
	check("turn 1 reversed-echo answer ('kcom olleh')",
		bot != null and str(bot.text).find("kcom olleh") != -1,
		str(bot.text).left(200) if bot != null else "<null>")
	check("turn 1 disposition == answer", _disposition_for(bot) == "answer")
	# Zero LLM/token spend — the passthrough provider never bills.
	check("turn 1 zero prompt tokens", bot != null and bot.prompt_tokens == 0,
		str(bot.prompt_tokens) if bot != null else "?")
	check("turn 1 zero completion tokens", bot != null and bot.completion_tokens == 0,
		str(bot.completion_tokens) if bot != null else "?")
	check("turn 1 status relay observed the Working line", saw_busy[0],
		"elapsed=%dms" % elapsed)
	# Chime fires exactly once for the turn (chat_completed emitted by the provider).
	await process_frame
	check("turn 1 completion signal fired exactly once", chimes[0] == 1, str(chimes[0]))
	so.chat_completed.disconnect(sig)


# ── Turn 2: "trigger-dialog" → question card → answer "y" ──────────────────
func _turn_two_dialog(so, pane, provider, session, tid: String) -> void:
	print("\n-- (d.2) Turn 2: dialog → question options → answer 'y' --")
	var bot = await provider.generate_content([{"text": "trigger-dialog"}])
	check("turn 2 returned a BotResponse", bot != null)
	check("turn 2 disposition == question", _disposition_for(bot) == "question",
		"%s / err=%s" % [str(bot.text).left(120), str(bot.error)] if bot != null else "<null>")
	var opts: Array = bot.hcp_data.get("passthrough_question_options", []) if bot != null else []
	check("turn 2 options parsed (the codex permission triple)", opts.size() == 3,
		str(opts))
	if opts.size() == 3:
		check("turn 2 first option is 'Yes, proceed' / keystroke 'y'",
			str(opts[0].get("label", "")).to_lower().find("yes, proceed") != -1
				and str(opts[0].get("keystroke", "")) == "y", str(opts))

	# W4 reads options off the CHI's HcpData — present them where the card looks.
	var CHI = load(CHAT_HISTORY_ITEM_PATH)
	var chi = CHI.new()
	chi.Role = 1  # ASSISTANT
	chi.Message = str(bot.text) if bot != null else ""
	chi.HcpData["passthrough_question_options"] = opts
	check("W4 surface: options carried onto the CHI HcpData",
		(chi.HcpData.get("passthrough_question_options", []) as Array).size() == 3)

	# Simulate the card answer "y": the plugin's pending_question path writes the
	# raw keystroke to the PTY. Drive it through the real provider (one keystroke
	# text → RawKeystroke on the plugin side). The follow-up turn completes.
	var bot2 = await provider.generate_content([{"text": "y"}])
	check("dialog answer turn returned", bot2 != null)
	check("dialog answer turn no transport error",
		bot2 != null and str(bot2.error).is_empty(),
		str(bot2.error) if bot2 != null else "<null>")
	# The mock CLI prints DIALOG-ANSWERED: y after the raw keystroke — assert via
	# the live session screen (the keystroke truly reached the PTY).
	var answered: bool = await _wait_until(func() -> bool:
		return session.get_plain_text().find("DIALOG-ANSWERED: y") != -1, 15000)
	check("mock CLI printed DIALOG-ANSWERED: y (keystroke reached the PTY)", answered,
		session.read_viewport_text().right(300))
	check("dialog follow-up turn completed (back to answer disposition)",
		_disposition_for(bot2) == "answer", str(bot2.text).left(120) if bot2 != null else "<null>")


# ── W6 summarize-to-note with a STUB distill provider ──────────────────────
func _summarize_leg(so, pane, history) -> void:
	print("\n-- (d.3) summarize-to-note (stub distill provider) --")
	# Seed a minimal attributed transcript so summarize has content.
	var CHI = load(CHAT_HISTORY_ITEM_PATH)
	var u = CHI.new(); u.Role = 0; u.Message = "hello mock"
	history.HistoryItemList.append(u)
	var a = CHI.new(); a.Role = 1; a.Message = "MOCK-ANSWER: kcom olleh"
	history.HistoryItemList.append(a)

	var stub_script := GDScript.new()
	stub_script.source_code = DISTILL_STUB_SRC
	var err := stub_script.reload()
	check("distill stub compiles", err == OK)
	if err != OK:
		return
	var stub = stub_script.new()

	var result: Dictionary = await pane.summarize_passthrough_to_note(history, stub)
	check("summarize result ok", result.get("ok", false), str(result))
	check("summarize made exactly one (stub) provider call", stub.calls == 1, str(stub.calls))
	var note_id := str(result.get("note_id", ""))
	check("summarize returned a note_id", not note_id.is_empty())
	var note = so.get_registered_object(note_id) if not note_id.is_empty() else null
	check("note registered + findable", note != null)
	if note != null:
		var controls = note.get_controls_container()
		check("note content == stub distilled text",
			controls != null and str(controls.content) == "E2E-DISTILLED-SUMMARY",
			str(controls.content) if controls != null else "<no controls>")
		check("note linked to the passthrough chat",
			note.linked_chat_ids.has(history.HistoryId), str(note.linked_chat_ids))
		note.free()
	stub.free()


# ── Helpers ────────────────────────────────────────────────────────────────

## True when the screen shows the codex idle prompt line (^› + space).
func _has_prompt_line(screen: String) -> bool:
	for line in screen.split("\n"):
		if line.begins_with("› "):
			return true
	return false


## Dispatch a plugin tool. Prefer the wired PluginToolRegistry.handle_tool_call
## (the real host dispatch path); fall back to the live connection if the
## registry doesn't know this manifest tool in --script mode.
func _call_plugin_tool(so, conn, tool_name: String, args: Dictionary) -> Dictionary:
	var reg = so.get("plugin_tool_registry")
	if reg != null and reg.has_method("is_plugin_tool") and reg.is_plugin_tool(tool_name):
		return await reg.handle_tool_call(tool_name, args)
	# Manifest tools dispatch 1:1 by name over the connection.
	var res = await conn.call_tool(tool_name, args)
	return res if res is Dictionary else {"error": "non-dict result", "raw": res}


func _teardown(pm, _registry, session) -> void:
	if session != null:
		var sessions = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
		if sessions != null:
			var reg = sessions.get_terminal_session_registry()
			if reg != null and reg.has_session(str(session.terminal_id)):
				reg.close_session(str(session.terminal_id))
	if pm != null:
		var def = pm._db.get_by_id(PLUGIN_ID) if pm._db != null else null
		if def != null and def.state == S_RUNNING:
			await pm.stop_plugin(PLUGIN_ID)
