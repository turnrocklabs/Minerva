extends SceneTree
## Non-mocked functional-floor tests for SetupExecutors — every case here
## spawns a REAL executable fixture script through the REAL executor path
## (OS.execute_with_pipe under the hood); nothing is stubbed.
##
## Run: godot --headless --path src --script test/test_plugin_setup_executors.gd
##
## Docs/design/plugin-setup-pipeline.md §4 fixture coverage:
##   F1  — copy-only happy path -> ok:true, artifact exists
##   F7  — step exits 2 -> setup_step_failed, exit_code 2 + stderr_tail
##   F8  — step exits 0, artifact absent -> setup_step_failed, artifact_expected set
##   F9  — step exceeds timeout_s -> setup_step_failed within the wall-clock deadline
##   F10 — exec step -> argv reaches the fixture process verbatim
##   F12 — dry-run golden: rendered plan byte-identical to a committed golden
##         file, and running the renderer twice on identical input produces
##         byte-identical output
## Plus a go_build case (fake-go fixture) for direct coverage of the
## tool_paths substitution path, since it's cheap and the round's brief
## explicitly asked for a "fake-go" fixture.
##
## SetupDryRun (F12) has no subprocess/filesystem surface of its own, so its
## coverage lives here rather than earning a third test file — this is the
## file that already owns the "does the real machinery behave" concerns.
##
## Each test gets its own throwaway plugin_dir under
## OS.get_user_data_dir()/setup_executor_tests/<case> so runs never collide
## and never touch the fixtures directory itself.

const FIXTURES_ABS_DIR_REL := "/test/fixtures/plugin_setup"

var _pass_count: int = 0
var _fail_count: int = 0
var _fixtures_dir: String = ""


func _init() -> void:
	print("=== SetupExecutors Tests ===\n")

	_fixtures_dir = ProjectSettings.globalize_path("res://" + FIXTURES_ABS_DIR_REL)
	_ensure_fixtures_executable()

	print("-- F1: copy-only happy path --")
	test_copy_happy_path()

	print("\n-- go_build happy path (fake-go fixture) --")
	test_go_build_happy_path()

	print("\n-- F7: step exits 2 --")
	test_exec_exit_2_returns_failure_envelope()

	print("\n-- F8: step exits 0, artifact absent --")
	test_exec_exit_0_no_artifact_returns_artifact_expected()

	print("\n-- F9: step exceeds timeout_s --")
	test_exec_timeout_is_enforced()

	print("\n-- F10: exec argv verbatim --")
	test_exec_argv_reaches_process_verbatim()
	test_exec_relative_argv0_resolved_against_plugin_dir()

	print("\n-- stderr_tail is capped at 2KB --")
	test_stderr_tail_capped_at_2kb()

	print("\n-- dry-run argv == executor resolved_argv (parity, every step type) --")
	test_dry_run_and_executor_argv_parity()

	print("\n-- F12: dry-run golden + determinism --")
	test_dry_run_matches_golden_file()
	test_dry_run_is_deterministic_across_repeated_calls()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ---------------------------------------------------------------------------
# F1 — copy
# ---------------------------------------------------------------------------

func test_copy_happy_path() -> void:
	var plugin_dir := _fresh_plugin_dir("copy_happy")
	var src_dir := plugin_dir.path_join("src_data")
	DirAccess.make_dir_recursive_absolute(src_dir)
	var src_file := src_dir.path_join("data.txt")
	var f := FileAccess.open(src_file, FileAccess.WRITE)
	f.store_string("hello from setup pipeline test\n")
	f.close()

	var step := {"type": "copy", "from": "src_data/data.txt", "to": "out/data.txt"}
	var result := SetupExecutors.run_step(step, 0, {"tool_paths": {}, "plugin_dir": plugin_dir})

	check("copy step returns ok:true", result.get("ok", false) == true, "got: %s" % str(result))
	var dest := plugin_dir.path_join("out/data.txt")
	check("copy destination file exists", FileAccess.file_exists(dest))
	if FileAccess.file_exists(dest):
		var df := FileAccess.open(dest, FileAccess.READ)
		var content := df.get_as_text()
		df.close()
		check("copy destination content matches source", content == "hello from setup pipeline test\n", "got: %s" % content)


