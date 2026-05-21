@tool
extends EditorPlugin

const OUTPUT_PATH := "res://.sightline/godot_probe/debugger_state.json"
const OUTPUT_TEXT_PATH := "res://.sightline/godot_probe/output_console.txt"
const CAPTURE_INTERVAL_SECONDS := 0.5
const MAX_TEXT_LENGTH := 1200
const MAX_DIAGNOSTIC_ROWS := 40
const OUTPUT_PREVIEW_TAIL_LINES := 40
const DEBUGGER_REGION_HEIGHT := 520.0

var _elapsed := 0.0


func _enter_tree() -> void:
	set_process(true)
	_capture_debugger_state()


func _exit_tree() -> void:
	set_process(false)


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < CAPTURE_INTERVAL_SECONDS:
		return
	_elapsed = 0.0
	_capture_debugger_state()


func _capture_debugger_state() -> void:
	var base := get_editor_interface().get_base_control()
	var debugger_state := _read_debugger_state(base)
	var output_console_state := _read_output_console_state(base)
	var state := {
		"schema": "sightline.godot.editor_probe_state.v4",
		"project": ProjectSettings.get_setting("application/config/name", ""),
		"project_path": ProjectSettings.globalize_path("res://"),
		"captured_at_unix": Time.get_unix_time_from_system(),
		"source": "godot_editor_probe",
		"debugger": debugger_state,
		"output_console": output_console_state,
		"provenance": {
			"adapter": "godot_editor_plugin",
			"plugin_id": "sightline_probe",
			"output_path": ProjectSettings.globalize_path(OUTPUT_PATH)
		}
	}
	_write_json(state)


func _read_debugger_state(root: Control) -> Dictionary:
	var text_controls: Array = []
	var tree_controls: Array = []
	var tab_bar_controls: Array = []
	_collect_controls(root, text_controls, tree_controls, tab_bar_controls)
	var tabs := _find_debugger_tabs(text_controls)
	var bottom_panel_controls: Array = []
	var debugger_subtree_rows: Array = []
	_collect_bottom_panel_diagnostics(root, bottom_panel_controls, debugger_subtree_rows)
	var rows: Array = []
	var regions: Array = []
	for tab in tabs:
		var region := _debugger_region_for_tab(root, tab)
		regions.append(region)
		_collect_rows_in_region(text_controls, tree_controls, region, rows)
	if rows.is_empty():
		rows.append_array(debugger_subtree_rows)
	rows = _dedupe_rows(rows)
	var tab_text := ""
	if not tabs.is_empty():
		tab_text = str(tabs[0].get("text", ""))
	var warning_count := _count_from_debugger_tab(tab_text)
	if warning_count < 0:
		warning_count = _count_warning_rows(rows)
	var extraction_status := "debugger_tab_not_found"
	if not tabs.is_empty():
		extraction_status = "scoped_debugger_region"
	elif not debugger_subtree_rows.is_empty():
		extraction_status = "debugger_subtree"
	return {
		"schema": "sightline.godot.debugger_rows.v2",
		"extraction_status": extraction_status,
		"tab_text": tab_text,
		"warning_count": warning_count,
		"error_count": _count_error_rows(rows),
		"rows": rows,
		"diagnostics": {
			"debugger_tabs": tabs.slice(0, MAX_DIAGNOSTIC_ROWS),
			"regions": regions,
			"tab_bar_candidates": tab_bar_controls.slice(0, MAX_DIAGNOSTIC_ROWS),
			"text_candidate_count": text_controls.size(),
			"tree_candidate_count": tree_controls.size(),
			"text_candidate_samples": text_controls.slice(0, MAX_DIAGNOSTIC_ROWS),
			"tree_candidate_samples": tree_controls.slice(0, MAX_DIAGNOSTIC_ROWS),
			"bottom_panel_controls": bottom_panel_controls.slice(0, MAX_DIAGNOSTIC_ROWS * 2),
			"debugger_subtree_rows": debugger_subtree_rows.slice(0, MAX_DIAGNOSTIC_ROWS),
			"row_count": rows.size(),
			"row_samples": rows.slice(0, MAX_DIAGNOSTIC_ROWS)
		}
	}


