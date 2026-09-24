extends RefCounted
## At Minerva start, updates the plugins the user opted in to (auto_update)
## to the marketplace's newer release, through the install queue: one at a
## time, the queue's upgrade transaction (a running plugin must start before
## the update commits, or it is rolled back), unattended consent (nothing is
## asked; skills the user customised keep their version). Each update's
## outcome is logged when it ends. Only marketplace-lane plugins are updated; a
## manifest-lane (developer) plugin is never overwritten. Nothing is awaited
## by startup, and a registry that cannot be read is logged and retried at
## the next start.

## Queue an update for every opted-in plugin whose registry entry is newer
## than the installed version. Returns the jobs queued, keyed by plugin id.
static func run(manager, registry_url: String = "") -> Dictionary:
	var candidates: Array = manager.get_db().get_all().filter(func(def) -> bool:
		return def.auto_update and def.install_lane == PluginDefinition.LANE_MARKETPLACE \
			and not InternalPlugins.has(def.id))
	if candidates.is_empty() or manager.install_queue == null:
		return {}
	var client: Node = MarketplaceClient.new()
	manager.add_child(client)
	var fetched: Dictionary = await client.fetch_registry(registry_url)
	client.queue_free()
	if manager.get("_shutting_down"):
		return {}
	if not fetched.get("ok", false):
		push_warning("[PluginAutoUpdater] Registry unreadable; plugin updates wait for the next start: %s"
			% MarketplaceClient.format_install_error(fetched))
		return {}
	var entries := {}
	for entry in fetched.registry.get("plugins", []):
		if entry is Dictionary:
			entries[str(entry.get("id", ""))] = entry
	var queued := {}
	for def in candidates:
		var entry: Dictionary = entries.get(def.id, {})
		if entry.is_empty() or compare_versions(str(entry.get("version", "")), def.version) <= 0:
			continue
		# A request the user already made stands, with its own choices.
		var existing: Array = manager.install_queue.jobs()
		var job = manager.install_queue.request(entry)
		# Refused at once (it conflicts with the user's own request) or
		# following it: the user's install does the work, not this one.
		if job in existing or job.state == job.State.DONE or job.joined != null:
			continue
		job.op.unattended = true
		queued[def.id] = job
		print("[PluginAutoUpdater] Updating '%s' %s -> %s" % [def.id, def.version, entry.version])
		job.finished.connect(func() -> void:
			print("[PluginAutoUpdater] '%s' update to %s: %s %s" % [def.id, entry.version, job.outcome, job.message]),
			CONNECT_ONE_SHOT)
	return queued


## -1, 0 or 1 as version `a` is older than, equal to or newer than `b`:
## dot-separated numeric parts compared as numbers (missing parts are 0), and
## a release is newer than the same version with a pre-release suffix
## ("1.2.0" > "1.2.0-rc.1"). Suffixes themselves compare as text; build
## metadata after "+" is ignored.
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
	return 1 if a_pre > b_pre else -1
