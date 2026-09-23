#include "process_file_lock.h"

#include <godot_cpp/core/class_db.hpp>

#ifdef PLATFORM_WINDOWS
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#endif

using namespace godot;

void ProcessFileLock::_bind_methods() {
    ClassDB::bind_method(D_METHOD("try_lock", "path"), &ProcessFileLock::try_lock);
    ClassDB::bind_method(D_METHOD("unlock"), &ProcessFileLock::unlock);
    ClassDB::bind_method(D_METHOD("is_locked"), &ProcessFileLock::is_locked);
}

ProcessFileLock::~ProcessFileLock() {
    unlock();
}

#ifdef PLATFORM_WINDOWS

bool ProcessFileLock::try_lock(const String &path) {
    if (is_locked()) {
        return true;
    }
    // Share modes let other holders open the file to try their own lock;
    // the byte-range lock is what excludes them.
    HANDLE handle = CreateFileW((LPCWSTR)path.utf16().get_data(), GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle == INVALID_HANDLE_VALUE) {
        return false;
    }
    OVERLAPPED overlapped = {};
    if (!LockFileEx(handle, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &overlapped)) {
        CloseHandle(handle);
        return false;
    }
    _handle = handle;
    return true;
}

void ProcessFileLock::unlock() {
    if (_handle != nullptr) {
        // Unlock explicitly: a lock left to CloseHandle may be released late.
        OVERLAPPED overlapped = {};
        UnlockFileEx((HANDLE)_handle, 0, 1, 0, &overlapped);
        CloseHandle((HANDLE)_handle);
        _handle = nullptr;
    }
}

bool ProcessFileLock::is_locked() const {
    return _handle != nullptr;
}

#else

bool ProcessFileLock::try_lock(const String &path) {
    if (is_locked()) {
        return true;
    }
    int fd = open(path.utf8().get_data(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) {
        return false;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        close(fd);
        return false;
    }
    _fd = fd;
    return true;
}

void ProcessFileLock::unlock() {
    if (_fd >= 0) {
        close(_fd);  // closing the descriptor releases the lock
        _fd = -1;
    }
}

bool ProcessFileLock::is_locked() const {
    return _fd >= 0;
}

#endif
