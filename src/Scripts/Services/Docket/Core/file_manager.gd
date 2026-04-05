extends RefCounted
class_name FileManager
## Load/save single .dct files (JSON internally).


static func create_new(path: String) -> Dictionary:
	var data := {
		"version": "1.0.0",
		"counter": 0,
		"items": {},
		"queries": {},
	}
	save(path, data)
	return data


static func save(path: String, data: Dictionary) -> void:
	var json_str := JSON.stringify(data, "\t")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(json_str)
		f.close()


static func load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"error": "File not found: %s" % path}

	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return {"error": "Cannot open: %s" % path}

	var text := f.get_as_text()
	f.close()

	var parsed = JSON.parse_string(text)
	if parsed == null:
		return {"error": "Invalid JSON in %s" % path}

	return parsed
