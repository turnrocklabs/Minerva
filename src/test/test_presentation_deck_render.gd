extends SceneTree
## Per-plugin functional test (W5) — the presentation plugin opens the W2
## fixture deck and reports its slide/tile structure through real MCP tool
## calls on the REAL MCPServerConnection.
##
## Run: godot --headless --path src --script test/test_presentation_deck_render.gd
##
## Tracks docket: minerva RCA 019e46b5 / work-item W5 019e470b444f
##
## Presentation is currently functional, so this test must PASS on current
## code — it is a per-plugin regression guard (proves W1 does not break the
## presentation plugin), not a fail-first repro.
##
## NOTE: PluginManager.gd / MCPServerConnection.gd reference the SingletonObject
## autoload at parse time; in --script mode autoloads register lazily, so use a
## deferred load() rather than a top-level preload().

const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const PLUGIN_ID := "presentation"
const PLUGIN_DIR_REL := "/github/plugins/presentation"
const DECK_FIXTURE_REL := "/test/fixtures/presentation/test_deck.mdeck"

const S_RUNNING := 2
const S_STOPPED := 3

## Host capabilities the presentation manifest declares. Disk-mode list_slides /
## list_tiles read the file directly (os.ReadFile) and need none of these, but
## granting the declared set matches the known-good parity-test setup.
const HOST_CAPS := [
	"host.documents.list_open",
	"host.documents.get_state",
	"host.documents.set_state",
	"host.documents.get_node",
	"host.documents.get_blob",
	"host.documents.patch_state",
	"host.documents.put_blob",
	"host.editors.export",
	"host.editors.open",
]

