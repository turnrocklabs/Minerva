#ifndef SUBPROCESS_H
#define SUBPROCESS_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <thread>
#include <atomic>
#include <mutex>
#include <queue>
#include <condition_variable>
#include <string>

namespace godot {

/// SubProcess - Simple subprocess with stdin/stdout pipe I/O
/// For MCP STDIO transport and similar use cases
class SubProcess : public Node {
    GDCLASS(SubProcess, Node)

private:
    int _stdin_fd;      // Write to child's stdin
    int _stdout_fd;     // Read from child's stdout
    int _stderr_fd;     // Read from child's stderr (separate from stdout)
    pid_t _child_pid;

    std::atomic<bool> _running{false};
    std::thread _read_thread;
    std::thread _stderr_thread;
    std::thread _write_thread;

    std::mutex _output_mutex;
    std::queue<String> _output_queue;

    std::mutex _stderr_mutex;
    std::queue<String> _stderr_queue;

    std::mutex _write_mutex;
    std::condition_variable _write_ready;
    std::queue<std::string> _write_queue;
    size_t _queued_write_bytes = 0;
    size_t _queued_output_bytes = 0;
    size_t _queued_stderr_bytes = 0;
    std::atomic<bool> _io_overflow{false};
    std::atomic<bool> _output_notification_pending{false};
    std::atomic<bool> _stderr_notification_pending{false};

    static constexpr size_t MAX_QUEUED_LINES = 32;
    static constexpr size_t MAX_QUEUED_BYTES = 40u * 1024u * 1024u;
    static constexpr size_t MAX_QUEUED_WRITE_BYTES = 72u * 1024u * 1024u;

    void _read_loop();
    void _stderr_read_loop();
    void _write_loop();
    void _record_overflow();
    void _emit_output_ready();
    void _emit_stderr_ready();

protected:
    static void _bind_methods();

public:
    SubProcess();
    ~SubProcess();

    /// Start subprocess with given command and arguments
    bool start(const String &command, const PackedStringArray &args = PackedStringArray());

    /// Start it with `extra_env` ({name: value}) added to, or replacing
    /// entries of, the environment it inherits; this process's own
    /// environment is untouched. Refuses (false) a name that is empty or has
    /// '=' or NUL, or a value with NUL, and on Windows two names equal but
    /// for case.
    bool start_with_env(const String &command, const PackedStringArray &args, const Dictionary &extra_env);

    /// The operating-system account this process runs as, or "" when it
    /// cannot be told.
    static String os_account_name();

    /// Stop the subprocess
    void stop();

    /// Admit data to the bounded stdin writer without blocking the caller.
    bool write_data(const String &data);
    bool has_io_overflow() const { return _io_overflow; }

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

#endif // SUBPROCESS_H
