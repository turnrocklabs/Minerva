class_name NoteSyncController
extends RefCounted


## Describes a state of the Note, usually after it is synced.[br]
## Used to check if local note that has been changed
## is out of sync wil the last recorded remote content.
class SyncStateInfo extends RefCounted:
	var sha256: String
	var title: String
	var enabled: bool
	var thread_id: String
	var thread_name: String

	func _init(note: Note, thread_id_: String, thread_name_: String) -> void:
		sha256 = note.sha256
		title = note.title
		enabled = note.enabled
		thread_id = thread_id_
		thread_name = thread_name_

		print("\n\n")
		prints("Create sync state with values:", title, enabled, sha256)
		print("\n\n")
	
	## Checks if the current note data is out of sync with this state object.
	func is_out_of_sync(target_note: Note, thread_id_: String, thread_name_: String) -> bool:
		print("is_out_of_sync")
		prints(thread_id_, ":", thread_id)
		prints(thread_name_, ":", thread_name)
		return (
			target_note.sha256 != sha256 or
			target_note.title != title or
			target_note.enabled != enabled or
			thread_id_ != thread_id or
			thread_name_ != thread_name
		)


enum SyncState {
	SYNCING,       # Syncing in progress
	SYNCED,        # Note matches remote version
	LOCAL_CHANGES, # Note modified locally, needs push to remote
	LOCAL_ONLY,    # New note, doesn't exist on remote yet
}

signal state_changed(state: SyncState)

static var _cloud_off_icon: = preload("res://assets/icons/cloud_off.svg")

var note: Note
var sync_manager: NoteSyncManager
var adapter: NoteServiceAdapter

var state: SyncState = SyncState.LOCAL_ONLY:
	set(value):
		state = value
		state_changed.emit(state)
		print("Emitted signal for %s" % note)
		_on_state_updated()


## Amount of seconds to wait before attempting another auto sync on note change, if one already failed
const FAILURE_COOLDOWN: = 10

var _sync_timer: SceneTreeTimer
## If last sync failed
var _sync_failed: = false
## Last sync timestamp
var _last_sync: float

var _state_info: SyncStateInfo


