class_name ArtifactBrowser
extends MarginContainer

## Shows the select and cancel button
@export var select: bool = true


signal artifact_selected(artifact: Artifact)
signal selection_canceled()


@onready var _artifact_tree: Tree = %ArtifactsTree
@onready var _search_line_edit: LineEdit = %SearchLineEdit
@onready var _framework_option_button: OptionButton = %FrameworkOptionButton
@onready var _language_option_button: OptionButton = %LanguageOptionButton
@onready var _visibility_option_button: OptionButton = %VisibilityOptionButton


@onready var _select_button: Button = %SelectButton
@onready var _cancel_button: Button = %CancelButton
@onready var _copy_uri_button: Button = %CopyURIButton
@onready var _delete_button: Button = %DeleteButton
@onready var _edit_metadata_button: Button = %EditMetadataButton
@onready var _download_button: Button = %DownloadButton


# Detail labels
@onready var _title_label: Label = %TitleLabel
@onready var _framework_label: Label = %FrameworkValueLabel
@onready var _language_label: Label = %LanguageValueLabel
@onready var _size_label: Label = %SizeValueLabel
@onready var _uploaded_label: Label = %UploadedValueLabel
@onready var _owner_label: Label = %OwnerValueLabel
@onready var _visibility_label: Label = %VisibilityValueLabel
@onready var _tags_label: Label = %TagsValueLabel
@onready var _description_label: Label = %DescriptionValueLabel
@onready var _uri_label: Label = %URIValueLabel

enum Field {
	URI,
	FILENAME,
	DESCRIPTION,
	FRAMEWORK,
	LANGUAGE,
	TAGS,
	VISIBILITY,
	SIZE,
	UPLOADED_AT,
	OWNER_ID,
}

## Defines the order in which the artifact metadata is displayed
static var HEADER: Array[Field] = [
	Field.FILENAME,
	Field.DESCRIPTION,
	Field.FRAMEWORK,
	Field.LANGUAGE,
	Field.TAGS,
	Field.VISIBILITY,
	Field.SIZE,
	Field.UPLOADED_AT,
	Field.OWNER_ID,
	Field.URI,
]

static var COLUMN_NAMES: Dictionary = {
	Field.FILENAME: "File Name",
	Field.DESCRIPTION: "Description",
	Field.FRAMEWORK: "Framework",
	Field.LANGUAGE: "Language",
	Field.TAGS: "Tags",
	Field.VISIBILITY: "Visibility",
	Field.SIZE: "File Size",
	Field.UPLOADED_AT: "Upload Date",
	Field.OWNER_ID: "Uploaded By",
	Field.URI: "URI",
}

var artifacts: Array[Artifact] = []
var selected_artifact: Artifact = null:
	set(value):
		selected_artifact = value

		_copy_uri_button.disabled = not selected_artifact
		_select_button.disabled = not selected_artifact
		_edit_metadata_button.disabled = not selected_artifact
		_delete_button.disabled = not selected_artifact
		_download_button.disabled = not selected_artifact


func _ready() -> void:

	_select_button.visible = select
	_cancel_button.visible = select

	_setup_tree()
	_load_fake_artifacts()


func _load_fake_artifacts() -> void:

	artifacts.clear()
	for data in fake_data:
		artifacts.append(Artifact.new(data))
	
	_update_filter_buttons()
	_populate_tree()


func set_artifacts(artifacts_: Array[Artifact]) -> void:
	artifacts = artifacts_
	
	_update_filter_buttons()
	_populate_tree()


