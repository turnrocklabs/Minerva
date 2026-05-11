extends SceneTree
## Integration test for T7 cases 3 + 4: set_state mutates an open plugin-owned
## doc, host-owned save persists the change.
##
## Run: godot --headless --path src --script test/test_host_capability_documents_mutate.gd
##
## Tracks docket: minerva 019df8e3c9d57472a7d721785f5f783c (T7)
## Parent DCR:   minerva 019df8e2d0937613a326389a4df133fb
##
## What this exercises that test_host_capability_documents.gd doesn't:
##   - A real DocumentBuffer attached to a real PluginScenePanelBroker entry.
##   - A stub editor_pane wired into SingletonObject so _find_editor_by_name +
##     _resolve_editor_buffer reach the buffer through the canonical path.
##   - The full set_state happy-path: probe_set_state → CapabilityBroker
##     → _resolve_editor_buffer → DocumentBuffer.apply_edit + mark_dirty.
##   - host-owned save: DocumentBuffer.save_to_disk persists buffer text,
##     dirty clears, on-disk bytes match the mutation.
##
## NOTE: PluginManager + EditorPane reference SingletonObject at parse time.
## In --script mode autoloads register lazily — use deferred load() once
## autoloads are wired.

const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const EDITOR_PANE_SCRIPT_PATH    := "res://Scripts/UI/Views/EditorPane.gd"
const EDITOR_SCRIPT_PATH         := "res://Scripts/UI/Controls/Editor.gd"
const DOCUMENT_BUFFER_SCRIPT_PATH := "res://Scripts/Services/Documents/DocumentBuffer.gd"
const DISK_ACCESS_SCRIPT_PATH    := "res://Scripts/Services/Documents/DiskAccess.gd"

const FIXTURE_DIR_REL := "/test/fixtures/document_probe"

const PLUGIN_ID    := "document_probe"
const PANEL_NAME   := "probe_panel"
const TAB_TITLE    := "probe_doc"
const INITIAL_TEXT := "initial deck text\n"
const MUTATED_TEXT := "mutated by set_state\nline two\n"

