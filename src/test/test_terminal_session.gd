extends SceneTree
## Test: TerminalSession + TerminalSessionRegistry headless PTY core, and the
## TerminalNew view attach/detach lifecycle (chat-passthrough DCR, T1).
##
## Run: godot --headless --path src --script test/test_terminal_session.gd
##
## Coverage (acceptance criteria T1):
##   1. Registry creates a session with NO view → write+wait+read sees output.
##   2. Attach a TerminalNew view → it renders existing scrollback.
##   3. Detach + free the view → session still alive; another round-trip works.
##   4. Two attach/detach cycles → no lost output, no leaked nodes.
##
## The Terminal GDExtension (forkpty) works headless — same as
## test_host_capability_terminal_io.gd. It is required for this CI regression.

const REGISTRY_SCRIPT := "res://Scripts/Services/Terminal/TerminalSessionRegistry.gd"
const TERMINAL_SCENE := "res://Scenes/Terminal.tscn"
const NOTE_SCRIPT := "res://Scripts/UI/Controls/Note.gd"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== TerminalSession / Registry Tests (T1) ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		var msg := "  FAIL: %s" % label
		if not detail.is_empty():
			msg += " — " + detail
		printerr(msg)


## Drive a session to settle after a write, then return its viewport text.
func _wait_for_marker(session, marker: String, timeout_ms: int = 10000) -> String:
	var start: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < timeout_ms:
		await process_frame
		var text: String = session.read_viewport_text()
		if text.find(marker) != -1:
			return text
	return session.read_viewport_text()


