extends SceneTree
## Required plugins (RequiredPlugins) with the app's PluginManager, a release
## listing and archive served over local HTTP:
##   - the pickup reads the newest published release of each required plugin
##     from a GitHub Releases listing: drafts and pre-releases are skipped,
##     and each "<id>-<version>-<target>.tar.gz" asset becomes a download;
##   - a relay whose tools/list lacks a tool Minerva calls on it is refused at
##     start and stopped;
##   - ensure() installs a missing required plugin from that release,
##     creates its record with Auto-start on and starts it, with the relay's
##     state file in its data directory; a plugin with no release is left
##     alone;
##   - an installed release whose entrypoint is built for another platform is
##     broken, and one missing a file it lists in SHA256SUMS refuses to
##     start, naming the plugin and the problem, and ensure() reinstalls it
##     without overriding the user's Auto-start off, and one made whole before
##     its repair runs, or before ensure has read the releases, is started
##     all the same, unless a person stopped it meanwhile;
##   - a repair queued while the plugin was missing leaves alone a developer
##     copy registered before it runs;
##   - a first install takes the Auto-start choice an older Minerva stored,
##     and keeps a capability the user revoked while it shipped built in;
##   - a required plugin cannot be removed, and starting one that is not
##     installed says which plugin is missing and how to get it.
##
## Run: godot --headless --path src --script test/test_required_plugins.gd

const HELPERS_GD := "res://test/marketplace_test_helpers.gd"
const PROBE_PY := "res://test/fixtures/capability_probe/capability_probe.py"
const RELAY := "agent_relay"
const CAPABILITY := "host.terminal.list"

var _h
var _pm: Node
var _temp := ""
var _fail := 0
## The profile's grants for the relay before the run, restored at the end
## once recorded.
var _grants_before = null
var _grants_recorded := false


func _init() -> void:
	create_timer(180.0).timeout.connect(func() -> void:
		print("FAIL: timed out")
		_finish(1))
	await process_frame
	_h = load(HELPERS_GD).new(self)
	_temp = "%s/test_required_plugins_%d" % [OS.get_user_data_dir(), Time.get_ticks_msec()]
	_test_newest_release_is_picked()
	_test_foreign_build_is_broken()
	_pm = await _h.bootstrap_plugin_manager(true)
	var port: int = _h.random_high_port()
	if _pm == null or not _pack_relay("9.9.9") or not _write_releases(port) \
			or not await _h.start_http_server(_temp, port):
		print("FAIL: fixture setup")
		_finish(1)
		return
	await _h.scrub_plugin(_pm, RELAY)
	if _pm._policy_ref != null:
		_grants_before = _pm._policy_ref._grants.get(RELAY)
		_grants_recorded = true
		_pm._policy_ref._grants.erase(RELAY)
	RequiredPlugins.releases_url = "http://127.0.0.1:%d/releases.json" % port
	await _test_missing_plugin_is_installed_and_started()
	await _test_broken_plugin_is_reinstalled_keeping_choices()
	await _test_repair_leaves_developer_copy()
	await _test_first_install_keeps_old_choices()
	await _test_required_plugin_is_kept()
	_finish(1 if _fail else 0)


func _test_newest_release_is_picked() -> void:
	var releases := [
		{"tag_name": "agent_relay-v1.2.0", "assets": [
			{"name": "agent_relay-1.2.0-linux-x86_64.tar.gz", "browser_download_url": "http://x/l"},
			{"name": "agent_relay-1.2.0-macos-arm64.tar.gz", "browser_download_url": "http://x/m"},
			{"name": "agent_relay-1.2.0-linux-x86_64.tar.gz.sha256", "browser_download_url": "http://x/s"}]},
		{"tag_name": "agent_relay-v1.10.0", "draft": true, "assets": []},
		{"tag_name": "agent_relay-v2.0.0-rc.1", "prerelease": true, "assets": []},
		{"tag_name": "agent_relay-v1.1.0", "assets": []},
		{"tag_name": "voice-v9.0.0", "assets": []},
	]
	var entry := RequiredPlugins.entry_from_releases(releases, RELAY)
	_check(entry.get("version") == "1.2.0" and entry.get("release_tag") == "agent_relay-v1.2.0"
		and entry.get("downloads") == {"linux-x86_64": "http://x/l", "macos-arm64": "http://x/m"},
		"the newest published release is picked, its archives keyed by target: %s" % [entry])
	_check(RequiredPlugins.entry_from_releases(releases, "not_listed").is_empty(),
		"a plugin with no release has no entry")


