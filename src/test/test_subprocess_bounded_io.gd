extends SceneTree
## Real native pipe ownership. This uses the host Python executable only as a
## deterministic child that can fill stdin and emit output; no network access.
## The lookup case always starts Python by its bare name, so PATH is searched;
## PYTHON, when set, picks the interpreter for the others. An explicit path,
## spaces included, is started as given.

var passed := 0
var failed := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func _run() -> void:
	if not ClassDB.class_exists("SubProcess"):
		printerr("SubProcess GDExtension is required")
		quit(2)
		return
	var bare_python := "python" if OS.get_name() == "Windows" else "python3"
	var python := OS.get_environment("PYTHON")
	if python.is_empty():
		python = bare_python
	var process = ClassDB.instantiate("SubProcess")
	root.add_child(process)
	check("missing executable fails synchronously",
		not process.start("minerva-subprocess-command-that-does-not-exist", PackedStringArray()))
	check("failed spawn does not publish a running child", not process.is_running())
	check("PATH lookup and argv survive native spawn", process.start(bare_python,
		PackedStringArray(["-c", "import sys; print(sys.argv[1])", "argument with spaces"])))
	var argv_until := Time.get_ticks_msec() + 3000
	while not process.has_output() and Time.get_ticks_msec() < argv_until:
		await create_timer(0.01).timeout
	check("spawned argv is byte-preserved", process.read_line() == "argument with spaces")
	process.stop()
	# The macOS Godot binary lives inside its app bundle, so it is not copied.
	if OS.get_name() != "macOS":
		var spaced_dir := OS.get_user_data_dir().path_join("sub process path")
		DirAccess.make_dir_recursive_absolute(spaced_dir)
		var godot := OS.get_executable_path()
		var copy := spaced_dir.path_join("godot copy" + ("." + godot.get_extension() if godot.get_extension() != "" else ""))
		var staged := DirAccess.copy_absolute(godot, copy) == OK
		if staged and OS.get_name() != "Windows":
			staged = FileAccess.set_unix_permissions(copy, 493) == OK  # rwxr-xr-x
		check("a copy of the engine is staged under a path with spaces", staged)
		check("an explicit path with spaces starts as given, with its arguments",
			staged and process.start(copy, PackedStringArray(["--headless", "--version"])))
		var version_until := Time.get_ticks_msec() + 10000
		while not process.has_output() and Time.get_ticks_msec() < version_until:
			await create_timer(0.05).timeout
		check("that child ran: it printed the engine version", process.read_line().begins_with("4."))
		process.stop()
		check("an explicit path that does not exist is refused",
			not process.start(spaced_dir.path_join("no such program"), PackedStringArray()))
		check("and publishes no running child", not process.is_running())
		DirAccess.remove_absolute(copy)
		DirAccess.remove_absolute(spaced_dir)
	check("blocking-child fixture starts", process.start(python,
		PackedStringArray(["-c", "import time; time.sleep(60)"])))
	check("large write is admitted without blocking the Godot caller",
		process.write_data("x".repeat(1024 * 1024)))
	await process_frame
	var stop_started := Time.get_ticks_msec()
	process.stop()
	check("full child stdin is interrupted and owned process stops within bound",
		Time.get_ticks_msec() - stop_started < 3000 and not process.is_running())

	var notifications := {"ready": 0, "overflow": 0}
	process.output_ready.connect(func(): notifications.ready += 1)
	process.io_overflow.connect(func(): notifications.overflow += 1)
	check("same native owner restarts after interrupted write", process.start(python,
		PackedStringArray(["-c", "import sys; [print(i) for i in range(100)]; sys.stdout.flush()"])))
	var until := Time.get_ticks_msec() + 3000
	while notifications.overflow == 0 and Time.get_ticks_msec() < until:
		await create_timer(0.01).timeout
	check("discarded output coalesces readiness and reports one fatal overflow",
		notifications.overflow == 1 and notifications.ready <= 2 and process.has_io_overflow())
	process.stop()
	process.queue_free()
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)
