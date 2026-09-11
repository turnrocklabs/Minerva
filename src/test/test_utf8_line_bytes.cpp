#include "../gdextension/terminal/common/utf8_line_bytes.h"
#include <cassert>
#include <iostream>
#include <vector>

int main() {
    const std::string input = u8"界🙂é\n\r\nlast界";
    // Every split includes those inside the two-, three- and four-byte characters.
    for (size_t split = 0; split <= input.size(); ++split) {
        for (bool windows : {false, true}) {
            Utf8LineBytes buffer;
            std::vector<std::string> lines;
            auto take = [&](const char *data, size_t size) { lines.emplace_back(data, size); };
            buffer.append(input.data(), split);
            while (buffer.pop_line(take, windows)) {}
            buffer.append(input.data() + split, input.size() - split);
            while (buffer.pop_line(take, windows)) {}
            buffer.take_tail(take);
            assert((lines == std::vector<std::string>{u8"界🙂é", windows ? "" : "\r", u8"last界"}));
            buffer.append("next\n", 5);
            assert(buffer.pop_line(take, windows));
            assert(lines.back() == "next");
        }
    }
    Utf8LineBytes buffer;
    std::string large(1024 * 1024, 'x');
    buffer.append(large.data(), large.size());
    bool emitted = false;
    auto take = [&](const char *data, size_t size) { emitted = true; assert(std::string(data, size) == large); };
    assert(!buffer.pop_line(take) && !emitted);
    buffer.append("\n", 1);
    assert(buffer.pop_line(take) && emitted);
    std::cout << "PASS: UTF-8 read boundaries, Windows CRLF, tails and large lines\n";
}
