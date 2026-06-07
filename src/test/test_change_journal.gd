extends SceneTree
## Unit tests for ChangeJournal (work item 019ea01719a2 — review diff backbone).
## Run: godot --headless --path src --script test/test_change_journal.gd

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== ChangeJournal tests ===")

	test_tracks_edits_and_diffs()
	test_mark_rebaselines()
	test_attribution_one_shot()
	test_changeset_summary_multi_file()
	test_revert_restores_baseline()
	test_revert_save_flushes_disk()
	test_revert_changeset_and_attribution()
	test_revert_reentrancy_then_edit()

	print("=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func _eq(desc: String, actual: Variant, expected: Variant) -> void:
	_check("%s (got %s)" % [desc, str(actual)], actual == expected)


# ── Tests ─────────────────────────────────────────────────────────────────────

func test_tracks_edits_and_diffs() -> void:
	print("test_tracks_edits_and_diffs:")
	var j := ChangeJournal.new("proj1")
	var buf := _MockBuf.new("a\nb\nc")
	j.track_buffer("main.gd", buf)
	_eq("clean file: no changed paths", j.changed_paths(), [])
	buf.edit("a\nb\nc\nd")  # append a line
	_eq("edited file shows up as changed", j.changed_paths(), ["main.gd"])
	var d := j.diff_for("main.gd")
	_eq("one add", d["adds"], 1)
	_eq("no dels", d["dels"], 0)
	_eq("baseline preserved (diff vs original, not vs nothing)", d["dels"], 0)


func test_mark_rebaselines() -> void:
	print("test_mark_rebaselines:")
	var j := ChangeJournal.new()
	var buf := _MockBuf.new("x")
	j.track_buffer("f.gd", buf)
	buf.edit("x\ny")
	_eq("changed before mark", j.changed_paths(), ["f.gd"])
	j.mark("turn:1", "ai")
	_eq("mark re-baselines -> nothing changed", j.changed_paths(), [])
	buf.edit("x\ny\nz")
	_eq("new edit after mark is changed again", j.changed_paths(), ["f.gd"])
	var d := j.diff_for("f.gd")
	_eq("diff is since the mark (1 add, not 2)", d["adds"], 1)


func test_attribution_one_shot() -> void:
	print("test_attribution_one_shot:")
	var j := ChangeJournal.new()
	var buf := _MockBuf.new("base")
	j.track_buffer("f.gd", buf)
	j.attribute_next_edit_to("ai")
	buf.edit("base\nfrom-agent")
	_eq("agent edit tagged ai", j.diff_for("f.gd")["source"], "ai")
	buf.edit("base\nfrom-agent\nfrom-human")  # no attribution set
	_eq("subsequent edit defaults to human", j.diff_for("f.gd")["source"], "human")


func test_changeset_summary_multi_file() -> void:
	print("test_changeset_summary_multi_file:")
	var j := ChangeJournal.new()
	var a := _MockBuf.new("1\n2\n3")
	var b := _MockBuf.new("alpha")
	j.track_buffer("a.gd", a)
	j.track_buffer("b.gd", b)
	j.mark("turn:7", "ai")
	a.edit("1\n2\n3\n4\n5")  # +2
	b.edit("")              # delete the only line
	var sum := j.changeset_summary()
	_eq("changeset label", sum["label"], "turn:7")
	_eq("changeset source", sum["source"], "ai")
	_eq("two files in the changeset", (sum["files"] as Array).size(), 2)


# ── P2: revert (DCR 019ea404ffcd) — real DocumentRegistry buffers ─────────────

var _tmp_seq := 0

# Unique temp file under user:// (absolute) seeded with `content`.
func _tmp_file(content: String) -> String:
	_tmp_seq += 1
	var abs := ProjectSettings.globalize_path("user://journal_revert_test_%d.txt" % _tmp_seq)
	var f := FileAccess.open(abs, FileAccess.WRITE)
	f.store_string(content)
	f.close()
	return abs

func _track_real(j: ChangeJournal, path: String):
	var reg := DocumentRegistry.get_instance()
	var r := reg.get_or_create_buffer(path)
	var buf = r["buffer"]
	j.track_buffer(buf.file_path, buf)
	return buf


func test_revert_restores_baseline() -> void:
	print("test_revert_restores_baseline:")
	var j := ChangeJournal.new("p")
	var path := _tmp_file("BASE")
	var buf = _track_real(j, path)
	j.mark("turn", "ai")
	buf.apply_edit("BASE\nAGENT EDIT")  # closed-file edit (no editor open in headless)
	_eq("file is changed", j.changed_paths().has(buf.file_path), true)
	var r := j.revert(buf.file_path)
	_eq("revert ok", r.get("ok"), true)
	_eq("revert reported reverted", r.get("reverted"), true)
	_eq("buffer text back to baseline", buf.text, "BASE")
	_eq("no longer changed", j.changed_paths(), [])
	# no-op revert when already at baseline
	var r2 := j.revert(buf.file_path)
	_eq("second revert is a no-op", r2.get("reverted"), false)


func test_revert_save_flushes_disk() -> void:
	print("test_revert_save_flushes_disk:")
	var j := ChangeJournal.new("p")
	var path := _tmp_file("DISK BASE")
	var buf = _track_real(j, path)
	j.mark("turn")
	buf.apply_edit("DISK BASE\nedited then saved to disk")
	buf.save_to_disk()  # disk now has the edit
	j.revert(buf.file_path, true)  # revert WITH save
	var on_disk := FileAccess.get_file_as_string(buf.file_path)
	_eq("disk restored to baseline by save-revert", on_disk, "DISK BASE")


func test_revert_changeset_and_attribution() -> void:
	print("test_revert_changeset_and_attribution:")
	var j := ChangeJournal.new("p")
	var pa := _tmp_file("A0")
	var pb := _tmp_file("B0")
	var a = _track_real(j, pa)
	var b = _track_real(j, pb)
	j.mark("turn", "ai")
	j.attribute_next_edit_to("ai")
	a.apply_edit("A0\nai-change")     # a: last edit ai
	b.apply_edit("B0\nhuman-change")  # b: last edit human (default)
	# source-filtered revert: only the ai file
	var res := j.revert_changeset(false, "ai")
	_eq("ai file reverted", (res["reverted"] as Array).has(a.file_path), true)
	_eq("human file skipped", (res["skipped"] as Array).has(b.file_path), true)
	_eq("a back to baseline", a.text, "A0")
	_eq("b untouched", b.text, "B0\nhuman-change")
	# now revert the rest (whole changeset)
	var res2 := j.revert_changeset()
	_eq("b now reverted", b.text, "B0")
	_eq("changeset clean", j.changed_paths(), [])


func test_revert_reentrancy_then_edit() -> void:
	print("test_revert_reentrancy_then_edit:")
	var j := ChangeJournal.new("p")
	var path := _tmp_file("R0")
	var buf = _track_real(j, path)
	j.mark("turn")
	buf.apply_edit("R0\nx")
	j.revert(buf.file_path)
	# the revert write must NOT have been recorded as a fresh changed path
	_eq("clean after revert (revert not self-recorded)", j.changed_paths(), [])
	# a normal edit after a revert still records (attribution back to human)
	buf.apply_edit("R0\ny")
	_eq("post-revert edit recorded", j.changed_paths().has(buf.file_path), true)
	_eq("post-revert edit attributed human", j.diff_for(buf.file_path)["source"], "human")


# ── Mock buffer (mirrors DocumentBuffer's text_changed(text, version)) ─────────

class _MockBuf extends RefCounted:
	signal text_changed(text: String, version: int)
	var text: String = ""
	var version: int = 0

	func _init(initial: String = "") -> void:
		text = initial

	func edit(t: String) -> void:
		text = t
		version += 1
		text_changed.emit(text, version)
