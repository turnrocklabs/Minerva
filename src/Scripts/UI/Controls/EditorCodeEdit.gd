class_name EditorCodeEdit
extends CodeEdit

## Content of the saved version of this code edit.[br]
## Every time the editor content is saved, this should be updated.
var saved_content: String


func _ready() -> void:
	size_flags_vertical = SizeFlags.SIZE_EXPAND_FILL
	caret_blink = true
	caret_multiple = false
	highlight_all_occurrences = true
	highlight_current_line = true
	gutters_draw_line_numbers = true
	gutters_zero_pad_line_numbers = true
	autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	name = "CodeEdit"
	line_folding = true
	editable = true

func apply_diff(diff: String) -> void:
	# 1) Convert current text into an editable Array[String]
	var lines: Array[String] = []
	for l in text.split("\n"):
		lines.append(l)

	# 2) Split diff text into lines
	var diff_lines: PackedStringArray = diff.split("\n")

	# 3) Regex to match unified-diff hunk headers: @@ -a,b +c,d @@
	var hunk_re := RegEx.new()
	hunk_re.compile("@@ -([0-9]+),?([0-9]*) +\\+([0-9]+),?([0-9]*) @@")

	var i := 0
	while i < diff_lines.size():
		var header := diff_lines[i]

		if header.begins_with("@@"):
			var m := hunk_re.search(header)
			if m:
				# -- Parse header values --
				var orig_start := int(m.get_string(1)) - 1	# 0-based
				var orig_len := 1
				if m.get_string(2) != "":
					orig_len = int(m.get_string(2))

				var new_len := 1
				if m.get_string(4) != "":
					new_len = int(m.get_string(4))

				# -- Collect replacement lines (context + additions) --
				var new_lines: Array[String] = []
				i += 1
				while i < diff_lines.size() and not diff_lines[i].begins_with("@@"):
					var dl := diff_lines[i]
					if dl.begins_with(" ") or dl.begins_with("+"):
						new_lines.append(dl.substr(1))	# strip leading char
					# deletions ("-") are skipped
					i += 1

				# -- Remove original lines --
				for _idx in range(orig_len):
					if orig_start < lines.size():
						lines.remove_at(orig_start)

				# -- Insert replacement lines --
				for j in range(new_lines.size()):
					lines.insert(orig_start + j, new_lines[j])

				# continue outer while (i already advanced inside while)
				continue

		# Not a hunk header → advance
		i += 1

	# 4) Reassemble text and update saved_content
	text = "\n".join(lines)
	saved_content = text

# --------------------------------------------------------------------
# Diff preview helpers (accurate unified diff – keep "-" lines, add "+" lines)
# --------------------------------------------------------------------
var _preview_original_text: String = ""
var _preview_highlighted: Array[int] = []


func clear_diff_preview() -> void:
	if _preview_original_text == "":
		return

	text = _preview_original_text
	_preview_original_text = ""

	for ln in _preview_highlighted:
		if ln < get_line_count():
			set_line_background_color(ln, Color(0, 0, 0, 0))
	_preview_highlighted.clear()


func preview_diff(diff: String) -> void:
	# ---------- reset any old preview ----------
	clear_diff_preview()

	# ---------- save current buffer for later ----------
	_preview_original_text = text

	# Work on a mutable copy of the buffer
	var lines: Array[String] = []
	for l in text.split("\n"):
		lines.append(l)

	# Split diff and prep header regex
	var diff_lines := diff.split("\n")
	var hunk_re := RegEx.new()
	hunk_re.compile("@@ -([0-9]+),?([0-9]*) +\\+([0-9]+),?([0-9]*) @@")

	var additions: Array[int] = []
	var deletions: Array[int] = []

	var i := 0
	var line_offset := 0		# tracks cumulative insertions

	while i < diff_lines.size():
		if diff_lines[i].begins_with("@@"):
			var m := hunk_re.search(diff_lines[i])
			if m:
				# Map original line number to current preview buffer
				var orig_start := int(m.get_string(1)) - 1
				var current_idx := orig_start + line_offset
				
				# Track where we are in the original file for this hunk
				var orig_line_counter := 0

				i += 1		# move to first body line
				while i < diff_lines.size() and not diff_lines[i].begins_with("@@"):
					var dl := diff_lines[i]

					if dl.begins_with(" "):
						# Context line: exists in both versions
						current_idx += 1
						orig_line_counter += 1

					elif dl.begins_with("-"):
						# Deletion: mark existing line for red highlight
						deletions.append(current_idx)
						current_idx += 1
						orig_line_counter += 1

					elif dl.begins_with("+"):
						# Insertion: insert new line and highlight green
						var new_content := dl.substr(1)
						lines.insert(current_idx, new_content)
						additions.append(current_idx)
						current_idx += 1
						line_offset += 1	# track that we added a line

					i += 1
				continue	# next hunk
		i += 1

	# ---------- update editor ----------
	text = "\n".join(lines)

	# ---------- apply highlights ----------
	var green := Color(0.25, 1.0, 0.25, 0.35)
	var red   := Color(1.0, 0.25, 0.25, 0.35)

	for ln in additions:
		if ln < get_line_count():
			_highlight_line(ln, green)

	for ln in deletions:
		if ln < get_line_count():
			_highlight_line(ln, red)


func _highlight_line(line_idx: int, color: Color) -> void:
	set_line_background_color(line_idx, color)
	_preview_highlighted.append(line_idx)
