extends Window


var license_agreement_script: String

func _ready():
	var file = FileAccess.open("res://license_agreement.md", FileAccess.READ)
	license_agreement_script = file.get_as_text()
	%LicenseScriptRichTextLabel.text = license_agreement_script


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass


func _on_close_requested() -> void:
	hide()
	#await get_tree().create_timer(0.2).timeout
	call_deferred("queue_free")


func _on_button_pressed() -> void:
	_on_close_requested()
