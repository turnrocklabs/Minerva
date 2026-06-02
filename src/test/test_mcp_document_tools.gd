extends SceneTree
## Test: MCPDocumentTools / OOXMLReader — minerva_read_document (.docx).
## Run: godot --headless --path src --script test/test_mcp_document_tools.gd
##
## Tracks docket: minerva 019e8547f0f6 (proof) under DCR 019e8547775c.
##
## Coverage:
##   - missing path / unsupported ext / native-import ext (csv) → clear errors
##   - not-a-zip and zip-without-document.xml → reader errors
##   - synthetic .docx: text (paragraphs), tables (rows/cols/csv), media metadata
##   - intra-cell newline (w:br) collapses in csv but is preserved in rows
##   - include_text=false / max_text_chars truncation
##   - INTEGRATION (if present): the real 61-student camp roster .docx

const MCPDocumentToolsScript := preload("res://Scripts/Services/MCP/Modules/MCPDocumentTools.gd")

var _pass := 0
var _fail := 0
var _dir := "/tmp/mcp_document_tools_test"
const REAL_DOCX := "/home/imran/Downloads/2026 Explorer Family Camp - student info for lanyards.docx"


func _init() -> void:
	print("=== MCPDocumentTools / OOXMLReader Tests ===\n")
	DirAccess.make_dir_recursive_absolute(_dir)
	var tools = MCPDocumentToolsScript.new(null)

	test_errors(tools)
	test_synthetic_docx(tools)
	test_text_options(tools)
	test_real_camp_docx(tools)

	_teardown()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func _teardown() -> void:
	var d := DirAccess.open(_dir)
	if d == null:
		return
	for n in d.get_files():
		DirAccess.remove_absolute("%s/%s" % [_dir, n])
	DirAccess.remove_absolute(_dir)


func _p(name: String) -> String:
	return "%s/%s" % [_dir, name]


# ── error paths ──────────────────────────────────────────────────────────────

func test_errors(tools) -> void:
	print("test_errors")
	check("missing path → error", tools.handle("minerva_read_document", {}).success == false)
	check("unsupported ext → error",
		tools.handle("minerva_read_document", {"path": _p("x.rtf")}).success == false)

	var csv_r: Dictionary = tools.handle("minerva_read_document", {"path": _p("x.csv")})
	check("csv ext → error pointing to native import", csv_r.success == false and "minerva_create_spreadsheet_editor" in str(csv_r.get("error", "")))

	# Not a ZIP: a plain-text file with a .docx extension.
	var bogus := _p("bogus.docx")
	var f := FileAccess.open(bogus, FileAccess.WRITE)
	f.store_string("this is not a zip")
	f.close()
	check("non-zip .docx → error", tools.handle("minerva_read_document", {"path": bogus}).success == false)

	# A valid ZIP that lacks word/document.xml.
	var nodoc := _p("nodoc.docx")
	var zp := ZIPPacker.new()
	zp.open(nodoc)
	zp.start_file("hello.txt")
	zp.write_file("hi".to_utf8_buffer())
	zp.close_file()
	zp.close()
	check("zip without document.xml → error", tools.handle("minerva_read_document", {"path": nodoc}).success == false)


# ── synthetic docx (full happy path) ─────────────────────────────────────────

func _write_docx(path: String, document_xml: String, media: Dictionary = {}) -> void:
	var zp := ZIPPacker.new()
	zp.open(path)
	zp.start_file("word/document.xml")
	zp.write_file(document_xml.to_utf8_buffer())
	zp.close_file()
	for name in media:
		zp.start_file(name)
		zp.write_file(media[name])
		zp.close_file()
	zp.close()


