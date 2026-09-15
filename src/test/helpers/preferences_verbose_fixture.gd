extends "res://Scripts/UI/Views/PreferencesPopup.gd"

var confirmation_result := false
var confirmed_save_called := false


func _confirm_voice_deactivation() -> bool:
	return confirmation_result


func _save_confirmed_preferences() -> void:
	confirmed_save_called = true
