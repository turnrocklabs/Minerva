class_name GraphicsEditorV2
extends PanelContainer

signal active_tool_changed(tool_: BaseTool)
@warning_ignore("unused_signal")
signal active_layer_changed(layer: LayerV2)
signal active_layer_is_mask_layer(is_mask_layer: bool)
signal active_layer_is_control_layer(is_control_layer: bool)

signal compose_progress_updated(progress: float)
signal compose_finished(image: Image)
signal delete_layer(layer: LayerV2)
signal selection_changed()

@export_category("Editor Canvas parameters")
@export_range(0.01, 0.9) var MIN_ZOOM: = 0.07
@export_range(1.1, 4.0) var MAX_ZOOM: = 2.5
@export var ZOOM_INCREMENT: = 1.05
@export var ZOOM_DECREMENT: = 0.95
@export_range(1.03, 2.0) var PAN_FACTOR: = 1.25

@onready var layers_container: LayersContainer = %LayersContainer
@onready var selection_overlay: Control = %SelectionOverlay  # SelectionOverlay type causes circular dependency
@onready var pose_editor_window: Window = %PoseEditorWindow
@onready var pose_editor_panel: Control = %PoseEditorPanel  # PoseEditorPanel type - avoid circular ref
@onready var layer_cards_container: Control = %LayerCardsContainer
@onready var tool_options_container: Control = %ToolOptionsContainer
@onready var layer_cards_popup_panel: Window = %LayerCardsPopupPanel
@onready var layer_cards_toggle_button: Button = %LayerCardsButton
@onready var layer_cards_panel_container: PanelContainer = %LayerCardsPanelContainer

@onready var message_window: PersistentWindow = %MessageWindow
@onready var message_title: Label = %MessageTitle
@onready var message_content: Label = %MessageContent

@onready var progress_window: PersistentWindow = %ProgressWindow
@onready var progress_window_bar: ProgressBar = %ProgressBar
@onready var progress_window_label: Label = %ProgressLabel
@onready var input_area_camera: Camera2D = %InputAreaCamera

@onready var _tools_option_button: OptionButton = %ToolsOptionButton

#region tool options containers
@onready var _brush_options_container: Control = %BrushOptions
@onready var _smudge_options_container: Control = %SmudgeOptions
@onready var _bucket_options_container: Control = %BucketOptions
@onready var _eraser_options_container: Control = %EraserOptions
@onready var _speech_bubble_options: Control = %SpeechBubbleOptions
@onready var _selection_options_container: Control = %SelectionOptions
@onready var _text_options_container: Control = %TextOptions
@onready var _rectangle_options_container: Control = %RectangleOptions
@onready var _ellipse_options_container: Control = %EllipseOptions
@onready var _diagram_shape_options_container: Control = %DiagramShapeOptions
@onready var _connector_options_container: Control = %ConnectorOptions
@onready var selection_indicator_button: MenuButton = %SelectionIndicatorButton
@onready var selection_mode_label: Label = %SelectionModeLabel

@onready var drawing_tool: DrawingTool = %DrawingTool
@onready var smudge_tool: SmudgeTool = %SmudgeTool
@onready var bucket_tool: BucketTool = %BucketTool
@onready var pan_tool: PanTool = %PanTool
@onready var eraser_tool: EraserTool = %EraserTool
@onready var transform_tool: TransformTool = %TransformTool
@onready var speech_bubble_tool: SpeechBubbleTool = %SpeechBubbleTool
@onready var render_view_tool: RenderViewTool = %RenderViewTool
@onready var eyedropper_tool: EyedropperTool = %EyedropperTool
@onready var magic_wand_tool: MagicWandTool = %MagicWandTool
@onready var rectangle_select_tool: RectangleSelectTool = %RectangleSelectTool
@onready var lasso_select_tool: LassoSelectTool = %LassoSelectTool
@onready var pose_editor_tool = %PoseEditorTool  # PoseEditorTool type - avoid circular ref
@onready var text_tool = %TextTool  # TextTool type - avoid circular ref
@onready var select_tool = %SelectTool  # SelectTool type - avoid circular ref
@onready var rectangle_tool = %RectangleTool  # RectangleTool type - avoid circular ref
@onready var ellipse_tool = %EllipseTool  # EllipseTool type - avoid circular ref
@onready var diagram_shape_tool = %DiagramShapeTool  # DiagramShapeTool type - avoid circular ref
@onready var connector_tool = %ConnectorTool  # ConnectorTool type - avoid circular ref


@onready var tool_options_mapping: = {
	drawing_tool: _brush_options_container,
	smudge_tool: _smudge_options_container,
	bucket_tool: _bucket_options_container,
	eraser_tool: _eraser_options_container,
	speech_bubble_tool: _speech_bubble_options,
	eyedropper_tool: _brush_options_container,
	magic_wand_tool: _selection_options_container,
	rectangle_select_tool: _selection_options_container,
	lasso_select_tool: _selection_options_container,
	text_tool: _text_options_container,
	rectangle_tool: _rectangle_options_container,
	ellipse_tool: _ellipse_options_container,
	diagram_shape_tool: _diagram_shape_options_container,
	connector_tool: _connector_options_container,
}

@onready var image_gen_window: Window = %ImageGenWindow
@onready var prompt_text_edit: TextEdit = %PromptTextEdit
@onready var send_prompt_button: Button = %SendPromptButton
@onready var negative_text_edit: TextEdit = %NegativeTextEdit
@onready var image_width_option_button: OptionButton = %ImageWidthOptionButton
@onready var advanced_settings_check_button: CheckButton = %AdvancedSettingsCheckButton
@onready var advanced_settings_container: VBoxContainer = %AdvancedSettingsContainer
@onready var prompt_button: Button = %PromptButton
@onready var steps_spin_box: SpinBox = %StepsSpinBox
@onready var cfg_spin_box: SpinBox = %CFGSpinBox
@onready var denoise_spin_box: SpinBox = %DenoiseSpinBox
@onready var denoise_container: HBoxContainer = %DenoiseContainer
@onready var seed_line_edit: LineEdit = %SeedLineEdit
@onready var workflow_option_button: OptionButton = %WorkflowOptionButton

@onready var mask_color_option_button: OptionButton = %MaskColorOptionButton
@onready var color_picker_button: ColorPickerButton = %ColorPickerButton
@onready var mask_layer_cards_container: VBoxContainer = %MaskLayerCardsContainer
@onready var control_layer_cards_container: VBoxContainer = %ControlLayerCardsContainer
@onready var image_gen_panel_container: PanelContainer = %ImageGenPanelContainer
@onready var tool_size_v_slider: VSlider = %ToolSizeVSlider
@onready var copy_layer_button: Button = %CopyLayerButton
@onready var merge_layers_button: Button = %MergeLayersButton
@onready var delete_layer_button: Button = %DeleteLayerButton
@onready var positive_prompt_mic_button: Button = %PositivePromptMicButton
@onready var negative_prompt_mic_button: Button = %NegativePromptMicButton
@onready var mask_container: HBoxContainer = %MaskContainer
@onready var top_of_layers_container: HBoxContainer = %TopOfLayersContainer
@onready var send_action_button: Button = %SendActionButton
@onready var edit_img_button: Button = %EditImgButton
@onready var send_mask_edit_button: Button = %SendMaskEditButton
@onready var ai_action_label: Label = %AIActionLabel
@onready var spritesheet_settings_container: VBoxContainer = %SpritesheetSettingsContainer
@onready var animation_option_button: OptionButton = %AnimationOptionButton
@onready var animation_frames_option_button: OptionButton = %AnimationFramesOptionButton

@onready var full_size_ai_container: MarginContainer = %FullSizeAIContainer
@onready var full_size_layers_container: MarginContainer = %FullSizeLayersContainer
@onready var dock_panel_container: MarginContainer = %DockPanelContainer
@onready var mini_map_control: Control = %MiniMapControl

@onready var dock_split_container: VSplitContainer = %DockSplitContainer
@onready var render_view_control: RenderViewRect = %RenderViewControl
@onready var connection_label: Label = %ConnectionLabel
@onready var drawing_area_sub_viewport: SubViewport = %DrawingAreaSubViewport

#endregion

const DEFAULT_IMAGE_GEN_RES: int = 1024 # The total number of pixels must be divisible by 64
const MAX_IMAGE_GEN_RES: int = 2048
const MIN_IMAGE_RES: int = 64

# Workflow selection for image generation
enum Workflow { Z_TURBO, QWEN }
const WORKFLOW_TOPICS: Dictionary = {
	Workflow.Z_TURBO: "media_gen/z_turbo_image_generate",
	Workflow.QWEN: "media_gen/image_generation"
}
const WORKFLOW_DEFAULT_STEPS: Dictionary = {
	Workflow.Z_TURBO: 9,
	Workflow.QWEN: 8
}
var current_workflow: Workflow = Workflow.Z_TURBO

#region AI Capabilities Registry (for MCP tools)

## Model metadata mapping - keyed by topic for lookup from Core discovery
## This provides fallback/default metadata when Core doesn't provide it
const MODEL_METADATA: Dictionary = {
	"media_gen/z_turbo_image_generate": {
		"id": "z_turbo",
		"name": "Z-Turbo",
		"default_steps": 9,
		"supports_edit": false,
		"supports_mask": false
	},
	"media_gen/image_generation": {
		"id": "qwen",
		"name": "Qwen",
		"default_steps": 8,
		"supports_edit": true,
		"supports_mask": true
	}
}

## Registered AI models for MCP tools
## Each: {id, name, topic, default_steps, supports_actions: ["create", "edit", "mask_edit"]}
var ai_models: Array[Dictionary] = []

## Available AI actions
const AI_ACTIONS: Array[Dictionary] = [
	{"id": "create", "name": "Create Image", "requires_layer": false, "requires_mask": false},
	{"id": "edit", "name": "Edit Image", "requires_layer": true, "requires_mask": false},
	{"id": "mask_edit", "name": "Mask Inpaint", "requires_layer": true, "requires_mask": true}
]

## Initialize AI models from local metadata (called on _ready)
func _init_ai_models() -> void:
	ai_models.clear()
	for topic in MODEL_METADATA:
		var meta: Dictionary = MODEL_METADATA[topic]
		var supports_actions: Array[String] = ["create"]
		if meta.get("supports_edit", false):
			supports_actions.append("edit")
		if meta.get("supports_mask", false):
			supports_actions.append("mask_edit")

		ai_models.append({
			"id": meta["id"],
			"name": meta["name"],
			"topic": topic,
			"default_steps": meta["default_steps"],
			"supports_actions": supports_actions
		})


## Get AI capabilities for MCP tools
func get_ai_capabilities() -> Dictionary:
	return {
		"success": true,
		"models": ai_models,
		"actions": AI_ACTIONS,
		"parameters": {
			"width": {"min": MIN_IMAGE_RES, "max": MAX_IMAGE_GEN_RES, "default": DEFAULT_IMAGE_GEN_RES, "step": 64},
			"height": {"min": MIN_IMAGE_RES, "max": MAX_IMAGE_GEN_RES, "default": DEFAULT_IMAGE_GEN_RES, "step": 64},
			"steps": {"min": 1, "max": 50},
			"cfg": {"min": 1.0, "max": 20.0, "default": 7.0},
			"denoise": {"min": 0.0, "max": 1.0, "default": 0.75}
		},
		"layers": _get_layers_info()
	}


## Get layer information for capabilities response
func _get_layers_info() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for layer in layers:
		var type_name: String
		match layer.type:
			LayerV2.Type.IMAGE:
				type_name = "image"
			LayerV2.Type.MASK:
				type_name = "mask"
			LayerV2.Type.CONTROL:
				type_name = "control"
			_:
				type_name = "unknown"
		result.append({
			"name": layer.name,  # Node.name property
			"type": type_name
		})
	return result


## Find a model by its ID
func _find_model_by_id(model_id: String) -> Dictionary:
	for model in ai_models:
		if model["id"] == model_id:
			return model
	return {}


## Find a layer by name
func _find_layer_by_name(layer_name: String) -> LayerV2:
	for layer in layers:
		if layer.name == layer_name:  # Node.name property
			return layer
	return null


