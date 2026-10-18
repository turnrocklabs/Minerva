class_name PluginEditorHandoff
extends RefCounted
## File opening and anonymous document creation share this orchestration owner.
## The host supplies live UI/services; this object owns no global lifecycle.
var pane: EditorPane
var manager: PluginManager
var registry: PluginEditorRegistry
var scene_broker: PluginScenePanelBroker
var documents: DocumentRegistry
var open_paired: Callable
var type_name: Callable


func _init(editor_pane: EditorPane, plugin_manager: PluginManager, editor_registry: PluginEditorRegistry,
		broker: PluginScenePanelBroker, document_registry: DocumentRegistry,
		paired_open: Callable, editor_type_name: Callable) -> void:
	pane = editor_pane
	manager = plugin_manager
	registry = editor_registry
	scene_broker = broker
	documents = document_registry
	open_paired = paired_open
	type_name = editor_type_name


func open_file_at_path(path: String) -> Dictionary:
	# --- Path validation ---
	var abs_path: String = path
	if not abs_path.is_absolute_path():
		# Resolve via ProjectSettings as best-effort; warn in response.
		var globalized: String = ProjectSettings.globalize_path(abs_path)
		abs_path = globalized
		push_warning("[open_file_at_path] path was relative; resolved to: %s" % abs_path)

	if not FileAccess.file_exists(abs_path):
		if DirAccess.dir_exists_absolute(abs_path):
			return {"ok": false, "errors": ["not_a_file: %s" % abs_path]}
		return {"ok": false, "errors": ["file_not_found: %s" % abs_path]}

	if pane == null:
		return {"ok": false, "errors": ["pane not available"]}

	# --- Idempotency: check if already open ---
	# TODO(paired_dsl close-one): for render_mode=paired_dsl, two editors share
	# editor.file. If the user closed only the render panel, this loop returns
	# the surviving text editor and _open_paired_dsl never runs to recreate the
	# render panel. Substrate-level limitation; revisit when paired_dsl ships.
	for editor: Editor in pane.get_open_editors():
		if editor.file == abs_path:
			var kind_name: String = type_name.call(editor.type)
			# Explicit Variant locals so null branches type-check (incompatible ternary).
			var existing_plugin_id: Variant = null
			if not editor.plugin_id.is_empty():
				existing_plugin_id = editor.plugin_id
			var existing_panel_name: Variant = null
			if not editor.panel_name.is_empty():
				existing_panel_name = editor.panel_name
			return {
				"ok": true,
				"editor_kind": kind_name,
				"editor_name": editor.tab_title,
				"plugin_id": existing_plugin_id,
				"panel_name": existing_panel_name,
			}

	# --- Extension resolution ---
	var lower: String = abs_path.to_lower()
	var ext: String = "." + abs_path.get_extension().to_lower()

	var result_editor: Editor = null
	var editor_kind: String = ""
	var p_id: String = ""
	var p_name: String = ""

	if lower.ends_with(".jpeg") or lower.ends_with(".jpg") or lower.ends_with(".png"):
		result_editor = pane.add(Editor.Type.GRAPHICS, abs_path)
		editor_kind = "GRAPHICS"
	# .minpcb routing removed at cutover 2026-07-07. Until the plugin's legacy
	# .minpcb importer lands (fast-follow), .minpcb falls through to the plugin
	# registry → TEXT fallback (its JSON is readable). The pcb plugin owns .pcbskel.
	elif lower.ends_with(".minkb"):
		result_editor = pane.add(Editor.Type.KANBAN, abs_path)
		editor_kind = "KANBAN"
	elif lower.ends_with(".minsheet"):
		result_editor = pane.add(Editor.Type.SPREADSHEET, abs_path)
		editor_kind = "SPREADSHEET"
	else:
		# Check plugin registry before falling back to TEXT (design §7.3).
		var reg: PluginEditorRegistry = null
		if "registry" in self:
			reg = get("registry")
		var panel_info: Dictionary = {}
		if reg != null:
			panel_info = reg.resolve_extension(ext)
		if not panel_info.is_empty():
			p_id = panel_info.get("plugin_id", "")
			p_name = panel_info.get("panel_name", "")
			# Validate plugin is running before opening.
			if manager != null:
				var status: Dictionary = manager.get_plugin_status(p_id)
				if not status.get("running", false):
					return {"ok": false, "errors": ["plugin_not_running: %s" % p_id]}
			# DCR 019dfa66 §T5: render_mode "paired_dsl" routes to a paired
			# text-editor + render-panel layout, both sharing the same
			# DocumentBuffer. The text editor is the canonical edit surface;
			# the render panel subscribes via the broker.
			var render_mode: String = panel_info.get("render_mode", "single")
			if render_mode == "paired_dsl":
				result_editor = open_paired.call(abs_path, p_id, p_name)
				editor_kind = "PLUGIN_SCENE_PAIRED_DSL"
			else:
				result_editor = pane.add_plugin_scene_editor(p_id, p_name, abs_path)
				editor_kind = "PLUGIN_SCENE"
		else:
			result_editor = pane.add(Editor.Type.TEXT, abs_path)
			editor_kind = "TEXT"

	if result_editor == null:
		return {"ok": false, "errors": ["no_handler_for_extension: %s" % ext]}

	# Explicit Variant locals so null branches type-check (incompatible ternary).
	var plugin_id_out: Variant = null
	if not p_id.is_empty():
		plugin_id_out = p_id
	var panel_name_out: Variant = null
	if not p_name.is_empty():
		panel_name_out = p_name
	return {
		"ok": true,
		"editor_kind": editor_kind,
		"editor_name": result_editor.tab_title,
		"plugin_id": plugin_id_out,
		"panel_name": panel_name_out,
	}



