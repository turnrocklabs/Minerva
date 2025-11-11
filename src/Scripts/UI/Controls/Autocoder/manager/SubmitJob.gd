class_name AutocoderSubmitJobManager
extends VBoxContainer

@onready var _artifact_browser_popup: PersistentWindow = %ArtifactBrowserPopup
@onready var _artifact_browser: ArtifactBrowser = %ArtifactBrowser

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

	if not SingletonObject.autocoder_manager.artifact_registry_adapter:
		SingletonObject.ErrorDisplay("Can't fetch", "Please connect to core first!")
		return
	
	var artifacts: = await SingletonObject.autocoder_manager.artifact_registry_adapter.search()
	_artifact_browser.set_artifacts(artifacts)
	
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

	editor.package_editor.artifact_uploaded.connect(
		func(artifact: Artifact):
			selected_artifact = artifact
	)


func _on_continue_session_check_box_pressed() -> void:
	pass # Replace with function body.


func _on_continue_session_check_box_toggled(toggled_on: bool) -> void:
	_session_option_button.disabled = not toggled_on


func _on_submit_job_button_pressed() -> void:
	if not SingletonObject.autocoder_manager.autocoder_adapter:
		SingletonObject.ErrorDisplay("Can't start", "Please connect to core first!")
		return
	
	var output: = await SingletonObject.autocoder_manager.autocoder_adapter.generate(
		"Generate a python hello world program",
		"", # no session
		selected_artifact.artifact_uri if selected_artifact else ""
	)

	SingletonObject.ErrorDisplay(output.status, output.message)

	SingletonObject.autocoder_manager.monitor_session(output.user_id, output.session_id)

	var success: = await Core.subscribe("autocoder-orchestrator/iteration/%s/%s" % [output.user_id, output.session_id])

	if not success:
		SingletonObject.ErrorDisplay("Can't subscribe", "Can't subscribe to session notifications")

	# _autocoder_notification_awaiter = Core.await_message()

	# _autocoder_notification_awaiter.with_cmd("publication").receive_all().connect(func(msg: Dictionary): prints("NOTIFICATION RECEIVED:", msg))


	prints("output is:", output.session_id)