func _test_foreign_build_is_broken() -> void:
	var dir := _temp.path_join("foreign")
	DirAccess.make_dir_recursive_absolute(dir)
	# A native header for a platform this computer is not: 64-bit x86-64 ELF
	# on a Mac, a single-architecture arm64 Mach-O elsewhere.
	var header := PackedByteArray()
	header.resize(64)
	if OS.get_name() == "macOS":
		header.encode_u32(0, 0x464C457F)
		header[4] = 2
		header[5] = 1
		header.encode_u16(18, 0x3E)
	else:
		header.encode_u32(0, 0xFEEDFACF)
		header.encode_u32(4, 0x0100000C)
	var f := FileAccess.open(dir.path_join("tool"), FileAccess.WRITE)
	f.store_buffer(header)
	f.close()
	f = FileAccess.open(dir.path_join("SHA256SUMS"), FileAccess.WRITE)
	f.store_string("%s  tool\n" % FileAccess.get_sha256(dir.path_join("tool")))
	f.close()
	var issue: String = load("res://Scripts/Services/Plugins/PluginArchive.gd").installed_issue(
		dir, "./tool", MarketplaceClient.platform_targets())
	_check(("linux-x86_64" if OS.get_name() == "macOS" else "macos-arm64") in issue,
		"an installed entrypoint built for another platform is broken, naming that platform: %s" % issue)


func _test_missing_plugin_is_installed_and_started() -> void:
	var queued: Dictionary = await RequiredPlugins.ensure(_pm)
	_check(queued.has(RELAY) and not queued.has("voice"),
		"the missing relay is queued from its release, and voice (no release here) is not: %s" % [queued.keys()])
	if not queued.has(RELAY):
		return
	var job = queued[RELAY]
	await _until(func() -> bool: return job.state == job.State.DONE)
	await _until(func() -> bool:
		var def = _pm.get_db().get_by_id(RELAY)
		return def != null and def.state == _pm.S_RUNNING)
	var def = _pm.get_db().get_by_id(RELAY)
	_check(def != null and def.version == "9.9.9" and def.autostart and def.state == _pm.S_RUNNING
		and def.install_lane == PluginDefinition.LANE_MARKETPLACE,
		"it is installed from the release with Auto-start on, and runs: %s" % [job.summary()])
	_check(_pm._policy_ref.is_capability_granted(RELAY, CAPABILITY),
		"a first install grants the capabilities it declares")

	var state_at: int = def.args.find("--state-file") + 1 if def != null else 0
	_check(state_at > 0 and state_at < def.args.size() and def.args[state_at] == ProjectSettings.globalize_path(
		"user://plugins/data/%s/agent_relay_state.json" % RELAY),
		"the relay is started with its state file in its data directory: %s" % [def.args if def != null else []])
	if def == null:
		return

	# A relay that lacks a tool Minerva calls on it is refused and stopped.
	await _pm.stop_plugin(RELAY)
	var args_before: Array[String] = def.args.duplicate()
	def.args.assign(_probe_args(false))
	var refused: Dictionary = await _pm.start_plugin(RELAY)
	_check("minerva_agent_relay_send" in str(refused.get("error", "")) and def.state == _pm.S_ERROR,
		"a relay without the tools Minerva calls is refused, naming them: %s" % [refused])
	def.args.assign(args_before)


