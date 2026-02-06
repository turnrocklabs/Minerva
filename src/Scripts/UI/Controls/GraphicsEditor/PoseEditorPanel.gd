class_name PoseEditorPanel
extends PanelContainer

## 3D Pose Editor Panel
## Provides a 3D viewport for manipulating OpenPose skeleton
## with camera orbit, bone rotation, and 2D render output.

## Preload PoseSkeleton3D to access constants (avoid circular reference)
const PoseSkeletonScript = preload("res://Scripts/UI/Controls/GraphicsEditor/PoseSkeleton3D.gd")

signal pose_rendered(image: Image)
signal closed()

@onready var subviewport: SubViewport = %SubViewport
@onready var camera: Camera3D = %Camera3D
@onready var pose_skeleton = %PoseSkeleton3D  # Avoid type annotation for circular ref
@onready var status_label: Label = %StatusLabel
@onready var viewport_container: SubViewportContainer = %SubViewportContainer

## Slider references (12 sliders for pose control)
@onready var preset_dropdown: OptionButton = %PresetDropdown
@onready var torso_lean_slider: HSlider = %TorsoLeanSlider
@onready var torso_twist_slider: HSlider = %TorsoTwistSlider
@onready var left_arm_elev_slider: HSlider = %LeftArmElevSlider
@onready var left_arm_swing_slider: HSlider = %LeftArmSwingSlider
@onready var left_elbow_slider: HSlider = %LeftElbowSlider
@onready var right_arm_elev_slider: HSlider = %RightArmElevSlider
@onready var right_arm_swing_slider: HSlider = %RightArmSwingSlider
@onready var right_elbow_slider: HSlider = %RightElbowSlider
@onready var left_leg_swing_slider: HSlider = %LeftLegSwingSlider
@onready var left_knee_slider: HSlider = %LeftKneeSlider
@onready var left_ankle_slider: HSlider = %LeftAnkleSlider
@onready var right_leg_swing_slider: HSlider = %RightLegSwingSlider
@onready var right_knee_slider: HSlider = %RightKneeSlider
@onready var right_ankle_slider: HSlider = %RightAnkleSlider

## Flag to prevent recursive slider updates
var _updating_sliders: bool = false

## Camera orbit state
var is_orbiting: bool = false
var is_panning: bool = false
var orbit_start_pos: Vector2 = Vector2.ZERO
var camera_distance: float = 4.0
var camera_rotation: Vector2 = Vector2(-0.3, 0.5)  # pitch, yaw
var camera_target: Vector3 = Vector3(0, 1.0, 0)  # Look at skeleton center (will be updated)

## Render output size
var render_size: Vector2i = Vector2i(512, 512)

var pose_texture: Texture:
	get:
		var _texture: = subviewport.get_texture()
		if _texture == null:
			return null
		_texture.get_image().resize(512, 512)
		return _texture


func _exit_tree() -> void:
	subviewport = null
	camera = null


func _ready() -> void:
	# Configure main viewport
	if subviewport:
		subviewport.transparent_bg = false

	_setup_presets()
	_update_camera_target()
	_update_camera_orbit()
	_update_status("Adjust sliders or select a preset")


## Setup preset dropdown with available poses
func _setup_presets() -> void:
	if not preset_dropdown or not pose_skeleton:
		return

	preset_dropdown.clear()

	# Add "Custom" as first option (when user manually adjusts sliders)
	preset_dropdown.add_item("Custom")

	# Add all presets from PoseSkeleton3D
	for preset_name in PoseSkeletonScript.POSE_PRESETS:
		preset_dropdown.add_item(preset_name)

	# Start with T-Pose selected (index 1, after "Custom")
	preset_dropdown.select(1)
	_apply_preset_by_index(1)


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return

	# Only process input if mouse is over the viewport container
	if not viewport_container:
		return

	var local_pos = viewport_container.get_local_mouse_position()
	var viewport_rect = Rect2(Vector2.ZERO, viewport_container.size)

	if not viewport_rect.has_point(local_pos):
		return

	if event is InputEventMouseButton:
		_handle_mouse_button(event, local_pos)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event, local_pos)


func _handle_mouse_button(event: InputEventMouseButton, local_pos: Vector2) -> void:
	match event.button_index:
		MOUSE_BUTTON_RIGHT:
			is_orbiting = event.pressed
			orbit_start_pos = local_pos

		MOUSE_BUTTON_MIDDLE:
			is_panning = event.pressed

		MOUSE_BUTTON_WHEEL_UP:
			camera_distance = max(1.5, camera_distance - 0.3)
			_update_camera_orbit()

		MOUSE_BUTTON_WHEEL_DOWN:
			camera_distance = min(10.0, camera_distance + 0.3)
			_update_camera_orbit()


