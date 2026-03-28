#include "subprocess.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <sys/wait.h>
#include <cstring>

using namespace godot;

void SubProcess::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("start", "command", "args"), &SubProcess::start, DEFVAL(PackedStringArray()));
    ClassDB::bind_method(D_METHOD("stop"), &SubProcess::stop);
    ClassDB::bind_method(D_METHOD("write_data", "data"), &SubProcess::write_data);
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

    // Start read threads for stdout and stderr
    _read_thread = std::thread([this]() {
        _read_loop();
    });
    _stderr_thread = std::thread([this]() {
        _stderr_read_loop();
    });

    return true;
}

void SubProcess::_read_loop()
{
    char buffer[4096];
    String line_buffer;

    while (_running) {
        ssize_t bytes_read = read(_stdout_fd, buffer, sizeof(buffer) - 1);

        if (bytes_read > 0) {
            buffer[bytes_read] = '\0';
            String chunk = String::utf8(buffer, bytes_read);

            // Split into lines
            line_buffer += chunk;

            int newline_pos;
            while ((newline_pos = line_buffer.find("\n")) != -1) {
                String line = line_buffer.substr(0, newline_pos);
                line_buffer = line_buffer.substr(newline_pos + 1);

                {
                    std::lock_guard<std::mutex> lock(_output_mutex);
                    _output_queue.push(line);
                }

                call_deferred("emit_signal", "output_ready");
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
    ssize_t written = write(_stdin_fd, utf8.ptr(), utf8.length());

    return written == utf8.length();
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
        _output_queue.pop();
    }
    return result;
}

void SubProcess::_stderr_read_loop()
{
    char buffer[4096];
    String line_buffer;

    while (_running) {
        ssize_t bytes_read = read(_stderr_fd, buffer, sizeof(buffer) - 1);

        if (bytes_read > 0) {
            buffer[bytes_read] = '\0';
            String chunk = String::utf8(buffer, bytes_read);

            line_buffer += chunk;

            int newline_pos;
            while ((newline_pos = line_buffer.find("\n")) != -1) {
                String line = line_buffer.substr(0, newline_pos);
                line_buffer = line_buffer.substr(newline_pos + 1);

                {
                    std::lock_guard<std::mutex> lock(_stderr_mutex);
                    _stderr_queue.push(line);
                }

                call_deferred("emit_signal", "stderr_ready");
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
    if (!line_buffer.is_empty()) {
        std::lock_guard<std::mutex> lock(_stderr_mutex);
        _stderr_queue.push(line_buffer);
        call_deferred("emit_signal", "stderr_ready");
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
    return line;
}

String SubProcess::read_all_stderr()
{
    std::lock_guard<std::mutex> lock(_stderr_mutex);
    String result;
    while (!_stderr_queue.empty()) {
        if (!result.is_empty())
            result += "\n";
        result += _stderr_queue.front();
        _stderr_queue.pop();
    }
    return result;
}
