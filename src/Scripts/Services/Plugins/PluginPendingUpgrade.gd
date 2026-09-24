extends RefCounted
## The first start of a plugin whose update was installed while it was
## stopped (PluginInstallTransaction.PHASE_PENDING). The update kept the
## working copy it replaced, so this start decides: if the new version
## starts, the update commits and that copy is dropped; if it fails, the
## previous files, DB record and the data as it was before this start are
## put back, keeping the user's current choices (autostart, auto_update,
## auto_reload), and the previous version is started instead. The plugin is
## only ever started because someone asked for it.

const Txn := preload("res://Scripts/Services/Plugins/PluginInstallTransaction.gd")
## The per-plugin choices a user can change after an update, which a rollback
## to the previous record must not undo.
const USER_CHOICES := ["autostart", "auto_update", "auto_reload"]


## Start `plugin_id` through `start_now` (PluginManager's start without this
## check), deciding a pending update on the way. Only a start that can
## actually run decides it: while the plugin is running, starting, in a
## crash loop, waiting on a build, or Minerva is shutting down, start_now's
## own refusal is returned and the update stays pending. Returns start_now's
## result; after a rollback that result is the previous version's, with
## rolled_back: {version, reason, message} added, message being the sentence
## to show (or an error naming both failures).
## The start is refused, the update still pending, when the staging lock is
## held (an install or recovery is in progress) or the data cannot be saved:
## starting the new version then could not be undone. A new version that
## starts but whose update cannot be recorded as done is rolled back at once,
## like one that fails to start.
static func start(manager, plugin_id: String, start_now: Callable) -> Dictionary:
	var staging_root := ProjectSettings.globalize_path(MarketplaceClient.STAGING_DIR)
	var txn = Txn.pending_for(staging_root, plugin_id)
	var db = manager.get_db()
	var current = db.get_by_id(plugin_id)
	if txn == null or current == null or manager.get("_shutting_down") \
			or not current.state in [manager.S_INSTALLED, manager.S_STOPPED, manager.S_ERROR]:
		return await start_now.call()
	if not txn.try_enter(staging_root):
		return {"error": "Plugin '%s' has an update waiting for its first start, and an install or recovery is in progress; start it again once that finishes" % plugin_id}
	if txn.db_before is Dictionary:
		for key in USER_CHOICES:
			txn.db_before[key] = current.get(key)
	# From here the operation is an unfinished replacement again: a crash
	# before it ends is rolled back by the next recovery.
	if not txn.save_data(Txn.data_directory(plugin_id)):
		txn.leave()
		return {"error": "Plugin '%s' has an update waiting for its first start, but its data could not be saved first, so the new version was not started; free disk space under user://plugins/ and start it again" % plugin_id}
	var new_version := str(current.version)
	var started: Dictionary = await start_now.call()
	# What went wrong, as a clause after "v<new version>".
	var failure := ""
	if not started.has("error"):
		if txn.publish(Txn.PHASE_COMMITTED):
			txn.leave()
			MarketplaceClient._rm_dir_recursive(txn.op_dir)
			return started
		# Not recorded as done, a later recovery would roll it back over
		# whatever it wrote meanwhile; so it is undone now, like a failed start.
		failure = "started, but its update could not be recorded as done in %s" % txn.op_dir
	else:
		failure = "did not start (%s)" % started.error
	manager.stop_plugin(plugin_id)
	var final_abs := ProjectSettings.globalize_path("user://plugins").path_join(plugin_id)
	var rollback: Dictionary = txn.roll_back(final_abs, db, txn.db_before)
	txn.leave()
	if not MarketplaceClient.rollback_complete(rollback):
		return {"error": "Plugin '%s' v%s %s, and its previous version could not be fully put back yet; it is kept at %s and Minerva restores it when it next starts." % [
			plugin_id, new_version, failure, rollback.kept_at]}
	MarketplaceClient._rm_dir_recursive(txn.op_dir)
	var previous = db.get_by_id(plugin_id)
	var previous_version: String = str(previous.version) if previous != null else "?"
	push_warning("[PluginPendingUpgrade] '%s' v%s %s; v%s was put back." % [
		plugin_id, new_version, failure, previous_version])
	var restarted: Dictionary = await start_now.call()
	if restarted.has("error"):
		return {"error": "Plugin '%s' v%s %s; v%s was put back but did not start either: %s" % [
			plugin_id, new_version, failure, previous_version, restarted.error]}
	restarted["rolled_back"] = {"version": new_version, "reason": failure,
		"message": "The update of '%s' to v%s %s, so v%s was put back and started." % [
			plugin_id, new_version, failure, previous_version]}
	return restarted
