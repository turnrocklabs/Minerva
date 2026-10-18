extends SceneTree
## Exercise the grouped fetch with real HTTP. Public catalog activation is S5.
const A := "owner-a/catalog-a"
const B := "owner-b/catalog-b"
var passed := 0
var failed := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, value: bool) -> void:
	if value:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func _run() -> void:
	var base := OS.get_environment("MINERVA_REQUIRED_GROUPS_URL")
	check("explicit loopback fixture", base.begins_with("http://127.0.0.1:"))
	if base.is_empty():
		quit(1)
		return
	var manager := Node.new()
	root.add_child(manager)
	var client := MarketplaceClient.new()
	manager.add_child(client)
	for scenario: String in ["rate", "disconnect", "nonlist", "partial", "caps", "early", "short"]:
		RequiredPlugins.releases_url = base + "/" + scenario
		var wanted_a := ["alpha", "missing"] if scenario == "partial" else ["late"] if scenario == "caps" else ["alpha"]
		var entries: Dictionary = await RequiredPlugins._fetch_grouped_entries(manager, {A: wanted_a, B: ["beta"]})
		check("%s retains independent second repository" % scenario,
			entries.get("beta", {}).get("version", "") == "2.3.0"
			and entries.get("beta", {}).get("downloads", {}).get("linux-x86_64", "") == "https://example.invalid/%s/beta-2.3.0.tar.gz" % B)
		if scenario in ["partial", "early"]:
			check("%s retains first repository's own release" % scenario, entries.get("alpha", {}).get("version", "") == "1.2.0")
		else:
			check("%s does not borrow a same-name foreign tag" % scenario, not entries.has("alpha") and not entries.has("late"))
		var history: Dictionary = await client.fetch_json(base + "/requests/" + scenario)
		var requests: Array = history.get("json", [])
		var count_a := 0
		var count_b := 0
		for request: Dictionary in requests:
			count_a += int(request.repo == A)
			count_b += int(request.repo == B)
		var expected_a := 10 if scenario == "caps" else 2 if scenario == "partial" else 1
		var expected_b := 10 if scenario == "caps" else 2 if scenario in ["early", "short"] else 1
		check("%s has independent cap/short/all-found stopping: %d/%d" % [scenario, count_a, count_b], count_a == expected_a and count_b == expected_b)
	check("default coordinates unchanged", RequiredPlugins.repository("docket") == RequiredPlugins.REPO
		and RequiredPlugins.release_page("docket") == "https://github.com/turnrocklabs/Minerva/releases")
	RequiredPlugins.releases_url = "https://api.github.com"
	manager.queue_free()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)
