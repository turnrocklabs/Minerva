class_name DockerDetector
extends RefCounted
## Detects Docker availability and platform capabilities.
## Cross-platform: Linux (native), macOS (Colima/Docker Desktop), Windows (Docker Desktop/WSL2).

signal detection_complete(result: Dictionary)

## Detection result structure:
## {
##   available: bool,        # Docker CLI found and daemon running
##   version: String,        # Docker version string
##   platform: String,       # "linux", "macos", "windows"
##   runtime: String,        # "native", "colima", "docker_desktop", "wsl2", "unknown"
##   gpu_available: bool,    # nvidia-container-toolkit detected
##   error: String,          # Empty if available, reason if not
## }


## Run full detection. Returns result dict and emits detection_complete.
func detect() -> Dictionary:
	var result := {
		"available": false,
		"version": "",
		"platform": _get_platform(),
		"runtime": "unknown",
		"gpu_available": false,
		"error": "",
	}

	# Step 1: Check docker CLI exists
	var version_result := _check_docker_cli()
	if not version_result.found:
		result.error = version_result.error
		detection_complete.emit(result)
		return result

	result.version = version_result.version

	# Step 2: Check daemon is running
	var daemon_result := _check_docker_daemon()
	if not daemon_result.running:
		result.error = daemon_result.error
		result.runtime = daemon_result.runtime
		detection_complete.emit(result)
		return result

	result.available = true
	result.runtime = daemon_result.runtime

	# Step 3: Check GPU support (non-blocking, optional)
	result.gpu_available = _check_gpu_support()

	detection_complete.emit(result)
	return result


func _get_platform() -> String:
	match OS.get_name():
		"macOS":
			return "macos"
		"Windows":
			return "windows"
		_:
			return "linux"


func _check_docker_cli() -> Dictionary:
	var output: Array = []
	var exit_code := OS.execute("docker", ["--version"], output, true)

	if exit_code != 0:
		# Try platform-specific paths
		var alt_paths := _get_docker_alt_paths()
		for path in alt_paths:
			exit_code = OS.execute(path, ["--version"], output, true)
			if exit_code == 0:
				break

	if exit_code != 0:
		return {"found": false, "version": "", "error": "Docker CLI not found. Install Docker to enable container features."}

	var version_str := ""
	if output.size() > 0:
		version_str = output[0].strip_edges()
		# Extract just the version number: "Docker version 24.0.7, build afdd53b" -> "24.0.7"
		var parts := version_str.split(",")[0].split(" ")
		if parts.size() >= 3:
			version_str = parts[2]

	return {"found": true, "version": version_str}


func _check_docker_daemon() -> Dictionary:
	var output: Array = []
	var exit_code := OS.execute("docker", ["info", "--format", "{{.ServerVersion}}"], output, true)

	if exit_code == 0:
		var runtime := _detect_runtime()
		return {"running": true, "runtime": runtime}

	# Daemon not running — provide platform-specific guidance
	var platform := _get_platform()
	var runtime := "unknown"
	var error := ""

	match platform:
		"macos":
			# Check if Colima is installed
			var colima_output: Array = []
			var colima_check := OS.execute("colima", ["status"], colima_output, true)
			if colima_check == 0:
				runtime = "colima"
				error = "Docker daemon not running. Start Colima with: colima start"
			else:
				# Check for Docker Desktop
				var desktop_check := OS.execute("docker", ["context", "ls"], colima_output, true)
				runtime = "docker_desktop"
				error = "Docker daemon not running. Start Docker Desktop or run: colima start"
		"windows":
			runtime = "docker_desktop"
			error = "Docker daemon not running. Start Docker Desktop and ensure WSL2 backend is enabled."
		_:
			runtime = "native"
			error = "Docker daemon not running. Start with: sudo systemctl start docker"

	return {"running": false, "runtime": runtime, "error": error}


func _detect_runtime() -> String:
	var platform := _get_platform()

	match platform:
		"linux":
			return "native"
		"macos":
			# Check active docker context for colima vs desktop
			var output: Array = []
			var exit_code := OS.execute("docker", ["context", "show"], output, true)
			if exit_code == 0 and output.size() > 0:
				var context: String = output[0].strip_edges()
				if "colima" in context.to_lower():
					return "colima"
			return "docker_desktop"
		"windows":
			return "docker_desktop"
		_:
			return "unknown"


func _check_gpu_support() -> bool:
	# Only relevant on Linux (and Windows with WSL2 GPU passthrough)
	var platform := _get_platform()
	if platform == "macos":
		return false  # No GPU passthrough on macOS containers

	# Try running a minimal container with --gpus flag
	var output: Array = []
	var exit_code := OS.execute(
		"docker", ["run", "--rm", "--gpus", "all", "hello-world"],
		output, true
	)

	# If that fails, check if nvidia-container-toolkit is installed without pulling an image
	if exit_code != 0:
		var toolkit_output: Array = []
		exit_code = OS.execute("nvidia-container-cli", ["--version"], toolkit_output, true)
		return exit_code == 0

	return true


func _get_docker_alt_paths() -> Array[String]:
	var paths: Array[String] = []
	match OS.get_name():
		"macOS":
			paths.append("/usr/local/bin/docker")
			paths.append("/opt/homebrew/bin/docker")
		"Windows":
			paths.append("C:\\Program Files\\Docker\\Docker\\resources\\bin\\docker.exe")
		_:
			paths.append("/usr/bin/docker")
	return paths
