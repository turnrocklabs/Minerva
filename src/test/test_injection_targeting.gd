extends SceneTree
## Test: injection targeting logic for signal-based proxy lifecycle.
## Run: godot --headless --script test/test_injection_targeting.gd
##
## Uses mock proxies (simple RefCounted with target_chat_id) to avoid
## depending on Note.Proxy which requires the full autoload chain.

var _pass_count: int = 0
var _fail_count: int = 0

class MockProxy extends RefCounted:
	var target_chat_id: String = ""

func _init():
	print("=== Injection Targeting Tests ===\n")

	test_match_empty_target()
	test_match_specific_target()
	test_selective_clear_all_consumed()
	test_selective_clear_preserves_other()
	test_selective_clear_untargeted_consumed_by_any()
	test_filter_for_chat_mixed()
	test_filter_untargeted_included_everywhere()
	test_filter_no_proxies()
	test_selective_clear_no_proxies()

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


# ── Matching logic (will live in Note.Proxy or a helper) ──────────────

func proxy_matches(target_chat_id: String, history_id: String) -> bool:
	return target_chat_id.is_empty() or target_chat_id == history_id


func selective_clear(proxies: Array, history_id: String) -> Array:
	var remaining: Array = []
	for proxy in proxies:
		if proxy.target_chat_id.is_empty() or proxy.target_chat_id == history_id:
			continue
		remaining.append(proxy)
	return remaining


func filter_for_chat(proxies: Array, history_id: String) -> Array:
	var result: Array = []
	for proxy in proxies:
		if proxy.target_chat_id.is_empty() or proxy.target_chat_id == history_id:
			result.append(proxy)
	return result


func make_proxies(targets: Array) -> Array:
	var proxies: Array = []
	for t in targets:
		var p := MockProxy.new()
		p.target_chat_id = t
		proxies.append(p)
	return proxies


# ── Tests ─────────────────────────────────────────────────────────────

func test_match_empty_target():
	print("test_match_empty_target:")
	check("empty target matches any chat", proxy_matches("", "chat_abc"))
	check("empty target matches empty id", proxy_matches("", ""))

func test_match_specific_target():
	print("test_match_specific_target:")
	check("matches same id", proxy_matches("chat_abc", "chat_abc"))
	check("rejects different id", not proxy_matches("chat_abc", "chat_xyz"))
	check("rejects empty id", not proxy_matches("chat_abc", ""))

func test_selective_clear_all_consumed():
	print("test_selective_clear_all_consumed:")
	var proxies := make_proxies(["", "", "chat_abc"])
	var remaining := selective_clear(proxies, "chat_abc")
	check("3 proxies: 2 untargeted + 1 matching = 0 remaining", remaining.size() == 0)

func test_selective_clear_preserves_other():
	print("test_selective_clear_preserves_other:")
	var proxies := make_proxies(["chat_abc", "chat_xyz", "chat_abc"])
	var remaining := selective_clear(proxies, "chat_abc")
	check("1 preserved (targeted at xyz)", remaining.size() == 1)
	check("preserved targets chat_xyz", remaining[0].target_chat_id == "chat_xyz")

func test_selective_clear_untargeted_consumed_by_any():
	print("test_selective_clear_untargeted_consumed_by_any:")
	var proxies := make_proxies(["", "chat_xyz"])
	var remaining := selective_clear(proxies, "chat_other")
	check("untargeted consumed, targeted preserved", remaining.size() == 1)
	check("preserved targets chat_xyz", remaining[0].target_chat_id == "chat_xyz")

func test_filter_for_chat_mixed():
	print("test_filter_for_chat_mixed:")
	var proxies := make_proxies(["", "chat_abc", "chat_xyz"])
	var filtered := filter_for_chat(proxies, "chat_abc")
	check("2 included (untargeted + matching)", filtered.size() == 2)
	check("first is untargeted", filtered[0].target_chat_id == "")
	check("second targets chat_abc", filtered[1].target_chat_id == "chat_abc")

func test_filter_untargeted_included_everywhere():
	print("test_filter_untargeted_included_everywhere:")
	var proxies := make_proxies(["", ""])
	check("both in chat_a", filter_for_chat(proxies, "chat_a").size() == 2)
	check("both in chat_b", filter_for_chat(proxies, "chat_b").size() == 2)

func test_filter_no_proxies():
	print("test_filter_no_proxies:")
	check("empty list returns empty", filter_for_chat([], "chat_a").size() == 0)

func test_selective_clear_no_proxies():
	print("test_selective_clear_no_proxies:")
	check("empty list returns empty", selective_clear([], "chat_a").size() == 0)