func _run() -> void:
	await process_frame
	await process_frame

	if not ClassDB.class_exists("Terminal"):
		check("Terminal GDExtension is available for lifecycle coverage", false)
		return

	var RegistryClass = load(REGISTRY_SCRIPT)
	var registry = RegistryClass.new()
	registry.name = "TestTerminalSessionRegistry"
	root.add_child(registry)
	await process_frame

	# ── AC1: headless session, NO view anywhere ──────────────────────────
	var session = registry.create_session("bg", 80, 24)
	check("registry created session", session != null)
	check("registry count == 1", registry.session_count() == 1)
	check("get_session round-trips", registry.get_session(session.terminal_id) == session)

	if not session.terminal_available:
		check("Terminal PTY starts for lifecycle coverage", false)
		registry.queue_free()
		return

	# No TerminalNew / Control should exist in the tree under the registry.
	var view_under_registry := false
	for child in registry.get_children():
		if child is Control:
			view_under_registry = true
	check("no Control view under registry", not view_under_registry)

	await process_frame
	session.write_input("echo hello_headless\r")
	var out1: String = await _wait_for_marker(session, "hello_headless")
	check("AC1: headless write+read sees output", out1.find("hello_headless") != -1,
		"viewport=%s" % out1)

	# ── AC2: attach a view → renders existing scrollback ─────────────────
	var view = load(TERMINAL_SCENE).instantiate()
	view._auto_create_session = false  # we inject the session
	root.add_child(view)
	await process_frame
	view.attach_session(session)
	# Give the view real grid geometry (headless layout collapses it).
	view._cols = 80
	view._rows = 24
	session.resize(80, 24)
	for i in range(10):
		await process_frame

	check("AC2: view reports terminal_available", view._terminal_available)
	check("AC2: view.terminal is session's node", view.terminal == session.terminal)
	check("AC2: session records its attached view", session.get_attached_view() == view)
	view._start_new_block(0, 0)
	view._start_new_block(2, 2)
	check("AC2: prompt markers created real block controls",
		view._blocks.size() == 2 and view._check_buttons_container.get_child_count() == 4)
	var so = root.get_node_or_null("SingletonObject")
	var NoteScript = load(NOTE_SCRIPT)
	var proxy = NoteScript.Proxy.new(func(): return null)
	view._blocks[0].checked = true
	view._blocks[0].proxy = proxy
	so.detached_note_proxies.append(proxy)
	check("AC2: checked block proxy entered detached injection state",
		proxy in so.detached_note_proxies)
	session.terminal.emit_signal("seq_erase_entire_screen")
	await process_frame
	check("AC2: native 2J retires block state, controls, and injection proxies",
		view._blocks.is_empty() and view._check_buttons_container.get_child_count() == 0
		and proxy not in so.detached_note_proxies)
	view._start_new_block(0, 0)
	session.terminal.emit_signal("seq_erase_saved_lines")
	await process_frame
	check("AC2: native 3J also retires block state and controls",
		view._blocks.is_empty() and view._check_buttons_container.get_child_count() == 0)
	# Split-layout rebuilds temporarily remove groups (and their views) from the
	# tree. Ownership must remain visible while the view is detached from it.
	root.remove_child(view)
	var duplicate = load(TERMINAL_SCENE).instantiate()
	duplicate._auto_create_session = false
	root.add_child(duplicate)
	await process_frame
	duplicate.attach_session(session)
	check("AC2: a second real view cannot adopt during layout reparenting",
		duplicate.get_session() == null and session.get_attached_view() == view)
	duplicate.queue_free()
	root.add_child(view)
	# The view extracts text from the SAME session scrollback.
	var view_text := ""
	var info: Dictionary = session.get_scroll_info()
	var total: int = info.get("total_rows", 0)
	for row in range(total):
		view_text += view._extract_row_text_screen(row) + "\n"
	check("AC2: view renders existing scrollback", view_text.find("hello_headless") != -1,
		"view_text=%s" % view_text)

	# ── AC3: detach + free the view → session survives, round-trip works ──
	view.detach_session()
	check("AC3: view detached (no session)", view.get_session() == null)
	check("AC3: detach releases authoritative view ownership", session.get_attached_view() == null)
	view.queue_free()
	await process_frame
	await process_frame

	check("AC3: session still alive after view freed", session.is_alive())
	check("AC3: session still in registry", registry.has_session(session.terminal_id))

	# Freeing a view without an explicit detach must not permanently reserve the
	# session; the weak claim expires with the view.
	var abandoned = load(TERMINAL_SCENE).instantiate()
	abandoned._auto_create_session = false
	root.add_child(abandoned)
	await process_frame
	abandoned.attach_session(session)
	abandoned._start_new_block(0, 0)
	var abandoned_proxy = NoteScript.Proxy.new(func(): return null)
	abandoned._blocks[0].checked = true
	abandoned._blocks[0].proxy = abandoned_proxy
	so.detached_note_proxies.append(abandoned_proxy)
	check("AC3: abandoned view proxy entered detached injection state",
		abandoned_proxy in so.detached_note_proxies)
	abandoned.queue_free()
	await process_frame
	await process_frame
	check("AC3: freeing a view releases its ownership claim and checked proxy",
		session.get_attached_view() == null
		and abandoned_proxy not in so.detached_note_proxies)

	session.write_input("echo after_detach\r")
	var out2: String = await _wait_for_marker(session, "after_detach")
	check("AC3: post-detach write+read works", out2.find("after_detach") != -1,
		"viewport=%s" % out2)
	# Earlier output not lost from scrollback.
	check("AC3: earlier output retained in scrollback",
		session.read_viewport_text().find("hello_headless") != -1 or out2.find("hello_headless") != -1,
		"checking scrollback retention")

	# ── AC4: two sequential attach/detach cycles, no leaks ───────────────
	var orphans_before := _count_orphans()
	for cycle in range(2):
		var v = load(TERMINAL_SCENE).instantiate()
		v._auto_create_session = false
		root.add_child(v)
		await process_frame
		v.attach_session(session)
		v._cols = 80
		v._rows = 24
		session.resize(80, 24)
		for i in range(6):
			await process_frame
		check("AC4 cycle %d: view sees session output" % cycle,
			session.read_viewport_text().find("after_detach") != -1
			or _viewport_has(session, "after_detach"),
			"cycle %d" % cycle)
		v.detach_session()
		v.queue_free()
		await process_frame
		await process_frame
		check("AC4 cycle %d: session alive after cycle" % cycle, session.is_alive())

	# Final round-trip proves nothing broke across cycles.
	session.write_input("echo cycles_done\r")
	var out3: String = await _wait_for_marker(session, "cycles_done")
	check("AC4: round-trip after 2 cycles", out3.find("cycles_done") != -1,
		"viewport=%s" % out3)

	# ── Cleanup + leak check ─────────────────────────────────────────────
	var closing_view = load(TERMINAL_SCENE).instantiate()
	closing_view._auto_create_session = false
	root.add_child(closing_view)
	await process_frame
	closing_view.attach_session(session)
	registry.close_session(session.terminal_id)
	check("close_session drops from registry", not registry.has_session(session.terminal_id))
	check("close_session detaches its live view", closing_view.get_session() == null)
	closing_view.queue_free()
	await process_frame
	await process_frame
	registry.queue_free()
	await process_frame
	await process_frame

	var orphans_after := _count_orphans()
	check("AC4: no leaked nodes across cycles", orphans_after <= orphans_before,
		"orphans before=%d after=%d" % [orphans_before, orphans_after])


func _viewport_has(session, marker: String) -> bool:
	var info: Dictionary = session.get_scroll_info()
	var total: int = info.get("total_rows", 0)
	for row in range(total):
		if session.extract_row_text_screen(row).find(marker) != -1:
			return true
	return false


func _count_orphans() -> int:
	# get_monitor() returns float; the orphan count is a whole number, so round
	# rather than let the implicit float -> int narrowing truncate it.
	return roundi(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
