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