func _read_output_console_state(root: Control) -> Dictionary:
	var records: Array = []
	var text_parts: Array = []
	var counters: Array = []
	_collect_output_console(root, false, records, text_parts, counters)
	var text := "\n".join(text_parts).strip_edges()
	var lines := _split_lines(text)
	var extraction_status := "output_panel_not_found"
	if not records.is_empty():
		extraction_status = "output_panel_found"
	if not text.is_empty():
		extraction_status = "output_text_found"
	_write_output_text(text)
	var preview_lines := _tail_lines(lines, OUTPUT_PREVIEW_TAIL_LINES)
	return {
		"schema": "sightline.godot.output_console.v2",
		"extraction_status": extraction_status,
		"line_count": lines.size(),
		"preview_tail": "\n".join(preview_lines),
		"preview_tail_lines": preview_lines.size(),
		"text_sha256": _sha256_hex(text),
		"text_byte_count": text.to_utf8_buffer().size(),
		"text_path": ProjectSettings.globalize_path(OUTPUT_TEXT_PATH),
		"counters": counters,
		"diagnostics": {
			"output_controls": records.slice(0, MAX_DIAGNOSTIC_ROWS * 2),
			"text_part_count": text_parts.size()
		}
	}


func _collect_output_console(
	node: Node,
	in_output_subtree: bool,
	records: Array,
	text_parts: Array,
	counters: Array
) -> void:
	if node == null:
		return
	var node_name := str(node.name)
	var node_path := str(node.get_path())
	var next_in_output_subtree := in_output_subtree or (
		node_path.contains("EditorBottomPanel")
		and (node_path.contains("/Output") or node_name == "Output")
	)
	if node is Control and next_in_output_subtree:
		var control := node as Control
		var text := _node_text(control)
		var record := _control_record(control, text)
		record["visible"] = control.visible
		record["visible_in_tree"] = control.is_visible_in_tree()
		if records.size() < MAX_DIAGNOSTIC_ROWS * 2:
			records.append(record)
		if control is RichTextLabel or control is TextEdit:
			var raw_text := _raw_node_text(control).strip_edges()
			if not raw_text.is_empty():
				text_parts.append(raw_text)
		elif control is Button:
			var stripped := text.strip_edges()
			if stripped.is_valid_int():
				counters.append({
					"text": stripped,
					"node_path": node_path,
					"name": node_name,
					"rect": record.get("rect", {})
				})
	for child in node.get_children():
		_collect_output_console(child, next_in_output_subtree, records, text_parts, counters)


func _collect_controls(node: Node, text_controls: Array, tree_controls: Array, tab_bar_controls: Array) -> void:
	if node == null:
		return
	if node is Control and (node as Control).is_visible_in_tree():
		var control := node as Control
		if control is TabBar:
			_collect_tab_bar_records(control as TabBar, text_controls, tab_bar_controls)
		if control is Tree:
			tree_controls.append(_control_record(control, ""))
		var text := _node_text(control)
		if not text.is_empty():
			text_controls.append(_control_record(control, text))
	for child in node.get_children():
		_collect_controls(child, text_controls, tree_controls, tab_bar_controls)


func _node_text(control: Control) -> String:
	return _trim_text(_raw_node_text(control).strip_edges())


func _raw_node_text(control: Control) -> String:
	var text := ""
	if control is Button:
		text = (control as Button).text
	elif control is Label:
		text = (control as Label).text
	elif control is RichTextLabel:
		text = (control as RichTextLabel).get_parsed_text()
	elif control is LineEdit:
		text = (control as LineEdit).text
	elif control is TextEdit:
		text = (control as TextEdit).text
	return text


func _control_record(control: Control, text: String) -> Dictionary:
	var rect := control.get_global_rect()
	return {
		"node_path": str(control.get_path()),
		"class": control.get_class(),
		"name": str(control.name),
		"text": _trim_text(text),
		"rect": _rect_dict(rect)
	}


func _collect_tab_bar_records(tab_bar: TabBar, text_controls: Array, tab_bar_controls: Array) -> void:
	var titles: Array = []
	for index in range(tab_bar.tab_count):
		var text := tab_bar.get_tab_title(index).strip_edges()
		titles.append(text)
		if text.is_empty():
			continue
		var tab_rect := tab_bar.get_tab_rect(index)
		var global_rect := Rect2(tab_bar.get_global_position() + tab_rect.position, tab_rect.size)
		var record := {
			"node_path": str(tab_bar.get_path()),
			"class": tab_bar.get_class(),
			"name": str(tab_bar.name),
			"text": _trim_text(text),
			"rect": _rect_dict(global_rect),
			"tab_index": index,
			"selected": tab_bar.current_tab == index
		}
		text_controls.append(record)
	tab_bar_controls.append({
		"node_path": str(tab_bar.get_path()),
		"class": tab_bar.get_class(),
		"name": str(tab_bar.name),
		"rect": _rect_dict(tab_bar.get_global_rect()),
		"current_tab": tab_bar.current_tab,
		"tab_count": tab_bar.tab_count,
		"titles": titles
	})


