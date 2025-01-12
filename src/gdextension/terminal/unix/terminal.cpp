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

void Terminal::_bind_methods()
{
    // Binding methods and signals
    BIND_ENUM_CONSTANT(TEXT);
    BIND_ENUM_CONSTANT(SEQUENCE);

    ClassDB::bind_method(D_METHOD("start", "width", "height"), &Terminal::start, DEFVAL(100), DEFVAL(100));
    ClassDB::bind_method(D_METHOD("resize", "width", "height"), &Terminal::resize);
    ClassDB::bind_method(D_METHOD("stop"), &Terminal::stop);
    ClassDB::bind_method(D_METHOD("write_input", "input"), &Terminal::write_input);
    ClassDB::bind_method(D_METHOD("is_running"), &Terminal::is_running);

    ADD_SIGNAL(MethodInfo("output_received", PropertyInfo(Variant::STRING, "content"), PropertyInfo(Variant::INT, "type")));
    ADD_SIGNAL(MethodInfo("on_shell_prompt_start"));
    ADD_SIGNAL(MethodInfo("on_shell_prompt_end"));

    ADD_SIGNAL(MethodInfo("seq_erase_in_display"));
    ADD_SIGNAL(MethodInfo("seq_erase_from_cursor_to_beginning_of_screen"));
    ADD_SIGNAL(MethodInfo("seq_erase_entire_screen"));
    ADD_SIGNAL(MethodInfo("seq_erase_saved_lines"));
    ADD_SIGNAL(MethodInfo("seq_erase_from_cursor_to_end_of_line"));
    ADD_SIGNAL(MethodInfo("seq_erase_start_of_line_to_cursor"));
    ADD_SIGNAL(MethodInfo("seq_erase_entire_line"));
    ADD_SIGNAL(MethodInfo("seq_erase_character", PropertyInfo(Variant::INT, "count")));

    // Graphics mode signals
    ADD_SIGNAL(MethodInfo("seq_reset_graphics"));
    ADD_SIGNAL(MethodInfo("seq_set_bold", PropertyInfo(Variant::BOOL, "enabled")));
    ADD_SIGNAL(MethodInfo("seq_set_dim", PropertyInfo(Variant::BOOL, "enabled")));
    ADD_SIGNAL(MethodInfo("seq_set_italic", PropertyInfo(Variant::BOOL, "enabled")));
    ADD_SIGNAL(MethodInfo("seq_set_underline", PropertyInfo(Variant::BOOL, "enabled")));
    ADD_SIGNAL(MethodInfo("seq_set_blink", PropertyInfo(Variant::BOOL, "enabled")));
    ADD_SIGNAL(MethodInfo("seq_set_inverse", PropertyInfo(Variant::BOOL, "enabled")));
    ADD_SIGNAL(MethodInfo("seq_set_hidden", PropertyInfo(Variant::BOOL, "enabled")));
    ADD_SIGNAL(MethodInfo("seq_set_strikethrough", PropertyInfo(Variant::BOOL, "enabled")));
    ADD_SIGNAL(MethodInfo("seq_set_foreground_color", PropertyInfo(Variant::COLOR, "color")));
    ADD_SIGNAL(MethodInfo("seq_set_background_color", PropertyInfo(Variant::COLOR, "color")));

    // Cursor movement signals
    ADD_SIGNAL(MethodInfo("seq_cursor_home"));
    ADD_SIGNAL(MethodInfo("seq_cursor_position", PropertyInfo(Variant::INT, "line"), PropertyInfo(Variant::INT, "column")));
    ADD_SIGNAL(MethodInfo("seq_cursor_up", PropertyInfo(Variant::INT, "lines")));
    ADD_SIGNAL(MethodInfo("seq_cursor_down", PropertyInfo(Variant::INT, "lines")));
    ADD_SIGNAL(MethodInfo("seq_cursor_right", PropertyInfo(Variant::INT, "columns")));
    ADD_SIGNAL(MethodInfo("seq_cursor_left", PropertyInfo(Variant::INT, "columns")));
    ADD_SIGNAL(MethodInfo("seq_cursor_next_line", PropertyInfo(Variant::INT, "lines")));
    ADD_SIGNAL(MethodInfo("seq_cursor_prev_line", PropertyInfo(Variant::INT, "lines")));
    ADD_SIGNAL(MethodInfo("seq_cursor_to_column", PropertyInfo(Variant::INT, "column")));
    ADD_SIGNAL(MethodInfo("seq_request_cursor_position"));
    ADD_SIGNAL(MethodInfo("seq_report_cursor_position", PropertyInfo(Variant::INT, "line"), PropertyInfo(Variant::INT, "column")));
    ADD_SIGNAL(MethodInfo("seq_cursor_up_scroll"));
    ADD_SIGNAL(MethodInfo("seq_save_cursor_position"));
    ADD_SIGNAL(MethodInfo("seq_restore_cursor_position"));

    // Private mode signals
    ADD_SIGNAL(MethodInfo("seq_set_cursor_visible", PropertyInfo(Variant::BOOL, "visible")));
    ADD_SIGNAL(MethodInfo("seq_restore_screen"));
    ADD_SIGNAL(MethodInfo("seq_save_screen"));
    ADD_SIGNAL(MethodInfo("seq_set_alternative_buffer", PropertyInfo(Variant::BOOL, "enabled")));

    // Character manipulation signals
    ADD_SIGNAL(MethodInfo("seq_erase_characters", PropertyInfo(Variant::INT, "count")));

    // OSC sequences
    ADD_SIGNAL(MethodInfo("title_changed", PropertyInfo(Variant::STRING, "title")));
}

