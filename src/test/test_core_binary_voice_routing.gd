extends SceneTree
## Voice TTS binary-frame routing — regression guard for the "audio leaks into the
## file collector" class of bug.
##
## Run: godot --headless --path src --script test/test_core_binary_voice_routing.gd
##
## Root cause this guards against:
##   core_client._handle_binary_frame() used to track ONE global transfer
##   (_binary_transfer_mode / _binary_files). The voice synth accumulates its
##   audio in _binary_files[0]. When a SECOND binary transfer (image gen, artifact)
##   interleaves, its NEW_MESSAGE both (a) flips the global mode away from "voice"
##   and (b) calls _reset_binary_transfer_state(), wiping _binary_files[0]. The
##   voice FILE_END then falls through to the media-gen branch and the audio is
##   written to disk / dropped instead of landing in _voice_binary_buffers.
##   take_voice_binary() returns empty -> synth hangs on "Synthesizing speech…".
##   Prefs preview works because nothing else is transferring; chat breaks because
##   transfers interleave.
##
## The fix routes voice streams by their per-frame msg_id (bytes 1..17 of every
## binary frame — the protocol's stream id), in a dedicated _voice_streams
## registry that the shared media-gen/artifact state can never clobber.
##
## Acceptance:
##   1. Happy path: a clean voice transfer -> take_voice_binary() returns the WAV.
##   2. INTERLEAVE (the bug): a media-gen NEW_MESSAGE arrives mid-voice-stream;
##      the voice audio STILL lands in the voice buffer intact. (Red on old code.)
##   3. No regression: a media-gen transfer still emits image_received with the
##      right request_id + buffer.
##   4. Fail-safe: voice FILE_* frames with NO preceding NEW_MESSAGE are dropped,
##      never written to the file collector / voice buffer.
##
## NOTE: class_name globals are invisible to --script runs; load() + duck-type.

const CORE_CLIENT_PATH := "res://Scripts/Services/Providers/Core/core_client.gd"

const NEW_MESSAGE := 0
const FILE_INFO := 1
const FILE_DATA := 2
const FILE_END := 3

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Core binary voice-routing test ===\n")
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


# --- Frame construction helpers (mirror the wire format) --------------------

func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b