## Execute an AI action (called by MCP tools)
func execute_ai_action(params: Dictionary) -> Dictionary:
	var model_id: String = params.get("model", "")
	var action_id: String = params.get("action", "")
	var prompt: String = params.get("prompt", "")

	# Validate prompt
	if prompt.is_empty():
		return {"error": "Prompt is required", "success": false}

	# Validate model exists
	var model: Dictionary = _find_model_by_id(model_id)
	if model.is_empty():
		return {"error": "Unknown model: %s" % model_id, "success": false}

	# Validate action supported by model
	if action_id not in model["supports_actions"]:
		return {"error": "Model '%s' doesn't support action '%s'" % [model_id, action_id], "success": false}

	# Build generation params
	var gen_params: Dictionary = {
		"positive_prompt": prompt,
		"negative_prompt": params.get("negative_prompt", ""),
		"width": params.get("width", DEFAULT_IMAGE_GEN_RES),
		"height": params.get("height", DEFAULT_IMAGE_GEN_RES),
		"steps": params.get("steps", model["default_steps"]),
		"cfg": params.get("cfg", 7.0),
		"denoise": params.get("denoise", 0.75),
		"topic": model["topic"]
	}

	# Route to appropriate handler based on action
	match action_id:
		"create":
			_current_image_gen_request_id = MediaGen.send_media_gen_request(gen_params)
			return {"success": true, "request_id": _current_image_gen_request_id, "message": "Image generation started"}

		"edit":
			var source_layer_name: String = params.get("source_layer", "")
			var source_layer: LayerV2 = _find_layer_by_name(source_layer_name)
			if not source_layer:
				return {"error": "Source layer not found: %s" % source_layer_name, "success": false}
			if source_layer.type != LayerV2.Type.IMAGE:
				return {"error": "Source layer must be an image layer", "success": false}

			# Get image buffer from layer
			var image_buffer: PackedByteArray = source_layer.image.save_png_to_buffer()
			_current_image_gen_request_id = MediaGen.send_media_edit_request(gen_params, image_buffer)
			return {"success": true, "request_id": _current_image_gen_request_id, "message": "Image edit started"}

		"mask_edit":
			var source_layer_name: String = params.get("source_layer", "")
			var mask_layer_name: String = params.get("mask_layer", "")

			var source_layer: LayerV2 = _find_layer_by_name(source_layer_name)
			if not source_layer:
				return {"error": "Source layer not found: %s" % source_layer_name, "success": false}
			if source_layer.type != LayerV2.Type.IMAGE:
				return {"error": "Source layer must be an image layer", "success": false}

			var mask_layer: LayerV2 = _find_layer_by_name(mask_layer_name)
			if not mask_layer:
				return {"error": "Mask layer not found: %s" % mask_layer_name, "success": false}
			if mask_layer.type != LayerV2.Type.MASK:
				return {"error": "Mask layer must be a mask layer", "success": false}

			# Get image and mask buffers
			var image_buffer: PackedByteArray = source_layer.image.save_png_to_buffer()
			var mask_buffer: PackedByteArray = MediaGen.generate_mask_bytes(mask_layer.image, Color.WHITE, "white")

			var images_dir: Array = [
				{"filename": "input_image.png", "buffer": image_buffer},
				{"filename": "mask.png", "buffer": mask_buffer}
			]
			_current_image_gen_request_id = MediaGen.send_media_selective_edit_request(gen_params, images_dir)
			return {"success": true, "request_id": _current_image_gen_request_id, "message": "Mask edit started"}

	return {"error": "Unknown action: %s" % action_id, "success": false}

#endregion

var canvas_size: = Vector2i(DEFAULT_IMAGE_GEN_RES, DEFAULT_IMAGE_GEN_RES)

var _custom_cursor: Resource
var _custom_cursor_shape: int = 0  # Control.CursorShape as int
var _custom_cursor_hotspot: Vector2
var _mouse_in_layers_container: bool = false


const COMMANDS_SIZE: = 15
var _command_idx: = -1
var _commands: Array[GraphicsEditorUndo.Command] = []

var layers: Array[LayerV2]

## Array of selected layers, in order in which they were selected
var selected_layers: Array[LayerV2] = []
var selected_mask_layers: Array[LayerV2] = []
var selected_control_layers: Array[LayerV2] = []
var is_active_layer_mask: = false
var is_active_layer_control: = false
var active_layer: LayerV2:
	get:
		if selected_layers.is_empty() and selected_mask_layers.is_empty() and selected_control_layers.is_empty():
			return layers[0] if not layers.is_empty() else null
		if is_active_layer_control:
			return selected_control_layers.get(0) if not selected_control_layers.is_empty() else null
		if is_active_layer_mask:
			return selected_mask_layers.get(0) if not selected_mask_layers.is_empty() else null
		else:
			return selected_layers.get(0) if not selected_layers.is_empty() else null

var last_selected_color: Color = Color.BLACK

# Selection system
var selection_mask: Image = null
var selection_visible: bool = true
var _marching_ants_offset: float = 0.0
var _marching_ants_timer: float = 0.0
const MARCHING_ANTS_SPEED: float = 10.0  # pixels per second
var _selection_is_empty: bool = true  # Cached flag to avoid O(W×H) scan on every pixel check
var _cached_selection_edges: Array[Vector2i] = []  # Cached edge pixels for marching ants
var _edges_cache_valid: bool = false  # Whether edge cache is up to date
var _selection_bbox: Rect2i = Rect2i()  # Bounding box of selection for optimized iteration

var active_tool: BaseTool:
	set(value):
		active_tool = value
		# reset the cursor here,
		# so it happends before the signal is consumed by selected tool which may change it
		set_custom_cursor(null)
		_set_drag_forward_to_layer(active_tool)
		active_tool_changed.emit(value)

var saved: = true
var _previous_tool_before_eraser: BaseTool = null  # Store tool to return to after eraser mode

var _current_image_gen_request_id: String = ""

func _ready() -> void:
	# Initialize AI models registry for MCP tools
	_init_ai_models()

	layer_cards_popup_panel.hide()
	image_gen_window.hide()
	progress_window.hide()
	message_window.hide()
	active_tool_changed.connect(_on_active_tool_changed)
	# Select the Brush tool by default (id 0)
	_select_tool_by_id(0)
	compose_progress_updated.connect(_on_compose_progress)
	compose_finished.connect(_on_compose_complete)
	active_layer_is_mask_layer.connect(_on_active_layer_mask_layer)
	active_layer_is_control_layer.connect(_on_active_layer_control_layer)
	# Connect pen inverted signals
	drawing_tool.pen_inverted_changed.connect(_on_pen_inverted_changed)
	eraser_tool.pen_normal_detected.connect(_on_pen_normal_detected)
	# Connect selection changed signal to update UI
	selection_changed.connect(_on_selection_changed)
	_setup_selection_popup_menu()
	# Connect media generation signal to receive generated images
	MediaGen.pass_image_to_editor.connect(_on_image_received)
	MediaGen.lock_media_gen_ui.connect(_on_lock_media_gen_ui)
	
	var temp_res: = MIN_IMAGE_RES
	var id_to_select: = 0
	var counter: = 0
	while temp_res + 64 <= MAX_IMAGE_GEN_RES:
		var res: = str(temp_res)
		image_width_option_button.add_item(res)
		if temp_res == DEFAULT_IMAGE_GEN_RES:
			id_to_select = counter
		temp_res += 64
		counter += 1
	
	image_width_option_button.select(id_to_select)
	
	delete_layer.connect(_on_delete_layer)
	
	get_viewport().set_embedding_subwindows(false)
	
	mini_map_control.visible = false
	
	if Core.connected:
		enable_ai_features()
	else:
		disable_ai_features(1)
	
	Core.client.connection_established.connect(enable_ai_features)
	
	Core.client.connection_error.connect(disable_ai_features)
	
	Core.client.connection_closed.connect(disable_ai_features)
	
	Core.http_connection_changed.connect(
		func(_active: bool):
			if not Core.connected:
				disable_ai_features(1)
			else:
				enable_ai_features()
	)
	
	input_area_camera.position = layers_container.get_global_rect().get_center()
	input_area_camera.offset = Vector2.ZERO
	
	workflow_option_button.select(0)

	response_layout_toggle()

	# Position drawing area at top-left of viewport on startup
	call_deferred("_position_view_top_left")

	# Clear custom cursor when mouse leaves the entire graphics editor panel
	mouse_exited.connect(_on_graphics_editor_mouse_exited)


func _process(delta: float) -> void:
	# Animate marching ants for selection
	if selection_visible and has_selection():
		_marching_ants_timer += delta
		if _marching_ants_timer >= 0.1:  # Update every 100ms
			_marching_ants_offset = fmod(_marching_ants_offset + 1.0, 8.0)
			_marching_ants_timer = 0.0
			selection_overlay.queue_redraw()

	# Update selection mode label based on modifier keys
	_update_selection_mode_label()


func _update_selection_mode_label() -> void:
	if not selection_mode_label or not _selection_options_container.visible:
		return

	var mode_text: String
	if Input.is_key_pressed(KEY_SHIFT) and Input.is_key_pressed(KEY_ALT):
		mode_text = "Mode: Intersect"
	elif Input.is_key_pressed(KEY_SHIFT):
		mode_text = "Mode: Add"
	elif Input.is_key_pressed(KEY_ALT):
		mode_text = "Mode: Subtract"
	else:
		mode_text = "Mode: Replace"

	if selection_mode_label.text != mode_text:
		selection_mode_label.text = mode_text


func setup(canvas_size_: Vector2i = Vector2i(DEFAULT_IMAGE_GEN_RES, DEFAULT_IMAGE_GEN_RES)) -> void:
	# Create layers in order (first created appears at bottom in visual stack)
	create_new_layer("Background", canvas_size_, Color.WHITE, false)
	create_new_layer("Canvas", canvas_size_, Color.TRANSPARENT, false, true)
	create_new_layer("Drawing", canvas_size_, Color.TRANSPARENT, true)  # Selected by default


func create_new_layer(layer_name: String, dimensions: Vector2i, color: Color = Color.TRANSPARENT, select: = true, locked: = false) -> LayerV2:
	deselect_layers()
	var layer: = LayerV2.create_drawing_layer(layer_name, dimensions, color)
	
	layer.locked = locked

	add_layer(layer, select)

	return layer

func create_new_image_layer(layer_name: String, image: Image, select: = true) -> LayerV2:
	deselect_layers()
	var layer: = LayerV2.create_image_layer(layer_name, image)
	
	add_layer(layer, select)

	return layer


func create_new_mask_layer(layer_name: String, dimensions: Vector2i, color: Color = Color.TRANSPARENT, select: = true, locked: = false) -> LayerV2:
	deselect_layers()
	var layer: = LayerV2.create_mask_layer(layer_name, dimensions, color)
	
	layer.locked = locked

	add_mask_layer(layer, select)

	return layer


func add_mask_layer(layer: LayerV2, select: = true) -> LayerV2:
	layer.tree_exiting.connect(_on_mask_layer_tree_exiting.bind(layer))

	var layer_card: = LayerCard.create(self, layer)

	layer_card.layer_selected.connect(_on_layer_card_selected.bind(layer, layer_card))
	layer_card.layer_deselected.connect(_on_layer_card_deselected.bind(layer, layer_card))
	layer_card.reorder.connect(_on_layer_card_reorder.bind(layer_card))
	layer_card.layer_clicked.connect(_on_layer_card_clicked.bind(layer_card))

	mask_layer_cards_container.add_child(layer_card)
	mask_layer_cards_container.move_child(layer_card, 0)
	layer_card.selected = select

	layers_container.add_child(layer, true)

	layers.append(layer)

	return layer


func create_new_control_layer(layer_name: String, dimensions: Vector2i, control_type: LayerV2.ControlType = LayerV2.ControlType.POSE, select: = true) -> LayerV2:
	var layer: = LayerV2.create_control_layer(layer_name, dimensions, control_type)

	add_control_layer(layer, select)

	return layer


func add_control_layer(layer: LayerV2, select: = true) -> LayerV2:
	layer.tree_exiting.connect(_on_control_layer_tree_exiting.bind(layer))

	var layer_card: = LayerCard.create(self, layer)

	layer_card.layer_selected.connect(_on_layer_card_selected.bind(layer, layer_card))
	layer_card.layer_deselected.connect(_on_layer_card_deselected.bind(layer, layer_card))
	layer_card.reorder.connect(_on_layer_card_reorder.bind(layer_card))
	layer_card.layer_clicked.connect(_on_layer_card_clicked.bind(layer_card))

	control_layer_cards_container.add_child(layer_card)
	control_layer_cards_container.move_child(layer_card, 0)
	layer_card.selected = select

	layers_container.add_child(layer, true)

	layers.append(layer)

	return layer


func add_layer(layer: LayerV2, select: = true) -> LayerV2:
	layer.tree_exiting.connect(_on_layer_tree_exiting.bind(layer))

	# Invalidate compose cache when new layer is added (needed for iterative generation)
	_compose_result_expired = true

	var layer_card: = LayerCard.create(self, layer)

	layer_card.layer_selected.connect(_on_layer_card_selected.bind(layer, layer_card))
	layer_card.layer_deselected.connect(_on_layer_card_deselected.bind(layer, layer_card))
	layer_card.reorder.connect(_on_layer_card_reorder.bind(layer_card))
	layer_card.layer_clicked.connect(_on_layer_card_clicked.bind(layer_card))

	if layer_cards_container:
		layer_cards_container.add_child(layer_card)
		layer_cards_container.move_child(layer_card, 0)
	layer_card.selected = select
	if layers_container:
		layers_container.add_child(layer, true)

	layers.append(layer)
	
	return layer