bool Terminal::_process_sequence(const String &seq)
{
    // https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797

    // UtilityFunctions::print("Processing sequence: ", seq.c_escape());

    for (const auto &[key, value] : ANSI_SEQUENCES)
    {
        if (seq == key)
        {
            call_deferred("emit_signal", value);
            return true;
        }
    }

    if (seq == "[888z") {
        call_deferred("emit_signal", "on_shell_prompt_start");
        return true;
    } else if (seq == "[999z") {
        call_deferred("emit_signal", "on_shell_prompt_end");
        return true;
    }

    if (seq.begins_with("[?"))
    {
        return _handle_private_sequence(seq);
    }

    // TODO: Find out why ConPTY sends this sequence without the ?, as it should look like this: [?25l
    // for example, [?25h is sent as expected
    // Handle ConPTY's special case for cursor hide without private marker
    if (seq == "[25l")
    {
        call_deferred("emit_signal", "seq_set_cursor_visible", false);
        return true;
    }

    if (seq.begins_with("]"))
    {
        // OSC sequence
        if (seq.begins_with("]0;"))
        {
            int bel_pos = seq.find("\x07");
            if (bel_pos != -1)
            {
                String title = seq.substr(3, bel_pos - 3); // Remove ]0; and everything after BEL
                call_deferred("emit_signal", "title_changed", title);
                return true;
            }
        }
    }

    char32_t last_char = seq[seq.length() - 1];

    if (last_char == 'X')
    {
        String num_str = seq.substr(1, seq.length() - 2); // Remove [ and X
        int count = num_str.is_empty() ? 1 : num_str.to_int();
        call_deferred("emit_signal", "seq_erase_characters", count);
        return true;
    }

    if (last_char == 'P')
    {
        return _handle_erase_sequence(seq);
    }

    // Cursor movement sequences
    if (last_char == 'H' || last_char == 'f' ||   // Position
        last_char == 'A' || last_char == 'B' ||   // Up/Down
        last_char == 'C' || last_char == 'D' ||   // Left/Right
        last_char == 'E' || last_char == 'F' ||   // Next/Prev line
        last_char == 'G' ||                       // To column
        last_char == 'n' || last_char == 'R' ||   // Position request/report
        seq == "M" || seq == "7" || seq == "8" || // Special cursor commands
        seq == "[s" || seq == "[u")
    {
        return _handle_cursor_sequence(seq);
    }

    if (last_char == 'm')
    {
        return _handle_graphics_mode(seq);
    }

    return false;
}

