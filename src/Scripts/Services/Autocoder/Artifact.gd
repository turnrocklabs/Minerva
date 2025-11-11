class_name Artifact
extends RefCounted

var artifact_uri: String
var filename: String
var description: String
var framework: String
var language: String
var tags: Array[String]
var visibility: String
var size: int
var uploaded_at: String
var owner_id: String

## Base64 string of artifact content. Used when uploading the artifact, otherwise empty
var _base64: String

func _init(data: Dictionary = {}) -> void:
	artifact_uri = data.get("artifact_uri", "")
	filename = data.get("filename", "")
	description = data.get("description", "")
	# framework and language can be null so check explicitly
	framework = str(data.get("framework")) if data.get("framework") != null else ""
	language = str(data.get("language")) if data.get("language") != null else ""
	visibility = data.get("visibility", "")
	size = data.get("size", 0)
	uploaded_at = data.get("uploaded_at", "")
	owner_id = data.get("owner_id", "")
	
	# Handle tags array
	var tags_raw = data.get("tags", [])
	if tags_raw is Array:
		for tag in tags_raw:
			tags.append(str(tag))


## Returns formatted size string (e.g., "3.30 MB")
func get_size_formatted(precision: = 1) -> String:
	var bytes: float = size
	
	var LABELS: PackedStringArray = ["B", "kB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"]
	var OFFSETS: Array[float] = [0.5, 0.05, 0.005, 0.0005]
	var FORMATS: PackedStringArray = ["%.0f %s", "%.1f %s", "%.2f %s", "%.3f %s"]

	var step := 1000.0
	var threshold := step - OFFSETS[precision]
	var is_negative := bytes < 0.0
	if is_negative:
		bytes = absf(bytes)

	for unit in LABELS:
		if bytes < threshold:
			var formatted := FORMATS[precision] % [bytes, unit]
			return ("-" if is_negative else "") + formatted
		if unit != LABELS[-1]:
			bytes /= step

	# fallback if extremely large
	return ("-" if is_negative else "") + FORMATS[precision] % [bytes, LABELS[-1]]


## Returns formatted date string (e.g., "2025-10-28")
func get_date_formatted() -> String:
	if "T" in uploaded_at:
		return uploaded_at.split("T")[0]
	return uploaded_at


## Returns tags as comma-separated string
func get_tags_string() -> String:
	return ", ".join(tags)


## Returns true if this artifact is owned by the current user
func is_owned_by(user_id: String) -> bool:
	return owner_id == user_id


## Returns true if artifact is public
func is_public() -> bool:
	return visibility == "public"


## Creates an [Artifact] object ready for upload to registry.[br]
## [param tar_file] must be an absolute path of file that ends with `.tar.gz`
static func create_from_file(tar_file: String, data: Dictionary) -> Artifact:
	if not tar_file.is_absolute_path() or not tar_file.get_file().ends_with(".tar.gz"):
		push_error("Invalid tar file path: %s" % tar_file)
		return null

	var artifact := Artifact.new(data)
	var bytes := FileAccess.get_file_as_bytes(tar_file)

	if bytes.is_empty():
		push_error("Failed to read tar file: %s (Error: %s)" % [tar_file, error_string(FileAccess.get_open_error())])
		return null

	artifact._base64 = Marshalls.raw_to_base64(bytes)
	artifact.size = bytes.size()
	
	# Auto-set filename if not provided
	if artifact.filename.is_empty():
		artifact.filename = tar_file.get_file()

	return artifact


## Creates tar.gz from directory contents (NOT including the directory itself).[br]
## Example: dir="/home/user/src" creates tar.gz with contents of src/, not src/ folder itself.
static func create_from_dir(dir: String, data: Dictionary) -> Artifact:
	if not DirAccess.dir_exists_absolute(dir):
		push_error("Directory does not exist: %s" % dir)
		return null
	
	# Generate temp filename based on directory name or random
	var dir_name := dir.get_file() if not dir.get_file().is_empty() else "artifact"
	var temp_file := OS.get_cache_dir().path_join("%s_%d.tar.gz" % [dir_name, Time.get_ticks_msec()])
	
	var args: PackedStringArray
	var command: String
	
	# Platform-specific tar command
	if OS.get_name() == "Windows":
		# Windows: use tar.exe (available in Windows 10+)
		command = "tar"
		args = ["-czf", temp_file, "-C", dir, "."]
	elif OS.get_name() == "Linux" or OS.get_name() == "MacOS":
		# Linux/Mac: standard tar
		command = "tar"
		args = ["-czf", temp_file, "-C", dir, "."]
	else:
		SingletonObject.ErrorDisplay("Can't package", "Can't package tar.gz on currently this system: %s" % OS.get_name())
		return null
	
	# Execute tar command
	var output: Array = []
	var exit_code := OS.execute(command, args, output, true)
	
	if exit_code != OK:
		push_error("Failed to create tar.gz: exit code %d, output: %s" % [exit_code, "\n".join(output)])
		return null
	
	# Create artifact from the generated tar file
	var artifact := create_from_file(temp_file, data)
	
	# Clean up temp file
	DirAccess.remove_absolute(temp_file)
	
	return artifact


## Returns dictionary ready for artifact/upload request
func get_data_for_upload() -> Dictionary:
	var upload_data := {
		"filename": filename,
		"content": _base64,
		"description": description,
		"visibility": visibility,
	}
	
	# Only include non-empty optional fields
	if not framework.is_empty():
		upload_data["framework"] = framework
	if not language.is_empty():
		upload_data["language"] = language
	if not tags.is_empty():
		upload_data["tags"] = tags
	
	return upload_data