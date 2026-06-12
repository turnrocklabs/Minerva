extends SceneTree
## W3 (chat-passthrough): passthrough launch dialog.
##
## Run: timeout 120 godot --headless --path src --script test/test_passthrough_launch.gd
##
## Acceptance (W3 contract):
##   1. infer_profile table: claude/codex/opencode/unknown.
##   2. Validation: empty name blocks Start with an inline error; nonexistent
##      cwd blocks; bind-to-existing selection disables command/cwd fields.
##   3. Launch happy path (stub watch_starter registers the fake agent-relay
##      entry): background session exists in the registry with the right name,
##      the PTY received the cd + `exec bash -lc` writes, the chat is created
##      with PassthroughMode / BoundTerminalId / PassthroughCommand / Cwd.
##   4. Watch-fail + entry-timeout paths: inline error, session CLOSED (no
##      orphan), no chat created, dialog stays open.
##   5. shell_exited → program message lands exactly once in the bound chat.
##   6. ServiceHistory round-trip includes PassthroughCommand/PassthroughCwd;
##      old saves default empty.
##
## NOTE: class_name globals are invisible to --script runs; load() + duck-type
## (the `so` autoload-node harness pattern from test_passthrough_mode.gd).

const DIALOG_PATH := "res://Scripts/UI/Controls/PassthroughLaunchDialog.gd"
const PROVIDER_REGISTRY_PATH := "res://Scripts/Services/Plugins/PluginChatProviderRegistry.gd"
const CHATPANE_PATH := "res://Scripts/UI/Views/ChatPane.gd"
const CHAT_HISTORY_PATH := "res://Scripts/Models/ChatHistory.gd"
const SERVICE_HISTORY_PATH := "res://Scripts/Models/ServiceHistory.gd"
const VBOX_CHAT_PATH := "res://Scripts/UI/Controls/vboxChat.gd"

## ChatPane subclass with the UI presentation of start_passthrough_chat stubbed
## out (render_history & friends need the full scene); the model build, the
## launch field-storage and the exit wiring under test stay REAL.
const PANE_STUB_SOURCE := """
extends "res://Scripts/UI/Views/ChatPane.gd"

var presented: Array = []

func start_passthrough_chat(entry_key: String, display_name: String, bound_terminal_id: String = "") -> ChatHistory:
	var history := _build_passthrough_history(entry_key, display_name, bound_terminal_id)
	if history != null:
		presented.append(history)
	return history
"""

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== W3 passthrough launch dialog test ===\n")
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


func _new_dialog():
	var d = load(DIALOG_PATH).new()
	root.add_child(d)  # _ready builds the form
	return d


func _new_stub_pane():
	var s := GDScript.new()
	s.source_code = PANE_STUB_SOURCE
	var err := s.reload()
	if err != OK:
		return null
	return s.new()