bool Terminal::_handle_erase_sequence(const String &seq)
{

    char lastChar = seq[seq.length() - 1];
    String numStr = seq.substr(1, seq.length() - 2); // Remove [ and last char

    switch(lastChar)
    {
        case 'P':
            int count = numStr.is_empty() ? 1 : numStr.to_int();
            call_deferred("seq_erase_character", "seq_cursor_prev_line", count);
            return true;
    }


    return false;
}

bool Terminal::_handle_private_sequence(const String &seq)
{
    // Private sequences start with [ and have ? after it
    if (!seq.begins_with("[?"))
    {
        return false;
    }

    // Remove [? from start and get the rest
    String params = seq.substr(2);

    // Handle each type
    if (params == "25l")
    {
        call_deferred("emit_signal", "seq_set_cursor_visible", false);
        return true;
    }
    else if (params == "25h")
    {
        call_deferred("emit_signal", "seq_set_cursor_visible", true);
        return true;
    }
    else if (params == "47l")
    {
        call_deferred("emit_signal", "seq_restore_screen");
        return true;
    }
    else if (params == "47h")
    {
        call_deferred("emit_signal", "seq_save_screen");
        return true;
    }
    else if (params == "1049h")
    {
        call_deferred("emit_signal", "seq_set_alternative_buffer", true);
        return true;
    }
    else if (params == "1049l")
    {
        call_deferred("emit_signal", "seq_set_alternative_buffer", false);
        return true;
    }

    return false; // Unknown private sequence
}

// https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797#colors--graphics-mode
bool Terminal::_handle_graphics_mode(const String &seq)
{
    String params = seq.substr(1, seq.length() - 2);

    if (params.is_empty() || params == "0")
    {
        call_deferred("emit_signal", "seq_reset_graphics");
        return true;
    }

    PackedStringArray parts = params.split(";");
    Vector<int> codes;
    for (int i = 0; i < parts.size(); i++)
    {
        codes.push_back(parts[i].to_int());
    }

    for (int i = 0; i < codes.size(); i++)
    {
        int code = codes[i];
        switch (code)
        {
            case 0:
                call_deferred("emit_signal", "seq_reset_graphics");
                break;
            case 1:
                call_deferred("emit_signal", "seq_set_bold", true);
                break;
            case 22: // Reset both dim and bold
                call_deferred("emit_signal", "seq_set_bold", false);
                call_deferred("emit_signal", "seq_set_dim", false);
                break;
            case 2:
                call_deferred("emit_signal", "seq_set_dim", true);
                break;
            case 3:
                call_deferred("emit_signal", "seq_set_italic", true);
                break;
            case 23:
                call_deferred("emit_signal", "seq_set_italic", false);
                break;
            case 4:
                call_deferred("emit_signal", "seq_set_underline", true);
                break;
            case 24:
                call_deferred("emit_signal", "seq_set_underline", false);
                break;
            case 5:
                call_deferred("emit_signal", "seq_set_blink", true);
                break;
            case 25:
                call_deferred("emit_signal", "seq_set_blink", false);
                break;
            case 7:
                call_deferred("emit_signal", "seq_set_inverse", true);
                break;
            case 27:
                call_deferred("emit_signal", "seq_set_inverse", false);
                break;
            case 8:
                call_deferred("emit_signal", "seq_set_hidden", true);
                break;
            case 28:
                call_deferred("emit_signal", "seq_set_hidden", false);
                break;
            case 9:
                call_deferred("emit_signal", "seq_set_strikethrough", true);
                break;
            case 29:
                call_deferred("emit_signal", "seq_set_strikethrough", false);
                break;

            // Basic foreground colors
            case 30: case 31: case 32: case 33:
            case 34: case 35: case 36: case 37:
                call_deferred("emit_signal", "seq_set_foreground_color", _get_basic_color(code - 30));
                break;

            // Basic background colors
            case 40: case 41: case 42: case 43:
            case 44: case 45: case 46: case 47:
                call_deferred("emit_signal", "seq_set_background_color", _get_basic_color(code - 40));
                break;

            // Default colors
            case 39:
                call_deferred("emit_signal", "seq_set_foreground_color", Color(1, 1, 1)); // Default white
                break;
            case 49:
                call_deferred("emit_signal", "seq_set_background_color", Color(0, 0, 0)); // Default black
                break;

            // Bright foreground colors
            case 90: case 91: case 92: case 93:
            case 94: case 95: case 96: case 97:
                call_deferred("emit_signal", "seq_set_foreground_color", _get_bright_color(code - 90));
                break;

            // Bright background colors
            case 100: case 101: case 102: case 103:
            case 104: case 105: case 106: case 107:
                call_deferred("emit_signal", "seq_set_background_color", _get_bright_color(code - 100));
                break;

            // 256 color support
            case 38: case 48:
                if (i + 2 < codes.size() && codes[i + 1] == 5) {
                    Color color = _get_256_color(codes[i + 2]);
                    if (code == 38) {
                        call_deferred("emit_signal", "seq_set_foreground_color", color);
                    } else {
                        call_deferred("emit_signal", "seq_set_background_color", color);
                    }
                    i += 2; // Skip the next two parameters
                }
                break;
        }
    }

    return true;
}

