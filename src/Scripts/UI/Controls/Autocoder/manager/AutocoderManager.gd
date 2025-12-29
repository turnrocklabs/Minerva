class_name AutocodeManager
extends VBoxContainer


var artifact_registry_adapter: ArtifactRegistryAdapter
var autocoder_adapter: AutocoderAdapter

var _monitoring_sessions: PackedStringArray

# keep an array of notification message handlers so they dont go out of scope and get garbage collected
var _notification_message_handlers: Array[Core.AwaitMessage]

func _init() -> void:
	Core.ready.connect(
		func():
			Core.client.connection_established.connect(_on_core_connected)
			Core.client.connection_closed.connect(_on_core_disconnected)
			Core.client.message_received.connect(_on_core_message_received)
	)

	SingletonObject.autocoder_manager = self


func info(input):
	if SingletonObject.verbose_logging:
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



func monitor_session(user_id: String, session_id: String,):

	var success: = await Core.subscribe("autocoder-orchestrator/iteration/%s/%s" % [user_id, session_id])

	if not success:
		SingletonObject.ErrorDisplay("Can't subscribe", "Can't subscribe to session notifications")
		# return?

	var message_awaiter = Core.await_message()

	_notification_message_handlers.append(message_awaiter)

	# using text editor for now
	var logs_editor: = SingletonObject.editor_pane.add(Editor.Type.TEXT, null, "Logs", message_awaiter)
	
	message_awaiter.with_cmd("publication").receive_all().connect(
		func(msg: Dictionary):
			# prints("NOTIFICATION RECEIVED:", msg)
			logs_editor.code_edit.text += "\n NOTIFICATION RECEIVED"
			logs_editor.code_edit.text += JSON.stringify(msg, "\t")
	)

	_monitoring_sessions.append(session_id)



