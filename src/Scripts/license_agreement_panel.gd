extends Window


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass


func _on_close_requested() -> void:
	hide()
	#await get_tree().create_timer(0.2).timeout
	call_deferred("queue_free")


func _on_button_pressed() -> void:
	_on_close_requested()
