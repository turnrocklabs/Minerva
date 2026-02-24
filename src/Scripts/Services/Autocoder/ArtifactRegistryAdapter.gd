class_name ArtifactRegistryAdapter
extends BaseServiceAdapter


## Search for artifacts by query, framework, and visibility
## @param query: Search string to match in description/tags (optional)
## @param framework: Filter by framework like "godot", "unity", "react" (optional)
## @param visibility: "public" for templates/shared artifacts, "private" for user's own (default: "public")
func search(query: String = "", framework: String = "", visibility: String = "public") -> Array[Artifact]:
	var artifacts: Array[Artifact]

	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't fetch artifacts. Core not connected")
		return artifacts

	var action := get_action("artifact/search")

	# Build search parameters
	var search_params := {
		"visibility": visibility
	}
	
	if query != "":
		search_params["query"] = query
	
	if framework != "":
		search_params["framework"] = framework

	var msg = await Core.send_message(service, action, search_params).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Artifact Search Error", "No response from server")
		return []
	
	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to search artifacts")
		SingletonObject.ErrorDisplay("Artifact Search Error", error_msg)
		return []

	var result_artifacts = safe_extract(msg, ["params", "result", "artifacts"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_ARRAY], [])

	for artifact_data in result_artifacts:
		artifacts.append(Artifact.new(artifact_data))

	return artifacts


