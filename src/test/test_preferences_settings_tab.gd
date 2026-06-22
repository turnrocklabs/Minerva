extends SceneTree
## Tests for the declarative Settings tab in PreferencesPopup.
##
## Run: godot --headless --path src --script test/test_preferences_settings_tab.gd
##
## The full PreferencesPopup scene cannot boot headless (its _ready loads
## encrypted prefs, wires Core signals, and touches the AudioServer), so this
## builds a detached PreferencesPopup node — _ready does not fire while it is
## out of the tree — supplies just the TabContainer path that _create_settings_tab
## needs, swaps in a controlled store (in-memory persistence, one fake plugin),
## and drives the tab builder + field renderer directly. No real config is touched.

var _pass_count: int = 0
var _fail_count: int = 0


class MemPersist:
	var mem: Dictionary = {}

	func read(section: String, key: String) -> Variant:
		return (mem.get(section, {}) as Dictionary).get(key, null)

	func write(section: String, key: String, value: Variant) -> void:
		if not mem.has(section):
			mem[section] = {}
		(mem[section] as Dictionary)[key] = value


class FakeDB:
	var defs: Dictionary = {}

	func get_by_id(plugin_id: String):
		return defs.get(plugin_id, null)

	func get_all() -> Array:
		return defs.values()


func _init() -> void:
	print("=== Preferences Settings Tab Tests ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	quit(1 if _fail_count > 0 else 0)


func _check(cond: bool, label: String) -> void:
	if cond:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s" % label)


## First LineEdit under `node`, or null.
func _first_lineedit(node: Node) -> LineEdit:
	if node is LineEdit:
		return node as LineEdit
	for child in node.get_children():
		var found := _first_lineedit(child)
		if found != null:
			return found
	return null


## Recursively look for a Label whose text equals `text` under `node`.
func _find_label(node: Node, text: String) -> bool:
	if node is Label and (node as Label).text == text:
		return true
	for child in node.get_children():
		if _find_label(child, text):
			return true
	return false


func _run() -> void:
	# Autoloads register after the first frames.
	await process_frame
	await process_frame

	var singleton = root.get_node_or_null("SingletonObject")
	_check(singleton != null, "SingletonObject autoload present")
	if singleton == null:
		return

	# Controlled store: core "Summarization" group plus one declaring plugin.
	var plugin := PluginDefinition.new("demo")
	plugin.name = "Demo Plugin"
	plugin.settings = [
		{"key": "mode", "type": "enum", "label": "Mode", "default": "fast", "options": ["fast", "slow"]},
		{"key": "enabled", "type": "bool", "label": "Enabled", "default": true},
	]
	var db := FakeDB.new()
	db.defs["demo"] = plugin

	var StoreScript := load("res://Scripts/Services/Plugins/PluginSettingsStore.gd")
	var store = StoreScript.new(db, MemPersist.new())

	var saved_store = singleton.plugin_settings_store
	singleton.plugin_settings_store = store

	# Build a detached PreferencesPopup; while out of the tree, _ready will not run.
	var PopupScript := load("res://Scripts/UI/Views/PreferencesPopup.gd")
	var popup = PopupScript.new()

	# Reproduce just the node path _create_settings_tab walks.
	var margin := MarginContainer.new()
	margin.name = "MarginContainer"
	popup.add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.name = "VBoxContainer"
	margin.add_child(vbox)
	var tab_container := TabContainer.new()
	tab_container.name = "TabContainer"
	vbox.add_child(tab_container)

	popup._create_settings_tab()

	var settings_tab: Node = null
	for child in tab_container.get_children():
		if child.name == "Settings":
			settings_tab = child
			break
	_check(settings_tab != null, "Settings tab node exists")

	if settings_tab != null:
		_check(_find_label(settings_tab, "Summarization"), "core scope renders Summarization section")
		_check(_find_label(settings_tab, "Demo Plugin"), "plugin scope renders the store-provided title")
		_check(_find_label(settings_tab, "Summarization model"), "core string field label present")
		_check(_find_label(settings_tab, "Mode"), "plugin enum field label present")

	# Drive an actual widget signal and assert the edit routes through the store.
	var probe := VBoxContainer.new()
	popup.add_child(probe)
	popup._add_setting_field(probe, "core", {
		"key": "model", "type": "string", "label": "Summarization model", "value": "x",
	}, "_settings_tab_loading")
	var line := _first_lineedit(probe)
	_check(line != null, "string field rendered a LineEdit")
	if line != null:
		line.text = "typed-via-widget"
		line.text_submitted.emit("typed-via-widget")
		_check(store.get_value("core", "model") == "typed-via-widget", "widget edit persists through the store")

	singleton.plugin_settings_store = saved_store
	popup.free()
