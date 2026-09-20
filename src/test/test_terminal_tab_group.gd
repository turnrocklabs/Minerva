extends SceneTree
## Test: TerminalTabGroup structure and tab management.
## Run: godot --headless --script test/test_terminal_tab_group.gd
##
## NOTE: TerminalNew.create() requires the GDExtension terminal backend to be
## loaded, which is unavailable in a headless script run.  Tests that would
## normally call add_terminal() / close_terminal() therefore work around this
## by manipulating the internal TabBar directly (the same way TerminalTabGroup
## itself does) so we can verify tab_count(), is_empty(), and the became_empty
## signal without the native extension.

## Stand-in for a TerminalNew view: the rename path only needs get_session(),
## and detach_terminal() (the demote path) only needs detach_session().
class FakeTerminalView extends Control:
	var session = null
	func get_session():
		return session
	func detach_session() -> void:
		session = null


const TERMINAL_TOOLS_PATH := "res://Scripts/Services/MCP/Modules/MCPTerminalTools.gd"


var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== TerminalTabGroup Tests ===\n")

	test_instantiation()
	test_initial_state()
	test_tab_count_increases()
	test_tab_count_decreases()
	test_is_empty_lifecycle()
	test_became_empty_signal()
	await test_double_click_renames_tab_and_session()
	await test_a_second_rename_editor_survives_the_first()
	await test_rename_when_a_tab_closes_under_it()
	await test_visibility_facts()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


# ── Helpers ───────────────────────────────────────────────────────────

## Creates a TerminalTabGroup and adds it to the scene tree so _ready() runs.
func make_group() -> TerminalTabGroup:
	var group := TerminalTabGroup.new()
	get_root().add_child(group)
	return group


## Simulates adding a tab without calling TerminalNew.create() (which needs the
## GDExtension).  Inserts a plain Control as a stand-in terminal node and
## registers it with the internal TabBar exactly as add_terminal() would.
func inject_fake_tab(group: TerminalTabGroup) -> Control:
	var fake := Control.new()
	fake.name = "FakeTerminal"
	fake.visible = false
	group._panel.add_child(fake, true)
	group._tab_bar.add_tab(fake.name)
	group._tab_bar.set_tab_metadata(group._tab_bar.tab_count - 1, fake)
	group._tab_metadata_written.emit()
	group._tab_bar.current_tab = group._tab_bar.tab_count - 1
	return fake


## Adds a tab backed by a FakeTerminalView with its own session, the way
## add_terminal() does (newest tab becomes the current one).
func inject_fake_view(group: TerminalTabGroup, session_name: String) -> FakeTerminalView:
	var view := FakeTerminalView.new()
	view.name = "FakeTerminal"
	view.visible = false
	view.session = TerminalSession.new(session_name)
	group._panel.add_child(view, true)
	group._tab_bar.add_tab(session_name)
	group._tab_bar.set_tab_metadata(group._tab_bar.tab_count - 1, view)
	group._tab_metadata_written.emit()
	group._tab_bar.current_tab = group._tab_bar.tab_count - 1
	return view


## Simulates closing a tab by index without touching TerminalNew.
func remove_fake_tab(group: TerminalTabGroup, tab: int) -> void:
	var node: Control = group._tab_bar.get_tab_metadata(tab)
	group._tab_bar.remove_tab(tab)
	if node:
		node.queue_free()
	group.terminal_closed.emit(tab)
	if group._tab_bar.tab_count == 0:
		group.became_empty.emit()


# ── Tests ─────────────────────────────────────────────────────────────

func test_instantiation() -> void:
	print("test_instantiation:")
	var group := make_group()
	check("TerminalTabGroup is a VBoxContainer", group is VBoxContainer)
	check("_tab_bar is populated after _ready()", group._tab_bar != null)
	check("_panel is populated after _ready()", group._panel != null)
	group.queue_free()


func test_initial_state() -> void:
	print("test_initial_state:")
	var group := make_group()
	# Visibility is false by default — auto-create won't fire yet.
	check("tab_count() starts at 0", group.tab_count() == 0)
	check("is_empty() starts true", group.is_empty())
	group.queue_free()


func test_tab_count_increases() -> void:
	print("test_tab_count_increases:")
	var group := make_group()
	inject_fake_tab(group)
	check("tab_count() == 1 after one inject", group.tab_count() == 1)
	inject_fake_tab(group)
	check("tab_count() == 2 after two injects", group.tab_count() == 2)
	group.queue_free()


func test_tab_count_decreases() -> void:
	print("test_tab_count_decreases:")
	var group := make_group()
	inject_fake_tab(group)
	inject_fake_tab(group)
	remove_fake_tab(group, 0)
	check("tab_count() == 1 after removing one of two", group.tab_count() == 1)
	group.queue_free()


