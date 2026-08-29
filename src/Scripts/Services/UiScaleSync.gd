class_name UiScaleSync
extends RefCounted
## Every sub-window renders at Minerva's UI zoom.
##
## The zoom lives in root.content_scale_factor and Godot sub-windows do not
## inherit it, so a dialog that nobody synced popped at 1.0 while the app
## rendered zoomed — eight of them found one HITL at a time (chore
## 019fb90972). Instead of a copy at every popup site, ONE hook on the scene
## tree stamps the root's factor on every Window the moment it enters the
## tree, re-stamps it on about_to_popup (a dialog built before a zoom change
## and popped after), and re-stamps every open window when the zoom changes.
##
## Sizes are the window's own business: wrap_controls dialogs (the whole
## AcceptDialog family) size themselves from their scaled content, and a
## fixed-size Window that scales its own rect (PersistentWindow) still does.

const _META_HOOKED := "ui_scale_synced"


## Arm the tree once (SingletonObject does it at startup).
static func install(tree: SceneTree) -> void:
	if tree.node_added.is_connected(_on_node_added):
		return
	tree.node_added.connect(_on_node_added)
	resync_all(tree)


static func _on_node_added(node: Node) -> void:
	if node is Window:
		sync(node as Window)


## Stamp the root's factor on one window and keep it stamped across pops.
static func sync(window: Window) -> void:
	if window == null or not window.is_inside_tree():
		return
	var root: Window = window.get_tree().root
	if window == root:
		return
	window.content_scale_factor = root.content_scale_factor
	if not window.has_meta(_META_HOOKED):
		window.set_meta(_META_HOOKED, true)
		window.about_to_popup.connect(sync.bind(window))


## After a zoom change: every window already in the tree follows.
static func resync_all(tree: SceneTree) -> void:
	if tree == null or tree.root == null:
		return
	for node in tree.root.find_children("*", "Window", true, false):
		sync(node as Window)