const S_RUNNING := 2
const S_STOPPED := 3

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== host.documents.set_state Mutate Test (T7 cases 3+4) ===\n")
	await _run_tests()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_tests() -> void:
	var fixture_dir: String = ProjectSettings.globalize_path("res://" + FIXTURE_DIR_REL)
	var manifest_path: String = fixture_dir + "/manifest.json"
	var probe_script: String = fixture_dir + "/document_probe.py"

	if not FileAccess.file_exists(manifest_path):
		printerr("FAIL: fixture manifest not found at %s" % manifest_path)
		_fail_count += 1
		return
	if not FileAccess.file_exists(probe_script):
		printerr("FAIL: fixture script not found at %s" % probe_script)
		_fail_count += 1
		return

	var py_check := OS.execute("python3", ["--version"], [], true)
	if py_check != OK:
		print("SKIP: python3 not available — skipping fixture plugin tests")
		quit(0)
		return

	# Wait one frame for autoloads to register.
	await process_frame

	# Wait for SingletonObject.plugin_scene_panel_broker (≤10s).
	var so_node = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload exists", so_node != null)
	if so_node == null:
		return
	var deadline_ms: int = Time.get_ticks_msec() + 10000
	while so_node.get("plugin_scene_panel_broker") == null and Time.get_ticks_msec() < deadline_ms:
		await Engine.get_main_loop().create_timer(0.1).timeout
	var pbroker = so_node.get("plugin_scene_panel_broker")
	check("plugin_scene_panel_broker initialised", pbroker != null,
		"Waited %dms" % (Time.get_ticks_msec() - (deadline_ms - 10000)))
	if pbroker == null:
		return

	# Build temp file path. The buffer is "host-owned" in the sense that
	# save_to_disk() writes the canonical bytes through DiskAccess.
	var tmp_path: String = OS.get_user_data_dir().path_join(
		"test_set_state_mutate_%d.txt" % Time.get_ticks_msec())
	# Pre-clean any straggler.
	if FileAccess.file_exists(tmp_path):
		DirAccess.remove_absolute(tmp_path)

	# Construct the DocumentBuffer at the temp path. file_path must NOT be
	# DocumentRegistry.UNBACKED_PREFIX'd — we want host_owned_save to land
	# the change on disk.
	var DocumentBufferScript = load(DOCUMENT_BUFFER_SCRIPT_PATH)
	check("DocumentBuffer script loaded", DocumentBufferScript != null)
	if DocumentBufferScript == null:
		return
	var buffer = DocumentBufferScript.new(tmp_path, INITIAL_TEXT)
	check("buffer initialised", buffer != null and buffer.text == INITIAL_TEXT,
		"buffer.text=%s" % (buffer.text if buffer != null else "<null>"))

	# Register a stub panel root with the broker (real attach path).
	var panel_root := Node.new()
	root.add_child(panel_root)
	pbroker.register_panel(panel_root, PLUGIN_ID, PANEL_NAME, PackedStringArray())
	check("panel registered with broker",
		pbroker.is_panel_registered(PANEL_NAME),
		"panel '%s' not registered" % PANEL_NAME)

	# Attach the buffer to the panel.  This is what makes get_attached_buffer
	# return our buffer when CapabilityBroker._resolve_editor_buffer looks it
	# up for a PLUGIN_SCENE editor.
	var attached_ok: bool = pbroker.attach_buffer_to_panel(PLUGIN_ID, PANEL_NAME, buffer)
	check("buffer attached to panel", attached_ok)

	# Build the stub editor + editor_pane.  Both subclass the real types so
	# the typed SingletonObject.editor_pane var accepts the assignment.
	var stub_editor = _StubPluginEditor.new(TAB_TITLE, PLUGIN_ID, PANEL_NAME)
	var stub_pane = _StubEditorPane.new()
	stub_pane.set_editors([stub_editor])

	# Inject — and restore at the end so we don't poison cross-test state.
	var prior_editor_pane = so_node.get("editor_pane")
	so_node.set("editor_pane", stub_pane)
	check("editor_pane installed on SingletonObject",
		so_node.get("editor_pane") == stub_pane,
		"got: %s" % str(so_node.get("editor_pane")))

	# Spin up the PluginManager + document_probe fixture (mirrors
	# test_host_capability_documents.gd).
	var pm_script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	check("PluginManager script loaded", pm_script != null)
	if pm_script == null:
		return
	var pm = pm_script.new()
	root.add_child(pm)
	await process_frame
	check("PluginManager initialised", pm._db != null)
	if pm._db == null:
		return

	var db = pm._db
	var def = db.get_by_id(PLUGIN_ID)
	if def == null:
		var install_result = await pm.install_plugin(manifest_path, true)
		check("install_plugin (document_probe) ok",
			install_result.get("ok", false) == true,
			"got: %s" % str(install_result))
		def = db.get_by_id(PLUGIN_ID)
	check("document_probe definition loaded", def != null)
	if def == null:
		return

	if def.state == S_RUNNING:
		await pm.stop_plugin(PLUGIN_ID)

	# Grant the four host.documents.* capabilities (same as the read test).
	var policy = pm.get_policy()
	if policy == null:
		policy = so_node.get("plugin_policy") if "plugin_policy" in so_node else null
	check("plugin policy available", policy != null)
	if policy != null:
		policy.grant_capability(PLUGIN_ID, "host.documents.list_open")
		policy.grant_capability(PLUGIN_ID, "host.documents.get_state")
		policy.grant_capability(PLUGIN_ID, "host.documents.set_state")
		policy.grant_capability(PLUGIN_ID, "host.documents.mark_dirty")

	var start_result = await pm.start_plugin(PLUGIN_ID)
	check("start_plugin (document_probe) ok",
		start_result.get("ok", false) == true,
		"got: %s" % str(start_result))
	check("state == RUNNING", def.state == S_RUNNING,
		"state=%d" % def.state)

	var conn = pm.get_connection(PLUGIN_ID)
	check("connection exists", conn != null)
	if conn == null:
		await _teardown(so_node, prior_editor_pane, pm, panel_root, pbroker)
		return

	# Sanity: list_open from the plugin now sees one document (our stub).
	print("\n-- Sanity: list_open sees the stub editor --")
	var initial_version: int = buffer.version
	var initial_dirty: bool = buffer.dirty
	var list_call = await conn.call_tool("probe_list", {})
	check("probe_list returned a Dictionary", list_call is Dictionary)
	if list_call is Dictionary and list_call.get("documents") is Array:
		var docs: Array = list_call["documents"]
		var found: bool = false
		for d in docs:
			if d is Dictionary and str(d.get("editor_name", "")) == TAB_TITLE:
				found = true
				check("list_open entry has kind=plugin_scene",
					str(d.get("kind", "")) == "plugin_scene",
					"got kind=%s" % str(d.get("kind")))
				check("list_open entry has plugin_id=document_probe",
					str(d.get("plugin_id", "")) == PLUGIN_ID,
					"got plugin_id=%s" % str(d.get("plugin_id")))
				break
		check("list_open found stub editor by tab_title", found,
			"documents=%s" % str(docs))

	# ---------------------------------------------------------------------
	# CASE 3 — set_state mutates the canonical DocumentBuffer.
	# ---------------------------------------------------------------------
	print("\n-- Case 3: probe_set_state mutates buffer --")
	var ss_call = await conn.call_tool("probe_set_state", {
		"editor_name": TAB_TITLE,
		"buffer_text": MUTATED_TEXT,
	})
	check("probe_set_state returned a Dictionary", ss_call is Dictionary,
		"got type %d" % typeof(ss_call))
	if ss_call is Dictionary:
		check("probe_set_state was not denied",
			ss_call.get("was_denied", true) == false,
			"got: %s" % str(ss_call))
		check("probe_set_state reports dirty=true",
			ss_call.get("dirty", false) == true,
			"got: %s" % str(ss_call))
		var version_raw: Variant = ss_call.get("version")
		check("probe_set_state reports version bumped",
			version_raw != null and int(version_raw) > initial_version,
			"initial_version=%d, got version=%s" % [initial_version, str(version_raw)])
		check("probe_set_state kind=plugin_scene",
			str(ss_call.get("kind", "")) == "plugin_scene",
			"got kind=%s" % str(ss_call.get("kind")))

	# Buffer state observed directly (the canonical truth).
	check("buffer.text equals mutated text",
		buffer.text == MUTATED_TEXT,
		"buffer.text len=%d initial-buffer-was-dirty=%s" % [buffer.text.length(), str(initial_dirty)])
	check("buffer.dirty == true after set_state",
		buffer.dirty == true)
	check("buffer.version > initial_version",
		buffer.version > initial_version,
		"version=%d initial_version=%d" % [buffer.version, initial_version])

	# get_state on the just-mutated editor returns the new buffer_text — proves
	# the round-trip is consistent from the plugin's POV.
	print("\n-- Case 3b: probe_state returns mutated buffer_text --")
	var gs_call = await conn.call_tool("probe_state", {"editor_name": TAB_TITLE})
	check("probe_state returned a Dictionary", gs_call is Dictionary)
	if gs_call is Dictionary:
		check("probe_state was not denied",
			gs_call.get("was_denied", true) == false,
			"got: %s" % str(gs_call))
		check("probe_state buffer_text matches mutation",
			str(gs_call.get("buffer_text", "")) == MUTATED_TEXT,
			"got: %s" % str(gs_call.get("buffer_text")))
		check("probe_state buffer_canonical=true",
			gs_call.get("buffer_canonical", false) == true,
			"got: %s" % str(gs_call.get("buffer_canonical")))

	# ---------------------------------------------------------------------
	# CASE 4 — host-owned save persists the change to disk and clears dirty.
	# ---------------------------------------------------------------------
	print("\n-- Case 4: host-owned save persists mutation to disk --")
	var save_result: Dictionary = buffer.save_to_disk()
	check("buffer.save_to_disk returned ok",
		save_result.get("ok", false) == true,
		"got: %s" % str(save_result))
	check("buffer.dirty == false after save",
		buffer.dirty == false,
		"buffer.dirty=%s" % str(buffer.dirty))

	# Read disk via FileAccess (the canonical persistence check — bypasses any
	# caching DiskAccess might have).
	var disk_text: String = ""
	if FileAccess.file_exists(tmp_path):
		var f := FileAccess.open(tmp_path, FileAccess.READ)
		if f != null:
			disk_text = f.get_as_text()
			f.close()
	check("disk bytes match mutated text",
		disk_text == MUTATED_TEXT,
		"disk_text len=%d expected len=%d" % [disk_text.length(), MUTATED_TEXT.length()])

	# Second set_state (re-write same content) — still marks dirty per the
	# CapabilityBroker contract.  This is a regression guard for the
	# "always mark dirty regardless of equality" rule at CapabilityBroker.gd:606.
	print("\n-- Regression guard: set_state with identical text still marks dirty --")
	var ss_same = await conn.call_tool("probe_set_state", {
		"editor_name": TAB_TITLE,
		"buffer_text": MUTATED_TEXT,
	})
	if ss_same is Dictionary:
		check("probe_set_state (same text) was not denied",
			ss_same.get("was_denied", true) == false,
			"got: %s" % str(ss_same))
		check("probe_set_state (same text) reports dirty=true",
			ss_same.get("dirty", false) == true,
			"got: %s" % str(ss_same))
	check("buffer.dirty == true after redundant set_state",
		buffer.dirty == true,
		"buffer.dirty=%s" % str(buffer.dirty))

	# Cleanup.
	await _teardown(so_node, prior_editor_pane, pm, panel_root, pbroker)
	if FileAccess.file_exists(tmp_path):
		DirAccess.remove_absolute(tmp_path)


