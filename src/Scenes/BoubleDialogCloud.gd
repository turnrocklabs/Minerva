extends Sprite2D

func _ready():
	if SingletonObject.CloudType == "Bubble":
		$".".texture = preload("res://assets/icons/BoubleDialogCloud.png")
		$".".scale = Vector2(2,2)
	else:
		$".".texture = preload("res://assets/icons/StraightDialogCloud.png")

func _on_add_pressed():
	$Add.queue_free()
	$Cancel.queue_free()
	$TextEdit.visible = false
	$RichTextLabel.visible = true
	$RichTextLabel.text = $TextEdit.text
	$Flip.queue_free()

func _on_cancel_pressed():
	self.queue_free()

func _on_flip_pressed():
	$".".scale *= Vector2(-1,1)
	$TextEdit.size *= Vector2(-1,1)
	$Add.size *= Vector2(-1,1)
	$RichTextLabel.size *= Vector2(-1,1)
	$Cancel.size *= Vector2(-1,1)
	$Flip.size *= Vector2(-1,1)