# when layer is deleted remove it from selected layers if it's there
func _on_layer_tree_exiting(layer: LayerV2) -> void:
	selected_layers.erase(layer)
	layers.erase(layer)


func _on_mask_layer_tree_exiting(layer: LayerV2) -> void:
	selected_mask_layers.erase(layer)
	layers.erase(layer)


func _on_control_layer_tree_exiting(layer: LayerV2) -> void:
	selected_control_layers.erase(layer)
	layers.erase(layer)


func _on_layer_card_selected(layer: LayerV2, _layer_card: LayerCard):
	if not selected_layers.has(layer) and (LayerV2.Type.DRAWING == layer.type or LayerV2.Type.IMAGE == layer.type):
		selected_layers.append(layer)
	if not selected_mask_layers.has(layer) and LayerV2.Type.MASK == layer.type:
		selected_mask_layers.append(layer)
	if not selected_control_layers.has(layer) and LayerV2.Type.CONTROL == layer.type:
		selected_control_layers.append(layer)

	# Determine which layer type is now active
	is_active_layer_control = false
	is_active_layer_mask = false
	if selected_control_layers.size() > 0 and selected_control_layers[0].type == LayerV2.Type.CONTROL:
		is_active_layer_control = true
		active_layer_is_control_layer.emit(true)
		active_layer_is_mask_layer.emit(false)
	elif selected_mask_layers.size() > 0 and selected_mask_layers[0].type == LayerV2.Type.MASK:
		is_active_layer_mask = true
		active_layer_is_mask_layer.emit(true)
		active_layer_is_control_layer.emit(false)
	elif selected_layers.size() > 0:
		active_layer_is_mask_layer.emit(false)
		active_layer_is_control_layer.emit(false)

	check_ai_buttons_toggle()


func _on_layer_card_deselected(layer: LayerV2, _layer_card: LayerCard):
	selected_layers.erase(layer)
	selected_mask_layers.erase(layer)
	selected_control_layers.erase(layer)

	# Determine which layer type is now active
	is_active_layer_control = false
	is_active_layer_mask = false
	if selected_control_layers.size() > 0 and selected_control_layers[0].type == LayerV2.Type.CONTROL:
		is_active_layer_control = true
		active_layer_is_control_layer.emit(true)
		active_layer_is_mask_layer.emit(false)
	elif selected_mask_layers.size() > 0 and selected_mask_layers[0].type == LayerV2.Type.MASK:
		is_active_layer_mask = true
		active_layer_is_mask_layer.emit(true)
		active_layer_is_control_layer.emit(false)
	elif selected_layers.size() > 0:
		active_layer_is_mask_layer.emit(false)
		active_layer_is_control_layer.emit(false)

	check_ai_buttons_toggle()


func _on_layer_card_clicked(button_index: int, layer_card: LayerCard):
	if button_index == MOUSE_BUTTON_LEFT:

		if layer_card.layer.locked: return # ignore locked layers

		if Input.is_key_pressed(KEY_CTRL):
			layer_card.selected = not layer_card.selected
		elif layer_card.selected:
			layer_card.selected = false
		else:
			# Deselect other layers in the same category
			match layer_card.layer.type:
				LayerV2.Type.MASK:
					for c: LayerCard in mask_layer_cards_container.get_children():
						c.selected = false
				LayerV2.Type.CONTROL:
					for c: LayerCard in control_layer_cards_container.get_children():
						c.selected = false
				_:  # IMAGE, DRAWING, SPEECH_BUBBLE
					for c: LayerCard in layer_cards_container.get_children():
						c.selected = false
			layer_card.selected = true


func _on_layer_card_reorder(to: int, layer_card: LayerCard):
	reorder_layer(layer_card.layer, to)


func display_message(title: String, content: String):
	message_window.popup_centered()
	message_title.text = title
	message_content.text = content

# FIXME: change this
func export_image(path: String) -> Error:
	
	var image: = await compose_final_image()

	if image.is_empty():
		return ERR_INVALID_DATA

	var error: = image.save_png(path)

	return error

# Helper function to get corners of a rotated layer
func _get_rotated_corners(layer: LayerV2) -> Array[Vector2]:
	var corners: Array[Vector2] = []
	var pivot = layer.pivot_offset
	var pos = layer.position
	var _size = layer.size
	var rotation_rad = layer.rotation
	
	# Calculate the four corners in local space
	var local_corners = [
		Vector2(0, 0) - pivot,           # Top-left
		Vector2(_size.x, 0) - pivot,      # Top-right
		Vector2(_size.x, _size.y) - pivot, # Bottom-right
		Vector2(0, _size.y) - pivot       # Bottom-left
	]
	
	# Transform to global space
	for corner in local_corners:
		# Rotate
		var rotated = corner.rotated(rotation_rad)
		# Translate to global position
		var global_corner = rotated + pivot + pos
		corners.append(global_corner)
	
	return corners

# Convert from global space to layer's local space (accounting for rotation)
func _global_to_layer_space(global_pos: Vector2, layer_pos: Vector2, rotation_rad: float, pivot: Vector2) -> Vector2:
	# Translate to layer's origin
	var relative_pos = global_pos - layer_pos
	# Adjust for pivot point
	relative_pos -= pivot
	# Apply inverse rotation
	relative_pos = relative_pos.rotated(-rotation_rad)
	# Re-adjust for pivot
	relative_pos += pivot
	
	return relative_pos

func set_custom_cursor(image: Resource = null, shape: int = 0, hotspot: Vector2 = Vector2.ZERO):
	_custom_cursor = image
	_custom_cursor_shape = shape
	_custom_cursor_hotspot = hotspot

	if image:
		# Apply cursor globally - don't restrict to container bounds
		# This prevents cursor flickering when pointer moves faster than rendered content
		# (See: Felt Engineering blog on dynamic cursor rotation)
		Input.set_custom_mouse_cursor(image, Input.CURSOR_ARROW, hotspot)
		layers_container.mouse_default_cursor_shape = Control.CURSOR_ARROW
	else:
		# Clear any custom cursor image
		Input.set_custom_mouse_cursor(null)
		# Set the control's default cursor shape directly
		var casted_shape = shape as Control.CursorShape
		layers_container.mouse_default_cursor_shape = casted_shape

func reorder_layer(layer: LayerV2, index: int) -> void:
	if not layer.has_meta("layer_card") or not layer.get_meta("layer_card") is LayerCard:
		push_error("Can't reorder layer %s to index %s, because of the invalid metadata on it" % [layer, index])
		return

	var layer_card: LayerCard = layer.get_meta("layer_card")
	
	if layer.type == LayerV2.Type.MASK:
		if index - layer_card.get_index() == 1:
			# same final order if we drop it on next index
			return
		if layer_card.get_index() < index:
			index -= 1
		if index == mask_layer_cards_container.get_child_count():
			index -= 1
		layers_container.move_child(layer, -(index+1))
		mask_layer_cards_container.move_child(layer_card, index)
	else:
		if index - layer_card.get_index() == 1:
			# same final order if we drop it on next index
			return
		if layer_card.get_index() < index:
			index -= 1
		if index == layer_cards_container.get_child_count():
			index -= 1
		layers_container.move_child(layer, -(index+1))
		layer_cards_container.move_child(layer_card, index)

# Why graphics editor instead of just layers container?
# When using layers container, pan tool acts wierd and i don't know why exactly.
# Control with tools is set to stop the mouse events to accommodate for the below input hadnling
var dragging: = false
var last_mouse_position: Vector2 = Vector2.ZERO

func _on_layers_container_gui_input(event: InputEvent) -> void:
	_gui_input(event)

func _gui_input(event: InputEvent) -> void:
	
	#region Move Canvas
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.is_pressed():
				dragging = true
				last_mouse_position = event.position
				return
			else:
				dragging = false
				return
		
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(event.position, ZOOM_INCREMENT)
			return
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(event.position, ZOOM_DECREMENT)
			return
	if event is InputEventMouseMotion:
		if dragging:
			# Pan all layers together
			var relative = event.position - last_mouse_position
			_pan_canvas(relative)
			last_mouse_position = event.position
			return
	#endregion Move Canvas

	# Handle active tool input
	# PanTool and SelectTool should work even without visible layers selected
	# Other tools need visible layers to function
	if active_tool:
		var should_handle = false
		if active_tool is PanTool or active_tool is SelectTool:
			# PanTool and SelectTool can work without selected layers
			should_handle = true
		elif selected_layers.any(func(l: LayerV2): return l.is_visible_in_tree()) or selected_mask_layers.any(func(l: LayerV2): return l.is_visible_in_tree()) or selected_control_layers.any(func(l: LayerV2): return l.is_visible_in_tree()):
			# Other tools need visible layers
			should_handle = true

		if should_handle:
			if active_tool.handle_input_event(event):
				_compose_result_expired = true
				saved = false
				graphics_editor_changed.emit()
				accept_event()  # Only accept if tool actually handled the event


func _pan_canvas(relative: Vector2) -> void:
	if input_area_camera.zoom.x == 0.0:
		return
	input_area_camera.offset -= relative * PAN_FACTOR * (1 / input_area_camera.zoom.x) 


func _zoom(mouse_position: Vector2, factor: float) -> void:
	if input_area_camera.zoom.x * factor < MIN_ZOOM or input_area_camera.zoom.x * factor > MAX_ZOOM:
		return
	# Get viewport size (the SubViewport that contains the camera)
	var viewport_size = input_area_camera.get_viewport().size
	
	# Mouse position relative to viewport center (camera looks at center by default)
	var mouse_offset = mouse_position - Vector2(viewport_size) / 2.0
	
	# World position under mouse = camera_pos + mouse_offset / zoom
	var world_pos_before = input_area_camera.position + mouse_offset / input_area_camera.zoom
	
	# Apply zoom
	input_area_camera.zoom *= factor
	
	# Adjust camera so world_pos_before stays under mouse
	input_area_camera.position = world_pos_before - mouse_offset / input_area_camera.zoom


signal graphics_editor_changed
func _unhandled_key_input(event: InputEvent) -> void:

	if event.is_action_pressed("ui_undo"):
		undo_command()

	elif event.is_action_pressed("ui_redo"):
		redo_command()

	# Selection keyboard shortcuts
	elif event is InputEventKey and event.pressed:
		_handle_selection_shortcuts(event)


func _handle_selection_shortcuts(event: InputEventKey) -> void:
	# Delete selection contents
	if event.keycode == KEY_DELETE and has_selection():
		delete_selection()
		get_viewport().set_input_as_handled()

	# Select All (Ctrl+A)
	elif event.keycode == KEY_A and event.ctrl_pressed and not event.shift_pressed:
		select_all()
		get_viewport().set_input_as_handled()

	# Deselect (Ctrl+D)
	elif event.keycode == KEY_D and event.ctrl_pressed and not event.shift_pressed:
		clear_selection()
		get_viewport().set_input_as_handled()

	# Invert Selection (Ctrl+Shift+I)
	elif event.keycode == KEY_I and event.ctrl_pressed and event.shift_pressed:
		invert_selection()
		get_viewport().set_input_as_handled()

	# Fill with foreground color (Alt+Backspace)
	elif event.keycode == KEY_BACKSPACE and event.alt_pressed and has_selection():
		fill_selection(last_selected_color)
		get_viewport().set_input_as_handled()


func _draw() -> void:
	# Propagate redraw to selected layers so their textures update when image pixels change
	for layer in selected_layers: layer.queue_redraw()
	for layer in selected_mask_layers: layer.queue_redraw()
	for c: LayerCard in layer_cards_container.get_children():
		c.queue_redraw()
	for c: LayerCard in mask_layer_cards_container.get_children():
		c.queue_redraw()

## Delegates drag handling functions to given layer.[br]
## See [method Control.set_drag_forwarding].
func _set_drag_forward_to_layer(tool_: BaseTool) -> void:
	#return
	if not tool_: return

	var gdd = tool_.get("_get_drag_data")
	print(gdd)
	gdd = gdd if gdd else Callable()

	var cdd = tool_.get("_can_drop_data")
	cdd = cdd if cdd else Callable()

	var dd = tool_.get("_drop_data")
	dd = dd if dd else Callable()
	
	prints(gdd, cdd, dd)

	set_drag_forwarding(gdd, cdd, dd)

func _on_active_tool_changed(tool_: BaseTool) -> void:
	for child in tool_options_container.get_children():
		child.visible = false
	
	var options: Control = tool_options_mapping.get(tool_)

	if options: options.visible = true

