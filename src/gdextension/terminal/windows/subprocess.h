#ifndef WINDOWS_SUBPROCESS_H
#define WINDOWS_SUBPROCESS_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <thread>
#include <atomic>
#include <mutex>
#include <queue>
#include <windows.h>

namespace godot {

/// SubProcess - Simple subprocess with stdin/stdout/stderr pipe I/O (Windows).
/// API-compatible with the unix backend (unix/subprocess.cpp): same methods and
/// the same output_ready / stderr_ready / process_exited signals, so
/// MCPServerConnection's STDIO transport works identically on Windows.
///
/// Implementation: CreateProcessW with three redirected anonymous pipes plus a
/// blocking reader thread per output stream (Windows anonymous pipes don't offer
/// a clean non-blocking poll, so a thread blocked in ReadFile is the idiom; it
/// unblocks when the child closes its write end on exit).
class SubProcess : public Node {
    GDCLASS(SubProcess, Node)

private:
    HANDLE _stdin_wr;       // Write to child's stdin
    HANDLE _stdout_rd;      // Read from child's stdout
    HANDLE _stderr_rd;      // Read from child's stderr (separate from stdout)
    HANDLE _child_process;  // Child process handle

    std::atomic<bool> _running{false};
    std::thread _read_thread;
    std::thread _stderr_thread;

    std::mutex _output_mutex;
    std::queue<String> _output_queue;

    std::mutex _stderr_mutex;
    std::queue<String> _stderr_queue;

    void _read_loop();
    void _stderr_read_loop();

protected:
    static void _bind_methods();

public:
    SubProcess();
    ~SubProcess();

    /// Start subprocess with given command and arguments
    bool start(const String &command, const PackedStringArray &args = PackedStringArray());

    /// Stop the subprocess
    void stop();

    /// Write data to subprocess stdin
    bool write_data(const String &data);

    /// Check if subprocess is running
    bool is_running() const { return _running; }

    /// Check if output is available
    bool has_output();

    /// Read next line of output (returns empty if none available)
    String read_line();

    /// Read all available output
    String read_all();

    /// Check if stderr output is available
    bool has_stderr();

    /// Read next line of stderr (returns empty if none available)
    String read_stderr_line();

    /// Read all available stderr
    String read_all_stderr();
};

}

#endif // WINDOWS_SUBPROCESS_H
