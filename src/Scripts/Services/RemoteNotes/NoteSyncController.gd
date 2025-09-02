class_name NoteSyncController
extends RefCounted


## Describes a state of the Note the is synced.[br]
## Used to check if local note that has been changed
## is out of sync wil the last recorded remote content.
class SyncStateInfo extends RefCounted:
	var sha256: String
	var title: String
	var enabled: bool

	func _init(note: Note) -> void:
		sha256 = note.sha256
		title = note.title
		enabled = note.enabled

		print("\n\n")
		prints("Create sync state with values:", title, enabled, sha256)
		print("\n\n")
	
	## Checks if the current note data is out of sync with this state object.
	func is_out_of_sync(target_note: Note):
		return (
			target_note.sha256 != sha256 or
			target_note.title != title or 
			target_note.enabled != enabled
		)


enum SyncState {
	SYNCING,       # Syncing in progress
	SYNCED,        # Note matches remote version
	LOCAL_CHANGES, # Note modified locally, needs push to remote
	LOCAL_ONLY,    # New note, doesn't exist on remote yet
}

var note: Note
var sync_manager: NoteSyncManager
var adapter: NoteServiceAdapter

var state: SyncState = SyncState.LOCAL_ONLY:
	set(value):
		state = value
		_on_state_updated()

var _state_info: SyncStateInfo


func _init(note_: Note, sync_manager_: NoteSyncManager) -> void:
	note = note_
	sync_manager = sync_manager_

	note.changed.connect(_on_note_change)

	_highjack_note_controls()

	# set initial state when the note is ready
	if not note.is_node_ready():
		note.ready.connect(
			func():
				_on_state_updated()
		)

	

func _to_string() -> String:
	return "Controller: %s" % [note]

func info(input):
	print("#\n#### NoteSyncController: %s\n#" % str(input))


func set_adapter(adapter_: NoteServiceAdapter) -> void:
	adapter = adapter_
	print(adapter)

func _highjack_note_controls():
	if not note: return

	note.remove_handle = _on_note_remove_button_pressed

## Sets the new state for this controlles note.[br]
## if [param when_ready] is `true` the state will be set ONLY when the note is ready.
## (is_note_initialized and initialized signals are used).
func set_state(new_state: SyncState, when_ready: = true) -> void:

	if when_ready:
		if not note.is_note_initialized():
			note.initialized.connect(
				(func(): info("Marking %s as SYNCED" % note); state = new_state),
				ConnectFlags.CONNECT_ONE_SHOT
			)
			return

	info("Marking already ready %s as SYNCED" % note)

	state = new_state

func _on_state_updated() -> void:
	
	# if not ready the _init function sets up a signal to update the note button
	# so we don't connect multiple times if this function is run several times
	if not note.is_node_ready():
		return
	
	if state == SyncState.LOCAL_ONLY:
		note.sync_controller_button.visible = false
		note.sync_controller_button.text = ""

		if note.sync_controller_button.pressed.is_connected(_on_sync_controller_button_pressed):
			note.sync_controller_button.pressed.disconnect(_on_sync_controller_button_pressed)
	else:

		match state:
			SyncState.SYNCING:
				note.sync_controller_button.text = "⟳"
				note.sync_controller_button.tooltip_text = "Syncing in progress..."

			SyncState.SYNCED:
				# record the current state info
				_state_info = SyncStateInfo.new(note)

				note.sync_controller_button.text = "☁"
				note.sync_controller_button.tooltip_text = "Note synced with remote"
			SyncState.LOCAL_CHANGES:
				note.sync_controller_button.tooltip_text = "Local changes"
				note.sync_controller_button.text = "●"
		
		note.sync_controller_button.visible = true
		if not note.sync_controller_button.pressed.is_connected(_on_sync_controller_button_pressed):
			note.sync_controller_button.pressed.connect(_on_sync_controller_button_pressed)


func _on_sync_controller_button_pressed():
	
	info("Sync button pressed")
	
	if state == SyncState.LOCAL_CHANGES:
		state = SyncState.SYNCING
		var success: = await adapter.save_note(note)
		
		state = SyncState.SYNCED if success else SyncState.LOCAL_CHANGES


func _on_note_remove_button_pressed():

	if state == SyncState.SYNCING: return

	match state:
		SyncState.LOCAL_ONLY:
			# Just delete locally, no remote action needed
			note.queue_free()
			sync_manager.cleanup_controller(note.uuid)
		
		SyncState.SYNCED, SyncState.LOCAL_CHANGES:
			# Delete from remote first, then local
			set_state(SyncState.SYNCING)
			var success = await adapter.delete_note(note)
			
			if success:
				note.queue_free()
				sync_manager.cleanup_controller(note.uuid)
			else:
				# Revert state on failure, keep note
				set_state(SyncState.LOCAL_CHANGES)


func _on_note_change():

	if _state_info == null:
		state = SyncState.LOCAL_CHANGES
		return
	
	if _state_info.is_out_of_sync(note):
		info("Note %s changed and is OUT of sync" % note)
		state = SyncState.LOCAL_CHANGES
	else:
		info("Note %s changed but is in sync" % note)
		state = SyncState.SYNCED

	
