extends SceneTree

class View extends Control:
	var buffer: DocumentBuffer
	var plugin_id := ""
	var plugin_panel_key := ""
	var tab_title := "same.mcad"
	func get_document_buffer() -> DocumentBuffer:
		return buffer

class IdentityPanel extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)
	var last_document_id := ""
	var snapshot := {"source": "stale panel source", "build_mode": "manual"}
	func _on_panel_save_request() -> Dictionary:
		return snapshot
	func receive(_channel: String, payload: Dictionary) -> void:
		last_document_id = str(payload.get("document_id", ""))
	func handle_tool(_tool: String, args: Dictionary) -> Dictionary:
		return {"success": true, "selected": args.editor_name}

var passed := 0
var failed := 0
func check(label: String, ok: bool) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: " + label)

func _init() -> void:
	await process_frame
	var registry := DocumentRegistry.get_instance()
	var buffer: DocumentBuffer = registry.create_unbacked_buffer().buffer
	var other: DocumentBuffer = registry.create_unbacked_buffer().buffer
	var text_view := View.new()
	text_view.buffer = buffer
	var render_view := View.new()
	render_view.buffer = buffer
	render_view.plugin_id = "cad"
	var other_view := View.new()
	other_view.buffer = other
	var views := [text_view, render_view, other_view]
	var text_id := DocumentIdentity.describe(text_view)
	var render_id := DocumentIdentity.describe(render_view)
	check("paired views share one document but have distinct view handles",
		text_id.document_id == render_id.document_id and text_id.view_id != render_id.view_id)
	check("same-named documents have different handles", other.document_id != buffer.document_id)
	check("document-only view selection reports ambiguity",
		DocumentIdentity.resolve({"document_id": buffer.document_id}, views).error == "ambiguous_document_view")
	check("plugin operation selects its own unique view",
		DocumentIdentity.resolve({"document_id": buffer.document_id}, views, null, "cad").editor == render_view)
	check("mismatched document/view handles cannot select another document",
		not DocumentIdentity.resolve({"document_id": other.document_id, "view_id": text_id.view_id}, views).ok)
	text_view.tab_title = "renamed.mcad"
	check("tab rename preserves identity", DocumentIdentity.describe(text_view) == text_id)
	var doc = load("res://Scripts/Services/MCP/Modules/MCPDocTools.gd").new()
	buffer.apply_edit("human edit")
	var read: Dictionary = await doc.handle("minerva_doc_read", {"document_id": buffer.document_id})
	check("document read returns canonical unsaved content and identity", read.text == "human edit" and read.document_id == buffer.document_id)
	var written: Dictionary = await doc.handle("minerva_doc_write", {"document_id": buffer.document_id, "text": "agent edit", "if_match_version": read.version})
	check("document write reaches both views' shared buffer", written.success and text_view.buffer.text == "agent edit" and render_view.buffer.text == "agent edit")
	var stale: Dictionary = await doc.handle("minerva_doc_write", {"document_id": buffer.document_id, "text": "stale edit", "if_match_version": read.version})
	check("identity routing preserves version guards", stale.has("error") and buffer.text == "agent edit")
	var old_path := buffer.file_path
	var destination := ProjectSettings.globalize_path("user://identity-test.mcad")
	var rebound := registry.rebind_buffer(old_path, destination)
	check("rebinding preserves the canonical handle", rebound.ok and registry.get_buffer_by_id(text_id.document_id) == buffer)
	var saved: Dictionary = await doc.handle("minerva_doc_save", {"document_id": buffer.document_id})
	check("save by document handle writes the rebound path", saved.success and FileAccess.get_file_as_string(destination) == "agent edit")
	registry.dispose_buffer(destination)
	check("disposed handles cannot load or guess a replacement", registry.get_buffer_by_id(text_id.document_id) == null)
	var reopened: DocumentBuffer = registry.get_or_create_buffer(destination).buffer
	check("reopening mints a new handle", reopened.document_id != text_id.document_id)
	registry.dispose_buffer(destination)
	registry.dispose_buffer(other.file_path)
	DirAccess.remove_absolute(destination)
	for view: Control in views:
		view.free()
	await _panel_route()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)