## Upload an artifact created with [method Artifact.create_from_dir]
## Returns the same artifact with [artifact_uri] and [size] updated, or null on failure
func upload(artifact: Artifact) -> Artifact:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't upload artifact. Core not connected")
		return null

	var action := get_action("artifact/upload")

	var upload_data := artifact.get_data_for_upload()

	# Show progress notification
	SingletonObject.create_toast_notification(
		"Uploading artifact '%s' (%s)..." % [artifact.filename, artifact.get_size_formatted()],
		ToastNotification.Type.INFO
	)

	var msg = await Core.send_message(service, action, upload_data).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Artifact Upload Error", "No response from server")
		return null
	
	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to upload artifact")
		SingletonObject.ErrorDisplay("Artifact Upload Error", error_msg)
		return null

	var result_uri = safe_extract(msg, ["params", "result", "uri"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")
	var result_size = safe_extract(msg, ["params", "result", "size"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_FLOAT], 0.0)

	artifact.artifact_uri = result_uri
	artifact._base64 = "" # Clear the base64 content now
	artifact.size = result_size

	SingletonObject.create_toast_notification(
		"Artifact uploaded successfully!",
		ToastNotification.Type.SUCCESS
	)

	return artifact


## Download artifact content and return payload (filename/content/size)
func _download_payload(artifact_uri: String, transfer_mode: String = "base64") -> Dictionary:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't download artifact. Core not connected")
		return {}

	var action := get_action("artifact/download")
	var download_data := {
		"uri": artifact_uri,
		"transfer_mode": transfer_mode
	}

	SingletonObject.create_toast_notification("Downloading artifact...", ToastNotification.Type.INFO)

	var msg = await Core.send_message(service, action, download_data).receive()
	
	if not msg:
		SingletonObject.ErrorDisplay("Artifact Download Error", "No response from server")
		return {}
	
	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to download artifact")
		SingletonObject.ErrorDisplay("Artifact Download Error", error_msg)
		return {}

	var filename = safe_extract(msg, ["params", "result", "filename"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")
	var content_base64 = safe_extract(msg, ["params", "result", "content"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")
	var size = safe_extract(msg, ["params", "result", "size"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_FLOAT], 0.0)
	if filename.is_empty() or content_base64.is_empty():
		SingletonObject.ErrorDisplay("Artifact Download Error", "Invalid download response")
		return {}

	return {
		"filename": filename,
		"content": content_base64,
		"size": size
	}


## Download artifact via binary WebSocket transfer.
## Returns {"filename": String, "buffer": PackedByteArray} or empty dict on failure.
func _download_binary(artifact_uri: String) -> Dictionary:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't download artifact. Core not connected")
		return {}

	var action := get_action("artifact/download")
	if not action:
		SingletonObject.ErrorDisplay("Download Error", "artifact/download action not found")
		return {}

	var download_data := {"uri": artifact_uri, "transfer_mode": "binary"}

	SingletonObject.create_toast_notification("Downloading artifact...", ToastNotification.Type.INFO)

	# Generate request_id and prepare core_client for binary frames
	var request_id: String = Core.client.send_text_message(service, action, download_data)
	Core.client.prepare_binary_artifact_download(request_id)
	print("🔽 _download_binary: sent request_id=%s for uri=%s, waiting for artifact_binary_received..." % [request_id, artifact_uri])

	# Wait for artifact_binary_received signal
	var result: Dictionary = {}
	var timed_out := false

	var on_received := func(req_id: String, filename: String, buffer: PackedByteArray):
		print("🔽 _download_binary: signal fired! req_id=%s (expected=%s) filename=%s size=%s" % [req_id, request_id, filename, buffer.size()])
		if req_id == request_id:
			# Mutate the captured dict — reassignment (result = {...}) won't
			# propagate to the outer scope in GDScript lambdas.
			result["filename"] = filename
			result["buffer"] = buffer
		else:
			print("🔽 _download_binary: req_id MISMATCH, ignoring")

	Core.client.artifact_binary_received.connect(on_received)

	# Poll with timeout
	var timeout := 120.0
	var elapsed := 0.0
	while result.is_empty() and not timed_out:
		await SingletonObject.get_tree().process_frame
		elapsed += SingletonObject.get_tree().root.get_process_delta_time()
		if elapsed >= timeout:
			timed_out = true

	# Disconnect signal
	if Core.client.artifact_binary_received.is_connected(on_received):
		Core.client.artifact_binary_received.disconnect(on_received)

	if timed_out and result.is_empty():
		print("🔽 _download_binary: TIMED OUT after %ss (result empty=%s)" % [elapsed, result.is_empty()])
		SingletonObject.ErrorDisplay("Download Error", "Binary artifact download timed out")
		return {}
	elif result.is_empty():
		print("🔽 _download_binary: loop exited but result empty (elapsed=%ss)" % elapsed)
		SingletonObject.ErrorDisplay("Download Error", "Binary artifact download failed")
		return {}

	return result


## Download an artifact by URI and save it to disk
## Opens a file dialog for the user to choose save location
## Returns true on success, false on failure
func download(artifact_uri: String) -> bool:
	var result = await _download_binary(artifact_uri)
	if result.is_empty():
		return false

	var filename: String = result.get("filename", "")
	var bytes: PackedByteArray = result.get("buffer", PackedByteArray())

	if bytes.is_empty():
		SingletonObject.ErrorDisplay("Download Error", "Empty artifact data")
		return false

	var size := float(bytes.size())

	# Open file dialog to save
	var file_dialog := FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.current_file = filename
	file_dialog.title = "Save Artifact"

	# Add appropriate filters based on filename
	if filename.ends_with(".tar.gz"):
		file_dialog.filters = PackedStringArray(["*.tar.gz ; Tar GZip Archive"])
	elif filename.ends_with(".zip"):
		file_dialog.filters = PackedStringArray(["*.zip ; ZIP Archive"])
	else:
		file_dialog.filters = PackedStringArray(["* ; All Files"])

	# Add to scene tree temporarily
	SingletonObject.add_child(file_dialog)
	file_dialog.popup_centered_ratio(0.5)

	# Use an array to capture the path (arrays are passed by reference)
	var dialog_result := [""]

	# Create a one-shot callable to capture the path
	var on_file_selected := func(path: String):
		dialog_result[0] = path

	var on_canceled := func():
		dialog_result[0] = ""

	file_dialog.file_selected.connect(on_file_selected, CONNECT_ONE_SHOT)
	file_dialog.canceled.connect(on_canceled, CONNECT_ONE_SHOT)

	# Wait for either signal
	await file_dialog.visibility_changed

	# Wait a frame to ensure signals are processed
	await SingletonObject.get_tree().process_frame

	file_dialog.queue_free()

	var selected_path: String = dialog_result[0]

	if selected_path.is_empty():
		# User canceled
		return false

	# Save the file
	var file := FileAccess.open(selected_path, FileAccess.WRITE)
	if not file:
		var err := FileAccess.get_open_error()
		SingletonObject.ErrorDisplay("Save Error", "Failed to save file: %s" % error_string(err))
		return false

	file.store_buffer(bytes)
	file.close()

	SingletonObject.create_toast_notification(
		"Artifact saved successfully (%s)" % _format_size(size),
		ToastNotification.Type.SUCCESS
	)
	return true


## Download an artifact and extract it into a destination directory
## Returns true on success, false on failure
func download_and_extract(artifact_uri: String, destination_dir: String) -> bool:
	if destination_dir.is_empty():
		SingletonObject.ErrorDisplay("Extract Error", "Missing destination directory")
		return false

	var result = await _download_binary(artifact_uri)
	if result.is_empty():
		return false

	var filename: String = result.get("filename", "")
	var bytes: PackedByteArray = result.get("buffer", PackedByteArray())

	if bytes.is_empty():
		SingletonObject.ErrorDisplay("Extract Error", "Empty artifact data")
		return false

	var size := float(bytes.size())

	var artifacts_dir = "user://autocoder_artifacts"
	var dir = DirAccess.open("user://")
	if not dir:
		SingletonObject.ErrorDisplay("Extract Error", "Failed to open user:// directory")
		return false
	if not dir.dir_exists("autocoder_artifacts"):
		dir.make_dir_recursive("autocoder_artifacts")

	var temp_path = "%s/%s" % [artifacts_dir, filename]
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if not file:
		var err := FileAccess.get_open_error()
		SingletonObject.ErrorDisplay("Extract Error", "Failed to write archive: %s" % error_string(err))
		return false
	file.store_buffer(bytes)
	file.close()

	var global_dest = ProjectSettings.globalize_path(destination_dir)
	DirAccess.make_dir_recursive_absolute(global_dest)
	var global_archive = ProjectSettings.globalize_path(temp_path)

	var args: PackedStringArray = []
	if filename.ends_with(".tar.gz"):
		args = PackedStringArray(["-xzf", global_archive, "-C", global_dest])
	elif filename.ends_with(".zip"):
		args = PackedStringArray(["-xf", global_archive, "-C", global_dest])
	else:
		SingletonObject.ErrorDisplay("Extract Error", "Unsupported archive format: %s" % filename)
		return false

	var output: Array[String] = []
	var exit_code = OS.execute("tar", args, output, true)
	if exit_code != 0:
		var output_text = "\n".join(output)
		SingletonObject.ErrorDisplay("Extract Error", "Failed to extract archive:\n%s" % output_text)
		return false

	SingletonObject.create_toast_notification(
		"Artifact extracted (%s)" % _format_size(size),
		ToastNotification.Type.SUCCESS
	)
	return true


## Helper to format file size
func _format_size(bytes: float) -> String:
	var units := ["B", "kB", "MB", "GB"]
	var unit_index := 0
	while bytes >= 1000.0 and unit_index < units.size() - 1:
		bytes /= 1000.0
		unit_index += 1
	return "%.1f %s" % [bytes, units[unit_index]]


## Delete an artifact by URI (owner only)
## Returns true on success, false on failure
func delete(artifact_uri: String) -> bool:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't delete artifact. Core not connected")
		return false

	var action := get_action("artifact/delete")

	var msg = await Core.send_message(service, action, {"artifact_uri": artifact_uri}).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Artifact Delete Error", "No response from server")
		return false
	
	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to delete artifact")
		SingletonObject.ErrorDisplay("Artifact Delete Error", error_msg)
		return false

	var success = safe_extract(msg, ["params", "result", "success"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_BOOL], false)

	return success


## List current user's own artifacts (private visibility)
## Returns an array of Artifact objects owned by the authenticated user
func list_mine() -> Array[Artifact]:
	var artifacts: Array[Artifact]

	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't list artifacts. Core not connected")
		return artifacts

	var action := get_action("artifact/list-mine")

	var msg = await Core.send_message(service, action, {}).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Artifact List Error", "No response from server")
		return []
	
	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to list user artifacts")
		SingletonObject.ErrorDisplay("Artifact List Error", error_msg)
		return []

	var result_artifacts = safe_extract(msg, ["params", "result", "artifacts"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_ARRAY], [])

	for artifact_data in result_artifacts:
		artifacts.append(Artifact.new(artifact_data))

	return artifacts


## Add metadata to an existing artifact on disk
## Useful for adding searchable metadata to artifacts that were created without it
## @param artifact_uri: The artifact:// URI
## @param filename: Filename within the artifact
## @param description: Human-readable description
## @param tags: Array of tag strings for categorization
## @param framework: Framework name (e.g. "godot", "unity")
## @param language: Programming language (e.g. "gdscript", "csharp")
## @param visibility: "public" or "private"
func add_metadata(
	artifact_uri: String,
	filename: String,
	description: String = "",
	tags: Array = [],
	framework: String = "",
	language: String = "",
	visibility: String = "public"
) -> bool:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't add metadata. Core not connected")
		return false

	var action := get_action("artifact/add-metadata")

	var metadata_params := {
		"artifact_uri": artifact_uri,
		"filename": filename,
		"description": description,
		"tags": tags,
		"visibility": visibility
	}
	
	if framework != "":
		metadata_params["framework"] = framework
	
	if language != "":
		metadata_params["language"] = language

	var msg = await Core.send_message(service, action, metadata_params).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Artifact Metadata Error", "No response from server")
		return false
	
	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to add metadata")
		SingletonObject.ErrorDisplay("Artifact Metadata Error", error_msg)
		return false

	var success = safe_extract(msg, ["params", "result", "success"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_BOOL], false)

	return success


## Helper: Search for public templates by framework
## @param framework: Framework name like "godot", "unity", "react"
func search_templates(framework: String = "") -> Array[Artifact]:
	return await search("", framework, "public")


## Helper: Search user's private artifacts
## @param query: Optional search query
func search_my_artifacts(query: String = "") -> Array[Artifact]:
	return await search(query, "", "private")