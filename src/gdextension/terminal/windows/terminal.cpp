#include "terminal.h"
#include <regex>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <godot_cpp/classes/reg_ex.hpp>
#include <godot_cpp/classes/reg_ex_match.hpp>

using namespace godot;

void WindowsTerminal::_bind_methods()
{

    BIND_ENUM_CONSTANT(TEXT)
    BIND_ENUM_CONSTANT(CURSOR_MOVE)
    BIND_ENUM_CONSTANT(CLEAR_LINE)
    BIND_ENUM_CONSTANT(CURSOR_VISIBLE)
    BIND_ENUM_CONSTANT(ERASE_CHARS)
    BIND_ENUM_CONSTANT(CURSOR_RIGHT)

    ClassDB::bind_method(D_METHOD("start", "width", "height"), &WindowsTerminal::start, DEFVAL(100), DEFVAL(100));
    ClassDB::bind_method(D_METHOD("resize", "width", "height"), &WindowsTerminal::resize);
    ClassDB::bind_method(D_METHOD("stop"), &WindowsTerminal::stop);
    ClassDB::bind_method(D_METHOD("write_input", "input"), &WindowsTerminal::write_input);
    ClassDB::bind_method(D_METHOD("is_running"), &WindowsTerminal::is_running);

    ADD_SIGNAL(MethodInfo("output_received", PropertyInfo(Variant::STRING, "content"), PropertyInfo(Variant::INT, "type")));
    ADD_SIGNAL(MethodInfo("command_output_end_reached"));

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

bool WindowsTerminal::_process_sequence(const String &seq)
{
    // https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797

    UtilityFunctions::print("Processing sequence: ", seq.c_escape());
    // call_deferred("emit_signal", "output_received", seq, (int)OutputType::TEXT);

    for (const auto &[key, value] : ANSI_SEQUENCES)
    {
        if (seq == key)
        {
            call_deferred("emit_signal", value);
            return true;
        }
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

bool WindowsTerminal::_handle_erase_sequence(const String &seq)
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

bool WindowsTerminal::_handle_private_sequence(const String &seq)
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
bool WindowsTerminal::_handle_graphics_mode(const String &seq)
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

Color WindowsTerminal::_get_basic_color(int index) const
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

Color WindowsTerminal::_get_bright_color(int index) const
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

Color WindowsTerminal::_get_256_color(int index) const
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

bool WindowsTerminal::_handle_cursor_sequence(const String &seq)
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

void WindowsTerminal::_process_input(const String &input)
{
    UtilityFunctions::print("Got: ", input.c_escape());

    String text_buffer;

    for (int i = 0; i < input.length(); i++)
    {
        char32_t c = input[i];
        if (c == '\x1B')
        {
            if (!text_buffer.is_empty())
            {   
                _strip_delimiter(text_buffer, true);
                call_deferred("emit_signal", "output_received", text_buffer, (int)OutputType::TEXT);
                text_buffer = String();
            }
            _in_escape = true;
            continue;
        }

        if (_in_escape)
        {
            _escape_buffer += String::chr(c);
            UtilityFunctions::print(_escape_buffer.c_escape());
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
            _strip_delimiter(text_buffer);
        }
    }

    if (!text_buffer.is_empty())
    {
        call_deferred("emit_signal", "output_received", text_buffer, (int)OutputType::TEXT);
    }
}

void WindowsTerminal::_strip_delimiter(String &text, bool buffer_end)
{
    // UtilityFunctions::print("\nStripping: ", text.c_escape());
    // UtilityFunctions::print("Command running: ", _command_running);
    

    Array arr;
    arr.push_back(_last_command);
    arr.push_back(_delimiter);


    String delimiter_command = String(" & echo {1}").format(arr);

    Ref<RegEx> delimiter_output_regex = RegEx::create_from_string(String("(\r\n)?([[:blank:]])*{1}([[:blank:]])*(\r\n)?").format(arr));


    if (!_command_running) {
        if (text.contains(delimiter_command))
        {
            text = text.replace(delimiter_command, String("").rpad(delimiter_command.length()));
        }
        if (buffer_end) {
            if (text.contains(_delimiter))
            {
                text = text.replace(_delimiter, String("").rpad(_delimiter.length()));
            }
        }
        return;
    }

    if (text.contains(delimiter_command))
    {
        text = text.replace(delimiter_command, String("").rpad(delimiter_command.length()));
    }
    else if (!delimiter_output_regex->search(text).is_null())
    {
        text = delimiter_output_regex->sub(text, "");
        UtilityFunctions::print("Found command delimiter: ", text);
        call_deferred("emit_signal", "command_output_end_reached");
        _command_running = false;
        _last_command.resize(0);
    }

    if (buffer_end) {
        if (text.contains(delimiter_command))
        {
            text = text.replace(delimiter_command, String("").rpad(delimiter_command.length()));
        }
        if (text.contains(_delimiter))
        {
            text = text.replace(_delimiter, String("").rpad(_delimiter.length()));
        }
    }
}

WindowsTerminal::WindowsTerminal() : _width(100), _height(100)
{
    _input_write = nullptr;
    _output_read = nullptr;
    _console = nullptr;
    ZeroMemory(&_process_info, sizeof(PROCESS_INFORMATION));
}

WindowsTerminal::~WindowsTerminal()
{
    stop();
}

bool WindowsTerminal::start(int width, int height)
{
    if (_running)
        return false;

    _width = width;
    _height = height;

    // Create pipes
    SECURITY_ATTRIBUTES sa = {sizeof(SECURITY_ATTRIBUTES), NULL, TRUE};
    HANDLE input_read, output_write;

    if (!CreatePipe(&input_read, &_input_write, &sa, 0) ||
        !CreatePipe(&_output_read, &output_write, &sa, 0))
    {
        if (input_read)
            CloseHandle(input_read);
        if (_input_write)
            CloseHandle(_input_write);
        return false;
    }

    // Create pseudo console with specified size
    COORD size = {static_cast<SHORT>(_width), static_cast<SHORT>(_height)};
    HRESULT hr = CreatePseudoConsole(size, input_read, output_write, 0, &_console);

    if (FAILED(hr))
    {
        CloseHandle(input_read);
        CloseHandle(output_write);
        CloseHandle(_input_write);
        CloseHandle(_output_read);
        return false;
    }

    // Setup process attributes
    STARTUPINFOEXW si = {0};
    si.StartupInfo.cb = sizeof(STARTUPINFOEXW);

    size_t attrListSize;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attrListSize);
    si.lpAttributeList = (PPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attrListSize);

    if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attrListSize) ||
        !UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                   _console, sizeof(HPCON), NULL, NULL))
    {
        ClosePseudoConsole(_console);
        HeapFree(GetProcessHeap(), 0, si.lpAttributeList);
        CloseHandle(input_read);
        CloseHandle(output_write);
        CloseHandle(_input_write);
        CloseHandle(_output_read);
        return false;
    }

    // Create cmd process
    WCHAR cmd[] = L"cmd.exe";
    if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT,
                        NULL, NULL, &si.StartupInfo, &_process_info))
    {
        ClosePseudoConsole(_console);
        HeapFree(GetProcessHeap(), 0, si.lpAttributeList);
        CloseHandle(input_read);
        CloseHandle(output_write);
        CloseHandle(_input_write);
        CloseHandle(_output_read);
        return false;
    }

    // Close temporary handles
    CloseHandle(input_read);
    CloseHandle(output_write);
    HeapFree(GetProcessHeap(), 0, si.lpAttributeList);

    HANDLE hProcess = OpenProcess(PROCESS_ALL_ACCESS, FALSE, _process_info.dwProcessId);
    if (hProcess) {
        // Get console input handle
        HANDLE hConsole = CreateFileW(L"CONIN$", 
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, 
            NULL, 
            OPEN_EXISTING, 
            0, 
            NULL);

        if (hConsole != INVALID_HANDLE_VALUE) {
            // Enable processed input and line input
            SetConsoleMode(hConsole, 
                ENABLE_PROCESSED_INPUT | 
                ENABLE_LINE_INPUT | 
                ENABLE_ECHO_INPUT |
                ENABLE_VIRTUAL_TERMINAL_INPUT);
            CloseHandle(hConsole);
        }
        CloseHandle(hProcess);
    }

    // Start output thread
    _running = true;
    _output_thread = std::thread([this]()
                                 {
       char buffer[4096];
       DWORD bytes_read;
       while (_running) {
           if (!ReadFile(_output_read, buffer, sizeof(buffer), &bytes_read, NULL)) {
               if (GetLastError() == ERROR_BROKEN_PIPE) break;
               continue;
           }
           if (bytes_read > 0) {
               _process_input(String::utf8((const char*)buffer, bytes_read));
           }
       } });

    return true;
}

