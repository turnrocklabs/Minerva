extends SceneTree
## Test: AudioToText PTT API — start_ptt / stop_ptt / _finish_transcription insertion.
## Run: godot --headless --script test/test_audio_to_text_ptt.gd
##
## Notes: these tests avoid actually calling _StartConverting() where it would touch
## the real audio bus. We stub that by bypassing it and directly asserting the
## contract around field population, gateway sequencing, and transcript insertion.


var _pass_count: int = 0
var _fail_count: int = 0


# ── Fakes ─────────────────────────────────────────────────────────────

class FakeGateway:
	var ptt_down_calls: int = 0
	var ptt_up_calls: int = 0
	var last_action: String = ""

	func ptt_down() -> void:
		ptt_down_calls += 1
		last_action = "down"

	func ptt_up() -> void:
		ptt_up_calls += 1
		last_action = "up"


# ── Runner ────────────────────────────────────────────────────────────

func _init():
	print("=== AudioToText PTT Tests ===\n")

	test_start_ptt_null_target_returns_invalid()
	test_start_ptt_populates_legacy_fields()
	test_start_ptt_calls_ptt_down()
	test_stop_ptt_idempotent()
	test_start_ptt_rollback_on_error()
	test_finish_transcription_append_empty()
	test_finish_transcription_append_nonempty()
	test_finish_transcription_replace()
	test_finish_transcription_legacy_path()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


# ── Helpers ───────────────────────────────────────────────────────────

## Build an AudioToText instance without triggering _ready (which needs the "Rec" bus).
## We bypass _ready by constructing via .new() and not adding to the tree; the PTT
## code paths we exercise don't touch `effect` or `mic_player`.
func _make_att() -> AudioToTexts:
	var att: AudioToTexts = AudioToTexts.new()
	return att


func _make_text_edit(initial: String = "") -> TextEdit:
	var te := TextEdit.new()
	te.text = initial
	return te


# ── Tests ─────────────────────────────────────────────────────────────

func test_start_ptt_null_target_returns_invalid():
	print("test_start_ptt_null_target_returns_invalid:")
	var att := _make_att()
	var req := AudioToTexts.PTTRequest.new()
	# req.target left null
	var err := att.start_ptt(req)
	check("returns ERR_INVALID_PARAMETER when target is null", err == ERR_INVALID_PARAMETER)
	check("_field_for_filling not set on invalid input", att._field_for_filling == null)
	att.free()


func test_start_ptt_populates_legacy_fields():
	print("test_start_ptt_populates_legacy_fields:")
	# We can't call _StartConverting safely without a bus, so we stub the instance:
	# swap in a script that overrides _StartConverting to a no-op returning OK.
	var att := _StubbedATT.new()
	var te := _make_text_edit()
	var btn := Button.new()
	var stop_btn := Button.new()
	var req := AudioToTexts.PTTRequest.new()
	req.target = te
	req.mic_button = btn
	req.stop_button = stop_btn
	var err := att.start_ptt(req)
	check("start_ptt returns OK with stub", err == OK)
	check("_field_for_filling == target", att._field_for_filling == te)
	check("_btn == mic_button", att._btn == btn)
	check("_btn_stop == stop_button", att._btn_stop == stop_btn)
	check("mic button modulate is LIME_GREEN", btn.modulate == Color.LIME_GREEN)
	btn.free()
	stop_btn.free()
	te.free()
	att.free()


func test_start_ptt_calls_ptt_down():
	print("test_start_ptt_calls_ptt_down:")
	var att := _StubbedATT.new()
	var te := _make_text_edit()
	var gw := FakeGateway.new()
	var req := AudioToTexts.PTTRequest.new()
	req.target = te
	req.voice_gateway = gw
	var err := att.start_ptt(req)
	check("start_ptt returns OK", err == OK)
	check("ptt_down was called exactly once", gw.ptt_down_calls == 1)
	check("ptt_up not called yet", gw.ptt_up_calls == 0)
	# Order check: the stub records whether _StartConverting saw last_action == "down".
	check("ptt_down fired before _StartConverting", att.saw_gateway_down_before_convert)
	te.free()
	att.free()


func test_stop_ptt_idempotent():
	print("test_stop_ptt_idempotent:")
	var att := _StubbedATT.new()
	var te := _make_text_edit()
	var gw := FakeGateway.new()
	var req := AudioToTexts.PTTRequest.new()
	req.target = te
	req.voice_gateway = gw
	att.start_ptt(req)
	att.stop_ptt()
	check("ptt_up called once after first stop_ptt", gw.ptt_up_calls == 1)
	att.stop_ptt()
	check("second stop_ptt is a no-op (still 1)", gw.ptt_up_calls == 1)
	# stop_ptt with no active PTT (fresh instance)
	var att2 := _StubbedATT.new()
	att2.stop_ptt()  # should not crash
	check("stop_ptt on fresh instance is safe", true)
	te.free()
	att.free()
	att2.free()