func _find_debugger_tabs(text_controls: Array) -> Array:
	var tabs: Array = []
	for record in text_controls:
		var text := str(record.get("text", "")).strip_edges()
		if _is_debugger_tab_text(text):
			tabs.append(record)
	tabs.sort_custom(func(a, b): return float(a["rect"]["y"]) > float(b["rect"]["y"]))
	return tabs


func _is_debugger_tab_text(text: String) -> bool:
	if text == "Debugger":
		return true
	var regex := RegEx.new()
	if regex.compile("^Debugger\\s*\\((\\d+)\\)$") != OK:
		return false
	return regex.search(text) != null


func _debugger_region_for_tab(root: Control, tab: Dictionary) -> Dictionary:
	var tab_rect: Dictionary = tab.get("rect", {})
	var root_rect := root.get_global_rect()
	var tab_y := float(tab_rect.get("y", root_rect.position.y + root_rect.size.y))
	var region_y = max(root_rect.position.y, tab_y - DEBUGGER_REGION_HEIGHT)
	return {
		"x": root_rect.position.x,
		"y": region_y,
		"width": root_rect.size.x,
		"height": max(0.0, tab_y - region_y),
		"tab": tab
	}


func _collect_rows_in_region(text_controls: Array, tree_controls: Array, region: Dictionary, rows: Array) -> void:
	for record in text_controls:
		var text := str(record.get("text", "")).strip_edges()
		if _is_debugger_tab_text(text):
			continue
		if _record_inside_region(record, region) and _looks_like_debugger_message(text):
			rows.append(_row_record("control", text, record))
	for tree_record in tree_controls:
		if not _record_inside_region(tree_record, region):
			continue
		var node := get_node_or_null(NodePath(str(tree_record.get("node_path", ""))))
		if node is Tree:
			_collect_tree_rows(node as Tree, rows)


func _collect_tree_rows(tree: Tree, rows: Array) -> void:
	var root := tree.get_root()
	if root == null:
		return
	var counter := [0]
	_collect_tree_item_rows(root, tree.columns, rows, _control_record(tree, ""), counter)


func _collect_tree_item_rows(item: TreeItem, columns: int, rows: Array, tree_record: Dictionary, counter: Array) -> void:
	var parts: Array[String] = []
	for column in range(columns):
		var text := item.get_text(column).strip_edges()
		if not text.is_empty():
			parts.append(text)
	var joined := _trim_text(" ".join(parts))
	var index := int(counter[0])
	counter[0] = index + 1
	if _looks_like_debugger_message(joined):
		var row := _row_record("tree", joined, tree_record)
		row["tree_row_index"] = index
		rows.append(row)
	var child := item.get_first_child()
	while child != null:
		_collect_tree_item_rows(child, columns, rows, tree_record, counter)
		child = child.get_next()


func _collect_bottom_panel_diagnostics(node: Node, bottom_panel_controls: Array, debugger_rows: Array) -> void:
	_collect_bottom_panel_diagnostics_inner(node, false, false, bottom_panel_controls, debugger_rows)


func _collect_bottom_panel_diagnostics_inner(
	node: Node,
	in_bottom_panel: bool,
	in_debugger_subtree: bool,
	bottom_panel_controls: Array,
	debugger_rows: Array
) -> void:
	if node == null:
		return
	var node_name := str(node.name)
	var node_path := str(node.get_path())
	var next_in_bottom_panel := in_bottom_panel or node_name.contains("EditorBottomPanel") or node_path.contains("EditorBottomPanel")
	var next_in_debugger_subtree := in_debugger_subtree or (
		next_in_bottom_panel and (node_name == "Debugger" or node_name.contains("Debugger") or node_path.contains("/Debugger"))
	)
	if node is Control and next_in_bottom_panel:
		var control := node as Control
		var record := _control_record(control, _node_text(control))
		record["visible"] = control.visible
		record["visible_in_tree"] = control.is_visible_in_tree()
		if bottom_panel_controls.size() < MAX_DIAGNOSTIC_ROWS * 2:
			bottom_panel_controls.append(record)
		if next_in_debugger_subtree:
			if control is Tree:
				_collect_tree_rows(control as Tree, debugger_rows)
			var text := str(record.get("text", "")).strip_edges()
			if _looks_like_debugger_message(text):
				debugger_rows.append(_row_record("debugger_subtree_control", text, record))
	for child in node.get_children():
		_collect_bottom_panel_diagnostics_inner(
			child,
			next_in_bottom_panel,
			next_in_debugger_subtree,
			bottom_panel_controls,
			debugger_rows
		)


