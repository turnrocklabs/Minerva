class_name NoteServiceAdapter
extends RefCounted

var service: Service

func _init(service_: Service) -> void:
	service = service_

func info(input):
	print("#\n#### NoteServiceAdapter: %s\n#" % str(input))

static func get_service_name() -> StringName:
	push_error("get_service_name not implemented")
	return &""

func delete_notes(_notes: Array[Note]) -> bool:
	# dummy await so we get rid of the REDUNDANT_AWAIT warning
	await Engine.get_main_loop().process_frame
	push_error("delete_notes not implemented")
	return false

func save_notes(_notes: Array[Note]) -> bool:
	# dummy await so we get rid of the REDUNDANT_AWAIT warning
	await Engine.get_main_loop().process_frame
	push_error("save_notes not implemented") 
	return false

func get_all_notes() -> Array[Note]:
	# dummy await so we get rid of the REDUNDANT_AWAIT warning
	await Engine.get_main_loop().process_frame
	push_error("get_all_notes not implemented")
	return []


func handle_action(action: Action, data: Variant) -> bool:
	# dummy await so we get rid of the REDUNDANT_AWAIT warning
	await Engine.get_main_loop().process_frame
	push_error("get_all_notes not implemented")
	return false

func safe_extract(data: Dictionary, fields: Array[String], types: Array[int], default: Variant = null) -> Variant:
	
	var current = data

	for i in fields.size():
		var field: = fields[i]
		var type: int = types[i] if i < types.size() else -1
		
		if field not in current:
			info("Field '%s' doesn't exist in the current data %s" % [field, current])
			return default

		current = current[field]

		if type == -1: continue

		if typeof(current) != type:
			info("Field '%s' has type '%s' but '%s' expected" % [field, type_string(typeof(current)), type_string(type)])
			return default
	
	return current


## Takes the local note and determins it's order value
## from the all note
func _get_note_order_for_remote(note: Note) -> int:
	# Find which tab this note belongs to
	var tab_idx = SingletonObject.notes_container.find_note(note)
	if tab_idx == -1:
		info("Note not found in any tab")
		return 0
	
	# Get all notes in that tab
	var notes_in_tab = SingletonObject.notes_container.get_notes(tab_idx)
	
	# Find the position of our note
	var note_index = notes_in_tab.find(note)
	if note_index == -1:
		info("Could not find note in tab %d" % tab_idx)
		return 0
	
	for i in range(tab_idx):
		note_index += SingletonObject.notes_container.get_notes(i).size()

	info("Note '%s' has order %d in tab %d (%d total notes)" % [note.title, note_index, tab_idx, notes_in_tab.size()])
	return note_index