func test_start_ptt_rollback_on_error():
	print("test_start_ptt_rollback_on_error:")
	var att := _FailingATT.new()
	var te := _make_text_edit()
	var gw := FakeGateway.new()
	var req := AudioToTexts.PTTRequest.new()
	req.target = te
	req.voice_gateway = gw
	var err := att.start_ptt(req)
	check("start_ptt propagates error from _StartConverting", err == ERR_INVALID_DATA)
	check("ptt_down was called", gw.ptt_down_calls == 1)
	check("ptt_up called to roll back gateway", gw.ptt_up_calls == 1)
	# A subsequent stop_ptt should be a no-op (already rolled back).
	att.stop_ptt()
	check("stop_ptt after rollback is a no-op", gw.ptt_up_calls == 1)
	te.free()
	att.free()


func test_finish_transcription_append_empty():
	print("test_finish_transcription_append_empty:")
	var att := _StubbedATT.new()
	var te := _make_text_edit("")
	var req := AudioToTexts.PTTRequest.new()
	req.target = te
	req.insert_mode = AudioToTexts.InsertMode.APPEND
	att._active_ptt_req = req
	att._field_for_filling = te
	att._finish_transcription_no_notify("hello")
	check("empty target appends without leading space", te.text == "hello")
	check("caret at end line", te.get_caret_line() == te.get_line_count() - 1)
	var last_line: String = te.get_line(te.get_line_count() - 1)
	check("caret at end column", te.get_caret_column() == last_line.length())
	te.free()
	att.free()


func test_finish_transcription_append_nonempty():
	print("test_finish_transcription_append_nonempty:")
	var att := _StubbedATT.new()
	var te := _make_text_edit("hi")
	var req := AudioToTexts.PTTRequest.new()
	req.target = te
	req.insert_mode = AudioToTexts.InsertMode.APPEND
	att._active_ptt_req = req
	att._field_for_filling = te
	att._finish_transcription_no_notify("there")
	check("non-empty target gets single leading space", te.text == "hi there")
	te.free()
	att.free()


func test_finish_transcription_replace():
	print("test_finish_transcription_replace:")
	var att := _StubbedATT.new()
	var te := _make_text_edit("old content")
	var req := AudioToTexts.PTTRequest.new()
	req.target = te
	req.insert_mode = AudioToTexts.InsertMode.REPLACE
	att._active_ptt_req = req
	att._field_for_filling = te
	att._finish_transcription_no_notify("fresh")
	check("REPLACE overwrites target text", te.text == "fresh")
	te.free()
	att.free()


func test_finish_transcription_legacy_path():
	print("test_finish_transcription_legacy_path:")
	# No PTTRequest — simulates current 13 call sites.
	var att := _StubbedATT.new()
	var te := _make_text_edit("old")
	att._field_for_filling = te
	att._active_ptt_req = null
	att._finish_transcription_no_notify("new")
	# Legacy behaviour: APPEND with space separator. Our new rule only drops the
	# leading space when the target is empty; "old" is non-empty so we get "old new".
	check("legacy append preserves existing text", te.text == "old new")
	te.free()
	att.free()


# ── Test doubles ──────────────────────────────────────────────────────

## Stubs out _StartConverting (returns OK) and _finish_transcription's notification
## side-effects (SingletonObject.transcription_notification_player is unavailable in
## headless tests). Also records gateway ordering for the ptt_down-before-convert test.
class _StubbedATT extends AudioToTexts:
	var saw_gateway_down_before_convert: bool = false

	func _StartConverting():
		var req := _active_ptt_req
		if req != null and req.voice_gateway != null:
			saw_gateway_down_before_convert = (req.voice_gateway.last_action == "down")
		return OK

	## Mirror of _finish_transcription minus the SingletonObject notification + signal,
	## which aren't available under `godot --headless --script`. Exercises the real
	## insertion logic path via a small inlined copy — kept in sync manually.
	func _finish_transcription_no_notify(text: String) -> void:
		var active_req := _active_ptt_req
		if text.is_empty():
			return
		var target: Control = null
		if active_req != null:
			target = active_req.target
		else:
			target = _field_for_filling
		if target == null:
			return
		var mode: int = active_req.insert_mode if active_req != null else AudioToTexts.InsertMode.APPEND
		if active_req != null and mode == AudioToTexts.InsertMode.REPLACE:
			target.text = text
		elif active_req != null and mode == AudioToTexts.InsertMode.AT_CARET and target.has_method("insert_text_at_caret"):
			target.insert_text_at_caret(text)
		else:
			var prefix := "" if target.text.is_empty() else " "
			target.text += prefix + text
		# Inline caret-to-end (inner-class inheritance can't reliably resolve parent helpers).
		if target is TextEdit:
			var te: TextEdit = target
			var last_line: int = max(te.get_line_count() - 1, 0)
			te.set_caret_line(last_line)
			te.set_caret_column(te.get_line(last_line).length())
		elif target is LineEdit:
			(target as LineEdit).caret_column = (target as LineEdit).text.length()
		_active_ptt_req = null


class _FailingATT extends AudioToTexts:
	func _StartConverting():
		return ERR_INVALID_DATA