func _on_pen_inverted_changed(is_inverted: bool) -> void:
	if is_inverted:
		# Switch to eraser tool when pen is inverted
		if active_tool != eraser_tool:
			_previous_tool_before_eraser = active_tool
			eraser_tool.set_activated_by_pen(true)  # Mark that eraser was activated by pen
			active_tool = eraser_tool
			# Update the UI to show eraser is selected (id 1)
			_select_tool_by_id(1, false)
	else:
		# Switch back to previous tool when pen is normal
		if active_tool == eraser_tool and _previous_tool_before_eraser:
			active_tool = _previous_tool_before_eraser
			# Update UI to show the previous tool
			if _previous_tool_before_eraser == drawing_tool:
				_select_tool_by_id(0, false)  # Brush
			elif _previous_tool_before_eraser == bucket_tool:
				_select_tool_by_id(3, false)  # Bucket
			elif _previous_tool_before_eraser == smudge_tool:
				_select_tool_by_id(2, false)  # Smudge
			_previous_tool_before_eraser = null


func _on_pen_normal_detected() -> void:
	# Called when eraser tool detects pen is no longer inverted
	if active_tool == eraser_tool and _previous_tool_before_eraser:
		active_tool = _previous_tool_before_eraser
		# Update UI to show the previous tool
		if _previous_tool_before_eraser == drawing_tool:
			_select_tool_by_id(0, false)  # Brush
		elif _previous_tool_before_eraser == bucket_tool:
			_select_tool_by_id(3, false)  # Bucket
		elif _previous_tool_before_eraser == smudge_tool:
			_select_tool_by_id(2, false)  # Smudge
		_previous_tool_before_eraser = null

#region Selection System

## Returns true if there is an active, non-empty selection
func has_selection() -> bool:
	return selection_mask != null and not _selection_is_empty

## Update the cached _selection_is_empty flag and bounding box - call this when selection changes
func _update_selection_cache() -> void:
	_edges_cache_valid = false  # Invalidate edges cache too
	if not selection_mask:
		_selection_is_empty = true
		_selection_bbox = Rect2i()
		_cached_selection_edges.clear()
		return

	# Scan to determine if selection is empty and calculate bounding box
	var w = selection_mask.get_width()
	var h = selection_mask.get_height()
	var min_x = w
	var min_y = h
	var max_x = -1
	var max_y = -1
	var found_any = false

	for y in h:
		for x in w:
			if selection_mask.get_pixel(x, y).r > 0.5:
				found_any = true
				min_x = mini(min_x, x)
				min_y = mini(min_y, y)
				max_x = maxi(max_x, x)
				max_y = maxi(max_y, y)

	if found_any:
		_selection_is_empty = false
		_selection_bbox = Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)
	else:
		_selection_is_empty = true
		_selection_bbox = Rect2i()
		_cached_selection_edges.clear()

## Get cached selection edges for marching ants rendering
func get_selection_edges() -> Array[Vector2i]:
	if _edges_cache_valid:
		return _cached_selection_edges

	_cached_selection_edges.clear()
	if not selection_mask or _selection_is_empty:
		_edges_cache_valid = true
		return _cached_selection_edges

	var w = selection_mask.get_width()
	var h = selection_mask.get_height()

	# Only iterate over bounding box instead of entire image for performance
	var x_start = _selection_bbox.position.x
	var y_start = _selection_bbox.position.y
	var x_end = x_start + _selection_bbox.size.x
	var y_end = y_start + _selection_bbox.size.y

	for y in range(y_start, y_end):
		for x in range(x_start, x_end):
			if selection_mask.get_pixel(x, y).r > 0.5:
				# Check if this is an edge pixel (has unselected neighbor)
				var is_edge = false
				if x == 0 or x == w-1 or y == 0 or y == h-1:
					is_edge = true
				elif selection_mask.get_pixel(x-1, y).r < 0.5 or \
					 selection_mask.get_pixel(x+1, y).r < 0.5 or \
					 selection_mask.get_pixel(x, y-1).r < 0.5 or \
					 selection_mask.get_pixel(x, y+1).r < 0.5:
					is_edge = true
				if is_edge:
					_cached_selection_edges.append(Vector2i(x, y))

	_edges_cache_valid = true
	return _cached_selection_edges

## Create a new selection mask of the given size, filled with black (no selection)
func create_selection_mask(size_: Vector2i) -> void:
	selection_mask = Image.create(size_.x, size_.y, false, Image.FORMAT_L8)
	selection_mask.fill(Color.BLACK)
	_selection_is_empty = true
	_selection_bbox = Rect2i()
	_edges_cache_valid = false
	_cached_selection_edges.clear()

## Clear the current selection (deselect all)
func clear_selection() -> void:
	if selection_mask:
		selection_mask.fill(Color.BLACK)
	_selection_is_empty = true
	_selection_bbox = Rect2i()
	_edges_cache_valid = false
	_cached_selection_edges.clear()
	selection_changed.emit()
	selection_overlay.queue_redraw()

## Select the entire canvas
func select_all() -> void:
	if active_layer and active_layer.image:
		create_selection_mask(active_layer.image.get_size())
		selection_mask.fill(Color.WHITE)
		_selection_is_empty = false
		_edges_cache_valid = false  # Edges need recalculation
		selection_changed.emit()
		queue_redraw()

## Invert the current selection
func invert_selection() -> void:
	if not selection_mask:
		return
	for y in selection_mask.get_height():
		for x in selection_mask.get_width():
			var current = selection_mask.get_pixel(x, y).r
			selection_mask.set_pixel(x, y, Color(1.0 - current, 1.0 - current, 1.0 - current))
	_update_selection_cache()  # Recalculate whether selection is empty
	selection_changed.emit()
	queue_redraw()

## Delete the contents within the selection (make transparent)
func delete_selection() -> void:
	if not has_selection() or not active_layer:
		return
	var command = GraphicsEditorUndo.DrawStrokeCommand.new(active_layer)
	var image = active_layer.image
	for y in selection_mask.get_height():
		for x in selection_mask.get_width():
			if selection_mask.get_pixel(x, y).r > 0.5:
				if x < image.get_width() and y < image.get_height():
					image.set_pixel(x, y, Color.TRANSPARENT)
	command.finalize_stroke()
	execute_command(command)
	active_layer.queue_redraw()
	_compose_result_expired = true
	saved = false
	graphics_editor_changed.emit()

## Fill the selection with the given color
func fill_selection(color: Color) -> void:
	if not has_selection() or not active_layer:
		return
	var command = GraphicsEditorUndo.DrawStrokeCommand.new(active_layer)
	var image = active_layer.image
	for y in selection_mask.get_height():
		for x in selection_mask.get_width():
			if selection_mask.get_pixel(x, y).r > 0.5:
				if x < image.get_width() and y < image.get_height():
					image.set_pixel(x, y, color)
	command.finalize_stroke()
	execute_command(command)
	active_layer.queue_redraw()
	_compose_result_expired = true
	saved = false
	graphics_editor_changed.emit()

## Check if a pixel position is within the selection (for drawing tools)
func is_pixel_selected(x: int, y: int) -> bool:
	if not has_selection():
		return true  # No selection means all pixels are "selected"
	if not selection_mask:
		return true
	if x < 0 or x >= selection_mask.get_width() or y < 0 or y >= selection_mask.get_height():
		return false
	return selection_mask.get_pixel(x, y).r > 0.5

#endregion Selection System

#region LayersCards PopUp panel
func _on_new_layer_button_pressed() -> void:
	create_new_layer("Layer", canvas_size)


func _on_copy_layer_button_pressed() -> void:
	for i: LayerV2 in selected_layers:
		var j: LayerV2 = i.duplicate()
		j.image = i.image.duplicate()
		add_layer(j, false)


func _on_merge_layers_button_pressed() -> void:
	merge_layers(selected_layers.duplicate())


func _on_delete_layer_button_pressed() -> void:
	for i: LayerCard in layer_cards_container.get_children():
		if i.selected:
			i.delete_layer()

#endregion LayersCards PopUp panel

func _on_brush_tool_button_toggled(toggled_on: bool) -> void:
	active_tool = drawing_tool if toggled_on else null

func _on_bucket_tool_button_toggled(toggled_on:bool) -> void:
	active_tool = bucket_tool if toggled_on else null

func _on_pane_tool_button_toggled(toggled_on:bool) -> void:
	if not toggled_on:
		_select_tool_by_id(13)  # Select tool
		_tools_option_button.grab_focus()
		return

	active_tool = pan_tool if toggled_on else null


func _on_eraser_tool_button_toggled(toggled_on: bool) -> void:
	if toggled_on:
		eraser_tool.set_activated_by_pen(false)  # Mark that eraser was activated manually
		active_tool = eraser_tool
	else:
		active_tool = null


func _on_transform_tool_button_toggled(toggled_on: bool) -> void:
	if not toggled_on:
		_select_tool_by_id(13)  # Select tool
		_tools_option_button.grab_focus()
		return

	active_tool = transform_tool if toggled_on else null


func _on_speech_bubble_tool_button_toggled(toggled_on:bool) -> void:
	active_tool = speech_bubble_tool if toggled_on else null

func _on_smudge_tool_button_toggled(toggled_on: bool) -> void:
	active_tool = smudge_tool if toggled_on else null

func _on_layers_container_mouse_entered() -> void:
	_mouse_in_layers_container = true
	# Cursor is now managed globally, no need to re-apply on container enter


func _on_add_image_button_pressed() -> void:
	var fd: = FileDialog.new()
	
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	# fd.filters = []

	fd.file_selected.connect(_on_file_selected)

	add_child(fd)

	fd.popup_centered()

func _on_file_selected(fp: String) -> void:
	var image: = Image.load_from_file(fp)

	var l: = LayerV2.create_image_layer(fp.get_file(), image)

	add_layer(l)

	# reselect the Select tool
	_select_tool_by_id(13)

func _on_layers_container_mouse_exited() -> void:
	_mouse_in_layers_container = false
	# Don't clear cursor on container exit - let tools manage cursor state globally
	# This prevents cursor flickering when pointer moves outside container bounds
	# but is still within the interactive area (e.g., transform handles outside layer)


func _on_graphics_editor_mouse_exited() -> void:
	# Clear custom cursor when leaving the entire graphics editor panel
	# This restores normal cursor when moving to other UI elements
	Input.set_custom_mouse_cursor(null)
	layers_container.mouse_default_cursor_shape = Control.CURSOR_ARROW


