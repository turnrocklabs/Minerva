#ifndef MINERVA_UTF8_LINE_BUFFER_H
#define MINERVA_UTF8_LINE_BUFFER_H
#include <godot_cpp/variant/string.hpp>
#include "utf8_line_bytes.h"

// Decode only complete lines; pipe reads can split a UTF-8 codepoint. Native
// subprocess readers admit popped payloads before bounding the pending tail:
// a delimiter needs bounded scratch room beyond an inclusive payload limit.
// The byte-buffer scan cursor examines only new bytes of an unfinished frame.
class Utf8LineBuffer {
    Utf8LineBytes bytes;
public:
    void append(const char *data, size_t size) { bytes.append(data, size); }
    size_t size() const { return bytes.size(); }
    size_t pending_payload_size(bool strip_cr) const { return bytes.pending_payload_size(strip_cr); }
    void clear() { bytes.clear(); }
    bool pop_line(godot::String &line, bool strip_cr = false, size_t *payload_bytes = nullptr) {
        return bytes.pop_line([&](const char *data, size_t size) {
            if (payload_bytes) *payload_bytes = size;
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
