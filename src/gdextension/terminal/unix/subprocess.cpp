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
#include <spawn.h>
#include <cstring>
#ifdef __APPLE__
#include <crt_externs.h>
#define MINERVA_ENVIRON (*_NSGetEnviron())
#else
extern char **environ;
#define MINERVA_ENVIRON environ
#endif

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
    int stdin_pipe[2] = {-1, -1};   // [0] = read end, [1] = write end
    int stdout_pipe[2] = {-1, -1};
    int stderr_pipe[2] = {-1, -1};

    auto make_pipe = [](int pair[2]) {
#ifdef __linux__
        return pipe2(pair, O_CLOEXEC);
#else
        if (pipe(pair) != 0) return -1;
        if (fcntl(pair[0], F_SETFD, FD_CLOEXEC) != 0
                || fcntl(pair[1], F_SETFD, FD_CLOEXEC) != 0) {
            int saved = errno;
            close(pair[0]); close(pair[1]);
            pair[0] = pair[1] = -1;
            errno = saved;
            return -1;
        }
        return 0;
#endif
    };
    if (make_pipe(stdin_pipe) == -1 || make_pipe(stdout_pipe) == -1
            || make_pipe(stderr_pipe) == -1) {
        for (int fd : {stdin_pipe[0], stdin_pipe[1], stdout_pipe[0], stdout_pipe[1],
                       stderr_pipe[0], stderr_pipe[1]}) if (fd >= 0) close(fd);
        UtilityFunctions::push_error("SubProcess: Failed to create pipes");
        return false;
    }
    auto close_pipes = [&]() {
        for (int fd : {stdin_pipe[0], stdin_pipe[1], stdout_pipe[0], stdout_pipe[1],
                       stderr_pipe[0], stderr_pipe[1]}) if (fd >= 0) close(fd);
    };
    // File actions may install fd 0/1/2 before later closes. Move every owned
    // endpoint above the stdio range so those actions cannot clobber each other.
    for (int *pair : {stdin_pipe, stdout_pipe, stderr_pipe}) {
        for (int i = 0; i < 2; ++i) {
            if (pair[i] <= STDERR_FILENO) {
                int moved = fcntl(pair[i], F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
                if (moved < 0) { close_pipes(); return false; }
                close(pair[i]);
                pair[i] = moved;
            }
        }
    }

    CharString cmd_utf8 = command.utf8();
    std::vector<CharString> storage;
    storage.reserve(static_cast<size_t>(args.size()) + 1);
    storage.push_back(cmd_utf8);
    for (int i = 0; i < args.size(); ++i) storage.push_back(args[i].utf8());
    std::vector<char *> argv;
    argv.reserve(storage.size() + 1);
    for (CharString &value : storage) argv.push_back(const_cast<char *>(value.ptr()));
    argv.push_back(nullptr);

    posix_spawn_file_actions_t actions;
    int spawn_error = posix_spawn_file_actions_init(&actions);
    const bool actions_initialized = spawn_error == 0;
    auto add = [&](int result) { if (spawn_error == 0 && result != 0) spawn_error = result; };
    if (spawn_error == 0) {
        add(posix_spawn_file_actions_adddup2(&actions, stdin_pipe[0], STDIN_FILENO));
        add(posix_spawn_file_actions_adddup2(&actions, stdout_pipe[1], STDOUT_FILENO));
        add(posix_spawn_file_actions_adddup2(&actions, stderr_pipe[1], STDERR_FILENO));
        for (int fd : {stdin_pipe[0], stdin_pipe[1], stdout_pipe[0], stdout_pipe[1],
                       stderr_pipe[0], stderr_pipe[1]})
            add(posix_spawn_file_actions_addclose(&actions, fd));
    }
    pid_t child = -1;
    if (spawn_error == 0)
        spawn_error = posix_spawnp(&child, cmd_utf8.ptr(), &actions, nullptr,
                                   argv.data(), MINERVA_ENVIRON);
    if (actions_initialized) posix_spawn_file_actions_destroy(&actions);
    if (spawn_error != 0) {
        close_pipes();
        UtilityFunctions::push_error("SubProcess: posix_spawnp failed: " + String(strerror(spawn_error)));
        return false;
    }
    _child_pid = child;

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
        int status = 0;
        pid_t waited = waitpid(_child_pid, &status, WNOHANG);
        if (waited == _child_pid && WIFEXITED(status)) {
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
