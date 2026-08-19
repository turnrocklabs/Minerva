extends SceneTree
const DIR := "/tmp/claude-1000/-home-imran-github-Minerva/aaf84624-5815-4236-907d-45da42a209da/scratchpad/chevron/"
func _init() -> void: call_deferred("_run")
func _run() -> void:
	await process_frame
	await process_frame
	var so = root.get_node_or_null("SingletonObject")
	root.size = Vector2i(560, 320)
	var scene = load("res://Scenes/Chat.tscn").instantiate()
	scene.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(scene)
	for i in 5: await process_frame
	var pane = scene.find_child("tcChats", true, false)
	var CH = load("res://Scripts/Models/ChatHistory.gd")
	for n in ["Competitor scan", "Pricing teardown", "Agenda"]:
		var h = CH.new(so.API_MODEL_PROVIDER_SCRIPTS.values()[1].new())
		h.HistoryName = n
		so.ChatList.append(h); pane.render_history(h)
	for i in 4: await process_frame
	var g1 = so.chat_groups.create_group("Market research")
	var g2 = so.chat_groups.create_group("Q3 planning")
	pane.set_chat_group(so.ChatList[0], g1); pane.set_chat_group(so.ChatList[1], g1)
	pane.set_chat_group(so.ChatList[2], g2)
	pane.set_active_group("__all__"); pane._refresh_group_dock()
	for i in 6: await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(DIR + "state_expanded.png")
	pane.get_group_dock().set_collapsed(true)
	for i in 6: await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(DIR + "state_collapsed.png")
	print("SAVED both")
	quit(0)
