class_name NoteServiceAdapter
extends RefCounted

enum ACTION_TYPE {
	LIST_THREADS,
	CREATE_THREAD,
	UPDATE_THREAD,
	DELETE_THREAD,
	GET_NOTES,
	SAVE_NOTES,
	PATCH_NOTES,
	DELETE_NOTES,
}

var service: Service
var _last_response: Dictionary

func _init(service_: Service) -> void:
	service = service_

func info(input):
	print("#\n#### NoteServiceAdapter: %s\n#" % str(input))

static func get_service_name() -> StringName:
	push_error("get_service_name not implemented")
	return &""

# ============================================================================
# THREAD METHODS
# ============================================================================

## List all threads - returns Array[NoteVBox] with thread data
func list_threads() -> Array[NoteVBox]:
	await Engine.get_main_loop().process_frame
	push_error("list_threads not implemented")
	return []

## Create a new thread - returns true on success
func create_thread(_thread_name: String, _thread_uuid: String = "", _order: int = -1, _metadata: Dictionary = {}) -> bool:
	await Engine.get_main_loop().process_frame
	push_error("create_thread not implemented")
	return false

## Update thread properties - returns true on success
func update_thread(_thread_uuid: String, _thread_name: String = "", _order: int = -1, _metadata: Dictionary = {}, _display_error: = true) -> bool:
	await Engine.get_main_loop().process_frame
	push_error("update_thread not implemented")
	return false

## Delete thread and all its notes - returns true on success
func delete_thread(_thread_uuid: String, _display_error: = true) -> bool:
	await Engine.get_main_loop().process_frame
	push_error("delete_thread not implemented")
	return false

# ============================================================================
# NOTE METHODS
# ============================================================================

## Get notes with optional filters - returns Array[Note]
func get_notes(_thread_id: String = "", _filters: Dictionary = {}) -> Array[Note]:
	await Engine.get_main_loop().process_frame
	push_error("get_notes not implemented")
	return []

## Get all notes (convenience method)
func get_all_notes() -> Array[Note]:
	return await get_notes()

## Save (create or update) notes - returns true on success
func save_notes(_notes: Array[Note]) -> bool:
	await Engine.get_main_loop().process_frame
	push_error("save_notes not implemented")
	return false

## Patch notes with specific fields - returns true on success
## If patch fails, automatically falls back to save_notes
func patch_notes(_notes: Array[Note], _fields: Array[String]) -> bool:
	await Engine.get_main_loop().process_frame
	push_error("patch_notes not implemented")
	return false

## Delete notes - returns true on success
func delete_notes(_notes: Array[Note]) -> bool:
	await Engine.get_main_loop().process_frame
	push_error("delete_notes not implemented")
	return false

func handle_action(_action: Action, _data: Variant) -> bool:
	await Engine.get_main_loop().process_frame
	push_error("handle_action not implemented")
	return false

func get_last_action_response() -> Dictionary:
	return _last_response

func safe_extract(data: Dictionary, fields: Array[String], types: Array[int], default: Variant = null) -> Variant:
	var current = data
	for i in fields.size():
		var field: = fields[i]
		var type: int = types[i] if i < types.size() else -1
		
		if field not in current:
			info("Field '%s' doesn't exist in current data" % field)
			return default
		
		current = current[field]
		
		if type != -1 and typeof(current) != type:
			info("Field '%s' has type '%s' but '%s' expected" % [field, type_string(typeof(current)), type_string(type)])
			return default
	
	return current

func _get_note_order_for_remote(note: Note) -> int:
	var tab_idx = SingletonObject.notes_container.find_note(note)
	if tab_idx == -1:
		return 0
	
	var notes_in_tab: = SingletonObject.notes_container.get_notes(tab_idx)
	var note_index = notes_in_tab.find(note)
	
	return note_index if note_index != -1 else 0