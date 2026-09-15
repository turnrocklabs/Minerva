#include "subprocess.h"
#include "common/utf8_line_buffer.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <poll.h>
#include <sys/wait.h>
#include <cstring>

using namespace godot;

void SubProcess::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("start", "command", "args"), &SubProcess::start, DEFVAL(PackedStringArray()));
    ClassDB::bind_method(D_METHOD("stop"), &SubProcess::stop);
    ClassDB::bind_method(D_METHOD("write_data", "data"), &SubProcess::write_data);
    ClassDB::bind_method(D_METHOD("has_io_overflow"), &SubProcess::has_io_overflow);
    ClassDB::bind_method(D_METHOD("_emit_output_ready"), &SubProcess::_emit_output_ready);
    ClassDB::bind_method(D_METHOD("_emit_stderr_ready"), &SubProcess::_emit_stderr_ready);
    ClassDB::bind_method(D_METHOD("is_running"), &SubProcess::is_running);
    ClassDB::bind_method(D_METHOD("has_output"), &SubProcess::has_output);
    ClassDB::bind_method(D_METHOD("read_line"), &SubProcess::read_line);
    ClassDB::bind_method(D_METHOD("read_all"), &SubProcess::read_all);
    ClassDB::bind_method(D_METHOD("has_stderr"), &SubProcess::has_stderr);
    ClassDB::bind_method(D_METHOD("read_stderr_line"), &SubProcess::read_stderr_line);
    ClassDB::bind_method(D_METHOD("read_all_stderr"), &SubProcess::read_all_stderr);

    ADD_SIGNAL(MethodInfo("output_ready"));
    ADD_SIGNAL(MethodInfo("stderr_ready"));
    ADD_SIGNAL(MethodInfo("process_exited", PropertyInfo(Variant::INT, "exit_code")));
    ADD_SIGNAL(MethodInfo("io_overflow"));
}

SubProcess::SubProcess()
{
    _stdin_fd = -1;
    _stdout_fd = -1;
    _stderr_fd = -1;
    _child_pid = -1;
}

SubProcess::~SubProcess()
{
    stop();
}

bool SubProcess::start(const String &command, const PackedStringArray &args)
{
    if (_running)
        return false;

    // Create pipes for stdin, stdout, and stderr (all separate)
    int stdin_pipe[2];   // [0] = read end, [1] = write end
    int stdout_pipe[2];
    int stderr_pipe[2];

    if (pipe(stdin_pipe) == -1 || pipe(stdout_pipe) == -1 || pipe(stderr_pipe) == -1) {
        UtilityFunctions::push_error("SubProcess: Failed to create pipes");
        return false;
    }

    _child_pid = fork();

    if (_child_pid == -1) {
        // Fork failed
        close(stdin_pipe[0]);
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);
        close(stdout_pipe[1]);
        close(stderr_pipe[0]);
        close(stderr_pipe[1]);
        UtilityFunctions::push_error("SubProcess: Fork failed");
        return false;
    }

    if (_child_pid == 0) {
        // Child process

        // Redirect stdin
        close(stdin_pipe[1]);  // Close write end
        dup2(stdin_pipe[0], STDIN_FILENO);
        close(stdin_pipe[0]);

        // Redirect stdout (separate pipe — clean JSON-RPC transport)
        close(stdout_pipe[0]);  // Close read end
        dup2(stdout_pipe[1], STDOUT_FILENO);
        close(stdout_pipe[1]);

        // Redirect stderr to its own pipe (NOT merged into stdout)
        close(stderr_pipe[0]);  // Close read end
        dup2(stderr_pipe[1], STDERR_FILENO);
        close(stderr_pipe[1]);

        // Build argv
        CharString cmd_utf8 = command.utf8();
        std::vector<char*> argv;
        argv.push_back(const_cast<char*>(cmd_utf8.ptr()));

        std::vector<CharString> arg_storage;
        for (int i = 0; i < args.size(); i++) {
            arg_storage.push_back(args[i].utf8());
            argv.push_back(const_cast<char*>(arg_storage.back().ptr()));
        }
        argv.push_back(nullptr);

        execvp(cmd_utf8.ptr(), argv.data());

        // If execvp returns, it failed
        _exit(127);
    }

    // Parent process

    // Close unused pipe ends
    close(stdin_pipe[0]);   // Close read end of stdin pipe
    close(stdout_pipe[1]);  // Close write end of stdout pipe
    close(stderr_pipe[1]);  // Close write end of stderr pipe

    _stdin_fd = stdin_pipe[1];
    _stdout_fd = stdout_pipe[0];
    _stderr_fd = stderr_pipe[0];

    // Set stdout and stderr to non-blocking
    int flags = fcntl(_stdout_fd, F_GETFL);
    fcntl(_stdout_fd, F_SETFL, flags | O_NONBLOCK);
    int err_flags = fcntl(_stderr_fd, F_GETFL);
    fcntl(_stderr_fd, F_SETFL, err_flags | O_NONBLOCK);

    _running = true;
	_io_overflow = false;
	_output_notification_pending = false;
	_stderr_notification_pending = false;
	{
		std::lock_guard<std::mutex> lock(_write_mutex);
		while (!_write_queue.empty()) _write_queue.pop();
		_queued_write_bytes = 0;
	}
	{
		std::lock_guard<std::mutex> lock(_output_mutex);
		while (!_output_queue.empty()) _output_queue.pop();
		_queued_output_bytes = 0;
	}
	{
		std::lock_guard<std::mutex> lock(_stderr_mutex);
		while (!_stderr_queue.empty()) _stderr_queue.pop();
		_queued_stderr_bytes = 0;
	}
	int in_flags = fcntl(_stdin_fd, F_GETFL);
	fcntl(_stdin_fd, F_SETFL, in_flags | O_NONBLOCK);

    // Start read threads for stdout and stderr
    _read_thread = std::thread([this]() {
        _read_loop();
    });
    _stderr_thread = std::thread([this]() {
        _stderr_read_loop();
    });
    _write_thread = std::thread([this]() { _write_loop(); });

    return true;
}

