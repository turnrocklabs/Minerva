class_name ServiceAccountPrompt
extends ConfirmationDialog

## Refuse an explicit service action without presenting absent setup as an error.
static func require_account() -> bool:
	if Core.has_account_configuration():
		return true
	var parent: Node = SingletonObject.main_scene
	if parent == null:
		return false
	var prompt := parent.get_node_or_null("ServiceAccountPrompt") as ServiceAccountPrompt
	if prompt == null:
		prompt = (load("res://Scenes/windows/ServiceAccountPrompt.tscn") as PackedScene).instantiate() as ServiceAccountPrompt
		parent.add_child(prompt)
		prompt.content_scale_factor = parent.get_window().content_scale_factor
	prompt.popup_centered()
	return false

static func open_settings() -> void:
	var prefs: PreferencesPopup = SingletonObject.preferences_popup
	if prefs == null:
		return
	var tabs := prefs.get_node("MarginContainer/VBoxContainer/TabContainer") as TabContainer
	for index in range(tabs.get_tab_count()):
		if tabs.get_tab_title(index) == "Account":
			tabs.current_tab = index
			break
	if prefs.visible:
		prefs.grab_focus()
	else:
		prefs.popup_centered()

func _ready() -> void:
	confirmed.connect(func() -> void:
		hide()
		open_settings()
		queue_free())
	canceled.connect(queue_free)
	close_requested.connect(queue_free)
