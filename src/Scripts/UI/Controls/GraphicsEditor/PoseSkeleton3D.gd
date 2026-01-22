class_name PoseSkeleton3D
extends Node3D

## 3D skeleton representation for OpenPose editing.
## Uses Skeleton3D with proper bone hierarchy for natural pose manipulation.

@onready var skeleton: Skeleton3D = $Skeleton3D

## OpenPose joint ID to bone name mapping (COCO 18-joint format)
const JOINT_MAP = {
	0: "Nose",
	1: "Neck",
	2: "RightShoulder",
	3: "RightElbow",
	4: "RightWrist",
	5: "LeftShoulder",
	6: "LeftElbow",
	7: "LeftWrist",
	8: "RightHip",
	9: "RightKnee",
	10: "RightAnkle",
	11: "LeftHip",
	12: "LeftKnee",
	13: "LeftAnkle",
	14: "RightEye",
	15: "LeftEye",
	16: "RightEar",
	17: "LeftEar"
}

## OpenPose joint colors (matches standard OpenPose visualization)
const JOINT_COLORS = {
	0: Color(1.0, 0.0, 0.0),      # Nose - Red
	1: Color(1.0, 0.34, 0.0),     # Neck - Orange
	2: Color(1.0, 0.67, 0.0),     # RShoulder - Yellow-Orange
	3: Color(1.0, 1.0, 0.0),      # RElbow - Yellow
	4: Color(0.67, 1.0, 0.0),     # RWrist - Yellow-Green
	5: Color(0.0, 1.0, 0.0),      # LShoulder - Green
	6: Color(0.0, 1.0, 0.34),     # LElbow - Green-Cyan
	7: Color(0.0, 1.0, 0.67),     # LWrist - Cyan-Green
	8: Color(0.0, 1.0, 1.0),      # RHip - Cyan
	9: Color(0.0, 0.67, 1.0),     # RKnee - Cyan-Blue
	10: Color(0.0, 0.34, 1.0),    # RAnkle - Blue-Cyan
	11: Color(0.0, 0.0, 1.0),     # LHip - Blue
	12: Color(0.34, 0.0, 1.0),    # LKnee - Blue-Purple
	13: Color(0.67, 0.0, 1.0),    # LAnkle - Purple
	14: Color(1.0, 0.0, 0.67),    # REye - Pink
	15: Color(1.0, 0.0, 0.34),    # LEye - Red-Pink
	16: Color(0.5, 0.0, 0.5),     # REar - Dark Purple
	17: Color(0.5, 0.5, 0.0),     # LEar - Olive
}

## Rotation limits for anatomically constrained joints (in radians)
## These prevent impossible poses like elbows bending backwards
const JOINT_LIMITS = {
	"RightElbow": {"axis": "x", "min": -2.6, "max": 0.1},   # Elbow bends ~0-150 degrees
	"LeftElbow": {"axis": "x", "min": -2.6, "max": 0.1},
	"RightKnee": {"axis": "x", "min": -0.1, "max": 2.4},    # Knee bends ~0-140 degrees
	"LeftKnee": {"axis": "x", "min": -0.1, "max": 2.4},
}

## Bone connections for drawing (pairs of joint IDs)
const BONES = [
	[0, 1],   # Nose -> Neck
	[1, 2],   # Neck -> RShoulder
	[2, 3],   # RShoulder -> RElbow
	[3, 4],   # RElbow -> RWrist
	[1, 5],   # Neck -> LShoulder
	[5, 6],   # LShoulder -> LElbow
	[6, 7],   # LElbow -> LWrist
	[1, 8],   # Neck -> RHip (through spine)
	[8, 9],   # RHip -> RKnee
	[9, 10],  # RKnee -> RAnkle
	[1, 11],  # Neck -> LHip (through spine)
	[11, 12], # LHip -> LKnee
	[12, 13], # LKnee -> LAnkle
	[0, 14],  # Nose -> REye
	[14, 16], # REye -> REar
	[0, 15],  # Nose -> LEye
	[15, 17], # LEye -> LEar
]

## Joint visual meshes for selection/display
var joint_visuals: Dictionary = {}

