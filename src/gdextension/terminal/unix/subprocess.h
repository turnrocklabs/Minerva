#ifndef SUBPROCESS_H
#define SUBPROCESS_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <thread>
#include <atomic>
#include <mutex>
#include <queue>

namespace godot {

/// SubProcess - Simple subprocess with stdin/stdout pipe I/O
/// For MCP STDIO transport and similar use cases
class SubProcess : public Node {
    GDCLASS(SubProcess, Node)

private:
    int _stdin_fd;      // Write to child's stdin
    int _stdout_fd;     // Read from child's stdout
    pid_t _child_pid;

    std::atomic<bool> _running{false};
    std::thread _read_thread;

    std::mutex _output_mutex;
    std::queue<String> _output_queue;

    void _read_loop();

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
};

}

#endif // SUBPROCESS_H
