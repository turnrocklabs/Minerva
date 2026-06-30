extends SceneTree
## Functional tests for Stage A reasoning extraction.
## Exercises the REAL OpenRouterProvider.to_bot_response / extract_reasoning code
## path against captured-shape response dicts (no logic mocking), plus the
## BotResponse reasoning sequence helpers.
## Run: godot --headless --script test/test_reasoning_extraction.gd

var _pass_count: int = 0
var _fail_count: int = 0
var _skip_count: int = 0

## OpenRouterProvider._init touches the SingletonObject autoload; in some headless
## configs that autoload doesn't compile. Probe and skip provider tests if so.
var _provider_available: bool = false


func _init():
	print("=== Reasoning Extraction Tests (Stage A) ===\n")

	print("-- BotResponse reasoning sequence --")
	test_botresponse_add_reasoning()
	test_botresponse_empty_by_default()

	_provider_available = _probe_provider()
	if not _provider_available:
		print("  NOTE: OpenRouterProvider unavailable (autoload not compiled). Provider tests skipped.\n")
	else:
		print("\n-- OpenRouter extract_reasoning --")
		test_extract_flat_reasoning_string()
		test_extract_reasoning_details_array()
		test_extract_encrypted_is_redacted()
		test_extract_no_reasoning_is_empty()

	print("\n=== Results: %d passed, %d failed, %d skipped ===" % [_pass_count, _fail_count, _skip_count])
	quit(1 if _fail_count > 0 else 0)


func _ok(cond: bool, label: String) -> void:
	if cond:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s" % label)


func _probe_provider() -> bool:
	# Guard against the autoload-missing crash by checking the class exists and
	# is constructable. ClassDB won't help (it's a script class), so try/catch
	# is not available in GDScript — instead probe the autoload singleton.
	return Engine.has_singleton("SingletonObject") or _singleton_node_exists()


func _singleton_node_exists() -> bool:
	# SingletonObject is registered as an autoload Node, reachable from root.
	if root == null:
		return false
	return root.has_node("SingletonObject")


# ----------------------------------------------------------------------------
# BotResponse sequence helpers (no autoload dependency)
# ----------------------------------------------------------------------------

func test_botresponse_add_reasoning() -> void:
	var r := BotResponse.new()
	_ok(not r.has_reasoning(), "fresh BotResponse has no reasoning")
	r.add_reasoning("first thought", "thinking", false)
	r.add_reasoning("a summary", "summary", false)
	r.add_reasoning("", "thinking", true)
	_ok(r.has_reasoning(), "has_reasoning true after adds")
	_ok(r.reasoning.size() == 3, "three segments recorded")
	_ok(r.reasoning[0]["order"] == 0 and r.reasoning[2]["order"] == 2, "order preserved 0..2")
	_ok(r.reasoning[1]["kind"] == "summary", "kind recorded for summary segment")
	_ok(r.reasoning[2]["redacted"] == true, "redacted flag recorded")


func test_botresponse_empty_by_default() -> void:
	var r := BotResponse.new()
	_ok(r.reasoning is Array and r.reasoning.is_empty(), "reasoning defaults to empty array")


# ----------------------------------------------------------------------------
# OpenRouter extraction (real to_bot_response path)
# ----------------------------------------------------------------------------

func _make_provider():
	return OpenRouterProvider.new()


func _base_response(message: Dictionary) -> Dictionary:
	return {
		"id": "test-id",
		"choices": [{"message": message, "finish_reason": "stop"}],
		"usage": {"prompt_tokens": 10, "completion_tokens": 20}
	}


func test_extract_flat_reasoning_string() -> void:
	var p = _make_provider()
	var data := _base_response({
		"role": "assistant",
		"content": "Hello!",
		"reasoning": "Let me think step by step about the greeting."
	})
	var resp = p.to_bot_response(data)
	_ok(resp.has_reasoning(), "flat reasoning extracted")
	_ok(resp.reasoning.size() == 1, "one segment from flat string")
	_ok(resp.reasoning[0]["kind"] == "thinking", "flat string maps to thinking")
	_ok(resp.reasoning[0]["text"].begins_with("Let me think"), "flat text preserved")
	_ok(resp.text == "Hello!", "content text still parsed alongside reasoning")
	p.free()


func test_extract_reasoning_details_array() -> void:
	var p = _make_provider()
	var data := _base_response({
		"role": "assistant",
		"content": "Answer.",
		"reasoning_details": [
			{"type": "reasoning.text", "text": "raw chain of thought"},
			{"type": "reasoning.summary", "summary": "short summary"}
		]
	})
	var resp = p.to_bot_response(data)
	_ok(resp.reasoning.size() == 2, "two segments from details array")
	_ok(resp.reasoning[0]["kind"] == "thinking" and resp.reasoning[0]["text"] == "raw chain of thought", "text detail -> thinking")
	_ok(resp.reasoning[1]["kind"] == "summary" and resp.reasoning[1]["text"] == "short summary", "summary detail -> summary")
	_ok(resp.reasoning[0]["order"] == 0 and resp.reasoning[1]["order"] == 1, "details order preserved")
	p.free()


func test_extract_encrypted_is_redacted() -> void:
	var p = _make_provider()
	var data := _base_response({
		"role": "assistant",
		"content": "Answer.",
		"reasoning_details": [
			{"type": "reasoning.encrypted", "data": "OPAQUE=="}
		]
	})
	var resp = p.to_bot_response(data)
	_ok(resp.reasoning.size() == 1, "encrypted detail produces one placeholder segment")
	_ok(resp.reasoning[0]["redacted"] == true, "encrypted -> redacted placeholder")
	_ok(resp.reasoning[0]["text"] == "", "redacted segment has no text")
	p.free()


func test_extract_no_reasoning_is_empty() -> void:
	var p = _make_provider()
	var data := _base_response({"role": "assistant", "content": "Just an answer."})
	var resp = p.to_bot_response(data)
	_ok(not resp.has_reasoning(), "no reasoning fields -> empty sequence")
	_ok(resp.text == "Just an answer.", "normal response unaffected")
	p.free()