## Bone line visuals (ImmediateMesh for lines between joints)
var bone_lines_mesh: MeshInstance3D = null

## Currently selected bone index (-1 = none)
var selected_bone: int = -1


func _ready() -> void:
	_setup_skeleton()
	_create_bone_visuals()
	_create_bone_lines()
	skeleton.rotate_y(180.0)


func _setup_skeleton() -> void:
	if not skeleton:
		skeleton = Skeleton3D.new()
		skeleton.name = "Skeleton3D"
		add_child(skeleton)

	# Build skeleton hierarchy
	# Root: Hips (center of body)
	_add_bone("Hips", -1, Vector3(0, 1.0, 0))

	# Spine chain
	_add_bone("Spine", skeleton.find_bone("Hips"), Vector3(0, 0.2, 0))
	_add_bone("Neck", skeleton.find_bone("Spine"), Vector3(0, 0.3, 0))
	_add_bone("Head", skeleton.find_bone("Neck"), Vector3(0, 0.15, 0))
	_add_bone("Nose", skeleton.find_bone("Head"), Vector3(0, 0.05, 0.1))

	# Face
	_add_bone("RightEye", skeleton.find_bone("Head"), Vector3(-0.03, 0.06, 0.08))
	_add_bone("LeftEye", skeleton.find_bone("Head"), Vector3(0.03, 0.06, 0.08))
	_add_bone("RightEar", skeleton.find_bone("RightEye"), Vector3(-0.06, 0, -0.04))
	_add_bone("LeftEar", skeleton.find_bone("LeftEye"), Vector3(0.06, 0, -0.04))

	# Right arm
	_add_bone("RightShoulder", skeleton.find_bone("Neck"), Vector3(-0.15, 0, 0))
	_add_bone("RightElbow", skeleton.find_bone("RightShoulder"), Vector3(-0.25, 0, 0))
	_add_bone("RightWrist", skeleton.find_bone("RightElbow"), Vector3(-0.25, 0, 0))

	# Left arm
	_add_bone("LeftShoulder", skeleton.find_bone("Neck"), Vector3(0.15, 0, 0))
	_add_bone("LeftElbow", skeleton.find_bone("LeftShoulder"), Vector3(0.25, 0, 0))
	_add_bone("LeftWrist", skeleton.find_bone("LeftElbow"), Vector3(0.25, 0, 0))

	# Right leg
	_add_bone("RightHip", skeleton.find_bone("Hips"), Vector3(-0.1, 0, 0))
	_add_bone("RightKnee", skeleton.find_bone("RightHip"), Vector3(0, -0.45, 0))
	_add_bone("RightAnkle", skeleton.find_bone("RightKnee"), Vector3(0, -0.45, 0))

	# Left leg
	_add_bone("LeftHip", skeleton.find_bone("Hips"), Vector3(0.1, 0, 0))
	_add_bone("LeftKnee", skeleton.find_bone("LeftHip"), Vector3(0, -0.45, 0))
	_add_bone("LeftAnkle", skeleton.find_bone("LeftKnee"), Vector3(0, -0.45, 0))


func _add_bone(bone_name: String, parent_idx: int, rest_position: Vector3) -> int:
	var bone_idx = skeleton.get_bone_count()
	skeleton.add_bone(bone_name)

	if parent_idx >= 0:
		skeleton.set_bone_parent(bone_idx, parent_idx)

	# Set rest transform
	var rest_transform = Transform3D()
	rest_transform.origin = rest_position
	skeleton.set_bone_rest(bone_idx, rest_transform)
	skeleton.set_bone_pose_position(bone_idx, rest_position)

	return bone_idx


