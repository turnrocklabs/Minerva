#include "process_file_lock.h"

#include <godot_cpp/core/class_db.hpp>

#ifdef PLATFORM_WINDOWS
#include <windows.h>
#else
#include <cerrno>
#include <cstdio>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#endif

using namespace godot;

void ProcessFileLock::_bind_methods() {
    ClassDB::bind_method(D_METHOD("try_lock_status", "path"), &ProcessFileLock::try_lock_status);
    ClassDB::bind_method(D_METHOD("try_lock", "path"), &ProcessFileLock::try_lock);
    ClassDB::bind_method(D_METHOD("unlock"), &ProcessFileLock::unlock);
    ClassDB::bind_method(D_METHOD("is_locked"), &ProcessFileLock::is_locked);
    ClassDB::bind_static_method("ProcessFileLock", D_METHOD("replace_file", "from", "to"), &ProcessFileLock::replace_file);
}

ProcessFileLock::~ProcessFileLock() {
    unlock();
}

bool ProcessFileLock::try_lock(const String &path) {
    return try_lock_status(path) == OK;
}

#ifdef PLATFORM_WINDOWS

Error ProcessFileLock::try_lock_status(const String &path) {
    if (is_locked()) {
        return OK;
    }
    // Share modes let other holders open the file to try their own lock;
    // the byte-range lock is what excludes them.
    HANDLE handle = CreateFileW((LPCWSTR)path.utf16().get_data(), GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle == INVALID_HANDLE_VALUE) {
        return ERR_CANT_OPEN;
    }
    OVERLAPPED overlapped = {};
    if (!LockFileEx(handle, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &overlapped)) {
        DWORD error = GetLastError();
        CloseHandle(handle);
        return error == ERROR_LOCK_VIOLATION ? ERR_BUSY : ERR_CANT_ACQUIRE_RESOURCE;
    }
    _handle = handle;
    return OK;
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

Error ProcessFileLock::replace_file(const String &from, const String &to) {
    return MoveFileExW((LPCWSTR)from.utf16().get_data(), (LPCWSTR)to.utf16().get_data(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) ? OK : FAILED;
}

#else

Error ProcessFileLock::try_lock_status(const String &path) {
    if (is_locked()) {
        return OK;
    }
    int fd = open(path.utf8().get_data(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) {
        return ERR_CANT_OPEN;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        int error = errno;
        close(fd);
        return error == EWOULDBLOCK ? ERR_BUSY : ERR_CANT_ACQUIRE_RESOURCE;
    }
    _fd = fd;
    return OK;
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

Error ProcessFileLock::replace_file(const String &from, const String &to) {
    return rename(from.utf8().get_data(), to.utf8().get_data()) == 0 ? OK : FAILED;
}

#endif
