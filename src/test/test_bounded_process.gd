extends SceneTree
## BoundedProcess.run with real child processes (Python, found by bare name
## as the host does):
##   - a child that writes to stdout and stderr and exits 3 is reported with
##     both outputs, stdout first, and exit code 3;
##   - a child that outlives its deadline is killed: run returns -1 soon
##     after the deadline, the kill has been issued (the pid is no longer
##     running: on Unix the child was also reaped; on Windows this shows only
##     that Godot released it), and frames keep being processed while it
##     waits;
##   - a command that cannot be run is reported non-zero.
##
## Run: godot --headless --path src --script test/test_bounded_process.gd

const HELPERS_GD := "res://test/marketplace_test_helpers.gd"

var _fail := 0


func _init() -> void:
	create_timer(60.0).timeout.connect(func() -> void:
		print("FAIL: timed out")
		quit(1))
	await process_frame
	var python: String = load(HELPERS_GD).python_cmd()

	var done: Dictionary = await BoundedProcess.run(python, ["-c",
		"import sys; sys.stdout.write('out-line'); sys.stdout.flush(); sys.stderr.write('err-line'); sys.exit(3)"], 10.0)
	_check(done.exit_code == 3 and done.output.find("out-line") != -1 \
		and done.output.find("err-line") > done.output.find("out-line"),
		"a child that exits reports its exit code and stdout then stderr: %s" % [done])

	var frames := [0]
	var count := func() -> void: frames[0] += 1
	process_frame.connect(count)
	var started := Time.get_ticks_msec()
	var hung: Dictionary = await BoundedProcess.run(python, ["-c", "import time; time.sleep(30)"], 0.5)
	var waited := Time.get_ticks_msec() - started
	process_frame.disconnect(count)
	# On Unix, asking about the reaped pid also logs an engine ERROR line.
	_check(hung.exit_code == -1 and hung.get("pid", -1) > 0 and not OS.is_process_running(hung.pid),
		"a child past its deadline is killed: %s" % [hung])
	_check(waited >= 500 and waited < 5000 and frames[0] >= 2,
		"run returns soon after the deadline, with frames processed meanwhile: %d ms, %d frames" % [waited, frames[0]])

	var missing: Dictionary = await BoundedProcess.run("minerva-no-such-command-for-bounded-process", [], 5.0)
	# Unix forks before exec, so a failed exec is an exited child (with
	# Godot's error text on stderr); Windows fails to spawn at all.
	_check(missing.exit_code != 0, "a command that cannot run is reported non-zero: %s" % [missing])

	print("=== %s ===" % ("FAIL" if _fail else "PASS"))
	quit(1 if _fail else 0)


func _check(ok: bool, what: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + what)
	if not ok:
		_fail += 1
