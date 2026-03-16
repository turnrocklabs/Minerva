class_name DockerManager
extends RefCounted
## Manages Docker containers for Minerva.
## Handles detection, building, starting, stopping, and health monitoring.

const DockerDetectorScript = preload("res://Scripts/Services/Docker/DockerDetector.gd")
const ContainerDefinitionScript = preload("res://Scripts/Services/Docker/ContainerDefinition.gd")

signal docker_status_changed(status: Dictionary)
signal container_status_changed(container_name: String, state: String)
signal build_progress(container_name: String, line: String)
signal build_complete(container_name: String, success: bool, error: String)
signal container_started(container_name: String)
signal container_stopped(container_name: String)
signal container_health_changed(container_name: String, healthy: bool)

const MAX_HEALTH_FAILURES := 3
const STOP_TIMEOUT_SECONDS := 5

var docker_status: Dictionary = {}
var _definitions: Dictionary = {}
var _container_states: Dictionary = {}
var _health_failures: Dictionary = {}
var _build_pids: Dictionary = {}
var _build_log_paths: Dictionary = {}
var _log_dir: String = ""
var _config_path: String = ""
var _detector: RefCounted
var _builtin_names: Array[String] = []  # names registered by code, not user


func _init() -> void:
	_detector = DockerDetectorScript.new()
	_log_dir = OS.get_user_data_dir().path_join("docker_logs")
	_config_path = OS.get_user_data_dir().path_join("docker_containers.json")
	if not DirAccess.dir_exists_absolute(_log_dir):
		DirAccess.make_dir_recursive_absolute(_log_dir)
	_load_custom_containers()


# ── Detection ───────────────────────────────────────────────────────────

func detect() -> Dictionary:
	docker_status = _detector.detect()
	docker_status_changed.emit(docker_status)
	return docker_status

func is_available() -> bool:
	return docker_status.get("available", false)

func is_gpu_available() -> bool:
	return docker_status.get("gpu_available", false)


# ── Registration ────────────────────────────────────────────────────────

func register(definition: Resource, builtin: bool = false) -> void:
	var cname: String = definition.container_name
	_definitions[cname] = definition
	if builtin:
		_builtin_names.append(cname)
	if is_running(definition):
		_set_state(cname, "running")
	else:
		_set_state(cname, "stopped")

func register_custom(display_name: String, image_name: String,
		dockerfile_path: String, build_context: String,
		ports: Dictionary = {}, health_endpoint: String = "",
		gpu_optional: bool = false, environment: Dictionary = {}) -> Resource:
	var def: Resource = ContainerDefinitionScript.new()
	def.display_name = display_name
	def.image_name = image_name
	def.dockerfile_path = dockerfile_path
	def.build_context = build_context
	def.ports = ports
	def.health_endpoint = health_endpoint
	def.gpu_optional = gpu_optional
	def.environment = environment
	register(def, false)
	_save_custom_containers()
	return def

func remove_container(definition: Resource) -> bool:
	var cname: String = definition.container_name
	if cname in _builtin_names:
		return false  # Can't remove builtin containers
	if is_running(definition):
		stop_container(definition)
	# Remove docker image
	OS.execute("docker", ["rmi", "-f", definition.image_name], [], true)
	_definitions.erase(cname)
	_container_states.erase(cname)
	_health_failures.erase(cname)
	_save_custom_containers()
	return true

func is_builtin(definition: Resource) -> bool:
	return definition.container_name in _builtin_names

func get_definitions() -> Array:
	return _definitions.values()


# ── Image Building ──────────────────────────────────────────────────────

func is_image_built(definition: Resource) -> bool:
	var output: Array = []
	var exit_code: int = OS.execute("docker", ["images", "-q", definition.image_name], output, true)
	return exit_code == 0 and output.size() > 0 and output[0].strip_edges() != ""

func build_image(definition: Resource) -> bool:
	if not is_available():
		build_complete.emit(definition.container_name, false, "Docker not available")
		return false

	if get_state(definition) == "building":
		return false

	var cname: String = definition.container_name
	_set_state(cname, "building")

	var log_path: String = _log_dir.path_join("%s_build.log" % cname)
	_build_log_paths[cname] = log_path

	var build_cmd: String = "docker build -t '%s'" % definition.image_name
	if definition.dockerfile_path != "":
		build_cmd += " -f '%s'" % definition.dockerfile_path
	build_cmd += " '%s'" % definition.build_context
	build_cmd += " > '%s' 2>&1; echo \"EXIT_CODE:$?\" >> '%s'" % [log_path, log_path]

	var f: FileAccess = FileAccess.open(log_path, FileAccess.WRITE)
	if f:
		f.close()

	var pid: int
	match OS.get_name():
		"Windows":
			pid = OS.create_process("cmd", PackedStringArray(["/c", build_cmd]))
		_:
			pid = OS.create_process("/bin/sh", PackedStringArray(["-c", build_cmd]))

	if pid <= 0:
		_set_state(cname, "error")
		build_complete.emit(cname, false, "Failed to start build process")
		return false

	_build_pids[cname] = pid
	return true