void SubProcess::_read_loop()
{
    char buffer[4096];
    Utf8LineBuffer line_buffer;

    while (_running) {
        ssize_t bytes_read = read(_stdout_fd, buffer, sizeof(buffer) - 1);

        if (bytes_read > 0) {
            line_buffer.append(buffer, bytes_read);
            if (line_buffer.size() > MAX_QUEUED_BYTES) { line_buffer.clear(); _record_overflow(); }
            String line;
            while (line_buffer.pop_line(line)) {

                bool queued = false;
                {
                    std::lock_guard<std::mutex> lock(_output_mutex);
                    size_t bytes = static_cast<size_t>(line.utf8().length());
                    if (_output_queue.size() >= MAX_QUEUED_LINES || _queued_output_bytes + bytes > MAX_QUEUED_BYTES) {
                        _record_overflow();
                    } else {
                        _queued_output_bytes += bytes;
                        _output_queue.push(line);
                        queued = true;
                    }
                }
                if (queued && !_output_notification_pending.exchange(true))
                    call_deferred("_emit_output_ready");
            }
        } else if (bytes_read == 0) {
            // EOF - process closed stdout
            break;
        } else if (bytes_read == -1) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                // No data available, sleep and retry
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            } else {
                // Real error
                break;
            }
        }
    }

    // Check exit status
    if (_child_pid > 0) {
        int status;
        waitpid(_child_pid, &status, WNOHANG);
        if (WIFEXITED(status)) {
            int exit_code = WEXITSTATUS(status);
            call_deferred("emit_signal", "process_exited", exit_code);
        }
    }
}

void SubProcess::stop()
{
    if (!_running)
        return;

    _running = false;
	_write_ready.notify_all();
	if (_write_thread.joinable()) {
		_write_thread.join();
	}

    // Close stdin to signal EOF to child
    if (_stdin_fd >= 0) {
        close(_stdin_fd);
        _stdin_fd = -1;
    }

    // Give process time to exit gracefully
    if (_child_pid > 0) {
        int status;
        pid_t result = waitpid(_child_pid, &status, WNOHANG);

        if (result == 0) {
            // Process still running, send SIGTERM
            kill(_child_pid, SIGTERM);

            // Wait a bit
            usleep(100000);  // 100ms

            result = waitpid(_child_pid, &status, WNOHANG);
            if (result == 0) {
                // Still running, force kill
                kill(_child_pid, SIGKILL);
                waitpid(_child_pid, &status, 0);
            }
        }

        _child_pid = -1;
    }

    // Wait for read threads
    if (_read_thread.joinable()) {
        _read_thread.join();
    }
    if (_stderr_thread.joinable()) {
        _stderr_thread.join();
    }

    // Close stdout and stderr
    if (_stdout_fd >= 0) {
        close(_stdout_fd);
        _stdout_fd = -1;
    }
    if (_stderr_fd >= 0) {
        close(_stderr_fd);
        _stderr_fd = -1;
    }
}

bool SubProcess::write_data(const String &data)
{
    if (!_running || _stdin_fd < 0 || data.is_empty())
        return false;

    CharString utf8 = data.utf8();
    std::string bytes(utf8.ptr(), static_cast<size_t>(utf8.length()));
    {
        std::lock_guard<std::mutex> lock(_write_mutex);
        if (_write_queue.size() >= MAX_QUEUED_LINES || _queued_write_bytes + bytes.size() > MAX_QUEUED_WRITE_BYTES)
            return false;
        _queued_write_bytes += bytes.size();
        _write_queue.push(std::move(bytes));
    }
    _write_ready.notify_one();
    return true;
}

