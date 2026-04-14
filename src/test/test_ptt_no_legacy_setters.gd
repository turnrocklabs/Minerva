extends SceneTree
## Regression guard: no file outside AudioToText.gd may assign to PTT legacy or private fields.
## Run: godot --headless --script test/test_ptt_no_legacy_setters.gd
##
## Scans src/Scripts/ recursively (excluding AudioToText.gd) for the pattern:
##   (AtT|AudioToTexts|audio_to_text)\.(FieldForFilling|btn|btnStop|_field_for_filling)\s*=
## Any match is a failure.

const SCAN_ROOT := "res://Scripts/"
const EXCLUDE_FILE := "Scripts/Models/AudioToText.gd"

# Matches the specific object-qualified setter patterns we want to guard.
# Using a simple string match on each line (GDScript lacks full regex on strings,
# so we check for the object prefixes and field names manually).
const OBJECT_PREFIXES: Array[String] = ["AtT.", "AudioToTexts.", "audio_to_text."]
const FIELD_NAMES: Array[String] = ["FieldForFilling", "btn", "btnStop", "_field_for_filling"]


func _init():
	print("=== PTT No-Legacy-Setters Regression Guard ===\n")

	var offenders: Array[String] = []
	_scan_dir(SCAN_ROOT, offenders)

	if offenders.is_empty():
		print("PASS: 0 legacy/private PTT setter assignments found outside AudioToText.gd")
		quit(0)
	else:
		printerr("FAIL: %d offending line(s) found:" % offenders.size())
		for entry in offenders:
			printerr("  " + entry)
		quit(1)


func _scan_dir(path: String, offenders: Array[String]) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		var full_path: String = path + entry
		if dir.current_is_dir():
			_scan_dir(full_path + "/", offenders)
		elif entry.ends_with(".gd"):
			# Exclude AudioToText.gd itself.
			if not full_path.ends_with(EXCLUDE_FILE):
				_scan_file(full_path, offenders)
		entry = dir.get_next()
	dir.list_dir_end()


func _scan_file(res_path: String, offenders: Array[String]) -> void:
	var file := FileAccess.open(res_path, FileAccess.READ)
	if file == null:
		return
	var line_num := 0
	while not file.eof_reached():
		line_num += 1
		var line := file.get_line()
		if _line_matches(line):
			offenders.append("%s:%d: %s" % [res_path, line_num, line.strip_edges()])
	file.close()


## Returns true if the line contains one of the guarded object-qualified setter patterns.
func _line_matches(line: String) -> bool:
	# Skip comment lines.
	var stripped := line.strip_edges()
	if stripped.begins_with("#"):
		return false
	for prefix in OBJECT_PREFIXES:
		if prefix in line:
			for field in FIELD_NAMES:
				var pattern := prefix + field
				if pattern in line:
					# Confirm it's an assignment (= follows, ignoring == comparisons).
					var idx := line.find(pattern)
					if idx == -1:
						continue
					var after := line.substr(idx + pattern.length()).strip_edges()
					if after.begins_with("=") and not after.begins_with("=="):
						return true
	return false