# ---------------------------------------------------------------------------
# go_build (fake-go fixture)
# ---------------------------------------------------------------------------

func test_go_build_happy_path() -> void:
	var plugin_dir := _fresh_plugin_dir("go_build_happy")
	var step := {"type": "go_build", "package": "./", "output": "bin/fake-plugin", "timeout_s": 15}
	var ctx := {"tool_paths": {"go": _fixtures_dir.path_join("fake-go")}, "plugin_dir": plugin_dir}
	var result := SetupExecutors.run_step(step, 0, ctx)

	check("go_build step returns ok:true", result.get("ok", false) == true, "got: %s" % str(result))
	var artifact := plugin_dir.path_join("bin/fake-plugin")
	check("go_build artifact was written by fake-go", FileAccess.file_exists(artifact))


# ---------------------------------------------------------------------------
# F7 — exit 2
# ---------------------------------------------------------------------------

func test_exec_exit_2_returns_failure_envelope() -> void:
	var plugin_dir := _fresh_plugin_dir("exec_exit2")
	var step := {
		"type": "exec",
		"argv": [_fixtures_dir.path_join("exit2-with-stderr.sh")],
		"timeout_s": 15,
	}
	var result := SetupExecutors.run_step(step, 3, {"tool_paths": {}, "plugin_dir": plugin_dir})

	check("exit-2 step returns the failure envelope", result.get("error", "") == "setup_step_failed", "got: %s" % str(result))
	check("envelope step_type is exec", result.get("step_type", "") == "exec")
	check("envelope step_index is echoed back", result.get("step_index", -1) == 3)
	check("envelope exit_code is 2", result.get("exit_code", -1) == 2, "got: %s" % str(result))
	check("envelope stderr_tail contains the fixture's stderr text",
			str(result.get("stderr_tail", "")).contains("boom"), "got: %s" % str(result.get("stderr_tail", "")))
	check("envelope has no artifact_expected key (not an artifact-check failure)",
			not result.has("artifact_expected"))
	check("envelope resolved_argv echoes the declared argv",
			result.get("resolved_argv", []) == [_fixtures_dir.path_join("exit2-with-stderr.sh")],
			"got: %s" % str(result.get("resolved_argv", [])))


# ---------------------------------------------------------------------------
# F8 — exit 0, artifact absent
# ---------------------------------------------------------------------------

func test_exec_exit_0_no_artifact_returns_artifact_expected() -> void:
	var plugin_dir := _fresh_plugin_dir("exec_no_artifact")
	var step := {
		"type": "exec",
		"argv": [_fixtures_dir.path_join("exit0-no-write.sh")],
		"artifact": "out/never-written.bin",
		"timeout_s": 15,
	}
	var result := SetupExecutors.run_step(step, 0, {"tool_paths": {}, "plugin_dir": plugin_dir})

	check("no-artifact step returns the failure envelope", result.get("error", "") == "setup_step_failed", "got: %s" % str(result))
	check("envelope exit_code is 0 (the process itself succeeded)", result.get("exit_code", -1) == 0, "got: %s" % str(result))
	check("envelope artifact_expected names the missing artifact",
			result.get("artifact_expected", "") == "out/never-written.bin", "got: %s" % str(result))


# ---------------------------------------------------------------------------
# F9 — timeout
# ---------------------------------------------------------------------------