Color Terminal::_get_basic_color(int index) const
{
    switch(index) {
        case 0: return Color(0, 0, 0);        // Black
        case 1: return Color(0.8, 0, 0);      // Red
        case 2: return Color(0, 0.8, 0);      // Green
        case 3: return Color(0.8, 0.8, 0);    // Yellow
        case 4: return Color(0, 0, 0.8);      // Blue
        case 5: return Color(0.8, 0, 0.8);    // Magenta
        case 6: return Color(0, 0.8, 0.8);    // Cyan
        case 7: return Color(0.8, 0.8, 0.8);  // White
        default: return Color(1, 1, 1);       // Default
    }
}

Color Terminal::_get_bright_color(int index) const
{
    switch(index) {
        case 0: return Color(0.5, 0.5, 0.5);  // Bright Black (Gray)
        case 1: return Color(1, 0, 0);        // Bright Red
        case 2: return Color(0, 1, 0);        // Bright Green
        case 3: return Color(1, 1, 0);        // Bright Yellow
        case 4: return Color(0, 0, 1);        // Bright Blue
        case 5: return Color(1, 0, 1);        // Bright Magenta
        case 6: return Color(0, 1, 1);        // Bright Cyan
        case 7: return Color(1, 1, 1);        // Bright White
        default: return Color(1, 1, 1);       // Default
    }
}

Color Terminal::_get_256_color(int index) const
{
    if (index < 16) {
        // First 16 colors are the basic + bright colors
        return index < 8 ? _get_basic_color(index) : _get_bright_color(index - 8);
    }
    else if (index < 232) {
        // 216 color cube (6x6x6)
        index -= 16;
        float r = (index / 36) * 51 / 255.0;
        float g = ((index % 36) / 6) * 51 / 255.0;
        float b = (index % 6) * 51 / 255.0;
        return Color(r, g, b);
    }
    else {
        // Grayscale (24 shades)
        float v = (index - 232) * 10 / 255.0;
        return Color(v, v, v);
    }
}