func refresh():
	if not SingletonObject.autocoder_manager.artifact_registry_adapter:
		SingletonObject.ErrorDisplay("Can't fetch", "Please connect to core first!")
		return

	# Use current filter settings for server-side search
	var search_query := _search_line_edit.text if _search_line_edit.text != "" else ""
	var selected_framework := ""
	var selected_visibility := "public"  # Default to public

	if _framework_option_button.selected > 0:
		selected_framework = _framework_option_button.get_item_text(_framework_option_button.selected)

	if _visibility_option_button.selected > 0:
		selected_visibility = _visibility_option_button.get_item_text(_visibility_option_button.selected).to_lower()

	SingletonObject.create_toast_notification("Fetching artifacts...", ToastNotification.Type.INFO)

	var fetched_artifacts: Array[Artifact] = []

	# Use list-mine for private artifacts, search for public/all
	if selected_visibility == "private":
		fetched_artifacts = await SingletonObject.autocoder_manager.artifact_registry_adapter.list_mine()

		# Apply client-side filtering for query and framework on private artifacts
		if search_query != "" or selected_framework != "":
			var filtered: Array[Artifact] = []
			for artifact in fetched_artifacts:
				var matches := true

				if search_query != "":
					var search_lower := search_query.to_lower()
					matches = (
						artifact.filename.to_lower().contains(search_lower) or
						artifact.description.to_lower().contains(search_lower) or
						artifact.get_tags_string().to_lower().contains(search_lower)
					)

				if matches and selected_framework != "":
					matches = artifact.framework == selected_framework

				if matches:
					filtered.append(artifact)

			fetched_artifacts = filtered
	else:
		fetched_artifacts = await SingletonObject.autocoder_manager.artifact_registry_adapter.search(
			search_query,
			selected_framework,
			selected_visibility
		)

	set_artifacts(fetched_artifacts)

	if fetched_artifacts.is_empty():
		SingletonObject.create_toast_notification("No artifacts found", ToastNotification.Type.INFO)
	else:
		SingletonObject.create_toast_notification(
			"Found %d artifact%s" % [fetched_artifacts.size(), "s" if fetched_artifacts.size() != 1 else ""],
			ToastNotification.Type.SUCCESS
		)


## Select an artifact by URI after refresh
func select_artifact_by_uri(artifact_uri: String) -> bool:
	# Find the artifact in the tree
	var root := _artifact_tree.get_root()
	if not root:
		return false

	var item := root.get_first_child()

	while item:
		var artifact: Artifact = item.get_metadata(0)
		if artifact and artifact.artifact_uri == artifact_uri:
			# Found it! Select and scroll to it
			_artifact_tree.set_selected(item, 0)
			_artifact_tree.scroll_to_item(item)
			selected_artifact = artifact
			_update_details_panel(artifact)
			return true

		item = item.get_next()

	return false


## Refresh and select a specific artifact by URI
func refresh_and_select(artifact_uri: String) -> void:
	await refresh()

	# Try to select the artifact
	if not select_artifact_by_uri(artifact_uri):
		SingletonObject.create_toast_notification(
			"Artifact loaded but not visible in current filters",
			ToastNotification.Type.WARNING
		)


func _setup_tree() -> void:
	_artifact_tree.column_titles_visible = true
	_artifact_tree.columns = HEADER.size()
	
	# Make columns resizable
	for i in HEADER.size():
		_artifact_tree.set_column_expand(i, true)
		_artifact_tree.set_column_expand_ratio(i, 1)
	
	# Give description and filename more space
	_artifact_tree.set_column_expand_ratio(0, 2)  # Filename
	_artifact_tree.set_column_expand_ratio(1, 3)  # Description
	
	_artifact_tree.clear()
	
	# Create header
	var header := _artifact_tree.create_item(null)
	for i in HEADER.size():
		var column: Field = HEADER[i]
		var column_name: String = COLUMN_NAMES.get(column, "")
		header.set_text(i, column_name)


func _update_filter_buttons() -> void:
	var frameworks = artifacts.map(func(a: Artifact): return a.framework)
	var languages = artifacts.map(func(a: Artifact): return a.language)
	var visibilities = artifacts.map(func(a: Artifact): return a.visibility)
	
	_update_filter_button(_framework_option_button, frameworks)
	_update_filter_button(_language_option_button, languages)
	_update_filter_button(_visibility_option_button, visibilities)


