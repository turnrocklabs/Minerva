extends PersistentWindow

var tab_reference = null

## Setting this property changes where the tab will be stored.[br]
## By default it's added to the `SingletonObject.notes_container`.
## After the tab has been added, the property reverts back to `null`.
var notes_container_override: NotesContainer


func _on_associated_notes_tab(tab_name: String, tab: Control)-> void:
	#print(tab_name)
	#print(tab.get_class())
	set_values(tab_name, tab)

func _pop_up_new_tab():
	set_values("", null)


func set_values(tab_name: String, tab: Control = null) -> void:
	tab_reference = tab
	%txtNewTabName.text = tab_name
	
	show.call_deferred()
	%txtNewTabName.call_deferred("grab_focus")


func _on_btn_voice_for_note_tab_pressed():
	SingletonObject.AtT.FieldForFilling = %txtNewTabName
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnVoiceForNoteTab
	#%btnVoiceForNoteTab.icon = icActive
	%btnVoiceForNoteTab.modulate = Color.LIME_GREEN

func _on_btn_create_thread_pressed() -> void:

	# TODO: if tab_reference, update tab

	var notes_container: NotesContainer = SingletonObject.notes_container if notes_container_override == null else notes_container_override

	notes_container.create_tab(%txtNewTabName.text)

	hide.call_deferred()

	notes_container_override = null


func _on_about_to_popup() -> void:
	%txtNewTabName.call_deferred("grab_focus")


func _on_close_requested() -> void:
	%txtNewTabName.text = ""
	call_deferred("hide")


func _on_txt_new_tab_name_text_submitted(_new_text: String) -> void:
	_on_btn_create_thread_pressed()
	call_deferred("hide")


func _on_window_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_on_close_requested()


func _on_btn_new_tab_pressed(drawer: = false) -> void:
	set_values("", null)
