class_name AutocoderAdapter
extends BaseServiceAdapter


class GenerationOutput extends RefCounted:
	var session_id: String
	var message: String
	var notification_topics: Array[String]
	var status: String
	var user_id: String
	var iteration: float

	func _init(
		sid: String,
		msg: String,
		notif_topics: Array[String],
		output_status: String,
		output_user_id: String,
		ouput_iteration: float
	) -> void:
		session_id = sid
		message = msg
		notification_topics = notif_topics
		status = output_status
		user_id = output_user_id
		iteration = ouput_iteration



# {
#     "cmd": "response",
#     "params": {
#         "client_id": "678dd438-6d80-4109-948c-cb1422ce1969",
#         "request_id": "019a5559-282a-72c2-b18b-8513de37e6dc",
#         "result": {
#             "iteration": 0.0,
#             "message": "Code generation started. Subscribe to notification topics for completion updates.",
#             "notification_topics": [
#                 "autocoder-orchestrator/iteration/678dd438-6d80-4109-948c-cb1422ce1969/*",
#                 "autocoder-orchestrator/iteration/678dd438-6d80-4109-948c-cb1422ce1969/ses_5aaa6d665ffeDGwbbZwNCXVAi3"
#             ],
#             "session_id": "ses_5aaa6d665ffeDGwbbZwNCXVAi3",
#             "status": "processing",
#             "user_id": "678dd438-6d80-4109-948c-cb1422ce1969"
#         }
#     },
#     "topic": "autocoder/generate"
# }

func generate(prompt: String, session_id: String = "", input_archive_uri: String = "", require_permission: = false) -> GenerationOutput:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't start autocoder. Core not connected")
		return null

	var action: = get_action("autocoder/generate")

	var data: = {
		"prompt": prompt,
		"require_permission": require_permission,
	}

	if not session_id.is_empty():
		data["session_id"] = session_id

	if not input_archive_uri.is_empty():
		data["input_archive_uri"] = input_archive_uri
	
	var msg = await Core.send_message(service, action, data).receive()

	if not msg or msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to start a session")
		SingletonObject.ErrorDisplay("Autocoder Error", error_msg)
		return null

	var sid = safe_extract(msg, ["params", "result", "session_id"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")
	var iteration = safe_extract(msg, ["params", "result", "iteration"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_FLOAT], 0.0)
	var message = safe_extract(msg, ["params", "result", "message"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")
	
	var notification_topics: Array[String]
	notification_topics.assign(safe_extract(msg, ["params", "result", "notification_topics"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_ARRAY], []))

	var status = safe_extract(msg, ["params", "result", "status"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")
	var user_id = safe_extract(msg, ["params", "result", "user_id"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")

	return GenerationOutput.new(
		sid,
		message,
		notification_topics,
		status,
		user_id,
		iteration,
	)


# subscribe_msg = {
#         "cmd": "subscribe",
#         "topic": "subscription",
#         "params": {
#             "client_id": client_id,
#             "request_id": request_id,
#             "topic": topic
#         }
#     }