func _init(note_: Note, sync_manager_: NoteSyncManager) -> void:
	note = note_
	sync_manager = sync_manager_

	note.changed.connect(_on_note_change)
	note.tab_changed.connect(_on_note_tab_changed)

	# set initial state when the note is ready
	if not note.is_note_initialized():
		note.initialized.connect(
			func():
				_highjack_note_controls()
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

## Sets the new state for this controlles note.[br]
## if [param when_ready] is `true` the state will be set ONLY when the note is initialized.
## (is_note_initialized and initialized signals are used).
func set_state(new_state: SyncState, when_ready: = true) -> void:

	if not is_instance_valid(note):
		push_warning("Tried to update state for note that has been deleted")
		sync_manager.cleanup_controller(note.uuid)
		return

	if when_ready:
		if not note.is_note_initialized():
			note.initialized.connect(
				(func(): info("Marking %s with sync value %s" % [note, new_state]); state = new_state),
				ConnectFlags.CONNECT_ONE_SHOT
			)
			return

	info("Marking already ready %s with sync value %s" % [note, new_state])

	state = new_state


## Tries to upload this controlles note to remote.[br]
## If the note is not initialized yet, it waits for it to be.
## See [method Note.is_note_initialized].[br]
## In case of failure displays an error message if [param display_error] is `true`.
func sync_note(display_error: = true) -> bool:
	if not note.is_note_initialized():
		await note.initialized

	state = SyncState.SYNCING

	var success: = await adapter.save_notes([note])

	if success:
		state = SyncState.SYNCED
	else:
		state = SyncState.LOCAL_CHANGES
		if display_error:
			SingletonObject.ErrorDisplay("Can't upload", "Couldn't auto upload the %s" % note)

	return success

## [class NoteSyncController] automatically starts a sync timer 
## when a remote notes state changes to [enum SyncState.LOCAL_CHANGES].[br]
## The timer is reset if changes happen again, and times out only when there are
## no changes for a set period of time.[br]
## This methods returns whether or not this current controllers note has a timer running.
func is_queued_for_sync() -> bool:
	return is_instance_valid(_sync_timer) and _sync_timer.time_left > 0

func _on_state_updated() -> void:
	print("Updated %s state to %s" % [note, state])
	# if not ready the _init function sets up a signal to update the note button
	# so we don't connect multiple times if this function is run several times
	if not note.is_note_initialized():
		return
	
	if is_instance_valid(_sync_timer):
		_sync_timer.timeout.disconnect(_on_sync_timer_timeout)
		_sync_timer = null
	
	if state == SyncState.LOCAL_ONLY:
		
		# revert he remove button back
		note.remove_handle = Callable()
		note.remove_icon = null
		note._remove_button.tooltip_text = "Delete"

		# disable the button for half a second, so the user doesnt accidentally delete it locally also
		note._remove_button.disabled = true
		note.get_tree().create_timer(0.5).timeout.connect(
			func(): if is_instance_valid(note): note._remove_button.disabled = false
		)

		note.sync_controller_button.visible = false
		note.sync_controller_button.text = ""

		if note.sync_controller_button.pressed.is_connected(_on_sync_controller_button_pressed):
			note.sync_controller_button.pressed.disconnect(_on_sync_controller_button_pressed)
	else:

		note.remove_handle = _on_note_remove_button_pressed
		note.remove_icon = _cloud_off_icon
		note._remove_button.tooltip_text = "Make Local"

		match state:
			SyncState.SYNCING:
				note.sync_controller_button.text = "⟳"
				note.sync_controller_button.tooltip_text = "Syncing in progress..."

			SyncState.SYNCED:
				# record the current state info
				var tab_idx: = SingletonObject.notes_container.find_note(note)

				info("SAVING STATE INFO: %s" % tab_idx)
				info("SAVING STATE INFO: %s" % SingletonObject.notes_container.get_tab_name(tab_idx))
				_state_info = SyncStateInfo.new(
					note,
					SingletonObject.notes_container.get_tab_id(tab_idx),
					SingletonObject.notes_container.get_tab_name(tab_idx),
				)

				note.sync_controller_button.text = "☁"
				note.sync_controller_button.tooltip_text = "Note synced with remote"
			SyncState.LOCAL_CHANGES:

				# Start a timer that will update this note in 2 seconds of inactivity
				# if any changes occurs again, the timer will be reset
				
				# if last sync didn't failed or more than FAILURE_COOLDOWN
				if not _sync_failed or Time.get_unix_time_from_system() - _last_sync > FAILURE_COOLDOWN:
					_sync_timer = note.get_tree().create_timer(2)
					_sync_timer.timeout.connect(_on_sync_timer_timeout)

				note.sync_controller_button.tooltip_text = "Local changes"
				note.sync_controller_button.text = "●"
		
		note.sync_controller_button.visible = true
		if not note.sync_controller_button.pressed.is_connected(_on_sync_controller_button_pressed):
			note.sync_controller_button.pressed.connect(_on_sync_controller_button_pressed)


func _on_sync_timer_timeout() -> void:
	_sync_failed = not await sync_note(false)
	
	_last_sync = Time.get_unix_time_from_system()

	if not _sync_failed:
		SingletonObject.create_toast_notification("Synced the %s" % note)
	else:
		SingletonObject.create_toast_notification("Couldn't sync the %s" % note, ToastNotification.Type.ERROR)


func _on_sync_controller_button_pressed():
	
	info("Sync button pressed for note: %s" % note)
	
	if state == SyncState.LOCAL_CHANGES:
		state = SyncState.SYNCING
		var success: = await adapter.save_notes([note])
		
		state = SyncState.SYNCED if success else SyncState.LOCAL_CHANGES


func _on_note_remove_button_pressed() -> bool:

	if state == SyncState.SYNCING: return false

	match state:
		SyncState.LOCAL_ONLY:
			# Just delete locally, no remote action needed
			note.queue_free()
			sync_manager.cleanup_controller(note.uuid)
		
		SyncState.SYNCED, SyncState.LOCAL_CHANGES:
			# Delete from remote first
			set_state(SyncState.SYNCING)
			var success = await adapter.delete_notes([note])
			
			if success:
				set_state(SyncState.LOCAL_ONLY)

				# DON'T delete the controller. it should just be left in the LOCAL_CHANGES mode
				# sync_manager.cleanup_controller(note.uuid)

				SingletonObject.create_toast_notification("Successfully deleted the remote %s" % note, ToastNotification.Type.INFO)
				return true
			else:
				# Revert state on failure, keep note
				set_state(SyncState.LOCAL_CHANGES)
				SingletonObject.create_toast_notification("Couldn't delete the remote %s" % note, ToastNotification.Type.ERROR)
				return false
	
	return false


func _on_note_change() -> void:

	if _state_info == null:
		# if this was a local only note, just leave it as that
		if state == SyncState.LOCAL_ONLY: return

		state = SyncState.LOCAL_CHANGES
		return
	
	var tab_idx: = SingletonObject.notes_container.find_note(note)
	
	if _state_info.is_out_of_sync(
		note,
		SingletonObject.notes_container.get_tab_id(tab_idx),
		SingletonObject.notes_container.get_tab_name(tab_idx),
	):
		info("Note %s changed and is OUT of sync" % note)
		state = SyncState.LOCAL_CHANGES
	else:
		info("Note %s changed but is in sync" % note)
		state = SyncState.SYNCED


func _on_note_tab_changed(tab_idx: int) -> void:
	if _state_info == null:
		# if this was a local only note, just leave it as that
		if state == SyncState.LOCAL_ONLY: return

		state = SyncState.LOCAL_CHANGES
		return
	
	info("Note %s moved to tab %s" % [note, tab_idx])

	if _state_info.is_out_of_sync(
		note,
		SingletonObject.notes_container.get_tab_id(tab_idx),
		SingletonObject.notes_container.get_tab_name(tab_idx),
	):
		info("Note %s changed and is OUT of sync" % note)
		state = SyncState.LOCAL_CHANGES
	else:
		info("Note %s changed but is in sync" % note)
		state = SyncState.SYNCED
	
