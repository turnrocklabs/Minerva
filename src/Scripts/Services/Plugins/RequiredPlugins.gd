class_name RequiredPlugins
extends RefCounted
## The plugins Minerva needs and fetches itself: their ids, where their
## releases are published, and what the host does for them. They are ordinary
## marketplace-lane plugins once installed (records, updates, rollback), with
## three differences:
##   - they cannot be removed (they can be stopped, and Auto-start turned off);
##   - a missing or broken one is installed at launch from its newest official
##     release (ensure), with Auto-start on when its record is first created;
##     offline, the next launch or the plugin panel tries again;
##   - a feature that needs a missing or broken one says which plugin and how
##     to get it.
## A developer's manifest-lane copy is never judged broken or replaced.
##
## Releases are the Minerva repository's per-plugin GitHub releases: tag
## "<id>-v<version>", one asset per target named "<id>-<version>-<target>.tar.gz"
## in the marketplace archive format.
##
## `manager` (the PluginManager) is untyped here on purpose: naming the class
## would compile PluginManager, which refers to the SingletonObject autoload,
## into every script that uses this one, and a script compiled before
## autoloads exist (a --script test suite) would then fail.

const PluginArchive := preload("res://Scripts/Services/Plugins/PluginArchive.gd")
const PluginInstallTransaction := preload("res://Scripts/Services/Plugins/PluginInstallTransaction.gd")
const PluginAutoUpdaterScript := preload("res://Scripts/Services/Plugins/PluginAutoUpdater.gd")
const REPO := "turnrocklabs/Minerva"
const PLUGINS := {
	"agent_relay": {"name": "Agent Relay"},
	"voice": {"name": "Voice Support"},
}
## The GitHub Releases API listing the pickup reads, newest first, a page at a
## time (tests point it at a local fixture).
static var releases_url := "https://api.github.com/repos/%s/releases" % REPO
## App builds share the listing, so a rarely released plugin can sit many pages
## back; the pickup stops at a short page, once every required plugin has a
## release, or after this many pages.
const MAX_RELEASE_PAGES := 10
const RELEASES_PER_PAGE := 100


static func has(plugin_id: String) -> bool:
	return PLUGINS.has(plugin_id)


static func ids() -> Array[String]:
	var out: Array[String] = []
	for id in PLUGINS:
		out.append(id)
	return out


static func display_name(plugin_id: String) -> String:
	return str(PLUGINS.get(plugin_id, {}).get("name", plugin_id))


## What a feature that needs `plugin_id` says while it is not installed, or,
## given its runtime_issue, while it is installed but cannot run.
static func missing_message(plugin_id: String, issue: String = "") -> String:
	var problem := "is not installed yet" if issue.is_empty() else "cannot run: %s" % issue
	return ("The required %s plugin (%s) %s. Minerva installs it from its official release at startup "
		+ "when it can reach GitHub; to try again now, open Plugins and press \"Install required plugins\".") % [
		display_name(plugin_id), plugin_id, problem]


## Why an installed release of a required plugin cannot run here, or "" when
## it can (PluginArchive.installed_issue; `every_file` false skips the listed
## files for a cheap look). A manifest-lane (developer) copy is always "": it
## is the developer's to fix, never replaced from a release.
static func runtime_issue(def: PluginDefinition, every_file: bool = true) -> String:
	if def.install_lane != PluginDefinition.LANE_MARKETPLACE:
		return ""
	return PluginArchive.installed_issue(ProjectSettings.globalize_path(def.data_directory),
		def.entrypoint, MarketplaceClient.platform_targets(), every_file)


