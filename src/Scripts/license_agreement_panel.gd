extends PersistentWindow
class_name LicensePopup

func _ready():
	var file = FileAccess.open("res://LICENSE.md", FileAccess.READ)
	%LicenseScriptMarkdownLabel._set_markdown_text(file.get_as_text())
	%LicenseScriptMarkdownLabel.call_deferred("scroll_to_line", 0)


func _on_close_requested() -> void:
	call_deferred("hide")
	call_deferred("queue_free")


func _on_button_pressed() -> void:
	_on_close_requested()