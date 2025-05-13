extends IconsButton

@export var timer_duration: = 3.0
@export var animation_duration: = 0.3
@onready var send_message_button: OptionButton = %SendMessageButton
# default pos = 14, 3
# default size = 22, 30
var tween: Tween
var timer: Timer

func _ready() -> void:
	timer = Timer.new()
	timer.wait_time = timer_duration
	timer.timeout.connect(hide_overhang_button)
	add_child(timer)
	timer.one_shot = false
	timer.stop()


func _on_mouse_entered() -> void:
	if tween  and tween.is_running():
		return
	if send_message_button.visible:
		return
	send_message_button.disabled = false
	send_message_button.visible = true
	timer.stop()
	tween = create_tween()
	tween.tween_property(send_message_button, "position:x", 33, animation_duration)


func _on_mouse_exited() -> void:
	if !send_message_button.visible and !send_message_button.has_focus():
		return
	timer.start()


func hide_overhang_button() -> void:
	if tween  and tween.is_running():
		return
	tween = create_tween()
	tween.tween_property(send_message_button, "position:x", 14, animation_duration)
	await  tween.finished
	send_message_button.visible = false
	timer.start()


func _on_send_message_button_mouse_entered() -> void:
	timer.stop()


func _on_send_message_button_mouse_exited() -> void:
	timer.start()
