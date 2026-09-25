extends SceneTree
## SubProcess.start_with_env gives one child environment entries of its own:
## that child sees the entry (a random value with non-ASCII characters, read
## back byte for byte) and still has the environment it inherits; this
## process and a second child started after it do not have it; an invalid
## name is refused. The child is the host Python (PYTHON, or python3 /
## python), printing the entry as UTF-8 hex so no console encoding is
## involved. A failure prints lengths, never the value.

const NAME := "MINERVA_TEST_CHILD_ENV"

var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		passed += 1
		print("PASS: %s" % label)
	else:
		failed += 1
		printerr("FAIL: %s%s" % [label, (" — " + detail) if detail != "" else ""])


func _python() -> String:
	var python := OS.get_environment("PYTHON")
	return python if not python.is_empty() else ("python" if OS.get_name() == "Windows" else "python3")


# The child's two lines: the entry's UTF-8 as hex ("-" when unset), and
# whether it has PATH.
func _child_lines(process, extra_env: Dictionary) -> Array:
	var python := _python()
	var script := "import os; v = os.environ.get('%s'); print(v.encode('utf-8').hex() if v is not None else '-'); print('path' if 'PATH' in os.environ or 'Path' in os.environ else 'nopath')" % NAME
	var args := PackedStringArray(["-c", script])
	var started: bool = process.start_with_env(python, args, extra_env) if not extra_env.is_empty() \
		else process.start(python, args)
	if not started:
		return []
	var lines: Array = []
	var until := Time.get_ticks_msec() + 10000
	while lines.size() < 2 and Time.get_ticks_msec() < until:
		if process.has_output():
			lines.append(str(process.read_line()).strip_edges())
		else:
			await create_timer(0.02).timeout
	process.stop()
	return lines


func _run() -> void:
	if not ClassDB.class_exists("SubProcess"):
		printerr("SubProcess GDExtension is required")
		quit(2)
		return
	var process = ClassDB.instantiate("SubProcess")
	root.add_child(process)
	check("the extension offers start_with_env and os_account_name",
		process.has_method("start_with_env") and process.has_method("os_account_name"))
	check("this process has no such entry to begin with", OS.get_environment(NAME).is_empty())
	var value := Crypto.new().generate_random_bytes(16).hex_encode() + "-é✓日本"
	var expected := value.to_utf8_buffer().hex_encode()

	var given := await _child_lines(process, {NAME: value})
	check("the child given the entry sees it byte for byte, and keeps its inherited PATH",
		given.size() == 2 and given[0] == expected and given[1] == "path",
		"got %d lines, entry %d hex chars (want %d)" % [given.size(), str(given[0]).length() if given.size() > 0 else 0, expected.length()])
	check("this process's environment is unchanged", OS.get_environment(NAME).is_empty())
	var plain := await _child_lines(process, {})
	check("a child started after it without the entry does not see it", plain.size() == 2 and plain[0] == "-" and plain[1] == "path",
		"got %d lines" % plain.size())
	# The same interpreter that just ran, so only the name can refuse the start.
	var probe := PackedStringArray(["-c", "pass"])
	check("an entry named with '=' is refused", given.size() == 2 and not process.start_with_env(_python(), probe, {"A=B": "x"}))
	process.stop()  # so a start the check wrongly allowed cannot make the next refuse
	check("an entry with an empty name is refused", given.size() == 2 and not process.start_with_env(_python(), probe, {"": "x"}))
	process.stop()
	check("the OS account is named", not str(process.os_account_name()).is_empty())
	process.queue_free()
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)
