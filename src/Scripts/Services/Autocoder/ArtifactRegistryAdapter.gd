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

	if not msg or msg.get("cmd") == "error":
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

	if not msg or msg.get("cmd") == "error":
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


## Download an artifact by URI and save it to disk
## Opens a file dialog for the user to choose save location
## Returns true on success, false on failure
func download(artifact_uri: String, transfer_mode: String = "base64") -> bool:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't download artifact. Core not connected")
		return false

	var action := get_action("artifact/download")

	var download_data := {
		"uri": artifact_uri,
		"transfer_mode": transfer_mode
	}

	SingletonObject.create_toast_notification("Downloading artifact...", ToastNotification.Type.INFO)

	var msg = await Core.send_message(service, action, download_data).receive()

	if not msg or msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to download artifact")
		SingletonObject.ErrorDisplay("Artifact Download Error", error_msg)
		return false

	var filename = safe_extract(msg, ["params", "result", "filename"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")
	var content_base64 = safe_extract(msg, ["params", "result", "content"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")
	var size = safe_extract(msg, ["params", "result", "size"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_FLOAT], 0.0)

	if filename.is_empty() or content_base64.is_empty():
		SingletonObject.ErrorDisplay("Artifact Download Error", "Invalid download response")
		return false

	# Decode base64 to bytes
	var bytes := Marshalls.base64_to_raw(content_base64)
	if bytes.is_empty():
		SingletonObject.ErrorDisplay("Artifact Download Error", "Failed to decode artifact data")
		return false

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
	var result := [""]

	# Create a one-shot callable to capture the path
	var on_file_selected := func(path: String):
		result[0] = path

	var on_canceled := func():
		result[0] = ""

	file_dialog.file_selected.connect(on_file_selected, CONNECT_ONE_SHOT)
	file_dialog.canceled.connect(on_canceled, CONNECT_ONE_SHOT)

	# Wait for either signal
	await file_dialog.visibility_changed

	# Wait a frame to ensure signals are processed
	await SingletonObject.get_tree().process_frame

	file_dialog.queue_free()

	var selected_path: String = result[0]

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

	if not msg or msg.get("cmd") == "error":
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

	if not msg or msg.get("cmd") == "error":
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

	if not msg or msg.get("cmd") == "error":
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