func _create_bone_visuals() -> void:
	# Create visual spheres for each OpenPose joint
	for joint_id in JOINT_MAP:
		var bone_name = JOINT_MAP[joint_id]
		var bone_idx = skeleton.find_bone(bone_name)
		if bone_idx < 0:
			continue

		# Create sphere mesh for joint
		var joint_mesh = MeshInstance3D.new()
		joint_mesh.name = bone_name + "_visual"

		var sphere = SphereMesh.new()
		sphere.radius = 0.04
		sphere.height = 0.08
		joint_mesh.mesh = sphere

		# Create material with OpenPose color
		var mat = StandardMaterial3D.new()
		mat.albedo_color = JOINT_COLORS.get(joint_id, Color.WHITE)
		mat.emission_enabled = true
		mat.emission = JOINT_COLORS.get(joint_id, Color.WHITE) * 0.3
		joint_mesh.set_surface_override_material(0, mat)

		add_child(joint_mesh)
		joint_visuals[joint_id] = joint_mesh

		# Add collision for selection
		var static_body = StaticBody3D.new()
		static_body.name = bone_name + "_body"
		static_body.set_meta("joint_id", joint_id)
		static_body.set_meta("bone_name", bone_name)

		var collision = CollisionShape3D.new()
		var shape = SphereShape3D.new()
		shape.radius = 0.06
		collision.shape = shape

		static_body.add_child(collision)
		joint_mesh.add_child(static_body)


func _create_bone_lines() -> void:
	# Create a MeshInstance3D with ImmediateMesh for drawing bone lines
	bone_lines_mesh = MeshInstance3D.new()
	bone_lines_mesh.name = "BoneLines"

	# Create material for bone lines
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	bone_lines_mesh.material_override = mat

	add_child(bone_lines_mesh)


func _process(_delta: float) -> void:
	_update_visual_positions()
	_update_bone_lines()


func _update_visual_positions() -> void:
	# Update visual mesh positions to match skeleton bone positions
	for joint_id in JOINT_MAP:
		var bone_name = JOINT_MAP[joint_id]
		var bone_idx = skeleton.find_bone(bone_name)
		if bone_idx < 0:
			continue

		var visual = joint_visuals.get(joint_id)
		if visual:
			visual.global_transform.origin = get_bone_global_position(bone_name)


func _update_bone_lines() -> void:
	if not bone_lines_mesh:
		return

	# Create new ImmediateMesh each frame to update bone positions
	var im = ImmediateMesh.new()

	# Draw each bone as a thick line (using triangles for thickness)
	for bone_conn in BONES:
		var from_id: int = bone_conn[0]
		var to_id: int = bone_conn[1]

		var from_name = JOINT_MAP.get(from_id, "")
		var to_name = JOINT_MAP.get(to_id, "")

		if from_name.is_empty() or to_name.is_empty():
			continue

		var from_pos = get_bone_global_position(from_name)
		var to_pos = get_bone_global_position(to_name)

		# Convert to local space
		from_pos = bone_lines_mesh.to_local(from_pos)
		to_pos = bone_lines_mesh.to_local(to_pos)

		var color = JOINT_COLORS.get(from_id, Color.WHITE)

		# Draw cylinder-like bone using triangles
		_draw_bone_cylinder(im, from_pos, to_pos, 0.02, color)

	bone_lines_mesh.mesh = im


func _draw_bone_cylinder(im: ImmediateMesh, from_pos: Vector3, to_pos: Vector3, radius: float, color: Color) -> void:
	var direction = (to_pos - from_pos).normalized()
	var length = from_pos.distance_to(to_pos)

	if length < 0.001:
		return

	# Find perpendicular vectors for cylinder cross-section
	var up = Vector3.UP
	if abs(direction.dot(up)) > 0.9:
		up = Vector3.RIGHT

	var right = direction.cross(up).normalized() * radius
	var forward = direction.cross(right).normalized() * radius

	# Create 8-sided cylinder
	var segments = 8
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	for i in range(segments):
		var angle1 = TAU * i / segments
		var angle2 = TAU * (i + 1) / segments

		var offset1 = right * cos(angle1) + forward * sin(angle1)
		var offset2 = right * cos(angle2) + forward * sin(angle2)

		var p1 = from_pos + offset1
		var p2 = from_pos + offset2
		var p3 = to_pos + offset1
		var p4 = to_pos + offset2

		# Side quad as two triangles
		im.surface_set_color(color)
		im.surface_add_vertex(p1)
		im.surface_add_vertex(p2)
		im.surface_add_vertex(p3)

		im.surface_add_vertex(p2)
		im.surface_add_vertex(p4)
		im.surface_add_vertex(p3)

	im.surface_end()


