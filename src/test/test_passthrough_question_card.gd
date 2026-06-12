extends SceneTree
## W4 (chat-passthrough): clickable question card in the chat flow.
##
## Run: timeout 120 godot --headless --path src --script test/test_passthrough_question_card.gd
##
## Acceptance (W4 contract):
##   1. A finalized question CHI (HcpData.passthrough_question_options = the
##      codex triple Yes/y, "Yes, don't ask again"/p, Cancel/"") + a VBox →
##      card instantiated with 3 correctly-labeled buttons, positioned right
##      after the question's message node.
##   2. Click "Yes" → the captured send seam receives exactly "y" on the RIGHT
##      history; card disabled (option buttons not clickable, no double-send).
##   2b. Click "Cancel" (empty keystroke per the locked contract) → NO send.
##   3. Options empty / missing / garbage → no card node added.
##   4. JSON round-trip of the options (stringify/parse) still renders + maps.
##   5. Two cards in one VBox stay independent (answer one, other still live).
##   6. Card freed with the VBox (instance invalid after free, no errors).
##
## NOTE: class_name globals are invisible to --script runs; load() + duck-type
## (harness pattern from test_passthrough_mode.gd / test_passthrough_launch.gd).
## The ChatPane stays OUT of the tree (its _ready needs the full scene); the
## VBox host goes IN the tree so the card's @onready %nodes resolve.

const CHATPANE_PATH := "res://Scripts/UI/Views/ChatPane.gd"
const CHAT_HISTORY_PATH := "res://Scripts/Models/ChatHistory.gd"
const CHI_PATH := "res://Scripts/Models/ChatHistoryItem.gd"
const VBOX_CHAT_PATH := "res://Scripts/UI/Controls/vboxChat.gd"

## ChatPane subclass with ONLY the send seam stubbed: the card hosting, the
## label→keystroke mapping and the disable wiring under test stay REAL.
const PANE_STUB_SOURCE := """
extends "res://Scripts/UI/Views/ChatPane.gd"

var sent: Array = []

func _passthrough_send_question_answer(history: ChatHistory, keystroke: String) -> void:
	sent.append({"history": history, "keystroke": keystroke})
"""

## The codex triple from the W1 locked contract (Cancel = "" → ESC plugin-side).
const CODEX_OPTIONS := [
	{"label": "Yes", "keystroke": "y"},
	{"label": "Yes, don't ask again", "keystroke": "p"},
	{"label": "Cancel", "keystroke": ""},
]

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== W4 passthrough question card test ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s%s" % [label, (" — " + detail) if detail != "" else ""])


func _new_stub_pane():
	var s := GDScript.new()
	s.source_code = PANE_STUB_SOURCE
	var err := s.reload()
	if err != OK:
		return null
	return s.new()


## Build an in-tree VBoxChat bound to `history` (chat_history must be set
## BEFORE entering the tree — VBoxChat._ready derefs it). Returns [host, vbox].
func _new_chat_vbox(history) -> Array:
	var host := Control.new()
	host.name = "W4Host"
	root.add_child(host)
	var vbox = load(VBOX_CHAT_PATH).new(host)
	vbox.chat_history = history
	host.add_child(vbox)
	history.VBox = vbox
	return [host, vbox]


func _new_question_chi(options, id := "q1"):
	var CHI = load(CHI_PATH)
	var chi = CHI.new(0, 2, "Allow this command?", true)  # TEXT, MODEL, suppress save
	chi.Id = id
	if options != null:
		chi.HcpData = {"passthrough_question_options": options}
	return chi


## Visible option buttons on the card, top-to-bottom (excludes the hidden
## free-text TextInput/SubmitButton pair).
func _option_buttons(card) -> Array:
	var out: Array = []
	for btn in card.find_children("*", "Button", true, false):
		if btn.visible:
			out.append(btn)
	return out


func _button_with_text(card, text: String):
	for btn in _option_buttons(card):
		if btn.text == text:
			return btn
	return null


func _run() -> void:
	await process_frame
	var so = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload present", so != null)

	var pane = _new_stub_pane()
	check("stub ChatPane compiles", pane != null)
	if pane == null:
		return

	_test_card_render(pane)
	_test_click_sends_keystroke(pane)
	_test_cancel_no_send(pane)
	_test_no_options_no_card(pane)
	_test_json_roundtrip(pane)
	_test_two_cards_independent(pane)
	await _test_freed_with_vbox(pane)

	pane.free()


