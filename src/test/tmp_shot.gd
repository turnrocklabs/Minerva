extends SceneTree
const DIR := "/tmp/claude-1000/-home-imran-github-Minerva/aaf84624-5815-4236-907d-45da42a209da/scratchpad/chevron/"
func _init() -> void: call_deferred("_run")
func _run() -> void:
	await process_frame
	await process_frame
	var so = root.get_node_or_null("SingletonObject")
	root.size = Vector2i(560, 300)
	var scene = load("res://Scenes/Chat.tscn").instantiate()
	scene.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(scene)
	for i in 6: await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(DIR + "blank_before.png")

	var pane = scene.find_child("tcChats", true, false)
	pane._on_new_chat()
	for i in 6: await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(DIR + "blank_after.png")
	print("SAVED")
	quit(0)
