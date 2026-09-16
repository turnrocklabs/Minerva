extends Node

signal completed(exit_code: int)

class View extends Control:
	var buffer: DocumentBuffer
	var type := Editor.Type.TEXT
	var plugin_id := ""
	var plugin_panel_key := ""
	var tab_title := "same.mcad"
	func get_document_buffer() -> DocumentBuffer:
		return buffer

class IdentityPanel extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)
	var last_document_id := ""
	var snapshot := {"source": "stale panel source", "build_mode": "manual",
		"last_eval": {"status": "ok", "shape_name": "shared"}}
	var apply_result := {"ok": true,
		"last_eval": {"status": "ok", "shape_name": "shared"}}
	func _on_panel_save_request() -> Dictionary:
		return snapshot
	func receive(_channel: String, payload: Dictionary) -> void:
		last_document_id = str(payload.get("document_id", ""))
	func _on_panel_apply_sync(_document: Variant) -> Dictionary:
		return apply_result.duplicate(true)
	func handle_tool(_tool: String, args: Dictionary) -> Dictionary:
		return {"success": true, "selected": args.editor_name}

class IdentityCadHost extends AnnotationHost:
	func get_registry() -> AnnotationRegistry:
		return null
	func transform_doc_to_screen(point: Vector2) -> Vector2:
		return point
	func get_view_context() -> String:
		return "cad:iso"
	func describe_point(_point: Vector2) -> String:
		return ""
	func render_content_to_image(_viewport_rect: Rect2) -> Image:
		return null
	func get_mesh_data() -> Dictionary:
		return {"vertices": [[-2.0, -3.0, 0.0], [2.0, 3.0, 5.0]], "faces": []}

class IdentityCadPanel extends IdentityPanel:
	var annotation_host := IdentityCadHost.new()
	func get_annotation_host() -> AnnotationHost:
		return annotation_host

class CountingToolManager extends RefCounted:
	var calls := 0
	var response: Dictionary = {}
	var workflow_activations: Array[Array] = []
	var workflow_response: Dictionary = {}
	func execute_tool(_tool_name: String, _arguments: Dictionary,
			_caller_chat_id: String) -> Dictionary:
		calls += 1
		return response.duplicate(true)
	func activate_tools_for_workflow(names: Array[String], _history = null) -> Dictionary:
		workflow_activations.append(names.duplicate())
		if not workflow_response.is_empty():
			return workflow_response.duplicate(true)
		return {"activated": names.duplicate(), "unavailable": [], "available": true}

var passed := 0
var failed := 0
func check(label: String, ok: bool) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: " + label)

func _ready() -> void:
	await get_tree().process_frame
	var registry := DocumentRegistry.get_instance()
	var buffer: DocumentBuffer = registry.create_unbacked_buffer().buffer
	var other: DocumentBuffer = registry.create_unbacked_buffer().buffer
	var text_view := View.new()
	text_view.buffer = buffer
	var render_view := View.new()
	render_view.buffer = buffer
	render_view.type = Editor.Type.PLUGIN_SCENE
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
	check("plugin operation maps an explicit source view to its paired render view",
		DocumentIdentity.resolve({"view_id": text_id.view_id}, views, null, "cad").editor == render_view)
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
	completed.emit(1 if failed else 0)


