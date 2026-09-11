class_name CoreModelPreferences
extends RefCounted
## One-time migration from display labels to Core model identities.

const FIELDS := {"Timeouts": "_model_timeouts", "Contexts": "_model_contexts", "NumGpu": "_model_num_gpu"}
const MIGRATIONS := "CoreActionMigrations"


static func ensure_migrated(spec: Dictionary, core: Node = null, host: Node = null) -> Dictionary:
	var settings := host if host != null else CoreModelCatalog.settings_host()
	if settings == null:
		return {"status": "unavailable"}
	var result := migrate(settings.config_file, settings.get("_config_file_name"), spec,
		CoreModelCatalog.list_models(core, settings, true))
	if result.get("changed", false):
		# Keep the existing host preference API's caches in sync with the saved map.
		for field in FIELDS:
			settings.set(FIELDS[field], settings.config_file.get_value("Models", field, {}).duplicate(true))
	return result


## Save the maps and marker together; never apply a migration that failed to persist.
static func migrate(config: ConfigFile, path: String, spec: Dictionary, candidates: Array[Dictionary]) -> Dictionary:
	var key := CoreModelCatalog.settings_key(spec)
	if key.is_empty():
		return {"status": "invalid_model_spec"}
	var old_markers: Dictionary = config.get_value("Models", MIGRATIONS, {})
	var markers := old_markers.duplicate(true)
	# Remember every encountered ambiguous identity, even one not selected yet.
	var labels: Dictionary = {}
	for candidate in candidates:
		labels[candidate.display] = labels.get(candidate.display, 0) + 1
	for candidate in candidates:
		if not candidate.settings_key.is_empty() and not markers.has(candidate.settings_key) \
				and (labels[candidate.display] > 1 or candidate.unavailable_reason == "model_ambiguous"):
			markers[candidate.settings_key] = "blocked_ambiguous"
	if markers.has(key) and markers == old_markers:
		return {"status": markers[key], "changed": false}
	var matches: Array[Dictionary] = []
	for candidate in candidates:
		if candidate.settings_key == key:
			matches.append(candidate)
	if matches.is_empty():
		return {"status": "unavailable"}
	var selected: Dictionary = matches[0]
	var count := 0
	for candidate in candidates:
		if candidate.display == selected.display:
			count += 1
	var ambiguous: bool = matches.size() != 1 or count != 1 or selected.unavailable_reason == "model_ambiguous"
	var status: String = markers.get(key, "blocked_ambiguous" if ambiguous else "complete")
	if not ambiguous and selected.unavailable_reason == "invalid_model_descriptor":
		return {"status": "invalid_model_descriptor"}

	var updated := ConfigFile.new()
	var parse_error := updated.parse(config.encode_to_text())
	if parse_error != OK:
		return {"status": "persistence_error", "error": parse_error}
	if not ambiguous and not old_markers.has(key):
		for field in FIELDS:
			var values: Dictionary = updated.get_value("Models", field, {}).duplicate(true)
			if not values.has(key) and values.has(selected.display) and _valid_legacy(field, values[selected.display]):
				values[key] = values[selected.display]
			updated.set_value("Models", field, values)
	markers = markers.duplicate(true)
	markers[key] = status
	updated.set_value("Models", MIGRATIONS, markers)
	var save_error := updated.save(path)
	if save_error != OK:
		push_warning("Core model preference migration could not be saved: %s" % error_string(save_error))
		return {"status": "persistence_error", "error": save_error}
	for field in FIELDS:
		config.set_value("Models", field, updated.get_value("Models", field, {}))
	config.set_value("Models", MIGRATIONS, markers)
	return {"status": status, "changed": true}


static func _valid_legacy(field: String, value: Variant) -> bool:
	if not (value is int or value is float) or not is_finite(float(value)):
		return false
	if field == "Timeouts":
		return value > 0
	if float(value) != floor(float(value)):
		return false
	return value >= 0 if field == "NumGpu" else value > 0