func test_is_empty_lifecycle() -> void:
	print("test_is_empty_lifecycle:")
	var group := make_group()
	check("is_empty() true before any tabs", group.is_empty())
	inject_fake_tab(group)
	check("is_empty() false after one tab", not group.is_empty())
	remove_fake_tab(group, 0)
	check("is_empty() true after removing last tab", group.is_empty())
	group.queue_free()


func test_became_empty_signal() -> void:
	print("test_became_empty_signal:")
	var group := make_group()
	# Array holder: lambdas capture locals by value, so assigning a plain `bool`
	# inside the lambda would never be visible here. Arrays are reference types.
	var fired := [false]
	group.became_empty.connect(func() -> void: fired[0] = true)

	inject_fake_tab(group)
	check("became_empty not fired after adding a tab", not fired[0])

	remove_fake_tab(group, 0)
	check("became_empty fired when last tab removed", fired[0])
	group.queue_free()


## Double-clicking a tab title opens the inline editor, and committing a name
## reaches the SESSION — which is what minerva_terminal_list reports and what
## minerva_terminal_notify resolves against. The PTY keeps the name it was
## spawned with, so the listing's name fields must show both once they differ.
func test_double_click_renames_tab_and_session() -> void:
	print("test_double_click_renames_tab_and_session:")
	var group := make_group()
	var view := FakeTerminalView.new()
	view.name = "FakeTerminal"
	view.visible = false
	var session := TerminalSession.new("codex")
	view.session = session
	group._panel.add_child(view, true)
	group._tab_bar.add_tab("codex")
	group._tab_bar.set_tab_metadata(0, view)
	group._tab_metadata_written.emit()

	# Let the TabBar lay out, so get_tab_rect() reports a real hit area.
	group.visible = true
	await process_frame
	await process_frame

	var rect: Rect2 = group._tab_bar.get_tab_rect(0)
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.double_click = true
	event.position = rect.get_center()
	# Drive the real wiring: the TabBar's gui_input signal, as a click does.
	group._tab_bar.gui_input.emit(event)

	var edit: LineEdit = group._rename_edit
	check("double-click opens the inline rename editor", edit != null)
	check("editor starts from the current tab title", edit != null and edit.text == "codex")

	if edit != null:
		edit.text = "codex-b"
		edit.text_submitted.emit("codex-b")

	check("tab title follows the committed name", group._tab_bar.get_tab_title(0) == "codex-b")
	check("session name follows the committed name", session.session_name == "codex-b")
	check("rename editor is gone after commit", group._rename_edit == null)

	# A session whose shell was spawned before the rename still answers to the
	# old name inside the PTY; the listing reports both.
	session.launch_name = "codex"
	var fields: Dictionary = session.name_fields()
	check("name_fields reports the current name", str(fields.get("name", "")) == "codex-b")
	check("name_fields reports launch_name when it differs", str(fields.get("launch_name", "")) == "codex")

	session.session_name = "codex"
	check("name_fields omits launch_name when the names agree",
		not session.name_fields().has("launch_name"))

	session.free()
	group.queue_free()


## Re-opening the rename over a still-focused editor must leave the SECOND
## editor open. The first is only queued for deletion, so it is still focused
## when the replacement grabs focus, and the focus_exited it emits then used to
## close whichever editor was current — the new one.
func test_a_second_rename_editor_survives_the_first() -> void:
	print("test_a_second_rename_editor_survives_the_first:")
	var group := make_group()
	var view := FakeTerminalView.new()
	view.name = "FakeTerminal"
	view.visible = false
	var session := TerminalSession.new("codex")
	view.session = session
	group._panel.add_child(view, true)
	group._tab_bar.add_tab("codex")
	group._tab_bar.set_tab_metadata(0, view)
	group._tab_metadata_written.emit()
	group.visible = true
	await process_frame
	await process_frame

	var first: LineEdit = group.begin_rename(0)
	check("the first rename editor opened", first != null)
	# Same frame: nothing has been freed yet, so the first editor is still in
	# the tree and still holds focus when the second one takes it.
	var second: LineEdit = group.begin_rename(0)
	check("the second rename editor opened", second != null)
	check("the second editor is the one the group holds", group._rename_edit == second)
	check("the second editor is alive", second != null and is_instance_valid(second))

	if second != null and is_instance_valid(second):
		second.text = "codex-c"
		second.text_submitted.emit("codex-c")
	check("the second editor's commit reaches the tab", group._tab_bar.get_tab_title(0) == "codex-c")
	check("and the session", session.session_name == "codex-c")
	check("no editor is left open", group._rename_edit == null)

	session.free()
	group.queue_free()


