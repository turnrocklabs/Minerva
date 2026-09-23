#ifndef PROCESS_FILE_LOCK_H
#define PROCESS_FILE_LOCK_H

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

/// An exclusive, non-blocking lock on a file, held until unlock(), until
/// this object is freed, or until the process exits (the OS releases it
/// then, however the process ends). Separate ProcessFileLock objects on the
/// same path conflict, even within one process. The handle is never
/// inherited by child processes. Unix: flock(LOCK_EX | LOCK_NB);
/// Windows: LockFileEx(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY).
///
/// Also offers replace_file(), which moves a file over another in one step
/// (rename on Unix, MoveFileExW with MOVEFILE_REPLACE_EXISTING on Windows),
/// so a reader sees the old file or the new one, never neither. Both paths
/// must be on the same volume; otherwise replace_file fails.
class ProcessFileLock : public RefCounted {
    GDCLASS(ProcessFileLock, RefCounted)

private:
#ifdef PLATFORM_WINDOWS
    void *_handle = nullptr;
#else
    int _fd = -1;
#endif

protected:
    static void _bind_methods();

public:
    ~ProcessFileLock();

    /// Create `path` if needed and lock it: OK; ERR_BUSY when another holder
    /// has it; ERR_CANT_OPEN when the file cannot be opened or created;
    /// ERR_CANT_ACQUIRE_RESOURCE for any other locking failure.
    Error try_lock_status(const String &path);
    /// try_lock_status(path) == OK.
    bool try_lock(const String &path);
    void unlock();
    bool is_locked() const;

    /// Move `from` over `to`, replacing it, as a single filesystem operation.
    static Error replace_file(const String &from, const String &to);
};

}

#endif
