extends Control
## Spike test for godot-cef integration under DCR 019dac8d / work_item 019dac8d..5fd1.
##
## Gates validated by this scene:
##   1. Caret blinks in HTML text inputs on click.
##   2. Typing registers in the input.
##   3. IPC JS → Godot round-trip fires ipc_message (button in HTML posts).
##   4. Local file loading works (file:// path — res:// equivalent tested separately if this works).
##
## How to run: open CefSpikeTest.tscn, press F6 (Play This Scene).

var _cef: Control = null


func _ready() -> void:
	print("[cef-spike] _ready")
	if not ClassDB.class_exists("CefTexture"):
		push_error("[cef-spike] CefTexture class not registered. godot-cef extension didn't load.")
		var label := Label.new()
		label.text = "CefTexture not available.\nOpen project in Godot 4.6, it should auto-register the extension.\nThen press F6 again."
		label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		add_child(label)
		return

	_cef = ClassDB.instantiate("CefTexture")
	if _cef == null:
		push_error("[cef-spike] ClassDB.instantiate(CefTexture) returned null")
		return

	# Disable Vulkan accelerated OSR. Our Godot runs on Vulkan (Forward+) and
	# CEF also runs on Vulkan; sharing textures between two independent Vulkan
	# instances via DMA-BUF fails silently here — we get a texture handle but
	# no visible output. Software OSR is slower but unambiguous for spiking.
	if _cef.has_method("set_enable_accelerated_osr"):
		_cef.set("enable_accelerated_osr", false)
		print("[cef-spike] accelerated OSR disabled, using software rendering")
	else:
		print("[cef-spike] note: enable_accelerated_osr property not found; continuing with defaults")

	add_child(_cef)
	_cef.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cef.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cef.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Dump everything, because godot-cef's JS-side API doesn't clearly map to
	# a single signal name. Connect to every signal whose name looks IPC-related
	# so we can see which one fires when JS calls window.sendIpcMessage.
	print("[cef-spike] signals:", _cef.get_signal_list().map(func(s): return s.name))
	print("[cef-spike] methods (public):", _cef.get_method_list().filter(func(m): return not m.name.begins_with("_")).map(func(m): return m.name))

	for sig in _cef.get_signal_list():
		var name: String = sig.name
		var lower: String = name.to_lower()
		if "ipc" in lower or "message" in lower or "listener" in lower or "data" in lower:
			_cef.connect(name, func(arg = null, arg2 = null, arg3 = null):
				print("[cef-spike] SIGNAL '", name, "' fired with args=", [arg, arg2, arg3]))
			print("[cef-spike] connected probe to signal: ", name)

	# Also try the listener-based API if it exists.
	if _cef.has_method("addListener"):
		_cef.call("addListener", "default", func(msg): print("[cef-spike] addListener 'default' got: ", msg))
		print("[cef-spike] addListener(default, ...) wired")
	if _cef.has_method("add_listener"):
		_cef.call("add_listener", "default", func(msg): print("[cef-spike] add_listener 'default' got: ", msg))
		print("[cef-spike] add_listener(default, ...) wired")

	# Now load our local HTML so we can test caret + typing + IPC gates.
	var html_res_path: String = "res://spike/cef/test.html"
	var absolute_path: String = ProjectSettings.globalize_path(html_res_path)
	var file_url: String = "file://" + absolute_path
	print("[cef-spike] loading url=", file_url)
	_cef.set("url", file_url)

	# Log CefTexture state 2 seconds after load-start so we can see if it ever
	# acquires a texture or paints anything.
	await get_tree().create_timer(2.0).timeout
	print("[cef-spike] post-load diagnostics:")
	print("  size=", _cef.size, " global_pos=", _cef.global_position)
	print("  visible=", _cef.visible, " visible_in_tree=", _cef.is_visible_in_tree())
	if _cef.has_method("get_texture"):
		var tex = _cef.get_texture()
		print("  texture=", tex, " has_texture=", (tex != null))
	print("  url_prop=", _cef.get("url"))


func _on_ipc_message(msg: String) -> void:
	print("[cef-spike] IPC received: ", msg)
	# Echo back to JS so we can verify Godot → JS eval path too
	if _cef != null and _cef.has_method("eval"):
		var reply := "spike_from_godot('Godot got: ' + " + JSON.stringify(msg) + ")"
		_cef.call("eval", reply)