## A tab can close while the inline editor is open. The editor is bound to the
## VIEW it was opened over, not to the index it was opened at, so another tab
## closing renumbers nothing that matters and the commit still finds its own
## tab — while the edited tab closing takes its rename with it, leaving the
## editor closed and no title touched.
func test_rename_when_a_tab_closes_under_it() -> void:
	print("test_rename_when_a_tab_closes_under_it:")

	# Leg 1: the edited tab itself goes, and the bystander below it survives.
	# An index-bound editor would have found that survivor at the freed index
	# and renamed it; a view-bound one finds nothing to rename.
	var group := make_group()
	var edited := inject_fake_view(group, "ops")
	var bystander := inject_fake_view(group, "codex")
	var edited_session = edited.session
	var bystander_session = bystander.session
	group.visible = true
	await process_frame
	await process_frame

	var edit: LineEdit = group.begin_rename(0)
	check("the rename editor opened over the first of two tabs", edit != null)
	# Only the EDITED tab goes; the bystander stays so a rename landing on the
	# wrong survivor would show.
	remove_fake_tab(group, 0)
	# queue_free lands at the end of the frame; only then is the view invalid,
	# which is what the commit checks before it renames anything.
	await process_frame
	await process_frame
	if edit != null and is_instance_valid(edit):
		edit.text_submitted.emit("renamed-nothing")
	check("the edited tab is gone and the bystander remains", group.tab_count() == 1)
	check("the commit left no editor open", group._rename_edit == null)
	check("and renamed neither session — the bystander keeps its title and name",
		edited_session.session_name == "ops" and bystander_session.session_name == "codex"
			and group._tab_bar.get_tab_title(0) == "codex")
	edited_session.free()
	bystander_session.free()
	group.queue_free()

	# Leg 2: a tab BELOW the edited one goes, so the edited tab shifts down an
	# index. The commit resolves the view's index again and lands on it.
	var group2 := make_group()
	var doomed := inject_fake_view(group2, "ops")
	var kept := inject_fake_view(group2, "codex")
	var doomed_session = doomed.session
	var kept_session = kept.session
	group2.visible = true
	await process_frame
	await process_frame

	var edit2: LineEdit = group2.begin_rename(1)
	check("the rename editor opened over the second tab", edit2 != null)
	remove_fake_tab(group2, 0)
	await process_frame
	await process_frame
	if edit2 != null and is_instance_valid(edit2):
		edit2.text_submitted.emit("codex-d")
	check("the surviving tab took the committed name",
		group2._tab_bar.tab_count == 1 and group2._tab_bar.get_tab_title(0) == "codex-d")
	check("and so did its session, not the closed one",
		kept_session.session_name == "codex-d" and doomed_session.session_name == "ops")
	doomed_session.free()
	kept_session.free()
	group2.queue_free()


## minerva_terminal_list's `visible` claims a person can SEE the terminal, which
## is three facts at once: a view is attached, the pane is shown, and that tab is
## the selected one in its group. MCPTerminalTools reads all three off the tab
## group, so this drives the real derivation with stand-in views — TerminalNew
## needs the GDExtension backend, which a headless run has no backend for.
func test_visibility_facts() -> void:
	print("test_visibility_facts:")
	var module = load(TERMINAL_TOOLS_PATH).new(null)

	# A hidden Control standing in for the terminal pane: hiding it is exactly
	# what MainUI.set_terminal_pane_visible(false) does to the group below it.
	var pane := Control.new()
	pane.name = "FakeTerminalPane"
	pane.visible = false
	get_root().add_child(pane)
	var group := TerminalTabGroup.new()
	pane.add_child(group)

	var first := inject_fake_view(group, "ops")
	await process_frame

	var facts: Dictionary = module._view_visibility(first)
	check("a view in a hidden pane is not visible", facts["visible"] == false)
	check("...but it still has a view", facts["has_view"] == true)
	check("...and the pane reads as hidden", facts["pane_shown"] == false)
	check("...while its tab is still the selected one", facts["selected"] == true)

	pane.visible = true
	await process_frame
	facts = module._view_visibility(first)
	check("the selected tab of a shown pane is visible",
		facts["visible"] == true and facts["pane_shown"] == true and facts["selected"] == true)

	# A second tab takes the selection, as add_terminal() does.
	var second := inject_fake_view(group, "codex")
	await process_frame
	facts = module._view_visibility(first)
	check("a tab behind another tab is not visible", facts["visible"] == false)
	check("...because it is not the selected tab", facts["selected"] == false)
	check("...though its view is still attached", facts["has_view"] == true)
	check("the tab that took the selection is the visible one",
		module._view_visibility(second)["visible"] == true)

	# Demote (MCPTerminalTools._terminal_demote) calls detach_terminal: the view
	# gives up the session and is freed, so no view can be found for that
	# session and every fact goes false.
	var demoted_session = second.session
	group.detach_terminal(1)
	check("demote leaves the view holding no session", second.session == null)
	check("demote leaves the session with no view of its own",
		demoted_session != null and demoted_session.session_name == "codex")
	facts = module._view_visibility(null)
	check("a demoted session has no view", facts["has_view"] == false)
	check("...and is not visible", facts["visible"] == false)

	if first.session != null:
		first.session.free()
	if demoted_session != null:
		demoted_session.free()
	pane.queue_free()