func test_exec_timeout_is_enforced() -> void:
	var plugin_dir := _fresh_plugin_dir("exec_timeout")
	var step := {
		"type": "exec",
		"argv": [_fixtures_dir.path_join("sleep-forever.sh")],
		"timeout_s": 1,
	}
	var start_ms := Time.get_ticks_msec()
	var result := SetupExecutors.run_step(step, 0, {"tool_paths": {}, "plugin_dir": plugin_dir})
	var elapsed_ms := Time.get_ticks_msec() - start_ms

	check("timeout step returns the failure envelope", result.get("error", "") == "setup_step_failed", "got: %s" % str(result))
	check("timeout is enforced well within the fixture's 30s sleep (took %dms)" % elapsed_ms, elapsed_ms < 10000)
	check("envelope stderr_tail mentions the timeout",
			str(result.get("stderr_tail", "")).contains("timed out"), "got: %s" % str(result.get("stderr_tail", "")))


# ---------------------------------------------------------------------------
# F10 — argv verbatim
# ---------------------------------------------------------------------------

func test_exec_argv_reaches_process_verbatim() -> void:
	var plugin_dir := _fresh_plugin_dir("exec_argv_verbatim")
	var outfile_rel := "argv_capture.txt"
	# exec steps have NO cwd guarantee (contract amendment) — the capture
	# path handed to the fixture must be absolute. The `artifact` field stays
	# plugin-relative; the executor resolves it against plugin_dir.
	var outfile_abs := plugin_dir.path_join(outfile_rel)
	var declared_args := ["arg with spaces", "arg\"with\"quotes", "--flag=value", "trailing-backslash\\", "$HOME", "%PATH%"]

	var step := {
		"type": "exec",
		"argv": [_fixtures_dir.path_join("echo-argv.sh"), outfile_abs] + declared_args,
		"artifact": outfile_rel,
		"timeout_s": 15,
	}
	var result := SetupExecutors.run_step(step, 0, {"tool_paths": {}, "plugin_dir": plugin_dir})
	check("echo-argv step returns ok:true", result.get("ok", false) == true, "got: %s" % str(result))

	check("argv capture file was written", FileAccess.file_exists(outfile_abs))
	if FileAccess.file_exists(outfile_abs):
		var f := FileAccess.open(outfile_abs, FileAccess.READ)
		var captured_text := f.get_as_text()
		f.close()
		var captured_lines: Array = captured_text.split("\n", false)
		check("captured argv matches the declared args exactly, in order (incl. unexpanded $X / %X%)",
				captured_lines == declared_args, "got: %s" % str(captured_lines))


func test_exec_relative_argv0_resolved_against_plugin_dir() -> void:
	var plugin_dir := _fresh_plugin_dir("exec_dotslash_argv0")
	# Plant a copy of the echo-argv fixture INSIDE the plugin dir so a
	# "./"-relative argv[0] only works if the executor really resolved it
	# against plugin_dir (there is no cwd to lean on).
	var local_script := plugin_dir.path_join("local-echo.sh")
	DirAccess.copy_absolute(_fixtures_dir.path_join("echo-argv.sh"), local_script)
	OS.execute("chmod", ["+x", local_script])

	var outfile_abs := plugin_dir.path_join("dotslash_capture.txt")
	var step := {
		"type": "exec",
		"argv": ["./local-echo.sh", outfile_abs, "hello"],
		"artifact": "dotslash_capture.txt",
		"timeout_s": 15,
	}
	var result := SetupExecutors.run_step(step, 0, {"tool_paths": {}, "plugin_dir": plugin_dir})
	check("'./'-relative argv[0] step returns ok:true", result.get("ok", false) == true, "got: %s" % str(result))
	check("'./'-relative argv[0] capture file exists", FileAccess.file_exists(outfile_abs))


# ---------------------------------------------------------------------------
# stderr_tail cap
# ---------------------------------------------------------------------------

func test_stderr_tail_capped_at_2kb() -> void:
	var plugin_dir := _fresh_plugin_dir("stderr_cap")
	var step := {
		"type": "exec",
		"argv": [_fixtures_dir.path_join("big-stderr.sh")],
		"timeout_s": 15,
	}
	var result := SetupExecutors.run_step(step, 0, {"tool_paths": {}, "plugin_dir": plugin_dir})

	check("big-stderr step returns the failure envelope", result.get("error", "") == "setup_step_failed", "got: %s" % str(result))
	var tail: String = str(result.get("stderr_tail", ""))
	check("stderr_tail is capped at <= 2048 bytes", tail.to_utf8_buffer().size() <= 2048,
			"got %d bytes" % tail.to_utf8_buffer().size())
	check("stderr_tail keeps the END marker (it's a tail, not a head)", tail.contains("END-MARKER"), "got: %s" % tail)
	check("stderr_tail drops the START marker (proves real truncation happened)",
			not tail.contains("START-MARKER"), "got: %s" % tail)


