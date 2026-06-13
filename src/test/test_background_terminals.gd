extends SceneTree
## Test: background terminal sessions through the MCP tool surface +
## host.terminal.* capabilities (chat-passthrough DCR, T2).
##
## Run: godot --headless --path src --script test/test_background_terminals.gd
##
## Coverage (acceptance criteria T2):
##   1. NO tab group in tree: terminal_create {background: true} succeeds;
##      write/wait/read round-trip ("bg42"). Default (visible) create still
##      fails with the tab-group error.
##   2. terminal_list reports visible == false; after promote (tab group
##      present) visible == true and the view renders the session scrollback;
##      after demote visible == false and write/read still works.
##   3. promote with no tab group → clear error (headless has no MainUI pane
##      to open).
##   4. CapabilityBroker host.terminal.{list,read,write,wait} round-trip
##      against a background session (no view ever attached).
##   5. Dead-session hygiene: shell exit → session stays listed, flagged
##      alive == false (flag-not-prune design).
##   6. terminal_close removes a background session from the registry/list.
##
## Tools are driven through MCPTerminalTools.handle() with a null server, the
## same idiom as test_mcp_annotation_tools.gd. ALL scripts that name the
## SingletonObject autoload (MCPTerminalTools, TerminalTabGroup→TerminalNew)
## are load()ed at runtime, never referenced as compile-time globals — a
## --script test compiles before autoloads register and would poison them for
## the whole run. Sessions/views/groups are duck-typed for the same reason.

const TOOLS_SCRIPT_PATH := "res://Scripts/Services/MCP/Modules/MCPTerminalTools.gd"
const TAB_GROUP_SCRIPT_PATH := "res://Scripts/UI/Controls/TerminalTabGroup.gd"
const TEST_PLUGIN_ID := "background_terminal_probe_test"
const BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"
const DEFINITION_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDefinition.gd"
const CAPS := [
	"host.terminal.list",
	"host.terminal.read",
	"host.terminal.write",
	"host.terminal.wait",
	"host.terminal.exec",  # T3: exec resolves through the same registry path
]

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Background Terminal Tests (T2) ===\n")
	_clear_policy_for_test()
	await _run()
	_clear_policy_for_test()
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


## Find the terminal_list entry for an id (or empty dict).
func _list_entry(tools, id: String) -> Dictionary:
	var listed: Dictionary = await tools.handle("minerva_terminal_list", {})
	for entry in listed.get("terminals", []):
		if str(entry.get("id", "")) == id:
			return entry
	return {}


## Write a command and wait for a marker to appear in the viewport via the
## MCP tool surface. Returns the final read content.
func _round_trip(tools, id: String, command: String, marker: String) -> String:
	var wr: Dictionary = await tools.handle("minerva_terminal_write",
		{"terminal_id": id, "text": command})
	if not wr.get("success", false):
		return "[write failed: %s]" % str(wr)
	var start: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < 15000:
		var rd: Dictionary = await tools.handle("minerva_terminal_read", {"terminal_id": id})
		if str(rd.get("content", "")).find(marker) != -1:
			return str(rd.get("content", ""))
		await process_frame
	var final: Dictionary = await tools.handle("minerva_terminal_read", {"terminal_id": id})
	return str(final.get("content", ""))


