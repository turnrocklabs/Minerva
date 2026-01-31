class_name MCPServerInstaller
extends RefCounted
## Handles installation of MCP servers from GitHub repositories.
## Supports cross-platform installation on macOS, Linux, and Windows.

signal progress_updated(percent: float, message: String)
signal log_message(text: String, is_error: bool)
signal installation_finished(success: bool, results: Dictionary)

const REPOS := {
	"nudge": "https://github.com/ipeerbhai/nudge.git",
	"cobrowser": "https://github.com/ipeerbhai/HumanWeb.git",
	"codetools": "https://github.com/ipeerbhai/codetools.git"
}

const PORTS := {
	"nudge": 8765,
	"cobrowser": 8678,  # MCP wrapper (mcp_tools.py) - connects to cobrowser_service on 8677
	"codetools": 8700
}

const SERVER_DESCRIPTIONS := {
	"nudge": "Nudge - Session-scoped hint cache for storing micro-facts",
	"cobrowser": "CoBrowser - Browser automation through Firefox extension",
	"codetools": "CodeTools - Code manipulation and analysis tools"
}

var _is_installing := false


func is_installing() -> bool:
	return _is_installing


## Check if required prerequisites are available
func check_prerequisites() -> Dictionary:
	var results := {
		"python": {"available": false, "version": "", "path": ""},
		"git": {"available": false, "version": ""},
		"firefox": {"available": false, "path": ""}
	}

	# Check Python
	var python_result := _check_python()
	results.python = python_result

	# Check Git
	var git_result := _check_git()
	results.git = git_result

	# Check Firefox (needed for cobrowser)
	var firefox_result := _check_firefox()
	results.firefox = firefox_result

	return results


func _check_python() -> Dictionary:
	var result := {"available": false, "version": "", "path": ""}

	# Try multiple Python executables, in order of preference
	var python_candidates: Array[String] = _get_python_candidates()

	for python_cmd in python_candidates:
		var output: Array = []
		var exit_code := OS.execute(python_cmd, ["--version"], output, true)

		if exit_code == 0 and output.size() > 0:
			var version_str: String = output[0].strip_edges()
			if version_str.begins_with("Python "):
				var clean_version: String = version_str.replace("Python ", "")

				# Check if version is 3.11+
				var version_parts: PackedStringArray = clean_version.split(".")
				if version_parts.size() >= 2:
					var major: int = version_parts[0].to_int()
					var minor: int = version_parts[1].to_int()
					if major >= 3 and minor >= 11:
						result.available = true
						result.version = clean_version
						result.path = python_cmd
						return result
					elif not result.available:
						# Store first found Python even if too old
						result.version = clean_version + " (need 3.11+)"

	return result


func _get_python_candidates() -> Array[String]:
	var candidates: Array[String] = []

	match OS.get_name():
		"Windows":
			candidates.append("python")
			candidates.append("python3")
			candidates.append("py")
		"macOS":
			# Try versioned Python first (Homebrew installs these)
			candidates.append("python3.13")
			candidates.append("python3.12")
			candidates.append("python3.11")
			# Homebrew paths
			candidates.append("/opt/homebrew/bin/python3")
			candidates.append("/usr/local/bin/python3")
			# Generic
			candidates.append("python3")
		_:  # Linux
			candidates.append("python3.13")
			candidates.append("python3.12")
			candidates.append("python3.11")
			candidates.append("python3")

	return candidates


func _check_git() -> Dictionary:
	var result := {"available": false, "version": ""}

	var output: Array = []
	var exit_code := OS.execute("git", ["--version"], output, true)

	if exit_code == 0 and output.size() > 0:
		result.available = true
		result.version = output[0].strip_edges()

	return result


func _check_firefox() -> Dictionary:
	var result := {"available": false, "path": ""}

	match OS.get_name():
		"Windows":
			# Check common installation paths
			var paths := [
				"C:\\Program Files\\Mozilla Firefox\\firefox.exe",
				"C:\\Program Files (x86)\\Mozilla Firefox\\firefox.exe"
			]
			for path in paths:
				if FileAccess.file_exists(path):
					result.available = true
					result.path = path
					break
		"macOS":
			var app_path := "/Applications/Firefox.app"
			if DirAccess.dir_exists_absolute(app_path):
				result.available = true
				result.path = app_path + "/Contents/MacOS/firefox"
		"Linux":
			var output: Array = []
			var exit_code := OS.execute("which", ["firefox"], output, true)
			if exit_code == 0 and output.size() > 0:
				result.available = true
				result.path = output[0].strip_edges()

	return result


