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
	_apply_filters()

func _on_search_line_edit_text_changed(_new_text: String) -> void:
	_apply_filters()

func _on_refresh_button_pressed() -> void:
	# TODO: In real implementation, fetch from artifact service
	# For now, just refresh the fake data
	_load_fake_artifacts()
	_update_filter_buttons()


func _on_visibility_option_button_item_selected(_index: int) -> void:
	_apply_filters()


func _on_language_option_button_item_selected(_index: int) -> void:
	_apply_filters()


func _on_framework_option_button_item_selected(_index: int) -> void:
	_apply_filters()


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
	pass

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
	pass

func _on_delete_button_pressed() -> void:
	pass

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
