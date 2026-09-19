## Host singletons that ChatPane's REAL turn path reaches while it renders.
##
## A headless suite that drives the real executors (execute_regular_chat, the
## parallel-worker delivery path) ends up inside production render code:
##
##   MessageMarkdown._setup_user_message  -> SingletonObject.preferences_popup
##                                           .get_user_initials()/.get_user_full_name()
##   ChatHistoryItem._on_response_arrived -> SingletonObject.notes_container /
##                                           .drawer_notes_container.get_tab_count()
##
## Those autoload fields are only filled by the real RootControl scene, so
## headless they are null and the render path prints `SCRIPT ERROR: ... on a
## null instance`. The suite still passes, but CI's functional runner
## (scripts/run-functional-tests.sh) fails any suite whose output carries a
## SCRIPT ERROR line, so the errors are not cosmetic.
##
## This fixture installs the REAL classes, detached from the tree, so no
## production null-guard is added for the tests' sake:
##   * PreferencesPopup — its scene-unique node refs are all @onready, so
##     outside the tree it is just its ConfigFile, which this fixture seeds with
##     a user name (get_user_initials reads USER/first_name with no default, so
##     an empty config would log a ConfigFile error instead).
##   * NotesContainer x2 — a real empty TabContainer, so get_tab_count() is 0
##     and the disable_notes loops simply do not run.
## Neither node is added to the tree, so no _ready() runs and no scene is needed.
##
## Both classes are loaded BY PATH at install time, never named as identifiers:
## their class bodies read the SingletonObject autoload, which does not exist
## yet while a `--script` suite (and anything it preloads) is being compiled.
##
## Usage:
##   var host := preload("res://test/helpers/chat_host_render_fixture.gd").new()
##   host.install(singleton_object_node)
##   ...
##   host.restore()

extends RefCounted

const PREFERENCES_POPUP_PATH := "res://Scripts/UI/Views/PreferencesPopup.gd"
const NOTES_CONTAINER_PATH := "res://Scenes/note/NotesContainer.gd"

## Seeded in-memory only — the fixture never saves the preferences file.
const USER_FIRST_NAME := "Test"
const USER_LAST_NAME := "Harness"

var _so: Node = null
var _installed: Array[Node] = []
var _previous: Dictionary = {}


## Fills preferences_popup / notes_container / drawer_notes_container on the
## SingletonObject autoload, remembering whatever was there.
func install(so: Node) -> void:
	if so == null or _so != null:
		return
	_so = so
	_previous = {
		"preferences_popup": so.preferences_popup,
		"notes_container": so.notes_container,
		"drawer_notes_container": so.drawer_notes_container,
	}
	if so.preferences_popup == null:
		var popup: Node = load(PREFERENCES_POPUP_PATH).new()
		popup.config_file.set_value("USER", "first_name", USER_FIRST_NAME)
		popup.config_file.set_value("USER", "last_name", USER_LAST_NAME)
		so.preferences_popup = popup
		_installed.append(popup)
	if so.notes_container == null:
		var notes: Node = load(NOTES_CONTAINER_PATH).new()
		so.notes_container = notes
		_installed.append(notes)
	if so.drawer_notes_container == null:
		var drawer: Node = load(NOTES_CONTAINER_PATH).new()
		so.drawer_notes_container = drawer
		_installed.append(drawer)


## Puts the autoload back the way it was and frees what this fixture made.
func restore() -> void:
	if _so == null:
		return
	_so.preferences_popup = _previous["preferences_popup"]
	_so.notes_container = _previous["notes_container"]
	_so.drawer_notes_container = _previous["drawer_notes_container"]
	for node in _installed:
		if is_instance_valid(node):
			node.free()
	_installed.clear()
	_previous.clear()
	_so = null