func _update_filter_button(option_button: OptionButton, items: Array) -> void:
	var selected_text: String = ""

	if option_button.selected != -1:
		selected_text = option_button.get_item_text(option_button.selected)

	option_button.clear()
	option_button.add_item("All")

	# Get unique items only
	var unique_items: Array[String] = []
	for item in items:
		var item_str = str(item)
		if item_str not in unique_items and not item_str.is_empty():
			unique_items.append(item_str)
	
	# Sort alphabetically
	unique_items.sort()
	
	# Add to option button
	for item_name in unique_items:
		option_button.add_item(item_name)

	# Restore previous selection if it exists
	if selected_text.is_empty():
		option_button.select(0)
	else:
		for i in option_button.item_count:
			if option_button.get_item_text(i) == selected_text:
				option_button.select(i)
				return
		# If previous selection not found, default to "All"
		option_button.select(0)

	


func _populate_tree() -> void:
	_artifact_tree.clear()
	
	# Recreate header
	var header := _artifact_tree.create_item(null)
	for i in HEADER.size():
		var column: Field = HEADER[i]
		var column_name: String = COLUMN_NAMES.get(column, "")
		header.set_text(i, column_name)
	
	# Add artifacts
	for artifact in artifacts:
		var item := _artifact_tree.create_item(null)
		
		for i in HEADER.size():
			var column: Field = HEADER[i]
			var column_text: String = _get_field_value(artifact, column)
			item.set_text(i, column_text)
		
		# Store artifact reference in metadata
		item.set_metadata(0, artifact)


func _get_field_value(artifact: Artifact, field: Field) -> String:
	match field:
		Field.FILENAME:
			return artifact.filename
		Field.DESCRIPTION:
			return artifact.description
		Field.FRAMEWORK:
			return artifact.framework
		Field.LANGUAGE:
			return artifact.language
		Field.TAGS:
			return artifact.get_tags_string()
		Field.VISIBILITY:
			return artifact.visibility
		Field.SIZE:
			return artifact.get_size_formatted()
		Field.UPLOADED_AT:
			return artifact.get_date_formatted()
		Field.OWNER_ID:
			return artifact.owner_id
		Field.URI:
			return artifact.artifact_uri
		_:
			return ""


func _on_artifact_selected() -> void:
	var selected_item := _artifact_tree.get_selected()
	if not selected_item:
		return
	
	selected_artifact = selected_item.get_metadata(0) as Artifact
	if selected_artifact:
		_update_details_panel(selected_artifact)


func _update_details_panel(artifact: Artifact) -> void:
	_title_label.text = artifact.filename
	_framework_label.text = artifact.framework
	_language_label.text = artifact.language
	_size_label.text = artifact.get_size_formatted()
	_uploaded_label.text = artifact.get_date_formatted()
	_owner_label.text = artifact.owner_id
	_visibility_label.text = artifact.visibility
	_tags_label.text = artifact.get_tags_string()
	_description_label.text = artifact.description
	_uri_label.text = artifact.artifact_uri


func _on_search_button_pressed() -> void:
	# Use server-side search instead of client-side filtering
	await refresh()

func _on_search_line_edit_text_changed(_new_text: String) -> void:
	# Client-side filtering for immediate feedback
	_apply_filters()

func _on_refresh_button_pressed() -> void:
	await refresh()


func _on_visibility_option_button_item_selected(_index: int) -> void:
	# Trigger server-side search when visibility changes
	await refresh()


func _on_language_option_button_item_selected(_index: int) -> void:
	# Language filtering is client-side only (not supported by server API)
	_apply_filters()


func _on_framework_option_button_item_selected(_index: int) -> void:
	# Trigger server-side search when framework changes
	await refresh()


