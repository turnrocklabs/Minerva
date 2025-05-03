extends Control
class_name ThreadedNotesManager

signal data_saved(status: int)
signal data_loaded(status: int)

# Changed path to res:// location
var data_path: String = "res://Lib/Drawer/drawer_data.json"

# Save all drawer data to JSON file
func save_data() -> void:
	# 1. Verify we have data to save
	if SingletonObject.DrawerThreadList.is_empty():
		push_error("Nothing to save - DrawerThreadList is empty!")
		data_saved.emit(ERR_INVALID_DATA)
		return
	
	# 2. Prepare the data structure
	var save_data = {
		"version": 1,
		"timestamp": Time.get_datetime_string_from_system(),
		"threads": SingletonObject.DrawerThreadList.duplicate(true)
	}
	
	# 3. Convert to JSON
	var json_string = JSON.stringify(save_data, "\t")
	if json_string.is_empty():
		push_error("Failed to convert data to JSON")
		data_saved.emit(ERR_INVALID_DATA)
		return
	
	print("Saving JSON data:\n", json_string)  # Debug output
	
	# 4. Write to res:// location (requires special handling)
	var global_path = ProjectSettings.globalize_path(data_path)
	var file = FileAccess.open(global_path, FileAccess.WRITE)
	if file == null:
		var error = FileAccess.get_open_error()
		push_error("File open failed with error: ", error)
		data_saved.emit(error)
		return
	
	file.store_string(json_string)
	file.flush()  # Force write to disk
	file.close()
	
	print("Data successfully saved to: ", global_path)
	data_saved.emit(OK)

# Load drawer data from JSON file
func load_data() -> void:
	# 1. Check if file exists
	if not FileAccess.file_exists(data_path):
		push_error("No save file found at: ", data_path)
		data_loaded.emit(ERR_FILE_NOT_FOUND)
		return
	
	# 2. Open and read file
	var file = FileAccess.open(data_path, FileAccess.READ)
	if file == null:
		var error = FileAccess.get_open_error()
		push_error("File open failed with error: ", error)
		data_loaded.emit(error)
		return
	
	var json_text = file.get_as_text()
	file.close()
	
	# 3. Parse JSON
	var json = JSON.new()
	var parse_result = json.parse(json_text)
	if parse_result != OK:
		push_error("JSON parse error: ", json.get_error_message())
		data_loaded.emit(ERR_PARSE_ERROR)
		return
	
	var data = json.get_data()
	
	# 4. Restore data
	if data.has("threads"):
		SingletonObject.DrawerThreadList = data["threads"].duplicate(true)
		print("Loaded ", SingletonObject.DrawerThreadList.size(), " threads")
		data_loaded.emit(OK)
	else:
		push_error("Invalid data format - missing 'threads' key")
		data_loaded.emit(ERR_INVALID_DATA)

# Quick save with error checking
func quick_save() -> bool:
	save_data()
	var status = await data_saved
	return status == OK

# Quick load with error checking
func quick_load() -> bool:
	load_data()
	var status = await data_loaded
	return status == OK

func _on_save_data_pressed() -> void:
	print("=== Attempting to save ===")
	print("Current data count: ", SingletonObject.DrawerThreadList.size())
	
	var success = await quick_save()
	
	if success:
		print("=== SAVE SUCCESSFUL ===")
		# Verify by loading immediately
		var verify = await quick_load()
		if verify:
			print("Verified load: ", SingletonObject.DrawerThreadList.size(), " items")
		else:
			print("Verification failed!")
	else:
		print("=== SAVE FAILED ===")
	
	await get_tree().create_timer(1.0).timeout


func _on_o_pen_pressed() -> void:
	load_data()