bool Terminal::_handle_cursor_sequence(const String &seq)
{
    // Handle sequences ending in specific letters
    char lastChar = seq[seq.length() - 1];
    String numStr = seq.substr(1, seq.length() - 2); // Remove [ and last char

    switch (lastChar)
    {
    case 'H':
    case 'f':
    {
        if (numStr.is_empty())
        {
            call_deferred("emit_signal", "seq_cursor_home");
        }
        else
        {
            PackedStringArray parts = numStr.split(";");
            if (parts.size() == 2)
            {
                int line = parts[0].to_int();
                int column = parts[1].to_int();
                call_deferred("emit_signal", "seq_cursor_position", line, column);
            }
        }
        return true;
    }
    case 'A':
    {
        int lines = numStr.is_empty() ? 1 : numStr.to_int();
        call_deferred("emit_signal", "seq_cursor_up", lines);
        return true;
    }
    case 'B':
    {
        int lines = numStr.is_empty() ? 1 : numStr.to_int();
        call_deferred("emit_signal", "seq_cursor_down", lines);
        return true;
    }
    case 'C':
    {
        int cols = numStr.is_empty() ? 1 : numStr.to_int();
        call_deferred("emit_signal", "seq_cursor_right", cols);
        return true;
    }
    case 'D':
    {
        int cols = numStr.is_empty() ? 1 : numStr.to_int();
        call_deferred("emit_signal", "seq_cursor_left", cols);
        return true;
    }
    case 'E':
    {
        int lines = numStr.is_empty() ? 1 : numStr.to_int();
        call_deferred("emit_signal", "seq_cursor_next_line", lines);
        return true;
    }
    case 'F':
    {
        int lines = numStr.is_empty() ? 1 : numStr.to_int();
        call_deferred("emit_signal", "seq_cursor_prev_line", lines);
        return true;
    }
    case 'G':
    {
        int column = numStr.is_empty() ? 1 : numStr.to_int();
        call_deferred("emit_signal", "seq_cursor_to_column", column);
        return true;
    }
    case 'n':
    {
        if (numStr == "6")
        {
            call_deferred("emit_signal", "seq_request_cursor_position");
        }
        return true;
    }
    case 'R':
    {
        PackedStringArray parts = numStr.split(";");
        if (parts.size() == 2)
        {
            int line = parts[0].to_int();
            int column = parts[1].to_int();
            call_deferred("emit_signal", "seq_report_cursor_position", line, column);
        }
        return true;
    }
    }

    // Handle special sequences
    if (seq == "M")
    {
        call_deferred("emit_signal", "seq_cursor_up_scroll");
        return true;
    }
    else if (seq == "7" || seq == "[s")
    {
        call_deferred("emit_signal", "seq_save_cursor_position");
        return true;
    }
    else if (seq == "8" || seq == "[u")
    {
        call_deferred("emit_signal", "seq_restore_cursor_position");
        return true;
    }

    return false;
}

void Terminal::_process_input(const String &input)
{
    String text_buffer;

    for (int i = 0; i < input.length(); i++)
    {
        char32_t c = input[i];
        if (c == '\x1B')
        {
            if (!text_buffer.is_empty())
            {
                call_deferred("emit_signal", "output_received", text_buffer, (int)OutputType::TEXT);
                text_buffer = String();
            }
            _in_escape = true;
            continue;
        }

        if (_in_escape)
        {
            _escape_buffer += String::chr(c);
            if ((_escape_buffer.begins_with("]") && c == 0x07) ||                         // Title sequence
                (!_escape_buffer.begins_with("]") && c >= 0x40 && c <= 0x7E && c != '[')) // Normal sequences
            {
                _process_sequence(_escape_buffer);
                _escape_buffer = String();
                _in_escape = false;
            }
        }
        else
        {
            text_buffer += String::chr(c);
        }
    }

    if (!text_buffer.is_empty())
    {
        call_deferred("emit_signal", "output_received", text_buffer, (int)OutputType::TEXT);
    }
}


Terminal::Terminal() : _width(100), _height(100)
{
    _master_fd = -1;
    _slave_fd = -1;
    _child_pid = -1;
}

Terminal::~Terminal()
{
    stop();
}

bool Terminal::start(int width, int height)
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
        putenv((char*)"TERM=xterm-256color");
        putenv((char*)"PS1=\\033[888z\\033[01;32m:\\u@\\h\\033[00m:\\033[01;34m\\w\\033[00m\\$ \\033[999z");
        putenv((char*)"BASH_ENV=");
        putenv((char*)"ENV=");

        const char* shell = getenv("SHELL");
        if (!shell) shell = "/bin/bash";
        
        execlp(shell, shell, "--norc", "--noprofile", nullptr);
        _exit(1);
    }

    // Parent process
    struct termios term_settings;
    tcgetattr(_master_fd, &term_settings);
    
    // Save original settings
    _old_term = term_settings;
    
    // Modified settings for raw mode
    term_settings.c_lflag &= ~(ICANON | ISIG | IEXTEN);
    term_settings.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    term_settings.c_cflag &= ~(CSIZE | PARENB);
    term_settings.c_cflag |= CS8 | ECHO;
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

void Terminal::stop()
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

bool Terminal::resize(int width, int height)
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

bool Terminal::write_input(const String &input)
{
    if (!_running || _master_fd < 0 || input.is_empty())
        return false;

    CharString data = input.utf8();
    ssize_t written = write(_master_fd, data.ptr(), data.length());
    
    return written == data.length();
}