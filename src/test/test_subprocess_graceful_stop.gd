extends SceneTree
## Broad actual-child oracle; requires the exact rebuilt terminal GDExtension.

var failed := 0
var passed := 0
var completed := false
var started_at := 0
var modes_completed: Array[String] = []

func _initialize() -> void:
	started_at = Time.get_ticks_msec()
	auto_accept_quit = false
	_run.call_deferred()

func _process(_delta: float) -> bool:
	if not completed and Time.get_ticks_msec() - started_at > 30000:
		check("watchdog: run did not complete", false)
		quit(1)
	return false

func _finalize() -> void:
	if not completed:
		check("run completed before engine exit", false)
		quit(1)
	print("Graceful-stop oracle: passed=%d failed=%d completed=%s children=%s" %
		[passed, failed, completed, str(modes_completed)])

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func _start_ready(process, mode: String) -> bool:
	var python := OS.get_environment("PYTHON")
	if python.is_empty():
		python = "python" if OS.get_name() == "Windows" else "python3"
	var fixture := ProjectSettings.globalize_path("res://test/fixtures/subprocess_graceful_stop/child.py")
	if not process.start(python, PackedStringArray([fixture, mode])):
		return false
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		if process.has_output():
			return process.read_line() == "READY"
		await create_timer(0.01).timeout
	return false

func _run() -> void:
	if not ClassDB.class_exists("SubProcess"):
		printerr("SubProcess GDExtension required")
		quit(2)
		return
	var process = ClassDB.instantiate("SubProcess")
	root.add_child(process)
	var exits: Array[int] = []
	process.process_exited.connect(func(code: int): exits.append(code))
	for mode: String in ["settle", "flood"]:
		check(mode + " child ready", await _start_ready(process, mode))
		var started := Time.get_ticks_msec()
		var code: int = process.stop_gracefully(10000, "oracle-" + mode)
		var elapsed := Time.get_ticks_msec() - started
		check(mode + " EOF exit is actual zero without signal", code == 0)
		check(mode + " settles after one second, before full grace", elapsed >= 900 and elapsed < 5000)
		check(mode + " final stderr retained", process.read_all_stderr().contains("EOF shutdown completed"))
		check(mode + " shutdown flood is drained without overflow", not process.has_io_overflow())
		check(mode + " ownership cleaned", not process.is_running())
		check(mode + " repeated graceful stop keeps result", process.stop_gracefully() == 0)
		process.stop()
		await process_frame
		check(mode + " exit signal agrees with actual result", not exits.is_empty() and exits.back() == 0)
		modes_completed.append(mode)
	check("ignoring EOF child ready", await _start_ready(process, "ignore"))
	var started := Time.get_ticks_msec()
	var forced: int = process.stop_gracefully(10000, "oracle-ignores-EOF")
	var elapsed := Time.get_ticks_msec() - started
	await process_frame
	check("ignoring EOF waits for bounded default grace", elapsed >= 9900 and elapsed < 13000)
	check("ignoring EOF is terminated and ownership cleaned", forced != 0 and not process.is_running())
	# Executor must also match the native named EOF-deadline warning in its log.
	check("forced child exit signal agrees", not exits.is_empty() and exits.back() == forced)
	modes_completed.append("ignore")
	process.stop()
	check("legacy stop remains bounded", await _start_ready(process, "ignore"))
	started = Time.get_ticks_msec()
	process.stop()
	check("no-argument stop does not acquire ten-second grace", Time.get_ticks_msec() - started < 3000)
	process.queue_free()
	check("watchdog: all modes completed within 30 seconds", Time.get_ticks_msec() - started_at < 30000)
	completed = true
	quit(1 if failed else 0)
