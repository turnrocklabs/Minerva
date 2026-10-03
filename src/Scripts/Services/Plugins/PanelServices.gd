class_name PanelServices
extends RefCounted
## Shared live editor/panel lookup and viewport capture; no autoload registration.
## Explicit broker/editor inputs support off-tree callers. Production discovers
## the current services from the SceneTree without retaining their lifetime.

static func context() -> Dictionary:
	var loop := Engine.get_main_loop()
	var so: Node = (loop as SceneTree).root.get_node_or_null("SingletonObject") if loop is SceneTree else null
	var pane: Variant = so.get("editor_pane") if so != null else null
	return {"broker": so.get("plugin_scene_panel_broker") if so != null else null,
		"editors": pane.get_open_editors() if is_instance_valid(pane) else []}


## Panel tools prefer broker aliases; snapshots prefer an exact visible tab.
## Duplicate tab names refuse resolution instead of choosing the first match.
static func resolve(editor_name: String, broker: Variant = null,
		editors: Array = [], prefer_panel: bool = false) -> Dictionary:
	if not is_instance_valid(broker):
		broker = null
	var known: Array = AnnotationHostRegistry.list_editor_names()
	if broker != null and broker.has_method("list_panel_editor_names"):
		for title in broker.list_panel_editor_names():
			if not known.has(title):
				known.append(title)
	var matches: Array[Object] = []
	for candidate in editors:
		if not is_instance_valid(candidate):
			continue
		var title := str(candidate.get("tab_title"))
		if not known.has(title):
			known.append(title)
		if DocumentIdentity.handle(candidate, "view") == editor_name:
			matches = [candidate]
			break
		if title == editor_name:
			matches.append(candidate)
	var editor: Object = matches[0] if matches.size() == 1 else null
	var panel: Variant = broker.get_panel_for_editor(editor_name) if broker != null and broker.has_method("get_panel_for_editor") else null
	var broker_panel: Variant = panel
	if not prefer_panel or panel == null:
		if matches.size() > 1:
			return {"ok": false, "error": "Ambiguous editor '%s'" % editor_name,
				"known": known, "dead": [], "views": ["active"]}
		if editor != null and not prefer_panel:
			panel = editor.get("plugin_scene_root") if "plugin_scene_root" in editor else null
	var host: AnnotationHost = AnnotationHostRegistry.get_host(editor_name)
	if panel == null and (prefer_panel or editor == null) and host != null and host.has_method("get_panel"):
		panel = host.get_panel()
	if not is_instance_valid(panel):
		panel = null
	if panel != null:
		for candidate in editors:
			if is_instance_valid(candidate) and "plugin_scene_root" in candidate and candidate.get("plugin_scene_root") == panel:
				editor = candidate
				break
		if panel.has_method("get_annotation_host"):
			var raw_host: Variant = panel.get_annotation_host()
			host = raw_host as AnnotationHost if is_instance_valid(raw_host) else null
	if editor == null and panel == null:
		var dead: Array = []
		if broker != null and broker.has_method("list_dead_panel_editor_names"):
			for title in broker.list_dead_panel_editor_names():
				if not known.has(title) and not dead.has(title):
					dead.append(title)
		return {"ok": false, "error": "Unknown or ambiguous editor '%s'" % editor_name,
			"known": known, "dead": dead, "views": ["active"]}
	var broker_bound: bool = is_instance_valid(panel) and panel == broker_panel
	var owner := str(broker.get_panel_owner(editor_name)) if broker_bound and broker.has_method("get_panel_owner") else ""
	if owner.is_empty() and panel != null and "plugin_id" in panel:
		owner = str(panel.get("plugin_id"))
	return {"ok": true, "editor": editor, "panel": panel, "host": host,
		"plugin_id": owner, "broker_bound": broker_bound}


static func resolve_cad_host(editor_name: String) -> AnnotationHost:
	var host := AnnotationHostRegistry.get_host(editor_name)
	if host != null and host.has_method("get_mesh_data"):
		return host
	var panel_host := AnnotationHostRegistry.get_panel_host(editor_name)
	if panel_host != null:
		return panel_host
	var ctx := context()
	var resolved := resolve(editor_name, ctx.broker, ctx.editors, true)
	if resolved.ok and resolved.host != null and resolved.panel != null:
		return resolved.host
	var editor: Variant = resolved.get("editor")
	if is_instance_valid(editor) and is_instance_valid(ctx.broker):
		var live_editors: Array = ctx.editors.filter(func(candidate: Variant) -> bool: return is_instance_valid(candidate))
		var paired := DocumentIdentity.owning_plugin_view(editor, ctx.broker, live_editors,
			DocumentIdentity.buffer_for(editor, ctx.broker))
		if paired != null and "plugin_id" in paired and str(paired.plugin_id) == "cad":
			return AnnotationHostRegistry.get_panel_host(str(paired.plugin_panel_key))
	return null


static func views(panel: Variant) -> Array[String]:
	var names: Array[String] = ["active"]
	if is_instance_valid(panel) and panel.has_method("get_viewports"):
		for slot in panel.get_viewports():
			if str(slot) != "active":
				names.append(str(slot))
	return names


## Selection is separate from GPU readback so headless tests can prove routing.
static func capture_target(resolved: Dictionary, slot: String = "active") -> Dictionary:
	var panel: Variant = resolved.get("panel")
	var available := views(panel)
	if not available.has(slot):
		return {"ok": false, "error": "Unknown view '%s'" % slot, "views": available}
	var raw_surface: Variant = panel if is_instance_valid(panel) else resolved.get("editor")
	var surface: Control = raw_surface as Control if is_instance_valid(raw_surface) else null
	if not is_instance_valid(surface) or not surface.is_visible_in_tree():
		return {"ok": false, "error": "View '%s' is not visible in the tree" % slot, "views": available}
	var viewport: Viewport = null
	if slot == "active":
		viewport = surface.get_viewport() if is_instance_valid(surface) else null
	else:
		var raw_viewport: Variant = panel.get_viewports().get(slot)
		viewport = raw_viewport as SubViewport if is_instance_valid(raw_viewport) else null
	if viewport == null or not is_instance_valid(viewport):
		return {"ok": false, "error": "View '%s' has no live viewport" % slot, "views": available}
	return {"ok": true, "viewport": viewport, "surface": surface if slot == "active" else null}


static func capture(target: Dictionary) -> Image:
	if not target.get("ok", false):
		return null
	await RenderingServer.frame_post_draw
	# Freed Objects can compare equal to null; inspect raw values before typing.
	var raw_viewport: Variant = target.get("viewport")
	var raw_surface: Variant = target.get("surface")
	if not is_instance_valid(raw_viewport) or (typeof(raw_surface) != TYPE_NIL
			and not is_instance_valid(raw_surface)):
		return null
	var viewport: Viewport = raw_viewport
	var surface: Control = raw_surface
	var texture := viewport.get_texture()
	var image: Image = texture.get_image() if texture != null else null
	if image != null and surface != null:
		var rect := Rect2i(surface.get_global_rect()).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
		return image.get_region(rect) if rect.has_area() else null
	return image
