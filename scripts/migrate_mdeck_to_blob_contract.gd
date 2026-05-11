extends SceneTree
## One-off migration: rewrite a legacy presentation .mdeck file (image bytes
## stored as raw base64 strings) into the phase-5 R3 blob-envelope shape.
##
## Reads --input <path>, writes --output <path>. Existing file is preserved;
## migration writes to a sibling. Sniffs PNG/JPEG/GIF/WebP magic bytes for
## content_type. Idempotent: re-running on already-migrated decks is a no-op
## (already-wrapped envelopes are detected and skipped).
##
## Run:
##   godot --headless --path src --script scripts/migrate_mdeck_to_blob_contract.gd \
##     -- --input ~/temp/llms_overview_v1.mdeck \
##        --output ~/temp/llms_overview_v1.migrated.mdeck
##
## After migration, copy the output back over the original AFTER manually
## verifying the migrated deck renders in Minerva.

func _init() -> void:
	# get_cmdline_user_args returns only what follows `--` on the command line;
	# get_cmdline_args also returns Godot's own flags (--headless, --script, etc.)
	# which we'd have to skip past. Easier to use user_args.
	var argv: PackedStringArray = OS.get_cmdline_user_args()
	var input_path: String = ""
	var output_path: String = ""
	var i: int = 0
	while i < argv.size():
		match argv[i]:
			"--input":
				if i + 1 < argv.size():
					input_path = argv[i + 1]
					i += 2
					continue
			"--output":
				if i + 1 < argv.size():
					output_path = argv[i + 1]
					i += 2
					continue
		i += 1

	if input_path.is_empty() or output_path.is_empty():
		printerr("Usage: --input <path> --output <path>")
		quit(2)
		return

	# Expand ~ since Godot doesn't expand it for arbitrary args.
	if input_path.begins_with("~"):
		input_path = OS.get_environment("HOME") + input_path.substr(1)
	if output_path.begins_with("~"):
		output_path = OS.get_environment("HOME") + output_path.substr(1)

	if not FileAccess.file_exists(input_path):
		printerr("Input file does not exist: %s" % input_path)
		quit(3)
		return

	var f := FileAccess.open(input_path, FileAccess.READ)
	if f == null:
		printerr("Could not open input: %s" % input_path)
		quit(3)
		return
	var text: String = f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		printerr("Input is not a JSON Dictionary at the top level")
		quit(4)
		return
	var deck: Dictionary = parsed as Dictionary

	var tiles_wrapped: int = 0
	var bgs_wrapped: int = 0
	var tiles_already: int = 0
	var bgs_already: int = 0

	var slides_v: Variant = deck.get("slides", [])
	if not (slides_v is Array):
		printerr("deck.slides is not an Array")
		quit(5)
		return

	for slide_v in (slides_v as Array):
		if not (slide_v is Dictionary):
			continue
		var slide: Dictionary = slide_v as Dictionary

		# Background
		var bg_v: Variant = slide.get("background", null)
		if bg_v is Dictionary:
			var bg: Dictionary = bg_v as Dictionary
			if str(bg.get("kind", "")) == "image":
				var value_v: Variant = bg.get("value", null)
				if value_v is String:
					var s: String = value_v as String
					if not s.is_empty():
						var raw: PackedByteArray = Marshalls.base64_to_raw(s)
						var ct: String = _sniff(raw)
						bg["value"] = {
							"__blob__": true,
							"content_type": ct,
							"bytes": s,
						}
						bgs_wrapped += 1
				elif value_v is Dictionary and _is_envelope(value_v):
					bgs_already += 1

		# Tiles
		var tiles_v: Variant = slide.get("tiles", [])
		if tiles_v is Array:
			for tile_v in (tiles_v as Array):
				if not (tile_v is Dictionary):
					continue
				var tile: Dictionary = tile_v as Dictionary
				if str(tile.get("kind", "")) != "image":
					continue
				var src_v: Variant = tile.get("src", null)
				if src_v is String:
					var s2: String = src_v as String
					if not s2.is_empty():
						var raw2: PackedByteArray = Marshalls.base64_to_raw(s2)
						var ct2: String = _sniff(raw2)
						tile["src"] = {
							"__blob__": true,
							"content_type": ct2,
							"bytes": s2,
						}
						tiles_wrapped += 1
				elif src_v is Dictionary and _is_envelope(src_v):
					tiles_already += 1

	var output_text: String = JSON.stringify(deck)
	var out := FileAccess.open(output_path, FileAccess.WRITE)
	if out == null:
		printerr("Could not open output: %s" % output_path)
		quit(6)
		return
	out.store_string(output_text)
	out.close()

	print("Migration complete:")
	print("  input:  %s (%d bytes)" % [input_path, text.length()])
	print("  output: %s (%d bytes)" % [output_path, output_text.length()])
	print("  image tiles:        wrapped %d, already-wrapped %d" % [tiles_wrapped, tiles_already])
	print("  image backgrounds:  wrapped %d, already-wrapped %d" % [bgs_wrapped, bgs_already])
	quit(0)


func _is_envelope(d: Variant) -> bool:
	if not (d is Dictionary):
		return false
	var dd: Dictionary = d as Dictionary
	if not dd.has("__blob__"):
		return false
	# Per godot/gdscript-variant-local-equals-bool-raises hint: use inline
	# subscript compare (preserves Variant typing) rather than typed local.
	return dd["__blob__"] == true or dd["__blob__"] == 1 or dd["__blob__"] == 1.0


func _sniff(bytes: PackedByteArray) -> String:
	if bytes.size() >= 8 \
			and bytes[0] == 0x89 and bytes[1] == 0x50 \
			and bytes[2] == 0x4E and bytes[3] == 0x47:
		return "image/png"
	if bytes.size() >= 3 \
			and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF:
		return "image/jpeg"
	if bytes.size() >= 6 \
			and bytes[0] == 0x47 and bytes[1] == 0x49 and bytes[2] == 0x46:
		return "image/gif"
	if bytes.size() >= 12 \
			and bytes[0] == 0x52 and bytes[1] == 0x49 \
			and bytes[2] == 0x46 and bytes[3] == 0x46 \
			and bytes[8] == 0x57 and bytes[9] == 0x45 \
			and bytes[10] == 0x42 and bytes[11] == 0x50:
		return "image/webp"
	return "image/png"
