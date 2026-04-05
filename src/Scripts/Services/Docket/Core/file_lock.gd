extends RefCounted
class_name FileLock
## Advisory file lock using a .lock sidecar file — same pattern as git.
##
## Usage:
##   var lock := FileLock.acquire("/path/to/project.dct.jsonl")
##   if lock == null:
##       push_warning("Could not acquire lock — proceeding anyway")
##   else:
##       _do_write()
##       lock.release()
##
## Lock file path: <protected_path>.lock
## Lock file contents: {"pid": <int>, "timestamp": <float>}
##
## Stale lock detection:
##   - Lock older than STALE_TIMEOUT_SEC seconds is considered stale
##   - OR: lock's PID is not a running process (checked via /proc on Linux)

const STALE_TIMEOUT_SEC := 60.0
const POLL_INTERVAL_MS  := 50

var _lock_path: String = ""
var _locked: bool = false


# -- Public API ---------------------------------------------------------------

static func acquire(path: String, timeout_ms: int = 5000) -> FileLock:
	## Try to acquire a lock for `path`. Returns a locked FileLock on success,
	## or null if the lock could not be acquired within timeout_ms.
	var lock_path := path + ".lock"
	var deadline_ms := Time.get_ticks_msec() + timeout_ms

	while true:
		# Attempt to create the lock file exclusively
		if _try_create_lock(lock_path):
			var fl := FileLock.new()
			fl._lock_path = lock_path
			fl._locked = true
			return fl

		# Lock exists — check if it's stale
		if _is_stale(lock_path):
			# Remove stale lock and retry immediately
			DirAccess.remove_absolute(lock_path)
			continue

		# Active lock held by someone else — check timeout
		if Time.get_ticks_msec() >= deadline_ms:
			push_warning("FileLock: timed out waiting for lock on %s" % path)
			return null

		# Brief wait before retrying — use OS.delay_msec (blocking, but short)
		OS.delay_msec(POLL_INTERVAL_MS)

	return null  # Unreachable, satisfies static analysis


func release() -> void:
	## Release the lock by removing the lock file.
	if not _locked:
		return
	if not _lock_path.is_empty():
		DirAccess.remove_absolute(_lock_path)
	_locked = false


func is_locked() -> bool:
	return _locked


# -- Destructor (safety net) --------------------------------------------------

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _locked:
		release()


# -- Private helpers ----------------------------------------------------------

static func _try_create_lock(lock_path: String) -> bool:
	## Attempt to create the lock file exclusively.
	## Returns true if we successfully created it (we own it).
	## Returns false if it already exists.
	if FileAccess.file_exists(lock_path):
		return false

	# Write PID + timestamp so we can detect stale locks later
	var f := FileAccess.open(lock_path, FileAccess.WRITE)
	if f == null:
		# Could be a race: another process just created it
		return false

	var payload := JSON.stringify({
		"pid": OS.get_process_id(),
		"timestamp": Time.get_unix_time_from_system(),
	})
	f.store_string(payload)
	f.flush()
	f.close()

	# On POSIX, FileAccess.open(WRITE) is not atomic — verify we still own it
	# by re-reading the PID back. If PIDs match, we own it.
	var written := _read_lock_pid(lock_path)
	if written != OS.get_process_id():
		# Race: another process overwrote it after we wrote
		return false

	return true


static func _is_stale(lock_path: String) -> bool:
	## Returns true if the lock file appears to belong to a dead or timed-out process.
	if not FileAccess.file_exists(lock_path):
		return true  # Already gone — treat as stale (caller will retry)

	var f := FileAccess.open(lock_path, FileAccess.READ)
	if f == null:
		return false  # Can't read it — assume active

	var raw := f.get_as_text()
	f.close()

	var parsed = JSON.parse_string(raw)
	if parsed == null or not parsed is Dictionary:
		# Unreadable / corrupt lock → stale
		return true

	# Check age
	var ts: float = float(parsed.get("timestamp", 0.0))
	var age := Time.get_unix_time_from_system() - ts
	if age > STALE_TIMEOUT_SEC:
		return true

	# Check PID liveness
	var pid: int = int(parsed.get("pid", 0))
	if pid > 0 and not _is_pid_running(pid):
		return true

	return false


static func _is_pid_running(pid: int) -> bool:
	## Returns true if the process with `pid` appears to be running.
	## Uses /proc/<pid>/ on Linux; falls back to OS.execute("kill", ["-0", pid]) on macOS.
	## On Windows, always returns false (conservative: don't break stale locks).
	var os_name := OS.get_name()

	if os_name == "Linux":
		return DirAccess.dir_exists_absolute("/proc/%d" % pid)

	if os_name == "macOS":
		var output: Array = []
		var exit_code := OS.execute("kill", ["-0", str(pid)], output, true)
		return exit_code == 0

	# Windows or unknown: fall back to age-based staleness only
	return true


static func _read_lock_pid(lock_path: String) -> int:
	## Read the PID written inside a lock file. Returns -1 on error.
	var f := FileAccess.open(lock_path, FileAccess.READ)
	if f == null:
		return -1
	var raw := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(raw)
	if parsed == null or not parsed is Dictionary:
		return -1
	return int(parsed.get("pid", -1))
