extends SceneTree
## Test: FileReference — the pure binary-sniff + reference-text logic behind
## "attach a binary file (docx/xlsx/pdf) as a path-reference note instead of
## garbage-decoding its bytes as text".
## Run: godot --headless --path src --script test/test_file_reference.gd

const REAL_DOCX := "/home/imran/Downloads/2026 Explorer Family Camp - student info for lanyards.docx"

var _pass := 0
var _fail := 0
var _dir := "/tmp/file_reference_test"


func _init() -> void:
	print("=== FileReference Tests ===\n")
	DirAccess.make_dir_recursive_absolute(_dir)

	test_looks_binary()
	test_reference_text()

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


func _write(name: String, bytes: PackedByteArray) -> String:
	var p := "%s/%s" % [_dir, name]
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	return p


func test_looks_binary() -> void:
	print("test_looks_binary")
	var txt := _write("plain.txt", "hello world\nsecond line, UTF-8 é".to_utf8_buffer())
	var pdfish := _write("fake.pdf", PackedByteArray([0x25, 0x50, 0x44, 0x46, 0x00, 0x01]))  # %PDF + NUL
	var zipish := _write("doc.docx", PackedByteArray([0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF]))   # PK zip + NUL
	check("plain UTF-8 text → not binary", FileReference.looks_binary(txt) == false)
	check("NUL-bearing .pdf → binary", FileReference.looks_binary(pdfish) == true)
	check("zip-magic .docx → binary", FileReference.looks_binary(zipish) == true)
	check("missing file → binary (safer than garbage read)", FileReference.looks_binary("%s/nope.bin" % _dir) == true)
	if FileAccess.file_exists(REAL_DOCX):
		check("real camp .docx → binary", FileReference.looks_binary(REAL_DOCX) == true)
	else:
		print("  SKIP: real .docx not present")


func test_reference_text() -> void:
	print("test_reference_text")
	var body := FileReference.reference_text("/home/imran/Downloads/roster.docx")
	check("carries the absolute path", "/home/imran/Downloads/roster.docx" in body)
	check("carries the filename", "Name: roster.docx" in body)
	check("carries the type", "Type: .docx" in body)
	check("flags that it is a reference, not inlined", "referenced" in body.to_lower())
