extends SceneTree
## Functional tests for ToolchainRegistry + ToolchainProbe — the toolchain
## resolve/preflight layer for the plugin `setup` pipeline
## (DCR 019f69428fa0 G2.1/G2.2, contract: Docs/design/plugin-setup-pipeline.md §2).
##
## Non-mocked functional floor: every "fake tool" is a real executable shell
## script under test/fixtures/toolchain/**, spawned through the REAL probe
## path (ToolchainProbe.run_with_timeout → OS.execute_with_pipe). Nothing
## about OS.execute or subprocess timeout is mocked; only the *search space*
## is redirected (via search_dirs_override) so tests never depend on what
## toolchains the host machine happens to have installed.
##
## Run: godot --headless --path src --script test/test_toolchain_registry.gd

const FIXTURES_RES := "res://test/fixtures/toolchain"

var _pass_count: int = 0
var _fail_count: int = 0
var _scratch_configs: Array[String] = []


func _init() -> void:
	print("=== ToolchainRegistry Tests ===\n")

	await process_frame

	test_happy_resolution()
	test_too_old_envelope()
	test_missing_envelope()
	test_hang_deadline_enforced()
	test_shim_rejected_without_execution()
	test_persistence_sticky_then_invalidate()
	test_preflight_multiple_failures()
	test_preflight_mixed_success_and_failure()
	test_unknown_tool_resolves_missing()
	test_well_known_dir_expansion_uses_env_not_literal()

	for cfg_path in _scratch_configs:
		_remove_user_file(cfg_path)

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Helpers ───────────────────────────────────────────────────────────────────

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


func _fixture_dir(name: String) -> String:
	return ProjectSettings.globalize_path(FIXTURES_RES.path_join(name))


## Every registry built here gets its own scratch config_path so tests never
## share a sticky-persistence cache with each other OR with the real
## user://toolchain_paths.cfg used by the running application. Tests that
## specifically exercise persistence set config_path themselves (see
## test_persistence_sticky_then_invalidate).
func _new_registry(search_dir_names: Array[String]) -> ToolchainRegistry:
	var reg := ToolchainRegistry.new()
	reg.config_path = _scratch_config_path("auto")
	var dirs: Array[String] = []
	for n in search_dir_names:
		dirs.append(_fixture_dir(n))
	reg.search_dirs_override = dirs
	_scratch_configs.append(reg.config_path)
	return reg


## Unique scratch config path so persistence tests never touch the real
## user://toolchain_paths.cfg and never collide with each other.
func _scratch_config_path(label: String) -> String:
	return "user://test_toolchain_paths_%s_%d.cfg" % [label, Time.get_ticks_usec()]


