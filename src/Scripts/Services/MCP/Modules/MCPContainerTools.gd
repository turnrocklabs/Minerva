class_name MCPContainerTools
extends MCPToolModule
## MCP tool module for Docker container management tools.


func get_tool_names() -> Array[String]:
	return ["minerva_container"]


func register_tools() -> void:
	var container_server: MinervaMCPServer = server
	container_server._register_tool("minerva_container",
		"Manage Docker containers with an operation.\n"
		+ "docker_status: Docker availability, version and GPU support.\n"
		+ "list: registered containers and states.\n"
		+ "status: name, detailed state.\n"
		+ "build: name, start image build; poll status.\n"
		+ "start: name, start a built image.\n"
		+ "stop: name, stop running container.\n"
		+ "remove: name, stop and remove custom definition/image.\n"
		+ "add: image_name; optional display_name, dockerfile_path, build_context, host_port, container_port, health_endpoint, gpu_optional.",
		{"type": "object", "properties": {
			"op": {"type": "string", "enum": ["docker_status", "list", "status", "build", "start", "stop", "remove", "add"]},
			"name": {"type": "string", "description": "Registered container name"},
			"image_name": {"type": "string", "description": "Docker image name for add"},
			"display_name": {"type": "string"},
			"dockerfile_path": {"type": "string", "description": "Absolute Dockerfile path"},
			"build_context": {"type": "string", "description": "Defaults to Dockerfile directory"},
			"host_port": {"type": "integer"},
			"container_port": {"type": "integer"},
			"health_endpoint": {"type": "string"},
			"gpu_optional": {"type": "boolean"},
		}, "required": ["op"]}, "containers")


func handle(_tool_name: String, arguments: Dictionary) -> Dictionary:
	var operation: String = str(arguments.get("op", ""))
	match operation:
		"docker_status": return _docker_status(arguments)
		"list": return _container_list(arguments)
		"status": return _container_status(arguments)
		"build": return _container_build(arguments)
		"start": return _container_start(arguments)
		"stop": return _container_stop(arguments)
		"remove": return _container_remove(arguments)
		"add": return _container_add(arguments)
	return {"success": false, "error": "Unknown container op: %s" % operation, "error_code": "unknown_op"}


func _docker_status(_arguments: Dictionary) -> Dictionary:
	var manager: RefCounted = SingletonObject.get_docker_manager()
	if manager.docker_status.is_empty():
		manager.detect()
	return {"docker": manager.docker_status, "success": true}


func _container_list(_arguments: Dictionary) -> Dictionary:
	var manager: RefCounted = SingletonObject.get_docker_manager()
	var definitions: Array = manager.get_definitions()
	var containers: Array = []

	for def in definitions:
		containers.append({
			"name": def.container_name,
			"display_name": def.display_name,
			"image": def.image_name,
			"state": manager.get_state(def),
			"has_image": manager.is_image_built(def),
			"running": manager.is_running(def),
		})

	return {"containers": containers, "count": containers.size(), "success": true}


func _container_status(arguments: Dictionary) -> Dictionary:
	var name: String = arguments.get("name", "")
	if name == "":
		return MCPToolUtils.error("Missing required field: name")

	var manager: RefCounted = SingletonObject.get_docker_manager()
	var definitions: Array = manager.get_definitions()

	for def in definitions:
		if def.container_name == name:
			return {
				"name": def.container_name,
				"display_name": def.display_name,
				"image": def.image_name,
				"state": manager.get_state(def),
				"has_image": manager.is_image_built(def),
				"running": manager.is_running(def),
				"healthy": manager.check_health(def) if manager.is_running(def) else false,
				"health_endpoint": def.health_endpoint,
				"ports": def.ports,
				"gpu_optional": def.gpu_optional,
				"success": true,
			}

	return MCPToolUtils.error("Container '%s' not registered" % name)