func _handle_mouse_motion(event: InputEventMouseMotion, _local_pos: Vector2) -> void:
	if is_orbiting:
		# Orbit around the skeleton center
		var delta = event.relative * 0.01
		camera_rotation.x = clamp(camera_rotation.x - delta.y, -PI/2 + 0.1, PI/2 - 0.1)
		camera_rotation.y -= delta.x
		_update_camera_orbit()
	elif is_panning:
		# Pan camera target in the camera's local XY plane
		var pan_speed = 0.005 * camera_distance
		var right = camera.global_transform.basis.x
		var up = camera.global_transform.basis.y
		camera_target -= right * event.relative.x * pan_speed
		camera_target += up * event.relative.y * pan_speed
		_update_camera_orbit()


## Update camera target to be at the skeleton's center
func _update_camera_target() -> void:
	if not pose_skeleton:
		return
	
	# Get the skeleton's center position (Hips bone is at the center)
	var hips_pos = pose_skeleton.get_bone_global_position("Hips")
	if hips_pos != Vector3.ZERO:
		camera_target = hips_pos
	else:
		# Fallback to skeleton's global position + offset
		camera_target = pose_skeleton.global_transform.origin + Vector3(0, 1.0, 0)


func _update_camera_orbit() -> void:
	if not camera:
		return

	# Calculate camera position on a sphere around the target
	# Using spherical coordinates: pitch (x) and yaw (y)
	var offset = Vector3(
		cos(camera_rotation.x) * sin(camera_rotation.y),
		sin(camera_rotation.x),
		cos(camera_rotation.x) * cos(camera_rotation.y)
	) * camera_distance

	# Set camera position relative to target
	camera.position = camera_target + offset
	
	# Always look at the target to maintain orbit
	camera.look_at(camera_target, Vector3.UP)


func _update_status(text: String) -> void:
	if status_label:
		status_label.text = text


## ============================================================================
## SLIDER HANDLERS
## ============================================================================

## Called when any slider value changes
func _on_slider_changed(_value: float) -> void:
	if _updating_sliders:
		return

	# Collect all slider values into a pose vector
	var pose_vector = _get_slider_values()

	# Apply to skeleton
	if pose_skeleton:
		pose_skeleton.apply_pose_vector(pose_vector)

	# Switch dropdown to "Custom" since user manually adjusted
	if preset_dropdown and preset_dropdown.selected != 0:
		preset_dropdown.select(0)

	_update_status("Pose updated")


## Called when a preset is selected from dropdown
func _on_preset_selected(index: int) -> void:
	_apply_preset_by_index(index)


## Apply a preset by dropdown index
func _apply_preset_by_index(index: int) -> void:
	if index == 0:
		# "Custom" - do nothing, user is manually adjusting
		return

	# Get preset name (offset by 1 for "Custom" entry)
	var preset_names = PoseSkeletonScript.POSE_PRESETS.keys()
	var preset_index = index - 1

	if preset_index < 0 or preset_index >= preset_names.size():
		return

	var preset_name = preset_names[preset_index]
	var preset_values = PoseSkeletonScript.POSE_PRESETS[preset_name]

	# Apply to skeleton
	if pose_skeleton:
		pose_skeleton.apply_pose_vector(preset_values)

	# Update sliders to match preset
	_set_slider_values(preset_values)

	_update_status("Preset: " + preset_name)


## Get current slider values as a 14-element array
func _get_slider_values() -> Array:
	return [
		torso_lean_slider.value if torso_lean_slider else 0.0,
		torso_twist_slider.value if torso_twist_slider else 0.0,
		left_arm_elev_slider.value if left_arm_elev_slider else 0.0,
		left_arm_swing_slider.value if left_arm_swing_slider else 0.0,
		left_elbow_slider.value if left_elbow_slider else 0.0,
		right_arm_elev_slider.value if right_arm_elev_slider else 0.0,
		right_arm_swing_slider.value if right_arm_swing_slider else 0.0,
		right_elbow_slider.value if right_elbow_slider else 0.0,
		left_leg_swing_slider.value if left_leg_swing_slider else 0.0,
		left_knee_slider.value if left_knee_slider else 0.0,
		left_ankle_slider.value if left_ankle_slider else 0.0,
		right_leg_swing_slider.value if right_leg_swing_slider else 0.0,
		right_knee_slider.value if right_knee_slider else 0.0,
		right_ankle_slider.value if right_ankle_slider else 0.0,
	]