func create_plugin_editor(args: Dictionary) -> Dictionary:
	var plugin_id: String = str(args.get("plugin_id", "")).strip_edges()
	var editor_item_id: String = str(args.get("editor_item_id", "")).strip_edges()
	var tab_title: String = str(args.get("tab_title", "")).strip_edges()
	if plugin_id.is_empty() or editor_item_id.is_empty():
		return MCPToolUtils.error("plugin_id and editor_item_id are required")

	var pm: PluginManager = manager
	if pm == null:
		return MCPToolUtils.error("plugin_manager_not_available")
	var def: PluginDefinition = pm.get_db().get_by_id(plugin_id)
	if def == null:
		return MCPToolUtils.error("plugin_not_found: %s" % plugin_id)

	# Look up the editor_items entry by its declared id.
	var editor_item: Dictionary = {}
	for ei: Dictionary in def.editor_items:
		if ei is Dictionary and str(ei.get("id", "")) == editor_item_id:
			editor_item = ei
			break
	if editor_item.is_empty():
		return MCPToolUtils.error("editor_item_not_found: %s" % editor_item_id)

	var panel_name: String = str(editor_item.get("panel", ""))
	if panel_name.is_empty():
		return MCPToolUtils.error("editor_item_missing_panel: %s" % editor_item_id)

	# Default tab_title to the editor_items entry's name field if the caller
	# didn't supply one.
	if tab_title.is_empty():
		tab_title = str(editor_item.get("name", editor_item_id))

	# Resolve panel kind + render_mode from ui_panels.
	var panel_kind: String = "html"
	var render_mode: String = "single"
	for pd: Dictionary in def.ui_panels:
		if pd is Dictionary and pd.get("name", "") == panel_name:
			panel_kind = str(pd.get("kind", "html"))
			render_mode = str(pd.get("render_mode", "single"))
			break

	var editor_pane: EditorPane = pane
	if editor_pane == null:
		return MCPToolUtils.error("editor_pane_not_available")

	# Anonymous create currently only supports godot_scene panels — html panels
	# expect an HTML payload at construction time. Filing this gap as a
	# follow-up since no current plugin uses html-anonymous.
	if panel_kind != "godot_scene":
		return MCPToolUtils.error("html_panel_anonymous_create_unsupported: kind=%s" % panel_kind)

	# paired_dsl panels (e.g. cad) expect a sibling TEXT editor sharing a
	# DocumentBuffer with the render panel. The file-open path
	# (SingletonObject._open_paired_dsl) handles this for path-bound .mcad —
	# the anonymous-create path mirrors that shape using an unbacked buffer
	# (DocumentRegistry mints a synthetic identity that survives Save-As).
	if render_mode == "paired_dsl":
		var unbacked_r := documents.create_unbacked_buffer()
		if not unbacked_r.ok:
			return MCPToolUtils.error("unbacked_buffer_creation_failed: %s" % unbacked_r.get("error", "?"))
		var unbacked_buf: DocumentBuffer = unbacked_r.buffer
		var unbacked_path: String = unbacked_buf.file_path

		# Text editor: anonymous (no `file`), bind to unbacked buffer manually.
		# Distinct title from the render tab — when both share the same name,
		# find_editor_by_name returns whichever is first in the list, breaking
		# minerva_doc_write's resolver: it picks the TEXT editor and skips the
		# PLUGIN_SCENE branch where invoke_apply_sync lives, so doc_write reply
		# arrives without last_eval. F2's buffer routing keeps both tabs in sync
		# via the shared DocumentBuffer regardless of which name the agent uses.
		var text_tab: String = "%s (source)" % tab_title
		var text_editor: Editor = editor_pane.add(Editor.Type.TEXT, null, text_tab)
		if text_editor == null:
			return MCPToolUtils.error("text_editor_creation_failed")
		text_editor.bind_to_buffer_path(unbacked_path)

		# Render editor: anonymous plugin scene, broker attaches the unbacked
		# buffer so text_changed signals from the TEXT editor flow to the panel
		# via the substrate-reserved attach_buffer / text_changed channels.
		var render_editor: Editor = editor_pane.add_plugin_scene_editor(plugin_id, panel_name, null, tab_title)
		if render_editor == null:
			return MCPToolUtils.error("render_editor_creation_failed")
		var broker: PluginScenePanelBroker = scene_broker
		if broker != null:
			broker.attach_buffer_to_panel(plugin_id, render_editor.plugin_panel_key, unbacked_buf)
		else:
			push_warning("[minerva_create_plugin_editor] plugin_scene_panel_broker missing; text_changed will not flow to render panel")

		return MCPToolUtils.success({
			"editor_name": str(render_editor.tab_title),
			"text_editor_name": str(text_editor.tab_title),
			"plugin_id": plugin_id,
			"panel_name": panel_name,
			"panel_kind": panel_kind,
			"render_mode": render_mode,
			"buffer_path": unbacked_path,
		})

	# Non-paired_dsl (single-render) anonymous panel: same as before.
	var editor: Editor = editor_pane.add_plugin_scene_editor(plugin_id, panel_name, null, tab_title)
	if editor == null:
		return MCPToolUtils.error("editor_creation_failed")

	return MCPToolUtils.success({
		"editor_name": str(editor.tab_title),
		"plugin_id": plugin_id,
		"panel_name": panel_name,
		"panel_kind": panel_kind,
		"render_mode": render_mode,
	})