func _remove_user_file(user_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(user_path)
	if FileAccess.file_exists(abs_path):
		DirAccess.remove_absolute(abs_path)


# ── Tests ─────────────────────────────────────────────────────────────────────

func test_happy_resolution() -> void:
	print("test_happy_resolution:")
	var reg := _new_registry(["happy"])
	var r := reg.resolve("go", "1.20")
	check("happy go resolves ok", r.get("ok", false), str(r))
	if r.get("ok", false):
		check("happy go path points at fixture", r["path"] == _fixture_dir("happy").path_join("go"),
				"got %s" % r["path"])
		check("happy go version parsed exactly", r["version"] == "1.22.4", "got %s" % r["version"])

	var rc := reg.resolve("cargo", "1.70")
	check("happy cargo resolves ok", rc.get("ok", false), str(rc))
	if rc.get("ok", false):
		check("happy cargo version parsed exactly", rc["version"] == "1.75.0", "got %s" % rc["version"])


func test_too_old_envelope() -> void:
	print("test_too_old_envelope:")
	var reg := _new_registry(["too_old"])
	var r := reg.resolve("go", "1.22")
	check("too_old go fails", not r.get("ok", false), str(r))
	check("too_old error code", r.get("error", "") == "toolchain_too_old", str(r))
	check("too_old tool field", r.get("tool", "") == "go")
	check("too_old found_path is the probed candidate",
			r.get("found_path", "") == _fixture_dir("too_old").path_join("go"), str(r))
	check("too_old found_version parsed", r.get("found_version", "") == "1.19.0", str(r))
	check("too_old required_min echoes input", r.get("required_min", "") == "1.22", str(r))
	check("too_old install_hint present", r.get("install_hint", "") != "")


func test_missing_envelope() -> void:
	print("test_missing_envelope:")
	var reg := _new_registry(["empty"])
	var r := reg.resolve("go", "1.22")
	check("missing go fails", not r.get("ok", false), str(r))
	check("missing error code", r.get("error", "") == "toolchain_missing", str(r))
	check("missing found_path empty", r.get("found_path", "?") == "", str(r))
	check("missing found_version empty", r.get("found_version", "?") == "", str(r))
	check("missing required_min echoes input", r.get("required_min", "") == "1.22")
	check("missing install_hint present", r.get("install_hint", "") != "")


func test_hang_deadline_enforced() -> void:
	print("test_hang_deadline_enforced:")
	var reg := _new_registry(["hang"])
	var start := Time.get_ticks_msec()
	var r := reg.resolve("go", "1.22")
	var elapsed := Time.get_ticks_msec() - start
	check("hang go fails", not r.get("ok", false), str(r))
	check("hang error code", r.get("error", "") == "toolchain_probe_failed", str(r))
	# 5s hard probe deadline (contract §2) + generous scheduling slack; a real
	# hang (8s sleep in the fixture) proves the deadline is enforced rather
	# than the child just happening to finish quickly.
	check("hang resolve() returns within ~6.5s deadline (elapsed=%dms)" % elapsed,
			elapsed < 6500, "elapsed=%dms" % elapsed)


func test_shim_rejected_without_execution() -> void:
	print("test_shim_rejected_without_execution:")
	var shim_dir := _fixture_dir("shim/Microsoft/WindowsApps")
	var marker := shim_dir.path_join("marker_ran.txt")
	if FileAccess.file_exists(marker):
		DirAccess.remove_absolute(marker)  # clean slate in case of a prior failed run

	var reg := ToolchainRegistry.new()
	reg.config_path = _scratch_config_path("shim")
	_scratch_configs.append(reg.config_path)
	reg.search_dirs_override = [shim_dir]
	var r := reg.resolve("go", "1.22")

	check("shim go fails", not r.get("ok", false), str(r))
	check("shim error code", r.get("error", "") == "toolchain_shim_rejected", str(r))
	check("shim candidate was never executed (no marker file)",
			not FileAccess.file_exists(marker),
			"marker file exists at %s — shim ran!" % marker)

	if FileAccess.file_exists(marker):
		DirAccess.remove_absolute(marker)  # don't leak state into a re-run


func test_persistence_sticky_then_invalidate() -> void:
	print("test_persistence_sticky_then_invalidate:")
	var cfg_path := _scratch_config_path("sticky")
	var reg := ToolchainRegistry.new()
	reg.config_path = cfg_path
	reg.search_dirs_override = [_fixture_dir("happy")]

	var r1 := reg.resolve("go", "1.20")
	check("initial resolve ok", r1.get("ok", false), str(r1))
	var resolved_path: String = r1.get("path", "")

	# "Corrupt/remove the search space" — point the search dirs at nothing.
	# The sticky persisted path itself is untouched, so resolve() should
	# still succeed by re-probing the persisted path directly (it never
	# consults search_dirs_override for the sticky check).
	reg.search_dirs_override = [_fixture_dir("empty")]
	var r2 := reg.resolve("go", "1.20")
	check("sticky path still used after search space removed", r2.get("ok", false), str(r2))
	check("sticky path unchanged", r2.get("path", "") == resolved_path, str(r2))

	# invalidate() clears the sticky entry — resolve() must fully re-resolve,
	# and with the search space still empty, that re-resolution now fails.
	# This proves invalidate() actually reruns full resolution rather than
	# resolve() silently keeping serving the old cached path forever.
	reg.invalidate("go")
	var r3 := reg.resolve("go", "1.20")
	check("resolve after invalidate() re-resolves (fails, empty search space)",
			not r3.get("ok", false), str(r3))
	check("post-invalidate failure is toolchain_missing (full resolution ran)",
			r3.get("error", "") == "toolchain_missing", str(r3))

	# And re-pointing search_dirs at a (different) working fixture proves the
	# full resolution path is genuinely live, not just permanently broken.
	reg.search_dirs_override = [_fixture_dir("refresh")]
	var r4 := reg.resolve("go", "1.20")
	check("resolve after invalidate() picks up a fresh candidate", r4.get("ok", false), str(r4))
	if r4.get("ok", false):
		check("fresh resolution used the refresh fixture, not the old sticky path",
				r4["path"] == _fixture_dir("refresh").path_join("go"), str(r4))

	_remove_user_file(cfg_path)


func test_preflight_multiple_failures() -> void:
	print("test_preflight_multiple_failures:")
	var reg := _new_registry(["empty"])
	var result := reg.preflight([
		{"tool": "go", "min": "1.22"},
		{"tool": "cargo", "min": "1.70"},
	])
	check("preflight not ok", not result.get("ok", true), str(result))
	var failures: Array = result.get("failures", [])
	check("preflight reports both failures", failures.size() == 2, "got %d: %s" % [failures.size(), str(failures)])
	var tools_seen := {}
	for f in failures:
		tools_seen[f.get("tool", "")] = f.get("error", "")
	check("go failure present", tools_seen.get("go", "") == "toolchain_missing", str(tools_seen))
	check("cargo failure present", tools_seen.get("cargo", "") == "toolchain_missing", str(tools_seen))
	check("preflight resolved dict empty on total failure", result.get("resolved", {}).is_empty())


func test_preflight_mixed_success_and_failure() -> void:
	print("test_preflight_mixed_success_and_failure:")
	# "happy" fixture dir only has go + cargo; python is absent → mixed result.
	var reg := _new_registry(["happy"])
	var result := reg.preflight([
		{"tool": "go", "min": "1.20"},
		{"tool": "python", "min": "3.9"},
	])
	check("preflight not fully ok (python missing)", not result.get("ok", true), str(result))
	var failures: Array = result.get("failures", [])
	check("exactly one failure (python)", failures.size() == 1, str(failures))
	if failures.size() == 1:
		check("failure is python/missing",
				failures[0].get("tool", "") == "python" and failures[0].get("error", "") == "toolchain_missing",
				str(failures[0]))
	var resolved: Dictionary = result.get("resolved", {})
	check("go resolved and present in resolved dict", resolved.has("go"), str(resolved))


func test_unknown_tool_resolves_missing() -> void:
	print("test_unknown_tool_resolves_missing:")
	var reg := _new_registry(["empty"])
	var r := reg.resolve("frobnicate-not-a-real-tool", "1.0")
	check("unknown tool fails closed rather than throwing", not r.get("ok", false), str(r))
	check("unknown tool reports toolchain_missing", r.get("error", "") == "toolchain_missing", str(r))


func test_well_known_dir_expansion_uses_env_not_literal() -> void:
	print("test_well_known_dir_expansion_uses_env_not_literal:")
	# Regression guard for the "never pass unexpanded env vars" requirement:
	# _well_known_dirs() must substitute {HOME}/{USERPROFILE} via
	# OS.get_environment() itself, never leave the literal placeholder in a
	# path that would later be handed to a subprocess.
	var reg := ToolchainRegistry.new()
	var dirs: Array[String] = reg._well_known_dirs("go")
	var any_unexpanded := false
	for d in dirs:
		if d.contains("{HOME}") or d.contains("{USERPROFILE}"):
			any_unexpanded = true
	check("well-known go dirs contain no unexpanded placeholders", not any_unexpanded, str(dirs))
	check("well-known go dirs is non-empty on a supported OS", dirs.size() > 0, str(dirs))