## Set slider values from a 14-element array
func _set_slider_values(values: Array) -> void:
	if values.size() < 14:
		return

	_updating_sliders = true

	if torso_lean_slider: torso_lean_slider.value = values[0]
	if torso_twist_slider: torso_twist_slider.value = values[1]
	if left_arm_elev_slider: left_arm_elev_slider.value = values[2]
	if left_arm_swing_slider: left_arm_swing_slider.value = values[3]
	if left_elbow_slider: left_elbow_slider.value = values[4]
	if right_arm_elev_slider: right_arm_elev_slider.value = values[5]
	if right_arm_swing_slider: right_arm_swing_slider.value = values[6]
	if right_elbow_slider: right_elbow_slider.value = values[7]
	if left_leg_swing_slider: left_leg_swing_slider.value = values[8]
	if left_knee_slider: left_knee_slider.value = values[9]
	if left_ankle_slider: left_ankle_slider.value = values[10]
	if right_leg_swing_slider: right_leg_swing_slider.value = values[11]
	if right_knee_slider: right_knee_slider.value = values[12]
	if right_ankle_slider: right_ankle_slider.value = values[13]

	_updating_sliders = false


## ============================================================================
## BUTTON HANDLERS
## ============================================================================

## Reset skeleton to T-pose
func _on_reset_button_pressed() -> void:
	if pose_skeleton:
		pose_skeleton.reset_to_tpose()

	# Reset sliders to zero (T-pose) - 14 values
	_set_slider_values([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])

	# Select T-Pose in dropdown
	if preset_dropdown:
		# Find T-Pose index
		for i in range(preset_dropdown.item_count):
			if preset_dropdown.get_item_text(i) == "T-Pose":
				preset_dropdown.select(i)
				break

	# Reset camera to initial position
	camera_distance = 4.0
	camera_rotation = Vector2(-0.3, 0.5)  # pitch, yaw
	_update_camera_target()  # Reset target to skeleton center
	_update_camera_orbit()

	_update_status("Reset to T-pose")


## Mirror the pose
func _on_mirror_button_pressed() -> void:
	if not pose_skeleton:
		return

	# Get current values and swap left/right
	# Structure: [torso_lean, torso_twist,
	#             left_arm_elev, left_arm_swing, left_elbow,
	#             right_arm_elev, right_arm_swing, right_elbow,
	#             left_leg_swing, left_knee, left_ankle,
	#             right_leg_swing, right_knee, right_ankle]
	var values = _get_slider_values()

	# Swap left/right arm values (indices 2-4 with 5-7)
	var temp_arm = [values[2], values[3], values[4]]
	values[2] = values[5]
	values[3] = values[6]
	values[4] = values[7]
	values[5] = temp_arm[0]
	values[6] = temp_arm[1]
	values[7] = temp_arm[2]

	# Swap left/right leg values (indices 8-10 with 11-13)
	var temp_leg = [values[8], values[9], values[10]]
	values[8] = values[11]
	values[9] = values[12]
	values[10] = values[13]
	values[11] = temp_leg[0]
	values[12] = temp_leg[1]
	values[13] = temp_leg[2]

	# Apply mirrored values
	_set_slider_values(values)
	pose_skeleton.apply_pose_vector(values)

	# Switch to Custom since we modified
	if preset_dropdown:
		preset_dropdown.select(0)

	_update_status("Pose mirrored")


## Render skeleton to 2D OpenPose image
func _on_render_button_pressed() -> void:
	_update_status("Rendering to 2D...")
	var image = render_to_2d_image(render_size)
	pose_rendered.emit(image)
	_update_status("Rendered to layer")


## Close the panel
func _on_close_button_pressed() -> void:
	hide()
	closed.emit()


## Render the skeleton to a 2D OpenPose-style image
func render_to_2d_image(img_size: Vector2i) -> Image:
	if not pose_skeleton:
		return _create_empty_image(img_size)

	# Create OpenPose-style output directly by projecting 3D positions to 2D
	return _create_openpose_image(img_size)