void SubProcess::_write_loop()
{
    while (_running) {
        std::string data;
        {
            std::unique_lock<std::mutex> lock(_write_mutex);
            _write_ready.wait(lock, [this]() { return !_running || !_write_queue.empty(); });
            if (!_running) break;
            data = std::move(_write_queue.front());
            _queued_write_bytes -= data.size();
            _write_queue.pop();
        }
        size_t sent = 0;
        while (_running && sent < data.size()) {
            ssize_t written = write(_stdin_fd, data.data() + sent, data.size() - sent);
            if (written > 0) sent += static_cast<size_t>(written);
            else if (written < 0 && errno == EINTR) continue;
            else if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                struct pollfd pfd {_stdin_fd, POLLOUT, 0};
                poll(&pfd, 1, 50);
            } else break;
        }
        if (_running && sent != data.size()) _record_overflow();
    }
}

bool SubProcess::has_output()
{
    std::lock_guard<std::mutex> lock(_output_mutex);
    return !_output_queue.empty();
}

String SubProcess::read_line()
{
    std::lock_guard<std::mutex> lock(_output_mutex);
    if (_output_queue.empty())
        return String();

    String line = _output_queue.front();
    _output_queue.pop();
    _queued_output_bytes -= static_cast<size_t>(line.utf8().length());
    return line;
}

String SubProcess::read_all()
{
    std::lock_guard<std::mutex> lock(_output_mutex);
    String result;
    while (!_output_queue.empty()) {
        if (!result.is_empty())
            result += "\n";
        result += _output_queue.front();
        _queued_output_bytes -= static_cast<size_t>(_output_queue.front().utf8().length());
        _output_queue.pop();
    }
    return result;
}

void SubProcess::_stderr_read_loop()
{
    char buffer[4096];
    Utf8LineBuffer line_buffer;

    while (_running) {
        ssize_t bytes_read = read(_stderr_fd, buffer, sizeof(buffer) - 1);

        if (bytes_read > 0) {
            line_buffer.append(buffer, bytes_read);
            if (line_buffer.size() > MAX_QUEUED_BYTES) { line_buffer.clear(); _record_overflow(); }
            String line;
            while (line_buffer.pop_line(line)) {

                bool queued = false;
                {
                    std::lock_guard<std::mutex> lock(_stderr_mutex);
                    size_t bytes = static_cast<size_t>(line.utf8().length());
                    if (_stderr_queue.size() >= MAX_QUEUED_LINES || _queued_stderr_bytes + bytes > MAX_QUEUED_BYTES) {
                        _record_overflow();
                    } else {
                        _queued_stderr_bytes += bytes;
                        _stderr_queue.push(line);
                        queued = true;
                    }
                }
                if (queued && !_stderr_notification_pending.exchange(true))
                    call_deferred("_emit_stderr_ready");
            }
        } else if (bytes_read == 0) {
            // EOF
            break;
        } else if (bytes_read == -1) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            } else {
                break;
            }
        }
    }

    // Flush any remaining partial line
    String tail = line_buffer.take_tail();
    if (!tail.is_empty()) {
        std::lock_guard<std::mutex> lock(_stderr_mutex);
        size_t bytes = static_cast<size_t>(tail.utf8().length());
        if (_stderr_queue.size() >= MAX_QUEUED_LINES || _queued_stderr_bytes + bytes > MAX_QUEUED_BYTES) _record_overflow();
        else {
            _queued_stderr_bytes += bytes;
            _stderr_queue.push(tail);
            if (!_stderr_notification_pending.exchange(true)) call_deferred("_emit_stderr_ready");
        }
    }
}

bool SubProcess::has_stderr()
{
    std::lock_guard<std::mutex> lock(_stderr_mutex);
    return !_stderr_queue.empty();
}

String SubProcess::read_stderr_line()
{
    std::lock_guard<std::mutex> lock(_stderr_mutex);
    if (_stderr_queue.empty())
        return String();

    String line = _stderr_queue.front();
    _stderr_queue.pop();
    _queued_stderr_bytes -= static_cast<size_t>(line.utf8().length());
    return line;
}

void SubProcess::_record_overflow()
{
    if (!_io_overflow.exchange(true))
        call_deferred("emit_signal", "io_overflow");
}

void SubProcess::_emit_output_ready()
{
    _output_notification_pending = false;
    emit_signal("output_ready");
}

void SubProcess::_emit_stderr_ready()
{
    _stderr_notification_pending = false;
    emit_signal("stderr_ready");
}

String SubProcess::read_all_stderr()
{
    std::lock_guard<std::mutex> lock(_stderr_mutex);
    String result;
    while (!_stderr_queue.empty()) {
        if (!result.is_empty())
            result += "\n";
        result += _stderr_queue.front();
        _queued_stderr_bytes -= static_cast<size_t>(_stderr_queue.front().utf8().length());
        _stderr_queue.pop();
    }
    return result;
}
