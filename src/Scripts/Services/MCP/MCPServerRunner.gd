class_name MCPServerRunner
extends RefCounted
## Manages running MCP server processes.
## Handles starting, stopping, and monitoring server processes.

signal server_started(server_name: String, pid: int)
signal server_stopped(server_name: String)
signal server_error(server_name: String, error: String)

const MCPServerInstallerScript := preload("res://Scripts/Services/MCP/MCPServerInstaller.gd")

## Track running server processes by name -> PID
var _running_servers: Dictionary = {}

## Path to PID files directory
var _pid_dir: String = ""


func _init() -> void:
	# Create PID directory in user data
	_pid_dir = OS.get_user_data_dir().path_join("mcp_pids")
	if not DirAccess.dir_exists_absolute(_pid_dir):
		DirAccess.make_dir_recursive_absolute(_pid_dir)

	# Load any existing PIDs from files
	_load_saved_pids()


## Check if a server process is running
func is_server_running(server_name: String) -> bool:
	if not _running_servers.has(server_name):
		return false

	# On Unix, check the actual PID file (the server PID, not shell PID)
	if OS.get_name() != "Windows":
		var actual_pid_file := _pid_dir.path_join(server_name + "_actual.pid")
		if FileAccess.file_exists(actual_pid_file):
			var file := FileAccess.open(actual_pid_file, FileAccess.READ)
			if file:
				var pid_str := file.get_as_text().strip_edges()
				file.close()
				if pid_str.is_valid_int():
					var actual_pid := pid_str.to_int()
					if _is_process_running(actual_pid):
						# Update our stored PID with the actual one
						_running_servers[server_name] = actual_pid
						return true
					else:
						# Server died, clean up
						_running_servers.erase(server_name)
						DirAccess.remove_absolute(actual_pid_file)
						_remove_pid_file(server_name)
						return false

	# Fall back to stored PID (Windows or if actual file not found yet)
	var pid: int = _running_servers[server_name]
	return _is_process_running(pid)


## Get the PID of a running server
func get_server_pid(server_name: String) -> int:
	# On Unix, try to get actual PID from file first
	if OS.get_name() != "Windows":
		var actual_pid_file := _pid_dir.path_join(server_name + "_actual.pid")
		if FileAccess.file_exists(actual_pid_file):
			var file := FileAccess.open(actual_pid_file, FileAccess.READ)
			if file:
				var pid_str := file.get_as_text().strip_edges()
				file.close()
				if pid_str.is_valid_int():
					return pid_str.to_int()
	return _running_servers.get(server_name, 0)


## Start a server process
func start_server(server_name: String) -> Error:
	if is_server_running(server_name):
		server_error.emit(server_name, "Server already running")
		return ERR_ALREADY_IN_USE

	# Get installation path from config
	var config := MCPConfig.new()
	config.load_config()
	var install_path := config.get_installation_path(server_name)

	if install_path.is_empty():
		server_error.emit(server_name, "Server not installed")
		return ERR_FILE_NOT_FOUND

	# Get startup command
	var installer := MCPServerInstallerScript.new()
	var cmd_info: Dictionary = installer.get_startup_command(server_name, install_path)

	if cmd_info.is_empty():
		server_error.emit(server_name, "Unknown server: " + server_name)
		return ERR_INVALID_PARAMETER

	var command: String = cmd_info.get("command", "")
	var args: Array = cmd_info.get("args", [])
	var cwd: String = cmd_info.get("cwd", "")

	if command.is_empty():
		server_error.emit(server_name, "No command for server")
		return ERR_INVALID_PARAMETER

	# Convert args to PackedStringArray
	var packed_args := PackedStringArray()
	for arg in args:
		packed_args.append(str(arg))

	# Start the process
	var pid := _start_background_process(server_name, command, packed_args, cwd)

	if pid <= 0:
		server_error.emit(server_name, "Failed to start process")
		return ERR_CANT_CREATE

	_running_servers[server_name] = pid
	_save_pid(server_name, pid)

	server_started.emit(server_name, pid)
	return OK


## Stop a server process
func stop_server(server_name: String) -> Error:
	if not _running_servers.has(server_name):
		server_error.emit(server_name, "Server not running")
		return ERR_DOES_NOT_EXIST

	# On Unix, get actual PID from file (not shell PID)
	var pid: int = _running_servers[server_name]
	if OS.get_name() != "Windows":
		var actual_pid_file := _pid_dir.path_join(server_name + "_actual.pid")
		if FileAccess.file_exists(actual_pid_file):
			var file := FileAccess.open(actual_pid_file, FileAccess.READ)
			if file:
				var pid_str := file.get_as_text().strip_edges()
				file.close()
				if pid_str.is_valid_int():
					pid = pid_str.to_int()
			# Clean up actual PID file
			DirAccess.remove_absolute(actual_pid_file)

	if not _kill_process(pid):
		server_error.emit(server_name, "Failed to stop process")
		return ERR_CANT_RESOLVE

	_running_servers.erase(server_name)
	_remove_pid_file(server_name)

	server_stopped.emit(server_name)
	return OK


