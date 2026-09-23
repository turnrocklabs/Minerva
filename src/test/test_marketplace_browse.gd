extends SceneTree
## The marketplace UI and MCP listing against a local registry, real
## archives over local HTTP (one throttled), a real PluginManager and queue:
##
##   - MarketplaceBrowseDialog (the real scene) lists the registry, marks an
##     entry with no build for this computer, shows the selected entry's long
##     description or says it has none, and installs a two-plugin selection
##     as two job rows with their own stage and progress;
##   - closing the dialog mid-install and opening a new one shows the same
##     jobs, and a dialog opened after they finish shows their outcomes until
##     the queue stops keeping them;
##   - PluginManagerPanel lists a plugin installed through the queue while
##     no dialog is open (as an MCP install is);
##   - minerva_plugin_marketplace_list / _detail return descriptions and
##     platform applicability, and report an unknown id or an unreachable
##     registry as errors.
##
## Run: godot --headless --path src --script test/test_marketplace_browse.gd

const HELPERS_GD := "res://test/marketplace_test_helpers.gd"
const DIALOG_TSCN := "res://Scenes/MarketplaceBrowseDialog.tscn"
const PANEL_TSCN := "res://Scenes/PluginManagerPanel.tscn"
const MCP_TOOLS_GD := "res://Scripts/Services/Plugins/PluginMCPTools.gd"
const THROTTLED_PY := "res://test/fixtures/throttled_http_server.py"
const SLOW := "test_browse_slow"      # described, throttled
const PLAIN := "test_browse_plain"    # published without a description
const EXTERNAL := "test_browse_external"
const ELSEWHERE := "test_browse_elsewhere"  # no build for this computer
const DESCRIPTION := "Draws test patterns for the marketplace browser. Needs nothing else; works offline. " \
	+ "This sentence pads the listing past the registry's minimum length."

var _h
var _pm: Node
var _temp := ""
var _registry_url := ""
var _urls := {}
var _slow_server := -1
var _fail := 0


func _init() -> void:
	create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL: timed out")
		_finish(1))
	await process_frame
	_h = load(HELPERS_GD).new(self)
	_temp = "%s/test_marketplace_browse_%d" % [OS.get_user_data_dir(), Time.get_ticks_msec()]
	var port: int = _h.random_high_port()
	for id in [PLAIN, EXTERNAL]:
		_urls[id] = "http://127.0.0.1:%d/%s.tar.gz" % [port, id]
	_urls[SLOW] = "http://127.0.0.1:%d/%s.tar.gz" % [port + 1, SLOW]
	_registry_url = "http://127.0.0.1:%d/registry.json" % port
	_pm = await _h.bootstrap_plugin_manager()
	var ready: bool = _pm != null and _pack(SLOW, 3 * 1024 * 1024) and _pack(PLAIN, 0) \
		and _pack(EXTERNAL, 0) and _write_registry() and await _h.start_http_server(_temp, port)
	if ready:
		_slow_server = OS.create_process("python3", [ProjectSettings.globalize_path(THROTTLED_PY),
			_temp.path_join(SLOW + ".tar.gz"), str(port + 1), "--rate", "1048576"])
		ready = await _port_open(port + 1)
	if not ready:
		print("FAIL: fixture setup")
		_finish(1)
		return
	for id in [SLOW, PLAIN, EXTERNAL]:
		await _h.scrub_plugin(_pm, id)

	await _test_dialog_installs_a_selection_and_survives_reopening()
	await _test_panel_lists_an_install_started_elsewhere()
	await _test_mcp_list_and_detail()
	_finish(1 if _fail else 0)


