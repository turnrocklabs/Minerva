class_name ArtifactRegistryAdapter
extends BaseServiceAdapter


func search() -> Array[Artifact]:
	var artifacts: Array[Artifact]

	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't fetch artifacts. Core not connected")
		return artifacts

	var action: = get_action("artifact/search")

	var msg = await Core.send_message(service, action, {}).receive()

	if not msg or msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to search artifacts")
		SingletonObject.ErrorDisplay("Artifact Search Error", error_msg)
		return []

	var result_artifacts = safe_extract(msg, ["params", "result", "artifacts"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_ARRAY], [])

	for artifact_data in result_artifacts:
		artifacts.append(Artifact.new(artifact_data))

	return artifacts


## Takes an [class Artifact] object created using [method Artifact.create_from_dir] and tries to upload it.[br]
## If upload was succesfull returns the same object with fields [artifact_uri] and [size] updated and [_base64] cleared.[br]
## On failure returns [null]
func upload(artifact: Artifact) -> Artifact:

	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't fetch artifacts. Core not connected")
		return null

	var action: = get_action("artifact/upload")

	var upload_data: = artifact.get_data_for_upload()

	var msg = await Core.send_message(service, action, upload_data).receive()

	if not msg or msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to to upload artifact")
		SingletonObject.ErrorDisplay("Artifact Upload Error", error_msg)
		return null

	var result_uri = safe_extract(msg, ["params", "result", "uri"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], [])
	var result_size = safe_extract(msg, ["params", "result", "size"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_FLOAT], 0.0)

	artifact.artifact_uri = result_uri
	artifact._base64 = "" # clear the bast64 content now
	artifact.size = result_size

	return artifact

func delete(artifact_uri) -> bool:

	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't delete artifact. Core not connected")
		return false

	var action: = get_action("artifact/delete")

	var msg = await Core.send_message(service, action, {"artifact_uri": artifact_uri}).receive()

	if not msg or msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to delete artifact")
		SingletonObject.ErrorDisplay("Artifact Delete Error", error_msg)
		return false

	var success = safe_extract(msg, ["params", "result", "success"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_BOOL], false)

	return success



