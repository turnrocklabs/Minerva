extends Panel

signal passAdasdsa(tabName)


func _on_btn_create_thread_pressed() -> void:
	emit_signal("passAdasdsa",%txtNewShelfName.text)
	%txtNewShelfName.clear()
	$"..".hide()