func merge_layers(to_merge: Array[LayerV2]) -> LayerV2:
	if to_merge.is_empty():
		push_error("Cannot merge empty array of layers")
		return null
	
	if to_merge.size() == 1:
		return to_merge[0]  # Nothing to merge
	
	# Calculate the bounding rectangle for all layers
	var bounds := Rect2()
	var first_layer := true
	
	for layer in to_merge:
		if not layer.visible:
			continue  # Skip invisible layers
			
		# Get the layer's bounding rect in global space
		var layer_rect = Rect2(layer.position, layer.size)
		
		# Handle rotation by getting rotated corners
		if layer.rotation != 0:
			var corners = _get_rotated_corners(layer)
			for corner in corners:
				if first_layer:
					bounds = Rect2(corner, Vector2.ZERO)
					first_layer = false
				else:
					bounds = bounds.expand(corner)
		else:
			if first_layer:
				bounds = layer_rect
				first_layer = false
			else:
				bounds = bounds.merge(layer_rect)
	
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		push_error("Invalid bounds calculated for merged layers")
		return null
	
	# Create a new image with the calculated bounds size
	var merged_image := Image.create(int(bounds.size.x), int(bounds.size.y), false, Image.FORMAT_RGBA8)
	merged_image.fill(Color(0, 0, 0, 0))  # Transparent background
	
	# Sort layers by their z-index (drawing order) - top layers first (higher index = on top)
	var sorted_layers: = to_merge.duplicate()
	sorted_layers.sort_custom(func(a: LayerV2, b: LayerV2): 
		return layers_container.get_children().find(a) < layers_container.get_children().find(b)
	)
	
	progress_window.show()
	progress_window_label.text = "Merging Layers"
	# Calculate total pixels for progress reporting
	var width: = int(bounds.size.x)
	var height: = int(bounds.size.y)
	var total_pixels: int = width * height * to_merge.size()
	var processed_pixels: int = 0
	var progress_update_interval: int = 100#max(1000, int(total_pixels / 100.0))
	
	
	# Blend each layer onto the merged image
	for layer in sorted_layers:
		if not layer.visible or not layer.image or layer.image.is_empty():
			continue
			
		var layer_image = layer.image
		var layer_pos = layer.position
		var rotation_rad = layer.rotation
		var pivot = layer.pivot_offset
		
		# For each pixel in the merged image
		for y in range(int(bounds.size.y)):
			for x in range(int(bounds.size.x)):
				# Convert merged image coordinates to global coordinates
				# var global_pos = Vector2(x, y) + bounds.position
				var global_pos = bounds.position + Vector2(x, y)
				
				# Convert global position to layer's local space
				var local_pos: = _global_to_layer_space(global_pos, layer_pos, rotation_rad, pivot)
				
				# Check if the point is within the layer's image bounds
				var img_x = int(local_pos.x)
				var img_y = int(local_pos.y)
				
				if img_x >= 0 and img_x < layer_image.get_width() and img_y >= 0 and img_y < layer_image.get_height():
					var src_color = layer_image.get_pixel(img_x, img_y)
					
					# Skip fully transparent pixels
					if src_color.a <= 0.01:
						continue
					
					# Blend with existing pixel
					var dst_color = merged_image.get_pixel(x, y)
					var blended: Color
					
					# Use the drawing tool's blend function if available, otherwise use our own
					if drawing_tool and drawing_tool.has_method("_blend_colors"):
						blended = drawing_tool._blend_colors(dst_color, src_color)
					else:
						blended = _blend_colors(dst_color, src_color)
					
					merged_image.set_pixel(x, y, blended)
				
				processed_pixels += 1
		
				if processed_pixels % 2000 == 0:
					await get_tree().process_frame # let the UI update
					#processed_pixels = 0
				# Update progress periodically
				if processed_pixels % progress_update_interval == 0:
					var progress = float(processed_pixels) / float(total_pixels)
					call_deferred("_emit_progress", progress)
					#await get_tree().process_frame # let the UI update
	
	progress_window.hide()
	
	var toast: ToastNotification = ToastNotification.create(ToastNotification.Type.SUCCESS, "Merging Layers Completed")
	
	SingletonObject.main_scene.add_child(toast)
	
	if to_merge[0].type == LayerV2.Type.MASK:
		var merged_layer: = LayerV2.create_image_layer("Merged Mask Layer", merged_image)
		merged_layer.type = LayerV2.Type.MASK
		add_mask_layer(merged_layer)
		merged_layer.position = bounds.position
		# Remove original layers and their cards
		for layer in to_merge:
			# Find and remove the layer card
			for card in mask_layer_cards_container.get_children():
				if card is LayerCard and card.layer == layer:
					card.queue_free()
					#break
			# Remove from layers array
			layers.erase(layer)
			selected_mask_layers.erase(layer)
			# Remove from scene
			layer.queue_free()
		
		return merged_layer
	else:
		var merged_layer = LayerV2.create_image_layer("Merged Layer", merged_image)
		# Add the merged layer to the editor
		add_layer(merged_layer)
		# We need to set the position here, after the add_layer
		# because that function resets this property, not sure where exactly
		merged_layer.position = bounds.position
		# Remove original layers and their cards
		for layer in to_merge:
			# Find and remove the layer card
			for card in layer_cards_container.get_children():
				if card is LayerCard and card.layer == layer:
					card.queue_free()
					#break
			# Remove from layers array
			layers.erase(layer)
			selected_layers.erase(layer)
			# Remove from scene
			layer.queue_free()
			
		return merged_layer

# Helper function for color blending (alpha compositing)
func _blend_colors(dst: Color, src: Color) -> Color:
	if src.a == 0.0:
		return dst
	if dst.a == 0.0:
		return src
	
	var alpha: float = src.a + dst.a * (1.0 - src.a)
	if alpha == 0.0:
		return Color.TRANSPARENT
	
	var r: float = (src.r * src.a + dst.r * dst.a * (1.0 - src.a)) / alpha
	var g: float = (src.g * src.a + dst.g * dst.a * (1.0 - src.a)) / alpha
	var b: float = (src.b * src.a + dst.b * dst.a * (1.0 - src.a)) / alpha
	
	return Color(r, g, b, alpha)

func _on_layer_cards_button_pressed() -> void:
	if !layer_cards_popup_panel.visible:
		layer_cards_popup_panel.position = Vector2(
			(
				layer_cards_toggle_button.global_position.x 
				-layer_cards_popup_panel.size.x/2.0
				+layer_cards_toggle_button.size.x/2.0
			),
			layer_cards_toggle_button.global_position.y + (layer_cards_toggle_button.size.y * 3.0)
		)
		layer_cards_popup_panel.show()
		if top_of_layers_container:
			top_of_layers_container.hide()
		if send_action_button:
			send_action_button.disabled = true
			send_action_button.hide()
	else:
		layer_cards_popup_panel.hide()


func _on_layer_cards_popup_panel_popup_hide() -> void:
	layer_cards_toggle_button.release_focus()
	layer_cards_toggle_button.set_pressed_no_signal(false)

#region Undo
## Stores the executed command in the commands stack.
## The command is treated as completed and ready for undo.
func execute_command(cmd: GraphicsEditorUndo.Command) -> void:
	# if we did execute a undo for some command and now there's a new one
	# delete all the commands after the current index and store the new one
	if _command_idx != _commands.size()-1:
		_commands.resize(_command_idx+1)
	# since this check occurs every time,
	# there must be no more than one command over the limit
	# account for element that will be added
	if _commands.size()+1 > COMMANDS_SIZE:
		_commands.remove_at(0)

	_commands.append(cmd)
	_command_idx = _commands.size()-1


func undo_command() -> void:
	if _command_idx < 0:
		return
	var cmd: = _commands[_command_idx]

	cmd.undo()

	_command_idx = clampi(_command_idx-1, 0, _commands.size()-1)


func redo_command() -> void:

	if _command_idx == _commands.size()-1:
		return # nothing to redo

	var cmd: = _commands[_command_idx+1]

	cmd.redo()

	_command_idx = clampi(_command_idx+1, 0, _commands.size()-1)
#endregion


## Selects a tool in the dropdown by its item ID (not position index)
## If _emit_signal is true, also triggers the item_selected signal
func _select_tool_by_id(item_id: int, _emit_signal: bool = true) -> void:
	for i in range(_tools_option_button.item_count):
		if _tools_option_button.get_item_id(i) == item_id:
			_tools_option_button.select(i)
			if _emit_signal:
				_tools_option_button.item_selected.emit(i)
			return


## Enables or disables a tool dropdown item by its ID
func _set_tool_disabled_by_id(item_id: int, disabled: bool) -> void:
	for i in range(_tools_option_button.item_count):
		if _tools_option_button.get_item_id(i) == item_id:
			_tools_option_button.set_item_disabled(i, disabled)
			return


func _on_tools_option_button_item_selected(index: int) -> void:
	# Get the item's ID (not position index) to match against
	var item_id = _tools_option_button.get_item_id(index)
	match item_id:
		0: _on_brush_tool_button_toggled(true); return
		1: _on_eraser_tool_button_toggled(true); return
		2: _on_smudge_tool_button_toggled(true); return
		3: _on_bucket_tool_button_toggled(true); return
		4: active_tool = null; _on_add_image_button_pressed(); return
		5: active_tool = eyedropper_tool; return
		6: active_tool = magic_wand_tool; return
		7: active_tool = rectangle_select_tool; return
		8: active_tool = lasso_select_tool; return
		9: active_tool = pose_editor_tool; return
		12: active_tool = text_tool; return
		13: active_tool = select_tool; return
		14: active_tool = rectangle_tool; return
		15: active_tool = ellipse_tool; return
		16: active_tool = diagram_shape_tool; return
		17: active_tool = connector_tool; return
		_: pass
	

#region Image compose

var _compose_result_image: Image
var _compose_result_expired: = false
var _current_compose_thread: Thread = null

func _on_compose_progress(progress: float):
	progress_window_bar.set_value_no_signal(progress * 100)

func _on_compose_complete(_image: Image):
	progress_window.hide()
	_compose_result_expired = false


func compose_final_image(show_dialog: = true) -> Image:
	# _compose_result_expired is set to true every time a tool is used
	if _compose_result_image and not _compose_result_expired:
		return _compose_result_image


	# Don't start if already running
	if _current_compose_thread != null and _current_compose_thread.is_alive():
		print("Compose already running, ignoring request")
		return Image.new()
	
	# Clean up previous thread if it exists
	if _current_compose_thread != null:
		if _current_compose_thread.is_alive():
			_current_compose_thread.wait_to_finish()
		_current_compose_thread = null
	
	if show_dialog:
		# Show progress window
		progress_window.popup_centered()
		progress_window_label.text = "Composing image..."
		progress_window_bar.value = 0
	
	# Extract all needed data from nodes in main thread
	var layer_data: Array[Dictionary] = []
	var layer_nodes = layers_container.get_children().filter(func(n): return n is LayerV2)
	
	for layer in layer_nodes:
		if layer is LayerV2 and layer.visible:
			layer_data.append({
				"image": layer.image,
				"position": layer.position,
				"rotation": layer.rotation,
				"pivot_offset": layer.pivot_offset,
				"size": layer.size
			})
	
	# Create and start new thread
	_current_compose_thread = Thread.new()
	_current_compose_thread.start(_compose_image_thread_worker.bind(layer_data))
	
	var img = await compose_finished
	saved = true
	return img

# Replace your thread worker with this simpler version:
func _compose_image_thread_worker(layer_data: Array[Dictionary]):
	print("Starting compose worker thread")
	
	var result_image = _compose_final_image_worker(layer_data)
	
	# Signal completion back to main thread
	call_deferred("_on_compose_finished", result_image)

# Keep your existing _compose_final_image_worker function as is, but update progress reporting:
func _compose_final_image_worker(layer_data: Array) -> Image:
	# If no layers, return empty image
	if layer_data.is_empty():
		return Image.new()
	
	# Determine the bounding rectangle for all layers
	var bounds := Rect2()
	var first_layer := true
	
	for data in layer_data:
		var corners = _get_rotated_corners_static(data.position, data.size, data.rotation, data.pivot_offset)
		for corner in corners:
			if first_layer:
				bounds = Rect2(corner, Vector2.ZERO)
				first_layer = false
			else:
				bounds = bounds.expand(corner)
	
	# Create output image
	var width = int(bounds.size.x)
	var height = int(bounds.size.y)
	var output_image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	output_image.fill(Color(0, 0, 0, 0))
	
	# Calculate total pixels for progress reporting
	var total_pixels = width * height * layer_data.size()
	var processed_pixels = 0
	var progress_update_interval: int = max(1000, int(total_pixels / 100.0))  # Update progress every 1% or 1000 pixels
	
	# Blend all layers onto the output image
	for layer_idx in range(layer_data.size()):
		var data = layer_data[layer_idx]
		var layer_image = data.image
		
		# Skip empty layers
		if not layer_image or layer_image.is_empty():
			processed_pixels += width * height  # Skip this layer's pixels
			continue
		
		var rotation_rad = data.rotation
		var pivot = data.pivot_offset
		var layer_pos = data.position
		
		# Process each pixel in the output image space
		for out_y in range(height):
			for out_x in range(width):
				# Get position in global space
				var global_pos = Vector2(out_x, out_y) + bounds.position
				
				# Convert to layer local space (accounting for rotation)
				var local_pos = _global_to_layer_space_static(global_pos, layer_pos, rotation_rad, pivot)
				
				# Check if the point is within the layer's image
				var img_x = int(local_pos.x)
				var img_y = int(local_pos.y)
				
				if img_x >= 0 and img_x < layer_image.get_width() and img_y >= 0 and img_y < layer_image.get_height():
					var src_color = layer_image.get_pixel(img_x, img_y)
					
					# Skip fully transparent pixels
					if src_color.a > 0.01:
						var dst_color = output_image.get_pixel(out_x, out_y)
						var blended = _blend_colors(dst_color, src_color)
						output_image.set_pixel(out_x, out_y, blended)
				
				processed_pixels += 1
				
				# Update progress periodically
				if processed_pixels % progress_update_interval == 0:
					var progress = float(processed_pixels) / float(total_pixels)
					call_deferred("_emit_progress", progress)
	
	return output_image

# Keep your existing helper functions:
func _emit_progress(progress: float):
	compose_progress_updated.emit(progress)

func _on_compose_finished(image: Image):
	_compose_result_image = image
	compose_finished.emit(image)
	
	# Clean up the thread
	if _current_compose_thread != null and _current_compose_thread.is_alive():
		_current_compose_thread.wait_to_finish()
		_current_compose_thread = null
	else:
		_current_compose_thread.wait_to_finish()
		_current_compose_thread = null

# Add this to handle cleanup when the node is being destroyed:
func _exit_tree():
	if MediaGen.pass_image_to_editor.is_connected(_on_image_received):
		MediaGen.pass_image_to_editor.disconnect(_on_image_received)
	
	if MediaGen.lock_media_gen_ui.is_connected(_on_lock_media_gen_ui):
		MediaGen.lock_media_gen_ui.disconnect(_on_lock_media_gen_ui)
	
	if Core.client.connection_established.is_connected(enable_ai_features):
		Core.client.connection_established.disconnect(enable_ai_features)
	
	if Core.client.connection_error.is_connected(disable_ai_features):
		Core.client.connection_error.disconnect(disable_ai_features)
	
	if Core.client.connection_closed.is_connected(disable_ai_features):
		Core.client.connection_closed.disconnect(disable_ai_features)
	
	if _current_compose_thread != null and _current_compose_thread.is_alive():
		_current_compose_thread.wait_to_finish()
	_current_compose_thread = null
 