func _run() -> void:
	await process_frame
	await process_frame

	if not ClassDB.class_exists("Terminal"):
		print("  SKIP: Terminal GDExtension not available — live PTY tests skipped")
		return

	var so = root.get_node_or_null("SingletonObject")
	if so == null:
		print("  SKIP: SingletonObject autoload not available under this invocation")
		return

	var tools = load(TOOLS_SCRIPT_PATH).new(null)

	# ── AC1: background create with NO tab group anywhere ───────────────
	print("-- AC1: background create + IO with no tab group --")

	# Today's failure mode is preserved for the default (visible) path.
	var vis_create: Dictionary = await tools.handle("minerva_terminal_create", {})
	check("AC1: default create without tab group still errors",
		not vis_create.get("success", true)
		and str(vis_create.get("error", "")).find("No terminal tab group") != -1,
		"got: %s" % str(vis_create))

	var created: Dictionary = await tools.handle("minerva_terminal_create",
		{"background": true, "name": "bg-t2"})
	check("AC1: background create succeeds", created.get("success", false),
		"got: %s" % str(created))
	check("AC1: created reports visible false", created.get("visible", true) == false)
	var bg_id: String = str(created.get("id", ""))
	check("AC1: created returns an id", not bg_id.is_empty())

	var registry = so.get_terminal_session_registry()
	check("AC1: session registered under registry", registry.has_session(bg_id))
	if not registry.get_session(bg_id).terminal_available:
		print("  SKIP: terminal extension instantiated but forkpty unavailable")
		return

	var out1: String = await _round_trip(tools, bg_id, "echo bg42\r", "bg42")
	check("AC1: write+read round-trip sees bg42", out1.find("bg42") != -1,
		"content=%s" % out1)

	var waited: Dictionary = await tools.handle("minerva_terminal_wait",
		{"terminal_id": bg_id, "timeout_ms": 5000, "settle_ms": 300})
	check("AC1: wait succeeds on background session", waited.get("success", false),
		"got: %s" % str(waited))

	# ── AC3: promote with no tab group → clear error ─────────────────────
	print("\n-- AC3: promote with no tab group --")
	var promote_fail: Dictionary = await tools.handle("minerva_terminal_promote",
		{"terminal_id": bg_id})
	check("AC3: promote without tab group errors clearly",
		not promote_fail.get("success", true)
		and str(promote_fail.get("error", "")).find("No terminal tab group") != -1,
		"got: %s" % str(promote_fail))

	# ── AC2: list visibility + promote/demote lifecycle ──────────────────
	print("\n-- AC2: list visible flag + promote/demote --")
	var entry: Dictionary = await _list_entry(tools, bg_id)
	check("AC2: background session listed", not entry.is_empty())
	check("AC2: listed visible == false", entry.get("visible", true) == false)
	check("AC2: listed alive == true", entry.get("alive", false) == true)
	check("AC2: listed name == bg-t2", str(entry.get("name", "")) == "bg-t2")

	# Hidden group: visible=false dodges the auto-create-on-visible behaviour so
	# the test controls exactly which sessions exist.
	var group = load(TAB_GROUP_SCRIPT_PATH).new()
	group.visible = false
	root.add_child(group)
	await process_frame

	var promoted: Dictionary = await tools.handle("minerva_terminal_promote",
		{"terminal_id": bg_id})
	check("AC2: promote succeeds", promoted.get("success", false),
		"got: %s" % str(promoted))
	check("AC2: promote reports visible true", promoted.get("visible", false) == true)
	check("AC2: promote keeps the id stable", str(promoted.get("id", "")) == bg_id)
	await process_frame

	entry = await _list_entry(tools, bg_id)
	check("AC2: visible == true after promote", entry.get("visible", false) == true)
	check("AC2: tab group has 1 tab after promote", group.tab_count() == 1)

	# The promoted view renders the session's existing scrollback (bg42).
	var view = group.get_active_terminal()
	check("AC2: promoted view attached to the session",
		view != null and view.get_session() == registry.get_session(bg_id))
	var view_text := ""
	if view:
		var session = registry.get_session(bg_id)
		var total: int = session.get_scroll_info().get("total_rows", 0)
		for row in range(total):
			view_text += view._extract_row_text_screen(row) + "\n"
	check("AC2: promoted view text contains bg42", view_text.find("bg42") != -1,
		"view_text=%s" % view_text)

	var promoted_again: Dictionary = await tools.handle("minerva_terminal_promote",
		{"terminal_id": bg_id})
	check("AC2: promote of visible terminal is no-op success",
		promoted_again.get("success", false)
		and promoted_again.get("already_visible", false) == true,
		"got: %s" % str(promoted_again))
	check("AC2: no duplicate tab from double promote", group.tab_count() == 1)

	var demoted: Dictionary = await tools.handle("minerva_terminal_demote",
		{"terminal_id": bg_id})
	check("AC2: demote succeeds", demoted.get("success", false), "got: %s" % str(demoted))
	check("AC2: demote reports visible false", demoted.get("visible", true) == false)
	await process_frame
	await process_frame

	entry = await _list_entry(tools, bg_id)
	check("AC2: visible == false after demote", entry.get("visible", true) == false)
	check("AC2: tab group empty after demote", group.tab_count() == 0)
	check("AC2: session still alive after demote", registry.get_session(bg_id).is_alive())

	var out2: String = await _round_trip(tools, bg_id, "echo bg43\r", "bg43")
	check("AC2: post-demote write+read round-trip works", out2.find("bg43") != -1,
		"content=%s" % out2)

	var demoted_again: Dictionary = await tools.handle("minerva_terminal_demote",
		{"terminal_id": bg_id})
	check("AC2: demote of background session is no-op success",
		demoted_again.get("success", false)
		and demoted_again.get("already_background", false) == true,
		"got: %s" % str(demoted_again))

	# ── AC4: CapabilityBroker host.terminal.* against a background session ─
	print("\n-- AC4: host.terminal.* round-trip on background session --")
	if so.get("plugin_capability_broker") == null or so.get("plugin_policy") == null \
			or so.get("plugin_manager") == null:
		print("  SKIP: capability broker not available under this invocation")
	else:
		var Def = load(DEFINITION_SCRIPT_PATH)
		var def = Def.new(TEST_PLUGIN_ID)
		var caps_typed: Array[String] = []
		caps_typed.assign(CAPS)
		def.host_capabilities = caps_typed
		so.plugin_manager.get_db()._plugins[TEST_PLUGIN_ID] = def
		var broker = so.plugin_capability_broker
		var policy = so.plugin_policy
		for cap in CAPS:
			policy.grant_capability(TEST_PLUGIN_ID, cap)
		var Broker = load(BROKER_SCRIPT_PATH)
		Broker._test_terminal_tool_override = null

		var blist: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.list", {})
		check("AC4: host.terminal.list succeeds", blist.get("success", false),
			"got: %s" % str(blist))
		var bg_entry: Dictionary = {}
		for e in blist.get("result", {}).get("terminals", []):
			if str(e.get("id", "")) == bg_id:
				bg_entry = e
		check("AC4: host.terminal.list includes the background session",
			not bg_entry.is_empty())
		check("AC4: host.terminal.list entry has visible == false",
			bg_entry.has("visible") and bg_entry.get("visible", true) == false,
			"entry=%s" % str(bg_entry))

		var bwr: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.write",
			{"terminal_id": bg_id, "text": "printf 'marker_%s\\n' bg_broker\r"})
		check("AC4: host.terminal.write succeeds", bwr.get("success", false),
			"got: %s" % str(bwr))
		var bwait: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.wait",
			{"terminal_id": bg_id, "timeout_ms": 10000, "settle_ms": 400})
		check("AC4: host.terminal.wait succeeds", bwait.get("success", false),
			"got: %s" % str(bwait))
		check("AC4: wait content has marker",
			str(bwait.get("result", {}).get("content", "")).find("marker_bg_broker") != -1,
			"content=%s" % str(bwait.get("result", {}).get("content", "")))
		var brd: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.read",
			{"terminal_id": bg_id})
		check("AC4: host.terminal.read sees marker",
			str(brd.get("result", {}).get("content", "")).find("marker_bg_broker") != -1,
			"got: %s" % str(brd))

		# T3: host.terminal.exec named at a BACKGROUND session resolves through
		# the same registry path and runs IN that session's PTY (write→wait),
		# not in the subprocess fallback.
		Broker._test_terminal_exec_override = null
		var bexec: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.exec",
			{"command": "echo exec_bg_t3", "terminal_id": bg_id, "timeout_ms": 8000})
		check("T3: host.terminal.exec on background session succeeds",
			bexec.get("success", false), "got: %s" % str(bexec))
		var bexec_res: Dictionary = bexec.get("result", {})
		check("T3: exec routed_through == terminal (not headless fallback)",
			str(bexec_res.get("routed_through", "")) == "terminal",
			"result=%s" % str(bexec_res))
		check("T3: exec terminal_id is the SESSION id (registry namespace)",
			str(bexec_res.get("terminal_id", "")) == bg_id)
		check("T3: exec stdout contains the marker",
			str(bexec_res.get("stdout", "")).find("exec_bg_t3") != -1,
			"stdout=%s" % str(bexec_res.get("stdout", "")))
		check("T3: exec exit_code_known false on the PTY path",
			bexec_res.get("exit_code_known", true) == false)
		# The command actually ran in THAT session: its scrollback has the marker.
		check("T3: session scrollback shows the exec command ran there",
			registry.get_session(bg_id).get_plain_text().find("exec_bg_t3") != -1)

	# ── AC5: dead-session hygiene — flagged alive=false, NOT pruned ──────
	print("\n-- AC5: dead-session flagging --")
	var created2: Dictionary = await tools.handle("minerva_terminal_create",
		{"background": true, "name": "bg-dying"})
	var dying_id: String = str(created2.get("id", ""))
	check("AC5: second background session created", created2.get("success", false))

	var wr_exit: Dictionary = await tools.handle("minerva_terminal_write",
		{"terminal_id": dying_id, "text": "exit 7\r"})
	check("AC5: write exit succeeds", wr_exit.get("success", false))
	var wait_exit: Dictionary = await tools.handle("minerva_terminal_wait",
		{"terminal_id": dying_id, "timeout_ms": 10000, "settle_ms": 400})
	check("AC5: wait reports shell_exited", wait_exit.get("shell_exited", false) == true,
		"got: %s" % str(wait_exit))
	check("AC5: wait reports exit code 7", wait_exit.get("shell_exit_code", -1) == 7)

	var dead_entry: Dictionary = await _list_entry(tools, dying_id)
	check("AC5: dead session STILL listed (flag, not prune)", not dead_entry.is_empty())
	check("AC5: dead session flagged alive == false",
		dead_entry.get("alive", true) == false, "entry=%s" % str(dead_entry))
	check("AC5: dead session visible == false", dead_entry.get("visible", true) == false)

	# Scrollback of a dead session remains readable (the point of flagging).
	var dead_read: Dictionary = await tools.handle("minerva_terminal_read",
		{"terminal_id": dying_id})
	check("AC5: dead session scrollback still readable",
		dead_read.get("success", false) and str(dead_read.get("content", "")).find("exit") != -1,
		"got: %s" % str(dead_read))

	# ── AC6: close removes background sessions ───────────────────────────
	print("\n-- AC6: close background sessions --")
	var closed: Dictionary = await tools.handle("minerva_terminal_close",
		{"terminal_id": dying_id})
	check("AC6: close dead background session succeeds", closed.get("success", false))
	check("AC6: closed session gone from registry", not registry.has_session(dying_id))
	var gone: Dictionary = await _list_entry(tools, dying_id)
	check("AC6: closed session gone from list", gone.is_empty())

	var closed1: Dictionary = await tools.handle("minerva_terminal_close",
		{"terminal_id": bg_id})
	check("AC6: close live background session succeeds", closed1.get("success", false))
	check("AC6: live session gone from registry", not registry.has_session(bg_id))

	group.queue_free()
	await process_frame
	await process_frame

	await _test_pane_adoption(registry, tools)