func _panel_route() -> void:
	var host = root.get_node("SingletonObject")
	var old_pane = host.editor_pane
	var old_broker = host.plugin_scene_panel_broker
	var pane = load("res://Scripts/UI/Views/EditorPane.gd").new()
	pane.Tabs = TabContainer.new()
	pane.add_child(pane.Tabs)
	host.editor_pane = pane
	var editor_script = load("res://Scripts/UI/Controls/Editor.gd")
	var text_view = editor_script.new()
	var render_view = editor_script.new()
	text_view.code_edit = EditorCodeEdit.new()
	text_view.add_child(text_view.code_edit)
	pane.Tabs.add_child(text_view)
	pane.Tabs.add_child(render_view)
	text_view.tab_title = "same.mcad"
	render_view.tab_title = "same.mcad"
	render_view.type = editor_script.Type.PLUGIN_SCENE
	render_view.plugin_id = "identity"
	render_view.plugin_panel_key = "identity-panel"
	var buffer: DocumentBuffer = DocumentRegistry.get_instance().create_unbacked_buffer().buffer
	text_view.bind_to_buffer_path(buffer.file_path)
	var broker = load("res://Scripts/Services/Plugins/PluginScenePanelBroker.gd").new(null, null, null, null)
	host.plugin_scene_panel_broker = broker
	var panel := IdentityPanel.new()
	root.add_child(panel)
	render_view.plugin_scene_root = panel
	render_view.plugin_save_mode = "host_owned"
	broker.register_panel(panel, "identity", "identity-panel", PackedStringArray(), "model", render_view)
	broker.attach_buffer_to_panel("identity", "identity-panel", buffer)
	check("buffer attachment carries canonical document identity", panel.last_document_id == buffer.document_id)
	buffer.apply_edit("shared source")
	check("buffer updates retain identity", panel.last_document_id == buffer.document_id)
	var registry = load("res://Scripts/Services/Plugins/PluginToolRegistry.gd").new()
	registry.scene_panel_broker = broker
	registry.register_plugin_tools("identity", [{"name": "minerva_identity_read", "executor": "panel",
		"input_schema": {"type": "object", "properties": {"editor_name": {"type": "string"}}, "required": ["editor_name"]}}])
	var by_doc: Dictionary = await registry.handle_tool_call("minerva_identity_read", {"document_id": buffer.document_id})
	check("generic plugin routing selects the document's render view", by_doc.get("selected", "") == "identity-panel")
	var doc = load("res://Scripts/Services/MCP/Modules/MCPDocTools.gd").new()
	var by_view: Dictionary = await doc.handle("minerva_doc_read", {"view_id": DocumentIdentity.handle(render_view, "view")})
	check("read by render view reaches the shared text buffer", by_view.get("text", "") == "shared source")
	var utils = load("res://Scripts/Services/MCP/Modules/MCPToolUtils.gd")
	check("legacy duplicate titles cannot select the first editor", utils.find_editor_by_name("same.mcad") == null)
	var listing = load("res://Scripts/Services/MCP/Modules/MCPEditorTools.gd").new()
	var listed: Dictionary = listing._list_editors({})
	check("editor listing exposes paired document and distinct view handles",
		listed.editors[0].document_id == listed.editors[1].document_id
		and listed.editors[0].view_id != listed.editors[1].view_id)
	var panel_host = load("res://Scripts/Services/Plugins/PluginScenePanelHost.gd")
	var documents := DocumentRegistry.get_instance()
	var destination := ProjectSettings.globalize_path("user://paired-save-test.mcad")
	var next_destination := ProjectSettings.globalize_path("user://paired-save-as-test.mcad")
	var source := "part = cube(12)\npart\n"
	buffer.apply_edit(source)
	var identity := buffer.document_id
	var version := buffer.version
	var saved: Dictionary = await doc.handle("minerva_doc_save", {
		"view_id": DocumentIdentity.handle(render_view, "view"), "path": destination})
	check("render Save As writes canonical DSL rather than panel JSON",
		saved.get("success", false) and FileAccess.get_file_as_string(destination) == source)
	check("render Save As preserves shared buffer identity and source revision",
		documents.get_buffer_by_id(identity) == buffer and buffer.version == version
		and text_view.get_document_buffer() == buffer and broker.get_attached_buffer("identity", "identity-panel") == buffer)
	check("render save updates both paired wrappers and the text saved snapshot",
		text_view.file == destination and render_view.file == destination
		and text_view.code_edit.saved_content == source and not buffer.dirty)
	check("project snapshots retain rich plugin state", panel_host.invoke_save(panel, {}) == panel.snapshot)
	var edited_source := source.replace("12", "14")
	buffer.apply_edit(edited_source)
	check("text Save As succeeds through real editor", await text_view.save_file_to_disc(next_destination))
	check("text Save As retains the pair and updates both paths",
		buffer.file_path == next_destination and render_view.file == next_destination
		and text_view.file == next_destination and buffer.document_id == identity
		and FileAccess.get_file_as_string(next_destination) == edited_source
		and FileAccess.get_file_as_string(destination) == source)
	var occupied: DocumentBuffer = documents.get_or_create_buffer(destination).buffer
	var rejected := documents.save_buffer_as(buffer, destination)
	check("Save As refuses another live document without changing either buffer",
		not rejected.ok and buffer.file_path == next_destination and occupied.text == source)
	var failed_save := documents.save_buffer_as(buffer, next_destination + "/child.mcad")
	check("failed disk write restores the original shared binding",
		not failed_save.ok and buffer.file_path == next_destination and text_view.file == next_destination)
	documents.dispose_buffer(destination)
	broker.unregister_panel("identity", "identity-panel")
	text_view._detach_document_buffer()
	var reopened: DocumentBuffer = documents.get_or_create_buffer(next_destination).buffer
	check("closing and reopening reads plain DSL with a new live identity",
		reopened.text == edited_source and reopened.document_id != identity)
	documents.dispose_buffer(next_destination)
	# Standalone plugins keep their existing JSON and byte-exact file contract.
	check("unpaired plugin saves JSON", panel_host.save_file(render_view, destination, broker).ok
		and JSON.parse_string(FileAccess.get_file_as_string(destination)) == panel.snapshot)
	panel.snapshot = {"_bytes": PackedByteArray([0, 255, 13, 10])}
	check("unpaired plugin saves raw bytes", panel_host.save_file(render_view, destination, broker).ok
		and FileAccess.get_file_as_bytes(destination) == panel.snapshot._bytes)
	DirAccess.remove_absolute(destination)
	DirAccess.remove_absolute(next_destination)

	text_view._detach_document_buffer()
	host.editor_pane = old_pane
	host.plugin_scene_panel_broker = old_broker
	panel.queue_free()
	pane.free()
