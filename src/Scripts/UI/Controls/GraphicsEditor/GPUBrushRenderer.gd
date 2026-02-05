class_name GPUBrushRenderer
extends RefCounted

## GPU-accelerated brush stroke rendering using compute shaders
## Optimizes the drawing operations by offloading pixel manipulation to the GPU

var rd: RenderingDevice
var shader: RID
var pipeline: RID

# Buffer RIDs
var stroke_buffer_rid: RID
var layer_backup_rid: RID
var output_image_rid: RID
var params_buffer_rid: RID
var selection_buffer_rid: RID

# Uniform set
var uniform_set: RID

# Image dimensions
var image_width: int
var image_height: int

# Selection mask (packed bits)
var selection_mask: PackedByteArray

# Current brush color for this stroke
var current_brush_color: Color = Color.WHITE

const WORKGROUP_SIZE = 8

enum Operation {
	STAMP = 0,      # Draw brush stamp to stroke buffer
	COMPOSITE = 1,  # Composite stroke buffer to output
	CLEAR = 2,      # Clear stroke buffer
}

func _init():
	rd = RenderingServer.create_local_rendering_device()
	if not rd:
		push_error("Failed to create local RenderingDevice for GPU brush rendering")
		return
	
	_load_shader()


func _load_shader() -> void:
	var shader_file = load("res://Scripts/UI/Controls/GraphicsEditor/brush_stroke_compute.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	
	if not shader_spirv:
		push_error("Failed to load brush compute shader SPIRV")
		return
	
	shader = rd.shader_create_from_spirv(shader_spirv)
	if not shader.is_valid():
		push_error("Failed to create shader from SPIRV")
		return
	
	pipeline = rd.compute_pipeline_create(shader)


func initialize_buffers(image: Image, selection_data: PackedByteArray = PackedByteArray()) -> bool:
	if not rd or not shader.is_valid():
		return false
	
	image_width = image.get_width()
	image_height = image.get_height()
	
	# Create stroke buffer (RGBA8)
	var stroke_buffer_image = Image.create(image_width, image_height, false, Image.FORMAT_RGBA8)
	stroke_buffer_image.fill(Color.TRANSPARENT)
	stroke_buffer_rid = _create_image_buffer(stroke_buffer_image)
	
	# Create layer backup buffer
	layer_backup_rid = _create_image_buffer(image)
	
	# Create output image buffer
	var output_image = Image.create(image_width, image_height, false, Image.FORMAT_RGBA8)
	output_image.fill(Color.TRANSPARENT)
	output_image_rid = _create_image_buffer(output_image)
	
	# Create parameters buffer
	params_buffer_rid = _create_params_buffer()
	
	# Create selection buffer
	var selection_size = ceili(float(image_width * image_height) / 32.0) * 4  # 32 pixels per uint (4 bytes)
	if selection_data.is_empty():
		# No selection - all pixels selected
		selection_mask = PackedByteArray()
		selection_mask.resize(selection_size)
		selection_mask.fill(0xFF)  # All bits set
	else:
		selection_mask = selection_data
	
	selection_buffer_rid = _create_selection_buffer()
	
	# Create uniform set
	_create_uniform_set()
	
	return true


func _create_image_buffer(image: Image) -> RID:
	var fmt = RDTextureFormat.new()
	fmt.width = image.get_width()
	fmt.height = image.get_height()
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	
	var view = RDTextureView.new()
	var data = image.get_data()
	
	return rd.texture_create(fmt, view, [data])


func _create_params_buffer() -> RID:
	# BrushParams structure: 
	# vec4 brush_color (16 bytes)
	# vec2 center_position (8 bytes)
	# float radius (4 bytes)
	# int operation (4 bytes)
	# vec2 image_size (8 bytes)
	# int use_selection (4 bytes)
	# float _padding (4 bytes)
	# Total: 48 bytes
	
	var buffer_size = 48
	var buffer = PackedByteArray()
	buffer.resize(buffer_size)
	buffer.fill(0)
	
	return rd.storage_buffer_create(buffer_size, buffer)


func _create_selection_buffer() -> RID:
	return rd.storage_buffer_create(selection_mask.size(), selection_mask)


func _create_uniform_set() -> void:
	var uniforms = []
	
	# Binding 0: stroke_buffer (image2D)
	var u0 = RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u0.binding = 0
	u0.add_id(stroke_buffer_rid)
	uniforms.append(u0)
	
	# Binding 1: layer_backup (readonly image2D)
	var u1 = RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u1.binding = 1
	u1.add_id(layer_backup_rid)
	uniforms.append(u1)
	
	# Binding 2: output_image (writeonly image2D)
	var u2 = RDUniform.new()
	u2.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u2.binding = 2
	u2.add_id(output_image_rid)
	uniforms.append(u2)
	
	# Binding 3: params (storage buffer)
	var u3 = RDUniform.new()
	u3.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u3.binding = 3
	u3.add_id(params_buffer_rid)
	uniforms.append(u3)
	
	# Binding 4: selection (storage buffer)
	var u4 = RDUniform.new()
	u4.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u4.binding = 4
	u4.add_id(selection_buffer_rid)
	uniforms.append(u4)
	
	uniform_set = rd.uniform_set_create(uniforms, shader, 0)


func draw_brush_stamp(center: Vector2, radius: float, color: Color, use_selection: bool = false) -> void:
	if not rd or not uniform_set.is_valid():
		return
	
	# Store the brush color for this stroke
	current_brush_color = color
	
	# Update parameters buffer
	_update_params_buffer(color, center, radius, Operation.STAMP, use_selection)
	
	# Dispatch compute shader
	_dispatch_compute()


func composite_stroke_to_output() -> void:
	if not rd or not uniform_set.is_valid():
		return
	
	# Update parameters for composite operation (use stored brush color)
	_update_params_buffer(current_brush_color, Vector2.ZERO, 0.0, Operation.COMPOSITE, false)
	
	# Dispatch compute shader
	_dispatch_compute()


func clear_stroke_buffer() -> void:
	if not rd or not uniform_set.is_valid():
		return
	
	# Update parameters for clear operation
	_update_params_buffer(Color.WHITE, Vector2.ZERO, 0.0, Operation.CLEAR, false)
	
	# Dispatch compute shader
	_dispatch_compute()


func _update_params_buffer(color: Color, center: Vector2, radius: float, operation: Operation, use_selection: bool) -> void:
	var params = PackedByteArray()
	params.resize(48)
	
	var offset = 0
	
	# vec4 brush_color (16 bytes)
	params.encode_float(offset, color.r)
	params.encode_float(offset + 4, color.g)
	params.encode_float(offset + 8, color.b)
	params.encode_float(offset + 12, color.a)
	offset += 16
	
	# vec2 center_position (8 bytes)
	params.encode_float(offset, center.x)
	params.encode_float(offset + 4, center.y)
	offset += 8
	
	# float radius (4 bytes)
	params.encode_float(offset, radius)
	offset += 4
	
	# int operation (4 bytes)
	params.encode_s32(offset, operation)
	offset += 4
	
	# vec2 image_size (8 bytes)
	params.encode_float(offset, float(image_width))
	params.encode_float(offset + 4, float(image_height))
	offset += 8
	
	# int use_selection (4 bytes)
	params.encode_s32(offset, 1 if use_selection else 0)
	offset += 4
	
	# float _padding (4 bytes) - already zeroed
	
	rd.buffer_update(params_buffer_rid, 0, params.size(), params)


func _dispatch_compute() -> void:
	var x_groups = ceili(float(image_width) / WORKGROUP_SIZE)
	var y_groups = ceili(float(image_height) / WORKGROUP_SIZE)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
	rd.compute_list_end()
	
	# Submit and sync
	rd.submit()
	rd.sync()


func get_output_image() -> Image:
	if not rd or not output_image_rid.is_valid():
		return null
	
	var byte_data = rd.texture_get_data(output_image_rid, 0)
	var image = Image.create_from_data(image_width, image_height, false, Image.FORMAT_RGBA8, byte_data)
	
	return image


func update_layer_backup(image: Image) -> void:
	if not rd or not layer_backup_rid.is_valid():
		return
	
	var data = image.get_data()
	rd.texture_update(layer_backup_rid, 0, data)


func cleanup() -> void:
	if not rd:
		return
	
	if uniform_set.is_valid():
		rd.free_rid(uniform_set)
	
	if stroke_buffer_rid.is_valid():
		rd.free_rid(stroke_buffer_rid)
	
	if layer_backup_rid.is_valid():
		rd.free_rid(layer_backup_rid)
	
	if output_image_rid.is_valid():
		rd.free_rid(output_image_rid)
	
	if params_buffer_rid.is_valid():
		rd.free_rid(params_buffer_rid)
	
	if selection_buffer_rid.is_valid():
		rd.free_rid(selection_buffer_rid)
	
	if pipeline.is_valid():
		rd.free_rid(pipeline)
	
	if shader.is_valid():
		rd.free_rid(shader)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if self:
			cleanup()