## Install selected MCP servers to the specified base directory
func install_servers(base_path: String, servers: Array) -> Dictionary:
	if _is_installing:
		return {"success": false, "error": "Installation already in progress"}

	_is_installing = true
	var results := {
		"success": true,
		"servers": {},
		"errors": []
	}

	# Ensure base directory exists
	if not DirAccess.dir_exists_absolute(base_path):
		var err := DirAccess.make_dir_recursive_absolute(base_path)
		if err != OK:
			_is_installing = false
			results.success = false
			results.errors.append("Failed to create directory: %s" % base_path)
			installation_finished.emit(false, results)
			return results

	var total_steps := servers.size() * 3  # clone, venv, install per server
	var current_step := 0

	for server in servers:
		if not REPOS.has(server):
			results.errors.append("Unknown server: %s" % server)
			continue

		var server_dir := base_path.path_join(_get_server_folder_name(server))
		var server_result := {"installed": false, "path": "", "error": ""}

		# Step 1: Clone repository
		current_step += 1
		progress_updated.emit(float(current_step) / total_steps * 100.0,
			"Cloning %s repository..." % server)
		log_message.emit("Cloning %s from %s" % [server, REPOS[server]], false)

		var clone_success := _clone_repo(REPOS[server], server_dir)
		if not clone_success:
			server_result.error = "Failed to clone repository"
			results.servers[server] = server_result
			results.errors.append("%s: Failed to clone" % server)
			log_message.emit("ERROR: Failed to clone %s" % server, true)
			continue

		# Step 2: Create virtual environment
		current_step += 1
		progress_updated.emit(float(current_step) / total_steps * 100.0,
			"Creating virtual environment for %s..." % server)
		log_message.emit("Creating virtual environment in %s" % server_dir, false)

		var venv_success := _create_venv(server_dir)
		if not venv_success:
			server_result.error = "Failed to create virtual environment"
			results.servers[server] = server_result
			results.errors.append("%s: Failed to create venv" % server)
			log_message.emit("ERROR: Failed to create venv for %s" % server, true)
			continue

		# Step 3: Install package
		current_step += 1
		progress_updated.emit(float(current_step) / total_steps * 100.0,
			"Installing %s package..." % server)
		log_message.emit("Installing package with pip...", false)

		var install_success := _install_package(server_dir, server)
		if not install_success:
			server_result.error = "Failed to install package"
			results.servers[server] = server_result
			results.errors.append("%s: Failed to install" % server)
			log_message.emit("ERROR: Failed to install %s" % server, true)
			continue

		# Success
		server_result.installed = true
		server_result.path = server_dir
		results.servers[server] = server_result
		log_message.emit("Successfully installed %s" % server, false)

	# Check if any servers failed
	for server in results.servers:
		if not results.servers[server].installed:
			results.success = false
			break

	progress_updated.emit(100.0, "Installation complete")
	_is_installing = false
	installation_finished.emit(results.success, results)

	return results


func _get_server_folder_name(server: String) -> String:
	match server:
		"cobrowser":
			return "HumanWeb"
		_:
			return server


func _clone_repo(repo_url: String, target_dir: String) -> bool:
	# Check if directory already exists with a .git folder
	if DirAccess.dir_exists_absolute(target_dir.path_join(".git")):
		log_message.emit("Repository already exists, pulling latest...", false)
		# Try to pull latest
		var pull_output: Array = []
		var pull_exit_code := OS.execute("git", ["-C", target_dir, "pull"], pull_output, true)
		if pull_output.size() > 0:
			log_message.emit(pull_output[0].strip_edges(), false)
		return pull_exit_code == 0

	# Clone fresh
	var output: Array = []
	var exit_code := OS.execute("git", ["clone", repo_url, target_dir], output, true)

	if output.size() > 0:
		for line in output:
			log_message.emit(line.strip_edges(), exit_code != 0)

	return exit_code == 0


func _create_venv(server_dir: String) -> bool:
	var python := _get_python_executable()
	var venv_path := server_dir.path_join(".venv")

	# Check if venv already exists
	if DirAccess.dir_exists_absolute(venv_path):
		log_message.emit("Virtual environment already exists", false)
		return true

	var output: Array = []
	var exit_code := OS.execute(python, ["-m", "venv", venv_path], output, true)

	if output.size() > 0:
		for line in output:
			log_message.emit(line.strip_edges(), exit_code != 0)

	return exit_code == 0