func poll_build(definition: Resource) -> bool:
	var cname: String = definition.container_name
	if get_state(definition) != "building":
		return false

	var log_path: String = _build_log_paths.get(cname, "")
	if log_path == "" or not FileAccess.file_exists(log_path):
		return true

	var f: FileAccess = FileAccess.open(log_path, FileAccess.READ)
	if not f:
		return true

	var content: String = f.get_as_text()
	f.close()

	var lines: PackedStringArray = content.split("\n")
	for line in lines:
		var trimmed: String = line.strip_edges()
		if trimmed != "" and not trimmed.begins_with("EXIT_CODE:"):
			build_progress.emit(cname, trimmed)

	if "EXIT_CODE:" in content:
		var exit_line: String = ""
		for i in range(lines.size() - 1, -1, -1):
			if lines[i].strip_edges().begins_with("EXIT_CODE:"):
				exit_line = lines[i].strip_edges()
				break

		var exit_code: int = exit_line.replace("EXIT_CODE:", "").to_int()
		_build_pids.erase(cname)

		if exit_code == 0:
			_set_state(cname, "stopped")
			build_complete.emit(cname, true, "")
		else:
			_set_state(cname, "error")
			build_complete.emit(cname, false, "Build failed (exit code %d). See log: %s" % [exit_code, log_path])
		return false

	return true

func get_build_log_path(definition: Resource) -> String:
	return _build_log_paths.get(definition.container_name, "")


# ── Container Lifecycle ─────────────────────────────────────────────────

func is_running(definition: Resource) -> bool:
	var output: Array = []
	var exit_code: int = OS.execute(
		"docker", ["ps", "-q", "-f", "name=%s" % definition.container_name],
		output, true
	)
	return exit_code == 0 and output.size() > 0 and output[0].strip_edges() != ""

func start_container(definition: Resource) -> bool:
	if not is_available():
		return false

	var cname: String = definition.container_name
	_force_remove(cname)

	var args: PackedStringArray = PackedStringArray()
	args.append("run")
	args.append("-d")
	args.append("--name")
	args.append(cname)

	for host_port in definition.ports:
		var container_port: int = definition.ports[host_port]
		args.append("-p")
		args.append("%d:%d" % [host_port, container_port])

	if definition.gpu_optional and is_gpu_available():
		args.append("--gpus")
		args.append("all")

	for key in definition.environment:
		args.append("-e")
		args.append("%s=%s" % [key, definition.environment[key]])

	args.append(definition.image_name)

	var output: Array = []
	var exit_code: int = OS.execute("docker", args, output, true)

	if exit_code == 0:
		_set_state(cname, "running")
		_health_failures[cname] = 0
		container_started.emit(cname)
		return true
	else:
		var error: String = output[0].strip_edges() if output.size() > 0 else "Unknown error"
		_set_state(cname, "error")
		push_error("DockerManager: Failed to start %s: %s" % [cname, error])
		return false

func stop_container(definition: Resource) -> bool:
	var cname: String = definition.container_name
	var output: Array = []
	var exit_code: int = OS.execute(
		"docker", ["stop", "-t", str(STOP_TIMEOUT_SECONDS), cname],
		output, true
	)
	OS.execute("docker", ["rm", "-f", cname], [], true)
	_set_state(cname, "stopped")
	_health_failures[cname] = 0
	container_stopped.emit(cname)
	return exit_code == 0

func stop_all() -> void:
	for cname in _definitions:
		var definition: Resource = _definitions[cname]
		if is_running(definition):
			stop_container(definition)

func get_state(definition: Resource) -> String:
	return _container_states.get(definition.container_name, "stopped")


# ── Health Checks ───────────────────────────────────────────────────────

func check_health(definition: Resource) -> bool:
	var cname: String = definition.container_name
	if definition.health_endpoint == "" or get_state(definition) != "running":
		return false

	var output: Array = []
	var exit_code: int = OS.execute(
		"curl", ["-sf", "--max-time", "3", definition.health_endpoint],
		output, true
	)

	var healthy: bool = exit_code == 0
	if healthy:
		if _health_failures.get(cname, 0) > 0:
			_health_failures[cname] = 0
			container_health_changed.emit(cname, true)
	else:
		_health_failures[cname] = _health_failures.get(cname, 0) + 1
		if _health_failures[cname] >= MAX_HEALTH_FAILURES:
			container_health_changed.emit(cname, false)

	return healthy

func is_unhealthy(definition: Resource) -> bool:
	return _health_failures.get(definition.container_name, 0) >= MAX_HEALTH_FAILURES


# ── Internal ────────────────────────────────────────────────────────────

func _set_state(container_name: String, state: String) -> void:
	var old_state: String = _container_states.get(container_name, "")
	_container_states[container_name] = state
	if old_state != state:
		container_status_changed.emit(container_name, state)

func _force_remove(container_name: String) -> void:
	OS.execute("docker", ["rm", "-f", container_name], [], true)


func _save_custom_containers() -> void:
	var custom: Array = []
	for cname in _definitions:
		if cname in _builtin_names:
			continue
		var def: Resource = _definitions[cname]
		custom.append({
			"display_name": def.display_name,
			"image_name": def.image_name,
			"dockerfile_path": def.dockerfile_path,
			"build_context": def.build_context,
			"ports": def.ports,
			"health_endpoint": def.health_endpoint,
			"gpu_optional": def.gpu_optional,
			"environment": def.environment,
		})
	var f: FileAccess = FileAccess.open(_config_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(custom, "\t"))
		f.close()


func _load_custom_containers() -> void:
	if not FileAccess.file_exists(_config_path):
		return
	var f: FileAccess = FileAccess.open(_config_path, FileAccess.READ)
	if not f:
		return
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Array:
		return
	for item in parsed:
		if item is Dictionary and item.has("image_name"):
			var def: Resource = ContainerDefinitionScript.new()
			def.display_name = item.get("display_name", item.get("image_name", ""))
			def.image_name = item.get("image_name", "")
			def.dockerfile_path = item.get("dockerfile_path", "")
			def.build_context = item.get("build_context", "")
			def.ports = item.get("ports", {})
			def.health_endpoint = item.get("health_endpoint", "")
			def.gpu_optional = item.get("gpu_optional", false)
			def.environment = item.get("environment", {})
			register(def, false)
