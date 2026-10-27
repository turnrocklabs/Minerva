extends RefCounted
## At Minerva start, updates the plugins the user opted in to (auto_update)
## to the newer release (the marketplace registry, or a required plugin's own
## releases, RequiredPlugins), through the install queue: one at a time, the
## queue's upgrade transaction (a running plugin must start before the update
## commits, or it is rolled back), unattended consent (nothing is asked;
## skills the user customised keep their version, and skills the update adds
## are not seeded). Each update's outcome is logged when it ends. Only
## marketplace-lane plugins are updated; a manifest-lane (developer) plugin is
## never overwritten. Required-plugin updates get a bounded window before
## autostart; marketplace updates keep their asynchronous post-start order.
## The same per-plugin path handles manual clicks, which bypass only opt-in.
## `manager` uses Node with dynamic calls to avoid compiling its autoload dependencies into
## --script suites that load RequiredPlugins before autoload readiness.

const Job := preload("res://Scripts/Services/Plugins/PluginInstallJob.gd")
enum Phase { ALL, REQUIRED, MARKETPLACE }
const STARTUP_WAIT_MSEC: int = 15000

## Do not spawn an old required binary before its opted-in update. Listing
## may outlive the window, so its deadline is checked again before queuing.
static func before_autostart(manager: Node) -> void:
	var deadline: int = Time.get_ticks_msec() + STARTUP_WAIT_MSEC
	var progress: Dictionary = {"listing": true, "jobs": {}}
	_prepare_required(manager, progress, deadline)
	while not manager.call("is_shutting_down") and Time.get_ticks_msec() < deadline:
		var jobs: Dictionary = progress.jobs
		if not progress.listing and jobs.values().all(func(job: Job) -> bool: return job.state == Job.State.DONE):
			return
		await manager.get_tree().create_timer(0.05).timeout
	var queue: Node = manager.get("install_queue")
	for job: Job in progress.jobs.values():
		if job.state != Job.State.DONE:
			queue.call("cancel", job)
	push_warning("[PluginAutoUpdater] Required-plugin startup update window ended; continuing autostart")


static func _prepare_required(manager: Node, progress: Dictionary, deadline: int) -> void:
	progress.jobs = await run(manager, "", Phase.REQUIRED, deadline)
	progress.listing = false

## Queue an update for every opted-in plugin whose registry entry is newer
## than the installed version. Returns the jobs queued, keyed by plugin id.
static func run(manager: Node, registry_url: String = "", phase: Phase = Phase.ALL, deadline: int = 0) -> Dictionary:
	var db: Object = manager.call("get_db")
	var definitions: Array = db.call("get_all")
	var candidates: Array = definitions.filter(func(def: PluginDefinition) -> bool:
		return (phase == Phase.ALL or RequiredPlugins.has(def.id) == (phase == Phase.REQUIRED)) \
			and not _attached(manager, def.id) and wants_update(def, ""))
	if candidates.is_empty() or manager.get("install_queue") == null:
		return {}
	var ids: Array[String] = []
	for candidate: PluginDefinition in candidates:
		ids.append(candidate.id)
	var entries := await fetch_entries(manager, ids, registry_url)
	var queued := {}
	for id: String in ids:
		if deadline > 0 and Time.get_ticks_msec() >= deadline:
			break
		var entry: Dictionary = entries.get(id, {})
		var job := queue_update(manager, id, entry)
		if job != null:
			queued[id] = job
	return queued


## Refresh each plugin's own release lane; there is no cached listing here.
static func fetch_entries(manager: Node, ids: Array[String], registry_url: String = "") -> Dictionary:
	if ids.is_empty() or manager.call("is_shutting_down"):
		return {}
	var entries := {}
	if ids.any(func(id: String) -> bool: return not RequiredPlugins.has(id)):
		entries = await _fetch_registry_entries(manager, registry_url)
	# Required plugins are published as their own releases, not in the registry.
	if ids.any(func(id: String) -> bool: return RequiredPlugins.has(id)):
		entries.merge(await RequiredPlugins.fetch_entries(manager), true)
	return {} if manager.call("is_shutting_down") else entries


static func _fetch_registry_entries(manager: Node, registry_url: String) -> Dictionary:
	var client: MarketplaceClient = MarketplaceClient.new()
	manager.add_child(client)
	var fetched: Dictionary = await client.fetch_registry(registry_url)
	client.queue_free()
	if manager.call("is_shutting_down"):
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
static func update_one(manager: Node, id: String, registry_url: String = "") -> Job:
	if _attached(manager, id):
		return null
	var entries := await fetch_entries(manager, [id], registry_url)
	var entry: Dictionary = entries.get(id, {})
	return queue_update(manager, id, entry, true)


## Rejudge after listing I/O; the install repeats this predicate under lock.
static func queue_update(manager: Node, id: String, entry: Dictionary, manual: bool = false) -> Job:
	if _attached(manager, id) or manager.call("is_shutting_down") or manager.get("install_queue") == null or entry.get("id", "") != id:
		return null
	var db: Object = manager.call("get_db")
	var def: PluginDefinition = db.call("get_by_id", id)
	var queue: Node = manager.get("install_queue")
	if not wants_update(def, str(entry.get("version", "")), manual) or queue.call("pending_for", id) != null:
		return null
	var job: Job = queue.call("request", entry, false, true, false, manual)
	print("[PluginAutoUpdater] Updating '%s' %s -> %s" % [id, def.version, entry.version])
	job.finished.connect(func() -> void:
		print("[PluginAutoUpdater] '%s' update to %s: %s %s" % [id, entry.version, job.outcome, job.message]), CONNECT_ONE_SHOT)
	return job


static func _attached(manager: Object, id: String) -> bool:
	# Runtime flags are empty before autostart. The profile registration is
	# authoritative even then, and a refused registration must stay exempt too.
	if id == "docket":
		var discovery: RefCounted = manager.get("endpoint_discovery")
		if discovery != null:
			var found: Dictionary = discovery.call("discover")
			if found.get("attached", false) or found.has("error"):
				return true
	if manager.has_method("is_attached") and manager.call("is_attached", id):
		return true
	var status: Dictionary = manager.call("get_plugin_status", id) if manager.has_method("get_plugin_status") else {}
	return status.get("attach_refused", false)


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
