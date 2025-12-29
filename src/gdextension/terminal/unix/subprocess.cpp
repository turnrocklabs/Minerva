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

    ADD_SIGNAL(MethodInfo("output_ready"));
    ADD_SIGNAL(MethodInfo("process_exited", PropertyInfo(Variant::INT, "exit_code")));
}

SubProcess::SubProcess()
{
    _stdin_fd = -1;
    _stdout_fd = -1;
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

    // Create pipes for stdin and stdout
    int stdin_pipe[2];   // [0] = read end, [1] = write end
    int stdout_pipe[2];

    if (pipe(stdin_pipe) == -1 || pipe(stdout_pipe) == -1) {
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
        UtilityFunctions::push_error("SubProcess: Fork failed");
        return false;
    }

    if (_child_pid == 0) {
        // Child process

        // Redirect stdin
        close(stdin_pipe[1]);  // Close write end
        dup2(stdin_pipe[0], STDIN_FILENO);
        close(stdin_pipe[0]);

        // Redirect stdout (and stderr to stdout)
        close(stdout_pipe[0]);  // Close read end
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stdout_pipe[1], STDERR_FILENO);
        close(stdout_pipe[1]);

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

    _stdin_fd = stdin_pipe[1];
    _stdout_fd = stdout_pipe[0];

    // Set stdout to non-blocking
    int flags = fcntl(_stdout_fd, F_GETFL);
    fcntl(_stdout_fd, F_SETFL, flags | O_NONBLOCK);

    _running = true;

    // Start read thread
    _read_thread = std::thread([this]() {
        _read_loop();
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

    // Wait for read thread
    if (_read_thread.joinable()) {
        _read_thread.join();
    }

    // Close stdout
    if (_stdout_fd >= 0) {
        close(_stdout_fd);
        _stdout_fd = -1;
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
