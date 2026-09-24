class_name BoundedProcess
extends RefCounted
## Runs an external command for at most a given time without blocking a
## frame, for probes that may hang (an app-execution alias, a slow conda).
## Await run(); the caller's frames keep going while it waits.


## Run `command` with `args` for at most `timeout_s`: each frame drains its
## output pipes and checks whether it has exited; one still running at the
## deadline is killed. Returns {exit_code, output, pid} with stdout then
## stderr, read as UTF-8; exit_code is non-zero when it could not start (-1
## when not even spawned, and then pid is -1) or was killed (-1).
static func run(command: String, args: PackedStringArray, timeout_s: float) -> Dictionary:
	var spawned: Dictionary = OS.execute_with_pipe(command, args, false)
	if spawned.is_empty():
		return {"exit_code": -1, "output": "", "pid": -1}
	var pid: int = spawned.pid
	var stdout := PackedByteArray()
	var stderr := PackedByteArray()
	var tree := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while OS.is_process_running(pid):
		stdout.append_array(_drain(spawned.stdio))
		stderr.append_array(_drain(spawned.stderr))
		if Time.get_ticks_msec() >= deadline:
			OS.kill(pid)
			return {"exit_code": -1, "output": "", "pid": pid}
		await tree.process_frame
	stdout.append_array(_drain(spawned.stdio))
	stderr.append_array(_drain(spawned.stderr))
	stdout.append_array(stderr)
	return {"exit_code": OS.get_process_exit_code(pid), "output": stdout.get_string_from_utf8(), "pid": pid}


## Whatever `pipe` holds now, without waiting for more.
static func _drain(pipe: FileAccess) -> PackedByteArray:
	var available := pipe.get_length()
	return pipe.get_buffer(available) if available > 0 else PackedByteArray()