func _test_dialog_installs_a_selection_and_survives_reopening() -> void:
	var dialog = await _open_dialog()
	var list: ItemList = dialog._list
	_check(list.item_count == 4 and list.is_item_disabled(_index(dialog, ELSEWHERE)),
		"the registry is listed and the entry with no build here is disabled")
	_select(dialog, PLAIN)
	_check("published without a description" in dialog._details.text, "a legacy entry says it has no description")
	_select(dialog, SLOW)
	_check(DESCRIPTION in dialog._details.text, "the selected entry's long description is shown")
	_check(dialog._install_btn.text == "Install 2" and not dialog._install_btn.disabled, "both selections can be installed")
	dialog._install_btn.pressed.emit()

	var slow = _pm.install_queue.job_for(SLOW)
	var give_up := Time.get_ticks_msec() + 20000
	while slow.op.done < 65536 and Time.get_ticks_msec() < give_up:
		await process_frame
	var rows: Dictionary = _rows_by_plugin(dialog)
	_check(rows.size() == 2, "two job rows: %s" % [rows.keys()])
	_check(rows.has(SLOW) and "Downloading" in rows[SLOW]._status.text and rows[SLOW]._progress.visible \
		and rows[SLOW]._progress.max_value > 0, "the running install shows its stage and byte progress")
	_check(rows.has(PLAIN) and "Waiting" in rows[PLAIN]._status.text, "the other waits its turn")

	dialog._on_close_requested()
	await process_frame
	dialog = await _open_dialog()
	rows = _rows_by_plugin(dialog)
	_check(rows.size() == 2 and slow.state != slow.State.DONE, "a reopened dialog shows the same unfinished jobs")
	await _pm.install_queue.job_for(PLAIN).finished
	dialog._on_close_requested()
	await process_frame
	dialog = await _open_dialog()
	_select(dialog, SLOW)
	rows = _rows_by_plugin(dialog)
	_check(rows.has(SLOW) and rows.has(PLAIN) and "Installed v1.0.0" in rows[SLOW]._status.text \
		and "Installed v1.0.0" in rows[PLAIN]._status.text, "a dialog opened after the installs shows their outcomes")
	_check(dialog._install_btn.disabled, "installed plugins are not offered again")

	# Finish enough quick (404) installs that the queue stops keeping SLOW's job.
	var trimmed = _pm.install_queue.job_for(SLOW)
	var last
	for i in _pm.install_queue.MAX_FINISHED:
		last = _pm.install_queue.request_url(_registry_url.replace("registry.json", "gone_%d.tar.gz" % i))
	await last.finished
	_check(not trimmed in _pm.install_queue.jobs() and not dialog._rows.has(trimmed),
		"a job the queue no longer keeps leaves the open dialog, so it cannot look retryable")
	dialog._on_close_requested()


func _test_panel_lists_an_install_started_elsewhere() -> void:
	var panel = load(PANEL_TSCN).instantiate()
	panel._pm_override = _pm
	root.add_child(panel)
	await process_frame
	var job = _pm.install_queue.request_url(_urls[EXTERNAL], true)
	await job.finished
	await process_frame
	var listed := false
	for i in panel._plugin_list.item_count:
		listed = listed or EXTERNAL in panel._plugin_list.get_item_text(i)
	_check(job.outcome == job.OUTCOME_INSTALLED and listed, "the panel lists a plugin installed without the dialog")
	panel.queue_free()


func _test_mcp_list_and_detail() -> void:
	var tools = load(MCP_TOOLS_GD).new(_pm)
	var listed: Dictionary = await tools.handle_tool_call("minerva_plugin_marketplace_list", {"registry_url": _registry_url})
	var by_id := {}
	for p in listed.get("plugins", []):
		by_id[p.id] = p
	_check(by_id.get(SLOW, {}).get("description") == DESCRIPTION and by_id.get(PLAIN, {}).get("description_missing") == true,
		"list returns long descriptions and flags a missing one")
	_check(by_id.get(ELSEWHERE, {}).get("available_here") == false and not str(by_id.get(ELSEWHERE, {}).get("unavailable_reason", "")).is_empty(),
		"list says which entries have no build here, and why")
	_check(by_id.get(SLOW, {}).get("installed_version") == "1.0.0", "list reports the installed version")

	var detail: Dictionary = await tools.handle_tool_call("minerva_plugin_marketplace_detail", {"id": EXTERNAL, "registry_url": _registry_url})
	_check(detail.get("download_url") == _urls[EXTERNAL] and detail.get("install", {}).get("outcome") == "installed",
		"detail gives this computer's download and the last install's outcome: %s" % [detail])
	var unknown: Dictionary = await tools.handle_tool_call("minerva_plugin_marketplace_detail", {"id": "no_such_plugin", "registry_url": _registry_url})
	_check(unknown.has("error") and SLOW in unknown.get("known_ids", []), "an unknown id is an error naming the known ids")
	var unreachable: Dictionary = await tools.handle_tool_call("minerva_plugin_marketplace_list",
		{"registry_url": _registry_url.replace("registry.json", "missing.json")})
	_check(unreachable.has("error"), "an unreachable registry is an error")


