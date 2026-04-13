class_name ProviderModelManager
extends RefCounted
## Base class for managing dynamic model configurations per provider.
## Handles JSON persistence, CRUD operations, and dynamic ID assignment.
## Subclass for provider-specific behavior (e.g., API model fetching).

signal models_changed()

## Path to the JSON config file (set by subclass or constructor)
var config_path: String

## Base ID for dynamic models (each provider uses a different range)
var dynamic_id_base: int

## List of model config dictionaries
var models: Array[Dictionary] = []

## Next available dynamic ID
var _next_id: int


func _init(p_config_path: String = "", p_dynamic_id_base: int = 10000, p_defaults: Array = []) -> void:
	config_path = p_config_path
	dynamic_id_base = p_dynamic_id_base
	_next_id = p_dynamic_id_base
	for d in p_defaults:
		_defaults.append(d)


## Default model configs to seed on first run (override in subclass or pass to constructor)
var _defaults: Array[Dictionary] = []


func load_config() -> void:
	if config_path.is_empty():
		return

	if not FileAccess.file_exists(config_path):
		# First run — populate with defaults
		for default_config in _defaults:
			var config: Dictionary = default_config.duplicate()
			config["id"] = _next_id
			_next_id += 1
			models.append(config)
		if not models.is_empty():
			save_config()
		return

	var file := FileAccess.open(config_path, FileAccess.READ)
	if not file:
		push_error("[ProviderModelManager] Failed to open config: %s" % error_string(FileAccess.get_open_error()))
		return

	var json_text := file.get_as_text()
	file.close()

	var data = JSON.parse_string(json_text)
	if data is Dictionary:
		_next_id = data.get("next_id", dynamic_id_base)
		var saved_models = data.get("models", [])
		models.clear()
		for m in saved_models:
			if m is Dictionary and m.has("id") and (m.has("api_model_id") or m.has("model_name")):
				models.append(m)


func save_config() -> void:
	if config_path.is_empty():
		return

	var data := {
		"next_id": _next_id,
		"models": models,
	}
	var file := FileAccess.open(config_path, FileAccess.WRITE)
	if not file:
		push_error("[ProviderModelManager] Failed to save config: %s" % error_string(FileAccess.get_open_error()))
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()


func add_model(config: Dictionary) -> int:
	var model_config := config.duplicate()
	model_config["id"] = _next_id
	_next_id += 1
	models.append(model_config)
	save_config()
	models_changed.emit()
	return model_config["id"]


func update_model(model_id: int, config: Dictionary) -> void:
	for i in range(models.size()):
		if models[i].get("id") == model_id:
			var updated := config.duplicate()
			updated["id"] = model_id
			models[i] = updated
			save_config()
			models_changed.emit()
			return


func remove_model(model_id: int) -> void:
	for i in range(models.size()):
		if models[i].get("id") == model_id:
			models.remove_at(i)
			save_config()
			models_changed.emit()
			return


func get_model(model_id: int) -> Dictionary:
	for m in models:
		if m.get("id") == model_id:
			return m
	return {}


## Get the preferred tool mode for a model. Returns "dynamic" (default) or "static".
func get_tool_mode(model_id: int) -> String:
	var model := get_model(model_id)
	return model.get("tool_mode", "dynamic")


func get_model_by_name(name_key: String, name_value: String) -> Dictionary:
	for m in models:
		if m.get(name_key) == name_value:
			return m
	return {}