func _apply_filters() -> void:
	var search_query := _search_line_edit.text.to_lower()
	var selected_framework := _framework_option_button.get_item_text(_framework_option_button.selected)
	var selected_language := _language_option_button.get_item_text(_language_option_button.selected)
	var selected_visibility := _visibility_option_button.get_item_text(_visibility_option_button.selected)
	
	var root := _artifact_tree.get_root()
	if not root:
		return
	
	# Start from first child (skip header)
	var item := root.get_first_child()
	
	while item:
		var artifact: Artifact = item.get_metadata(0)
		var should_show := true
		
		# Check search query (filename, description, tags)
		if not search_query.is_empty():
			var matches_search := (
				artifact.filename.to_lower().contains(search_query) or
				artifact.description.to_lower().contains(search_query) or
				artifact.get_tags_string().to_lower().contains(search_query)
			)
			if not matches_search:
				should_show = false
		
		# Check framework filter
		if should_show and selected_framework != "All" and artifact.framework != selected_framework:
			should_show = false
		
		# Check language filter
		if should_show and selected_language != "All" and artifact.language != selected_language:
			should_show = false
		
		# Check visibility filter
		if should_show and selected_visibility != "All" and artifact.visibility != selected_visibility:
			should_show = false
		
		# Show/hide item
		item.visible = should_show
		
		item = item.get_next()


func _on_download_button_pressed() -> void:
	if _artifact_tree.get_selected():	
		if not SingletonObject.autocoder_manager.artifact_registry_adapter:
			SingletonObject.ErrorDisplay("Can't download", "Please connect to core first!")
			return
	
		var artifact: Artifact = _artifact_tree.get_selected().get_metadata(0)

		SingletonObject.autocoder_manager.artifact_registry_adapter.download(artifact.artifact_uri)


func _on_copy_uri_button_pressed() -> void:
	if selected_artifact:
		DisplayServer.clipboard_set(selected_artifact.artifact_uri)
		SingletonObject.create_toast_notification("Artifact URI copied", ToastNotification.Type.INFO)


func _on_select_button_pressed() -> void:
	if _artifact_tree.get_selected():
		var artifact: Artifact = _artifact_tree.get_selected().get_metadata(0)

		if artifact:
			artifact_selected.emit(artifact)
		else:
			SingletonObject.ErrorDisplay("Can't get artifact", "Error while selecting Artifact from displayed tree")


func _on_edit_metadata_button_pressed() -> void:
	if not selected_artifact:
		return

	if not SingletonObject.autocoder_manager.artifact_registry_adapter:
		SingletonObject.ErrorDisplay("Can't edit metadata", "Please connect to core first!")
		return

	# Create a simple dialog for editing metadata
	var dialog := _create_metadata_dialog(selected_artifact)
	dialog.popup_centered()

	# Wait for confirmation
	var confirmed: bool = await dialog.confirmed

	if not confirmed:
		dialog.queue_free()
		return

	# Extract values from dialog
	var description_edit: LineEdit = dialog.get_node("%DescriptionEdit")
	var tags_edit: LineEdit = dialog.get_node("%TagsEdit")
	var framework_edit: LineEdit = dialog.get_node("%FrameworkEdit")
	var language_edit: LineEdit = dialog.get_node("%LanguageEdit")
	var visibility_option: OptionButton = dialog.get_node("%VisibilityOption")

	var new_description := description_edit.text
	var new_tags_text := tags_edit.text
	var new_framework := framework_edit.text
	var new_language := language_edit.text
	var new_visibility := "public" if visibility_option.selected == 0 else "private"

	# Parse tags (comma-separated)
	var new_tags: Array = []
	if not new_tags_text.is_empty():
		for tag in new_tags_text.split(","):
			var trimmed := tag.strip_edges()
			if not trimmed.is_empty():
				new_tags.append(trimmed)

	dialog.queue_free()

	# Send update request
	var success := await SingletonObject.autocoder_manager.artifact_registry_adapter.add_metadata(
		selected_artifact.artifact_uri,
		selected_artifact.filename,
		new_description,
		new_tags,
		new_framework,
		new_language,
		new_visibility
	)

	if success:
		SingletonObject.create_toast_notification(
			"Metadata updated successfully",
			ToastNotification.Type.SUCCESS
		)
		await refresh()
	else:
		SingletonObject.ErrorDisplay("Update Failed", "Failed to update artifact metadata")