## Get the global position of a bone by name
func get_bone_global_position(bone_name: String) -> Vector3:
	var bone_idx = skeleton.find_bone(bone_name)
	if bone_idx < 0:
		return Vector3.ZERO

	# Get global pose
	var global_pose = skeleton.get_bone_global_pose(bone_idx)
	return skeleton.global_transform * global_pose.origin


## Set the rotation of a bone by name
func set_bone_rotation(bone_name: String, bone_rotation: Quaternion) -> void:
	var bone_idx = skeleton.find_bone(bone_name)
	if bone_idx >= 0:
		skeleton.set_bone_pose_rotation(bone_idx, bone_rotation)


## Set the rotation of a bone with anatomical constraints applied
func set_bone_rotation_constrained(bone_name: String, bone_rotation: Quaternion) -> void:
	var bone_idx = skeleton.find_bone(bone_name)
	if bone_idx < 0:
		return

	var final_rotation = bone_rotation

	# Apply anatomical limits if this joint has constraints
	if bone_name in JOINT_LIMITS:
		var limits = JOINT_LIMITS[bone_name]
		var euler = final_rotation.get_euler()

		match limits.axis:
			"x": euler.x = clamp(euler.x, limits.min, limits.max)
			"y": euler.y = clamp(euler.y, limits.min, limits.max)
			"z": euler.z = clamp(euler.z, limits.min, limits.max)

		final_rotation = Quaternion.from_euler(euler)

	skeleton.set_bone_pose_rotation(bone_idx, final_rotation)


## Get the rotation of a bone by name
func get_bone_rotation(bone_name: String) -> Quaternion:
	var bone_idx = skeleton.find_bone(bone_name)
	if bone_idx < 0:
		return Quaternion.IDENTITY
	return skeleton.get_bone_pose_rotation(bone_idx)


## Get the parent bone name of a given bone
func get_parent_bone_name(bone_name: String) -> String:
	var bone_idx = skeleton.find_bone(bone_name)
	if bone_idx < 0:
		return ""

	var parent_idx = skeleton.get_bone_parent(bone_idx)
	if parent_idx < 0:
		return ""

	return skeleton.get_bone_name(parent_idx)


## Reset skeleton to T-pose
func reset_to_tpose() -> void:
	for i in range(skeleton.get_bone_count()):
		skeleton.set_bone_pose_rotation(i, Quaternion.IDENTITY)
		skeleton.set_bone_pose_position(i, skeleton.get_bone_rest(i).origin)


## Get pose data for serialization
func get_pose_data() -> Dictionary:
	var data = {}
	for i in range(skeleton.get_bone_count()):
		var bone_name = skeleton.get_bone_name(i)
		var rot = skeleton.get_bone_pose_rotation(i)
		var pos = skeleton.get_bone_pose_position(i)
		data[bone_name] = {
			"rotation": {"x": rot.x, "y": rot.y, "z": rot.z, "w": rot.w},
			"position": {"x": pos.x, "y": pos.y, "z": pos.z}
		}
	return data


## Set pose data from serialized format
func set_pose_data(data: Dictionary) -> void:
	for bone_name in data:
		var bone_idx = skeleton.find_bone(bone_name)
		if bone_idx < 0:
			continue

		var bone_data = data[bone_name]
		if bone_data.has("rotation"):
			var r = bone_data.rotation
			skeleton.set_bone_pose_rotation(bone_idx, Quaternion(r.x, r.y, r.z, r.w))
		if bone_data.has("position"):
			var p = bone_data.position
			skeleton.set_bone_pose_position(bone_idx, Vector3(p.x, p.y, p.z))


