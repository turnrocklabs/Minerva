class_name BashTool
extends RefCounted
## Execute shell commands with policy enforcement. Ported from CodeTools bash.py.

const DEFAULT_TIMEOUT_MS: int = 120000  # 2 minutes
const MAX_TIMEOUT_MS: int = 600000      # 10 minutes
const MAX_OUTPUT: int = 30000           # max chars in output


static func run_command(command: String, working_dir: String = "",
		timeout_ms: int = DEFAULT_TIMEOUT_MS) -> Dictionary:
	## Execute a bash command. Returns {stdout, stderr, exit_code, timed_out}.
	## Policy is checked before execution — call check_policy() first or use run_checked().

	if working_dir.is_empty():
		working_dir = OS.get_environment("PWD")
		if working_dir.is_empty():
			working_dir = "."

	timeout_ms = mini(timeout_ms, MAX_TIMEOUT_MS)

	var output: Array = []
	var exit_code: int = OS.execute("bash", ["-c", "cd %s && %s" % [working_dir.c_escape(), command]], output, true, false)

	var stdout: String = output[0] if output.size() > 0 else ""
	# OS.execute merges stdout+stderr. Separate them via shell redirect if needed.
	var stderr: String = ""

	# Truncate
	if stdout.length() > MAX_OUTPUT:
		stdout = stdout.substr(0, MAX_OUTPUT) + "\n... [output truncated]"

	return {
		"stdout": stdout,
		"stderr": stderr,
		"exit_code": exit_code,
		"timed_out": false,  # OS.execute is blocking; timeout not supported natively
	}


static func run_checked(command: String, working_dir: String = "",
		timeout_ms: int = DEFAULT_TIMEOUT_MS) -> Dictionary:
	## Execute with policy check. Returns error dict if denied.
	var policy_error: String = CodeToolsPolicy.get_instance().check_bash_command(command)
	if not policy_error.is_empty():
		return {"success": false, "error": policy_error, "exit_code": -1}

	var result := run_command(command, working_dir, timeout_ms)
	result["success"] = result["exit_code"] == 0
	return result
