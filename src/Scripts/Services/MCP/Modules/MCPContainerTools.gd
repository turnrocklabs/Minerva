class_name MCPContainerTools
extends MCPToolModule
## MCP tool module for Docker container management tools.
## Handles listing, building, starting, stopping, adding, and removing containers.


func get_tool_names() -> Array[String]:
	return [
		"minerva_container_list",
		"minerva_container_status",
		"minerva_container_build",
		"minerva_container_start",
		"minerva_container_stop",
		"minerva_container_add",
		"minerva_container_remove",
		"minerva_docker_status",
	]


func register_tools() -> void:
	server._register_tool("minerva_docker_status",
		"Check Docker availability, version, platform, runtime type, and GPU support.",
		{
			"type": "object",
			"properties": {},
		}
	, "containers")

	server._register_tool("minerva_container_list",
		"List all registered managed containers with their current state (stopped, building, running, error).",
		{
			"type": "object",
			"properties": {},
		}
	, "containers")

	server._register_tool("minerva_container_status",
		"Get detailed status of a specific container by name.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Container name (e.g., 'minerva-voice-gateway')"
				}
			},
			"required": ["name"]
		}
	, "containers")

	server._register_tool("minerva_container_build",
		"Build a Docker image for a registered container from its Dockerfile. Non-blocking — returns immediately, poll with minerva_container_status to check progress.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Container name (e.g., 'minerva-voice-gateway')"
				}
			},
			"required": ["name"]
		}
	, "containers")

	server._register_tool("minerva_container_start",
		"Start a registered container. Image must be built first.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Container name (e.g., 'minerva-voice-gateway')"
				}
			},
			"required": ["name"]
		}
	, "containers")

	server._register_tool("minerva_container_stop",
		"Stop a running container.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Container name (e.g., 'minerva-voice-gateway')"
				}
			},
			"required": ["name"]
		}
	, "containers")

	server._register_tool("minerva_container_add",
		"Add a custom container definition. Persists across restarts. Specify at minimum image_name and either dockerfile_path or an existing image.",
		{
			"type": "object",
			"properties": {
				"display_name": {
					"type": "string",
					"description": "Human-readable name (e.g., 'My Service')"
				},
				"image_name": {
					"type": "string",
					"description": "Docker image name (e.g., 'my-service')"
				},
				"dockerfile_path": {
					"type": "string",
					"description": "Absolute path to Dockerfile"
				},
				"build_context": {
					"type": "string",
					"description": "Build context directory (defaults to Dockerfile's directory)"
				},
				"host_port": {
					"type": "integer",
					"description": "Host port to map"
				},
				"container_port": {
					"type": "integer",
					"description": "Container port to map"
				},
				"health_endpoint": {
					"type": "string",
					"description": "Health check URL (e.g., 'http://localhost:8080/health')"
				},
				"gpu_optional": {
					"type": "boolean",
					"description": "Request GPU if available (default: false)"
				}
			},
			"required": ["image_name"]
		}
	, "containers")

	server._register_tool("minerva_container_remove",
		"Remove a custom container definition (stops container and removes image). Cannot remove builtin containers.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Container name to remove"
				}
			},
			"required": ["name"]
		}
	, "containers")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_docker_status": return _docker_status(arguments)
		"minerva_container_list": return _container_list(arguments)
		"minerva_container_status": return _container_status(arguments)
		"minerva_container_build": return _container_build(arguments)
		"minerva_container_start": return _container_start(arguments)
		"minerva_container_stop": return _container_stop(arguments)
		"minerva_container_add": return _container_add(arguments)
		"minerva_container_remove": return _container_remove(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


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
				return {"message": "Build started for %s. Poll with minerva_container_status to check progress." % name, "state": "building", "success": true}
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
				return MCPToolUtils.error("Image not built. Run minerva_container_build first.")
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
