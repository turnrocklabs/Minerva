class_name ToastNotification
extends Control

static var _scnene: = preload("res://Scenes/toast/ToastNotification.tscn")

@onready var _content_label: Label = %ContentLabel
@onready var _panel_container: PanelContainer = %PanelContainer
@onready var _fade_in_control: TextureRect = %FadeTextureRect


enum Type {
	INFO,
	WARNING,
	ERROR,
}

var content: String
var type: Type

static var _theme_variations: Dictionary[Type, StringName] = {
	Type.INFO: &"ToastInfo",
	Type.WARNING: &"ToastWarning",
	Type.ERROR: &"ToastError",
}

static func create(type_: Type, text: String) -> ToastNotification:
	
	var toast_obj: ToastNotification = _scnene.instantiate()

	toast_obj.type = type_
	toast_obj.content = text

	return toast_obj


func _ready() -> void:

	var parent: = get_parent()

	var count: = 1

	for child in parent.get_children():
		if child is ToastNotification and not child.is_queued_for_deletion():
			count += 1

	var screen_size: = get_viewport_rect().size

	position = Vector2(
		screen_size.x - _panel_container.size.x - 15,
		screen_size.y - (_panel_container.size.y+5)*count - 50
	)

	_content_label.text = content
	_panel_container.theme_type_variation = _theme_variations[type]

	_fade_in_control.custom_minimum_size.x = 0
	
	var tween: = create_tween()
	tween.set_parallel(true)

	tween.tween_property(_fade_in_control, "size:x", 0, 3)
	tween.tween_property(_fade_in_control, "position:x", 400, 3)

	tween.set_parallel(false)

	tween.tween_property(self, "position:x", screen_size.x, 0.5).set_trans(Tween.TransitionType.TRANS_BACK)
	
	await tween.finished

	queue_free()
