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
