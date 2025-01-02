#include "terminal.h"
#include <regex>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/reg_ex.hpp>
#include <godot_cpp/classes/reg_ex_match.hpp>

#include <fcntl.h>
#include <unistd.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <pty.h>
#include <signal.h>
#include <errno.h>

using namespace godot;

void LinuxTerminal::_bind_methods()
{
    // Binding methods and signals - this part remains mostly the same
    BIND_ENUM_CONSTANT(TEXT);
    BIND_ENUM_CONSTANT(SEQUENCE);

    ClassDB::bind_method(D_METHOD("start", "width", "height"), &LinuxTerminal::start, DEFVAL(100), DEFVAL(100));
    ClassDB::bind_method(D_METHOD("resize", "width", "height"), &LinuxTerminal::resize);
    ClassDB::bind_method(D_METHOD("stop"), &LinuxTerminal::stop);
    ClassDB::bind_method(D_METHOD("write_input", "input"), &LinuxTerminal::write_input);
    ClassDB::bind_method(D_METHOD("is_running"), &LinuxTerminal::is_running);

    // All the signal bindings remain exactly the same as in WindowsTerminal
    ADD_SIGNAL(MethodInfo("output_received", PropertyInfo(Variant::STRING, "content"), PropertyInfo(Variant::INT, "type")));
    // ... [rest of the signals remain the same]
}

// The sequence processing methods remain exactly the same as they handle ANSI sequences
bool LinuxTerminal::_process_sequence(const String &seq)
{
    // Keep the same implementation as WindowsTerminal
    // This code processes ANSI sequences which are platform-independent
    // ... [same implementation as WindowsTerminal]
}

LinuxTerminal::LinuxTerminal() : _width(100), _height(100)
{
    _master_fd = -1;
    _slave_fd = -1;
    _child_pid = -1;
}

LinuxTerminal::~LinuxTerminal()
{
    stop();
}

bool LinuxTerminal::start(int width, int height)
{
    if (_running)
        return false;

    _width = width;
    _height = height;

    // Create PTY
    struct winsize ws = {
        .ws_row = (unsigned short)height,
        .ws_col = (unsigned short)width,
        .ws_xpixel = 0,
        .ws_ypixel = 0
    };

    // Open pseudoterminal
    _child_pid = forkpty(&_master_fd, nullptr, nullptr, &ws);
    
    if (_child_pid == -1) {
        // Fork failed
        return false;
    }
    
    if (_child_pid == 0) {
        // Child process
        // Set up environment
        putenv((char*)"TERM=xterm-256color");
        
        // Execute shell
        const char* shell = getenv("SHELL");
        if (!shell) shell = "/bin/bash";
        
        execlp(shell, shell, nullptr);
        _exit(1); // In case exec fails
    }

    // Parent process
    // Set up master PTY
    struct termios term_settings;
    tcgetattr(_master_fd, &term_settings);
    
    // Save original settings
    _old_term = term_settings;
    
    // Modified settings for raw mode
    term_settings.c_lflag &= ~(ICANON | ECHO | ISIG | IEXTEN);
    term_settings.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    term_settings.c_cflag &= ~(CSIZE | PARENB);
    term_settings.c_cflag |= CS8;
    term_settings.c_oflag &= ~(OPOST);
    
    // Set minimal character and timing
    term_settings.c_cc[VMIN] = 1;
    term_settings.c_cc[VTIME] = 0;
    
    tcsetattr(_master_fd, TCSANOW, &term_settings);

    // Set non-blocking mode for master
    int flags = fcntl(_master_fd, F_GETFL);
    fcntl(_master_fd, F_SETFL, flags | O_NONBLOCK);

    // Start output thread
    _running = true;
    _output_thread = std::thread([this]() {
        char buffer[4096];
        while (_running) {
            ssize_t bytes_read = read(_master_fd, buffer, sizeof(buffer));
            if (bytes_read > 0) {
                _process_input(String::utf8((const char*)buffer, bytes_read));
            } else if (bytes_read == -1) {
                if (errno != EAGAIN && errno != EWOULDBLOCK) {
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            } else {
                break;
            }
        }
    });

    return true;
}

void LinuxTerminal::stop()
{
    if (!_running)
        return;

    _running = false;

    if (_child_pid > 0) {
        kill(_child_pid, SIGTERM);
        _child_pid = -1;
    }

    if (_output_thread.joinable()) {
        _output_thread.join();
    }

    if (_master_fd >= 0) {
        // Restore original terminal settings
        tcsetattr(_master_fd, TCSANOW, &_old_term);
        close(_master_fd);
        _master_fd = -1;
    }

    if (_slave_fd >= 0) {
        close(_slave_fd);
        _slave_fd = -1;
    }
}

bool LinuxTerminal::resize(int width, int height)
{
    if (!_running || _master_fd < 0)
        return false;

    struct winsize ws = {
        .ws_row = (unsigned short)height,
        .ws_col = (unsigned short)width,
        .ws_xpixel = 0,
        .ws_ypixel = 0
    };

    if (ioctl(_master_fd, TIOCSWINSZ, &ws) == -1) {
        return false;
    }

    _width = width;
    _height = height;
    return true;
}

bool LinuxTerminal::write_input(const String &input)
{
    if (!_running || _master_fd < 0 || input.is_empty())
        return false;

    CharString data = input.utf8();
    ssize_t written = write(_master_fd, data.ptr(), data.length());
    
    return written == data.length();
}