func test_synthetic_docx(tools) -> void:
	print("test_synthetic_docx")
	# A header cell with a <w:br> mimics Word wrapping a header across two lines —
	# the real-world gotcha that the csv must collapse for clean column names.
	var xml := """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
<w:p><w:r><w:t>Roster for 2026</w:t></w:r></w:p>
<w:p><w:r><w:t>Second paragraph, with comma.</w:t></w:r></w:p>
<w:tbl>
<w:tr><w:tc><w:p><w:r><w:t>Name</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Family </w:t></w:r><w:br/><w:r><w:t>Group</w:t></w:r></w:p></w:tc></w:tr>
<w:tr><w:tc><w:p><w:r><w:t>Ada Lovelace</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>8</w:t></w:r></w:p></w:tc></w:tr>
<w:tr><w:tc><w:p><w:r><w:t>Bo Diddley</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>3</w:t></w:r></w:p></w:tc></w:tr>
</w:tbl>
</w:body>
</w:document>"""
	var path := _p("good.docx")
	# One bogus media part to verify enumeration + content-type inference.
	_write_docx(path, xml, {"word/media/image1.png": PackedByteArray([0x89, 0x50, 0x4E, 0x47])})

	var r: Dictionary = tools.handle("minerva_read_document", {"path": path})
	check("success", r.success == true)
	check("format docx", r.get("format", "") == "docx")

	# text
	var text: String = r.get("text", "")
	check("text has para 1", "Roster for 2026" in text)
	check("text has para 2", "Second paragraph, with comma." in text)

	# tables
	var tables: Array = r.get("tables", [])
	check("one table", tables.size() == 1 and r.get("table_count", 0) == 1)
	var t: Dictionary = tables[0]
	check("3 rows", t.get("row_count", 0) == 3)
	check("2 cols", t.get("column_count", 0) == 2)
	var rows: Array = t.get("rows", [])
	check("header[0]=Name", rows[0][0] == "Name")
	# faithful rows preserve the intra-cell newline from <w:br> ("Family \nGroup")
	check("header[1] preserves newline in rows", "\n" in str(rows[0][1]))
	check("row1 Ada", rows[1][0] == "Ada Lovelace" and rows[1][1] == "8")

	# csv: newline collapsed, header readable, comma-containing text quoted
	var csv: String = t.get("csv", "")
	check("csv header line collapses newline → 'Family Group'", csv.split("\n")[0] == "Name,Family Group")
	check("csv row Ada", "Ada Lovelace,8" in csv)

	# images metadata (no bytes)
	var imgs: Array = r.get("images", [])
	check("one media image", imgs.size() == 1)
	check("image content_type png", imgs.size() == 1 and imgs[0].get("content_type", "") == "image/png")
	check("image byte_size 4", imgs.size() == 1 and imgs[0].get("byte_size", 0) == 4)
	check("image has no inlined bytes", imgs.size() == 1 and not imgs[0].has("bytes"))


# ── text options ─────────────────────────────────────────────────────────────

func test_text_options(tools) -> void:
	print("test_text_options")
	var xml := """<?xml version="1.0"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t>ABCDEFGHIJ</w:t></w:r></w:p></w:body></w:document>"""
	var path := _p("textopts.docx")
	_write_docx(path, xml)

	var no_text: Dictionary = tools.handle("minerva_read_document", {"path": path, "include_text": false})
	check("include_text=false → empty text", no_text.get("text", "x") == "")

	var trunc: Dictionary = tools.handle("minerva_read_document", {"path": path, "max_text_chars": 4})
	check("max_text_chars truncates", trunc.get("text", "") == "ABCD")
	check("text_truncated flag set", trunc.get("text_truncated", false) == true)


# ── integration: the real camp roster ────────────────────────────────────────

func test_real_camp_docx(tools) -> void:
	print("test_real_camp_docx")
	if not FileAccess.file_exists(REAL_DOCX):
		print("  SKIP: real camp .docx not present on this machine")
		return
	var r: Dictionary = tools.handle("minerva_read_document", {"path": REAL_DOCX})
	check("real docx reads", r.success == true)
	var tables: Array = r.get("tables", [])
	check("real docx has 1 table", tables.size() == 1)
	if tables.size() == 1:
		var t: Dictionary = tables[0]
		check("real docx 62 rows (header + 61 students)", t.get("row_count", 0) == 62)
		check("real docx 9 columns", t.get("column_count", 0) == 9)
		# csv header line has collapsed the newlines Word wrapped into column names
		var header := str(t.get("csv", "")).split("\n")[0]
		check("real docx csv header has no embedded newline", not ("\n" in header))
		check("real docx csv first col is Student", header.begins_with("Student"))