# Static helper functions that don't access node properties
static func _get_rotated_corners_static(position_: Vector2, size_: Vector2, rotation_: float, pivot_offset_: Vector2) -> Array[Vector2]:
	var corners: Array[Vector2] = []
	var pivot = pivot_offset_
	var pos = position_
	var rotation_rad = rotation_
	
	# Calculate the four corners in local space
	var local_corners = [
		Vector2(0, 0) - pivot,           # Top-left
		Vector2(size_.x, 0) - pivot,      # Top-right
		Vector2(size_.x, size_.y) - pivot, # Bottom-right
		Vector2(0, size_.y) - pivot       # Bottom-left
	]
	
	# Transform to global space
	for corner in local_corners:
		# Rotate
		var rotated = corner.rotated(rotation_rad)
		# Translate to global position
		var global_corner = rotated + pivot + pos
		corners.append(global_corner)
	
	return corners

static func _global_to_layer_space_static(global_pos: Vector2, layer_pos: Vector2, rotation_rad: float, pivot: Vector2) -> Vector2:
	# Translate to layer's origin
	var relative_pos = global_pos - layer_pos
	# Adjust for pivot point
	relative_pos -= pivot
	# Apply inverse rotation
	relative_pos = relative_pos.rotated(-rotation_rad)
	# Re-adjust for pivot
	relative_pos += pivot
	
	return relative_pos


func _on_prompt_button_pressed() -> void:
	if !image_gen_window.visible:
		image_gen_window.position = Vector2(
			(
				prompt_button.global_position.x 
				-image_gen_window.size.x
				+prompt_button.size.x
			),
			prompt_button.global_position.y + 50
		)
		image_gen_window.show()
	else:
		image_gen_window.hide()


func _on_send_prompt_button_pressed() -> void:
	image_gen_window.hide()
	var params : Dictionary = get_params_image_gen()
	var toast: ToastNotification
	send_prompt_button.modulate = Color.LIME_GREEN
	send_prompt_button.disabled = true
	edit_img_button.disabled = true
	send_mask_edit_button.disabled = true
	if params.is_empty():
		toast =ToastNotification.create(ToastNotification.Type.WARNING, "Please enter a valid prompt for image generation")
	
	else:
		toast =ToastNotification.create(ToastNotification.Type.INFO, "Sending Image Gen request...")
		_current_image_gen_request_id = MediaGen.send_media_gen_request(params)
		image_gen_window.hide()
		layer_cards_popup_panel.hide()
	SingletonObject.main_scene.add_child(toast)
	save_prompt_to_history(params["positive_prompt"], params["negative_prompt"])
	prompt_text_edit.text = ""


func _on_image_received(filename:String, request_id: String, buffer: PackedByteArray) -> void:
	if request_id != _current_image_gen_request_id:
		return
	send_prompt_button.modulate = Color.WHITE
	send_prompt_button.disabled = false
	edit_img_button.modulate = Color.WHITE
	edit_img_button.disabled = false
	send_mask_edit_button.modulate = Color.WHITE
	send_mask_edit_button.disabled = false
	if progress_window.visible:
		progress_window.hide()

	if buffer.is_empty():
		display_message("Error", "Received empty image data from media generation service")
		return

	var image: = Image.new()
	var err = image.load_png_from_buffer(buffer)

	if err != OK:
		display_message("Error", "Failed to load generated image (error: %s)" % err)
		return

	var l: = LayerV2.create_image_layer(filename, image)

	add_layer(l)
	_current_image_gen_request_id = ""


enum AI_REQUEST {
	IMAGE_GEN,
	EDIT_IMAGE,
	MASK_EDIT
}
var ai_request_type: AI_REQUEST = AI_REQUEST.EDIT_IMAGE
func _on_edit_button_pressed() -> void:
	edit_img_button.modulate = Color.LIME_GREEN
	send_prompt_button.disabled = true
	edit_img_button.disabled = true
	send_mask_edit_button.disabled = true
	if floating_windows_active:
		if !layer_cards_popup_panel.visible:
			layer_cards_popup_panel.position = Vector2(
				(
					image_gen_window.position.x 
					-layer_cards_popup_panel.size.x/2.0
					+ image_gen_window.size.x/2.0
				),
				image_gen_window.position.y + image_gen_window.size.y + 30
			)
			if layer_cards_popup_panel.get_child_count() > 0:
				layer_cards_popup_panel.show()
				layer_cards_popup_panel.borderless = false
				ai_action_label.text = "Pick an Layer to Send to Edit"
				%TopOfLayersContainer.show()
				send_action_button.disabled = false
				send_action_button.show()
			ai_request_type = AI_REQUEST.EDIT_IMAGE
		else:
			layer_cards_popup_panel.hide()
			layer_cards_popup_panel.borderless = true
			%TopOfLayersContainer.hide()
			send_action_button.disabled = true
			send_action_button.hide()
	else:
		ai_request_type = AI_REQUEST.EDIT_IMAGE
		send_action_button.pressed.emit()


func _on_edit_img_button_pressed() -> void:
	if ai_request_type == AI_REQUEST.EDIT_IMAGE:
		if selected_layers.size() < 1 or current_workflow == Workflow.Z_TURBO:
			return
		
		var layer_to_send: LayerV2 = selected_layers[0]
		# Get the image from the active layer
		if layer_to_send == null:
			return
		var image_to_edit: Image = layer_to_send.image
		var image_filename: String = layer_to_send.name + ".png" # Use layer name as filename
		# Convert Image to PackedByteArray (PNG format)
		# The image must be converted to RGBA8 for PNG export if it's not already.
		# Duplicate to avoid modifying the original layer image directly during conversion.
		var image_for_export: Image = image_to_edit.duplicate()
		if image_for_export.get_format() != Image.FORMAT_RGBA8:
			image_for_export.convert(Image.FORMAT_RGBA8)
		
		var image_buffer: PackedByteArray = image_for_export.save_png_to_buffer()
		
		if image_buffer.is_empty():
			display_message("Error", "Failed to convert active layer image to PNG buffer.")
			return
		
		var toast : =ToastNotification.create(ToastNotification.Type.INFO, "Sending image edit request...")
		SingletonObject.main_scene.add_child(toast)
		
		var params: Dictionary = get_params_image_gen()
		
		if params.is_empty():
			return
		
		if !seed_line_edit.text.is_empty():
			params["seed"] = seed_line_edit.text
		
		_current_image_gen_request_id = MediaGen.send_media_edit_request(params, image_buffer, image_filename)
		
		image_gen_window.hide()
		layer_cards_popup_panel.hide()
	elif  ai_request_type == AI_REQUEST.MASK_EDIT:
		if selected_layers.size() < 1 or current_workflow == Workflow.Z_TURBO:
			return
		if !selected_layers[0].has_meta("linked_mask_layer") and selected_mask_layers.size() < 1:
			display_message("Mask Required", "Select a mask layer for masked editing.")
			return
		var image_layer_to_edit: LayerV2 = selected_layers[0]
		
		if image_layer_to_edit == null:
			return
		if prompt_text_edit.text.is_empty():
			display_message("Input Required", "Please enter a positive prompt for masked image editing.")
			return
		
		var images_dir: Array = []
		
		var base_image_to_edit: Image = image_layer_to_edit.image
		var base_image_filename: String = image_layer_to_edit.name + ".png" 
		
		
		var base_image_for_export: Image = base_image_to_edit.duplicate()
		if base_image_for_export.get_format() != Image.FORMAT_RGBA8:
			base_image_for_export.convert(Image.FORMAT_RGBA8)
		
		var base_image_buffer: PackedByteArray = base_image_for_export.save_png_to_buffer()
		
		if base_image_buffer.is_empty():
			display_message("Error", "Failed to convert active layer image to PNG buffer for mask editing.")
			return
		var base64_base_image_data: String = Marshalls.raw_to_base64(base_image_buffer)
		
		var image_file: = {
				"filename": base_image_filename,
				"role": "image",
				"data": base64_base_image_data,
				"content_type": "image/png"
			}
		images_dir.append(image_file)
		
		var mask_color_channel: = ""
		if image_layer_to_edit.has_meta("linked_mask_layer"):
			var i: LayerV2 = image_layer_to_edit.get_meta("linked_mask_layer")
			var base_mask_image: = i.image
			var mask_layer_name: = i.name + ".png"
			mask_color_channel = i.layer.mask_color_name
			var base_mask_image_for_export: Image = base_mask_image.duplicate()
			if base_mask_image_for_export.get_format() != Image.FORMAT_RGBA8:
				base_mask_image_for_export.convert(Image.FORMAT_RGBA8)
			
			var base_mask_buffer: PackedByteArray = MediaGen.generate_mask_bytes(base_mask_image_for_export, i.layer.mask_color, mask_color_channel)
			#var base_mask_buffer: PackedByteArray = base_mask_image_for_export.save_png_to_buffer()
			if base_mask_buffer.is_empty():
				display_message("Error", "Error generating the mask image")
				return
			var base64_mask_image_data: String = (Marshalls.raw_to_base64(base_mask_buffer))
			
			var mask_file: = {
			"filename": mask_layer_name,
			"role": "mask",
			"data": base64_mask_image_data,
			"content_type": "image/png"
			}
			images_dir.append(mask_file)
		else:
			for i: LayerV2 in selected_mask_layers:
				if i.type == LayerV2.Type.MASK:
					var base_mask_image: = i.image
					var mask_layer_name: = i.name + ".png"
					mask_color_channel = i.mask_color_name
					var base_mask_image_for_export: Image = base_mask_image.duplicate()
					if base_mask_image_for_export.get_format() != Image.FORMAT_RGBA8:
						base_mask_image_for_export.convert(Image.FORMAT_RGBA8)
					
					var base_mask_buffer: PackedByteArray = MediaGen.generate_mask_bytes(base_mask_image_for_export, i.mask_color, mask_color_channel)
					#var base_mask_buffer: PackedByteArray = base_mask_image_for_export.save_png_to_buffer()
					if base_mask_buffer.is_empty():
						display_message("Error", "Error generating the mask image")
						return
					var base64_mask_image_data: String = (Marshalls.raw_to_base64(base_mask_buffer))
					
					var mask_file: = {
					"filename": mask_layer_name,
					"role": "mask",
					"data": base64_mask_image_data,
					"content_type": "image/png"
					}
					images_dir.append(mask_file)
		
		var toast: = ToastNotification.create(ToastNotification.Type.INFO, "Sending image and mask for selective editing...")
		SingletonObject.main_scene.add_child(toast)
		
		var selective_editing_params: Dictionary = get_params_image_gen()
		selective_editing_params["mask_channel"] = mask_color_channel
		_current_image_gen_request_id = MediaGen.send_media_selective_edit_request(selective_editing_params, images_dir)
		image_gen_window.hide()
		layer_cards_popup_panel.hide()
	prompt_text_edit.text = ""

func _on_advanced_settings_check_button_toggled(toggled_on: bool) -> void:
	advanced_settings_container.visible = toggled_on


func get_params_image_gen() -> Dictionary:
	if prompt_text_edit.text.is_empty():
		return {}
	
	var idx: = image_width_option_button.selected
	var image_res: int = image_width_option_button.get_item_text(idx).to_int()
	return {
		"positive_prompt" = prompt_text_edit.text,
		"negative_prompt" = negative_text_edit.text,
		"width" = image_res,
		"height" = image_res,
		"steps" = steps_spin_box.value,
		"cfg" = cfg_spin_box.value,
		"denoise" = denoise_spin_box.value,
		"topic" = WORKFLOW_TOPICS[current_workflow]
	}


func selected_layers_has_mask() -> bool:
	for i in selected_layers:
		if i.type == LayerV2.Type.MASK:
			return true
	return false


func selected_layers_has_image() -> bool:
	for i in selected_layers:
		if i.type == LayerV2.Type.IMAGE:
			return true
	return false


func get_first_image_layer() -> LayerV2:
	for i in selected_layers:
		if i.type == LayerV2.Type.IMAGE:
			return i
	return null


