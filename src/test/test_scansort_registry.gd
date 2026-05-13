extends SceneTree
## Scansort plugin registry tool integration test — T5 R2.
##
## Run: godot --headless --path src --script test/test_scansort_registry.gd
##
## Tracks docket: minerva 019e1cdb451076ae8c344f6e6ec605e1 (scansort plugin DCR)
## Round:         T5 R2 — cross-vault registry layer (registry_list/add/remove,
##                check_sha256, check_sha256_all_vaults)
##
## Goal: exercise the 5 new registry/fingerprint MCP tools against real vault
##       files using the actual Rust binary. No stubs. Verifies:
##         1. empty registry list
##         2. add vault A (newly added)
##         3. add vault B (newly added), list has 2
##         4. add vault A again (idempotent — added == false)
##         5. check_sha256 single vault, sha not present
##         6. check_sha256_all_vaults, sha not in any vault
##         7. remove vault A (removed == true), list has 1
##         8. remove vault A again (removed == false)

const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"

const SCANSORT_PLUGIN_DIR_REL := "/github/plugins/scansort"
const SCANSORT_BINARY_REL := "/scansort-plugin"
const SCANSORT_MANIFEST_REL := "/manifest.json"

const S_RUNNING := 2
const S_STOPPED := 3

## Paths inside the auto-granted plugin data scope.
const VAULT_SCOPE_REL := "user://plugins/data/scansort/test"
const VAULT_A_FILENAME := "r2_vault_a.ssort"
const VAULT_B_FILENAME := "r2_vault_b.ssort"
const REGISTRY_FILENAME := "r2_registry.json"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Scansort Registry Tool Integration Test (T5 R2) ===\n")
	print("Purpose: registry list/add/remove + check_sha256 / check_sha256_all_vaults via real Rust binary.\n")

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

	# --- PREPARE PATHS ---
	var scope_dir: String = ProjectSettings.globalize_path(VAULT_SCOPE_REL)
	DirAccess.make_dir_recursive_absolute(scope_dir)
	var vault_a_abs: String = scope_dir.path_join(VAULT_A_FILENAME)
	var vault_b_abs: String = scope_dir.path_join(VAULT_B_FILENAME)
	var registry_abs: String = scope_dir.path_join(REGISTRY_FILENAME)

	print("\nVault A:  %s" % vault_a_abs)
	print("Vault B:  %s" % vault_b_abs)
	print("Registry: %s\n" % registry_abs)

	# Pre-clean: remove stale files from any prior run.
	for path in [vault_a_abs, vault_a_abs + "-wal", vault_a_abs + "-shm",
				 vault_b_abs, vault_b_abs + "-wal", vault_b_abs + "-shm",
				 registry_abs]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)

	# --- SETUP: create two test vaults ---
	print("-- setup: create vault A --")
	var ca: Dictionary = await conn.call_tool(
		"minerva_scansort_create_vault",
		{"path": vault_a_abs, "name": "Vault A"}
	)
	check("create vault A ok", ca.get("ok", false) == true, "got: %s" % str(ca))
	check("vault A file exists", FileAccess.file_exists(vault_a_abs))

	print("-- setup: create vault B --")
	var cb: Dictionary = await conn.call_tool(
		"minerva_scansort_create_vault",
		{"path": vault_b_abs, "name": "Vault B"}
	)
	check("create vault B ok", cb.get("ok", false) == true, "got: %s" % str(cb))
	check("vault B file exists", FileAccess.file_exists(vault_b_abs))

	# --- 1. EMPTY REGISTRY LIST ---
	print("\n-- case 1: empty registry list --")
	var list1: Dictionary = await conn.call_tool(
		"minerva_scansort_registry_list",
		{"registry_path": registry_abs}
	)
	check("registry_list returned Dictionary", list1 is Dictionary,
		"got type %d" % typeof(list1))
	var entries1 = list1.get("entries", null)
	check("registry_list entries is Array", entries1 is Array,
		"got: %s" % str(entries1))
	check("empty registry has 0 entries", entries1 is Array and entries1.size() == 0,
		"got %d entries" % (entries1.size() if entries1 is Array else -1))

	# --- 2. ADD VAULT A ---
	print("\n-- case 2: add vault A --")
	var add_a: Dictionary = await conn.call_tool(
		"minerva_scansort_registry_add",
		{"vault_path": vault_a_abs, "registry_path": registry_abs}
	)
	check("registry_add A returned Dictionary", add_a is Dictionary,
		"got type %d" % typeof(add_a))
	check("registry_add A ok == true", add_a.get("ok", false) == true,
		"got: %s" % str(add_a))
	check("registry_add A added == true", add_a.get("added", false) == true,
		"got: %s" % str(add_a))

	# List should have 1 entry with name "Vault A"
	var list2: Dictionary = await conn.call_tool(
		"minerva_scansort_registry_list",
		{"registry_path": registry_abs}
	)
	var entries2 = list2.get("entries", [])
	check("after add A: 1 entry", entries2 is Array and entries2.size() == 1,
		"got %d entries" % (entries2.size() if entries2 is Array else -1))
	if entries2 is Array and entries2.size() == 1:
		var e = entries2[0]
		check("entry 0 name == 'Vault A'", e.get("name", "") == "Vault A",
			"got name: '%s'" % str(e.get("name", "")))

	# --- 3. ADD VAULT B ---
	print("\n-- case 3: add vault B --")
	var add_b: Dictionary = await conn.call_tool(
		"minerva_scansort_registry_add",
		{"vault_path": vault_b_abs, "registry_path": registry_abs}
	)
	check("registry_add B ok == true", add_b.get("ok", false) == true,
		"got: %s" % str(add_b))
	check("registry_add B added == true", add_b.get("added", false) == true,
		"got: %s" % str(add_b))

	var list3: Dictionary = await conn.call_tool(
		"minerva_scansort_registry_list",
		{"registry_path": registry_abs}
	)
	var entries3 = list3.get("entries", [])
	check("after add B: 2 entries", entries3 is Array and entries3.size() == 2,
		"got %d entries" % (entries3.size() if entries3 is Array else -1))

	# --- 4. ADD VAULT A AGAIN (idempotent) ---
	print("\n-- case 4: add vault A again (idempotent) --")
	var add_a2: Dictionary = await conn.call_tool(
		"minerva_scansort_registry_add",
		{"vault_path": vault_a_abs, "registry_path": registry_abs}
	)
	check("registry_add A again ok == true", add_a2.get("ok", false) == true,
		"got: %s" % str(add_a2))
	check("registry_add A again added == false (idempotent)", add_a2.get("added", true) == false,
		"got: %s" % str(add_a2))

	# List count must still be 2
	var list4: Dictionary = await conn.call_tool(
		"minerva_scansort_registry_list",
		{"registry_path": registry_abs}
	)
	var entries4 = list4.get("entries", [])
	check("after idempotent add: still 2 entries", entries4 is Array and entries4.size() == 2,
		"got %d entries" % (entries4.size() if entries4 is Array else -1))

	# --- 5. CHECK_SHA256 SINGLE VAULT, SHA NOT PRESENT ---
	print("\n-- case 5: check_sha256 single vault, sha not present --")
	var zero_sha: String = "0000000000000000000000000000000000000000000000000000000000000000"
	var sha_check: Dictionary = await conn.call_tool(
		"minerva_scansort_check_sha256",
		{"vault_path": vault_a_abs, "sha256": zero_sha}
	)
	check("check_sha256 returned Dictionary", sha_check is Dictionary,
		"got type %d" % typeof(sha_check))
	check("check_sha256 found == false", sha_check.get("found", true) == false,
		"got: %s" % str(sha_check))
	check("check_sha256 doc_id == null", sha_check.get("doc_id", 0) == null,
		"got doc_id: %s" % str(sha_check.get("doc_id", "MISSING")))

	# --- 6. CHECK_SHA256_ALL_VAULTS, SHA NOT IN ANY VAULT ---
	print("\n-- case 6: check_sha256_all_vaults, sha not in any vault --")
	var all_check: Dictionary = await conn.call_tool(
		"minerva_scansort_check_sha256_all_vaults",
		{"sha256": zero_sha, "registry_path": registry_abs}
	)
	check("check_sha256_all_vaults returned Dictionary", all_check is Dictionary,
		"got type %d" % typeof(all_check))
	check("check_sha256_all_vaults found == false", all_check.get("found", true) == false,
		"got: %s" % str(all_check))
	check("check_sha256_all_vaults vault_path == null", all_check.get("vault_path", 0) == null,
		"got vault_path: %s" % str(all_check.get("vault_path", "MISSING")))
	check("check_sha256_all_vaults doc_id == null", all_check.get("doc_id", 0) == null,
		"got doc_id: %s" % str(all_check.get("doc_id", "MISSING")))

	# --- 7. REMOVE VAULT A ---
	print("\n-- case 7: remove vault A --")
	var rem_a: Dictionary = await conn.call_tool(
		"minerva_scansort_registry_remove",
		{"vault_path": vault_a_abs, "registry_path": registry_abs}
	)
	check("registry_remove A returned Dictionary", rem_a is Dictionary,
		"got type %d" % typeof(rem_a))
	check("registry_remove A ok == true", rem_a.get("ok", false) == true,
		"got: %s" % str(rem_a))
	check("registry_remove A removed == true", rem_a.get("removed", false) == true,
		"got: %s" % str(rem_a))

	var list7: Dictionary = await conn.call_tool(
		"minerva_scansort_registry_list",
		{"registry_path": registry_abs}
	)
	var entries7 = list7.get("entries", [])
	check("after remove A: 1 entry", entries7 is Array and entries7.size() == 1,
		"got %d entries" % (entries7.size() if entries7 is Array else -1))
	if entries7 is Array and entries7.size() == 1:
		var e = entries7[0]
		check("remaining entry name == 'Vault B'", e.get("name", "") == "Vault B",
			"got name: '%s'" % str(e.get("name", "")))

	# --- 8. REMOVE VAULT A AGAIN (already gone) ---
	print("\n-- case 8: remove vault A again (already gone) --")
	var rem_a2: Dictionary = await conn.call_tool(
		"minerva_scansort_registry_remove",
		{"vault_path": vault_a_abs, "registry_path": registry_abs}
	)
	check("registry_remove A again ok == true", rem_a2.get("ok", false) == true,
		"got: %s" % str(rem_a2))
	check("registry_remove A again removed == false", rem_a2.get("removed", true) == false,
		"got: %s" % str(rem_a2))

	# --- CLEANUP ---
	print("\n-- cleanup --")
	for path in [vault_a_abs, vault_a_abs + "-wal", vault_a_abs + "-shm",
				 vault_b_abs, vault_b_abs + "-wal", vault_b_abs + "-shm",
				 registry_abs]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	check("vault A file deleted", not FileAccess.file_exists(vault_a_abs))
	check("vault B file deleted", not FileAccess.file_exists(vault_b_abs))
	check("registry file deleted", not FileAccess.file_exists(registry_abs))

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
