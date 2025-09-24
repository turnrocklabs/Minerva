class_name NoteVBox
extends VBoxContainer

## Emitted when a new Note node is added to this objects vbox container.
signal note_added(note: Note)
signal auto_upload_toggled(on: bool)

static var _scene: = preload("res://Scenes/note/NoteVBox.tscn")

@onready var _vbox: VBoxContainer = %VBoxContainer

@onready var _remote_option_container: Container = %RemoteOptionsContainer
@onready var _remote_check_buttion: CheckButton = %RemoteCheckButton
@onready var _remote_service_label: Label = %RemoteServiceLabel

@onready var _bulk_upload_button: Button = %BulkUploadButton
const _bulk_button_text: = "Upload local notes (%s)"

var auto_upload: bool:
	set(value): _remote_check_buttion.button_pressed = value
	get: return _remote_check_buttion.button_pressed

static func create() -> NoteVBox:
	var scn: = _scene.instantiate()
	return scn


func _ready() -> void:
	_vbox.child_entered_tree.connect(_on_vbox_child_entered_tree)
	_vbox.child_exiting_tree.connect(_on_vbox_child_exiting_tree)

func _on_vbox_child_entered_tree(node: Node):
	if node is Note:
		
		var controller: = SingletonObject.notes_sync_manger.get_sync_controller(node)

		# update the bulk button on state change, or when the note is removed from the tree
		controller.state_changed.connect(func(_state): _update_bulk_button())
		node.tree_exiting.connect(_update_bulk_button)

		_update_bulk_button() # and update now for the state already set in the controller _init

		note_added.emit(node)
		

func _on_vbox_child_exiting_tree(node: Node):
	if node is Note: pass

## Adds the [class Note] object to the VBox container of this instance.
func add_note(note: Note, index: int = 0):
	_vbox.add_child(note)
	_vbox.move_child(note, index)

	prints("NoteVBox added note at:", index)

func get_notes() -> Array[Note]:
	var notes: Array[Note]

	var note_children = _vbox.get_children().filter(func(node: Node): return node is Note)

	notes.assign(note_children)

	return notes

func _on_remote_check_button_toggled(toggled_on: bool) -> void:
	auto_upload_toggled.emit(toggled_on)


func _get_local_notes() -> Array:
	return get_notes().filter(
		func(note: Note):
			if note.is_queued_for_deletion(): return false
			
			var controller: = SingletonObject.notes_sync_manger.get_sync_controller(note)
			print("%s state is %s" % [note, controller.state])
			return not controller.state in [NoteSyncController.SyncState.SYNCED, NoteSyncController.SyncState.SYNCING]
	)


func _on_bulk_upload_button_pressed() -> void:
	var notes: = _get_local_notes()

	var success: = await SingletonObject.notes_sync_manger.sync_notes(notes, false)

	# we'll just display the warning for notes we passed, even tho sync_notes updates other notes also,
	# that update is just the order field
	if not success:
		SingletonObject.ErrorDisplay("Failed", "Couldn't upload the following notes:\n %s" % "\n".join(notes))


func _update_bulk_button() -> void:
	print("\n")
	print("Upldate bulk button")
	print("\n")
	# get all notes that are not synced
	var notes: = _get_local_notes()

	_bulk_upload_button.disabled = notes.is_empty()

	_bulk_upload_button.text = _bulk_button_text % [notes.size()]

	if notes.is_empty():
		_bulk_upload_button.release_focus()