## Expected structure of test_deck.mdeck (see the fixture README).
const EXPECTED_SLIDES := [
	{"id": "slide_fixture_0001", "title": "Test Slide One", "tiles": 2},
	{"id": "slide_fixture_0002", "title": "Test Slide Two", "tiles": 3},
	{"id": "slide_fixture_0003", "title": "Test Slide Three", "tiles": 2},
]
const EXPECTED_TOTAL_TILES := 7

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== Presentation Plugin Functional Test (W5) ===\n")
	print("Drives the real presentation plugin + MCPServerConnection — no stubs.\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	var home: String = OS.get_environment("HOME")
	if home == "":
		printerr("FAIL: $HOME unset — cannot locate the plugin source dir.")
		_fail += 1
		return
	var manifest_path: String = home + PLUGIN_DIR_REL + "/manifest.json"
	if not FileAccess.file_exists(manifest_path):
		print("SKIP: presentation plugin manifest not found at %s" % manifest_path)
		quit(0)
		return

	var deck_path: String = ProjectSettings.globalize_path("res://" + DECK_FIXTURE_REL)
	if not FileAccess.file_exists(deck_path):
		printerr("FAIL: deck fixture not found at %s" % deck_path)
		_fail += 1
		return

	print("Manifest: %s" % manifest_path)
	print("Deck fixture: %s\n" % deck_path)

	# Wait for autoloads, then for the scene-panel broker to be wired (the
	# presentation plugin declares panels; mirror the parity-test readiness wait).
	await process_frame
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload exists", so != null)
	if so == null:
		return
	var deadline_ms: int = Time.get_ticks_msec() + 10000
	while so.get("plugin_scene_panel_broker") == null and Time.get_ticks_msec() < deadline_ms:
		await Engine.get_main_loop().create_timer(0.1).timeout

	var pm_script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	if pm_script == null:
		printerr("FAIL: could not load PluginManager.gd")
		_fail += 1
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
		print("Presentation not in PluginDB — installing from manifest...")
		var install_result = await pm.install_plugin(manifest_path, true)
		check("install_plugin returns ok", install_result.get("ok", false) == true,
				"got: %s" % str(install_result))
		def = db.get_by_id(PLUGIN_ID)
	check("presentation definition loaded into DB", def != null)
	if def == null:
		return

	if def.state == S_RUNNING:
		print("Plugin already RUNNING — stopping first for a clean baseline.")
		await pm.stop_plugin(PLUGIN_ID)

	# Grant the declared host capabilities.
	var policy = pm.get_policy()
	if policy == null and "plugin_policy" in so:
		policy = so.get("plugin_policy")
	if policy != null:
		for cap in HOST_CAPS:
			policy.grant_capability(PLUGIN_ID, cap)

	print("\n-- start_plugin --")
	var start_result = await pm.start_plugin(PLUGIN_ID)
	check("start_plugin returns ok", start_result.get("ok", false) == true,
			"got: %s" % str(start_result))
	check("plugin state == RUNNING", def.state == S_RUNNING,
			"got state=%d" % def.state)

	var conn = pm.get_connection(PLUGIN_ID)
	check("connection exists post-start", conn != null)
	if conn != null:
		await _test_list_slides(conn, deck_path)
		await _test_list_tiles(conn, deck_path)

	print("\n-- stop_plugin --")
	var stop_result = await pm.stop_plugin(PLUGIN_ID)
	check("stop_plugin returns ok", stop_result.get("ok", false) == true,
			"got: %s" % str(stop_result))


## list_slides (disk mode) must report the fixture's 3 slides with correct
## ids, titles and per-slide tile counts.
func _test_list_slides(conn, deck_path: String) -> void:
	print("\n-- list_slides: fixture deck structure --")
	var ls = await conn.call_tool("minerva_presentation_list_slides", {"path": deck_path})
	check("list_slides returned a Dictionary", ls is Dictionary,
			"got type %d" % typeof(ls))
	check("list_slides reported success", ls is Dictionary and ls.get("success", false) == true,
			"got: %s" % str(ls).left(200))
	var slides = ls.get("slides", []) if ls is Dictionary else []
	check("list_slides reports exactly 3 slides",
			slides is Array and slides.size() == EXPECTED_SLIDES.size(),
			"got %d" % (slides.size() if slides is Array else -1))
	if not (slides is Array) or slides.size() != EXPECTED_SLIDES.size():
		return
	for i in range(EXPECTED_SLIDES.size()):
		var s = slides[i]
		var expected = EXPECTED_SLIDES[i]
		check("slide %d id == %s" % [i, expected["id"]],
				s is Dictionary and str(s.get("id", "")) == expected["id"],
				"got %s" % str(s.get("id", "") if s is Dictionary else s))
		check("slide %d title == '%s'" % [i, expected["title"]],
				s is Dictionary and str(s.get("title", "")) == expected["title"],
				"got %s" % str(s.get("title", "") if s is Dictionary else s))
		check("slide %d tile_count == %d" % [i, expected["tiles"]],
				s is Dictionary and int(s.get("tile_count", -1)) == expected["tiles"],
				"got %s" % str(s.get("tile_count", "?") if s is Dictionary else s))


## list_tiles (disk mode) per slide must agree with the expected counts and
## report only text tiles; total tiles across the deck must be 7.
func _test_list_tiles(conn, deck_path: String) -> void:
	print("\n-- list_tiles: per-slide tiles --")
	var total_tiles: int = 0
	for i in range(EXPECTED_SLIDES.size()):
		var lt = await conn.call_tool("minerva_presentation_list_tiles",
				{"path": deck_path, "slide_index": i})
		check("list_tiles[%d] reported success" % i,
				lt is Dictionary and lt.get("success", false) == true,
				"got: %s" % str(lt).left(200))
		var tiles = lt.get("tiles", []) if lt is Dictionary else []
		var n: int = tiles.size() if tiles is Array else 0
		total_tiles += n
		check("slide %d has %d tiles" % [i, EXPECTED_SLIDES[i]["tiles"]],
				n == EXPECTED_SLIDES[i]["tiles"], "got %d" % n)
		var all_text: bool = true
		if tiles is Array:
			for t in tiles:
				if not (t is Dictionary and str(t.get("kind", "")) == "text"):
					all_text = false
		check("slide %d tiles are all kind=text" % i, all_text)
	check("deck has %d tiles total" % EXPECTED_TOTAL_TILES,
			total_tiles == EXPECTED_TOTAL_TILES, "got %d" % total_tiles)


func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % description)
	else:
		_fail += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)
