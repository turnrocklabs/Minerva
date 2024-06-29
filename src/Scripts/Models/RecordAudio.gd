extends Node

class_name RecordAudio


var effect
var recording

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	var idx = AudioServer.get_bus_index("Rec")
	effect = AudioServer.get_bus_effect(idx, 0)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
