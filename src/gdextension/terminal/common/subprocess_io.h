#ifndef MINERVA_SUBPROCESS_IO_H
#define MINERVA_SUBPROCESS_IO_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <algorithm>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>

// One policy for both native pipe backends. stdout is a protocol; stderr is
// lossy diagnostics. Payload byte counts exclude LF and the Windows CR in
// CRLF; retain the same byte count alongside the decoded queued value.
namespace SubProcessIO {
constexpr size_t STDOUT_LINES = 256;
constexpr size_t STDOUT_BYTES = 40u * 1024u * 1024u;
constexpr size_t STDOUT_LINE_BYTES = 40u * 1024u * 1024u;
constexpr size_t STDIN_LINES = 32;
constexpr size_t STDIN_BYTES = 72u * 1024u * 1024u;
constexpr size_t STDERR_LINES = 64;
constexpr size_t STDERR_BYTES = 64u * 1024u;
constexpr size_t STDERR_LINE_BYTES = 8u * 1024u;
constexpr size_t HISTORY_LINES = 32;
constexpr size_t HISTORY_LINE_BYTES = 1024;
constexpr size_t HISTORY_BYTES = 8u * 1024u;
constexpr int READER_DRAIN_MS = 100;

struct QueuedLine { godot::String text; size_t bytes; };
struct Refusal { const char *cause = nullptr; size_t observed = 0, limit = 0; };

inline Refusal stdout_admission(size_t bytes, size_t queued_lines, size_t queued_bytes) {
    if (bytes > STDOUT_LINE_BYTES) return {"stdout_line_bytes", bytes, STDOUT_LINE_BYTES};
    if (queued_lines >= STDOUT_LINES) return {"stdout_queue_lines", queued_lines + 1, STDOUT_LINES};
    if (queued_bytes + bytes > STDOUT_BYTES) return {"stdout_queue_bytes", queued_bytes + bytes, STDOUT_BYTES};
    return {};
}
inline Refusal stdout_pending(size_t bytes, size_t queued_bytes) {
    if (bytes > STDOUT_LINE_BYTES) return {"stdout_line_bytes", bytes, STDOUT_LINE_BYTES};
    if (queued_bytes + bytes > STDOUT_BYTES) return {"stdout_queue_bytes", queued_bytes + bytes, STDOUT_BYTES};
    return {};
}
inline bool stderr_needs_eviction(size_t lines, size_t bytes, size_t incoming) {
    return lines > 0 && (lines >= STDERR_LINES || bytes + incoming > STDERR_BYTES);
}

// Repair malformed peer bytes without asking Godot's decoder to log them.
// A partial codepoint at a truncation/EOF boundary is discarded, never decoded.
inline size_t clean_utf8(std::string &text) {
    for (size_t i = 0; i < text.size();) {
        unsigned char c = text[i];
        size_t n = c < 0x80 ? 1 : (c >= 0xc2 && c <= 0xdf ? 2 :
                (c >= 0xe0 && c <= 0xef ? 3 : (c >= 0xf0 && c <= 0xf4 ? 4 : 0)));
        bool valid = n != 0;
        for (size_t j = 1; valid && j < n && i + j < text.size(); ++j) {
            unsigned char next = text[i + j];
            valid = next >= 0x80 && next <= 0xbf &&
                    (j != 1 || !((c == 0xe0 && next < 0xa0) || (c == 0xed && next > 0x9f) ||
                    (c == 0xf0 && next < 0x90) || (c == 0xf4 && next > 0x8f)));
        }
        if (valid && i + n > text.size()) {
            size_t removed = text.size() - i;
            text.resize(i);
            return removed;
        }
        if (!valid) { text[i] = '?'; n = 1; }
        i += n;
    }
    return 0;
}

// Retain a bounded prefix, then discard through the delimiter. A later pipe
// chunk can never replay the discarded suffix as a new diagnostic line.
class StderrLines {
    std::string prefix;
    bool truncated = false;
public:
    template<class Line, class Loss> void append(const char *data, size_t size, Line line, Loss loss) {
        while (size > 0) {
            const char *newline = static_cast<const char *>(std::memchr(data, '\n', size));
            size_t part = newline ? static_cast<size_t>(newline - data) : size;
            size_t keep = std::min(part, STDERR_LINE_BYTES - prefix.size());
            prefix.append(data, keep);
            if (part > keep) { loss(part - keep, !truncated); truncated = true; }
            data += part; size -= part;
            if (newline) { finish(line, loss); ++data; --size; }
        }
    }
    template<class Line, class Loss> void finish(Line line, Loss loss) {
        if (!truncated && !prefix.empty() && prefix.back() == '\r') prefix.pop_back();
        size_t removed = clean_utf8(prefix);
        if (removed) loss(removed, !truncated);
        line(prefix);
        prefix.clear(); truncated = false;
    }
    bool has_tail() const { return !prefix.empty() || truncated; }
};

// All snapshot fields, including first cause, exit facts and independent
// history, have one mutex. Queue draining cannot consume this evidence.
// Empty cause means no fatal condition observed. A process_exit cause carries
// actual exit_kind (exit/signal/unknown), exit_code and exit_signal separately:
// numeric exit 128+N never implies signal N. A later stop updates exit facts,
// stop_requested and terminated_by_host without replacing the original cause.
// observed/limit use lines for *_queue_lines, bytes for *_bytes/write errors;
// os_error is the native errno/GetLastError value (zero when not applicable).
// generation is scoped to a SubProcess instance and increments on each start.
// stderr_tail is absent unless the disclosure owner explicitly opts in;
// tail_omitted otherwise explains why only loss counts are disclosed.
// Terminal signals/snapshots are provisional: the stderr reader may be behind.
// The consumer must finalize_io(expected_generation, include_stderr) BEFORE
// publishing one terminal outcome. It uses existing stop/reap, then allows up
// to READER_DRAIN_MS for EOF before interrupting and joining existing readers.
// evidence_state becomes complete only if stderr actually reached EOF; cutoff
// means bounded evidence may omit remaining bytes (e.g. inherited open pipes).
class Diagnostics {
    std::mutex mutex;
    int64_t generation = 0;
    std::string cause, channel, exit_kind = "unknown";
    int64_t observed = 0, limit = 0, os_error = 0, exit_code = -1, exit_signal = 0;
    bool stop_requested = false, terminated_by_host = false;
    bool finalized = false, stderr_eof = false;
    uint64_t dropped_lines = 0, dropped_bytes = 0, truncated_lines = 0, truncated_bytes = 0;
    std::deque<std::string> history;
    size_t history_bytes = 0;
public:
    void reset(int64_t value) {
        std::lock_guard<std::mutex> lock(mutex);
        generation = value; cause.clear(); channel.clear(); exit_kind = "unknown";
        observed = limit = os_error = exit_signal = 0; exit_code = -1;
        stop_requested = terminated_by_host = false;
        finalized = stderr_eof = false;
        dropped_lines = dropped_bytes = truncated_lines = truncated_bytes = 0;
        history.clear(); history_bytes = 0;
    }
    bool fail(const char *reason, const char *stream, int64_t amount, int64_t bound, int64_t error) {
        std::lock_guard<std::mutex> lock(mutex);
        if (!cause.empty()) return false;
        cause = reason; channel = stream; observed = amount; limit = bound; os_error = error;
        return true;
    }
    void exited(const char *kind, int64_t code, int64_t signal) {
        std::lock_guard<std::mutex> lock(mutex);
        exit_kind = kind; exit_code = code; exit_signal = signal;
    }
    void stopping(bool terminated = false) {
        std::lock_guard<std::mutex> lock(mutex);
        stop_requested = true; terminated_by_host = terminated_by_host || terminated;
    }
    void stderr_finished(bool eof) {
        std::lock_guard<std::mutex> lock(mutex);
        stderr_eof = eof;
    }
    void finish() {
        std::lock_guard<std::mutex> lock(mutex);
        finalized = true;
    }
    void drop(size_t bytes) {
        std::lock_guard<std::mutex> lock(mutex);
        ++dropped_lines; dropped_bytes += bytes;
    }
    void truncate(size_t bytes, bool first) {
        std::lock_guard<std::mutex> lock(mutex);
        truncated_lines += first; truncated_bytes += bytes;
    }
    void remember(const std::string &line) {
        std::lock_guard<std::mutex> lock(mutex);
        std::string retained = line.substr(0, HISTORY_LINE_BYTES);
        clean_utf8(retained);
        while (!history.empty() && (history.size() >= HISTORY_LINES ||
                history_bytes + retained.size() > HISTORY_BYTES)) {
            history_bytes -= history.front().size(); history.pop_front();
        }
        history_bytes += retained.size(); history.push_back(std::move(retained));
    }
    godot::Dictionary snapshot(bool include_stderr) {
        std::lock_guard<std::mutex> lock(mutex);
        godot::Dictionary result;
        result["generation"] = generation;
        result["cause"] = godot::String::utf8(cause.c_str());
        result["channel"] = godot::String::utf8(channel.c_str());
        result["observed"] = observed; result["limit"] = limit; result["os_error"] = os_error;
        result["exit_kind"] = godot::String::utf8(exit_kind.c_str());
        result["exit_code"] = exit_code; result["exit_signal"] = exit_signal;
        result["stop_requested"] = stop_requested; result["terminated_by_host"] = terminated_by_host;
        result["stderr_eof"] = stderr_eof;
        result["evidence_state"] = finalized ? (stderr_eof ? "complete" : "cutoff") : "provisional";
        result["stderr_dropped_lines"] = static_cast<int64_t>(dropped_lines);
        result["stderr_dropped_bytes"] = static_cast<int64_t>(dropped_bytes);
        result["stderr_truncated_lines"] = static_cast<int64_t>(truncated_lines);
        result["stderr_truncated_bytes"] = static_cast<int64_t>(truncated_bytes);
        if (include_stderr) {
            godot::PackedStringArray tail;
            for (const std::string &line : history) tail.push_back(godot::String::utf8(line.data(), line.size()));
            result["stderr_tail"] = tail;
        } else result["tail_omitted"] = "stderr_logging_disabled";
        return result;
    }
};
}
#endif