## Create OpenPose-style 2D image by projecting 3D positions
func _create_openpose_image(img_size: Vector2i) -> Image:
	var output = Image.create(img_size.x, img_size.y, false, Image.FORMAT_RGBA8)
	output.fill(Color.BLACK)

	if not pose_skeleton:
		return output

	# Orthographic projection parameters (front view)
	var ortho_size = 2.5  # Half-height of view in world units
	var center = Vector3(0, 1.0, 0)  # Look at center of skeleton

	# Draw bones first (behind joints)
	for bone in PoseSkeletonScript.BONES:
		var from_id: int = bone[0]
		var to_id: int = bone[1]

		var from_name = PoseSkeletonScript.JOINT_MAP.get(from_id, "")
		var to_name = PoseSkeletonScript.JOINT_MAP.get(to_id, "")

		if from_name.is_empty() or to_name.is_empty():
			continue

		var from_3d = pose_skeleton.get_bone_global_position(from_name)
		var to_3d = pose_skeleton.get_bone_global_position(to_name)

		var from_2d = _project_to_2d(from_3d, center, ortho_size, size)
		var to_2d = _project_to_2d(to_3d, center, ortho_size, size)

		var color = PoseSkeletonScript.JOINT_COLORS.get(from_id, Color.WHITE)
		_draw_line_on_image(output, from_2d, to_2d, color, 4)

	# Draw joints on top
	for joint_id in PoseSkeletonScript.JOINT_MAP:
		var jbone_name = PoseSkeletonScript.JOINT_MAP[joint_id]
		var pos_3d = pose_skeleton.get_bone_global_position(jbone_name)
		var pos_2d = _project_to_2d(pos_3d, center, ortho_size, size)

		var color = PoseSkeletonScript.JOINT_COLORS.get(joint_id, Color.WHITE)
		_draw_circle_on_image(output, pos_2d, 6, color)

	return output


## Project a 3D point to 2D using orthographic projection (front view)
func _project_to_2d(pos_3d: Vector3, center: Vector3, ortho_size: float, img_size: Vector2i) -> Vector2:
	# Front view: X maps to screen X, Y maps to screen Y (inverted)
	var relative = pos_3d - center

	# Normalize to [-1, 1] range based on ortho_size
	var nx = relative.x / ortho_size
	var ny = -relative.y / ortho_size  # Invert Y for screen coordinates

	# Map to image coordinates
	var x = (nx * 0.5 + 0.5) * img_size.x
	var y = (ny * 0.5 + 0.5) * img_size.y

	return Vector2(x, y)


func _create_empty_image(img_size: Vector2i) -> Image:
	var img = Image.create(img_size.x, img_size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color.BLACK)
	return img


## Draw a filled circle on an image
func _draw_circle_on_image(img: Image, center: Vector2, radius: int, color: Color) -> void:
	var cx = int(center.x)
	var cy = int(center.y)

	for y in range(cy - radius, cy + radius + 1):
		for x in range(cx - radius, cx + radius + 1):
			if x < 0 or x >= img.get_width() or y < 0 or y >= img.get_height():
				continue

			var dist = Vector2(x - cx, y - cy).length()
			if dist <= radius:
				img.set_pixel(x, y, color)


## Draw a line on an image using Bresenham's algorithm with thickness
func _draw_line_on_image(img: Image, from: Vector2, to: Vector2, color: Color, thickness: int = 1) -> void:
	var x0 = int(from.x)
	var y0 = int(from.y)
	var x1 = int(to.x)
	var y1 = int(to.y)

	var dx = abs(x1 - x0)
	var dy = abs(y1 - y0)
	var sx = 1 if x0 < x1 else -1
	var sy = 1 if y0 < y1 else -1
	var err = dx - dy

	@warning_ignore("integer_division")
	var half_thick: int = thickness / 2

	while true:
		# Draw thick point
		for ty in range(-half_thick, half_thick + 1):
			for tx in range(-half_thick, half_thick + 1):
				var px = x0 + tx
				var py = y0 + ty
				if px >= 0 and px < img.get_width() and py >= 0 and py < img.get_height():
					img.set_pixel(px, py, color)

		if x0 == x1 and y0 == y1:
			break

		var e2 = 2 * err
		if e2 > -dy:
			err -= dy
			x0 += sx
		if e2 < dx:
			err += dx
			y0 += sy


## Get current pose data for serialization
func get_pose_data() -> Dictionary:
	if pose_skeleton:
		return pose_skeleton.get_pose_data()
	return {}


## Set pose data from serialized format
func set_pose_data(data: Dictionary) -> void:
	if pose_skeleton:
		pose_skeleton.set_pose_data(data)


func _on_visibility_changed() -> void:
	#pose_skeleton.set_process(visible)
	if get_parent():
		pose_skeleton.set_process(get_parent().visible)