func _container_build(arguments: Dictionary) -> Dictionary:
	var name: String = arguments.get("name", "")
	if name == "":
		return MCPToolUtils.error("Missing required field: name")

	var manager: RefCounted = SingletonObject.get_docker_manager()
	if not manager.is_available():
		return MCPToolUtils.error("Docker not available")

	var definitions: Array = manager.get_definitions()
	for def in definitions:
		if def.container_name == name:
			var started: bool = manager.build_image(def)
			if started:
				return {"message": "Build started for %s. Poll with minerva_container op status to check progress." % name, "state": "building", "success": true}
			else:
				return {"error": "Failed to start build (may already be building)", "state": manager.get_state(def), "success": false}

	return MCPToolUtils.error("Container '%s' not registered" % name)


func _container_start(arguments: Dictionary) -> Dictionary:
	var name: String = arguments.get("name", "")
	if name == "":
		return MCPToolUtils.error("Missing required field: name")

	var manager: RefCounted = SingletonObject.get_docker_manager()
	if not manager.is_available():
		return MCPToolUtils.error("Docker not available")

	var definitions: Array = manager.get_definitions()
	for def in definitions:
		if def.container_name == name:
			if not manager.is_image_built(def):
				return MCPToolUtils.error("Image not built. Run minerva_container op build first.")
			var ok: bool = manager.start_container(def)
			if ok:
				return {"message": "%s started" % name, "state": "running", "success": true}
			else:
				return {"error": "Failed to start container", "state": manager.get_state(def), "success": false}

	return MCPToolUtils.error("Container '%s' not registered" % name)


func _container_stop(arguments: Dictionary) -> Dictionary:
	var name: String = arguments.get("name", "")
	if name == "":
		return MCPToolUtils.error("Missing required field: name")

	var manager: RefCounted = SingletonObject.get_docker_manager()
	var definitions: Array = manager.get_definitions()

	for def in definitions:
		if def.container_name == name:
			var ok: bool = manager.stop_container(def)
			if ok:
				return {"message": "%s stopped" % name, "state": "stopped", "success": true}
			else:
				return MCPToolUtils.error("Failed to stop container")

	return MCPToolUtils.error("Container '%s' not registered" % name)


func _container_add(arguments: Dictionary) -> Dictionary:
	var img: String = arguments.get("image_name", "")
	if img == "":
		return MCPToolUtils.error("Missing required field: image_name")

	var dn: String = arguments.get("display_name", img)
	var df: String = arguments.get("dockerfile_path", "")
	var ctx: String = arguments.get("build_context", "")
	var hp: String = arguments.get("health_endpoint", "")
	var gpu: bool = arguments.get("gpu_optional", false)

	if ctx == "" and df != "":
		ctx = df.get_base_dir()

	var ports: Dictionary = {}
	var host_port: int = arguments.get("host_port", 0)
	var container_port: int = arguments.get("container_port", 0)
	if host_port > 0 and container_port > 0:
		ports[host_port] = container_port

	var manager: RefCounted = SingletonObject.get_docker_manager()
	manager.register_custom(dn, img, df, ctx, ports, hp, gpu)
	return {"message": "Container '%s' added" % img, "name": img, "success": true}


func _container_remove(arguments: Dictionary) -> Dictionary:
	var name: String = arguments.get("name", "")
	if name == "":
		return MCPToolUtils.error("Missing required field: name")

	var manager: RefCounted = SingletonObject.get_docker_manager()
	var definitions: Array = manager.get_definitions()

	for def in definitions:
		if def.container_name == name:
			if manager.is_builtin(def):
				return MCPToolUtils.error("Cannot remove builtin container '%s'" % name)
			var ok: bool = manager.remove_container(def)
			if ok:
				return {"message": "Container '%s' removed" % name, "success": true}
			return MCPToolUtils.error("Failed to remove container")

	return MCPToolUtils.error("Container '%s' not registered" % name)