## W8 HITL: a visible tab group ADOPTS every live session as a regular tab —
## background terminals are just tabs the pane hasn't rendered yet.
func _test_pane_adoption(registry, tools) -> void:
	print("\n-- W8: visible pane adopts background sessions --")

	# Two background sessions exist BEFORE the pane opens.
	var a: Dictionary = await tools.handle("minerva_terminal_create",
		{"background": true, "name": "adopt-a"})
	var b: Dictionary = await tools.handle("minerva_terminal_create",
		{"background": true, "name": "adopt-b"})
	var a_id: String = str(a.get("id", ""))
	var b_id: String = str(b.get("id", ""))

	var group = load(TAB_GROUP_SCRIPT_PATH).new()
	root.add_child(group)
	group.visible = true  # entering the tree visible fires visibility sync
	await process_frame
	await process_frame

	check("adoption: both sessions got tabs (no bare shell added)",
		group.tab_count() == 2, "tabs=%d" % group.tab_count())
	var adopted_a = _find_view_for(a_id)
	check("adoption: view attached to session a", adopted_a != null)
	check("adoption: re-sync is idempotent (no duplicate tabs)",
		_count_views_for(a_id) == 1, "views=%d" % _count_views_for(a_id))

	# A session created WHILE the pane is open appears as a tab (deferred sync).
	var c: Dictionary = await tools.handle("minerva_terminal_create",
		{"background": true, "name": "adopt-c"})
	var c_id: String = str(c.get("id", ""))
	await process_frame
	await process_frame
	check("adoption: session created while visible gets a tab",
		_count_views_for(c_id) == 1, "views=%d" % _count_views_for(c_id))
	check("adoption: list reports it visible", bool((await _list_entry(tools, c_id)).get("visible", false)))

	# Adopted tabs are interactive: write through the view's session round-trips.
	var rt: String = await _round_trip(tools, a_id, "echo adopt-rt-$((40+2))\r", "adopt-rt-42")
	check("adoption: adopted terminal still round-trips", rt.find("adopt-rt-42") != -1, rt)

	# Demote stays demoted until the NEXT sync event (documented semantics).
	var dem: Dictionary = await tools.handle("minerva_terminal_demote", {"terminal_id": b_id})
	check("adoption: demote succeeds", dem.get("success", false))
	await process_frame
	check("adoption: demoted tab not instantly re-adopted",
		_count_views_for(b_id) == 0, "views=%d" % _count_views_for(b_id))
	group.visible = false
	await process_frame
	group.visible = true  # next visibility sync re-adopts
	await process_frame
	await process_frame
	check("adoption: visibility toggle re-adopts the demoted session",
		_count_views_for(b_id) == 1, "views=%d" % _count_views_for(b_id))

	# Cleanup.
	for tid in [a_id, b_id, c_id]:
		await tools.handle("minerva_terminal_close", {"terminal_id": tid})
	group.queue_free()
	await process_frame
	await process_frame

	await _test_adoption_resizes_grid(registry, tools)


