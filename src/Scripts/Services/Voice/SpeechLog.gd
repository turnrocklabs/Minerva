class_name SpeechLog
extends RefCounted
## One atomic file per admission; no audio, retention cap or shadow index.
const Atomic = preload("res://Scripts/Services/Plugins/AtomicFile.gd")
const VERSION: int = 1
var _directory: String
var _write: Callable
var _records: Dictionary = {}
var _order: int = 0
var errors: Array[String] = []
var ready: bool = true


func _init(directory: String, writer: Callable = Atomic.write) -> void:
	_directory = directory
	_write = writer
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		ready = false
		errors.append("Speech log directory is unavailable.")
		return
	var folder: DirAccess = DirAccess.open(directory)
	if folder == null:
		ready = false
		errors.append("Speech log directory cannot be read.")
		return
	for filename: String in folder.get_files():
		if not filename.ends_with(".json"):
			continue
		# Reserve even corrupt admission filenames before parsing their content.
		var filename_order: int = filename.get_basename().trim_prefix("speech_").to_int()
		if filename_order > 0 and filename_order <= 9007199254740991:
			_order = maxi(_order, filename_order)
		var file: FileAccess = FileAccess.open(directory.path_join(filename), FileAccess.READ)
		var parsed: Variant = JSON.parse_string(file.get_as_text()) if file != null else null
		if file != null:
			file.close()
		if not parsed is Dictionary:
			errors.append("Unreadable or unsupported speech record: " + filename)
			continue
		var record: Dictionary = parsed
		if not _valid(record) or filename != str(record.log_id) + ".json":
			errors.append("Unreadable or unsupported speech record: " + filename)
			continue
		_records[record.log_id] = record
		var order_number: float = record.admission_order
		_order = maxi(_order, int(order_number))


static func is_integer(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = value
	return is_finite(number) and number == floor(number) and number >= 0 and number <= 9007199254740991.0


static func _valid(record: Dictionary) -> bool:
	if record.get("version") != VERSION or not record.get("log_id") is String or not str(record.log_id).is_valid_identifier():
		return false
	if not is_integer(record.get("admission_order")) or not is_integer(record.get("created_at")):
		return false
	for key: String in ["producer", "topic"]:
		if not record.get(key) is String:
			return false
	if not record.get("exempt_ids") is Array:
		return false
	var exemptions: Array = record.exempt_ids
	if not exemptions.all(func(id: Variant) -> bool: return id is String and str(id).is_valid_identifier()):
		return false
	if not record.get("deleted") is bool:
		return false
	if record.deleted:
		return record.size() == 9
	for key: String in ["text", "original_text", "summary", "device", "voice_id", "voice_name", "backend", "error", "fallback_reason"]:
		if not record.get(key) is String:
			return false
	if not record.get("summary_explicit", false) is bool or not record.get("heard") is bool or not record.get("origin") is Dictionary or not (record.get("volume") is float or record.get("volume") is int):
		return false
	var volume: float = record.volume
	return is_finite(volume) and volume >= 0 and volume <= 1


func admit(fields: Dictionary, exempt_ids: Array[String] = []) -> Dictionary:
	if not ready:
		return _failure("Speech log directory is unavailable: " + "; ".join(errors))
	_order += 1
	while FileAccess.file_exists(_directory.path_join("speech_%d.json" % _order)):
		_order += 1
	var record: Dictionary = fields.duplicate(true)
	record.merge({"version": VERSION, "log_id": "speech_%d" % _order, "admission_order": _order,
		"created_at": int(Time.get_unix_time_from_system()), "deleted": false, "heard": false, "exempt_ids": exempt_ids.duplicate()}, true)
	return _commit(record)


func update_record(id: String, fields: Dictionary) -> Dictionary:
	var record: Dictionary = _records.get(id, {})
	record = record.duplicate(true)
	if record.is_empty() or record.get("deleted", false):
		return _failure("Speech record is unavailable.")
	record.merge(fields, true)
	return _commit(record)


func delete_record(id: String) -> Dictionary:
	var original: Dictionary = _records.get(id, {})
	if original.is_empty() or original.get("deleted", false):
		return _failure("Speech record is unavailable.")
	var tombstone: Dictionary = {"deleted": true}
	for key: String in ["version", "log_id", "created_at", "admission_order", "producer", "topic", "exempt_ids"]:
		tombstone[key] = original[key]
	# Retain only admission metadata; deleting newer content must not revive old content.
	tombstone["tombstone"] = true
	return _commit(tombstone)


func _commit(record: Dictionary) -> Dictionary:
	if not ready or not _valid(record):
		return _failure("Speech log validation failed; existing records are retained.")
	var id: String = record.log_id
	if not _write.call(_directory.path_join(id + ".json"), JSON.stringify(record)):
		return _failure("Speech log could not be saved; existing records are retained.")
	_records[id] = record
	return {"success": true, "record": get_record(id)}


func get_record(id: String) -> Dictionary:
	var record: Dictionary = _records.get(id, {})
	if record.is_empty() or record.deleted:
		return {}
	var result: Dictionary = record.duplicate(true)
	result["superseded"] = false
	if not record.heard and not str(record.topic).is_empty():
		var order_number: float = record.admission_order
		for newer: Dictionary in _records.values():
			var newer_order: float = newer.admission_order
			if newer_order > order_number and newer.producer == record.producer and newer.topic == record.topic and id not in newer.exempt_ids:
				result.superseded = true
				break
	return result


func list_records(producer: String = "", topic: String = "") -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for id: String in _records:
		var record: Dictionary = get_record(id)
		if not record.is_empty() and (producer.is_empty() or record.producer == producer) and (topic.is_empty() or record.topic == topic):
			records.append(record)
	records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var left: float = a.admission_order
		var right: float = b.admission_order
		return left > right)
	return records


static func _failure(message: String) -> Dictionary:
	return {"success": false, "error_code": "speech_log_write", "error_message": message}