func _create_metadata_dialog(artifact: Artifact) -> AcceptDialog:
	var dialog := AcceptDialog.new()
	dialog.title = "Edit Artifact Metadata"
	dialog.dialog_text = ""
	dialog.min_size = Vector2i(500, 400)

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	dialog.add_child(vbox)

	# Filename (read-only)
	var filename_label := Label.new()
	filename_label.text = "Filename: %s" % artifact.filename
	vbox.add_child(filename_label)

	vbox.add_child(HSeparator.new())

	# Description
	var desc_label := Label.new()
	desc_label.text = "Description:"
	vbox.add_child(desc_label)

	var description_edit := LineEdit.new()
	description_edit.unique_name_in_owner = true
	description_edit.name = "DescriptionEdit"
	description_edit.text = artifact.description
	description_edit.placeholder_text = "Brief description of the artifact"
	vbox.add_child(description_edit)

	# Tags
	var tags_label := Label.new()
	tags_label.text = "Tags (comma-separated):"
	vbox.add_child(tags_label)

	var tags_edit := LineEdit.new()
	tags_edit.unique_name_in_owner = true
	tags_edit.name = "TagsEdit"
	tags_edit.text = artifact.get_tags_string()
	tags_edit.placeholder_text = "template, starter, game"
	vbox.add_child(tags_edit)

	# Framework
	var framework_label := Label.new()
	framework_label.text = "Framework:"
	vbox.add_child(framework_label)

	var framework_edit := LineEdit.new()
	framework_edit.unique_name_in_owner = true
	framework_edit.name = "FrameworkEdit"
	framework_edit.text = artifact.framework
	framework_edit.placeholder_text = "godot, unity, react, etc."
	vbox.add_child(framework_edit)

	# Language
	var language_label := Label.new()
	language_label.text = "Language:"
	vbox.add_child(language_label)

	var language_edit := LineEdit.new()
	language_edit.unique_name_in_owner = true
	language_edit.name = "LanguageEdit"
	language_edit.text = artifact.language
	language_edit.placeholder_text = "gdscript, csharp, javascript, etc."
	vbox.add_child(language_edit)

	# Visibility
	var visibility_label := Label.new()
	visibility_label.text = "Visibility:"
	vbox.add_child(visibility_label)

	var visibility_option := OptionButton.new()
	visibility_option.unique_name_in_owner = true
	visibility_option.name = "VisibilityOption"
	visibility_option.add_item("Public")
	visibility_option.add_item("Private")
	visibility_option.selected = 0 if artifact.visibility == "public" else 1
	vbox.add_child(visibility_option)

	SingletonObject.add_child(dialog)

	return dialog

func _on_delete_button_pressed() -> void:
	if _artifact_tree.get_selected():
		
		if not SingletonObject.autocoder_manager.artifact_registry_adapter:
			SingletonObject.ErrorDisplay("Can't fetch", "Please connect to core first!")
			return
		
		var artifact: Artifact = _artifact_tree.get_selected().get_metadata(0)
		
		var success: = await SingletonObject.autocoder_manager.artifact_registry_adapter.delete(artifact.artifact_uri)

		if success:
			SingletonObject.create_toast_notification(
				"Artifact deleted successfully",
				ToastNotification.Type.SUCCESS
			)

	await refresh()


func _on_cancel_button_pressed() -> void:
	selection_canceled.emit()

