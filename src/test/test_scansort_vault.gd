extends SceneTree
## Scansort plugin vault tool integration test — T5 R1.
##
## Run: godot --headless --path src --script test/test_scansort_vault.gd
##
## Tracks docket: minerva 019e1cdb451076ae8c344f6e6ec605e1 (scansort plugin DCR)
## Round:         T5 R1 — vault file format + crypto + password layer
##
## Goal: exercise the 6 new MCP tools against a real vault file using the
##       actual Rust binary. No stubs. Verifies:
##         1. vault creation
##         2. password set + verify (correct + wrong)
##         3. check_vault_has_password
##         4. open_vault returns correct metadata
##         5. update_project_key persists across open_vault calls

const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"

const SCANSORT_PLUGIN_DIR_REL := "/github/plugins/scansort"
const SCANSORT_BINARY_REL := "/scansort-plugin"
const SCANSORT_MANIFEST_REL := "/manifest.json"

const S_RUNNING := 2
const S_STOPPED := 3

## Path inside the auto-granted plugin data scope.
const VAULT_SCOPE_REL := "user://plugins/data/scansort/test"
const VAULT_FILENAME := "r1_vault.ssort"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Scansort Vault Tool Integration Test (T5 R1) ===\n")
	print("Purpose: vault create/open/password/project-key via real Rust binary.\n")

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
	# Wait one frame so autoloads (SingletonObject) have a chance to register.
	await process_frame

	# Wait for SingletonObject.initialize_plugins() to complete.
	var so_node_init = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if so_node_init != null:
		var deadline_ms: int = Time.get_ticks_msec() + 10000
		while so_node_init.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline_ms:
			await Engine.get_main_loop().create_timer(0.1).timeout
		var ready_at: int = Time.get_ticks_msec()
		print("SingletonObject.plugin_tool_registry available after %dms" % (ready_at - (deadline_ms - 10000)))

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

	# Ensure plugin is not already RUNNING (stale state from prior run).
	if def.state == S_RUNNING:
		print("Plugin already RUNNING — stopping first for clean baseline.")
		await pm.stop_plugin("scansort")

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

	# --- PREPARE VAULT PATH ---
	# Ensure the test directory exists inside the auto-granted scope.
	var scope_dir: String = ProjectSettings.globalize_path(VAULT_SCOPE_REL)
	DirAccess.make_dir_recursive_absolute(scope_dir)
	var vault_abs: String = scope_dir.path_join(VAULT_FILENAME)
	print("\nVault path: %s" % vault_abs)

	# Pre-clean: delete any vault left from a prior run.
	if FileAccess.file_exists(vault_abs):
		print("Pre-clean: removing stale vault file from prior run.")
		DirAccess.remove_absolute(vault_abs)
		# WAL and SHM sidecar files
		DirAccess.remove_absolute(vault_abs + "-wal")
		DirAccess.remove_absolute(vault_abs + "-shm")

	# --- 1. CREATE VAULT ---
	print("\n-- minerva_scansort_create_vault --")
	var create_result: Dictionary = await conn.call_tool(
		"minerva_scansort_create_vault",
		{"path": vault_abs, "name": "R1 Test Vault"}
	)
	check("create_vault returned Dictionary", create_result is Dictionary,
		"got type %d" % typeof(create_result))
	check("create_vault ok == true",
		create_result.get("ok", false) == true,
		"got: %s" % str(create_result))
	check("vault file exists after create",
		FileAccess.file_exists(vault_abs))

	# --- 2. SET PASSWORD ---
	print("\n-- minerva_scansort_set_password --")
	var set_pw_result: Dictionary = await conn.call_tool(
		"minerva_scansort_set_password",
		{"path": vault_abs, "password": "hunter2-test"}
	)
	check("set_password returned Dictionary", set_pw_result is Dictionary,
		"got type %d" % typeof(set_pw_result))
	check("set_password ok == true",
		set_pw_result.get("ok", false) == true,
		"got: %s" % str(set_pw_result))

	# --- 3. CHECK VAULT HAS PASSWORD ---
	print("\n-- minerva_scansort_check_vault_has_password --")
	var has_pw_result: Dictionary = await conn.call_tool(
		"minerva_scansort_check_vault_has_password",
		{"path": vault_abs}
	)
	check("check_vault_has_password returned Dictionary", has_pw_result is Dictionary,
		"got type %d" % typeof(has_pw_result))
	check("check_vault_has_password has_password == true",
		has_pw_result.get("has_password", false) == true,
		"got: %s" % str(has_pw_result))

	# --- 4. VERIFY PASSWORD (correct) ---
	print("\n-- minerva_scansort_verify_password (correct) --")
	var verify_ok: Dictionary = await conn.call_tool(
		"minerva_scansort_verify_password",
		{"path": vault_abs, "password": "hunter2-test"}
	)
	check("verify_password (correct) returned Dictionary", verify_ok is Dictionary,
		"got type %d" % typeof(verify_ok))
	# Transport ok = call dispatched cleanly; verified = semantic match result.
	check("verify_password (correct) ok == true (transport)",
		verify_ok.get("ok", false) == true,
		"got: %s" % str(verify_ok))
	check("verify_password (correct) verified == true (semantic)",
		verify_ok.get("verified", false) == true,
		"got: %s" % str(verify_ok))

	# --- 5. VERIFY PASSWORD (wrong) — must return ok:true verified:false, NOT an error ---
	print("\n-- minerva_scansort_verify_password (wrong) --")
	var verify_wrong: Dictionary = await conn.call_tool(
		"minerva_scansort_verify_password",
		{"path": vault_abs, "password": "wrong-password"}
	)
	check("verify_password (wrong) returned Dictionary", verify_wrong is Dictionary,
		"got type %d" % typeof(verify_wrong))
	# Mismatch is a valid dispatch result; ok stays true, verified is false.
	check("verify_password (wrong) ok == true (transport still succeeded)",
		verify_wrong.get("ok", false) == true,
		"got: %s" % str(verify_wrong))
	check("verify_password (wrong) verified == false (semantic mismatch)",
		verify_wrong.get("verified", true) == false,
		"got: %s" % str(verify_wrong))
	check("verify_password (wrong) has no 'error' field",
		not verify_wrong.has("error"),
		"got error field: %s" % str(verify_wrong.get("error", "")))

	# --- 6. OPEN VAULT (first time) ---
	print("\n-- minerva_scansort_open_vault (initial) --")
	var open_result: Dictionary = await conn.call_tool(
		"minerva_scansort_open_vault",
		{"path": vault_abs}
	)
	check("open_vault returned Dictionary", open_result is Dictionary,
		"got type %d" % typeof(open_result))
	check("open_vault ok == true",
		open_result.get("ok", false) == true,
		"got: %s" % str(open_result))
	var info: Dictionary = open_result.get("info", {})
	check("open_vault info is Dictionary", info is Dictionary,
		"got type %d" % typeof(info))
	check("open_vault info.name == 'R1 Test Vault'",
		info.get("name", "") == "R1 Test Vault",
		"got name: '%s'" % str(info.get("name", "")))

	# --- 7. UPDATE PROJECT KEY ---
	print("\n-- minerva_scansort_update_project_key --")
	var update_result: Dictionary = await conn.call_tool(
		"minerva_scansort_update_project_key",
		{"path": vault_abs, "key": "emergency_contact_name", "value": "Imran"}
	)
	check("update_project_key returned Dictionary", update_result is Dictionary,
		"got type %d" % typeof(update_result))
	check("update_project_key ok == true",
		update_result.get("ok", false) == true,
		"got: %s" % str(update_result))

	# --- 8. OPEN VAULT AGAIN — verify persisted key ---
	print("\n-- minerva_scansort_open_vault (after update_project_key) --")
	var open_result2: Dictionary = await conn.call_tool(
		"minerva_scansort_open_vault",
		{"path": vault_abs}
	)
	check("open_vault (2nd) returned Dictionary", open_result2 is Dictionary,
		"got type %d" % typeof(open_result2))
	check("open_vault (2nd) ok == true",
		open_result2.get("ok", false) == true,
		"got: %s" % str(open_result2))
	var info2: Dictionary = open_result2.get("info", {})
	check("open_vault (2nd) emergency_contact_name == 'Imran'",
		info2.get("emergency_contact_name", "") == "Imran",
		"got: '%s'" % str(info2.get("emergency_contact_name", "")))

	# --- CLEANUP ---
	print("\n-- cleanup --")
	DirAccess.remove_absolute(vault_abs)
	DirAccess.remove_absolute(vault_abs + "-wal")
	DirAccess.remove_absolute(vault_abs + "-shm")
	check("vault file deleted after test",
		not FileAccess.file_exists(vault_abs))

	# --- STOP ---
	print("\n-- stop_plugin --")
	var stop_result = await pm.stop_plugin("scansort")
	check("stop_plugin returns ok",
		stop_result.get("ok", false) == true,
		"got: %s" % str(stop_result))
	check("plugin state == STOPPED", def.state == S_STOPPED,
		"got state=%d (expected %d)" % [def.state, S_STOPPED])


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