## Mirror the pose left-to-right
func mirror_pose() -> void:
	var pairs = [
		["RightShoulder", "LeftShoulder"],
		["RightElbow", "LeftElbow"],
		["RightWrist", "LeftWrist"],
		["RightHip", "LeftHip"],
		["RightKnee", "LeftKnee"],
		["RightAnkle", "LeftAnkle"],
		["RightEye", "LeftEye"],
		["RightEar", "LeftEar"],
	]

	for pair in pairs:
		var left_idx = skeleton.find_bone(pair[0])
		var right_idx = skeleton.find_bone(pair[1])
		if left_idx < 0 or right_idx < 0:
			continue

		var left_rot = skeleton.get_bone_pose_rotation(left_idx)
		var right_rot = skeleton.get_bone_pose_rotation(right_idx)

		# Mirror rotations (flip X axis)
		left_rot.x = -left_rot.x
		left_rot.w = -left_rot.w
		right_rot.x = -right_rot.x
		right_rot.w = -right_rot.w

		skeleton.set_bone_pose_rotation(left_idx, right_rot)
		skeleton.set_bone_pose_rotation(right_idx, left_rot)


## Get joint ID from bone name
func get_joint_id(bone_name: String) -> int:
	for joint_id in JOINT_MAP:
		if JOINT_MAP[joint_id] == bone_name:
			return joint_id
	return -1


## Set visual highlight for selected bone
func set_selected_joint(joint_id: int) -> void:
	selected_bone = joint_id

	# Update visual appearance
	for jid in joint_visuals:
		var visual = joint_visuals[jid] as MeshInstance3D
		if not visual:
			continue

		var mat = visual.get_surface_override_material(0) as StandardMaterial3D
		if not mat:
			continue

		if jid == joint_id:
			# Highlight selected
			mat.emission = JOINT_COLORS.get(jid, Color.WHITE)
			visual.scale = Vector3.ONE * 1.5
		else:
			# Normal
			mat.emission = JOINT_COLORS.get(jid, Color.WHITE) * 0.3
			visual.scale = Vector3.ONE


## ============================================================================
## SLIDER-DRIVEN POSE SYSTEM
## Based on IML (Imaginary Modeling Language) StandardVector approach:
## - 12 normalized slider values [-1, 1] control body pose
## - Spherical coordinates for natural arm/leg motion
## - Behavioral abstraction: sliders control semantic actions (arm up/down)
## ============================================================================

