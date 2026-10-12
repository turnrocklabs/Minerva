class_name SelectedModelManager
extends ProviderModelManager
## User selections are independent of discovery. Retired configurations remain
## addressable so projects saved with an older numeric ID can still be opened.

signal persistence_failed(message: String)

var legacy_models: Dictionary = {}
var load_error: String = ""


func load_config() -> void:
	if not FileAccess.file_exists(config_path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(config_path))
	if not parsed is Dictionary or not parsed.get("models") is Array:
		load_error = "Invalid model selections: %s" % config_path
		_report_error(load_error)
		return
	var data: Dictionary = parsed
	if not data.get("legacy_models", {}) is Dictionary or int(data.get("selection_version", 0)) > 1:
		load_error = "Unsupported model selections: %s" % config_path
		_report_error(load_error)
		return
	_next_id = int(data.get("next_id", dynamic_id_base))
	legacy_models = data.get("legacy_models", {}).duplicate(true)
	models.clear()
	var seen: Dictionary = {}
	for value: Variant in data.models:
		if not value is Dictionary or not value.has("id") or not value.has("model_name"):
			load_error = "Invalid model entry in %s" % config_path
			_report_error(load_error)
			return
		var config: Dictionary = value.duplicate(true)
		var id := int(config.id)
		_next_id = maxi(_next_id, id + 1)
		if int(data.get("selection_version", 0)) < 1:
			legacy_models[str(id)] = config.duplicate(true)
		config = selected_config(config)
		var name: String = str(config.model_name)
		if not seen.has(name):
			seen[name] = true
			models.append(config)
	if int(data.get("selection_version", 0)) < 1:
		var backup := config_path + ".before-selection-migration"
		if not FileAccess.file_exists(backup):
			var err := DirAccess.copy_absolute(config_path, backup)
			if err != OK:
				load_error = "Cannot back up model selections: %s" % error_string(err)
				_report_error(load_error)
				return
		save_config()


static func selected_config(config: Dictionary) -> Dictionary:
	if config.is_empty():
		return {}
	var selected := config.duplicate(true)
	var name: String = str(selected.get("model_name", ""))
	var effort: String = str(selected.get("reasoning_effort", ""))
	var label: String = str(selected.get("display_name", name))
	if not effort.is_empty():
		var suffix := " (%s)" % ("XHigh" if effort == "xhigh" else effort.capitalize())
		label = label.trim_suffix(suffix)
	selected["display_name"] = label
	selected["catalog_key"] = name
	selected.erase("reasoning_effort")
	selected.erase("reasoning_description")
	return selected


func save_config() -> void:
	if not load_error.is_empty():
		_report_error(load_error)
		return
	var temporary := config_path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		_report_error("Cannot write model selections: %s" % error_string(FileAccess.get_open_error()))
		return
	file.store_string(JSON.stringify({"selection_version": 1, "next_id": _next_id,
		"models": models, "legacy_models": legacy_models}, "\t"))
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		_report_error("Cannot save model selections: %s" % error_string(write_error))
		return
	var err := DirAccess.rename_absolute(temporary, config_path)
	if err != OK:
		_report_error("Cannot replace model selections: %s" % error_string(err))


func add_model(config: Dictionary) -> int:
	var existing := get_model_by_name("model_name", str(config.get("model_name", "")))
	if not existing.is_empty():
		return int(existing.id)
	return super.add_model(selected_config(config))


func update_model(model_id: int, config: Dictionary) -> void:
	var duplicate := get_model_by_name("model_name", str(config.get("model_name", "")))
	if not duplicate.is_empty() and int(duplicate.id) != model_id:
		_report_error("This model is already selected.")
		return
	super.update_model(model_id, selected_config(config))


func remove_model(model_id: int) -> void:
	var config := super.get_model(model_id)
	if not config.is_empty():
		var original_effort := legacy_effort(model_id)
		legacy_models[str(model_id)] = config.duplicate(true)
		# Current custom settings and original effort have different lifetimes.
		legacy_models[str(model_id)]["reasoning_effort"] = original_effort
	super.remove_model(model_id)


func get_model(model_id: int) -> Dictionary:
	var config := super.get_model(model_id)
	if config.is_empty():
		config = selected_config(legacy_models.get(str(model_id), {}))
	return config


func legacy_effort(model_id: int) -> String:
	return str(legacy_models.get(str(model_id), {}).get("reasoning_effort", ""))


## Refresh only metadata for explicitly selected entries. An empty selection
## stays empty; models absent from a transient catalog are not deleted.
func refresh_selected(available: Array) -> void:
	for current: Dictionary in models:
		for value: Variant in available:
			if value is Dictionary and value.get("model_name") == current.get("model_name"):
				var id := int(current.id)
				var label: String = str(current.get("display_name", ""))
				var metadata := selected_config(value)
				for field: String in ["id", "display_name", "short_name", "input_token_cost", "output_token_cost", "tool_mode"]:
					metadata.erase(field)
				current.merge(metadata, true)
				current["id"] = id
				current["display_name"] = label
				break
	save_config()
	models_changed.emit()


func _report_error(message: String) -> void:
	push_error(message)
	persistence_failed.emit(message)
