extends SceneTree
## Text-zoom regression tests (View → Zoom In/Out Text).
##
## Run: godot --headless --path src --script test/test_text_zoom.gd
##
## Locks the two fixes that make text zoom usable for chat:
##   1. _set_node_font_size handles ANY RichTextLabel (chat bodies are
##      MarkdownLabel subclasses, but MessageMarkdown also creates plain
##      RichTextLabels) via the per-style font-size keys — the generic
##      "font_size" key does nothing on RichTextLabel.
##   2. _reset_node_font_size REMOVES overrides (theme values return).
##   3. _on_node_added_apply_text_zoom stamps late-created Controls only
##      while a non-default zoom is active — new chat messages keep the
##      user's chosen size instead of reverting to the theme default.
##
## MainScene is instantiated DETACHED (never enters the tree, _ready never
## fires) so no scene dependencies or real config writes are involved.

const MAIN_SCENE_SCRIPT := "res://Scripts/UI/Views/MainScene.gd"

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
	print("=== text zoom tests ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	# Autoload globals (SingletonObject) register after _init in --script runs;
	# MainScene.gd won't compile until they exist.
	await process_frame
	var script = load(MAIN_SCENE_SCRIPT)
	check("MainScene.gd compiles", script != null)
	if script == null:
		return
	var ms: Control = script.new()

	# -- RichTextLabel gets the per-style keys ------------------------------
	var rtl := RichTextLabel.new()
	ms._set_node_font_size(rtl, 24)
	check("RichTextLabel: normal_font_size override applied",
		rtl.has_theme_font_size_override("normal_font_size")
			and rtl.get_theme_font_size("normal_font_size") == 24)
	for key in ["bold_font_size", "italics_font_size", "bold_italics_font_size", "mono_font_size"]:
		check("RichTextLabel: %s override applied" % key,
			rtl.has_theme_font_size_override(key) and rtl.get_theme_font_size(key) == 24)
	check("RichTextLabel: generic font_size key NOT used",
		not rtl.has_theme_font_size_override("font_size"))

	# -- plain Control gets the generic key ---------------------------------
	var lbl := Label.new()
	ms._set_node_font_size(lbl, 24)
	check("Label: font_size override applied",
		lbl.has_theme_font_size_override("font_size")
			and lbl.get_theme_font_size("font_size") == 24)

	# -- reset removes overrides --------------------------------------------
	ms._reset_node_font_size(rtl)
	check("RichTextLabel: reset removes normal_font_size override",
		not rtl.has_theme_font_size_override("normal_font_size"))
	ms._reset_node_font_size(lbl)
	check("Label: reset removes font_size override",
		not lbl.has_theme_font_size_override("font_size"))

	# -- late-created nodes stamped only while zoomed ------------------------
	ms._default_zoom = 14
	ms.current_font_size = 14
	var late_idle := RichTextLabel.new()
	ms._on_node_added_apply_text_zoom(late_idle)
	check("node_added hook: no-op at default zoom",
		not late_idle.has_theme_font_size_override("normal_font_size"))

	ms.current_font_size = 22
	var late_zoomed := RichTextLabel.new()
	ms._on_node_added_apply_text_zoom(late_zoomed)
	check("node_added hook: applies active zoom to new RichTextLabel",
		late_zoomed.has_theme_font_size_override("normal_font_size")
			and late_zoomed.get_theme_font_size("normal_font_size") == 22)
	var late_non_control := Node.new()
	ms._on_node_added_apply_text_zoom(late_non_control)
	check("node_added hook: ignores non-Control nodes", true)  # no crash = pass

	rtl.free()
	lbl.free()
	late_idle.free()
	late_zoomed.free()
	late_non_control.free()
	ms.free()
