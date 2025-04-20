extends Node


@onready var _client_script: = preload("res://Scripts/Services/Providers/Core/core_client.gd")
var registered: = false

var client: CoreClient

var services: Array[Service]

func _ready() -> void:
	var cn = Node.new()
	cn.set_script(_client_script)

	add_child(cn)

	client = cn

func start(url: String = "ws://127.0.0.1:3030/connect") -> bool:

	var connected: = client.connect_to_core(url)

	if not connected:
		return false

	await client.connection_established
	client.register_with_core()

	return true


func send_message(topic: String, msg: Dictionary):
	var request_id: = client.send_message(topic, msg)

	return await_message().with_request_id(request_id)

func fetch_services() -> Array[Service]:
	client.request_connections()

	var msg = await Core.await_message().with_cmd("response").with_topic("skills/discovery").receive()

	if not msg: return []

	var services_array: Array = msg.get("params", {}).get("result", [])

	services.clear()
	for srvc_dta in services_array:
		print("\n")
		print("Service data:")
		print(srvc_dta)
		services.append(Service.new(srvc_dta["params"]))
	
	print("\n\n\n")

	print(services)

	return services


class AwaitMessage extends RefCounted:
	var topic: String
	var cmd: String
	var request_id: String
	var timeout: float = 5
	
	var client: CoreClient

	var _received_message = null
	var _stop: = false

	func _init(client_: CoreClient) -> void:
		client = client_

	func _check_message(data: Dictionary) -> bool:
		
		if not cmd.is_empty():
			var msg_cmd = data.get("cmd")

			if cmd != msg_cmd:
				prints(cmd, msg_cmd)
				return false
		
		if not topic.is_empty():
			var msg_topic = data.get("topic")

			if topic != msg_topic:
				prints(topic, msg_topic)
				return false
		
		if not request_id.is_empty():
			var msg_request_id = data.get("params", {}).get("request_id")

			if request_id != msg_request_id:
				prints(request_id, msg_request_id)
				return false
		
		return true

	func receive():
		# set a timer to timeout and set the stop variable
		client.get_tree().create_timer(timeout).timeout.connect(
			func():
				self._stop = true
		)

		client.message_received.connect(
			func(data: Dictionary):
				if _check_message(data):
					self._received_message = data
		)

		while not _stop and not _received_message:
			await client.get_tree().process_frame
		
		return _received_message

	func with_timeout(timeout_: float) -> AwaitMessage:
		timeout = timeout_
		return self

	func with_topic(topic_: String) -> AwaitMessage:
		topic = topic_
		return self

	func with_request_id(request_id_: String) -> AwaitMessage:
		request_id = request_id_
		return self

	func with_cmd(cmd_: String) -> AwaitMessage:
		cmd = cmd_
		return self
	


func await_message() -> AwaitMessage:
	return AwaitMessage.new(client)
