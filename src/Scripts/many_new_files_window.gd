extends PersistentWindow

@onready var new_files_line_edit: LineEdit = %NewFilesLineEdit
@onready var error_label: Label = %ErrorLabel

func _on_button_pressed() -> void:
	handle_new_files_action(new_files_line_edit.text)


func _on_new_files_line_edit_text_submitted(new_text: String) -> void:
	handle_new_files_action(new_text)


func handle_new_files_action(new_text: String) -> void:
	if new_text.is_valid_int():
		create_new_files(new_text.to_int())
		error_label.hide()
		new_files_line_edit.text = ""
		self.hide()
	else:
		error_label.show()


func create_new_files(quantity: int) -> void:
	for i in range(quantity):
		SingletonObject.editor_container.editor_pane.add(Editor.Type.TEXT)


func _on_about_to_popup() -> void:
	new_files_line_edit.grab_focus()