## Preset poses as 14-float arrays
## Order: [torso_lean, torso_twist,
##         left_arm_elev, left_arm_swing, left_elbow,
##         right_arm_elev, right_arm_swing, right_elbow,
##         left_leg_swing, left_knee, left_ankle,
##         right_leg_swing, right_knee, right_ankle]
const POSE_PRESETS = {
	"T-Pose": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
	"Arms Down": [0.0, 0.0, -1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
	"Arms Up": [0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
	"Walking": [0.1, 0.0, -0.3, 0.2, 0.1, -0.3, -0.2, 0.1, 0.3, 0.2, -0.3, -0.3, 0.2, 0.3],
	"Running": [0.2, 0.0, -0.5, 0.5, 0.3, -0.5, -0.5, 0.3, 0.5, 0.4, -0.4, -0.5, 0.4, 0.4],
	"Sitting": [-0.3, 0.0, -0.5, 0.0, 0.2, -0.5, 0.0, 0.2, 0.5, 0.9, 0.5, 0.5, 0.9, 0.5],
	"Waving": [0.0, 0.1, 0.8, 0.3, 0.6, -0.6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
	"Hands on Hips": [0.0, 0.0, -0.4, -0.3, 0.7, -0.4, 0.3, 0.7, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
}


## Apply a 14-value pose vector to the skeleton
## Uses spherical coordinates for natural arm/leg motion (inspired by IML)
##
## values: Array of 14 floats, each normalized to [-1, 1] or [0, 1]:
##   [0] torso_lean      - Forward/back lean [-1, 1]
##   [1] torso_twist     - Left/right twist [-1, 1]
##   [2] left_arm_elev   - Arm up/down [-1, 1]
##   [3] left_arm_swing  - Arm forward/back [-1, 1]
##   [4] left_elbow      - Elbow bend [0, 1]
##   [5] right_arm_elev  - Arm up/down [-1, 1]
##   [6] right_arm_swing - Arm forward/back [-1, 1]
##   [7] right_elbow     - Elbow bend [0, 1]
##   [8] left_leg_swing  - Leg forward/back [-1, 1]
##   [9] left_knee       - Knee bend [0, 1]
##   [10] left_ankle     - Foot up/down [-1, 1]
##   [11] right_leg_swing - Leg forward/back [-1, 1]
##   [12] right_knee      - Knee bend [0, 1]
##   [13] right_ankle     - Foot up/down [-1, 1]
func apply_pose_vector(values: Array) -> void:
	if values.size() < 14:
		push_warning("apply_pose_vector: Expected 14 values, got ", values.size())
		return

	# Reset to T-pose first for clean state
	reset_to_tpose()

	# -------------------------------------------------------------------------
	# TORSO (Spine bone)
	# -------------------------------------------------------------------------
	var torso_lean: float = values[0]   # [-1, 1] back to forward
	var torso_twist: float = values[1]  # [-1, 1] left to right

	# Increased motion: lean up to ~57 degrees, twist up to ~69 degrees
	var spine_rot = Quaternion.from_euler(Vector3(
		torso_lean * 1.0,    # X: lean forward/back (up to ~57 degrees)
		torso_twist * 1.2,   # Y: twist left/right (up to ~69 degrees)
		0.0
	))
	set_bone_rotation("Spine", spine_rot)

	# -------------------------------------------------------------------------
	# HEAD/NECK - Counter-rotate to stay upright when torso leans
	# This keeps the head facing forward relative to world space
	# -------------------------------------------------------------------------
	var neck_rot = Quaternion.from_euler(Vector3(
		-torso_lean * 0.5,   # Counter lean (partial, so head follows a bit)
		-torso_twist * 0.3,  # Counter twist (partial)
		0.0
	))
	set_bone_rotation("Neck", neck_rot)

	# -------------------------------------------------------------------------
	# LEFT ARM - Spherical coordinates for natural motion
	# -------------------------------------------------------------------------
	var l_arm_elev: float = values[2]   # [-1, 1] down to up
	var l_arm_swing: float = values[3]  # [-1, 1] back to forward
	var l_elbow_bend: float = values[4] # [0, 1] straight to bent

	# Increased motion: elevation up to 90 degrees, swing up to 90 degrees
	var l_elev_angle = l_arm_elev * PI / 2.0     # Up to 90 degrees up/down
	var l_swing_angle = l_arm_swing * PI / 2.0   # Up to 90 degrees fwd/back

	var l_shoulder_rot = Quaternion.from_euler(Vector3(
		-l_swing_angle,  # X: forward/back (negative because of bone orientation)
		0.0,
		l_elev_angle     # Z: up/down
	))
	set_bone_rotation("LeftShoulder", l_shoulder_rot)

	# Elbow bends up to ~150 degrees
	var l_elbow_rot = Quaternion.from_euler(Vector3(0.0, l_elbow_bend * 2.6, 0.0))
	set_bone_rotation("LeftElbow", l_elbow_rot)

	# -------------------------------------------------------------------------
	# RIGHT ARM - Mirror of left arm
	# -------------------------------------------------------------------------
	var r_arm_elev: float = values[5]
	var r_arm_swing: float = values[6]
	var r_elbow_bend: float = values[7]

	var r_elev_angle = r_arm_elev * PI / 2.0
	var r_swing_angle = r_arm_swing * PI / 2.0

	var r_shoulder_rot = Quaternion.from_euler(Vector3(
		-r_swing_angle,   # X: forward/back
		0.0,
		-r_elev_angle     # Z: up/down (negated for right side)
	))
	set_bone_rotation("RightShoulder", r_shoulder_rot)

	var r_elbow_rot = Quaternion.from_euler(Vector3(0.0, -r_elbow_bend * 2.6, 0.0))
	set_bone_rotation("RightElbow", r_elbow_rot)

	# -------------------------------------------------------------------------
	# LEFT LEG
	# -------------------------------------------------------------------------
	var l_leg_swing: float = values[8]   # [-1, 1] back to forward
	var l_knee_bend: float = values[9]   # [0, 1] straight to bent
	var l_ankle: float = values[10]      # [-1, 1] toe up to toe down

	# Increased motion: leg swing up to 90 degrees
	var l_leg_angle = l_leg_swing * PI / 2.0
	var l_hip_rot = Quaternion.from_euler(Vector3(l_leg_angle, 0.0, 0.0))
	set_bone_rotation("LeftHip", l_hip_rot)

	# Knee bends up to ~150 degrees
	var l_knee_rot = Quaternion.from_euler(Vector3(-l_knee_bend * 2.6, 0.0, 0.0))
	set_bone_rotation("LeftKnee", l_knee_rot)

	# Ankle rotates foot up/down (up to ~60 degrees each way)
	var l_ankle_rot = Quaternion.from_euler(Vector3(l_ankle * PI / 3.0, 0.0, 0.0))
	set_bone_rotation("LeftAnkle", l_ankle_rot)

	# -------------------------------------------------------------------------
	# RIGHT LEG
	# -------------------------------------------------------------------------
	var r_leg_swing: float = values[11]
	var r_knee_bend: float = values[12]
	var r_ankle: float = values[13]

	var r_leg_angle = r_leg_swing * PI / 2.0
	var r_hip_rot = Quaternion.from_euler(Vector3(r_leg_angle, 0.0, 0.0))
	set_bone_rotation("RightHip", r_hip_rot)

	var r_knee_rot = Quaternion.from_euler(Vector3(-r_knee_bend * 2.6, 0.0, 0.0))
	set_bone_rotation("RightKnee", r_knee_rot)

	var r_ankle_rot = Quaternion.from_euler(Vector3(r_ankle * PI / 3.0, 0.0, 0.0))
	set_bone_rotation("RightAnkle", r_ankle_rot)


## Get the current pose as a 14-value vector
func get_pose_vector() -> Array:
	# This is an approximation - extracting slider values from rotations
	# For precise round-tripping, store the last applied values
	var values: Array = []
	values.resize(14)
	values.fill(0.0)

	# Torso
	var spine_rot = get_bone_rotation("Spine").get_euler()
	values[0] = spine_rot.x / 1.0   # torso_lean
	values[1] = spine_rot.y / 1.2   # torso_twist

	# Left arm
	var l_shoulder_rot = get_bone_rotation("LeftShoulder").get_euler()
	values[2] = l_shoulder_rot.z / (PI / 2.0)   # left_arm_elev
	values[3] = -l_shoulder_rot.x / (PI / 2.0)  # left_arm_swing
	var l_elbow_rot = get_bone_rotation("LeftElbow").get_euler()
	values[4] = l_elbow_rot.y / 2.6             # left_elbow

	# Right arm
	var r_shoulder_rot = get_bone_rotation("RightShoulder").get_euler()
	values[5] = -r_shoulder_rot.z / (PI / 2.0)  # right_arm_elev
	values[6] = -r_shoulder_rot.x / (PI / 2.0)  # right_arm_swing
	var r_elbow_rot = get_bone_rotation("RightElbow").get_euler()
	values[7] = -r_elbow_rot.y / 2.6            # right_elbow

	# Left leg
	var l_hip_rot = get_bone_rotation("LeftHip").get_euler()
	values[8] = l_hip_rot.x / (PI / 2.0)        # left_leg_swing
	var l_knee_rot = get_bone_rotation("LeftKnee").get_euler()
	values[9] = -l_knee_rot.x / 2.6             # left_knee
	var l_ankle_rot = get_bone_rotation("LeftAnkle").get_euler()
	values[10] = l_ankle_rot.x / (PI / 3.0)     # left_ankle

	# Right leg
	var r_hip_rot = get_bone_rotation("RightHip").get_euler()
	values[11] = r_hip_rot.x / (PI / 2.0)       # right_leg_swing
	var r_knee_rot = get_bone_rotation("RightKnee").get_euler()
	values[12] = -r_knee_rot.x / 2.6            # right_knee
	var r_ankle_rot = get_bone_rotation("RightAnkle").get_euler()
	values[13] = r_ankle_rot.x / (PI / 3.0)     # right_ankle

	return values


## Get list of preset names
func get_preset_names() -> Array:
	return POSE_PRESETS.keys()


## Apply a preset pose by name
func apply_preset(preset_name: String) -> void:
	if preset_name in POSE_PRESETS:
		apply_pose_vector(POSE_PRESETS[preset_name])
