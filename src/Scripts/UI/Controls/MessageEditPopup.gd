class_name MessageEditPopup
extends PopupPanel

var message: MessageMarkdown


func _on_about_to_popup():
	%MessageTextEdit.text = message.content


func _on_save_button_pressed():
	message.content = %MessageTextEdit.text
	hide()
