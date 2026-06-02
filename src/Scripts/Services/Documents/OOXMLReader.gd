class_name OOXMLReader
extends RefCounted
## Cross-platform reader for OOXML wordprocessing documents (.docx).
##
## A .docx is a ZIP of XML parts; the body lives in word/document.xml. This reader
## uses only Godot built-ins (ZIPReader + XMLParser) so it runs identically on
## Windows, macOS-arm, and Linux with ZERO external dependencies — no LibreOffice,
## no Word, no Python (the design-of-record decision for DCR 019e8547775c).
##
## Scope: extract DATA (paragraph text + tables + embedded-media metadata), NOT
## faithful rendering/layout. Viewing a .docx (which needs an office suite) is a
## separate, non-cross-platform concern and is deliberately out of scope.
##
## All methods are static and pure — headless-testable, no scene tree.

## Read a .docx and return its data.
## Returns: {
##   ok: bool, error: String,
##   text: String,                         # all paragraph text, "\n"-joined
##   tables: Array[{                        # one entry per <w:tbl>
##       rows: Array[Array[String]],        # faithful cell text (may contain \n)
##       row_count: int, column_count: int, # column_count = widest row
##       csv: String                        # import-ready: intra-cell whitespace
##   }],                                    #   collapsed, RFC-4180 quoted
##   images: Array[{name, content_type, byte_size}]  # metadata only (no bytes)
## }
static func read_docx(path: String) -> Dictionary:
	var out := {
		"ok": false, "error": "",
		"text": "", "tables": [], "images": [],
	}

	if not FileAccess.file_exists(path):
		out.error = "File not found: %s" % path
		return out

	var zip := ZIPReader.new()
	var err := zip.open(path)
	if err != OK:
		out.error = "Not a readable ZIP/.docx (err %d): %s" % [err, path]
		return out

	var files := zip.get_files()
	if not files.has("word/document.xml"):
		zip.close()
		out.error = "Not a wordprocessing .docx (no word/document.xml). Parts: %s" % str(files.slice(0, 8))
		return out

	var xml_bytes := zip.read_file("word/document.xml")

	out.text = _extract_text(xml_bytes)
	out.tables = _extract_tables(xml_bytes)
	out.images = _list_media(zip, files)

	zip.close()
	out.ok = true
	return out


## Full document text: every <w:p> becomes one line; runs (<w:t>) within a
## paragraph are concatenated; <w:tab>→\t, <w:br>/<w:cr>→newline.
static func _extract_text(xml_bytes: PackedByteArray) -> String:
	var p := XMLParser.new()
	if p.open_buffer(xml_bytes) != OK:
		return ""
	var lines: Array[String] = []
	var cur := ""
	var in_para := false
	while p.read() == OK:
		var nt := p.get_node_type()
		if nt == XMLParser.NODE_ELEMENT:
			match p.get_node_name():
				"w:p":
					if in_para:
						lines.append(cur)
					cur = ""
					in_para = true
				"w:tab":
					cur += "\t"
				"w:br", "w:cr":
					cur += "\n"
		elif nt == XMLParser.NODE_TEXT and in_para:
			cur += p.get_node_data()
	if in_para:
		lines.append(cur)
	return "\n".join(lines)


## Structured tables. Returns Array of {rows, row_count, column_count, csv}.
static func _extract_tables(xml_bytes: PackedByteArray) -> Array:
	var p := XMLParser.new()
	if p.open_buffer(xml_bytes) != OK:
		return []

	var tables: Array = []
	var cur_table: Array = []   # Array[Array[String]]
	var cur_row: Array = []     # Array[String]
	var depth_tbl := 0          # nesting depth so nested tables don't corrupt the outer
	var in_cell := false
	var cell_paras: Array = []
	var cur_para := ""

	while p.read() == OK:
		var nt := p.get_node_type()
		if nt == XMLParser.NODE_ELEMENT:
			match p.get_node_name():
				"w:tbl":
					depth_tbl += 1
					if depth_tbl == 1:
						cur_table = []
				"w:tr":
					if depth_tbl >= 1:
						cur_row = []
				"w:tc":
					if depth_tbl >= 1:
						in_cell = true
						cell_paras = []
						cur_para = ""
				"w:p":
					if in_cell and cur_para != "":
						cell_paras.append(cur_para)
						cur_para = ""
				"w:tab":
					if in_cell:
						cur_para += "\t"
				"w:br", "w:cr":
					if in_cell:
						cell_paras.append(cur_para)
						cur_para = ""
		elif nt == XMLParser.NODE_TEXT:
			if in_cell:
				cur_para += p.get_node_data()
		elif nt == XMLParser.NODE_ELEMENT_END:
			match p.get_node_name():
				"w:tc":
					if in_cell:
						if cur_para != "":
							cell_paras.append(cur_para)
						cur_row.append("\n".join(cell_paras).strip_edges())
						in_cell = false
						cell_paras = []
						cur_para = ""
				"w:tr":
					if depth_tbl >= 1 and not cur_row.is_empty():
						cur_table.append(cur_row)
						cur_row = []
				"w:tbl":
					if depth_tbl == 1:
						tables.append(_finalize_table(cur_table))
						cur_table = []
					depth_tbl = max(0, depth_tbl - 1)
	return tables


static func _finalize_table(rows: Array) -> Dictionary:
	var cols := 0
	for r in rows:
		cols = max(cols, (r as Array).size())
	return {
		"rows": rows,
		"row_count": rows.size(),
		"column_count": cols,
		"csv": _rows_to_csv(rows),
	}


## Import-ready CSV: intra-cell whitespace (incl. \n,\t) collapsed to single
## spaces so column headers and values round-trip cleanly through the
## spreadsheet importer; fields are RFC-4180 quoted when needed.
static func _rows_to_csv(rows: Array) -> String:
	var out: Array[String] = []
	for r in rows:
		var cells: Array[String] = []
		for c in (r as Array):
			cells.append(_csv_field(str(c)))
		out.append(",".join(cells))
	return "\n".join(out)


static func _csv_field(raw: String) -> String:
	# Collapse any run of whitespace (spaces, tabs, newlines) to one space.
	var collapsed := _collapse_ws(raw)
	if collapsed.contains(",") or collapsed.contains("\"") or collapsed.contains("\n"):
		return "\"" + collapsed.replace("\"", "\"\"") + "\""
	return collapsed


static func _collapse_ws(s: String) -> String:
	var re := RegEx.new()
	re.compile("\\s+")
	return re.sub(s, " ", true).strip_edges()


## Embedded-media metadata (word/media/*). Names + inferred content-type + size.
## Bytes are NOT inlined — media can be megabytes; a caller that needs the bytes
## can read them by name. (Keeps the reader's payload bounded.)
static func _list_media(zip: ZIPReader, files: PackedStringArray) -> Array:
	var imgs: Array = []
	for f in files:
		if f.begins_with("word/media/"):
			var bytes := zip.read_file(f)
			imgs.append({
				"name": f,
				"content_type": _content_type_for(f),
				"byte_size": bytes.size(),
			})
	return imgs


static func _content_type_for(name: String) -> String:
	match name.get_extension().to_lower():
		"png": return "image/png"
		"jpg", "jpeg": return "image/jpeg"
		"gif": return "image/gif"
		"bmp": return "image/bmp"
		"tif", "tiff": return "image/tiff"
		"svg": return "image/svg+xml"
		"emf": return "image/x-emf"
		"wmf": return "image/x-wmf"
		_: return "application/octet-stream"
