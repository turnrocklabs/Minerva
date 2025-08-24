class_name NoteField
extends VBoxContainer

static var _scene: = preload("res://Scripts/Services/Providers/Core/dynamic_ui/note/note_scene.tscn")

@onready var _field_name_label: Label = %FieldName
@onready var _field_rich_text_label: RichTextLabel = %RichTextLabel

var _requested_fields: String

var selected_notes: = 0:
	set(value):
		selected_notes = value
		_field_rich_text_label.text = "Selected %s notes" % selected_notes


static func create(field_params: Dictionary, input: = true) -> NoteField:
	
	var scn: NoteField = _scene.instantiate()

	scn.ready.connect(
		func():
			scn._field_name_label.text = field_params["display_name"] + ":"
			scn._requested_fields = field_params.get("fields", "")

			if input:
				scn.selected_notes = scn.selected_notes
				for t in SingletonObject.ThreadList:
					for item in t.MemoryItemList:
						if item.Enabled:
							scn.selected_notes += 1
				
				SingletonObject.note_toggled.connect(
					func(_note: Note, on: bool):
						if on:
							scn.selected_notes += 1
						else:
							scn.selected_notes -= 1
				)

			else:
				# TODO: RECREATE THE NODES
				pass
	)

	return scn

func get_user_data():
	var data: Array[Dictionary] = []
	
	for t in SingletonObject.ThreadList:
		for item in t.MemoryItemList:
			if item.Enabled:
				var serialized_note = item.Serialize(false)
				
				if _requested_fields.is_empty():
					data.append(serialized_note)
				else:
					print("Requested note fields are: %s" % _requested_fields)
					var serialized_part: = {}
					for field in _requested_fields:
						serialized_part[field] = serialized_note.get(field, "")

						if not serialized_part[field]:
							push_error("Couldn't extract requested field '%s' from the note" % field)

					data.append(serialized_part)

	return data

func update_output(notes: Array) -> void:

	var orphans: Dictionary = {}

	for note_data in notes:
		var item: = MemoryItem.Deserialize(note_data)
		var owning_thread: String = item.OwningThread if item.OwningThread else ""
		var item_uuid: String = item.UUID if item.UUID else ""

		if owning_thread.is_empty():
			if orphans.has(owning_thread):
				orphans[owning_thread].append(item)
			else:
				orphans[owning_thread] = [item]

			continue

		var found: = false
		
		for i in SingletonObject.ThreadList.size():
			var thread: = SingletonObject.ThreadList[i]
			if thread.ThreadId == owning_thread:
				
				# check if this memory item already exists
				for existing_item in thread.MemoryItemList:
					if existing_item.UUID == item_uuid:
						thread.MemoryItemList[i] = item # just replace the item

				# if not just append this note
				if not thread.MemoryItemList.has(item):
					thread.MemoryItemList.append(item)
				
				found = true

				break

		# if we found the target thread, stop here
		if found: continue

		# if we get here the item owner thread wasn't found
		if orphans.has(owning_thread):
			orphans[owning_thread].append(item)
		else:
			orphans[owning_thread] = [item]


	# if a note doesn't have a owning thread set (empty string)
	# the note will be duplicated each time since we can't know what it's associated with
	# we may go through all threads and memory items and try to find the matching memory item UUID
	# but this is a rare problem
	for owning_thread in orphans.keys():
		var thread = MemoryThread.new(owning_thread)
		thread.ThreadName = "Remote Orphan Notes"
		
		for item: MemoryItem in orphans[owning_thread]:
			thread.MemoryItemList.append(item)

		SingletonObject.ThreadList.append(thread)

	SingletonObject.NotesTab.render_threads()
