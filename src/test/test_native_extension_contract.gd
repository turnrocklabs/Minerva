extends SceneTree
## Run in a disposable minimal editor project with no terminal extension.

func _initialize() -> void:
	var contract: GDScript = load("res://NativeExtensionContract.gd")
	var message: String = contract.warning()
	var passed: bool = not ClassDB.class_exists("ProcessFileLock") \
		and message.contains("ProcessFileLock.try_lock_status") \
		and message.contains("SubProcess.stop_gracefully") \
		and message.contains("libterminal.linux.template_debug.x86_64.so") \
		and message.contains("scripts/build-extensions.sh linux --terminal-only")
	if passed:
		push_warning(message)
	print("NATIVE_CONTRACT_PASS" if passed else "NATIVE_CONTRACT_FAIL")
	quit(0 if passed else 1)
