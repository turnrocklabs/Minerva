extends "res://Scripts/Services/Voice/BundledVoiceDetectorAdapter.gd"

var manager
var endpoints: Array[Dictionary] = []


func _get_manager():
	return manager


func _connect_endpoint(endpoint: Dictionary, generation: int) -> void:
	if generation == _generation:
		endpoints.append(endpoint.duplicate(true))


class FakeConnection extends RefCounted:
	signal release_configure
	var block_configure := false
	var configure_error := false
	var ready := true
	var calls: Array[String] = []

	func call_tool(name: String, _arguments: Dictionary) -> Dictionary:
		calls.append(name)
		if name == "minerva_voice_configure":
			if block_configure:
				await release_configure
			return {"error": "rejected"} if configure_error else {"configured": true}
		return {"ready": ready, "port": 1234, "path": "/audio", "token": "test-token"}


class FakeManager extends RefCounted:
	var connection: FakeConnection
	var next_connection: FakeConnection
	var starts := 0
	var stops := 0

	func start_plugin(_id: String) -> Dictionary:
		starts += 1
		if connection == null:
			connection = next_connection
		return {"ok": true}

	func stop_plugin(_id: String) -> Dictionary:
		stops += 1
		connection = null
		return {"ok": true}

	func get_connection(_id: String):
		return connection