func _test_broken_plugin_is_reinstalled_keeping_choices() -> void:
	await _pm.stop_plugin(RELAY)
	_pm.get_db().set_autostart(RELAY, false)
	var def = _pm.get_db().get_by_id(RELAY)
	var probe := ProjectSettings.globalize_path(def.data_directory).path_join("capability_probe.py")
	DirAccess.remove_absolute(probe)
	var refused: Dictionary = await _pm.start_plugin(RELAY)
	var refusal := str(refused.get("error", ""))
	_check(RELAY in RequiredPlugins.missing_ids(_pm) and "Agent Relay" in refusal and "capability_probe.py" in refusal,
		"a release missing a listed file is broken and refuses to start, saying which: %s" % [refused])
	var queued: Dictionary = await RequiredPlugins.ensure(_pm)
	var job = queued.get(RELAY)
	if job != null:
		await _until(func() -> bool: return job.state == job.State.DONE)
	def = _pm.get_db().get_by_id(RELAY)
	_check(job != null and FileAccess.file_exists(probe) and not def.autostart and def.state != _pm.S_RUNNING,
		"ensure reinstalls it and leaves Auto-start off and the plugin stopped: %s" % [job.summary() if job != null else queued])
	var started: Dictionary = await _pm.start_plugin(RELAY)
	_check(not started.has("error") and def.state == _pm.S_RUNNING,
		"the reinstalled plugin starts when the user starts it: %s" % [started])
	await _pm.stop_plugin(RELAY)

	# Made whole by something else before its repair runs: the repair is
	# skipped, and the plugin still starts in this launch.
	_pm.get_db().set_autostart(RELAY, true)
	DirAccess.remove_absolute(probe)
	queued = await RequiredPlugins.ensure(_pm)
	job = queued.get(RELAY)
	DirAccess.copy_absolute(ProjectSettings.globalize_path(PROBE_PY), probe)
	if job != null:
		await _until(func() -> bool: return job.state == job.State.DONE)
	await _until(func() -> bool: return def.state == _pm.S_RUNNING)
	_check(job != null and str(job.result.get("error", "")) == "repair_not_needed" and def.state == _pm.S_RUNNING,
		"a repair that finds the plugin whole still starts it: %s" % [job.summary() if job != null else queued])
	await _pm.stop_plugin(RELAY)

	# The same, but a person stops the plugin while its repair waits: it stays
	# stopped (its saved Auto-start is untouched).
	DirAccess.remove_absolute(probe)
	queued = await RequiredPlugins.ensure(_pm)
	job = queued.get(RELAY)
	_pm.stop_plugin(RELAY, true)
	DirAccess.copy_absolute(ProjectSettings.globalize_path(PROBE_PY), probe)
	if job != null:
		await _until(func() -> bool: return job.state == job.State.DONE)
	await _until(func() -> bool: return def.state == _pm.S_RUNNING, 5.0)  # what a wrong start would reach
	_check(job != null and str(job.result.get("error", "")) == "repair_not_needed"
		and not def.state in [_pm.S_RUNNING, _pm.S_STARTING] and def.autostart,
		"a person's Stop while the repair waits keeps the plugin stopped: %s" % [job.summary() if job != null else queued])

	# Made whole while ensure reads the release listing: nothing is queued,
	# and the plugin still starts in this launch.
	DirAccess.remove_absolute(probe)
	var last_job = _pm.install_queue.job_for(RELAY)
	RequiredPlugins.ensure(_pm)  # suspended in its release fetch
	DirAccess.copy_absolute(ProjectSettings.globalize_path(PROBE_PY), probe)
	await _until(func() -> bool: return def.state == _pm.S_RUNNING)
	_check(def.state == _pm.S_RUNNING and _pm.install_queue.job_for(RELAY) == last_job,
		"a plugin made whole during ensure's fetch is started without a repair")
	await _pm.stop_plugin(RELAY)


func _test_repair_leaves_developer_copy() -> void:
	await _h.scrub_plugin(_pm, RELAY)
	var queued: Dictionary = await RequiredPlugins.ensure(_pm)
	var job = queued.get(RELAY)
	# The queued repair has not reached its install lock yet; a developer
	# registers their checkout (the record exists before install_plugin yields).
	var registered: Dictionary = await _pm.install_plugin(_temp.path_join("relay/manifest.json"), true)
	if job != null:
		await _until(func() -> bool: return job.state == job.State.DONE)
	var def = _pm.get_db().get_by_id(RELAY)
	_check(registered.get("ok", false) and job != null and str(job.result.get("error", "")) == "repair_not_needed"
		and def != null and def.install_lane == PluginDefinition.LANE_MANIFEST,
		"a queued repair leaves a developer copy registered meanwhile: %s" % [job.summary() if job != null else queued])
	_pm.get_db().remove(RELAY)


