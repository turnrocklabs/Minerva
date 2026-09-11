#ifndef MINERVA_UTF8_LINE_BUFFER_H
#define MINERVA_UTF8_LINE_BUFFER_H
#include <godot_cpp/variant/string.hpp>
#include "utf8_line_bytes.h"

// Decode only complete lines; pipe reads can split a UTF-8 codepoint.
class Utf8LineBuffer {
    Utf8LineBytes bytes;
public:
    void append(const char *data, size_t size) { bytes.append(data, size); }
    bool pop_line(godot::String &line, bool strip_cr = false) {
        return bytes.pop_line([&](const char *data, size_t size) {
            line = godot::String::utf8(data, size);
        }, strip_cr);
    }
    godot::String take_tail() {
        godot::String tail;
        bytes.take_tail([&](const char *data, size_t size) {
            tail = godot::String::utf8(data, size);
        });
        return tail;
    }
};
#endif
