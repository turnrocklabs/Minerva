extends Window


func _ready():
	var file = FileAccess.open("res://license_agreement.md", FileAccess.READ)
	%LicenseScriptRichTextLabel.text = file.get_as_text()


func _on_close_requested() -> void:
	hide()
	call_deferred("queue_free")


func _on_button_pressed() -> void:
	_on_close_requested()
