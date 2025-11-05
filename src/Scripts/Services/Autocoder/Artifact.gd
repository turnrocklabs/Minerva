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


## Creates an [class Artifact] object ready for upload to registry.[br]
## [param tar_file] must be an absolute path of file that ends with `.tar.gz`
static func create_from_file(tar_file: String, data: Dictionary) -> Artifact:
	if not tar_file.is_absolute_path() or not tar_file.get_file().ends_with(".tar.gz"):
		return null

	var artifact: = Artifact.new(data)

	var bytes: = FileAccess.get_file_as_bytes(tar_file)

	if bytes.is_empty(): # TODO: check last error
		return null

	artifact._base64 = Marshalls.raw_to_base64(bytes)

	return artifact


static func create_from_dir(dir: String, data: Dictionary) -> Artifact:
	
	var temp_file: = OS.get_temp_dir().path_join("%s.tar.gz" % dir.get_file())

	var err := OS.execute("tar", ["-czf", temp_file, "-C", dir, "."])

	if err != OK:
		return null

	return create_from_file(temp_file, data)

func get_data_for_upload() -> Dictionary:

	# TODO: add rest of the fields
	return {
		"filename": filename,
		"content": _base64,
		"description": description,
		"framework": framework,
		"language": language,
		"visibility": visibility,
		"tags": tags,
	}
