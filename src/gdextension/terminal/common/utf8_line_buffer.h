#ifndef MINERVA_UTF8_LINE_BUFFER_H
#define MINERVA_UTF8_LINE_BUFFER_H

#include <godot_cpp/variant/string.hpp>
#include <string>

// Pipe reads may end inside a UTF-8 codepoint. Decode only complete lines.
class Utf8LineBuffer {
    std::string bytes;
    size_t scanned = 0;

public:
    void append(const char *data, size_t size) { bytes.append(data, size); }

    bool pop_line(godot::String &line, bool strip_cr = false) {
        const size_t end = bytes.find('\n', scanned);
        if (end == std::string::npos) {
            scanned = bytes.size();
            return false;
        }
        size_t length = end;
        if (strip_cr && length > 0 && bytes[length - 1] == '\r')
            --length;
        line = godot::String::utf8(bytes.data(), length);
        bytes.erase(0, end + 1);
        scanned = 0;
        return true;
    }

    godot::String take_tail() {
        godot::String tail = godot::String::utf8(bytes.data(), bytes.size());
        bytes.clear();
        scanned = 0;
        return tail;
    }
};

#endif