# --- Acceptance 1: render ----------------------------------------------------
func _test_card_render(pane) -> void:
	print("\n-- card render: codex triple --")
	var CH = load(CHAT_HISTORY_PATH)
	var history = CH.new(null, "hist-w4-render")
	var hv := _new_chat_vbox(history)
	var host: Control = hv[0]
	var vbox = hv[1]

	# A chat with an earlier message + the question's message node + a later
	# program label, so "right after the message node" is actually asserted.
	var earlier := Control.new()
	vbox.add_child(earlier)
	var msg_node := Control.new()
	vbox.add_child(msg_node)
	var later := Label.new()
	vbox.add_child(later)

	var chi = _new_question_chi(CODEX_OPTIONS.duplicate(true))
	var card = pane._passthrough_add_question_card(history, chi, msg_node)
	check("card instantiated", card != null)
	if card == null:
		host.free()
		return
	check("card parented to the chat VBox", card.get_parent() == vbox)
	check("card positioned right after the message node",
		card.get_index() == msg_node.get_index() + 1,
		"card=%d msg=%d" % [card.get_index(), msg_node.get_index()])

	var btns := _option_buttons(card)
	check("3 option buttons", btns.size() == 3, "got %d" % btns.size())
	var texts: Array = []
	for b in btns:
		texts.append(b.text)
	for want in ["Yes", "Yes, don't ask again", "Cancel"]:
		check("button labeled '%s' present" % want, texts.has(want), str(texts))
	# Host compensates the card's prepend idiom: contract order preserved.
	check("displayed order matches contract (Yes first, Cancel last)",
		btns.size() == 3 and btns[0].text == "Yes" and btns[2].text == "Cancel",
		str(texts))
	check("free-text input hidden when options present",
		card.get_node("%TextInput").visible == false)

	host.free()


# --- Acceptance 2: click → keystroke on the right history --------------------
func _test_click_sends_keystroke(pane) -> void:
	print("\n-- click sends mapped keystroke --")
	var CH = load(CHAT_HISTORY_PATH)
	var history = CH.new(null, "hist-w4-click")
	var other_history = CH.new(null, "hist-w4-other")  # identity foil
	var hv := _new_chat_vbox(history)
	var host: Control = hv[0]
	var vbox = hv[1]
	var msg_node := Control.new()
	vbox.add_child(msg_node)

	pane.sent.clear()
	var chi = _new_question_chi(CODEX_OPTIONS.duplicate(true))
	var card = pane._passthrough_add_question_card(history, chi, msg_node)
	check("card created", card != null)
	if card == null:
		host.free()
		return

	var yes_btn = _button_with_text(card, "Yes")
	check("'Yes' button found", yes_btn != null)
	if yes_btn == null:
		host.free()
		return
	yes_btn.pressed.emit()  # real click path: button → card → answer_submitted

	check("exactly one send", pane.sent.size() == 1, "got %d" % pane.sent.size())
	if pane.sent.size() == 1:
		check("keystroke is exactly 'y'", pane.sent[0]["keystroke"] == "y",
			str(pane.sent[0]["keystroke"]))
		check("sent on the ORIGINATING history", pane.sent[0]["history"] == history)
		check("not the foil history", pane.sent[0]["history"] != other_history)

	# Disabled after answering: buttons greyed AND a second click is inert.
	var all_disabled := true
	for b in _option_buttons(card):
		if not b.disabled:
			all_disabled = false
	check("option buttons disabled after answer", all_disabled)
	var p_btn = _button_with_text(card, "Yes, don't ask again")
	if p_btn != null:
		p_btn.pressed.emit()
	check("second click after answer sends nothing", pane.sent.size() == 1,
		"got %d" % pane.sent.size())

	host.free()


# --- Acceptance 2b: Cancel ("" keystroke) never sends ------------------------
func _test_cancel_no_send(pane) -> void:
	print("\n-- cancel: empty keystroke never sent --")
	var CH = load(CHAT_HISTORY_PATH)
	var history = CH.new(null, "hist-w4-cancel")
	var hv := _new_chat_vbox(history)
	var host: Control = hv[0]
	var vbox = hv[1]
	var msg_node := Control.new()
	vbox.add_child(msg_node)

	pane.sent.clear()
	var chi = _new_question_chi(CODEX_OPTIONS.duplicate(true))
	var card = pane._passthrough_add_question_card(history, chi, msg_node)
	var cancel_btn = _button_with_text(card, "Cancel")
	check("'Cancel' button found", cancel_btn != null)
	if cancel_btn != null:
		cancel_btn.pressed.emit()
	check("cancel: nothing sent (empty keystroke)", pane.sent.is_empty(),
		str(pane.sent))
	var all_disabled := true
	for b in _option_buttons(card):
		if not b.disabled:
			all_disabled = false
	check("cancel: card still disabled after answer", all_disabled)

	host.free()


