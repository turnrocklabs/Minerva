extends Control
class_name DrawerNotesManager

var data_path: String = "user://drawer_data.json"

## Whether we have already loaded the drawer data on open
var _loaded: = false

func _ready() -> void:
	# Eager load: restore drawer data on startup so it's never empty when save fires
	load_drawer_data.call_deferred()

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST:
			if _loaded:
				save_drawer_data()


## Main save function - called by signal
func save_drawer_data() -> void:
	var data: = {
		"version": 1,
		"timestamp": Time.get_datetime_string_from_system(),
		"notes": SingletonObject.drawer_notes_container.serialize(),
	}

	write_data_to_file(data)


## Write serialized data to file
func write_data_to_file(data: Dictionary) -> void:
	var file = FileAccess.open(data_path, FileAccess.WRITE)
	if file:
		file.store_line(JSON.stringify(data, "\t"))
		file.close()
		print("Drawer data saved successfully")
	else:
		push_error("Failed to save drawer data: " + error_string(FileAccess.get_open_error()))

## Main load function
func load_drawer_data() -> void:
	if _loaded: return
	
	_loaded = true
	if not FileAccess.file_exists(data_path):
		print("No drawer data file found - starting fresh")
		return
	
	var data = read_data_from_file()
	if data.is_empty():
		return
		
	SingletonObject.drawer_notes_container.deserialize(data.get("notes", []))

## Read and parse data from file
func read_data_from_file() -> Dictionary:
	var file = FileAccess.open(data_path, FileAccess.READ)
	if not file:
		push_error("Failed to open drawer data file: " + error_string(FileAccess.get_open_error()))
		return {}
	
	var json_text = file.get_as_text()
	file.close()
	
	var json = JSON.parse_string(json_text)
	if not json is Dictionary:
		push_error("Invalid JSON in drawer data file")
		return {}
	
	return json

## UI Event Handlers
func _on_add_note_pressed() -> void:
	%CreateNewNote.popup_centered()
	%CreateNewNote.notes_container_override = SingletonObject.drawer_notes_container

func _on_add_shelf_pressed() -> void:
	%NewThreadPopup.popup_centered()
	%NewThreadPopup.notes_container_override = SingletonObject.drawer_notes_container

func _on_save_pressed() -> void:
	save_drawer_data()
	$"..".hide()
	$"../CloseActions".hide()

func _on_close_pressed() -> void:
	$"../CloseActions".hide()

func _on_exit_pressed() -> void:
	$"../CloseActions".hide()
	$"..".hide()