func _test_first_install_keeps_old_choices() -> void:
	await _h.scrub_plugin(_pm, RELAY)
	_pm.get_db()._legacy_autostart[RELAY] = false
	_pm._policy_ref.revoke_capability(RELAY, CAPABILITY)
	var queued: Dictionary = await RequiredPlugins.ensure(_pm)
	var job = queued.get(RELAY)
	if job != null:
		await _until(func() -> bool: return job.state == job.State.DONE)
	var def = _pm.get_db().get_by_id(RELAY)
	_check(def != null and not def.autostart and def.state != _pm.S_RUNNING,
		"a first install takes an older Minerva's stored Auto-start off and does not start")
	_check(def != null and not _pm._policy_ref.is_capability_granted(RELAY, CAPABILITY),
		"a first install keeps a capability the user revoked")


func _test_required_plugin_is_kept() -> void:
	var removed: Dictionary = await _pm.remove_plugin(RELAY)
	_check(removed.has("error") and "cannot be removed" in str(removed.error) and _pm.get_db().has_plugin(RELAY),
		"a required plugin cannot be removed: %s" % [removed])
	await _h.scrub_plugin(_pm, RELAY)
	var started: Dictionary = await _pm.start_plugin(RELAY)
	var refusal := str(started.get("error", ""))
	_check("Agent Relay" in refusal and "not installed" in refusal and "Install required plugins" in refusal,
		"starting a missing required plugin names it and how to get it: %s" % [started])


## A relay stand-in: the capability probe under the relay's id, packed as the
## release archive for this computer's preferred target.
func _pack_relay(version: String) -> bool:
	var dir := _temp.path_join("relay")
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest := {
		"id": RELAY, "name": "Agent Relay", "version": version, "host_api_version": "1",
		"release_targets": MarketplaceClient.platform_targets(),
		"backend": {"transport": "stdio", "entrypoint": _h.python_cmd(), "args": _probe_args(true)},
		"tools": [], "ui": {"panels": [], "ipc_messages": []},
		"permissions": {"host_capabilities": [CAPABILITY]}, "auto_reload": false,
	}
	var f := FileAccess.open(dir.path_join("manifest.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(manifest))
	f.close()
	DirAccess.copy_absolute(ProjectSettings.globalize_path(PROBE_PY), dir.path_join("capability_probe.py"))
	return _h.pack_plugin_dir(dir, _temp.path_join("%s-%s-%s.tar.gz" % [RELAY, version,
		MarketplaceClient.resolve_platform_target()]))


## The relay stand-in's arguments: with `host_tools`, it also lists the tools
## Minerva calls on the relay.
func _probe_args(host_tools: bool) -> Array[String]:
	var args: Array[String] = ["capability_probe.py"]
	if host_tools:
		args.append_array(["--list-tools", ",".join(RequiredPlugins.PLUGINS[RELAY].host_tools)])
	return args


func _write_releases(port: int) -> bool:
	var asset := "%s-9.9.9-%s.tar.gz" % [RELAY, MarketplaceClient.resolve_platform_target()]
	var releases := [{"tag_name": "agent_relay-v9.9.9", "assets": [
		{"name": asset, "browser_download_url": "http://127.0.0.1:%d/%s" % [port, asset]}]}]
	var f := FileAccess.open(_temp.path_join("releases.json"), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(releases))
	f.close()
	return true


func _until(ready: Callable, seconds: float = 60.0) -> void:
	var give_up := Time.get_ticks_msec() + int(seconds * 1000)
	while not ready.call() and Time.get_ticks_msec() < give_up:
		await process_frame


func _check(ok: bool, what: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + what)
	if not ok:
		_fail += 1


func _finish(code: int) -> void:
	if _pm != null and _pm.get_db().has_plugin(RELAY):
		_pm.stop_plugin(RELAY)
		_pm.get_db().remove(RELAY)
	if _grants_recorded:
		_pm._policy_ref._grants.erase(RELAY)
		if _grants_before != null:
			_pm._policy_ref._grants[RELAY] = _grants_before
		_pm._policy_ref._save()
	if _h != null:
		_h.rm_dir_recursive("user://plugins/" + RELAY)
		_h.teardown()
		_h.remove_tree(_temp)
	print("=== %s ===" % ("FAIL" if code else "PASS"))
	quit(code)
