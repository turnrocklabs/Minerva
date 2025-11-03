class_name AutocoderSubmitJobManager
extends VBoxContainer

@onready var _artifact_browser_popup: PersistentWindow = %ArtifactBrowserPopup
# @onready var _artifact_browser: ArtifactBrowser = %ArtifactBrowser

@onready var _input_resources_container: Container = %InputResourcesContainer

@onready var _selected_artifact_name_label: Label = %SelectedArtifactNameLabel
@onready var _selected_artifact_uri_label: Label = %SelectedArtifactURILabel

@onready var _session_option_button: OptionButton = %SessionOptionButton

var selected_artifact: Artifact = null:
	set(value):
		selected_artifact = value

		_input_resources_container.visible = selected_artifact != null

		if selected_artifact:
			_selected_artifact_name_label.text = selected_artifact.filename
			_selected_artifact_uri_label.text = selected_artifact.artifact_uri


func _on_select_package_button_pressed() -> void:
	_artifact_browser_popup.size = DisplayServer.screen_get_size() * 0.9
	_artifact_browser_popup.popup_centered()



func _on_artifact_browser_selection_canceled() -> void:
	_artifact_browser_popup.hide()

func _on_artifact_browser_artifact_selected(artifact: Artifact) -> void:
	selected_artifact = artifact
	_artifact_browser_popup.hide()



func _on_clear_input_resources_button_pressed() -> void:
	selected_artifact = null

func _on_create_package_button_pressed() -> void:
	var editor: = SingletonObject.editor_pane.add(Editor.Type.PACKAGE)

	editor.package_editor.directory_selected.connect(
		func(dir: String):
			var temp_a: = Artifact.new({
				"filename": dir
			})

			selected_artifact = temp_a
	)


func _on_continue_session_check_box_pressed() -> void:
	pass # Replace with function body.


func _on_continue_session_check_box_toggled(toggled_on: bool) -> void:
	_session_option_button.disabled = not toggled_on


func _on_submit_job_button_pressed() -> void:
	pass # Replace with function body.
