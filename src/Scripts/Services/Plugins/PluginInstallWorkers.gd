extends RefCounted
## The install worker threads that are running (PluginDownloader's transfer,
## PluginArchive's extract and verify), so that PluginManager.shutdown_all
## can stop them before Minerva exits: a thread still running while the
## process tears down keeps using engine state being freed, and can crash it.
## Main thread only: the workers themselves never call these.

# [{thread: Thread, stop: Callable}]
static var _running: Array = []


## Track `thread` until untrack; `stop` asks it to finish soon (it is called
## from the main thread and must not wait).
static func track(thread: Thread, stop: Callable) -> void:
	_running.append({"thread": thread, "stop": stop})


static func untrack(thread: Thread) -> void:
	_running = _running.filter(func(worker: Dictionary) -> bool: return worker.thread != thread)


## Ask every tracked worker to stop, then wait for each to finish. Returns
## how many there were.
static func stop_all() -> int:
	var workers := _running
	_running = []
	for worker in workers:
		worker.stop.call()
	for worker in workers:
		if worker.thread.is_started():
			worker.thread.wait_to_finish()
	return workers.size()
