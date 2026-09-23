extends SceneTree
## Child process for test_marketplace_install_transaction: takes a
## ProcessFileLock on the path it is given, writes the marker file once it
## holds it, and waits to be killed. The lock must be released by the OS
## when this process dies.
##
##   godot --headless --path src --script res://test/fixtures/hold_process_lock.gd -- <lock path> <marker path>

var _lock


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	_lock = ClassDB.instantiate("ProcessFileLock")
	if _lock == null or _lock.try_lock_status(args[0]) != OK:
		quit(1)
		return
	var marker := FileAccess.open(args[1], FileAccess.WRITE)
	marker.store_string("locked")
	marker.close()
	# Hold the lock until killed; quit after a minute in case nobody does.
	await create_timer(60.0).timeout
	quit(0)