func _panel_route() -> void:
	var host = get_tree().root.get_node("SingletonObject")
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
	get_tree().root.add_child(panel)
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
		"input_schema": {"type": "object", "additionalProperties": false,
			"properties": {"editor_name": {"type": "string"}},
			"required": ["editor_name"]}}])
	var by_doc: Dictionary = await registry.handle_tool_call("minerva_identity_read", {"document_id": buffer.document_id})
	check("strict native schemas receive only the canonical panel locator",
		by_doc.get("selected", "") == "identity-panel")
	var by_source_view: Dictionary = await registry.handle_tool_call(
		"minerva_identity_read", {"view_id": DocumentIdentity.handle(text_view, "view")})
	check("panel tools accept the paired source view and dispatch to its render panel",
		by_source_view.get("selected", "") == "identity-panel")
	var doc = load("res://Scripts/Services/MCP/Modules/MCPDocTools.gd").new()
	var by_view: Dictionary = await doc.handle("minerva_doc_read", {"view_id": DocumentIdentity.handle(render_view, "view")})
	check("read by render view reaches the shared text buffer and advertises whole-document operations",
		by_view.get("text", "") == "shared source"
		and not (by_view.get("supported_operations", []) as Array).has("minerva_doc_edit")
		and by_view.get("last_eval", {}).get("shape_name") == "shared")
	var by_document: Dictionary = await doc.handle("minerva_doc_read", {
		"document_id": buffer.document_id})
	check("canonical document reads use the owning plugin view for evaluation status",
		by_document.get("last_eval", {}).get("status") == "ok")
	var unsupported: Dictionary = await doc.handle("minerva_doc_edit", {
		"view_id": DocumentIdentity.handle(text_view, "view"),
		"old_string": "shared", "new_string": "changed"})
	check("a paired structured document refuses partial edits through either view",
		unsupported.get("error_code") == "operation_unsupported"
		and unsupported.get("retryable") == false
		and unsupported.get("next_tool") == "minerva_doc_write"
		and unsupported.get("document_identity", {}).get("document_id") == buffer.document_id
		and buffer.text == "shared source")
	var recovered: Dictionary = await doc.handle("minerva_doc_write", {
		"view_id": DocumentIdentity.handle(text_view, "view"), "text": "whole source"})
	check("the advertised whole-document recovery writes the canonical buffer",
		recovered.get("success", false) and buffer.text == "whole source"
		and recovered.get("last_eval", {}).get("status") == "ok")
	var path_recovery: Dictionary = await doc.handle("minerva_doc_write", {
		"path": buffer.file_path, "text": "path source"})
	var path_read: Dictionary = await doc.handle("minerva_doc_read", {
		"path": buffer.file_path})
	check("path recovery and read also route through the owning plugin view",
		path_recovery.get("last_eval", {}).get("status") == "ok"
		and path_read.get("last_eval", {}).get("shape_name") == "shared")
	panel.apply_result = {"ok": false, "last_eval": {"status": "error",
		"error_kind": "parse", "error_message": "bad CAD source"}}
	var failed_recovery: Dictionary = await doc.handle("minerva_doc_write", {
		"document_id": buffer.document_id, "text": "broken source"})
	check("canonical recovery propagates owning plugin evaluation failure",
		failed_recovery.get("success") == false
		and failed_recovery.get("last_eval", {}).get("error_message") == "bad CAD source")
	panel.apply_result = {"ok": true,
		"last_eval": {"status": "ok", "shape_name": "shared"}}
	buffer.apply_edit("shared source")
	var utils = load("res://Scripts/Services/MCP/Modules/MCPToolUtils.gd")
	check("legacy duplicate titles cannot select the first editor", utils.find_editor_by_name("same.mcad") == null)
	var listing = load("res://Scripts/Services/MCP/Modules/MCPEditorTools.gd").new()
	var listed: Dictionary = listing._list_editors({})
	check("editor listing exposes paired document and distinct view handles",
		listed.editors[0].document_id == listed.editors[1].document_id
		and listed.editors[0].view_id != listed.editors[1].view_id
		and not (listed.editors[0].supported_operations as Array).has("minerva_doc_edit")
		and not (listed.editors[1].supported_operations as Array).has("minerva_doc_edit"))
	var cad_panel := IdentityCadPanel.new()
	get_tree().root.add_child(cad_panel)
	var cad_buffer: DocumentBuffer = DocumentRegistry.get_instance() \
		.create_unbacked_buffer().buffer
	var cad_source_view = editor_script.new()
	cad_source_view.code_edit = EditorCodeEdit.new()
	cad_source_view.add_child(cad_source_view.code_edit)
	pane.Tabs.add_child(cad_source_view)
	cad_source_view.bind_to_buffer_path(cad_buffer.file_path)
	var cad_source_tab: int = pane.Tabs.get_tab_idx_from_control(cad_source_view)
	pane.Tabs.set_tab_title(cad_source_tab, "cad-source.mcad")
	cad_source_view.tab_title = "cad-source.mcad"
	var cad_view = editor_script.new()
	cad_view.type = editor_script.Type.PLUGIN_SCENE
	cad_view.plugin_id = "cad"
	cad_view.plugin_panel_key = "cad-panel"
	cad_view.plugin_scene_root = cad_panel
	pane.Tabs.add_child(cad_view)
	broker.register_panel(cad_panel, "cad", "cad-panel", PackedStringArray(),
		"model", cad_view)
	broker.attach_buffer_to_panel("cad", "cad-panel", cad_buffer)
	var cad_profile := DocumentIdentity.operation_profile(cad_source_view, broker,
		[cad_source_view, cad_view])
	check("paired CAD identity advertises explicit full-write guidance",
		str(cad_profile.get("write_guidance", "")).contains("minerva_doc_write")
		and str(cad_profile.get("write_guidance", "")).contains("last_eval"))
	var cad_tools = load(
		"res://Scripts/Services/MCP/Modules/MCPCadTools.gd").new(null)
	var legacy_source_target: Dictionary = await cad_tools.handle(
		"minerva_cad_get_mesh_info", {"editor_name": "cad-source.mcad"})
	check("legacy CAD inspection maps a unique source-tab name to its paired panel",
		legacy_source_target.get("success", false)
		and legacy_source_target.get("vertex_count", 0) == 2)
	broker.unregister_panel("cad", "cad-panel")
	cad_source_view._detach_document_buffer()
	DocumentRegistry.get_instance().dispose_buffer(cad_buffer.file_path)
	cad_source_view.free()
	cad_view.free()
	cad_panel.queue_free()
	render_view.plugin_save_mode = "none"
	var no_save: Dictionary = await doc.handle("minerva_doc_read", {
		"document_id": buffer.document_id})
	var no_save_list: Dictionary = listing._list_editors({})
	var no_save_call: Dictionary = await doc.handle("minerva_doc_save", {
		"document_id": buffer.document_id})
	check("save_mode none is omitted from list/read supported operations",
		not (DocumentIdentity.operation_profile(render_view, broker,
			pane.get_open_editors()).supported_operations as Array).has("minerva_doc_save")
		and not (no_save.supported_operations as Array).has("minerva_doc_save")
		and not (no_save_list.editors[0].supported_operations as Array).has("minerva_doc_save")
		and not (no_save_list.editors[1].supported_operations as Array).has("minerva_doc_save")
		and str(no_save_call.get("error", "")).contains("document_save_unsupported"))
	render_view.plugin_save_mode = "plugin_owned"
	var plugin_save_read: Dictionary = await doc.handle("minerva_doc_read", {
		"view_id": DocumentIdentity.handle(text_view, "view")})
	var plugin_save_list: Dictionary = listing._list_editors({})
	check("plugin_owned save is not advertised as a host document operation",
		not (DocumentIdentity.operation_profile(text_view, broker,
			pane.get_open_editors()).supported_operations as Array).has("minerva_doc_save")
		and not (plugin_save_read.supported_operations as Array).has("minerva_doc_save")
		and not (plugin_save_list.editors[0].supported_operations as Array).has("minerva_doc_save")
		and not (plugin_save_list.editors[1].supported_operations as Array).has("minerva_doc_save"))
	render_view.plugin_save_mode = "host_owned"
	await _chatpane_recovery_route(pane, text_view, buffer, editor_script)
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


