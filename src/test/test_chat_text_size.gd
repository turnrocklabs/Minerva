extends SceneTree
## Chat-scoped text size tests (View → Chat Text Larger/Smaller/Reset).
##
## Run: godot --headless --path src --script test/test_chat_text_size.gd
##
## Replaces test_text_zoom.gd: the whole-tree text zoom is gone (stamping font
## overrides on every Control overflowed popups). Chat text size is now owned
## by SingletonObject (chat_font_size, 0 = theme default) and applied by
## MessageMarkdown to its OWN RichTextLabels only, with the collapsed-height
## budgets scaled by the font ratio so bigger text doesn't clip.

const MESSAGE_SCENE := "res://Scenes/MessageMarkdown.tscn"

var _pass := 0
var _fail := 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s%s" % [label, (" — " + detail) if detail != "" else ""])


func _init() -> void:
	print("=== chat text size tests ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	await process_frame
	var so = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload present", so != null)
	if so == null:
		return

	# -- state machine on SingletonObject ------------------------------------
	var original: int = so.chat_font_size

	so.chat_font_size = 0
	var default_size: int = so.theme_default_font_size()
	check("theme_default_font_size positive", default_size > 0, str(default_size))
	check("effective size falls back to theme default when unset",
		so.effective_chat_font_size() == default_size)

	so.increment_chat_font_size()
	check("increment from default steps up",
		so.chat_font_size == clampi(default_size + so.chat_font_size_step,
			so.min_chat_font_size, so.max_chat_font_size),
		str(so.chat_font_size))
	check("effective size uses the explicit value",
		so.effective_chat_font_size() == so.chat_font_size)

	so.chat_font_size = so.max_chat_font_size
	so.increment_chat_font_size()
	check("increment clamps at max", so.chat_font_size == so.max_chat_font_size)

	so.chat_font_size = so.min_chat_font_size
	so.decrement_chat_font_size()
	check("decrement clamps at min", so.chat_font_size == so.min_chat_font_size)

	var signal_fired: Array = [false]
	var handler := func(): signal_fired[0] = true
	so.chat_font_size_changed.connect(handler)
	so.reset_chat_font_size()
	check("reset returns to 0 (theme default)", so.chat_font_size == 0)
	check("changes emit chat_font_size_changed", signal_fired[0])
	so.chat_font_size_changed.disconnect(handler)

	# -- MessageMarkdown application (detached instance, _ready never fires) --
	var scene = load(MESSAGE_SCENE)
	check("MessageMarkdown.tscn loads", scene != null)
	if scene == null:
		so.chat_font_size = original
		return
	var msg = scene.instantiate()

	# _apply_font_overrides targets every RichTextLabel in the subtree.
	msg._apply_font_overrides(msg, 24)
	var rtl_count := 0
	var all_sized := true
	var stack: Array[Node] = [msg]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is RichTextLabel:
			rtl_count += 1
			if not (n.has_theme_font_size_override("normal_font_size")
					and n.get_theme_font_size("normal_font_size") == 24
					and n.get_theme_font_size("mono_font_size") == 24):
				all_sized = false
		stack.append_array(n.get_children())
	check("subtree contains RichTextLabels", rtl_count > 0, str(rtl_count))
	check("all RichTextLabels get the per-style size keys", all_sized)

	msg._apply_font_overrides(msg, 0)
	var any_override := false
	stack = [msg]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is RichTextLabel and n.has_theme_font_size_override("normal_font_size"):
			any_override = true
		stack.append_array(n.get_children())
	check("size 0 removes all overrides (theme default returns)", not any_override)

	# -- collapsed-height budgets scale with the font ratio -------------------
	var base_start: float = msg.custom_starting_size
	var base_max: float = msg.max_message_size_limit
	so.chat_font_size = default_size * 2
	msg._apply_chat_font_size()
	check("custom_starting_size scales with font ratio",
		is_equal_approx(msg.custom_starting_size, base_start * 2.0),
		str(msg.custom_starting_size))
	check("max_message_size_limit scales with font ratio",
		is_equal_approx(msg.max_message_size_limit, base_max * 2.0),
		str(msg.max_message_size_limit))

	so.chat_font_size = 0
	msg._apply_chat_font_size()
	check("reset restores the height budgets",
		is_equal_approx(msg.custom_starting_size, base_start)
			and is_equal_approx(msg.max_message_size_limit, base_max),
		"%s / %s" % [msg.custom_starting_size, msg.max_message_size_limit])

	msg.free()
	# Leave the user's persisted value untouched.
	so.chat_font_size = original
