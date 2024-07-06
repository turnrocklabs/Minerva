extends PersistentWindow


func _on_close_requested() -> void:
	hide()


func _on_cancel_button_pressed() -> void:
	%SystemPromptTextEdit.text = ""
	hide()
