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
		"minerva_journal_mark",
		"minerva_journal_changes",
		"minerva_journal_diff",
		"minerva_journal_revert",
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
		"Replace a document's full text. Pass either `path` or `editor_name` (exactly one). Buffer/editor becomes dirty; disk is NOT modified until minerva_doc_save. Creates a buffer if needed for path. For editor_name on an anonymous editor, sets the editor's visible text directly. For plugin-scene editors (e.g. cad): plain text is wrapped as {\"source\": text} — pass DSL as-is without JSON-stringifying; pass a JSON object literal if you need fuller control over the Dictionary the plugin receives. Returns the resolved {path?, editor_name?} so callers know which key to use next.",
		_dual_key_schema({
			"text": {"type": "string", "description": "Full text content"},
			"save": {"type": "boolean", "description": "Also flush to disk now (default false = buffered, persist later via minerva_doc_save)."},
		}, ["text"]), "documents")

	server._register_tool("minerva_doc_edit",
		"Replace old_string with new_string. Pass either `path` or `editor_name`. Without replace_all, old_string must match exactly once. NOT supported on plugin-scene editors (use minerva_doc_write to replace the whole document instead).",
		_dual_key_schema({
			"old_string": {"type": "string", "description": "String to find (must be unique unless replace_all)"},
			"new_string": {"type": "string", "description": "Replacement string"},
			"replace_all": {"type": "boolean", "description": "Replace every occurrence instead of requiring a unique match (default false)."},
			"save": {"type": "boolean", "description": "Also flush to disk now (default false)."},
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

	server._register_tool("minerva_journal_mark",
		"Start a new change-journal CHANGESET: re-baseline every tracked file to its current text so subsequent edits are 'what changed since this mark'. Call this before an edit batch you want to review as a unit (work item 019ea01719a2). Returns {label, seq}.",
		{"type": "object", "properties": {
			"label": {"type": "string", "description": "Changeset label, e.g. 'fix-auth' or 'turn:7'. Default 'manual'."},
			"source": {"type": "string", "description": "Who drives this changeset: 'ai' or 'human'. Optional."},
		}}, "documents")

	server._register_tool("minerva_journal_changes",
		"Overview of the CURRENT change-journal changeset: the files changed since the last mark, each with add/del counts and attribution (ai/human). The review launcher. Returns {label, source, seq, files:[{path,adds,dels,source}]}.",
		{"type": "object", "properties": {}}, "documents")

	server._register_tool("minerva_journal_diff",
		"Structured line diff for ONE file in the current changeset (baseline-vs-current): added line indices + removed {after_index,text} (for ghost rows) + counts + attribution. Backs the native review render. Returns the diff dict.",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "Absolute file path of a changed file (see minerva_journal_changes)."},
		}, "required": ["path"]}, "documents")

	server._register_tool("minerva_journal_revert",
		"UNDO journal changes by restoring the current-changeset BASELINE. Pass `path` for ONE file, or omit it to revert EVERY changed file in the changeset (the 'undo the agent's turn' arm). Optional `source` (e.g. 'ai') reverts only files whose last edit was by that source, preserving files the human last touched. Works on CLOSED files too (the per-editor Undo button can't). Routes through the buffer, so it propagates to any open editor and is itself one undoable step; set `save:true` to also flush to disk. Returns {reverted:[paths], skipped:[paths]}. (work item 019ea40563137 / DCR 019ea404ffcd P2.)",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "Absolute file path of a changed file. Omit to revert all changed files in the changeset."},
			"source": {"type": "string", "description": "Only revert files whose last edit was by this source, e.g. 'ai'. Ignored when `path` is given."},
			"save": {"type": "boolean", "description": "Also flush reverted files to disk now (default false)."},
		}}, "documents")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	# _doc_write awaits PluginScenePanelHost.invoke_apply_sync (paired_dsl
	# plugin scenes) so it must be called with `await`. The other ops are
	# synchronous; awaiting them is cheap and keeps the match arm uniform.
	match tool_name:
		"minerva_doc_read": return _doc_read(arguments)
		"minerva_doc_write": return await _doc_write(arguments)
		"minerva_doc_edit": return _doc_edit(arguments)
		"minerva_doc_save": return _doc_save(arguments)
		"minerva_doc_save_all": return _doc_save_all(arguments)
		"minerva_journal_mark": return _journal_mark(arguments)
		"minerva_journal_changes": return _journal_changes(arguments)
		"minerva_journal_diff": return _journal_diff(arguments)
		"minerva_journal_revert": return _journal_revert(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


# ── Change journal (work item 019ea01719a2) ─────────────────────────────────

func _journal() -> ChangeJournal:
	return SingletonObject.change_journal if SingletonObject else null


func _journal_mark(args: Dictionary) -> Dictionary:
	var j := _journal()
	if j == null:
		return MCPToolUtils.error("change journal unavailable")
	var label := str(args.get("label", "manual"))
	j.mark(label, str(args.get("source", "")))
	var sum := j.changeset_summary()
	return {"success": true, "label": sum["label"], "seq": sum["seq"]}


func _journal_changes(_args: Dictionary) -> Dictionary:
	var j := _journal()
	if j == null:
		return MCPToolUtils.error("change journal unavailable")
	var sum := j.changeset_summary()
	sum["success"] = true
	return sum


func _journal_diff(args: Dictionary) -> Dictionary:
	var j := _journal()
	if j == null:
		return MCPToolUtils.error("change journal unavailable")
	var path := str(args.get("path", "")).strip_edges()
	if path.is_empty():
		return MCPToolUtils.error("path is required")
	var d := j.diff_for(path)
	d["success"] = true
	return d


func _journal_revert(args: Dictionary) -> Dictionary:
	var j := _journal()
	if j == null:
		return MCPToolUtils.error("change journal unavailable")
	var save := bool(args.get("save", false))
	var path := str(args.get("path", "")).strip_edges()
	if not path.is_empty():
		var r := j.revert(path, save)
		if not bool(r.get("ok", false)):
			return MCPToolUtils.error(str(r.get("error", "revert failed")))
		var did := bool(r.get("reverted", false))
		return {
			"success": true,
			"reverted": ([str(r.get("path", path))] if did else []),
			"skipped": ([] if did else [str(r.get("path", path))]),
			"saved": bool(r.get("saved", false)),
		}
	var res := j.revert_changeset(save, str(args.get("source", "")).strip_edges())
	res["success"] = true
	return res


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

	# PLUGIN_SCENE: if the broker has a DocumentBuffer attached to this panel
	# (paired_dsl case), the buffer is canonical — route through it so that
	# the paired text editor stays in sync (broker propagates text_changed back
	# to the panel via its existing subscription). Otherwise the editor owns
	# its own state via _on_panel_load_request / _on_panel_save_request.
	if ed_type == Editor.Type.PLUGIN_SCENE:
		var pbroker = SingletonObject.plugin_scene_panel_broker
		var ed_pid: String = str(editor.plugin_id) if "plugin_id" in editor else ""
		var ed_pname: String = str(editor.panel_name) if "panel_name" in editor else ""
		if pbroker != null and not ed_pid.is_empty() and not ed_pname.is_empty():
			var attached: DocumentBuffer = pbroker.get_attached_buffer(ed_pid, ed_pname)
			if attached != null:
				return {
					"ok": true,
					"kind": KIND_BUFFER,
					"buffer": attached,
					"editor": editor,
					"path": attached.file_path,
					"editor_name": editor_name,
				}
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

	# Anonymous TEXT editor that was bind_to_buffer_path()'d to an unbacked
	# (or any) buffer — the buffer is canonical even though editor.file is
	# empty. Route through it so MCP doc_* writes propagate to anyone else
	# subscribed (e.g. paired plugin scene render panel via the broker).
	if editor.has_method("get_document_buffer"):
		var ed_buf: DocumentBuffer = editor.get_document_buffer()
		if ed_buf != null:
			return {
				"ok": true,
				"kind": KIND_BUFFER,
				"buffer": ed_buf,
				"editor": editor,
				"path": str(ed_buf.file_path),
				"editor_name": editor_name,
			}

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
			var read_ok := {
				"text": buf.text,
				"version": buf.version,
				"dirty": buf.dirty,
				"path": t.path,
				"editor_name": t.editor_name,
			}
			# Paired_dsl plugin scene: also surface the panel's last_eval so the
			# agent can verify worker outcome without burning a second tool round.
			# Falls through silently when the editor has no plugin save hook.
			var ed_r = t.editor
			if ed_r != null and "type" in ed_r and int(ed_r.type) == Editor.Type.PLUGIN_SCENE \
					and ed_r.plugin_scene_root != null:
				var save_payload: Variant = PluginScenePanelHost.invoke_save(ed_r.plugin_scene_root, {})
				if save_payload is Dictionary and save_payload.has("last_eval"):
					read_ok["last_eval"] = save_payload["last_eval"]
			return _ok(read_ok)
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
			# host_owned: round-trip the plugin's _on_panel_save_request → JSON.
			var editor2 = t.editor
			if editor2.plugin_scene_root == null:
				return _err("plugin_scene_root_missing: editor '%s' has no mounted plugin scene" % t.editor_name)
			var payload: Variant = PluginScenePanelHost.invoke_save(editor2.plugin_scene_root, {})
			if payload == null:
				return _err("plugin_scene_save_request_returned_null: scene did not implement _on_panel_save_request or returned null")
			var serialised: String = ""
			if payload is Dictionary:
				serialised = JSON.stringify(payload, "\t")
			elif payload is String:
				serialised = payload
			else:
				return _err("plugin_scene_unsupported_payload_type: %s" % type_string(typeof(payload)))
			return _ok({
				"text": serialised,
				"version": 0,
				"dirty": false,
				"path": t.path,
				"editor_name": t.editor_name,
			})
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
			# Attribute this edit to the agent in the change journal (work item
			# 019ea01719a2); consumed one-shot by the resulting text_changed.
			if SingletonObject.change_journal:
				SingletonObject.change_journal.attribute_next_edit_to("ai")
			buf.apply_edit(text)
			var write_resp := {
				"version": buf.version,
				"dirty": buf.dirty,
				"path": t.path,
				"editor_name": t.editor_name,
			}
			# Optional persist-to-disk so a single write lands the file (parity with
			# the old WriteTool; the codetools file_write alias proxies this with
			# save=true). DiskAccess.write now mkdir -p's. work item 019ea035bb28.
			if bool(args.get("save", false)):
				var sr := buf.save_to_disk()
				if not sr.get("ok", false):
					return _err("saved_failed: %s" % str(sr.get("error", "")))
				write_resp["dirty"] = buf.dirty
				write_resp["saved"] = true
			# Paired_dsl plugin scene: await the panel's synchronous-apply hook
			# (cancels in-flight, skips debounce, awaits worker reply) so the
			# MCP response carries last_eval. Without this, the agent has to
			# poll doc_read until the eval lands — burning rounds and racing
			# the debounce. Falls through silently when the panel doesn't
			# expose the hook (non-cad plugins, html panels, etc.).
			var ed_w = t.editor
			if ed_w != null and "type" in ed_w and int(ed_w.type) == Editor.Type.PLUGIN_SCENE \
					and ed_w.plugin_scene_root != null:
				var apply_doc := {"source": text}
				var apply_result: Variant = await PluginScenePanelHost.invoke_apply_sync(
					ed_w.plugin_scene_root, apply_doc
				)
				if apply_result is Dictionary:
					if apply_result.has("last_eval"):
						write_resp["last_eval"] = apply_result["last_eval"]
					# If the plugin reports failure, propagate as MCP-level error
					# so the agent's "did it work?" check is the tool reply, not
					# a separate doc_read. Buffer write itself succeeded, so we
					# preserve version/dirty in the error envelope too.
					if not bool(apply_result.get("ok", true)):
						var le: Dictionary = apply_result.get("last_eval", {}) as Dictionary
						var err_kind: String = str(le.get("error_kind", "apply_failed"))
						var err_msg: String = str(le.get("error_message", "plugin reported ok=false"))
						return {
							"success": false,
							"ok": false,
							"error": "%s: %s" % [err_kind, err_msg],
							"last_eval": le,
							"version": buf.version,
							"dirty": buf.dirty,
							"path": t.path,
							"editor_name": t.editor_name,
						}
			return _ok(write_resp)
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
			# Plugin scenes expect Dictionary documents (per
			# _on_panel_load_request signature). Two input shapes are accepted:
			#  1. JSON object/array text → parsed and passed as-is.
			#  2. Plain text → wrapped as {"source": text}, the convention used
			#     by paired-DSL plugins (e.g. cad). Lets the LLM pass raw DSL
			#     without having to JSON-stringify it.
			var editor2 = t.editor
			if editor2.plugin_scene_root == null:
				return _err("plugin_scene_root_missing: editor '%s' has no mounted plugin scene" % t.editor_name)
			var doc: Dictionary = {}
			var trimmed := text.strip_edges()
			if trimmed.begins_with("{") or trimmed.begins_with("["):
				var parsed: Variant = JSON.parse_string(text)
				if parsed == null:
					return _err("plugin_scene_invalid_json: text starts with { or [ but does not parse as JSON")
				if not (parsed is Dictionary):
					return _err("plugin_scene_unsupported_payload: parsed JSON is not a Dictionary (got %s)" % type_string(typeof(parsed)))
				doc = parsed as Dictionary
			else:
				doc = {"source": text}
			var ok2: bool = PluginScenePanelHost.invoke_load(editor2.plugin_scene_root, doc)
			if not ok2:
				return _err("plugin_scene_load_request_failed: scene did not implement _on_panel_load_request")
			return _ok({
				"version": 0,
				"dirty": true,
				"path": t.path,
				"editor_name": t.editor_name,
			})
	return _err("unhandled kind: %s" % t.kind)


func _doc_edit(args: Dictionary) -> Dictionary:
	if not args.has("old_string"):
		return _err("old_string is required")
	if not args.has("new_string"):
		return _err("new_string is required")
	var old_str: String = args.get("old_string", "")
	var new_str: String = args.get("new_string", "")
	var replace_all: bool = bool(args.get("replace_all", false))
	var do_save: bool = bool(args.get("save", false))

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
	var new_text: String
	if replace_all:
		# Parity with the old EditTool: replace every occurrence.
		new_text = current_text.replace(old_str, new_str)
	else:
		var second := current_text.find(old_str, idx + old_str.length())
		if second != -1:
			return _err("old_string is not unique in buffer (matches at offsets %d and %d); pass replace_all=true to replace every occurrence" % [idx, second])
		new_text = current_text.substr(0, idx) + new_str + current_text.substr(idx + old_str.length())

	match t.kind:
		KIND_BUFFER:
			var buf: DocumentBuffer = t.buffer
			if SingletonObject.change_journal:
				SingletonObject.change_journal.attribute_next_edit_to("ai")
			buf.apply_edit(new_text)
			var resp := {
				"version": buf.version,
				"dirty": buf.dirty,
				"path": t.path,
				"editor_name": t.editor_name,
			}
			if do_save:
				var sr := buf.save_to_disk()
				if not sr.get("ok", false):
					return _err("saved_failed: %s" % str(sr.get("error", "")))
				resp["dirty"] = buf.dirty
				resp["saved"] = true
			return _ok(resp)
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
	var ed_file: String = str(editor.file) if "file" in editor else ""

	if ed_type == Editor.Type.PLUGIN_SCENE:
		# host_owned save mode is the only one wired through doc_save; the
		# editor's save_file_to_disc handles the dispatch (per Editor.gd
		# Type.PLUGIN_SCENE branch). plugin_owned and "none" return cleanly
		# from save_file_to_disc but don't actually write — surface that.
		if editor.plugin_save_mode == "none":
			return _err("plugin_scene_save_mode_none: this plugin's panel does not write to disk")
		if editor.plugin_save_mode == "plugin_owned":
			return _err("plugin_scene_save_mode_plugin_owned: not yet implemented; the plugin owns saving — call its tool directly")
		if ed_file.is_empty() and not have_path:
			return _err("editor '%s' is anonymous; pass `path` to bind via Save-As" % editor_name)
		var save_target_p := path_arg if have_path else ed_file
		editor.save_file_to_disc(save_target_p)
		return _ok({"path": save_target_p, "editor_name": str(editor.tab_title)})

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