## W8 HITL scroll bug: adopting an already-running background session into a
## REAL-sized pane must reflow the PTY/vt grid to the view's geometry. The
## session starts at 80×24 in the background; without the resize the view
## renders a clipped 80×24 grid (content wraps at col 80, scrollback math uses
## viewport_rows=24 against a much shorter view) and scrolling reads as dead.
func _test_adoption_resizes_grid(registry, tools) -> void:
	print("\n-- W8: adoption reflows the PTY grid to the view --")

	var created: Dictionary = await tools.handle("minerva_terminal_create",
		{"background": true, "name": "adopt-resize"})
	var tid: String = str(created.get("id", ""))
	var session = registry.get_session(tid)
	check("adopt-resize: background session starts 80x24",
		session != null and session.get_cols() == 80 and session.get_rows() == 24)

	var group = load(TAB_GROUP_SCRIPT_PATH).new()
	# A real on-screen pane: big enough to clear the degenerate-rect guard.
	group.custom_minimum_size = Vector2(1200, 400)
	group.size = Vector2(1200, 400)
	root.add_child(group)
	group.visible = true
	# _ready sync awaits a frame; container layout + a possible resized-signal
	# sync need a few more.
	for i in range(5):
		await process_frame

	var view = _find_view_for(tid)
	check("adopt-resize: view attached", view != null)
	if view != null:
		var expected_cols: int = view._cols
		var expected_rows: int = view._rows
		check("adopt-resize: view computed a non-default grid",
			expected_cols != 80 or expected_rows != 24,
			"computed %dx%d" % [expected_cols, expected_rows])
		var info: Dictionary = session.get_scroll_info()
		check("adopt-resize: vt viewport reflowed to the view's rows",
			int(info.get("viewport_rows", -1)) == expected_rows,
			"viewport_rows=%s expected=%d" % [str(info.get("viewport_rows")), expected_rows])

	await tools.handle("minerva_terminal_close", {"terminal_id": tid})
	group.queue_free()
	await process_frame
	await process_frame