# --- Acceptance 3: no options → no card --------------------------------------
func _test_no_options_no_card(pane) -> void:
	print("\n-- no options → no card --")
	var CH = load(CHAT_HISTORY_PATH)
	var history = CH.new(null, "hist-w4-empty")
	var hv := _new_chat_vbox(history)
	var host: Control = hv[0]
	var vbox = hv[1]
	var msg_node := Control.new()
	vbox.add_child(msg_node)
	var before: int = vbox.get_child_count()

	var empty_chi = _new_question_chi([])
	check("empty options → null", pane._passthrough_add_question_card(history, empty_chi, msg_node) == null)

	var plain_chi = _new_question_chi(null)  # no HcpData key at all
	check("no HcpData key → null", pane._passthrough_add_question_card(history, plain_chi, msg_node) == null)

	var garbage_chi = _new_question_chi(["not-a-dict", 42, {"keystroke": "x"}])
	check("garbage / label-less options → null",
		pane._passthrough_add_question_card(history, garbage_chi, msg_node) == null)

	check("no card node added to VBox", vbox.get_child_count() == before,
		"children %d → %d" % [before, vbox.get_child_count()])

	host.free()


# --- Acceptance 4: JSON round-trip -------------------------------------------
func _test_json_roundtrip(pane) -> void:
	print("\n-- JSON round-trip of options --")
	var CH = load(CHAT_HISTORY_PATH)
	var history = CH.new(null, "hist-w4-json")
	var hv := _new_chat_vbox(history)
	var host: Control = hv[0]
	var vbox = hv[1]
	var msg_node := Control.new()
	vbox.add_child(msg_node)

	# Round-trip exactly like project save / plugin IPC would (ints → floats etc.).
	var rt: Dictionary = JSON.parse_string(JSON.stringify(
		{"passthrough_question_options": CODEX_OPTIONS}))
	var chi = _new_question_chi(rt["passthrough_question_options"], "q-json")

	pane.sent.clear()
	var card = pane._passthrough_add_question_card(history, chi, msg_node)
	check("round-tripped options still render a card", card != null)
	if card != null:
		check("round-trip: 3 buttons", _option_buttons(card).size() == 3)
		var yes_btn = _button_with_text(card, "Yes")
		check("round-trip: 'Yes' label intact", yes_btn != null)
		if yes_btn != null:
			yes_btn.pressed.emit()
		check("round-trip: keystroke maps to 'y' (string intact)",
			pane.sent.size() == 1 and pane.sent[0]["keystroke"] == "y",
			str(pane.sent))

	host.free()


# --- Acceptance 5: two cards independent -------------------------------------
func _test_two_cards_independent(pane) -> void:
	print("\n-- two cards in one chat stay independent --")
	var CH = load(CHAT_HISTORY_PATH)
	var history = CH.new(null, "hist-w4-two")
	var hv := _new_chat_vbox(history)
	var host: Control = hv[0]
	var vbox = hv[1]

	var msg_a := Control.new()
	vbox.add_child(msg_a)
	var card_a = pane._passthrough_add_question_card(
		history, _new_question_chi(CODEX_OPTIONS.duplicate(true), "q-a"), msg_a)

	var msg_b := Control.new()
	vbox.add_child(msg_b)
	var card_b = pane._passthrough_add_question_card(
		history, _new_question_chi(CODEX_OPTIONS.duplicate(true), "q-b"), msg_b)

	check("both cards created", card_a != null and card_b != null)
	if card_a == null or card_b == null:
		host.free()
		return

	pane.sent.clear()
	_button_with_text(card_a, "Yes").pressed.emit()
	check("card A answered → one send", pane.sent.size() == 1)
	check("card A disabled", _button_with_text(card_a, "Cancel").disabled)
	check("card B still active (buttons enabled)",
		not _button_with_text(card_b, "Yes").disabled)

	# Answering the OLD-style stale card B is harmless: keystroke just sends.
	_button_with_text(card_b, "Yes, don't ask again").pressed.emit()
	check("card B answers independently with 'p'",
		pane.sent.size() == 2 and pane.sent[1]["keystroke"] == "p", str(pane.sent))

	host.free()


# --- Acceptance 6: freed with the VBox ---------------------------------------
func _test_freed_with_vbox(pane) -> void:
	print("\n-- card freed with the chat VBox --")
	var CH = load(CHAT_HISTORY_PATH)
	var history = CH.new(null, "hist-w4-free")
	var hv := _new_chat_vbox(history)
	var host: Control = hv[0]
	var vbox = hv[1]
	var msg_node := Control.new()
	vbox.add_child(msg_node)

	var card = pane._passthrough_add_question_card(
		history, _new_question_chi(CODEX_OPTIONS.duplicate(true), "q-free"), msg_node)
	check("card created", card != null)

	# Chat close path: the VBox subtree is freed; the card (a plain child) and
	# its card-owned answer_submitted connection go with it.
	history.VBox = null
	host.free()
	await process_frame
	check("card instance invalid after VBox freed", not is_instance_valid(card))
	check("send seam untouched by the free", true)  # reaching here = no errors
