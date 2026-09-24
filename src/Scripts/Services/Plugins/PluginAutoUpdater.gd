extends RefCounted
## At Minerva start, updates the plugins the user opted in to (auto_update)
## to the marketplace's newer release, through the install queue: one at a
## time, the queue's upgrade transaction (a running plugin must start before
## the update commits, or it is rolled back), unattended consent (nothing is
## asked; skills the user customised keep their version, and skills the
## update adds are not seeded). Each update's
## outcome is logged when it ends. Only marketplace-lane plugins are updated; a
## manifest-lane (developer) plugin is never overwritten. Nothing is awaited
## by startup, and a registry that cannot be read is logged and retried at
## the next start.

## Queue an update for every opted-in plugin whose registry entry is newer
## than the installed version. Returns the jobs queued, keyed by plugin id.
static func run(manager, registry_url: String = "") -> Dictionary:
	var candidates: Array = manager.get_db().get_all().filter(func(def) -> bool:
		return wants_update(def, ""))
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
	for candidate in candidates:
		# The fetch took time: judge the plugin as it is now (removed, opted
		# out, moved to the developer lane, or updated by hand meanwhile). The
		# install checks again under its lock before it replaces anything.
		var def = manager.get_db().get_by_id(candidate.id)
		var entry: Dictionary = entries.get(candidate.id, {})
		if entry.is_empty() or not wants_update(def, str(entry.get("version", ""))):
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


## Whether `def` (a PluginDefinition, or null) still wants an unattended
## update to `version`: installed, opted in, on the marketplace lane, not
## host-owned, and older than `version` ("" skips the version check).
static func wants_update(def, version: String) -> bool:
	return def != null and def.auto_update and def.install_lane == PluginDefinition.LANE_MARKETPLACE \
		and not InternalPlugins.has(def.id) \
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
