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


func _init(data: Dictionary = {}) -> void:
	artifact_uri = data.get("artifact_uri", "")
	filename = data.get("filename", "")
	description = data.get("description", "")
	framework = data.get("framework", "")
	language = data.get("language", "")
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
func get_size_formatted() -> String:
	return "%.2f MB" % (float(size) / 1024.0 / 1024.0)


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