func _install_package(server_dir: String, server_name: String = "") -> bool:
	var pip := _get_pip_in_venv(server_dir)

	# First upgrade pip
	var output: Array = []
	var exit_code := OS.execute(pip, ["install", "--upgrade", "pip"], output, true)
	if output.size() > 0:
		log_message.emit("Upgrading pip...", false)

	# Determine installation method based on server
	output = []
	if server_name == "cobrowser":
		# HumanWeb uses requirements.txt in src/ directory
		var requirements_path := server_dir.path_join("src").path_join("requirements.txt")
		if FileAccess.file_exists(requirements_path):
			log_message.emit("Installing from requirements.txt...", false)
			exit_code = OS.execute(pip, ["install", "-r", requirements_path], output, true)
		else:
			log_message.emit("ERROR: requirements.txt not found at " + requirements_path, true)
			return false
	else:
		# Standard editable install for nudge and codetools
		exit_code = OS.execute(pip, ["install", "-e", server_dir], output, true)

	if output.size() > 0:
		for line in output:
			var trimmed: String = str(line).strip_edges()
			if not trimmed.is_empty():
				log_message.emit(trimmed, exit_code != 0)

	return exit_code == 0


func _get_python_executable() -> String:
	# Find a suitable Python 3.11+ executable
	var candidates: Array[String] = _get_python_candidates()

	for python_cmd in candidates:
		var output: Array = []
		var exit_code := OS.execute(python_cmd, ["--version"], output, true)

		if exit_code == 0 and output.size() > 0:
			var version_str: String = output[0].strip_edges()
			if version_str.begins_with("Python "):
				var clean_version: String = version_str.replace("Python ", "")
				var version_parts: PackedStringArray = clean_version.split(".")
				if version_parts.size() >= 2:
					var major: int = version_parts[0].to_int()
					var minor: int = version_parts[1].to_int()
					if major >= 3 and minor >= 11:
						return python_cmd

	# Fallback to generic python3
	match OS.get_name():
		"Windows":
			return "python"
		_:
			return "python3"


func _get_pip_in_venv(server_dir: String) -> String:
	var venv_path := server_dir.path_join(".venv")
	match OS.get_name():
		"Windows":
			return venv_path.path_join("Scripts").path_join("pip.exe")
		_:
			return venv_path.path_join("bin").path_join("pip")


func _get_python_in_venv(server_dir: String) -> String:
	var venv_path := server_dir.path_join(".venv")
	match OS.get_name():
		"Windows":
			return venv_path.path_join("Scripts").path_join("python.exe")
		_:
			return venv_path.path_join("bin").path_join("python")


## Get the command to start a server
func get_startup_command(server: String, install_path: String) -> Dictionary:
	if install_path.is_empty():
		return {}

	var python := _get_python_in_venv(install_path)

	match server:
		"nudge":
			return {
				"command": python,
				"args": ["-m", "nudge", "serve"],
				"cwd": install_path,
				"port": PORTS.nudge
			}
		"cobrowser":
			return {
				"command": python,
				"args": ["-m", "uvicorn", "src.Library.mcp_tools:app",
						"--host", "0.0.0.0", "--port", str(PORTS.cobrowser)],
				"cwd": install_path,
				"port": PORTS.cobrowser
			}
		"codetools":
			return {
				"command": python,
				"args": ["-m", "codetools", "serve", "--port", str(PORTS.codetools)],
				"cwd": install_path,
				"port": PORTS.codetools
			}

	return {}


## Get platform-specific installation instructions for missing prerequisites
static func get_install_instructions(prerequisite: String) -> String:
	match prerequisite:
		"python":
			match OS.get_name():
				"macOS":
					return "Install Python 3.11+ from python.org or via Homebrew:\n  brew install python@3.11"
				"Linux":
					return "Install Python 3.11+:\n  sudo apt install python3.11 python3.11-venv  (Debian/Ubuntu)\n  sudo dnf install python3.11  (Fedora)"
				"Windows":
					return "Install Python 3.11+ from python.org\nMake sure to check 'Add Python to PATH' during installation"
		"git":
			match OS.get_name():
				"macOS":
					return "Install Git via Xcode Command Line Tools:\n  xcode-select --install\nor via Homebrew:\n  brew install git"
				"Linux":
					return "Install Git:\n  sudo apt install git  (Debian/Ubuntu)\n  sudo dnf install git  (Fedora)"
				"Windows":
					return "Install Git from git-scm.com"
		"firefox":
			match OS.get_name():
				"macOS":
					return "Install Firefox from mozilla.org or:\n  brew install --cask firefox"
				"Linux":
					return "Install Firefox:\n  sudo apt install firefox  (Debian/Ubuntu)\n  sudo dnf install firefox  (Fedora)"
				"Windows":
					return "Install Firefox from mozilla.org"

	return "Please install %s manually" % prerequisite
