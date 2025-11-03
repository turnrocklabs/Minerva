@tool
extends Control

@export var anim_duration: float = 1.5
@onready var loading_ring: TextureProgressBar = %LoadingRing

var tween: Tween
func _ready() -> void:
	tween = create_tween().set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_LINEAR)
	tween.set_loops(1000)
	
	tween.tween_property(loading_ring, "value", 100, anim_duration)
	tween.parallel().tween_property(loading_ring, "radial_initial_angle", 360.0, anim_duration)
	
	tween.tween_property(loading_ring, "value", 0, anim_duration)
	tween.parallel().tween_property(loading_ring, "radial_initial_angle", 0.0, anim_duration)
