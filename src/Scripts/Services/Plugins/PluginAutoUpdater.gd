extends RefCounted
## At Minerva start, updates the plugins the user opted in to (auto_update)
## to the newer release (the marketplace registry, or a required plugin's own
## releases, RequiredPlugins), through the install queue: one at a time, the
## queue's upgrade transaction (a running plugin must start before the update
## commits, or it is rolled back), unattended consent (nothing is asked;
## skills the user customised keep their version, and skills the update adds
## are not seeded). Each update's outcome is logged when it ends. Only
## marketplace-lane plugins are updated; a manifest-lane (developer) plugin is
## never overwritten. Nothing is awaited by startup, and a registry or release
## listing that cannot be read is logged and retried at the next start.
## The same per-plugin path handles manual clicks, which bypass only opt-in.
## `manager` stays untyped to avoid compiling its autoload dependencies into
## --script suites that load RequiredPlugins before autoload readiness.

const Job := preload("res://Scripts/Services/Plugins/PluginInstallJob.gd")

## Queue an update for every opted-in plugin whose registry entry is newer
## than the installed version. Returns the jobs queued, keyed by plugin id.
static func run(manager, registry_url: String = "") -> Dictionary:
	var candidates: Array = manager.get_db().get_all().filter(func(def: PluginDefinition) -> bool:
		return not _attached(manager, def.id) and wants_update(def, ""))
	if candidates.is_empty() or manager.install_queue == null:
		return {}
	var ids: Array[String] = []
	for candidate: PluginDefinition in candidates:
		ids.append(candidate.id)
	var entries := await fetch_entries(manager, ids, registry_url)
	var queued := {}
	for id: String in ids:
		var job := queue_update(manager, id, entries.get(id, {}))
		if job != null:
			queued[id] = job
	return queued


## Refresh each plugin's own release lane; there is no cached listing here.
static func fetch_entries(manager, ids: Array[String], registry_url: String = "") -> Dictionary:
	if ids.is_empty() or manager.is_shutting_down():
		return {}
	var entries := {}
	if ids.any(func(id: String) -> bool: return not RequiredPlugins.has(id)):
		entries = await _fetch_registry_entries(manager, registry_url)
	# Required plugins are published as their own releases, not in the registry.
	if ids.any(func(id: String) -> bool: return RequiredPlugins.has(id)):
		entries.merge(await RequiredPlugins.fetch_entries(manager), true)
	return {} if manager.is_shutting_down() else entries


static func _fetch_registry_entries(manager, registry_url: String) -> Dictionary:
	var client: Node = MarketplaceClient.new()
	manager.add_child(client)
	var fetched: Dictionary = await client.fetch_registry(registry_url)
	client.queue_free()
	if manager.is_shutting_down():
		return {}
	var entries := {}
	if fetched.get("ok", false):
		for entry in fetched.registry.get("plugins", []):
			if entry is Dictionary:
				entries[str(entry.get("id", ""))] = entry
	else:
		push_warning("[PluginAutoUpdater] Registry unreadable; marketplace plugin updates could not be checked: %s"
			% MarketplaceClient.format_install_error(fetched))
	return entries


## A manual action checks now, then uses the same conditional update job.
static func update_one(manager, id: String, registry_url: String = "") -> Job:
	if _attached(manager, id):
		return null
	var entries := await fetch_entries(manager, [id], registry_url)
	return queue_update(manager, id, entries.get(id, {}), true)


## Rejudge after listing I/O; the install repeats this predicate under lock.
static func queue_update(manager, id: String, entry: Dictionary, manual: bool = false) -> Job:
	if _attached(manager, id) or manager.is_shutting_down() or manager.install_queue == null or entry.get("id", "") != id:
		return null
	var def: PluginDefinition = manager.get_db().get_by_id(id)
	if not wants_update(def, str(entry.get("version", "")), manual) or manager.install_queue.pending_for(id) != null:
		return null
	var job: Job = manager.install_queue.request(entry, false, true, false, manual)
	print("[PluginAutoUpdater] Updating '%s' %s -> %s" % [id, def.version, entry.version])
	job.finished.connect(func() -> void:
		print("[PluginAutoUpdater] '%s' update to %s: %s %s" % [id, entry.version, job.outcome, job.message]), CONNECT_ONE_SHOT)
	return job


static func _attached(manager, id: String) -> bool:
	return manager.has_method("is_attached") and manager.is_attached(id)


## Installed, marketplace-lane and older than `version` ("" skips version).
## Startup additionally requires opt-in; an explicit manual action does not.
static func wants_update(def: PluginDefinition, version: String, manual: bool = false) -> bool:
	return def != null and (manual or def.auto_update) and def.install_lane == PluginDefinition.LANE_MARKETPLACE \
		and (version.is_empty() or compare_versions(version, def.version) > 0)


## -1, 0 or 1 as version `a` is older than, equal to or newer than `b`:
## dot-separated numeric parts compared as numbers (missing parts are 0), and
## a release is newer than the same version with a pre-release suffix
## ("1.2.0" > "1.2.0-rc.1"). Pre-release suffixes compare part by part, dot
## separated: numeric parts as numbers ("rc.10" > "rc.2"), others as text, a
## numeric part below a text one. Build metadata after "+" is ignored.
static func compare_versions(a: String, b: String) -> int:
	var a_parts := a.get_slice("+", 0).split("-", true, 1)
	var b_parts := b.get_slice("+", 0).split("-", true, 1)
	var a_nums := a_parts[0].split(".")
	var b_nums := b_parts[0].split(".")
	for i in maxi(a_nums.size(), b_nums.size()):
		var x := int(a_nums[i]) if i < a_nums.size() else 0
		var y := int(b_nums[i]) if i < b_nums.size() else 0
		if x != y:
			return 1 if x > y else -1
	var a_pre := a_parts[1] if a_parts.size() > 1 else ""
	var b_pre := b_parts[1] if b_parts.size() > 1 else ""
	if a_pre == b_pre:
		return 0
	if a_pre.is_empty():
		return 1
	if b_pre.is_empty():
		return -1
	var a_ids := a_pre.split(".")
	var b_ids := b_pre.split(".")
	for i in mini(a_ids.size(), b_ids.size()):
		var x := a_ids[i]
		var y := b_ids[i]
		if x == y:
			continue
		if x.is_valid_int() and y.is_valid_int():
			return 1 if int(x) > int(y) else -1
		if x.is_valid_int() != y.is_valid_int():
			return -1 if x.is_valid_int() else 1
		return 1 if x > y else -1
	return signi(a_ids.size() - b_ids.size())
