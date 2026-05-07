class_name MCPDocTools
extends MCPToolModule
## MCP tool module for document-canonical read/write/edit/save.
##
## Each tool accepts either `path` or `editor_name` as the buffer key (exactly
## one). Path-keyed calls route through DocumentRegistry. Editor-keyed calls
## resolve the editor by tab_title and dispatch to:
##   - DocumentRegistry buffer when the editor has a bound file path (TEXT)
##   - editor.code_edit.text directly for anonymous TEXT editors
##   - (Slice 2) plugin-scene IPC channels for PLUGIN_SCENE editors
##
## After Save-As, the editor's tab_title changes; doc_save returns the
## post-save editor_name so the LLM can update its key.


func _init(mcp_server = null) -> void:
	super._init(mcp_server)


func get_tool_names() -> Array[String]:
	return [
		"minerva_doc_read",
		"minerva_doc_write",
		"minerva_doc_edit",
		"minerva_doc_save",
		"minerva_doc_save_all",
	]


func register_tools() -> void:
	server._register_tool("minerva_doc_read",
		"Read a document's text. Pass either `path` (absolute file path) or `editor_name` (the tab title). Path-keyed reads load from disk into the registry on first access. Editor-keyed reads return the visible text of an editor tab — works for both path-bound and anonymous (unsaved) editors. Returns not_found when neither buffer, file, nor named editor exists.",
		_dual_key_schema({
			"text": {"type": "string"},
			"version": {"type": "integer"},
			"dirty": {"type": "boolean"},
		}, []), "documents")

	server._register_tool("minerva_doc_write",
		"Replace a document's full text. Pass either `path` or `editor_name` (exactly one). Buffer/editor becomes dirty; disk is NOT modified until minerva_doc_save. Creates a buffer if needed for path. For editor_name on an anonymous editor, sets the editor's visible text directly. Returns the resolved {path?, editor_name?} so callers know which key to use next.",
		_dual_key_schema({
			"text": {"type": "string", "description": "Full text content"},
		}, ["text"]), "documents")

	server._register_tool("minerva_doc_edit",
		"Replace one occurrence of old_string with new_string. Pass either `path` or `editor_name`. old_string must match exactly once. NOT supported on plugin-scene editors (use minerva_doc_write to replace the whole document instead).",
		_dual_key_schema({
			"old_string": {"type": "string", "description": "String to find (must be unique)"},
			"new_string": {"type": "string", "description": "Replacement string"},
		}, ["old_string", "new_string"]), "documents")

	server._register_tool("minerva_doc_save",
		"Flush a document to disk. Pass either `path` or `editor_name`. With editor_name, an optional `path` argument performs Save-As (binds the editor to that path). For an unbound (anonymous) editor `path` is REQUIRED. Returns {path, editor_name} after save — note that Save-As renames the tab, so the returned editor_name may differ from the one passed in.",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "Absolute file path. Required for path-keyed save. Optional for editor_name save (triggers Save-As when present)."},
			"editor_name": {"type": "string", "description": "Tab title of the editor. Alternative key to path."},
		}}, "documents")

	server._register_tool("minerva_doc_save_all",
		"Flush every dirty document buffer to disk. Returns saved_paths and any failures.",
		{"type": "object", "properties": {}}, "documents")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_doc_read": return _doc_read(arguments)
		"minerva_doc_write": return _doc_write(arguments)
		"minerva_doc_edit": return _doc_edit(arguments)
		"minerva_doc_save": return _doc_save(arguments)
		"minerva_doc_save_all": return _doc_save_all(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


# ── Dual-key resolver ──────────────────────────────────────────────────────

const KIND_BUFFER := "buffer"           # path-keyed; DocumentRegistry buffer
const KIND_TEXT_LOCAL := "text_local"   # editor-keyed; anonymous TEXT
const KIND_PLUGIN_SCENE := "plugin_scene"  # editor-keyed; PLUGIN_SCENE (Slice 2)


## Returns {ok, error?, kind, buffer?, editor?, path, editor_name}.
##
## - kind=="buffer": buffer is loaded from registry; path is the resolved path.
## - kind=="text_local": editor is the TEXT editor; path is "" (anonymous).
## - kind=="plugin_scene": editor is the PLUGIN_SCENE editor; Slice 2.
##
## When an editor_name resolves to an editor that DOES have a bound file path,
## we promote it to KIND_BUFFER so reads/writes go through the registry —
## anything attached to that path stays in sync.
func _resolve_target(args: Dictionary, require_existing: bool) -> Dictionary:
	var path: String = str(args.get("path", "")).strip_edges()
	var editor_name: String = str(args.get("editor_name", "")).strip_edges()

	var have_path := not path.is_empty()
	var have_name := not editor_name.is_empty()

	if have_path and have_name:
		return {"ok": false, "error": "pass either `path` or `editor_name`, not both"}
	if not have_path and not have_name:
		return {"ok": false, "error": "either `path` or `editor_name` is required"}

	if have_path:
		var registry := DocumentRegistry.get_instance()
		if require_existing and not registry.has_buffer(path) and not DiskAccess.exists(path):
			return {"ok": false, "error": "not_found: %s" % path}
		var r := registry.get_or_create_buffer(path)
		if not r.ok:
			return {"ok": false, "error": r.error}
		return {
			"ok": true,
			"kind": KIND_BUFFER,
			"buffer": r.buffer,
			"editor": null,
			"path": path,
			"editor_name": "",
		}

	# Editor-keyed
	var editor: Variant = MCPToolUtils.find_editor_by_name(editor_name)
	if editor == null:
		return {"ok": false, "error": "editor_not_found: %s" % editor_name}

	var ed_type: int = -1
	if "type" in editor:
		ed_type = int(editor.type)

	# PLUGIN_SCENE → Slice 2 (not yet wired).
	if ed_type == Editor.Type.PLUGIN_SCENE:
		return {
			"ok": true,
			"kind": KIND_PLUGIN_SCENE,
			"buffer": null,
			"editor": editor,
			"path": str(editor.file) if "file" in editor else "",
			"editor_name": editor_name,
		}

	# TEXT (or any code_edit-backed editor): if a file path is bound, prefer
	# the registry buffer so multiple panels stay in sync.
	var ed_path: String = str(editor.file) if "file" in editor else ""
	if not ed_path.is_empty():
		var registry2 := DocumentRegistry.get_instance()
		var r2 := registry2.get_or_create_buffer(ed_path)
		if r2.ok:
			return {
				"ok": true,
				"kind": KIND_BUFFER,
				"buffer": r2.buffer,
				"editor": editor,
				"path": ed_path,
				"editor_name": editor_name,
			}
		# Fall through to text_local if registry refused (rare).

	# Anonymous (or registry-refused) TEXT editor → operate on code_edit.text.
	if not ("code_edit" in editor) or editor.code_edit == null:
		return {"ok": false, "error": "editor '%s' has no text content (kind=%d)" % [editor_name, ed_type]}
	return {
		"ok": true,
		"kind": KIND_TEXT_LOCAL,
		"buffer": null,
		"editor": editor,
		"path": "",
		"editor_name": editor_name,
	}


## Build the JSON schema for tools that accept either path OR editor_name.
## extra_props: additional non-key properties (e.g. text, old_string).
## extra_required: which of those are required (key fields are NOT — they're
## checked in _resolve_target).
static func _dual_key_schema(extra_props: Dictionary, extra_required: Array) -> Dictionary:
	var props := {
		"path": {"type": "string", "description": "Absolute file path (alternative to editor_name)"},
		"editor_name": {"type": "string", "description": "Tab title of the editor (alternative to path)"},
	}
	props.merge(extra_props)
	return {"type": "object", "properties": props, "required": extra_required}


# ── Tool implementations ───────────────────────────────────────────────────

func _doc_read(args: Dictionary) -> Dictionary:
	var t := _resolve_target(args, true)
	if not t.ok:
		return _err(t.error)

	match t.kind:
		KIND_BUFFER:
			var buf: DocumentBuffer = t.buffer
			return _ok({
				"text": buf.text,
				"version": buf.version,
				"dirty": buf.dirty,
				"path": t.path,
				"editor_name": t.editor_name,
			})
		KIND_TEXT_LOCAL:
			var editor = t.editor
			return _ok({
				"text": editor.code_edit.text,
				"version": 0,
				"dirty": _editor_is_dirty(editor),
				"path": "",
				"editor_name": t.editor_name,
			})
		KIND_PLUGIN_SCENE:
			return _err("plugin_scene_unsupported: minerva_doc_read on plugin-scene editors lands in Slice 2")
	return _err("unhandled kind: %s" % t.kind)


func _doc_write(args: Dictionary) -> Dictionary:
	if not args.has("text"):
		return _err("text is required")
	var text: String = args.get("text", "")

	var t := _resolve_target(args, false)
	if not t.ok:
		return _err(t.error)

	match t.kind:
		KIND_BUFFER:
			var buf: DocumentBuffer = t.buffer
			buf.apply_edit(text)
			return _ok({
				"version": buf.version,
				"dirty": buf.dirty,
				"path": t.path,
				"editor_name": t.editor_name,
			})
		KIND_TEXT_LOCAL:
			var editor = t.editor
			editor.code_edit.text = text
			editor.code_edit.text_changed.emit()
			return _ok({
				"version": 0,
				"dirty": true,
				"path": "",
				"editor_name": t.editor_name,
			})
		KIND_PLUGIN_SCENE:
			return _err("plugin_scene_unsupported: minerva_doc_write on plugin-scene editors lands in Slice 2")
	return _err("unhandled kind: %s" % t.kind)


func _doc_edit(args: Dictionary) -> Dictionary:
	if not args.has("old_string"):
		return _err("old_string is required")
	if not args.has("new_string"):
		return _err("new_string is required")
	var old_str: String = args.get("old_string", "")
	var new_str: String = args.get("new_string", "")

	var t := _resolve_target(args, true)
	if not t.ok:
		return _err(t.error)

	if t.kind == KIND_PLUGIN_SCENE:
		return _err("plugin_scene_unsupported: minerva_doc_edit cannot string-replace a structured plugin document; use minerva_doc_write to replace the whole document")

	# Both KIND_BUFFER and KIND_TEXT_LOCAL operate on a string; unify.
	var current_text: String = ""
	match t.kind:
		KIND_BUFFER:
			current_text = (t.buffer as DocumentBuffer).text
		KIND_TEXT_LOCAL:
			current_text = t.editor.code_edit.text

	var idx := current_text.find(old_str)
	if idx == -1:
		return _err("old_string not found in buffer")
	var second := current_text.find(old_str, idx + old_str.length())
	if second != -1:
		return _err("old_string is not unique in buffer (matches at offsets %d and %d)" % [idx, second])

	var new_text := current_text.substr(0, idx) + new_str + current_text.substr(idx + old_str.length())

	match t.kind:
		KIND_BUFFER:
			var buf: DocumentBuffer = t.buffer
			buf.apply_edit(new_text)
			return _ok({
				"version": buf.version,
				"dirty": buf.dirty,
				"path": t.path,
				"editor_name": t.editor_name,
			})
		KIND_TEXT_LOCAL:
			t.editor.code_edit.text = new_text
			t.editor.code_edit.text_changed.emit()
			return _ok({
				"version": 0,
				"dirty": true,
				"path": "",
				"editor_name": t.editor_name,
			})
	return _err("unhandled kind: %s" % t.kind)


func _doc_save(args: Dictionary) -> Dictionary:
	var path_arg: String = str(args.get("path", "")).strip_edges()
	var editor_name: String = str(args.get("editor_name", "")).strip_edges()
	var have_path := not path_arg.is_empty()
	var have_name := not editor_name.is_empty()

	if not have_path and not have_name:
		return _err("either `path` or `editor_name` is required")

	# Pure path-keyed save (legacy contract): require an existing buffer.
	if have_path and not have_name:
		var registry := DocumentRegistry.get_instance()
		if not registry.has_buffer(path_arg):
			return _err("no buffer for path: %s" % path_arg)
		var r := registry.get_or_create_buffer(path_arg)
		if not r.ok:
			return _err(r.error)
		var save_r := (r.buffer as DocumentBuffer).save_to_disk()
		if not save_r.ok:
			return _err(save_r.error)
		return _ok({"path": path_arg, "editor_name": ""})

	# Editor-keyed save (with optional path for Save-As).
	var editor: Variant = MCPToolUtils.find_editor_by_name(editor_name)
	if editor == null:
		return _err("editor_not_found: %s" % editor_name)

	var ed_type: int = int(editor.type) if "type" in editor else -1
	if ed_type == Editor.Type.PLUGIN_SCENE:
		return _err("plugin_scene_unsupported: minerva_doc_save on plugin-scene editors lands in Slice 2")

	var ed_file: String = str(editor.file) if "file" in editor else ""

	# Anonymous editor: path is required to bind it (Save-As).
	if ed_file.is_empty() and not have_path:
		return _err("editor '%s' is anonymous; pass `path` to bind via Save-As" % editor_name)

	# Light path: path-bound editor, no Save-As → flush its buffer.
	if not ed_file.is_empty() and (not have_path or path_arg == ed_file):
		var registry2 := DocumentRegistry.get_instance()
		if registry2.has_buffer(ed_file):
			var r2 := registry2.get_or_create_buffer(ed_file)
			if r2.ok:
				var save_r2 := (r2.buffer as DocumentBuffer).save_to_disk()
				if not save_r2.ok:
					return _err(save_r2.error)
				return _ok({"path": ed_file, "editor_name": str(editor.tab_title)})
		# No buffer? Fall through to editor.save_file_to_disc.

	# Heavy path: Save-As (or first-save of anonymous), or no buffer for ed_file.
	# Editor.save_file_to_disc handles binding `file`, attaching the buffer,
	# mirroring code_edit.text into it, persisting, AND renaming tab_title.
	var save_target := path_arg if have_path else ed_file
	editor.save_file_to_disc(save_target)
	# tab_title may have changed; return the post-save value.
	return _ok({"path": save_target, "editor_name": str(editor.tab_title)})


func _doc_save_all(_args: Dictionary) -> Dictionary:
	var registry := DocumentRegistry.get_instance()
	var dirty_paths := registry.list_dirty_buffer_paths()
	var saved: Array = []
	var failures: Array = []

	for path in dirty_paths:
		var r := registry.get_or_create_buffer(path)
		if not r.ok:
			failures.append({"path": path, "error": r.error})
			continue
		var buf: DocumentBuffer = r.buffer
		var save_r := buf.save_to_disk()
		if save_r.ok:
			saved.append(path)
		else:
			failures.append({"path": path, "error": save_r.error})

	return _ok({
		"saved_paths": saved,
		"failures": failures,
	})


# ── Helpers ────────────────────────────────────────────────────────────────

## Best-effort dirty flag for an anonymous TEXT editor. We don't track an
## explicit dirty bit here — code_edit's saved_content reflects the last save.
static func _editor_is_dirty(editor) -> bool:
	if not ("code_edit" in editor) or editor.code_edit == null:
		return false
	var saved: String = ""
	if "saved_content" in editor.code_edit:
		saved = str(editor.code_edit.saved_content)
	return editor.code_edit.text != saved


# ── Local response helpers (mirror MCPToolUtils to stay headless-testable) ──

static func _ok(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


static func _err(msg: String) -> Dictionary:
	return {"error": msg, "success": false}