## The newest release of `plugin_id` in a GitHub Releases API listing, as a
## registry entry {id, version, release_tag, downloads: {target: url}}, or {}
## when the listing has none. Drafts and pre-releases are skipped.
static func entry_from_releases(releases: Array, plugin_id: String) -> Dictionary:
	var prefix := "%s-v" % plugin_id
	var best: Dictionary = {}
	for release in releases:
		if not release is Dictionary or release.get("draft", false) or release.get("prerelease", false):
			continue
		var tag := str(release.get("tag_name", ""))
		if not tag.begins_with(prefix):
			continue
		var version := tag.substr(prefix.length())
		if not best.is_empty() and PluginAutoUpdaterScript.compare_versions(version, best.version) <= 0:
			continue
		var downloads := {}
		var asset_prefix := "%s-%s-" % [plugin_id, version]
		for asset in release.get("assets", []):
			var name := str(asset.get("name", "")) if asset is Dictionary else ""
			if name.begins_with(asset_prefix) and name.ends_with(".tar.gz"):
				downloads[name.trim_prefix(asset_prefix).trim_suffix(".tar.gz")] = str(asset.get("browser_download_url", ""))
		best = {"id": plugin_id, "name": display_name(plugin_id), "version": version,
			"release_tag": tag, "downloads": downloads}
	return best


## The newest release of each required plugin, as registry entries keyed by
## id (entry_from_releases), from the release listing; {} when its first page
## cannot be read.
static func fetch_entries(manager) -> Dictionary:
	var client: Node = MarketplaceClient.new()
	manager.add_child(client)
	var releases: Array = []
	var entries := {}
	for page in range(1, MAX_RELEASE_PAGES + 1):
		var url := "%s?per_page=%d&page=%d" % [releases_url, RELEASES_PER_PAGE, page]
		var fetched: Dictionary = await client.fetch_json(url,
			PackedStringArray(["Accept: application/vnd.github+json", "User-Agent: Minerva"]))
		if not fetched.get("ok", false) or not fetched.json is Array:
			push_warning("[RequiredPlugins] Release listing unreadable at %s: %s" % [url,
				MarketplaceClient.format_install_error(fetched) if not fetched.get("ok", false) else "not a list"])
			break
		releases.append_array(fetched.json)
		entries = {}
		for id in ids():
			var entry := entry_from_releases(releases, id)
			if not entry.is_empty():
				entries[id] = entry
		if fetched.json.size() < RELEASES_PER_PAGE or entries.size() == PLUGINS.size():
			break
	client.queue_free()
	return entries


## Whether a required plugin's record `def` (null when there is none) needs
## installing: it is missing or broken (runtime_issue, with `every_file` as
## there).
static func needs_repair(def: PluginDefinition, every_file: bool = true) -> bool:
	return def == null or not runtime_issue(def, every_file).is_empty()


## The required plugins that need_repair.
static func missing_ids(manager, every_file: bool = true) -> Array[String]:
	var missing: Array[String] = []
	for id in ids():
		if needs_repair(manager.get_db().get_by_id(id), every_file):
			missing.append(id)
	return missing


## Install every missing required plugin (missing_ids). Each is queued as a
## repair of its newest release: new skills are seeded without asking, as for
## a plugin that ships with Minerva, customised ones are kept, and the install
## is skipped if, when it takes the install lock, the plugin no longer needs
## repair (needs_repair). A record created here gets Auto-start on (or the
## choice an older Minerva stored for it). Once installed, or found whole
## after the fetch or when its repair runs, the release copy is started if its
## Auto-start is on and no person has stopped it since (_start_if_wanted).
## Returns the jobs queued or already pending, keyed by plugin id; nothing new
## is queued when the release listing cannot be read.
static func ensure(manager) -> Dictionary:
	if manager.install_queue == null:
		return {}
	var missing := missing_ids(manager)
	var queued := _pending_jobs(manager, missing)
	if queued.size() == missing.size():
		return queued
	# A person who stops one of these meanwhile cancels its start below.
	var stops := {}
	for id in missing:
		stops[id] = manager.person_stops(id)
	var entries := await fetch_entries(manager)
	if manager.is_shutting_down():
		return {}
	# The fetch took time: judge each plugin as it is now. One made whole
	# meanwhile (by a startup update) starts now, as its repair would have.
	var still_missing := missing_ids(manager)
	for id in missing:
		if not id in still_missing and not queued.has(id):
			_start_if_wanted(manager, id, stops.get(id, manager.person_stops(id)))
	missing = still_missing
	if entries.is_empty():
		push_warning("[RequiredPlugins] No release could be read; required plugins wait for the next start or the plugin panel")
		return queued
	queued = _pending_jobs(manager, missing)
	for id in missing:
		if queued.has(id):
			continue
		var entry: Dictionary = entries.get(id, {})
		if entry.is_empty() or MarketplaceClient.download_target(entry.downloads).is_empty():
			push_warning("[RequiredPlugins] No release of '%s' for %s at %s" % [id, MarketplaceClient.resolve_platform_target(), releases_url])
			continue
		var fresh: bool = not manager.get_db().has_plugin(id)
		var job = manager.install_queue.request(entry, true, false, true)
		queued[id] = job
		job.finished.connect(_on_installed.bind(manager, job, fresh, stops.get(id, manager.person_stops(id))),
			CONNECT_ONE_SHOT)
	return queued