func _row_record(source: String, text: String, record: Dictionary) -> Dictionary:
	return {
		"source": source,
		"text": _trim_text(text),
		"severity": _severity_for_text(text),
		"node_path": record.get("node_path", ""),
		"class": record.get("class", ""),
		"name": record.get("name", ""),
		"rect": record.get("rect", {})
	}


func _looks_like_debugger_message(text: String) -> bool:
	if text.is_empty():
		return false
	if text.length() > MAX_TEXT_LENGTH:
		return false
	var lowered := text.to_lower()
	return (
		lowered.begins_with("warning:")
		or lowered.begins_with("error:")
		or lowered.begins_with("script error:")
		or lowered.contains("gdscript::reload:")
		or lowered.contains(" is shadowing ")
		or lowered.contains(" declared below ")
		or lowered.contains("static function")
	)


func _severity_for_text(text: String) -> String:
	var lowered := text.to_lower()
	if lowered.begins_with("script error:"):
		return "script_error"
	if lowered.begins_with("error:"):
		return "error"
	if lowered.begins_with("warning:"):
		return "warning"
	if lowered.contains("gdscript::reload:") or lowered.contains("is shadowing") or lowered.contains("declared below") or lowered.contains("static function"):
		return "warning"
	return "issue"


func _record_inside_region(record: Dictionary, region: Dictionary) -> bool:
	var rect: Dictionary = record.get("rect", {})
	var x := float(rect.get("x", 0.0))
	var y := float(rect.get("y", 0.0))
	var width := float(rect.get("width", 0.0))
	var height := float(rect.get("height", 0.0))
	var rx := float(region.get("x", 0.0))
	var ry := float(region.get("y", 0.0))
	var rw := float(region.get("width", 0.0))
	var rh := float(region.get("height", 0.0))
	var center_x := x + width / 2.0
	var center_y := y + height / 2.0
	return center_x >= rx and center_x <= rx + rw and center_y >= ry and center_y <= ry + rh


func _dedupe_rows(rows: Array) -> Array:
	var seen := {}
	var output: Array = []
	for row in rows:
		var source := str(row.get("source", ""))
		var key := ""
		if source == "tree":
			key = "tree|" + str(row.get("node_path", "")) + "|" + str(row.get("tree_row_index", -1))
		else:
			key = source + "|" + str(row.get("severity", "")) + "|" + str(row.get("text", ""))
		if seen.has(key):
			continue
		seen[key] = true
		output.append(row)
	return output


func _count_from_debugger_tab(text: String) -> int:
	var regex := RegEx.new()
	if regex.compile("^Debugger\\s*\\((\\d+)\\)$") != OK:
		return -1
	var result := regex.search(text)
	if result == null:
		return -1
	return int(result.get_string(1))


func _count_warning_rows(rows: Array) -> int:
	var count := 0
	for row in rows:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		if str(row.get("severity", "")) == "warning":
			count += 1
	return count


func _count_error_rows(rows: Array) -> int:
	var count := 0
	for row in rows:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var severity := str(row.get("severity", ""))
		if severity == "error" or severity == "script_error":
			count += 1
	return count


func _rect_dict(rect: Rect2) -> Dictionary:
	return {
		"x": rect.position.x,
		"y": rect.position.y,
		"width": rect.size.x,
		"height": rect.size.y
	}


func _trim_text(text: String) -> String:
	if text.length() <= MAX_TEXT_LENGTH:
		return text
	return text.substr(0, MAX_TEXT_LENGTH) + "...<truncated>"


func _split_lines(text: String) -> Array:
	if text.is_empty():
		return []
	var output: Array = []
	for line in text.split("\n"):
		output.append(line)
	return output


func _tail_lines(lines: Array, count: int) -> Array:
	if count <= 0 or lines.is_empty():
		return []
	if lines.size() <= count:
		return lines.duplicate()
	return lines.slice(lines.size() - count, lines.size())


func _sha256_hex(text: String) -> String:
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if not text.is_empty():
		ctx.update(text.to_utf8_buffer())
	var bytes: PackedByteArray = ctx.finish()
	var hex := ""
	for b in bytes:
		hex += "%02x" % b
	return hex


func _write_json(state: Dictionary) -> void:
	var absolute_path := ProjectSettings.globalize_path(OUTPUT_PATH)
	var directory := absolute_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(absolute_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(state, "\t"))
	file.close()


func _write_output_text(text: String) -> void:
	var absolute_path := ProjectSettings.globalize_path(OUTPUT_TEXT_PATH)
	var directory := absolute_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(absolute_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()
