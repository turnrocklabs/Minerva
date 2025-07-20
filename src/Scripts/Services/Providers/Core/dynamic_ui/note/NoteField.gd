class_name NoteField
extends VBoxContainer

static var _scene: = preload("res://Scripts/Services/Providers/Core/dynamic_ui/note/note_scene.tscn")

@onready var _field_name_label: Label = %FieldName
@onready var _field_rich_text_label: RichTextLabel = %RichTextLabel

var selected_notes: = 0:
	set(value):
		selected_notes = value
		_field_rich_text_label.text = "Selected %s notes" % selected_notes


static func create(field_params: Dictionary, input: = true) -> NoteField:
	
	var scn: NoteField = _scene.instantiate()

	scn.ready.connect(
		func():
			scn._field_name_label.text = field_params["display_name"] + ":"

			if input:
				scn.selected_notes = scn.selected_notes
				for thread in SingletonObject.ThreadList:
					for item in thread.MemoryItemList:
						if item.Enabled:
							scn.selected_notes += 1
				
				SingletonObject.note_toggled.connect(
					func(_note: Note, on: bool):
						if on:
							scn.selected_notes += 1
						else:
							scn.selected_notes -= 1
				)

			# else use rich text label
			else:
				# TODO: RECREATE THE NODES
				pass
	)

	return scn

func get_user_data():
	var data: Array[Dictionary] = []
	
	for thread in SingletonObject.ThreadList:
		for item in thread.MemoryItemList:
			if item.Enabled:
				data.append(item.Serialize(false))
	
	print("DATA FOR NOTES IS")
	print(data)

	return data

func update_output(notes: Array[Dictionary]) -> void:
	pass
	# _field_rich_text_label.text = text
