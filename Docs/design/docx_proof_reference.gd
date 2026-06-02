# Proof (docket 019e8547f0f6): read a .docx purely with Godot built-ins —
# ZIPReader (docx is a zip) + XMLParser (word/document.xml is OOXML).
# Zero external deps; same code path runs on Windows / macOS-arm / Linux.
#
# Run:  godot --headless --path src --script /tmp/docx_proof.gd
extends SceneTree

const DOCX := "/home/imran/Downloads/2026 Explorer Family Camp - student info for lanyards.docx"
const REF_ROWS := "/home/imran/temp3/all_rows.json"

func _initialize() -> void:
	var doc := _read_document_xml(DOCX)
	if doc.is_empty():
		printerr("FAIL: could not read word/document.xml")
		quit(1)
		return

	var tables := _extract_tables(doc)
	print("tables found: ", tables.size())
	if tables.is_empty():
		printerr("FAIL: no <w:tbl> found")
		quit(1)
		return

	var t: Array = tables[0]
	print("table[0]: rows=", t.size(), " cols(header)=", (t[0] as Array).size() if t.size() > 0 else 0)
	print("--- header ---")
	print(t[0])
	print("--- row 1 (first student) ---")
	if t.size() > 1:
		print(t[1])
	print("--- row 2 ---")
	if t.size() > 2:
		print(t[2])

	# Cross-check the student count against the reference all_rows.json (~61).
	var ref_count := _ref_student_count()
	var data_rows := t.size() - 1  # minus header
	print("data rows (students): ", data_rows, "   reference all_rows.json: ", ref_count)

	# Build {header: value} objects (what minerva_read_document → spreadsheet would do).
	var objs := _rows_to_objects(t)
	print("objects built: ", objs.size())
	if objs.size() > 0:
		print("first object: ", JSON.stringify(objs[0]))

	var ok := data_rows >= 60 and data_rows <= 62 and tables.size() == 1
	print("RESULT: ", ("PASS" if ok else "FAIL"), " (expect 1 table, ~61 student rows)")
	quit(0 if ok else 1)


func _read_document_xml(path: String) -> PackedByteArray:
	var zip := ZIPReader.new()
	var err := zip.open(path)
	if err != OK:
		printerr("zip.open err=", err)
		return PackedByteArray()
	var bytes := zip.read_file("word/document.xml")
	zip.close()
	return bytes


# Returns Array[ Array[ Array[String] ] ]  →  tables[ rows[ cells[] ] ]
func _extract_tables(xml_bytes: PackedByteArray) -> Array:
	var p := XMLParser.new()
	if p.open_buffer(xml_bytes) != OK:
		return []

	var tables: Array = []
	var cur_table: Array = []        # Array[ Array[String] ]
	var cur_row: Array = []          # Array[String]
	var depth_tbl := 0
	var in_cell := false
	var cell_paras: Array = []       # Array[String] — one entry per <w:p> in the cell
	var cur_para := ""

	while p.read() == OK:
		var nt := p.get_node_type()
		if nt == XMLParser.NODE_ELEMENT:
			var name := p.get_node_name()
			match name:
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
			var ename := p.get_node_name()
			match ename:
				"w:tc":
					if in_cell:
						if cur_para != "":
							cell_paras.append(cur_para)
						# join paragraphs with newline; trim trailing blanks
						var joined := "\n".join(cell_paras).strip_edges()
						cur_row.append(joined)
						in_cell = false
						cell_paras = []
						cur_para = ""
				"w:tr":
					if depth_tbl >= 1 and not cur_row.is_empty():
						cur_table.append(cur_row)
						cur_row = []
				"w:tbl":
					if depth_tbl == 1:
						tables.append(cur_table)
						cur_table = []
					depth_tbl = max(0, depth_tbl - 1)
	return tables


func _rows_to_objects(table: Array) -> Array:
	if table.size() < 2:
		return []
	var headers: Array = table[0]
	var out: Array = []
	for r in range(1, table.size()):
		var row: Array = table[r]
		var obj := {}
		for c in range(headers.size()):
			var key := str(headers[c]) if c < headers.size() else ("col%d" % c)
			var val := str(row[c]) if c < row.size() else ""
			obj[key] = val
		out.append(obj)
	return out


func _ref_student_count() -> int:
	if not FileAccess.file_exists(REF_ROWS):
		return -1
	var txt := FileAccess.get_file_as_string(REF_ROWS)
	var parsed = JSON.parse_string(txt)
	if parsed is Array:
		return (parsed as Array).size()
	return -1