## The unfinished install-queue jobs for `plugin_ids`, keyed by id. A startup
## update does not count: it may yet skip itself, so a repair queues anyway.
static func _pending_jobs(manager, plugin_ids: Array[String]) -> Dictionary:
	var pending := {}
	for id in plugin_ids:
		var job = manager.install_queue.pending_for(id, true)
		if job != null:
			pending[id] = job
	return pending


static func _on_installed(manager, job, fresh: bool, stops: int) -> void:
	var id: String = job.plugin_id()
	print("[RequiredPlugins] '%s' %s: %s %s" % [id, job.result.get("version", ""), job.outcome, job.message])
	# Skipped because something else (a startup update, say) made the plugin
	# whole first: it still starts now, as the repair would have.
	var healed_meanwhile := str(job.result.get("error", "")) == "repair_not_needed"
	if job.outcome != job.OUTCOME_INSTALLED and not healed_meanwhile:
		return
	if fresh and not healed_meanwhile:
		var legacy = manager.get_db().legacy_autostart(id)
		manager.get_db().set_autostart(id, true if legacy == null else bool(legacy))
	_start_if_wanted(manager, id, stops)


## Start required plugin `id`, which was missing or broken when ensure ran and
## is now whole, if it is the release copy (a developer copy is the
## developer's to start), its Auto-start is on, it is not already running or
## starting, and no person has stopped it since ensure ran (`stops` is
## manager.person_stops then).
static func _start_if_wanted(manager, id: String, stops: int) -> void:
	var def: PluginDefinition = manager.get_db().get_by_id(id)
	if def != null and def.install_lane == PluginDefinition.LANE_MARKETPLACE and def.autostart \
			and manager.person_stops(id) == stops \
			and not def.state in [PluginDefinition.State.RUNNING, PluginDefinition.State.STARTING]:
		var started: Dictionary = await manager.start_plugin(id)
		if started.has("error") and not started.get("disabled", false):
			push_warning("[RequiredPlugins] '%s' is installed but did not start: %s" % [id, started.error])


## How the host launches `def`, where a required plugin needs more than its
## manifest says. Applied to the in-memory definition just before each start;
## for the relay, its manifest arguments plus --state-file.
static func prepare_launch(def: PluginDefinition) -> void:
	if def.id == "agent_relay":
		# Relay state lives in the plugin's data directory, which updates and
		# their rollbacks keep, not beside the replaceable binary.
		var state_file := PluginInstallTransaction.data_directory(def.id).path_join("agent_relay_state.json")
		DirAccess.make_dir_recursive_absolute(state_file.get_base_dir())
		var at := def.args.find("--state-file")
		if at >= 0:
			def.args.remove_at(at)
			if at < def.args.size():
				def.args.remove_at(at)  # its path
		def.args.append_array(["--state-file", state_file])


## Move a relay state file an older Minerva left in user://plugins/agent_relay/
## into the data directory, unless one is already there, before anything can
## install over that directory; the directory itself goes if nothing else is
## in it. Called at launch, before any plugin starts or installs.
static func move_legacy_relay_state() -> void:
	var legacy := ProjectSettings.globalize_path("user://plugins/agent_relay/agent_relay_state.json")
	var current := PluginInstallTransaction.data_directory("agent_relay").path_join("agent_relay_state.json")
	if not FileAccess.file_exists(legacy) or FileAccess.file_exists(current):
		return
	DirAccess.make_dir_recursive_absolute(current.get_base_dir())
	if DirAccess.rename_absolute(legacy, current) == OK:
		DirAccess.remove_absolute(legacy.get_base_dir())  # only succeeds when now empty