func _find_view_for(session_id: String):
	for term in root.get_tree().get_nodes_in_group("terminal_pane"):
		if is_instance_valid(term) and term.has_method("get_session"):
			var s = term.get_session()
			if s != null and is_instance_valid(s) and str(s.terminal_id) == session_id:
				return term
	return null


func _count_views_for(session_id: String) -> int:
	var n := 0
	for term in root.get_tree().get_nodes_in_group("terminal_pane"):
		if is_instance_valid(term) and term.has_method("get_session"):
			var s = term.get_session()
			if s != null and is_instance_valid(s) and str(s.terminal_id) == session_id:
				n += 1
	return n


func _clear_policy_for_test() -> void:
	var policy_file: String = ProjectSettings.globalize_path("user://plugins/policy.json")
	if not FileAccess.file_exists(policy_file):
		return
	var fa := FileAccess.open(policy_file, FileAccess.READ)
	if fa == null:
		return
	var raw := fa.get_as_text()
	fa.close()
	var data: Variant = JSON.parse_string(raw)
	if not data is Dictionary:
		return
	var grants: Dictionary = (data as Dictionary).get("grants", {})
	grants.erase(TEST_PLUGIN_ID)
	(data as Dictionary)["grants"] = grants
	fa = FileAccess.open(policy_file, FileAccess.WRITE)
	if fa == null:
		return
	fa.store_string(JSON.stringify(data, "  "))
	fa.close()