var fake_data = [
  {
	"artifact_uri": "artifact://godot-space-shooter-template-v1",
	"filename": "godot_space_shooter_template.tar.gz",
	"description": "Complete Godot 4.4 space shooter template with player controls, enemy spawning, and basic shooting mechanics. Includes sprites and sound effects.",
	"framework": "godot",
	"language": "gdscript",
	"tags": ["template", "space-shooter", "game", "starter"],
	"visibility": "public",
	"size": 3457280,
	"uploaded_at": "2025-10-28T14:23:45Z",
	"owner_id": "user_alice_001"
  },
  {
	"artifact_uri": "artifact://godot-platformer-base-v2",
	"filename": "platformer_base.tar.gz",
	"description": "2D platformer template with character controller, jump mechanics, moving platforms, and collectibles system.",
	"framework": "godot",
	"language": "gdscript",
	"tags": ["template", "platformer", "2d", "character-controller"],
	"visibility": "public",
	"size": 2145728,
	"uploaded_at": "2025-10-30T09:15:22Z",
	"owner_id": "user_bob_002"
  },
  {
	"artifact_uri": "artifact://ui-theme-scifi-pack",
	"filename": "scifi_ui_theme.tar.gz",
	"description": "Sci-fi themed UI pack with buttons, panels, health bars, and HUD elements. Includes 50+ assets.",
	"framework": "godot",
	"language": "theme",
	"tags": ["ui", "theme", "scifi", "assets"],
	"visibility": "public",
	"size": 8912640,
	"uploaded_at": "2025-10-25T16:42:11Z",
	"owner_id": "user_charlie_003"
  },
  {
	"artifact_uri": "artifact://my-character-sprites-v1",
	"filename": "character_animations.tar.gz",
	"description": "Custom character sprite sheets for my RPG project. Walk, run, attack, idle animations.",
	"framework": "godot",
	"language": "assets",
	"tags": ["sprites", "character", "animation", "rpg"],
	"visibility": "private",
	"size": 5242880,
	"uploaded_at": "2025-10-31T11:05:33Z",
	"owner_id": "user_current"
  },
  {
	"artifact_uri": "artifact://inventory-system-godot",
	"filename": "inventory_system.tar.gz",
	"description": "Drag-and-drop inventory system with grid layout, item stacking, and equipment slots. Fully documented.",
	"framework": "godot",
	"language": "gdscript",
	"tags": ["system", "inventory", "ui", "rpg"],
	"visibility": "public",
	"size": 1572864,
	"uploaded_at": "2025-10-29T13:28:56Z",
	"owner_id": "user_diana_004"
  },
  {
	"artifact_uri": "artifact://particle-effects-pack-v3",
	"filename": "particle_effects.tar.gz",
	"description": "Collection of 30 particle effects: explosions, magic spells, smoke, fire, and more. GPU particles.",
	"framework": "godot",
	"language": "assets",
	"tags": ["particles", "effects", "vfx", "magic"],
	"visibility": "public",
	"size": 4194304,
	"uploaded_at": "2025-10-27T08:51:07Z",
	"owner_id": "user_eve_005"
  },
  {
	"artifact_uri": "artifact://godot-dialogue-system",
	"filename": "dialogue_system.tar.gz",
	"description": "Branching dialogue system with choice nodes, character portraits, and typewriter text effect.",
	"framework": "godot",
	"language": "gdscript",
	"tags": ["dialogue", "narrative", "system", "rpg"],
	"visibility": "public",
	"size": 983040,
	"uploaded_at": "2025-10-26T19:34:29Z",
	"owner_id": "user_frank_006"
  },
  {
	"artifact_uri": "artifact://top-down-shooter-base",
	"filename": "top_down_shooter.tar.gz",
	"description": "Top-down shooter template with twin-stick controls, weapon system, and enemy AI. Includes test levels.",
	"framework": "godot",
	"language": "gdscript",
	"tags": ["template", "shooter", "top-down", "twin-stick"],
	"visibility": "public",
	"size": 6291456,
	"uploaded_at": "2025-10-24T12:17:48Z",
	"owner_id": "user_grace_007"
  },
  {
	"artifact_uri": "artifact://my-test-project-wip",
	"filename": "test_project.tar.gz",
	"description": "Work in progress test project - do not use. Personal experiments with procedural generation.",
	"framework": "godot",
	"language": "gdscript",
	"tags": ["wip", "experimental", "procedural"],
	"visibility": "private",
	"size": 12582912,
	"uploaded_at": "2025-11-01T07:22:14Z",
	"owner_id": "user_current"
  },
  {
	"artifact_uri": "artifact://audio-sfx-8bit-retro",
	"filename": "8bit_sfx_pack.tar.gz",
	"description": "Retro 8-bit sound effects pack: jumps, coins, explosions, power-ups. 100+ sounds in .wav format.",
	"framework": "godot",
	"language": "assets",
	"tags": ["audio", "sfx", "8bit", "retro"],
	"visibility": "public",
	"size": 7340032,
	"uploaded_at": "2025-10-23T15:46:39Z",
	"owner_id": "user_henry_008"
  }
]
