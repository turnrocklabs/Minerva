extends SceneTree
## Scansort plugin extract/render tool integration test — T6 R2.
##
## Run: godot --headless --path src --script test/test_scansort_extract.gd
##
## Tracks docket: minerva 019e1cdb451076ae8c344f6e6ec605e1 (scansort plugin DCR)
## Round:         T6 R2 — extract.rs + render.rs port + 2 new MCP tools
##
## Goal: exercise minerva_scansort_extract_text and minerva_scansort_render_pages
##       against a real vault-free Rust binary. No stubs. Verifies:
##         1. Plain text extraction (sha256, file_type, full_text, page_count, char_count)
##         2. JSON file extraction (file_type == "text")
##         3. PNG image extraction (file_type == "image", dhash, char_count == 0)
##         4. Missing file → success: false + error
##         5. Empty file → success: true, char_count == 0
##         6. PDF extraction (from fixture sample.pdf — file_type "pdf", page_count >= 1)
##         7. render_pages on PDF fixture → success: true, pages non-empty, base64 non-empty
##         8. render_pages with missing file → success: false
##         9. render_pages on non-PDF text file → success: false (unsupported type)
##        10. render_pages max_pages=1 → only 1 page returned

const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"

const SCANSORT_PLUGIN_DIR_REL := "/github/plugins/scansort"
const SCANSORT_BINARY_REL := "/scansort-plugin"
const SCANSORT_MANIFEST_REL := "/manifest.json"

const S_RUNNING := 2
const S_STOPPED := 3

## Absolute path to the PDF fixture shipped with the test suite.
const PDF_FIXTURE_RES := "res://test/fixtures/scansort/sample.pdf"

## text content for test 1 (must match sha256 below exactly, including newline)
const TXT_CONTENT := "Hello scansort\nLine 2\n"
## sha256("Hello scansort\nLine 2\n") — verified with sha256sum
const TXT_SHA256 := "3c94b56a1e05776f46ed0f770bb0c9e8eb16e91fbd3649cce1d90f0fa210b9a3"

## sha256 of fixture/scansort/sample.pdf — verified with sha256sum
const PDF_SHA256 := "ad1b4934acfbb5c8ff34522a3568b965f9955063457ecd33a18328be1f7cb071"

var _pass_count: int = 0
var _fail_count: int = 0
var _run_id: String = ""


