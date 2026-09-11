#ifndef MINERVA_UTF8_LINE_BYTES_H
#define MINERVA_UTF8_LINE_BYTES_H
#include <string>

// Keep byte ownership until a full line can be decoded. The callback borrows
// the bytes during the call, avoiding a second copy of large protocol lines.
class Utf8LineBytes {
    std::string bytes;
    size_t scanned = 0;
public:
    void append(const char *data, size_t size) { bytes.append(data, size); }
    template<class Consumer> bool pop_line(Consumer consume, bool strip_cr = false) {
        const size_t end = bytes.find('\n', scanned);
        if (end == std::string::npos) { scanned = bytes.size(); return false; }
        size_t length = end;
        if (strip_cr && length > 0 && bytes[length - 1] == '\r') --length;
        consume(bytes.data(), length);
        bytes.erase(0, end + 1);
        scanned = 0;
        return true;
    }
    template<class Consumer> void take_tail(Consumer consume) {
        consume(bytes.data(), bytes.size());
        bytes.clear();
        scanned = 0;
    }
};
#endif