func _open_dialog():
	var dialog = load(DIALOG_TSCN).instantiate()
	dialog.plugin_manager = _pm
	dialog.registry_url = _registry_url
	root.add_child(dialog)
	var give_up := Time.get_ticks_msec() + 10000
	while dialog._list.item_count == 0 and Time.get_ticks_msec() < give_up:
		await process_frame
	return dialog


## Add `id` to the dialog's selection the way a click does.
func _select(dialog, id: String) -> void:
	var idx := _index(dialog, id)
	dialog._list.select(idx, false)
	dialog._list.multi_selected.emit(idx, true)


func _index(dialog, id: String) -> int:
	for i in dialog._plugins.size():
		if dialog._plugins[i].id == id:
			return i
	return -1


func _rows_by_plugin(dialog) -> Dictionary:
	var rows := {}
	for row in dialog.get_node("%JobRows").get_children():
		rows[row.job.plugin_id()] = row
	return rows


func _write_registry() -> bool:
	var target := MarketplaceClient.resolve_platform_target()
	var plugins := []
	for id in [SLOW, PLAIN, EXTERNAL]:
		var entry := {"id": id, "name": id, "version": "1.0.0", "release_tag": "%s-v1.0.0" % id,
			"downloads": {target: _urls[id]}}
		if id == SLOW:
			entry["description"] = DESCRIPTION
		plugins.append(entry)
	plugins.append({"id": ELSEWHERE, "name": ELSEWHERE, "version": "1.0.0", "description": DESCRIPTION,
		"downloads": {"not-this-computer": "http://127.0.0.1:1/none.tar.gz"}})
	var f := FileAccess.open(_temp.path_join("registry.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"registry_version": 2, "plugins": plugins}))
	f.close()
	return true


func _port_open(port: int) -> bool:
	for i in 50:
		if OS.execute("bash", ["-c", "exec 3<>/dev/tcp/127.0.0.1/%d" % port]) == 0:
			return true
		await create_timer(0.1).timeout
	return false


## Archive `<id>.tar.gz` in the temp dir: manifest, placeholder binary,
## optional random payload, SHA256SUMS.
func _pack(id: String, payload_bytes: int) -> bool:
	var dir := _temp.path_join(id)
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("manifest.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({
		"id": id, "name": id, "version": "1.0.0", "host_api_version": "1",
		"backend": {"transport": "stdio", "entrypoint": "./test-binary", "args": []},
		"tools": [], "ui": {"panels": [], "ipc_messages": []},
		"permissions": {"host_capabilities": []}, "autostart": false, "auto_reload": false,
	}))
	f.close()
	f = FileAccess.open(dir.path_join("test-binary"), FileAccess.WRITE)
	f.store_string("PLACEHOLDER")
	f.close()
	if payload_bytes > 0:
		f = FileAccess.open(dir.path_join("payload.bin"), FileAccess.WRITE)
		f.store_buffer(Crypto.new().generate_random_bytes(payload_bytes))
		f.close()
	return _h.pack_plugin_dir(dir, dir.get_base_dir().path_join(id + ".tar.gz"))


func _check(ok: bool, what: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + what)
	if not ok:
		_fail += 1


func _finish(code: int) -> void:
	if _pm != null:
		for id in [SLOW, PLAIN, EXTERNAL]:
			if _pm.get_db().has_plugin(id):
				_pm.get_db().remove(id)
			_h.rm_dir_recursive("user://plugins/" + id)
	if _slow_server > 0:
		OS.kill(_slow_server)
	_h.teardown()
	OS.execute("rm", ["-rf", _temp])
	print("=== %s ===" % ("FAIL" if code else "PASS"))
	quit(code)