func _u64(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(8)
	for i in range(8):
		b[i] = (v >> (i * 8)) & 0xFF
	return b


## A binary frame is: [frame_type:1B][msg_id:16B][payload…]
func _frame(frame_type: int, msg_id: PackedByteArray, payload: PackedByteArray) -> PackedByteArray:
	var id := msg_id.duplicate()
	id.resize(16)
	var f := PackedByteArray()
	f.append(frame_type)
	f.append_array(id)
	f.append_array(payload)
	return f


func _id(byte_val: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(16)
	b.fill(byte_val)
	return b


func _new_message_payload(header: Dictionary, num_files: int) -> PackedByteArray:
	var json_bytes := JSON.stringify(header).to_utf8_buffer()
	var p := PackedByteArray()
	p.append_array(_u32(json_bytes.size()))
	p.append_array(_u32(num_files))
	p.append_array(json_bytes)
	return p


func _voice_file_info_payload(path: String, file_size: int) -> PackedByteArray:
	# Voice Format A: [path_len:u32][file_size:u32][path]
	var pb := path.to_utf8_buffer()
	var p := PackedByteArray()
	p.append_array(_u32(pb.size()))
	p.append_array(_u32(file_size))
	p.append_array(pb)
	return p


func _media_file_info_payload(name: String, file_size: int) -> PackedByteArray:
	# Media-gen Format: [file_size:u64][name_len:u32][name]
	var nb := name.to_utf8_buffer()
	var p := PackedByteArray()
	p.append_array(_u64(file_size))
	p.append_array(_u32(nb.size()))
	p.append_array(nb)
	return p


# --- The suite -------------------------------------------------------------

func _run() -> void:
	await process_frame
	var CC = load(CORE_CLIENT_PATH)
	check("CoreClient script loads", CC != null)
	if CC == null:
		return

	_test_happy_path(CC)
	_test_interleaved_transfer(CC)
	_test_media_gen_no_regression(CC)
	_test_missing_new_message_failsafe(CC)


## 1. Clean voice transfer -> audio in voice buffer.
func _test_happy_path(CC) -> void:
	var client = CC.new()
	var V := _id(0xA1)
	var rid := "voice-req-happy"
	var audio := PackedByteArray([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])

	client._handle_binary_frame(_frame(NEW_MESSAGE, V, _new_message_payload(
		{"cmd": "response", "topic": "voice/tts/synthesize", "params": {"request_id": rid}}, 1)))
	client._handle_binary_frame(_frame(FILE_INFO, V, _voice_file_info_payload("out.wav", audio.size())))
	client._handle_binary_frame(_frame(FILE_DATA, V, audio))
	client._handle_binary_frame(_frame(FILE_END, V, PackedByteArray()))

	var got: PackedByteArray = client.take_voice_binary(rid)
	check("happy path: voice audio lands in voice buffer", got == audio,
		"expected %s got %s" % [audio, got])
	client.free()


## 2. THE BUG: media-gen NEW_MESSAGE interleaves mid-voice-stream.
##    Voice audio must survive intact in the voice buffer.
func _test_interleaved_transfer(CC) -> void:
	var client = CC.new()
	var V := _id(0xA1)   # voice stream
	var M := _id(0xB2)   # media-gen stream
	var rid := "voice-req-interleaved"
	var chunk1 := PackedByteArray([0x11, 0x22, 0x33])
	var chunk2 := PackedByteArray([0x44, 0x55, 0x66, 0x77])
	var full := chunk1 + chunk2

	# Voice transfer begins…
	client._handle_binary_frame(_frame(NEW_MESSAGE, V, _new_message_payload(
		{"cmd": "response", "topic": "voice/tts/synthesize", "params": {"request_id": rid}}, 1)))
	client._handle_binary_frame(_frame(FILE_INFO, V, _voice_file_info_payload("out.wav", full.size())))
	client._handle_binary_frame(_frame(FILE_DATA, V, chunk1))

	# …a media-gen transfer interleaves (this is what flips/wipes the global state).
	client._handle_binary_frame(_frame(NEW_MESSAGE, M, _new_message_payload(
		{"cmd": "response", "topic": "media_gen/image_generation", "params": {"request_id": "img-x"}}, 1)))

	# …voice stream continues and finishes.
	client._handle_binary_frame(_frame(FILE_DATA, V, chunk2))
	client._handle_binary_frame(_frame(FILE_END, V, PackedByteArray()))

	var got: PackedByteArray = client.take_voice_binary(rid)
	check("interleave: voice audio intact despite mid-stream media-gen NEW_MESSAGE",
		got == full, "expected %s got %s" % [full, got])
	client.free()


## 3. Media-gen still routes to image_received (no regression).
func _test_media_gen_no_regression(CC) -> void:
	var client = CC.new()
	var M := _id(0xC3)
	var rid := "img-req-1"
	var img := PackedByteArray([0xDE, 0xAD, 0xBE, 0xEF])

	var captured := {"fired": false, "rid": "", "buf": PackedByteArray()}
	client.image_received.connect(func(_fname: String, req: String, buf: PackedByteArray):
		captured["fired"] = true
		captured["rid"] = req
		captured["buf"] = buf)

	client._handle_binary_frame(_frame(NEW_MESSAGE, M, _new_message_payload(
		{"cmd": "response", "topic": "media_gen/image_generation", "params": {"request_id": rid}}, 1)))
	client._handle_binary_frame(_frame(FILE_INFO, M, _media_file_info_payload("pic.png", img.size())))
	client._handle_binary_frame(_frame(FILE_DATA, M, img))
	client._handle_binary_frame(_frame(FILE_END, M, _u32(0)))

	check("media-gen: image_received fired", captured["fired"])
	check("media-gen: image_received has correct request_id", captured["rid"] == rid,
		"got %s" % captured["rid"])
	check("media-gen: image_received buffer intact", captured["buf"] == img,
		"expected %s got %s" % [img, captured["buf"]])
	client.free()


## 4. Fail-safe: voice FILE_* with no NEW_MESSAGE must NOT misroute.
func _test_missing_new_message_failsafe(CC) -> void:
	var client = CC.new()
	var V := _id(0xD4)
	var img_fired := {"v": false}
	client.image_received.connect(func(_f, _r, _b): img_fired["v"] = true)

	# No NEW_MESSAGE — frames arrive cold (e.g. header missed).
	client._handle_binary_frame(_frame(FILE_INFO, V, _voice_file_info_payload("out.wav", 4)))
	client._handle_binary_frame(_frame(FILE_DATA, V, PackedByteArray([1, 2, 3, 4])))
	client._handle_binary_frame(_frame(FILE_END, V, PackedByteArray()))

	check("failsafe: orphan voice frames not misrouted to image collector", not img_fired["v"])
	check("failsafe: orphan voice frames produce no voice buffer entry",
		client.take_voice_binary("anything").is_empty())
	client.free()
