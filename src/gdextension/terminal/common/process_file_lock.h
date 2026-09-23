#ifndef PROCESS_FILE_LOCK_H
#define PROCESS_FILE_LOCK_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

/// An exclusive, non-blocking lock on a file, held until unlock(), until
/// this object is freed, or until the process exits (the OS releases it
/// then, however the process ends). Separate ProcessFileLock objects on the
/// same path conflict, even within one process. The handle is never
/// inherited by child processes. Unix: flock(LOCK_EX | LOCK_NB);
/// Windows: LockFileEx(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY).
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

    /// Create `path` if needed and lock it. Returns false when another
    /// holder has it (or it cannot be opened).
    bool try_lock(const String &path);
    void unlock();
    bool is_locked() const;
};

}

#endif