func _on_mask_edit_button_pressed() -> void: 
	send_mask_edit_button.modulate = Color.LIME_GREEN
	send_prompt_button.disabled = true
	edit_img_button.disabled = true
	send_mask_edit_button.disabled = true
	if floating_windows_active:
		if !layer_cards_popup_panel.visible:
			layer_cards_popup_panel.position = Vector2(
				(
					image_gen_window.position.x 
					-layer_cards_popup_panel.size.x/2.0
					+ image_gen_window.size.x/2.0
				),
				image_gen_window.position.y + image_gen_window.size.y + 30
			)
			layer_cards_popup_panel.borderless = false
			ai_action_label.text = "Pick an Image Layer and a Mask Layer to Send to Edit"
			send_action_button.disabled = false
			ai_request_type = AI_REQUEST.MASK_EDIT
			
			%TopOfLayersContainer.show()
			send_action_button.show()
			image_gen_window.hide()
			layer_cards_popup_panel.show()
		else:
			layer_cards_popup_panel.hide()
			layer_cards_popup_panel.borderless = true
			%TopOfLayersContainer.hide()
			send_action_button.disabled = true
			send_action_button.hide()
	else:
		ai_request_type = AI_REQUEST.MASK_EDIT
		send_action_button.pressed.emit()

#region LayersCards Masks PopUp panel
func _on_new_mask_layer_button_pressed() -> void:
	var new_layer_size: = Vector2.ZERO
	if active_layer != null:
		new_layer_size = active_layer.base_image.get_size()
	else:
		new_layer_size = canvas_size
	create_new_mask_layer("Mask Layer", new_layer_size)
	_on_mask_color_option_button_item_selected(mask_color_option_button.selected)


func _on_delete_mask_layer_button_pressed() -> void:
	for i: LayerCard in mask_layer_cards_container.get_children():
		if i.selected:
			i.delete_layer()


func _on_copy_mask_layer_button_pressed() -> void:
	for i: LayerV2 in selected_mask_layers:
		var j: LayerV2 = i.duplicate()
		j.image = i.image.duplicate()
		add_mask_layer(j, false)


func _on_merge_mask_layers_button_pressed() -> void:
	merge_layers(selected_mask_layers.duplicate())


func _on_new_control_layer_button_pressed() -> void:
	# Deselect other layers
	for c: LayerCard in layer_cards_container.get_children():
		c.selected = false
	for c: LayerCard in mask_layer_cards_container.get_children():
		c.selected = false
	for c: LayerCard in control_layer_cards_container.get_children():
		c.selected = false

	create_new_control_layer("Pose Layer", canvas_size, LayerV2.ControlType.POSE)


func _on_delete_control_layer_button_pressed() -> void:
	for i: LayerCard in control_layer_cards_container.get_children():
		if i.selected:
			i.delete_layer()


func _on_open_pose_editor_button_pressed() -> void:
	# Open the 3D pose editor window
	if pose_editor_window:
		pose_editor_window.show()
		pose_editor_window.grab_focus()


func _on_pose_editor_window_close_requested() -> void:
	if pose_editor_window:
		pose_editor_window.hide()


func _on_pose_editor_panel_pose_rendered(image: Image) -> void:
	# Update the active CONTROL layer with the rendered 2D pose image
	if active_layer and active_layer.type == LayerV2.Type.CONTROL:
		active_layer.image = image
		active_layer.queue_redraw()

#endregion LayersCards Masks PopUp panel

func _on_mask_color_option_button_item_selected(index: int) -> void:
	if active_layer and active_layer.type == active_layer.Type.MASK :
		var mask_color: Color = mask_color_option_button.get_item_icon(index).get_image().get_pixel(0,0)
		color_picker_button.color = mask_color
		active_layer.mask_color = mask_color
		active_layer.mask_color_name = mask_color_option_button.get_item_text(index).to_lower()
		active_layer.lock_color = true


func _on_delete_layer(layer: LayerV2) -> void:
	if layer.tree_exited.is_connected(_on_layer_tree_exiting):
		layer.tree_exited.disconnect(_on_layer_tree_exiting)
	layers.erase(layer)
	selected_layers.erase(layer)
	selected_mask_layers.erase(layer)
	layer.queue_free()


func _on_positive_prompt_mic_button_pressed() -> void:
	if SingletonObject.AtT._StartConverting() != OK: return
	SingletonObject.AtT.FieldForFilling = prompt_text_edit
	SingletonObject.AtT.btn = positive_prompt_mic_button
	positive_prompt_mic_button.modulate = Color(Color.LIME_GREEN)
	SingletonObject.AtT.btnStop = positive_prompt_mic_button


func _on_negative_prompt_mic_button_pressed() -> void:
	if SingletonObject.AtT._StartConverting() != OK: return
	SingletonObject.AtT.FieldForFilling = negative_text_edit
	SingletonObject.AtT.btn = negative_prompt_mic_button
	negative_prompt_mic_button.modulate = Color(Color.LIME_GREEN)
	SingletonObject.AtT.btnStop = negative_prompt_mic_button


func _on_active_layer_mask_layer(is_mask: bool) -> void:
	is_active_layer_mask = is_mask
	color_picker_button.visible = not is_mask
	mask_container.visible = is_mask
	if is_mask:
		_select_tool_by_id(0)  # Brush (id 0)
		_set_tool_disabled_by_id(2, true)  # Smudge
		_set_tool_disabled_by_id(3, true)  # Bucket
		_set_tool_disabled_by_id(4, true)  # Insert Image
		color_picker_button.color = active_layer.mask_color
	else:
		_set_tool_disabled_by_id(2, false)  # Smudge
		_set_tool_disabled_by_id(3, false)  # Bucket
		_set_tool_disabled_by_id(4, false)  # Insert Image
		color_picker_button.color = last_selected_color


func _on_active_layer_control_layer(is_control: bool) -> void:
	var was_control = is_active_layer_control  # Track previous state
	is_active_layer_control = is_control

	if is_control:
		# Check if it's a POSE control layer and auto-select pose tool
		if active_layer and active_layer.control_type == LayerV2.ControlType.POSE:
			_select_tool_by_id(9)  # Pose Editor
		# Disable drawing tools that don't apply to control layers
		_set_tool_disabled_by_id(0, true)  # Brush
		_set_tool_disabled_by_id(1, true)  # Eraser
		_set_tool_disabled_by_id(2, true)  # Smudge
		_set_tool_disabled_by_id(3, true)  # Bucket
		_set_tool_disabled_by_id(4, true)  # Insert Image
	else:
		# Re-enable tools when switching away from control layer
		_set_tool_disabled_by_id(0, false)  # Brush
		_set_tool_disabled_by_id(1, false)  # Eraser
		_set_tool_disabled_by_id(2, false)  # Smudge
		_set_tool_disabled_by_id(3, false)  # Bucket
		_set_tool_disabled_by_id(4, false)  # Insert Image
		# Only switch back to Select tool if we were previously on a control layer
		if was_control:
			_select_tool_by_id(13)  # Select tool


func _on_image_gen_window_close_requested() -> void:
	image_gen_window.hide()
	response_layout_toggle()


func _on_color_picker_button_color_changed(color: Color) -> void:
	last_selected_color = color


func _on_layer_cards_popup_panel_close_requested() -> void:
	layer_cards_popup_panel.hide()
	response_layout_toggle()


func _on_back_button_pressed() -> void:
	image_gen_window.show()
	layer_cards_popup_panel.hide()


func _on_send_action_button_pressed() -> void:
	_on_edit_img_button_pressed()


func _on_resized() -> void:
	if is_node_ready():
		response_layout_toggle()
		if mini_map_control and mini_map_control.visible:
			mini_map_control.custom_minimum_size.x = layers_container.size.x / 6.5
			mini_map_control.custom_minimum_size.y = layers_container.size.y / 6.5
			var margin_con: PanelContainer = mini_map_control.get_child(0)
			margin_con.position = Vector2.ZERO
			margin_con.anchors_preset = Control.PRESET_FULL_RECT

var floating_windows_active: = true  # Always use floating windows mode
func response_layout_toggle() -> void:
	# Always use popup/floating window mode for Layers and AI panels
	# Buttons are always visible, clicking them opens popup windows

	if full_size_ai_container.get_child_count() > 0:
		full_size_ai_container.remove_child(image_gen_panel_container)
		image_gen_window.size = image_gen_panel_container.size
		image_gen_window.add_child(image_gen_panel_container)
		image_gen_panel_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	prompt_button.show()

	if full_size_layers_container.get_child_count() > 0:
		full_size_layers_container.remove_child(layer_cards_panel_container)
		layer_cards_popup_panel.size = layer_cards_panel_container.size
		layer_cards_popup_panel.add_child(layer_cards_panel_container)
		layer_cards_panel_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer_cards_toggle_button.show()

	dock_panel_container.hide()


static var _edit_img_base_tooltip: = "Edit selected Image (edits the currently selected layer with the current prompt)"
#static var _mask_edit_base_tooltip: = "Send mask edit request (needs a mask layer and a regular layer to be selected)"
func check_ai_buttons_toggle() -> void:
	# Always in floating windows mode - enable buttons based on connection status
	if Core.connected:
		edit_img_button.disabled = false
		send_mask_edit_button.disabled = false
	else:
		if edit_img_button:
			edit_img_button.disabled = true
			edit_img_button.tooltip_text = _edit_img_base_tooltip
		if send_mask_edit_button:
			send_mask_edit_button.disabled = true
	


var draw_render_view: = false

func _on_draw_rect(rect: Rect2) -> void:
	render_view_control.draw_render_view = draw_render_view
	render_view_control._rect = rect
	render_view_control.queue_redraw()


func _on_workflow_option_button_item_selected(index: int) -> void:
	match index:
		0:  # Z-Turbo
			current_workflow = Workflow.Z_TURBO
			steps_spin_box.value = WORKFLOW_DEFAULT_STEPS[Workflow.Z_TURBO]
			edit_img_button.disabled = true
			send_mask_edit_button.disabled = true
		1:  # Qwen
			current_workflow = Workflow.QWEN
			steps_spin_box.value = WORKFLOW_DEFAULT_STEPS[Workflow.QWEN]
			edit_img_button.disabled = false
			send_mask_edit_button.disabled = false


func toggle_enable_ai_fields(enable: bool = true) -> void:
	send_action_button.disabled = not enable
	send_prompt_button.disabled = not enable
	prompt_button.disabled = not enable
	negative_prompt_mic_button.disabled = not enable
	positive_prompt_mic_button.disabled = not enable
	prompt_text_edit.editable = enable
	negative_text_edit.editable = enable
	advanced_settings_check_button.disabled = not enable
	if workflow_option_button.selected == 0:
		edit_img_button.disabled = true
		send_mask_edit_button.disabled = true
	else:
		edit_img_button.disabled = not enable
		send_mask_edit_button.disabled = not enable
	workflow_option_button.disabled = not enable

func disable_ai_features(error: int) -> void:
	if error != 0:
		connection_label.text = "Not Connected to backend.\nConnect to backend to \naccess AI Features."
		connection_label.show()
	toggle_enable_ai_fields(false)

func enable_ai_features() -> void:
	if connection_label.visible:
		connection_label.hide()
	toggle_enable_ai_fields()


func _on_lock_media_gen_ui(lock: bool = true) -> void:
	if lock:
		disable_ai_features(0)
	else:
		enable_ai_features()


func _on_center_view_button_pressed() -> void:
	center_view()


## Position the drawing area at the top-left of the viewport
func _position_view_top_left() -> void:
	var viewport_size = input_area_camera.get_viewport().size
	# Camera2D centers on its position, so offset to put content at top-left
	# Account for zoom: at zoom 0.5, we see 2x the area, so offset needs adjustment
	var zoom_factor = input_area_camera.zoom.x
	# Offset camera so origin (0,0) appears at top-left with some padding
	var padding = Vector2(20, 20)
	input_area_camera.offset = Vector2.ZERO
	input_area_camera.position = (Vector2(viewport_size) / 2.0) / zoom_factor - padding


func _on_zoom_out_button_pressed() -> void:
	_zoom(layers_container.position + (layers_container.size /2.0) , ZOOM_DECREMENT - 0.15)


func _on_zoom_in_button_pressed() -> void:
	_zoom(layers_container.position + (layers_container.size /2.0), ZOOM_INCREMENT + 0.15)


func center_view(layer: LayerV2 = null) -> void:
	if layer == null and active_layer != null:
		layer = active_layer
	else:
		layer = layers_container.get_child(0)
	if input_area_camera != null and layer != null:
		input_area_camera.position = layer.get_global_rect().get_center()
		input_area_camera.offset = Vector2.ZERO


func deselect_layers() -> void:
	for c: LayerCard in layer_cards_container.get_children():
		c.selected = false
	for c: LayerCard in mask_layer_cards_container.get_children():
		c.selected = false


#region Selection UI

## Popup menu item IDs for selection operations
enum SelectionMenuId {
	SELECT_ALL = 0,
	DESELECT = 1,
	INVERT = 2,
	SEPARATOR = 3,
	DELETE_CONTENTS = 4,
	FILL_WITH_COLOR = 5,
}

