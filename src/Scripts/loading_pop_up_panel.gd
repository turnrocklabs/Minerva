extends Control

func _ready() -> void:
	SingletonObject.Loading.connect(show_loading)


func show_loading(is_loading: bool = true, label_text: String = ""):
	print("entered show loading")
	if label_text != "":
		%MessageRichTextLabel.text = label_text.capitalize()
	else:
		%MessageRichTextLabel.text = "Loading Project..."
	if is_loading:
		visible = true
	else:
		visible = false


func _on_visibility_changed() -> void:
	if visible:
		%AnimationPlayer.play("new_animation")
	else:
		%AnimationPlayer.stop()
