#ifndef WINDOWS_TERMINAL_H
#define WINDOWS_TERMINAL_H

#include <godot_cpp/classes/node.hpp>
#include <thread>
#include <atomic>
#include <vector>
#include <windows.h>

namespace godot
{

    enum class OutputType
    {
        TEXT = 0,
        SEQUENCE = 1
    };

    class WindowsTerminal : public Node
    {
        GDCLASS(WindowsTerminal, Node)

    private:
        struct TerminalCommand
        {
            enum Type
            {
                TEXT = 0,
                CURSOR_MOVE = 1,
                CLEAR_LINE = 2,
                CURSOR_VISIBLE = 3,
                ERASE_CHARS = 4,
                CURSOR_RIGHT = 5,
            };
            Type type;
            int param1 = 0;
            int param2 = 0;

            TerminalCommand(Type t, int p1 = 0, int p2 = 0) : type(t), param1(p1), param2(p2) {}
        };

        int _width;
        int _height;

        // for determinig the command output end
        String _delimiter = "##__COMMAND_END__##";
        String _last_command = "";
        std::vector<String> _command_history;
        std::atomic<int> _command_history_idx = -1;

        HANDLE _input_write;
        HANDLE _output_read;
        HPCON _console;
        PROCESS_INFORMATION _process_info;
        std::atomic<bool> _command_running{false};
        std::atomic<bool> _running{false};
        std::thread _output_thread;

        bool _in_escape = false;
        String _escape_buffer;
        bool _process_sequence(const String &seq);
        bool _handle_erase_sequence(const String& seq);
        bool _handle_private_sequence(const String& seq);
        bool _handle_graphics_mode(const String &seq);
        Color _get_basic_color(int index) const;
        Color _get_bright_color(int index) const;
        Color _get_256_color(int index) const;
        bool _handle_cursor_sequence(const String& seq);
        void _process_input(const String &input);
        void _strip_delimiter(String &text, bool buffer_end = false);

        static constexpr std::array<std::pair<const char *, const char *>, 11> ANSI_SEQUENCES{{
            // https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797#erase-functions
            {"[J", "seq_erase_in_display"},
            {"[0J", "seq_erase_in_display"},
            {"[1J", "seq_erase_from_cursor_to_beginning_of_screen"},
            {"[2J", "seq_erase_entire_screen"},
            {"[3J", "seq_erase_saved_lines"},
            {"[K", "seq_erase_from_cursor_to_end_of_line"},
            {"[0K", "seq_erase_from_cursor_to_end_of_line"},
            {"[1K", "seq_erase_start_of_line_to_cursor"},
            {"[2K", "seq_erase_entire_line"},
        }};

    protected:
        static void _bind_methods();

    public:
        WindowsTerminal();
        ~WindowsTerminal();

        enum Type
        {
            TEXT = TerminalCommand::TEXT,
            CURSOR_MOVE = TerminalCommand::CURSOR_MOVE,
            CLEAR_LINE = TerminalCommand::CLEAR_LINE,
            CURSOR_VISIBLE = TerminalCommand::CURSOR_VISIBLE,
            ERASE_CHARS = TerminalCommand::ERASE_CHARS,
            CURSOR_RIGHT = TerminalCommand::CURSOR_RIGHT
        };

        bool start(int width = 100, int height = 100);
        bool resize(int width, int height);
        void stop();
        bool write_input(const String &input);
        bool is_running() const { return _running; }
    };

}

VARIANT_ENUM_CAST(WindowsTerminal::Type)

#endif // WINDOWS_TERMINAL_H