void WindowsTerminal::stop()
{
    if (!_running)
        return;

    _running = false;

    if (_console)
    {
        ClosePseudoConsole(_console);
        _console = nullptr;
    }

    if (_process_info.hProcess)
    {
        TerminateProcess(_process_info.hProcess, 0);
        CloseHandle(_process_info.hProcess);
        CloseHandle(_process_info.hThread);
        ZeroMemory(&_process_info, sizeof(PROCESS_INFORMATION));
    }

    if (_output_thread.joinable())
    {
        _output_thread.join();
    }

    if (_input_write)
    {
        CloseHandle(_input_write);
        _input_write = nullptr;
    }

    if (_output_read)
    {
        CloseHandle(_output_read);
        _output_read = nullptr;
    }
}

bool WindowsTerminal::resize(int width, int height)
{
    if (!_running || !_console)
        return false;

    COORD new_size = {static_cast<SHORT>(width), static_cast<SHORT>(height)};
    HRESULT hr = ResizePseudoConsole(_console, new_size);
    
    if (SUCCEEDED(hr)) {
        _width = width;
        _height = height;
        return true;
    }
    
    return false;
}

bool WindowsTerminal::write_input(const String &input)
{
    if (!_running || !_input_write || input.is_empty())
        return false;


    String command;

    UtilityFunctions::print("Input is: ", input.c_escape());

    if (input == String::chr(8))
    {
        UtilityFunctions::print("BACKSPACE");
        _last_command = _last_command.erase(_last_command.length()-1);
    }

    // if (input == "\x1B[A") {
        
    //     command = "";

    //     // if there's another history element older than the current one
    //     if (_command_history_idx+1 < _command_history.size()-1) {

    //         // to delete the current present command
    //         String backspaces;
    //         if (_command_history_idx < 0) {
    //             backspaces = String::chr(8).repeat(_last_command.length());
    //         } else {
    //             backspaces = String::chr(8).repeat(_command_history.at(_command_history_idx).length());
    //         }
            
    //         _command_history_idx += 1;
            
    //         command = backspaces + _command_history.at(_command_history_idx);
    //     }
        
    // }
    if (!_command_running) {
        
        if (false && input == "\r\n" && !_last_command.strip_edges().is_empty()) {
            Array arr;
            arr.push_back(_delimiter);

            command = String(" & echo {0}\r\n").format(arr);
            UtilityFunctions::print("Last history command: ", _last_command);

            _command_history.push_back(_last_command);
            _command_running = true;
            _command_history_idx = -1;
        }
        else {
            _last_command += input;
            command = input;
        }

    
    } else {
        command = input;
        // _last_command += input;
    }

    // command = input;

    UtilityFunctions::print("Command is: ", command);
    UtilityFunctions::print("Last command: ", _last_command);

    CharString data = command.utf8();
    DWORD written;
    
    return WriteFile(_input_write, data.ptr(), data.length(), &written, NULL);

    //

    // if (input == "\r\n") {
    //     Array arr;
    //     arr.push_back(_delimiter);
    //     arr.push_back(input);

    //     command = String("{0} & echo {1} ").format(arr);

    //     _last_command = input; // last user command without the delimiter echo
    //     _command_running = true;
    // }

    // if (!_command_running) {

    //     Array arr;
    //     arr.push_back(input);
    //     arr.push_back(_delimiter);

    //     command = String("{0} & echo {1} ").format(arr);

    //     _last_command = input; // last user command without the delimiter echo
    //     _command_running = true;
    // } else {
    //     command = input;
    // }

    // if (send) {
    //     command = command + String("\r\n");

    //     if (!_command_running) _command_running = true;
    // }

    // CharString data = command.utf8();
    // DWORD written;

    // return WriteFile(_input_write, data.ptr(), data.length(), &written, NULL);
}