## Setup the popup menu for the selection indicator button
func _setup_selection_popup_menu() -> void:
	var popup := selection_indicator_button.get_popup()
	popup.clear()
	popup.add_item("Select All          Ctrl+A", SelectionMenuId.SELECT_ALL)
	popup.add_item("Deselect            Ctrl+D", SelectionMenuId.DESELECT)
	popup.add_item("Invert Selection    Ctrl+Shift+I", SelectionMenuId.INVERT)
	popup.add_separator()
	popup.add_item("Delete Contents     Del", SelectionMenuId.DELETE_CONTENTS)
	popup.add_item("Fill with Color     Alt+Backspace", SelectionMenuId.FILL_WITH_COLOR)
	popup.id_pressed.connect(_on_selection_popup_id_pressed)

## Called when selection changes to update the indicator button visibility
func _on_selection_changed() -> void:
	selection_indicator_button.visible = has_selection()

## Called when the selection indicator button's popup is about to show
func _on_selection_indicator_about_to_popup() -> void:
	# Refresh popup menu state if needed
	pass

## Handle selection popup menu item selection
func _on_selection_popup_id_pressed(id: int) -> void:
	match id:
		SelectionMenuId.SELECT_ALL:
			select_all()
		SelectionMenuId.DESELECT:
			clear_selection()
		SelectionMenuId.INVERT:
			invert_selection()
		SelectionMenuId.DELETE_CONTENTS:
			delete_selection()
		SelectionMenuId.FILL_WITH_COLOR:
			# Use the color from the brush color picker
			fill_selection(color_picker_button.color)

## Button handler for Select All in SelectionOptions
func _on_select_all_button_pressed() -> void:
	select_all()

## Button handler for Deselect in SelectionOptions
func _on_deselect_button_pressed() -> void:
	clear_selection()

## Button handler for Invert in SelectionOptions
func _on_invert_button_pressed() -> void:
	invert_selection()

## Button handler for Delete Selection Contents in SelectionOptions
func _on_delete_selection_button_pressed() -> void:
	delete_selection()

## Color picker handler for Fill Selection in SelectionOptions
func _on_fill_selection_color_changed(color: Color) -> void:
	fill_selection(color)

#endregion

## Export region and exit the render view tool
## Called automatically when user draws a valid selection rectangle
func export_region_and_exit() -> void:
	# Ensure the render view rectangle exists and has a valid size
	var export_rect = render_view_control._rect
	if not export_rect.size.x > 0 or not export_rect.size.y > 0:
		display_message("Error", "Selection rectangle is empty or invalid.")
		_exit_render_view_tool()
		return

	# Clear the selection rectangle immediately for better UX
	_exit_render_view_tool()

	# Show file dialog and wait for result
	var selected_path = await _show_save_dialog()
	if selected_path.is_empty():
		return

	# Ensure .png extension
	if not selected_path.ends_with(".png"):
		selected_path += ".png"

	# Capture the image from the saved rect
	var image: Image = await compose_region_image(export_rect)
	if image.is_empty():
		display_message("Error", "Failed to capture region image.")
		return

	# Convert to RGBA8 if needed
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)

	var error = image.save_png(selected_path)
	if error != OK:
		push_error("Failed to save image: " + str(error))
		display_message("Error", "Failed to save image to: " + selected_path)


## Show save dialog and return selected path, or empty string if cancelled
func _show_save_dialog() -> String:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.add_filter("*.png", "PNG Image")
	fd.title = "Export Region as PNG"
	add_child(fd)

	var result: Array = []  # Use array to capture in closure (reference type)
	fd.file_selected.connect(func(path: String): result.append(path))
	fd.canceled.connect(func(): pass)

	fd.popup_centered(Vector2i(800, 600))

	# Wait for either signal to fire
	while result.is_empty() and fd.visible:
		await get_tree().process_frame

	fd.queue_free()
	return result[0] if result.size() > 0 else ""


## Clean up and exit the render view tool, returning to default tool
func _exit_render_view_tool() -> void:
	render_view_control._rect = Rect2()
	render_view_control.draw_render_view = false
	render_view_control.queue_redraw()
	active_tool = null
	_select_tool_by_id(13)  # Select tool


func compose_region_image(region: Rect2, show_dialog: = true) -> Image:
	if region.size.x <= 0 or region.size.y <= 0:
		push_error("Cannot compose image for an empty or invalid region: %s" % region)
		return Image.new()

	if _current_compose_thread != null and _current_compose_thread.is_alive():
		print("Compose already running, ignoring request for region")
		return Image.new()

	if _current_compose_thread != null:
		if _current_compose_thread.is_alive():
			_current_compose_thread.wait_to_finish()
		_current_compose_thread = null

	if show_dialog:
		progress_window.popup_centered()
		progress_window_label.text = "Composing region image..."
		progress_window_bar.value = 0

	var layer_data: Array[Dictionary] = []
	var layer_nodes = layers_container.get_children().filter(func(n): return n is LayerV2)

	for layer in layer_nodes:
		if layer is LayerV2 and layer.visible and layer.image and not layer.image.is_empty():
			layer_data.append({
				"image": layer.image,
				"position": layer.position,
				"rotation": layer.rotation,
				"pivot_offset": layer.pivot_offset,
				"size": layer.size
			})

	_current_compose_thread = Thread.new()
	_current_compose_thread.start(_compose_image_region_thread_worker.bind(layer_data, region))

	var img = await compose_finished # This signal currently emits _compose_result_image
	saved = true
	return img

func _compose_image_region_thread_worker(layer_data: Array[Dictionary], region: Rect2):
	print("Starting compose region worker thread for region: %s" % region)
	var result_image = _compose_final_image_worker_for_region(layer_data, region)
	call_deferred("_on_compose_finished", result_image) # Use existing signal


func _compose_final_image_worker_for_region(layer_data: Array[Dictionary], region: Rect2) -> Image:
	if layer_data.is_empty() or region.size.x <= 0 or region.size.y <= 0:
		return Image.new()

	var width = int(region.size.x)
	var height = int(region.size.y)
	var output_image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	output_image.fill(Color(0, 0, 0, 0)) # Transparent background

	# Estimate total pixels for progress reporting more accurately
	# Only layers that potentially intersect the region will contribute significantly
	var estimated_pixels_per_layer = width * height # Max possible contribution
	var total_pixels = estimated_pixels_per_layer * layer_data.size()
	var processed_pixels = 0
	# Update progress every 1% or 1000 pixels, whichever is larger
	var progress_update_interval: int = max(1000, int(total_pixels / 100.0))
	if progress_update_interval == 0: progress_update_interval = 1 # Avoid division by zero

	# Blend all layers onto the output image
	for layer_idx in range(layer_data.size()):
		var data = layer_data[layer_idx]
		var layer_image = data.image
		
		if not layer_image or layer_image.is_empty():
			processed_pixels += width * height # Assume full region skipped for progress
			continue
		
		var rotation_rad = data.rotation
		var pivot = data.pivot_offset
		var layer_pos = data.position
		
		# Process each pixel in the output image space
		for out_y in range(height):
			for out_x in range(width):
				# Get global position corresponding to output_image pixel
				var global_pos = Vector2(out_x, out_y) + region.position
				
				# Convert to layer local space (accounting for rotation)
				var local_pos = _global_to_layer_space_static(global_pos, layer_pos, rotation_rad, pivot)
				
				# Check if the point is within the layer's image
				var img_x = int(local_pos.x)
				var img_y = int(local_pos.y)
				
				if img_x >= 0 and img_x < layer_image.get_width() and img_y >= 0 and img_y < layer_image.get_height():
					var src_color = layer_image.get_pixel(img_x, img_y)
					
					if src_color.a > 0.01: # Skip fully transparent pixels
						var dst_color = output_image.get_pixel(out_x, out_y)
						var blended = _blend_colors(dst_color, src_color)
						output_image.set_pixel(out_x, out_y, blended)
				
				processed_pixels += 1
				
				if processed_pixels % progress_update_interval == 0:
					var progress = float(processed_pixels) / float(total_pixels)
					call_deferred("_emit_progress", progress)
	
	return output_image


## Activate the export region tool (called from Editor.gd ExportAreaButton)
func activate_export_region_tool() -> void:
	active_tool = render_view_tool
	render_view_control.draw_render_view = true
	render_view_control._rect = Rect2()
	render_view_control.queue_redraw()

#region Gen AI Prompt History
func _on_prompt_history_button_pressed() -> void:
	var hist_window: = Window.new()
	var root_vbox_container: = VBoxContainer.new()
	var panel: = PanelContainer.new()
	var scroll_container: = ScrollContainer.new()
	var label: = Label.new()
	
	add_child(hist_window)
	
	hist_window.size = Vector2i(400, 300)
	hist_window.title = "Prompt History"
	
	hist_window.add_child(root_vbox_container)
	root_vbox_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_vbox_container.set_offsets_preset(Control.PRESET_FULL_RECT)
	root_vbox_container.add_theme_constant_override("separation", 0)
	
	var content_margin: = MarginContainer.new()
	root_vbox_container.add_child(content_margin)
	content_margin.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	content_margin.set_v_size_flags(Control.SIZE_EXPAND_FILL)
	
	content_margin.add_child(panel)
	panel.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	panel.set_v_size_flags(Control.SIZE_EXPAND_FILL)
	
	panel.add_child(scroll_container)
	scroll_container.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	scroll_container.set_v_size_flags(Control.SIZE_EXPAND_FILL)
	
	scroll_container.add_theme_constant_override("h_scroll_separation", 0)
	scroll_container.add_theme_constant_override("v_scroll_separation", 0)
	
	scroll_container.add_child(label)
	label.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	label.set_v_size_flags(Control.SIZE_SHRINK_BEGIN)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	label.text = get_gen_ai_history()

	label.add_theme_color_override("font_color", Color.WHITE)

	hist_window.close_requested.connect(func() -> void:
		hist_window.queue_free()
	)
	
	hist_window.popup()


func get_gen_ai_history() -> String:
	var file_path = SingletonObject.GEN_AI_HIST_FILE_PATH
	var file = FileAccess.open(file_path, FileAccess.READ)

	if file:
		var content = file.get_as_text()
		file.close()
		if content.is_empty():
			return "No History Found"
		return content
	else:
		return "No History Found"


func _csv_escape(text: String) -> String:
	var needs_quoting = text.contains(",") or text.contains("\"") or text.contains("\n")
	var escaped_text = text.replace("\"", "\"\"")
	
	if needs_quoting:
		return "\"" + escaped_text + "\""
	else:
		return escaped_text


func save_prompt_to_history(positive_prompt: String, negative_prompt: String) -> void:
	var file_path = SingletonObject.GEN_AI_HIST_FILE_PATH
	
	var current_time: = Time.get_datetime_string_from_system(true, true)
	
	var escaped_time: = _csv_escape(current_time)
	var escaped_positive_prompt: = _csv_escape(positive_prompt.strip_edges())
	var escaped_negative_prompt: = _csv_escape(negative_prompt.strip_edges())
	
	var history_entry: = "%s,%s,%s\n" % [escaped_time, escaped_positive_prompt, escaped_negative_prompt]
	
	var file: = FileAccess.open(file_path, FileAccess.READ_WRITE)
	if file:
		if file.get_length() == 0:
			file.store_string(_csv_escape("Timestamp") + "," + _csv_escape("Positive Prompt") + "," + _csv_escape("Negative Prompt") + "\n")
		
		file.seek_end()
		file.store_string(history_entry)
		file.close()
		print("Prompt saved to history (CSV): %s" % history_entry.strip_edges())
	else:
		push_error("Failed to open prompt history file for writing: %s" % file_path)

#endregion Gen AI Prompt History

var sprite_anim_selected: = ""
var spritesheet_frames: = ""
var spritesheet_anim_is_active: = false
func _on_sprite_sheet_check_button_toggled(toggled_on: bool) -> void:
	spritesheet_settings_container.visible = toggled_on
	spritesheet_anim_is_active = toggled_on


func _on_animation_option_button_item_selected(index: int) -> void:
	sprite_anim_selected =  animation_option_button.get_item_text(index)
	spritesheet_anim_is_active = spritesheet_settings_container.visible


func _on_animation_frames_option_button_item_selected(index: int) -> void:
	spritesheet_frames = animation_frames_option_button.get_item_text(index)
	spritesheet_anim_is_active = spritesheet_settings_container.visible


@onready var main_h_split_container: HSplitContainer = %MainHSplitContainer
@onready var v: VBoxContainer = %v

func _on_main_h_split_container_dragged(_offset: int) -> void:
	# Dock panel dragging is disabled - always using floating windows mode
	pass

var dragging_split: = false
func _on_main_h_split_container_drag_ended() -> void:
	dragging_split = false


func _on_main_h_split_container_drag_started() -> void:
	dragging_split = true
