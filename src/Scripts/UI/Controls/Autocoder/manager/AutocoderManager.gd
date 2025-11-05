class_name AutocodeManager
extends VBoxContainer


var artifact_registry_adapter: ArtifactRegistryAdapter
var autocoder_adapter: AutocoderAdapter

func _init() -> void:
	Core.ready.connect(
		func():
			Core.client.connection_established.connect(_on_core_connected)
			Core.client.connection_closed.connect(_on_core_disconnected)
			Core.client.message_received.connect(_on_core_message_received)
	)

	SingletonObject.autocoder_manager = self


func info(input):
	print("#\n#### Autocoder: %s\n#" % str(input))


func _on_core_connected():
	info("Waiting for registration message...")
	
	var registration_message = await (
		Core
		.await_message()
		.with_topic("system")
		.with_cmd("registration_confirmed")
		.receive()
	)
	
	if not registration_message:
		info("No registration message received")
		return
	
	info("Registration message received")
	
	var services = await Core.fetch_services()
	
	for service in services:
		
		info("Found service: %s" % service.client_id)
		
		if service.client_id == "artifact-service":
			artifact_registry_adapter = ArtifactRegistryAdapter.new(service)
		
		if service.client_id == "autocoder-orchestrator":
			autocoder_adapter = AutocoderAdapter.new(service)


func _on_core_disconnected():
	info("Core disconnected")

func _on_core_message_received(data):
	if data is Dictionary and data.get("cmd", "") == "event" and data.get("entity_type", "") == "core":
		var params = data.get("params", {})
		if params.get("name", "") == "service_disconnected":
			info("Service %s disconnected" % params.get("service_id", "Unknown"))