# ---------------------------------------------------------------------------
# Dry-run <-> executor argv parity (MF3 guard)
# ---------------------------------------------------------------------------

## Both SetupDryRun and SetupExecutors consume SetupSteps.build(); this test
## proves it stays that way. For every step type it asserts:
##   (a) the argv arrays SetupDryRun renders == SetupSteps.build()'s phases
##       (parsed back out of the rendered text, so the DISPLAYED argv is
##       what's compared, not an internal shortcut), and
##   (b) the executor's failure-envelope resolved_argv (forced via a
##       nonexistent tool/binary) == the first spawnable phase's argv.
func test_dry_run_and_executor_argv_parity() -> void:
	var plugin_dir := _fresh_plugin_dir("argv_parity")
	var tool_paths := {
		"go": "/nonexistent/tools/go",
		"cargo": "/nonexistent/tools/cargo",
		"python": "/nonexistent/tools/python",
	}
	var cases: Array[Dictionary] = [
		{"type": "go_build", "package": "./", "output": "bin/x", "timeout_s": 5},
		{"type": "cargo_build", "manifest_dir": "worker", "artifact": "worker/target/release/w", "timeout_s": 5},
		{"type": "cargo_build", "manifest_dir": "worker", "artifact": "t/w", "profile": "custom-prof", "timeout_s": 5},
		{"type": "python_venv", "dir": "worker", "install": "editable", "timeout_s": 5},
		{"type": "python_venv", "dir": "worker", "install": "requirements", "requirements_file": "reqs.txt", "timeout_s": 5},
		{"type": "exec", "argv": ["/nonexistent/bin/prog", "a b", "--x"], "artifact": "out.bin", "timeout_s": 5},
		{"type": "exec", "argv": ["./rel-prog", "verbatim"], "timeout_s": 5},
		{"type": "copy", "from": "nonexistent-src.txt", "to": "out/dst.txt"},
	]

	for case_idx in cases.size():
		var step: Dictionary = cases[case_idx]
		var step_type: String = str(step.get("type", ""))
		var desc_prefix := "[case %d %s]" % [case_idx, step_type]

		var phases: Array = SetupSteps.build(step, tool_paths, plugin_dir).get("phases", [])
		var builder_argvs: Array = []
		for phase in phases:
			if not (phase.get("argv", []) as Array).is_empty():
				builder_argvs.append(phase.get("argv"))

		# (a) dry-run rendered argv == builder argv, phase for phase.
		var rendered: String = SetupDryRun.render({"steps": [step]}, plugin_dir, tool_paths)
		var rendered_argvs := _extract_rendered_argvs(rendered)
		check("%s dry-run renders the builder's argv exactly" % desc_prefix,
				str(rendered_argvs) == str(builder_argvs),
				"rendered=%s builder=%s" % [str(rendered_argvs), str(builder_argvs)])

		# (b) executor resolved_argv == builder argv (first spawnable phase).
		# Every subprocess case uses a nonexistent tool/binary so run_step
		# fails at spawn and hands the argv back in the envelope; copy fails
		# on the missing source with an empty resolved_argv (no subprocess).
		var result := SetupExecutors.run_step(step, case_idx, {"tool_paths": tool_paths, "plugin_dir": plugin_dir})
		check("%s executor returns the failure envelope" % desc_prefix,
				result.get("error", "") == "setup_step_failed", "got: %s" % str(result))
		var expected_resolved: Array = builder_argvs[0] if not builder_argvs.is_empty() else []
		check("%s executor resolved_argv == dry-run/builder argv" % desc_prefix,
				str(result.get("resolved_argv", null)) == str(expected_resolved),
				"resolved=%s expected=%s" % [str(result.get("resolved_argv", null)), str(expected_resolved)])