## Poll until predicate() is true or timeout. Returns predicate's final value.
func _wait_until(predicate: Callable, timeout_ms: int = 10000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return bool(predicate.call())


func _run() -> void:
	await process_frame
	var so = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload present", so != null)
	if so == null:
		return

	_test_infer_profile()
	_test_quoting()
	await _test_validation(so)
	await _test_happy_path(so)
	await _test_watch_fail_paths(so)
	await _test_shell_exit_message(so)
	_test_service_history_roundtrip()


# --- Acceptance 1 -----------------------------------------------------------
func _test_infer_profile() -> void:
	print("\n-- infer_profile table --")
	var D = load(DIALOG_PATH)
	check("claude command → claude",
		D.infer_profile("claude --dangerously-skip-permissions") == "claude")
	check("codex command → codex", D.infer_profile("codex -m gpt-5") == "codex")
	check("opencode command → opencode", D.infer_profile("opencode") == "opencode")
	check("unknown command → default claude", D.infer_profile("vim notes.txt") == "claude")
	check("empty command → default claude", D.infer_profile("") == "claude")
	check("case-insensitive", D.infer_profile("CLAUDE") == "claude")


func _test_quoting() -> void:
	print("\n-- shell quoting + launch incantation --")
	var D = load(DIALOG_PATH)
	check("shell_quote wraps in single quotes", D.shell_quote("abc") == "'abc'")
	check("shell_quote escapes embedded single quotes",
		D.shell_quote("a'b") == "'a'\\''b'", D.shell_quote("a'b"))
	check("build_launch_line uses exec bash -lc + \\r",
		D.build_launch_line("claude --x") == "exec bash -lc 'claude --x'\r",
		D.build_launch_line("claude --x"))
	check("build_cd_line quotes + \\r", D.build_cd_line("/tmp/a b") == "cd '/tmp/a b'\r",
		D.build_cd_line("/tmp/a b"))
	check("entry key format", D.entry_key_for_terminal("123") == "plugin:agent_relay:terminal-123")


# --- Acceptance 2 -----------------------------------------------------------
func _test_validation(so) -> void:
	print("\n-- validation: inline errors, dialog stays open --")
	var registry = so.get_terminal_session_registry()
	var dialog = _new_dialog()
	var watch_calls := [0]
	dialog.watch_starter = func(_args: Dictionary) -> Dictionary:
		watch_calls[0] += 1
		return {"ok": true}
	dialog.popup_launch()
	var sessions_before: int = registry.session_count()

	# Empty name → blocked.
	dialog._name_edit.text = ""
	dialog._on_start_pressed()
	check("empty name → inline error", dialog.current_error() != "", dialog.current_error())
	check("empty name → watch never called", watch_calls[0] == 0)
	check("empty name → no session created", registry.session_count() == sessions_before)
	check("empty name → dialog still open", dialog.visible)

	# Nonexistent cwd → blocked.
	dialog._name_edit.text = "Validate Test"
	dialog._cwd_edit.text = "/definitely/not/a/dir/w3_launch_test"
	dialog._on_start_pressed()
	check("bad cwd → inline error mentions directory",
		dialog.current_error().to_lower().contains("directory"), dialog.current_error())
	check("bad cwd → no session created", registry.session_count() == sessions_before)

	# Bind-to-existing disables command/cwd fields.
	var session = registry.create_session("bind-target", 80, 24)
	check("probe session started", session != null and session.started)
	dialog._refresh_existing_dropdown()
	check("existing dropdown lists the live session", dialog._existing_dropdown.item_count == 2,
		str(dialog._existing_dropdown.item_count))
	dialog._existing_dropdown.select(1)
	dialog._on_existing_selected(1)
	check("bind-to-existing → command field disabled", not dialog._command_edit.editable)
	check("bind-to-existing → cwd field disabled", not dialog._cwd_edit.editable)
	dialog._existing_dropdown.select(0)
	dialog._on_existing_selected(0)
	check("back to new-session → command field re-enabled", dialog._command_edit.editable)

	registry.close_session(session.terminal_id)
	dialog.queue_free()
	await process_frame


# --- Acceptance 3 -----------------------------------------------------------
func _test_happy_path(so) -> void:
	print("\n-- launch happy path (stubbed watch registers the entry) --")
	var registry = so.get_terminal_session_registry()
	var cpr = load(PROVIDER_REGISTRY_PATH).new()
	so.plugin_chat_provider_registry = cpr

	var pane = _new_stub_pane()
	check("stub ChatPane compiles", pane != null)
	if pane == null:
		so.plugin_chat_provider_registry = null
		return

	var dialog = _new_dialog()
	dialog.entry_wait_timeout_sec = 3.0
	dialog.chat_starter = pane.launch_passthrough_chat
	var watch_calls: Array = []
	dialog.watch_starter = func(args: Dictionary) -> Dictionary:
		watch_calls.append(args)
		cpr.register_entry("agent_relay", {
			"entry_id": "terminal-%s" % str(args.get("terminal_id", "")),
			"display_name": "Agent on %s" % str(args.get("terminal_id", "")),
			"generate_tool": "minerva_agent_relay_send",
			"history_mode": "newest_only"})
		return {"ok": true}

	dialog.popup_launch()
	# `echo claude-...` keeps profile inference on "claude" without actually
	# launching a real agent CLI in the test environment.
	var command := "echo claude-marker-w3"
	dialog._name_edit.text = "PT Launch Test"
	dialog._command_edit.text = command
	dialog._on_command_changed(command)
	dialog._cwd_edit.text = "/tmp"
	await dialog._on_start_pressed()

	check("no launch error", dialog.current_error() == "", dialog.current_error())
	check("watch seam called once", watch_calls.size() == 1, str(watch_calls.size()))
	if watch_calls.is_empty():
		dialog.queue_free()
		pane.free()
		so.plugin_chat_provider_registry = null
		return
	var tid: String = str(watch_calls[0].get("terminal_id", ""))
	check("watch got a terminal id", not tid.is_empty())
	check("watch got the inferred profile", str(watch_calls[0].get("profile", "")) == "claude",
		str(watch_calls[0]))

	# Background session exists in the registry, named after the form.
	check("background session exists in registry", registry.has_session(tid))
	var session = registry.get_session(tid)
	check("session named from the form", session != null and session.session_name == "PT Launch Test",
		session.session_name if session != null else "<null>")

	# The PTY received the cd + exec bash -lc writes (echoed by the shell).
	var saw_writes: bool = await _wait_until(func() -> bool:
		if session == null:
			return false
		var txt: String = session.get_plain_text()
		return txt.contains("cd '/tmp'") and txt.contains("exec bash -lc 'echo claude-marker-w3'"))
	check("PTY received cd + exec bash -lc writes", saw_writes,
		session.get_plain_text().left(400) if session != null else "<null>")

	# Chat created with the full passthrough binding.
	check("exactly one chat created", pane.presented.size() == 1, str(pane.presented.size()))
	if pane.presented.size() == 1:
		var history = pane.presented[0]
		check("chat PassthroughMode", history.PassthroughMode == true)
		check("chat BoundTerminalId == session id", history.BoundTerminalId == tid,
			history.BoundTerminalId)
		check("chat PassthroughCommand stored", history.PassthroughCommand == command,
			history.PassthroughCommand)
		check("chat PassthroughCwd stored", history.PassthroughCwd == "/tmp", history.PassthroughCwd)
		check("chat PassthroughName from session name", history.PassthroughName == "PT Launch Test",
			history.PassthroughName)
	check("dialog closed on success", not dialog.visible)

	registry.close_session(tid)
	dialog.queue_free()
	pane.free()
	so.plugin_chat_provider_registry = null
	await process_frame


# --- Acceptance 4 -----------------------------------------------------------
func _test_watch_fail_paths(so) -> void:
	print("\n-- watch-fail + entry-timeout: error, session closed, no chat --")
	var registry = so.get_terminal_session_registry()
	var cpr = load(PROVIDER_REGISTRY_PATH).new()
	so.plugin_chat_provider_registry = cpr

	var pane = _new_stub_pane()
	var dialog = _new_dialog()
	dialog.entry_wait_timeout_sec = 0.3
	dialog.chat_starter = pane.launch_passthrough_chat
	dialog.watch_starter = func(_args: Dictionary) -> Dictionary:
		return {"ok": false, "error": "plugin not running"}
	dialog.popup_launch()
	var sessions_before: int = registry.session_count()

	dialog._name_edit.text = "Fail Test"
	dialog._command_edit.text = "echo claude-fail"
	await dialog._on_start_pressed()
	check("watch fail → inline error names the watch/plugin",
		dialog.current_error().to_lower().contains("agent-relay"), dialog.current_error())
	check("watch fail → session closed (no orphan)", registry.session_count() == sessions_before,
		str(registry.session_count()))
	check("watch fail → no chat created", pane.presented.is_empty())
	check("watch fail → dialog still open", dialog.visible)

	# Entry-timeout path: watch claims success but never registers the entry.
	dialog.watch_starter = func(_args: Dictionary) -> Dictionary:
		return {"ok": true}
	await dialog._on_start_pressed()
	check("entry timeout → inline error", dialog.current_error() != "", dialog.current_error())
	check("entry timeout → session closed (no orphan)",
		registry.session_count() == sessions_before, str(registry.session_count()))
	check("entry timeout → no chat created", pane.presented.is_empty())
	check("entry timeout → dialog still open", dialog.visible)

	# isError-style seam result also counts as failure.
	dialog.watch_starter = func(_args: Dictionary) -> Dictionary:
		return {"isError": true, "content": [{"type": "text", "text": "{\"error\": \"boom\"}"}]}
	await dialog._on_start_pressed()
	check("isError envelope → inline error", dialog.current_error() != "", dialog.current_error())
	check("isError envelope → session closed", registry.session_count() == sessions_before)

	dialog.queue_free()
	pane.free()
	so.plugin_chat_provider_registry = null
	await process_frame


# --- Acceptance 5 -----------------------------------------------------------
func _test_shell_exit_message(so) -> void:
	print("\n-- shell_exited → one program message in the bound chat --")
	var registry = so.get_terminal_session_registry()
	var pane = _new_stub_pane()
	var CH = load(CHAT_HISTORY_PATH)
	var VB = load(VBOX_CHAT_PATH)

	var session = registry.create_session("exit-probe", 80, 24)
	check("exit-probe session started", session != null and session.started)
	if session == null or not session.started:
		pane.free()
		return
	var tid: String = str(session.terminal_id)

	var history = CH.new(null, "hist-w3-exit")
	history.PassthroughMode = true
	history.BoundTerminalId = tid
	var vb_parent := Control.new()
	vb_parent.name = "ExitTestParent"
	var vb = VB.new(vb_parent)
	vb.chat_history = history
	history.VBox = vb

	# Wire TWICE — de-dupe must still yield exactly one message per exit.
	pane._wire_passthrough_exit(history)
	pane._wire_passthrough_exit(history)

	session.write_input("exit 3\r")
	var exited: bool = await _wait_until(func() -> bool: return session.shell_exit_code != null)
	check("shell exited", exited)
	await process_frame  # let queued signal lambdas run

	var exit_labels: Array[String] = []
	for child in vb.get_children():
		if child is Label and str(child.text).contains("terminal agent exited"):
			exit_labels.append(child.text)
	check("exactly one exit message", exit_labels.size() == 1, str(exit_labels))
	if exit_labels.size() == 1:
		check("message names the exit code + relaunch affordance",
			exit_labels[0].contains("(code 3)") and exit_labels[0].contains("⇅"),
			exit_labels[0])

	# Binding AFTER the exit (already-dead session) surfaces immediately, once.
	var history2 = CH.new(null, "hist-w3-exit2")
	history2.PassthroughMode = true
	history2.BoundTerminalId = tid
	var vb2 = VB.new(vb_parent)
	vb2.chat_history = history2
	history2.VBox = vb2
	pane._wire_passthrough_exit(history2)
	var late := 0
	for child in vb2.get_children():
		if child is Label and str(child.text).contains("terminal agent exited"):
			late += 1
	check("bind-after-exit surfaces the message immediately, once", late == 1, str(late))

	registry.close_session(tid)
	vb.free()
	vb2.free()
	vb_parent.free()
	pane.free()
	await process_frame


# --- Acceptance 6 -----------------------------------------------------------
func _test_service_history_roundtrip() -> void:
	print("\n-- ServiceHistory: PassthroughCommand/Cwd round-trip --")
	var CH = load(CHAT_HISTORY_PATH)
	var SH = load(SERVICE_HISTORY_PATH)

	var sh = CH.new(null, "hist-w3-rt")
	sh.PassthroughMode = true
	sh.BoundTerminalId = "term-9"
	sh.PassthroughCommand = "claude --dangerously-skip-permissions"
	sh.PassthroughCwd = "/home/me/proj"

	var serialized: Dictionary = sh.Serialize()
	check("Serialize writes PassthroughCommand",
		str(serialized.get("PassthroughCommand", "")) == "claude --dangerously-skip-permissions")
	check("Serialize writes PassthroughCwd", str(serialized.get("PassthroughCwd", "")) == "/home/me/proj")

	var json_data = JSON.parse_string(JSON.stringify(serialized))
	var restored = SH.Deserialize(json_data)
	check("round-trip preserves PassthroughCommand",
		restored.PassthroughCommand == "claude --dangerously-skip-permissions",
		restored.PassthroughCommand)
	check("round-trip preserves PassthroughCwd", restored.PassthroughCwd == "/home/me/proj",
		restored.PassthroughCwd)

	var fields: Array = SH.SERIALIZER_FIELDS
	for f in ["PassthroughCommand", "PassthroughCwd"]:
		check("SERIALIZER_FIELDS has %s" % f, fields.has(f))

	# Old saves (fields absent) → defaults empty.
	var old_dict: Dictionary = CH.new(null, "hist-w3-old").Serialize()
	old_dict.erase("PassthroughCommand")
	old_dict.erase("PassthroughCwd")
	var old_restored = SH.Deserialize(old_dict)
	check("old save: PassthroughCommand defaults empty", old_restored.PassthroughCommand == "")
	check("old save: PassthroughCwd defaults empty", old_restored.PassthroughCwd == "")