func _chatpane_recovery_route(pane, text_view, buffer: DocumentBuffer,
		editor_script) -> void:
	var ChatPaneScript = load("res://Scripts/UI/Views/ChatPane.gd")
	var Guard = load("res://Scripts/Services/MCP/MCPUnsupportedOperationGuard.gd")
	var view_id := DocumentIdentity.handle(text_view, "view")
	var by_view: Dictionary = ChatPaneScript._live_document_identity(
		"minerva_doc_edit", {"view_id": view_id})
	var by_document: Dictionary = ChatPaneScript._live_document_identity(
		"minerva_doc_edit", {"document_id": buffer.document_id})
	var text_tab: int = pane.Tabs.get_tab_idx_from_control(text_view)
	pane.Tabs.set_tab_title(text_tab, "Former CAD title")
	text_view.tab_title = "Former CAD title"
	var by_title: Dictionary = ChatPaneScript._live_document_identity(
		"minerva_doc_edit", {"editor_name": "Former CAD title"})
	check("ChatPane resolves live document and view locators to one canonical identity",
		by_view.get("document_id") == buffer.document_id
		and by_document.get("document_id") == buffer.document_id
		and by_title.get("document_id") == buffer.document_id)
	var refusal := {
		"success": false,
		"error": "structured document",
		"error_code": "operation_unsupported",
		"retryable": false,
		"next_tool": "minerva_doc_write",
		"document_identity": {"document_id": buffer.document_id},
	}
	var manager := CountingToolManager.new()
	manager.response = refusal
	var guard = Guard.new()
	var first: Dictionary = await ChatPaneScript._execute_with_document_recovery(
		manager, guard, "minerva_doc_edit", {"editor_name": "Former CAD title"},
		by_title, 0, "chat-a")
	var second: Dictionary = await ChatPaneScript._execute_with_document_recovery(
		manager, guard, "minerva_doc_edit", {"view_id": view_id}, by_view, 1, "chat-a")
	check("ChatPane returns the first refusal then terminates an alias retry without execution",
		first.get("error_code") == "operation_unsupported"
		and first.get("recovery_tools", []) == ["minerva_doc_read", "minerva_doc_write"]
		and manager.workflow_activations.size() == 1
		and second.get("terminate_tool_loop", false) and manager.calls == 1)
	var unavailable_manager := CountingToolManager.new()
	unavailable_manager.response = refusal
	unavailable_manager.workflow_response = {"activated": ["minerva_doc_read"],
		"unavailable": [{"name": "minerva_doc_write", "reason": "budget"}],
		"available": false}
	var unavailable_recovery: Dictionary = await \
		ChatPaneScript._execute_with_document_recovery(unavailable_manager, Guard.new(),
			"minerva_doc_edit", {"view_id": view_id}, by_view, 0, "chat-a")
	check("a refused recovery names the advertised tool that could not be activated",
		not unavailable_recovery.get("recovery_available", true)
		and unavailable_recovery.get("recovery_message", "").contains("minerva_doc_write"))
	var batch_manager := CountingToolManager.new()
	batch_manager.response = refusal
	var batch_guard = Guard.new()
	var batch_results: Array[Dictionary] = []
	for replacement in ["14", "16"]:
		batch_results.append(await ChatPaneScript._execute_with_document_recovery(
			batch_manager, batch_guard, "minerva_doc_edit",
			{"view_id": view_id, "new_string": replacement}, by_view, 0, "chat-a"))
	check("same-response batch calls each receive a result before the model sees the refusal",
		batch_results.size() == 2 and batch_manager.calls == 2
		and batch_results[0].get("error_code") == "operation_unsupported"
		and batch_results[1].get("error_code") == "operation_unsupported")
	var other: DocumentBuffer = DocumentRegistry.get_instance().create_unbacked_buffer().buffer
	pane.Tabs.set_tab_title(text_tab, "Current CAD title")
	text_view.tab_title = "Current CAD title"
	var other_view = editor_script.new()
	other_view.code_edit = EditorCodeEdit.new()
	other_view.add_child(other_view.code_edit)
	other_view.bind_to_buffer_path(other.file_path)
	pane.Tabs.add_child(other_view)
	pane.Tabs.set_tab_title(pane.Tabs.get_tab_count() - 1, "Former CAD title")
	var unrelated: Dictionary = ChatPaneScript._live_document_identity(
		"minerva_doc_edit", {"editor_name": "Former CAD title"})
	manager.response = {"success": true}
	var allowed: Dictionary = await ChatPaneScript._execute_with_document_recovery(
		manager, guard, "minerva_doc_edit", {"editor_name": "Former CAD title"},
		unrelated, 1, "chat-a")
	var next_turn: Dictionary = await ChatPaneScript._execute_with_document_recovery(
		manager, Guard.new(), "minerva_doc_edit", {"document_id": buffer.document_id},
		by_document, 1, "chat-b")
	check("a current title on another document and a new chat turn remain executable",
		allowed.get("success", false) and next_turn.get("success", false)
		and manager.calls == 3)
	var panel_canonical = editor_script.new()
	panel_canonical.type = editor_script.Type.PLUGIN_SCENE
	panel_canonical.plugin_id = "panel-only"
	panel_canonical.plugin_panel_key = "panel-only-view"
	pane.Tabs.add_child(panel_canonical)
	var panel_identity := DocumentIdentity.describe(panel_canonical,
		get_tree().root.get_node("SingletonObject").plugin_scene_panel_broker)
	var resolved_panel: Dictionary = ChatPaneScript._live_document_identity(
		"minerva_doc_edit", {"document_id": panel_identity.document_id})
	var panel_manager := CountingToolManager.new()
	panel_manager.response = refusal.duplicate(true)
	panel_manager.response["document_identity"] = panel_identity
	var panel_guard = Guard.new()
	await ChatPaneScript._execute_with_document_recovery(panel_manager, panel_guard,
		"minerva_doc_edit", {"document_id": panel_identity.document_id},
		resolved_panel, 0, "chat-panel")
	var panel_repeat: Dictionary = await ChatPaneScript._execute_with_document_recovery(
		panel_manager, panel_guard, "minerva_doc_edit",
		{"document_id": panel_identity.document_id}, resolved_panel, 1, "chat-panel")
	check("unbuffered plugin-scene document handles stop a repeated dispatch",
		resolved_panel.get("document_id") == panel_identity.document_id
		and panel_repeat.get("terminate_tool_loop", false) and panel_manager.calls == 1)
	pane.Tabs.remove_child(panel_canonical)
	panel_canonical.free()
	other_view._detach_document_buffer()
	pane.Tabs.remove_child(other_view)
	other_view.free()
	DocumentRegistry.get_instance().dispose_buffer(other.file_path)