## Parses every `argv=...` / `argv[label]=...` line out of a rendered plan
## back into arrays, in order.
func _extract_rendered_argvs(rendered: String) -> Array:
	var out: Array = []
	for line in rendered.split("\n"):
		var trimmed: String = line.strip_edges()
		if not trimmed.begins_with("argv"):
			continue
		var eq := trimmed.find("=")
		if eq == -1:
			continue
		var parsed: Variant = JSON.parse_string(trimmed.substr(eq + 1))
		if parsed is Array:
			out.append(parsed)
	return out


# ---------------------------------------------------------------------------
# F12 — dry-run golden + determinism
# ---------------------------------------------------------------------------

## The setup dict, plugin_dir, and tool_paths used to generate
## fixtures/plugin_setup/dry_run_golden.txt. Deliberately excludes
## python_venv (its rendered venv-python path is OS.get_name()-conditional —
## see SetupDryRun's module comment), so the golden file is portable across
## every CI platform, not just the one it happened to be generated on.
func _golden_dry_run_inputs() -> Dictionary:
	return {
		"setup": {
			"requires": [
				{"tool": "go", "min": "1.22"},
				{"tool": "python", "min": "3.10"},
			],
			"steps": [
				{"type": "go_build", "package": "./", "output": "bin/pcb-plugin"},
				{"type": "cargo_build", "manifest_dir": "worker", "artifact": "worker/target/release/worker"},
				{"type": "copy", "from": "assets/policy.json", "to": "bin/policy.json"},
				{"type": "exec", "argv": ["./scripts/postinstall.sh", "--flag"], "artifact": "bin/generated.dat"},
			],
		},
		"plugin_dir": "/tmp/fixture-plugin",
		"tool_paths": {"go": "/usr/local/go/bin/go", "cargo": "/home/user/.cargo/bin/cargo"},
	}


func test_dry_run_matches_golden_file() -> void:
	var inputs := _golden_dry_run_inputs()
	var rendered: String = SetupDryRun.render(inputs["setup"], inputs["plugin_dir"], inputs["tool_paths"])

	var golden_path := _fixtures_dir.path_join("dry_run_golden.txt")
	check("golden fixture file exists at %s" % golden_path, FileAccess.file_exists(golden_path))
	if not FileAccess.file_exists(golden_path):
		return

	var f := FileAccess.open(golden_path, FileAccess.READ)
	var golden_text := f.get_as_text()
	f.close()

	check("rendered plan is byte-identical to the committed golden file",
			rendered == golden_text,
			"rendered %d bytes vs golden %d bytes" % [rendered.to_utf8_buffer().size(), golden_text.to_utf8_buffer().size()])


func test_dry_run_is_deterministic_across_repeated_calls() -> void:
	var inputs := _golden_dry_run_inputs()
	var first: String = SetupDryRun.render(inputs["setup"], inputs["plugin_dir"], inputs["tool_paths"])
	var second: String = SetupDryRun.render(inputs["setup"], inputs["plugin_dir"], inputs["tool_paths"])
	check("rendering the same inputs twice produces byte-identical output", first == second)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Fixture scripts are checked out from git, which does not always preserve
## the executable bit reliably across every checkout path (worktrees, CI
## artifact extraction, etc). Defensive chmod so this test never fails for a
## reason unrelated to the executor logic under test.
func _ensure_fixtures_executable() -> void:
	for name in ["fake-go", "exit2-with-stderr.sh", "exit0-no-write.sh", "sleep-forever.sh", "echo-argv.sh", "big-stderr.sh"]:
		OS.execute("chmod", ["+x", _fixtures_dir.path_join(name)])


func _fresh_plugin_dir(case_name: String) -> String:
	var dir: String = ProjectSettings.globalize_path("user://setup_executor_tests").path_join(case_name)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


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
