class_name WebDocumentLifetime
extends RefCounted
## Host-owned identity and immutable file backing for one privileged document.

const ROOT := "user://web-documents"

var generation: int
var capability: String
var directory: String
var file_path: String
var file_url: String

static func create(source: String, generation_value: int):
	var lifetime := WebDocumentLifetime.new()
	lifetime.generation = generation_value
	lifetime.capability = Crypto.new().generate_random_bytes(32).hex_encode()
	lifetime.directory = "%s/%s" % [ROOT,
		Crypto.new().generate_random_bytes(16).hex_encode()]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(lifetime.directory))
	lifetime.file_path = lifetime.directory.path_join("index.html")
	var file := FileAccess.open(lifetime.file_path, FileAccess.WRITE)
	if file == null:
		return null
	var marker := source.find("__MINERVA_DOCUMENT_CAPABILITY__")
	if marker < 0:
		file.close()
		lifetime.dispose()
		return null
	file.store_string(source.substr(0, marker) + lifetime.capability \
		+ source.substr(marker + "__MINERVA_DOCUMENT_CAPABILITY__".length()))
	file.close()
	var absolute := ProjectSettings.globalize_path(lifetime.file_path)
	lifetime.file_url = _absolute_file_url(absolute)
	return lifetime


static func _absolute_file_url(absolute_path: String) -> String:
	var normalized := absolute_path.replace("\\", "/").trim_prefix("/")
	var encoded: PackedStringArray = []
	var parts := normalized.split("/", false)
	for index in range(parts.size()):
		var part: String = parts[index]
		if index == 0 and part.length() == 2 and part.ends_with(":"):
			encoded.append(part.left(1).uri_encode() + ":")
		else:
			encoded.append(part.uri_encode())
	return "file:///" + "/".join(encoded)


static func encode_json(value: Variant) -> Dictionary:
	return load("res://Scripts/Services/MCP/MCPJsonSerialization.gd").encode(value)


func dispose() -> void:
	if file_path.is_empty():
		return
	var absolute_file := ProjectSettings.globalize_path(file_path)
	if FileAccess.file_exists(absolute_file):
		DirAccess.remove_absolute(absolute_file)
	var absolute_dir := ProjectSettings.globalize_path(directory)
	if DirAccess.dir_exists_absolute(absolute_dir):
		DirAccess.remove_absolute(absolute_dir)
	file_path = ""
	directory = ""
	file_url = ""
	capability = ""


func dispose_after_view_node(view: Node) -> void:
	# call_deferred retains this lifetime and the detached view independently
	# of their former editor. Native PREDELETE completes before the immutable
	# backing file is removed.
	if is_instance_valid(view):
		view.free()
	dispose()