func _init() -> void:
	_run_id = str(Time.get_ticks_usec())
	print("=== Scansort Extract/Render Integration Test (T6 R2) ===\n")
	print("Run ID: %s\n" % _run_id)
	print("Purpose: extract_text + render_pages via real Rust binary.\n")

	var home: String = OS.get_environment("HOME")
	if home == "":
		printerr("FAIL: $HOME is unset — can't locate plugin source dir.")
		quit(1)
		return

	var plugin_dir: String = home + SCANSORT_PLUGIN_DIR_REL
	var binary_path: String = plugin_dir + SCANSORT_BINARY_REL
	var manifest_path: String = plugin_dir + SCANSORT_MANIFEST_REL

	if not FileAccess.file_exists(binary_path):
		print("SKIP: scansort-plugin binary not built at %s" % binary_path)
		print("      Build with: cd %s && cargo build --release && cp target/release/scansort-plugin ." % plugin_dir)
		quit(0)
		return

	if not FileAccess.file_exists(manifest_path):
		printerr("FAIL: scansort manifest not found at %s" % manifest_path)
		quit(1)
		return

	print("Scansort plugin source: %s" % plugin_dir)
	print("Scansort binary:        %s\n" % binary_path)

	await _run_test(manifest_path)

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_test(manifest_path: String) -> void:
	await process_frame

	# Wait for SingletonObject.plugin_tool_registry to be non-null.
	var so_node_init = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if so_node_init != null:
		var deadline_ms: int = Time.get_ticks_msec() + 10000
		while so_node_init.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline_ms:
			await Engine.get_main_loop().create_timer(0.1).timeout

	var pm_script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	if pm_script == null:
		printerr("FAIL: could not load PluginManager.gd")
		_fail_count += 1
		return

	var pm = pm_script.new()
	root.add_child(pm)
	await process_frame

	check("PluginManager initialised", pm._db != null)
	if pm._db == null:
		return

	var db = pm._db
	var def = db.get_by_id("scansort")

	if def == null:
		print("Scansort not in PluginDB — installing from manifest...")
		var install_result = await pm.install_plugin(manifest_path, true)
		check("install_plugin returns ok", install_result.get("ok", false) == true,
			"got: %s" % str(install_result))
		def = db.get_by_id("scansort")

	check("Scansort definition loaded into DB", def != null)
	if def == null:
		return

	# Ensure plugin is not already RUNNING.
	if def.state == S_RUNNING:
		print("Plugin already RUNNING — stopping first for clean baseline.")
		await pm.stop_plugin("scansort")

	# Clean policy.json to avoid stale capability grants.
	var policy_path: String = ProjectSettings.globalize_path("user://plugins/policy.json")
	if FileAccess.file_exists(policy_path):
		print("Pre-clean: removing stale policy.json")
		DirAccess.remove_absolute(policy_path)

	# --- START ---
	print("\n-- start_plugin --")
	var start_result = await pm.start_plugin("scansort")
	check("start_plugin returns ok",
		start_result.get("ok", false) == true,
		"got: %s" % str(start_result))
	check("plugin state == RUNNING", def.state == S_RUNNING,
		"got state=%d (expected %d)" % [def.state, S_RUNNING])

	var conn = pm.get_connection("scansort")
	check("connection exists post-start", conn != null)
	if conn == null:
		return

	# --- PREPARE TEMP DIR ---
	var scope_dir: String = ProjectSettings.globalize_path("user://plugins/data/scansort/test")
	DirAccess.make_dir_recursive_absolute(scope_dir)

	var txt_abs: String = scope_dir.path_join("r2_txt_%s.txt" % _run_id)
	var json_abs: String = scope_dir.path_join("r2_json_%s.json" % _run_id)
	var png_abs: String = scope_dir.path_join("r2_img_%s.png" % _run_id)
	var empty_abs: String = scope_dir.path_join("r2_empty_%s.txt" % _run_id)
	var nonexist_abs: String = scope_dir.path_join("r2_nonexist_%s.txt" % _run_id)
	var pdf_abs: String = ProjectSettings.globalize_path(PDF_FIXTURE_RES)

	# Pre-clean stale files.
	_clean_stale_files(scope_dir, "r2_")

	# Write text fixture.
	var fw := FileAccess.open(txt_abs, FileAccess.WRITE)
	check("can create text fixture", fw != null)
	if fw != null:
		fw.store_string(TXT_CONTENT)
		fw.close()

	# Write JSON fixture.
	var jw := FileAccess.open(json_abs, FileAccess.WRITE)
	if jw != null:
		jw.store_string('{"hello": "world", "count": 42}')
		jw.close()

	# Write PNG fixture (16x16 solid red).
	var img := Image.create(16, 16, false, Image.FORMAT_RGB8)
	img.fill(Color(1, 0, 0))
	img.save_png(png_abs)
	check("PNG fixture written", FileAccess.file_exists(png_abs))

	# Write empty file.
	var ew := FileAccess.open(empty_abs, FileAccess.WRITE)
	if ew != null:
		ew.close()

	# --- TEST 1: plain text extraction ---
	print("\n-- test 1: extract_text — plain text file --")
	var t1: Dictionary = await conn.call_tool(
		"minerva_scansort_extract_text",
		{"file_path": txt_abs}
	)
	check("t1: returns Dictionary", t1 is Dictionary, "got type %d" % typeof(t1))
	check("t1: success == true",
		t1.get("success", false) == true,
		"got: %s" % str(t1))
	check("t1: file_type == 'text'",
		t1.get("file_type", "") == "text",
		"got file_type='%s'" % str(t1.get("file_type", "")))
	check("t1: full_text contains 'Hello scansort'",
		(t1.get("full_text", "") as String).contains("Hello scansort"),
		"got full_text='%s'" % str(t1.get("full_text", "")))
	check("t1: sha256 matches known value",
		t1.get("sha256", "") == TXT_SHA256,
		"got sha256='%s'" % str(t1.get("sha256", "")))
	check("t1: page_count == 1",
		int(t1.get("page_count", 0)) == 1,
		"got page_count=%s" % str(t1.get("page_count", "")))
	check("t1: char_count > 0",
		int(t1.get("char_count", 0)) > 0,
		"got char_count=%s" % str(t1.get("char_count", 0)))
	check("t1: simhash is a string",
		t1.get("simhash", "") is String,
		"got simhash type %d" % typeof(t1.get("simhash", "")))

	# --- TEST 2: JSON file extraction ---
	print("\n-- test 2: extract_text — JSON file (file_type == text) --")
	var t2: Dictionary = await conn.call_tool(
		"minerva_scansort_extract_text",
		{"file_path": json_abs}
	)
	check("t2: returns Dictionary", t2 is Dictionary, "got type %d" % typeof(t2))
	check("t2: success == true",
		t2.get("success", false) == true,
		"got: %s" % str(t2))
	check("t2: file_type == 'text'",
		t2.get("file_type", "") == "text",
		"got file_type='%s'" % str(t2.get("file_type", "")))
	check("t2: sha256 non-empty",
		not (t2.get("sha256", "") as String).is_empty(),
		"got sha256='%s'" % str(t2.get("sha256", "")))

	# --- TEST 3: PNG image extraction ---
	print("\n-- test 3: extract_text — PNG image --")
	var t3: Dictionary = await conn.call_tool(
		"minerva_scansort_extract_text",
		{"file_path": png_abs}
	)
	check("t3: returns Dictionary", t3 is Dictionary, "got type %d" % typeof(t3))
	check("t3: success == true",
		t3.get("success", false) == true,
		"got: %s" % str(t3))
	check("t3: file_type == 'image'",
		t3.get("file_type", "") == "image",
		"got file_type='%s'" % str(t3.get("file_type", "")))
	check("t3: char_count == 0",
		int(t3.get("char_count", -1)) == 0,
		"got char_count=%s" % str(t3.get("char_count", "")))
	check("t3: page_count == 1",
		int(t3.get("page_count", 0)) == 1,
		"got page_count=%s" % str(t3.get("page_count", "")))
	check("t3: dhash is 16-char hex string",
		(t3.get("dhash", "") as String).length() == 16,
		"got dhash='%s'" % str(t3.get("dhash", "")))
	check("t3: sha256 non-empty",
		not (t3.get("sha256", "") as String).is_empty(),
		"got sha256='%s'" % str(t3.get("sha256", "")))

	# --- TEST 4: missing file → error ---
	print("\n-- test 4: extract_text — missing file --")
	var t4: Dictionary = await conn.call_tool(
		"minerva_scansort_extract_text",
		{"file_path": nonexist_abs}
	)
	check("t4: returns Dictionary", t4 is Dictionary, "got type %d" % typeof(t4))
	check("t4: success == false",
		t4.get("success", true) == false,
		"got: %s" % str(t4))
	check("t4: error field present",
		t4.has("error") and not (t4.get("error", "") as String).is_empty(),
		"got: %s" % str(t4))
	check("t4: error mentions 'not found'",
		(t4.get("error", "") as String).to_lower().contains("not found"),
		"got error='%s'" % str(t4.get("error", "")))

	# --- TEST 5: empty file ---
	print("\n-- test 5: extract_text — empty file --")
	var t5: Dictionary = await conn.call_tool(
		"minerva_scansort_extract_text",
		{"file_path": empty_abs}
	)
	check("t5: returns Dictionary", t5 is Dictionary, "got type %d" % typeof(t5))
	# Empty file: success with 0 chars (text type, zero bytes is valid UTF-8)
	check("t5: success == true (empty is valid)",
		t5.get("success", false) == true,
		"got: %s" % str(t5))
	check("t5: char_count == 0",
		int(t5.get("char_count", -1)) == 0,
		"got char_count=%s" % str(t5.get("char_count", "")))

	# --- TEST 6: PDF extraction from fixture ---
	print("\n-- test 6: extract_text — PDF fixture --")
	check("PDF fixture exists at globalized path", FileAccess.file_exists(pdf_abs),
		"path=%s" % pdf_abs)
	if FileAccess.file_exists(pdf_abs):
		var t6: Dictionary = await conn.call_tool(
			"minerva_scansort_extract_text",
			{"file_path": pdf_abs}
		)
		check("t6: returns Dictionary", t6 is Dictionary, "got type %d" % typeof(t6))
		check("t6: success == true",
			t6.get("success", false) == true,
			"got: %s" % str(t6))
		check("t6: file_type == 'pdf'",
			t6.get("file_type", "") == "pdf",
			"got file_type='%s'" % str(t6.get("file_type", "")))
		check("t6: page_count >= 1",
			int(t6.get("page_count", 0)) >= 1,
			"got page_count=%s" % str(t6.get("page_count", "")))
		check("t6: sha256 matches fixture",
			t6.get("sha256", "") == PDF_SHA256,
			"got sha256='%s'" % str(t6.get("sha256", "")))
		check("t6: full_text contains 'Scansort'",
			(t6.get("full_text", "") as String).contains("Scansort"),
			"got full_text='%s'" % str((t6.get("full_text", "") as String).left(80)))
	else:
		# Skip PDF sub-checks if fixture is missing (shouldn't happen)
		print("  SKIP: PDF fixture not found at %s" % pdf_abs)

	# --- TEST 7: render_pages on PDF fixture ---
	print("\n-- test 7: render_pages — PDF fixture --")
	if FileAccess.file_exists(pdf_abs):
		var t7: Dictionary = await conn.call_tool(
			"minerva_scansort_render_pages",
			{"file_path": pdf_abs, "max_pages": 2, "dpi": 72}
		)
		check("t7: returns Dictionary", t7 is Dictionary, "got type %d" % typeof(t7))
		check("t7: success == true",
			t7.get("success", false) == true,
			"got: %s" % str(t7))
		var pages7 = t7.get("pages", [])
		check("t7: pages is Array", pages7 is Array, "got type %d" % typeof(pages7))
		check("t7: pages non-empty",
			(pages7 as Array).size() >= 1,
			"got pages.size()=%d" % (pages7 as Array).size())
		check("t7: page_count >= 1",
			int(t7.get("page_count", 0)) >= 1,
			"got page_count=%s" % str(t7.get("page_count", "")))
		if (pages7 as Array).size() > 0:
			var p0: Dictionary = (pages7 as Array)[0]
			check("t7: pages[0] has page_num",
				p0.has("page_num"),
				"got keys: %s" % str(p0.keys()))
			check("t7: pages[0].page_num == 1",
				int(p0.get("page_num", -1)) == 1,
				"got page_num=%s" % str(p0.get("page_num", "")))
			var b64: String = p0.get("base64", "")
			check("t7: pages[0].base64 non-empty",
				b64.length() > 0,
				"got base64 length=%d" % b64.length())
			# PNG base64 starts with 'iVBOR' (base64 of \x89PNG)
			check("t7: pages[0].base64 looks like PNG",
				b64.begins_with("iVBOR"),
				"got base64 prefix='%s'" % b64.left(10))
	else:
		print("  SKIP: PDF fixture not found")

	# --- TEST 8: render_pages missing file ---
	print("\n-- test 8: render_pages — missing file --")
	var t8: Dictionary = await conn.call_tool(
		"minerva_scansort_render_pages",
		{"file_path": nonexist_abs}
	)
	check("t8: returns Dictionary", t8 is Dictionary, "got type %d" % typeof(t8))
	check("t8: success == false",
		t8.get("success", true) == false,
		"got: %s" % str(t8))

	# --- TEST 9: render_pages on text file (unsupported type) ---
	print("\n-- test 9: render_pages — text file (unsupported) --")
	var t9: Dictionary = await conn.call_tool(
		"minerva_scansort_render_pages",
		{"file_path": txt_abs}
	)
	check("t9: returns Dictionary", t9 is Dictionary, "got type %d" % typeof(t9))
	check("t9: success == false (unsupported type)",
		t9.get("success", true) == false,
		"got: %s" % str(t9))

	# --- TEST 10: render_pages max_pages=1 on PDF ---
	print("\n-- test 10: render_pages — max_pages=1 on PDF fixture --")
	if FileAccess.file_exists(pdf_abs):
		var t10: Dictionary = await conn.call_tool(
			"minerva_scansort_render_pages",
			{"file_path": pdf_abs, "max_pages": 1, "dpi": 72}
		)
		check("t10: success == true",
			t10.get("success", false) == true,
			"got: %s" % str(t10))
		var pages10 = t10.get("pages", [])
		check("t10: exactly 1 page returned",
			(pages10 as Array).size() == 1,
			"got pages.size()=%d" % (pages10 as Array).size())
	else:
		print("  SKIP: PDF fixture not found")

	# --- CLEANUP ---
	print("\n-- cleanup --")
	DirAccess.remove_absolute(txt_abs)
	DirAccess.remove_absolute(json_abs)
	DirAccess.remove_absolute(png_abs)
	DirAccess.remove_absolute(empty_abs)
	check("txt fixture cleaned up", not FileAccess.file_exists(txt_abs))

	# --- STOP ---
	print("\n-- stop_plugin --")
	var stop_result = await pm.stop_plugin("scansort")
	check("stop_plugin returns ok",
		stop_result.get("ok", false) == true,
		"got: %s" % str(stop_result))
	check("plugin state == STOPPED", def.state == S_STOPPED,
		"got state=%d (expected %d)" % [def.state, S_STOPPED])

	# Remove scansort from PluginDB to avoid cross-run pollution.
	db.remove("scansort")


func _clean_stale_files(scope_dir: String, prefix: String) -> void:
	var da := DirAccess.open(scope_dir)
	if da == null:
		return
	da.list_dir_begin()
	var fname: String = da.get_next()
	while fname != "":
		if fname.begins_with(prefix):
			DirAccess.remove_absolute(scope_dir.path_join(fname))
		fname = da.get_next()
	da.list_dir_end()


func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)