## Stop all running servers
func stop_all_servers() -> void:
	var servers_to_stop := _running_servers.keys().duplicate()
	for server_name in servers_to_stop:
		stop_server(server_name)


## Get list of running server names
func get_running_servers() -> Array[String]:
	var running: Array[String] = []
	for server_name in _running_servers:
		if is_server_running(server_name):
			running.append(server_name)
	return running


## Start a background process and return its PID
func _start_background_process(server_name: String, command: String, args: PackedStringArray, cwd: String) -> int:
	match OS.get_name():
		"Windows":
			# Windows: use cmd /c start
			var full_args := PackedStringArray()
			full_args.append("/c")
			full_args.append("cd")
			full_args.append("/d")
			full_args.append(cwd)
			full_args.append("&&")
			full_args.append("start")
			full_args.append("/b")
			full_args.append(command)
			for arg in args:
				full_args.append(arg)
			return OS.create_process("cmd", full_args)
		_:
			# Unix: Create a wrapper script that launches the server and records PID
			# We write the actual server PID to a file so we can track it later
			var actual_pid_file := _pid_dir.path_join(server_name + "_actual.pid")

			# Build a shell command that:
			# 1. Changes to working directory
			# 2. Launches server with nohup, redirecting output
			# 3. Writes the server PID to a file
			# 4. Shell exits immediately, server keeps running
			var shell_script := "cd '%s' && nohup '%s'" % [cwd, command]
			for arg in args:
				shell_script += " '%s'" % arg
			shell_script += " > /dev/null 2>&1 & echo $! > '%s'" % actual_pid_file

			# Launch shell with create_process (non-blocking)
			var shell_pid := OS.create_process("/bin/sh", ["-c", shell_script])
			if shell_pid <= 0:
				return -1

			# Return shell PID initially - is_server_running will check actual PID file
			return shell_pid


## Check if a process is running by PID
func _is_process_running(pid: int) -> bool:
	if pid <= 0:
		return false

	match OS.get_name():
		"Windows":
			var output: Array = []
			var exit_code := OS.execute("tasklist", ["/FI", "PID eq %d" % pid], output, true)
			if exit_code == 0 and output.size() > 0:
				return str(output[0]).contains(str(pid))
			return false
		_:
			# Unix: use kill -0 to check if process exists
			var exit_code := OS.execute("kill", ["-0", str(pid)], [], true)
			return exit_code == 0


## Kill a process by PID
func _kill_process(pid: int) -> bool:
	if pid <= 0:
		return false

	match OS.get_name():
		"Windows":
			var exit_code := OS.execute("taskkill", ["/PID", str(pid), "/F"], [], true)
			return exit_code == 0
		_:
			# Unix: send SIGTERM first, then SIGKILL if needed
			var exit_code := OS.execute("kill", [str(pid)], [], true)
			if exit_code != 0:
				exit_code = OS.execute("kill", ["-9", str(pid)], [], true)
			return exit_code == 0


## Save PID to file for persistence
func _save_pid(server_name: String, pid: int) -> void:
	var pid_file := _pid_dir.path_join(server_name + ".pid")
	var file := FileAccess.open(pid_file, FileAccess.WRITE)
	if file:
		file.store_string(str(pid))
		file.close()


## Remove PID file
func _remove_pid_file(server_name: String) -> void:
	var pid_file := _pid_dir.path_join(server_name + ".pid")
	if FileAccess.file_exists(pid_file):
		DirAccess.remove_absolute(pid_file)


## Load saved PIDs from files
func _load_saved_pids() -> void:
	var dir := DirAccess.open(_pid_dir)
	if not dir:
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".pid"):
			var server_name := file_name.replace(".pid", "")
			var pid_file := _pid_dir.path_join(file_name)
			var file := FileAccess.open(pid_file, FileAccess.READ)
			if file:
				var pid_str := file.get_as_text().strip_edges()
				file.close()
				if pid_str.is_valid_int():
					var pid := pid_str.to_int()
					if _is_process_running(pid):
						_running_servers[server_name] = pid
					else:
						# Process no longer running, clean up PID file
						_remove_pid_file(server_name)
		file_name = dir.get_next()
	dir.list_dir_end()
