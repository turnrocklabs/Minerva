extends PersistentWindow

var tab_reference = null
#var tab_title: String = ""

func _ready() -> void:
	SingletonObject.associated_notes_tab.connect(_on_assosiated_notes_tab)
	SingletonObject.pop_up_new_tab.connect(_pop_up_new_tab)


func _on_assosiated_notes_tab(tab_name: String, tab: Control)-> void:
	#print(tab_name)
	#print(tab.get_class())
	set_values(tab_name, tab)

func _pop_up_new_tab():
	set_values("", null)


func set_values(tab_name: String, tab: Control = null) -> void:
	tab_reference = tab
	%txtNewTabName.text = tab_name
	call_deferred("show")
	%txtNewTabName.call_deferred("grab_focus")


func _on_btn_voice_for_note_tab_pressed():
	SingletonObject.AtT.FieldForFilling = %txtNewTabName
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnVoiceForNoteTab
	#%btnVoiceForNoteTab.icon = icActive
	%btnVoiceForNoteTab.modulate = Color.LIME_GREEN


func _on_btn_create_thread_pressed() -> void:
	SingletonObject.create_notes_tab.emit(%txtNewTabName.text, tab_reference)
	call_deferred("hide")


func _on_about_to_popup() -> void:
	%txtNewTabName.call_deferred("grab_focus")


func _on_close_requested() -> void:
	call_deferred("hide")


func _on_txt_new_tab_name_text_submitted(new_text: String) -> void:
	SingletonObject.create_notes_tab.emit(new_text, tab_reference)
	call_deferred("hide")


func _on_window_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_on_close_requested()