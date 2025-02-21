extends ColorRect


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass


func _on_apply_changes_pressed() -> void:
	#do some stuff to apply chanes for message
	
	visible = false


func _on_cancle_changes_pressed() -> void:
	visible = false