func _teardown(so_node, prior_editor_pane, pm, panel_root, pbroker) -> void:
	print("\n-- Teardown --")
	if pm != null:
		await pm.stop_plugin(PLUGIN_ID)
	# Detach + unregister the panel.
	if pbroker != null:
		pbroker.detach_buffer_from_panel(PLUGIN_ID, PANEL_NAME)
		pbroker.unregister_panel(PLUGIN_ID, PANEL_NAME)
	if panel_root != null and is_instance_valid(panel_root):
		panel_root.queue_free()
	# Restore prior editor_pane (typically null in headless).
	if so_node != null:
		so_node.set("editor_pane", prior_editor_pane)


# ---------------------------------------------------------------------------
# Stubs
#
# Both subclass the real types so the typed SingletonObject.editor_pane var
# (declared `editor_pane: EditorPane`) and the typed Array[Editor] returned by
# get_open_editors() accept the values.  Neither is added to the scene tree,
# so neither's _ready (and @onready vars) ever fire — the stubs only carry
# the duck-typed fields CapabilityBroker reads.
# ---------------------------------------------------------------------------

# Editor.Type.PLUGIN_SCENE = 14 (see Editor.gd:105 enum).
# Hardcoded rather than referenced because Editor.gd's `tab_title` setter
# null-derefs SingletonObject.editor_pane.Tabs in headless — subclassing
# Editor would invoke that setter at construction time.
const _PLUGIN_SCENE_TYPE := 14


class _StubPluginEditor:
	var tab_title: String
	var type: int = _PLUGIN_SCENE_TYPE
	var plugin_id: String
	var panel_name: String
	var file: String = ""

	func _init(p_tab_title: String, p_plugin_id: String, p_panel_name: String) -> void:
		tab_title = p_tab_title
		plugin_id = p_plugin_id
		panel_name = p_panel_name


# Subclasses EditorPane so the typed `editor_pane: EditorPane` var on
# SingletonObject accepts the assignment. Not added to the scene tree, so
# _ready (and @onready vars like Tabs) never fire — we only use the
# `get_open_editors` override below.
class _StubEditorPane extends "res://Scripts/UI/Views/EditorPane.gd":
	var _stub_editors: Array = []

	func set_editors(p_editors: Array) -> void:
		_stub_editors = p_editors

	# Override the typed Array[Editor] return with Array — the duck-typed
	# stubs above are not Editor subclasses, and CapabilityBroker only reads
	# duck-typed fields (tab_title, type, plugin_id, panel_name, file).
	@warning_ignore("native_method_override")
	func get_open_editors() -> Array:
		return _stub_editors


func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		var msg := "  FAIL: %s" % description
		if not detail.is_empty():
			msg += " | %s" % detail
		printerr(msg)
