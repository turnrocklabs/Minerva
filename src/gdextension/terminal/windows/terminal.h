#ifndef WINDOWS_TERMINAL_H
#define WINDOWS_TERMINAL_H

#include <common/terminal_interface.h>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <thread>
#include <atomic>
#include <vector>
#include <windows.h>
#include <minerva_vt.h>

namespace godot
{

    enum class OutputType
    {
        TEXT = 0,
        SEQUENCE = 1
    };

    class Terminal : public TerminalInterface
    {
        GDCLASS(Terminal, Node)

    private:
        struct TerminalCommand
        {
            enum Type
            {
                TEXT = 0,
                SEQUENCE = 1,
            };
            Type type;
            int param1 = 0;
            int param2 = 0;

            TerminalCommand(Type t, int p1 = 0, int p2 = 0) : type(t), param1(p1), param2(p2) {}
        };

        int _width;
        int _height;

        HANDLE _input_write;
        HANDLE _output_read;
        HPCON _console;
        PROCESS_INFORMATION _process_info;
        std::atomic<bool> _command_running{false};
        std::atomic<bool> _running{false};
        std::thread _output_thread;

        bool _in_escape = false;
        String _escape_buffer;

        // libghostty-vt terminal state (shared with the unix backend via the
        // minerva-vt shim). ConPTY supplies the PTY; ghostty-vt supplies the
        // cell grid / cursor / key encoding the renderer drives.
        MinervaTerminal _vt_terminal = nullptr;

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
        Terminal();
        ~Terminal();

        enum Type
        {
            TEXT = TerminalCommand::TEXT,
            SEQUENCE = TerminalCommand::SEQUENCE
        };

        bool start(int width = 100, int height = 100) override;
        bool resize(int width, int height) override;
        void stop() override;
        bool write_input(const String &input) override;
        void write_to_screen(const String &data);
        bool is_running() const override { return _running; }

        // Cell-grid access methods (powered by libghostty-vt)
        Dictionary get_cell(int col, int row) const;
        Dictionary get_cell_screen(int col, int row) const;
        Dictionary get_cursor() const;
        String get_plain_text() const;
        void scroll_viewport(int lines);
        Dictionary get_scroll_info() const;

        // Key encoding (powered by ghostty key encoder)
        PackedByteArray encode_key(int ghostty_key, int action, int mods, const String &utf8_text) const;
    };

}

VARIANT_ENUM_CAST(Terminal::Type)

#endif // WINDOWS_TERMINAL_H