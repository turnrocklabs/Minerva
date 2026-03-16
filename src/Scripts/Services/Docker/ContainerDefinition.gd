class_name ContainerDefinition
extends Resource
## Defines a Docker container that Minerva manages.
## Each managed container has one of these registered with DockerManager.

## Display name shown in UI (e.g., "Voice Gateway")
@export var display_name: String = ""

## Docker image name (e.g., "minerva-voice-gateway")
@export var image_name: String = ""

## Path to Dockerfile relative to Minerva install directory
@export var dockerfile_path: String = ""

## Build context directory (usually the directory containing the Dockerfile)
@export var build_context: String = ""

## Port mappings: host_port -> container_port
@export var ports: Dictionary = {}

## Health check endpoint (e.g., "http://localhost:8090/health")
@export var health_endpoint: String = ""

## Request GPU if available, fall back to CPU if not
@export var gpu_optional: bool = false

## Environment variables to pass to container
@export var environment: Dictionary = {}

## Container name (same as image name by default)
var container_name: String:
	get:
		return image_name
