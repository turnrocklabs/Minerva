#include "subprocess.h"
#include <chrono>
#include "common/utf8_line_buffer.h"
#include "common/env_overrides.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <string>
#include <vector>

using namespace godot;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Convert a Godot String (UTF-8) to a wide string for the Win32 *W APIs.
static std::wstring to_wide(const String &s)
{
    CharString u8 = s.utf8();
    int len = static_cast<int>(u8.length());
    if (len <= 0)
        return std::wstring();
    int wlen = MultiByteToWideChar(CP_UTF8, 0, u8.get_data(), len, nullptr, 0);
    if (wlen <= 0)
        return std::wstring();
    std::wstring w(static_cast<size_t>(wlen), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, u8.get_data(), len, &w[0], wlen);
    return w;
}

// Quote a single argument per the Windows CommandLineToArgvW rules so that
// CreateProcessW reconstructs the exact argv the caller intended (paths with
// spaces, embedded quotes, trailing backslashes).
static std::wstring quote_arg(const std::wstring &arg)
{
    if (!arg.empty() && arg.find_first_of(L" \t\n\v\"") == std::wstring::npos)
        return arg; // no quoting needed

    std::wstring out;
    out.push_back(L'"');
    for (auto it = arg.begin();; ++it) {
        unsigned backslashes = 0;
        while (it != arg.end() && *it == L'\\') {
            ++it;
            ++backslashes;
        }
        if (it == arg.end()) {
            // Escape all backslashes, but let the terminating quote be a
            // literal quote (so double them).
            out.append(backslashes * 2, L'\\');
            break;
        } else if (*it == L'"') {
            // Escape backslashes and the following quote.
            out.append(backslashes * 2 + 1, L'\\');
            out.push_back(*it);
        } else {
            // Backslashes are not special here.
            out.append(backslashes, L'\\');
            out.push_back(*it);
        }
    }
    out.push_back(L'"');
    return out;
}

// The inherited environment with `overrides` (UTF-8 name/value pairs)
// replacing entries of the same name, compared without case as Windows
// names are, or added: a Unicode block, each entry NUL-terminated and the
// whole ending in an extra NUL. Entries starting with '=' (the per-drive
// current directories) are kept as they are; the inherited order is kept
// and new entries come last (CreateProcess does not need the block sorted).
// False, building nothing, when two overrides name the same variable or the
// inherited environment cannot be read.
static bool build_environment_block(const std::vector<std::pair<std::string, std::string>> &overrides,
        std::wstring &block)
{
    std::vector<std::pair<std::wstring, std::wstring>> wide;
    for (const auto &entry : overrides) {
        std::wstring name = to_wide(String::utf8(entry.first.c_str()));
        for (const auto &earlier : wide)
            if (CompareStringOrdinal(earlier.first.c_str(), -1, name.c_str(), -1, TRUE) == CSTR_EQUAL)
                return false;
        wide.emplace_back(name, to_wide(String::utf8(entry.second.c_str())));
    }
    std::vector<bool> placed(wide.size(), false);
    block.clear();
    LPWCH inherited = GetEnvironmentStringsW();
    if (inherited == nullptr)
        return false;
    for (LPWCH entry = inherited; *entry != L'\0'; entry += wcslen(entry) + 1) {
        std::wstring text(entry);
        const size_t equals = text.find(L'=', 1);  // past a leading '=' of a drive entry
        const std::wstring name = text.substr(0, equals);
        bool replaced = false;
        if (text[0] != L'=') {
            // Every inherited entry of the name goes; the override is written
            // once, where the first one was.
            for (size_t i = 0; i < wide.size(); ++i) {
                if (CompareStringOrdinal(wide[i].first.c_str(), -1, name.c_str(), -1, TRUE) == CSTR_EQUAL) {
                    if (!placed[i]) {
                        block += wide[i].first + L"=" + wide[i].second;
                        block.push_back(L'\0');
                        placed[i] = true;
                    }
                    replaced = true;
                    break;
                }
            }
        }
        if (!replaced) {
            block += text;
            block.push_back(L'\0');
        }
    }
    FreeEnvironmentStringsW(inherited);
    for (size_t i = 0; i < wide.size(); ++i) {
        if (!placed[i]) {
            block += wide[i].first + L"=" + wide[i].second;
            block.push_back(L'\0');
        }
    }
    block.push_back(L'\0');
    return true;
}

static void close_handle(HANDLE &h)
{
    if (h != nullptr && h != INVALID_HANDLE_VALUE) {
        CloseHandle(h);
        h = nullptr;
    }
}

// ---------------------------------------------------------------------------
// Bindings / lifecycle
// ---------------------------------------------------------------------------

void SubProcess::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("start", "command", "args"), &SubProcess::start, DEFVAL(PackedStringArray()));
    ClassDB::bind_method(D_METHOD("start_with_env", "command", "args", "extra_env"), &SubProcess::start_with_env);
    ClassDB::bind_static_method("SubProcess", D_METHOD("os_account_name"), &SubProcess::os_account_name);
    ClassDB::bind_method(D_METHOD("stop"), &SubProcess::stop);
    ClassDB::bind_method(D_METHOD("stop_gracefully", "grace_ms", "process_name"), &SubProcess::stop_gracefully, DEFVAL(10000), DEFVAL(String()));
    ClassDB::bind_method(D_METHOD("write_data", "data"), &SubProcess::write_data);
    ClassDB::bind_method(D_METHOD("has_io_overflow"), &SubProcess::has_io_overflow);
    ClassDB::bind_method(D_METHOD("get_io_diagnostics", "include_stderr"), &SubProcess::get_io_diagnostics, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("finalize_io", "generation", "include_stderr"), &SubProcess::finalize_io, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("_emit_io_failure", "generation", "first", "legacy_overflow"), &SubProcess::_emit_io_failure);
    ClassDB::bind_method(D_METHOD("_emit_process_exited", "generation", "exit_code"), &SubProcess::_emit_process_exited);
    ClassDB::bind_method(D_METHOD("_emit_output_ready", "generation"), &SubProcess::_emit_output_ready);
    ClassDB::bind_method(D_METHOD("_emit_stderr_ready", "generation"), &SubProcess::_emit_stderr_ready);
    ClassDB::bind_method(D_METHOD("is_running"), &SubProcess::is_running);
    ClassDB::bind_method(D_METHOD("has_output"), &SubProcess::has_output);
    ClassDB::bind_method(D_METHOD("read_line"), &SubProcess::read_line);
    ClassDB::bind_method(D_METHOD("read_all"), &SubProcess::read_all);
    ClassDB::bind_method(D_METHOD("has_stderr"), &SubProcess::has_stderr);
    ClassDB::bind_method(D_METHOD("read_stderr_line"), &SubProcess::read_stderr_line);
    ClassDB::bind_method(D_METHOD("read_all_stderr"), &SubProcess::read_all_stderr);

    ADD_SIGNAL(MethodInfo("output_ready"));
    ADD_SIGNAL(MethodInfo("stderr_ready"));
    ADD_SIGNAL(MethodInfo("process_exited", PropertyInfo(Variant::INT, "exit_code")));
    ADD_SIGNAL(MethodInfo("io_overflow"));
    ADD_SIGNAL(MethodInfo("io_failed", PropertyInfo(Variant::INT, "generation")));
}

SubProcess::SubProcess()
{
    _stdin_wr = nullptr;
    _stdout_rd = nullptr;
    _stderr_rd = nullptr;
    _child_process = nullptr;
}

SubProcess::~SubProcess()
{
    stop();
}

// ---------------------------------------------------------------------------
// start / stop
// ---------------------------------------------------------------------------

bool SubProcess::start(const String &command, const PackedStringArray &args)
{
    return start_with_env(command, args, Dictionary());
}

String SubProcess::os_account_name()
{
    wchar_t name[257];  // UNLEN + 1
    DWORD length = 257;
    if (!GetUserNameW(name, &length) || length <= 1)
        return String();
    return String(std::wstring(name, length - 1).c_str());  // length counts the NUL
}

bool SubProcess::start_with_env(const String &command, const PackedStringArray &args, const Dictionary &extra_env)
{
    if (_running)
        return false;
    std::vector<std::pair<std::string, std::string>> overrides;
    std::wstring environment;
    if (!minerva_env_overrides(extra_env, overrides)) {
        UtilityFunctions::push_error("SubProcess: an environment override has an invalid name or value");
        return false;
    }
    if (!build_environment_block(overrides, environment)) {
        UtilityFunctions::push_error("SubProcess: two environment overrides name the same variable, or the inherited environment could not be read");
        return false;
    }

    SECURITY_ATTRIBUTES sa = {};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;       // pipe ends are inheritable by default...
    sa.lpSecurityDescriptor = nullptr;

    HANDLE stdin_rd = nullptr, stdin_wr = nullptr;
    HANDLE stdout_rd = nullptr, stdout_wr = nullptr;
    HANDLE stderr_rd = nullptr, stderr_wr = nullptr;

    if (!CreatePipe(&stdin_rd, &stdin_wr, &sa, 0) ||
        !CreatePipe(&stdout_rd, &stdout_wr, &sa, 0) ||
        !CreatePipe(&stderr_rd, &stderr_wr, &sa, 0)) {
        UtilityFunctions::push_error("SubProcess: Failed to create pipes");
        close_handle(stdin_rd);
        close_handle(stdin_wr);
        close_handle(stdout_rd);
        close_handle(stdout_wr);
        close_handle(stderr_rd);
        close_handle(stderr_wr);
        return false;
    }

    // ...but the PARENT-side ends must not leak into the child, or the child's
    // stdout/stderr never report EOF (a held write end keeps the pipe open).
    SetHandleInformation(stdin_wr, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(stdout_rd, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(stderr_rd, HANDLE_FLAG_INHERIT, 0);

    // Build the application path (backslash-normalized; CreateProcessW's
    // lpApplicationName is a real filesystem path) and a properly quoted command
    // line whose argv[0] matches.
    std::wstring app = to_wide(command);
    for (auto &c : app)
        if (c == L'/')
            c = L'\\';
    // A bare name ("python", "node") names no file, and lpApplicationName is
    // never searched for. For a bare name, lpApplicationName is left null so
    // CreateProcessW takes the quoted first token of the command line and
    // looks for it: the parent's directory, the current directory, the system
    // directories, then PATH, with ".exe" appended when it has no extension.
    // A path (a separator or drive colon) is launched exactly as given.
    const bool bare = app.find_first_of(L"\\:") == std::wstring::npos;

    std::wstring cmdline = quote_arg(app);
    for (int i = 0; i < args.size(); i++) {
        cmdline += L" ";
        cmdline += quote_arg(to_wide(args[i]));
    }

    STARTUPINFOW si = {};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = stdin_rd;
    si.hStdOutput = stdout_wr;
    si.hStdError = stderr_wr;

    PROCESS_INFORMATION pi = {};

    // lpCommandLine must be mutable.
    std::wstring cmdbuf = cmdline;
    BOOL ok = CreateProcessW(
        bare ? nullptr : app.c_str(),
        &cmdbuf[0],
        nullptr,            // process security
        nullptr,            // thread security
        TRUE,               // inherit handles (the child-side pipe ends)
        // No console window flashes for console subprocesses; the
        // environment block is UTF-16.
        CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
        &environment[0],    // the inherited environment with the overrides
        nullptr,            // inherit working directory
        &si,
        &pi);

    // The child has its own copies of the inherited ends now; close ours either
    // way (on failure these were never duplicated, so this is the cleanup path).
    close_handle(stdin_rd);
    close_handle(stdout_wr);
    close_handle(stderr_wr);

    if (!ok) {
        UtilityFunctions::push_error("SubProcess: CreateProcess failed for: " + command);
        close_handle(stdin_wr);
        close_handle(stdout_rd);
        close_handle(stderr_rd);
        return false;
    }

    // We don't need the primary thread handle.
    close_handle(pi.hThread);

    _stdin_wr = stdin_wr;
    _stdout_rd = stdout_rd;
    _stderr_rd = stderr_rd;
    _child_process = pi.hProcess;

    _diagnostics.reset(++_generation);
    _stdout_failed = false;
    _closing = false;
    _stdout_done = false;
    _stderr_done = false;
    _exit_code = -1;
    _exited = false;
    _running = true;
    _io_overflow = false;
	_output_notification_pending = false;
	_stderr_notification_pending = false;
	{
		std::lock_guard<std::mutex> lock(_write_mutex);
		while (!_write_queue.empty()) _write_queue.pop();
		_queued_write_bytes = 0;
		_stdin_admission_closed = false;
	}
	{
		std::lock_guard<std::mutex> lock(_output_mutex);
		while (!_output_queue.empty()) _output_queue.pop();
		_queued_output_bytes = 0;
	}
	{
		std::lock_guard<std::mutex> lock(_stderr_mutex);
		while (!_stderr_queue.empty()) _stderr_queue.pop();
		_queued_stderr_bytes = 0;
	}

    _read_thread = std::thread([this]() { _read_loop(); });
    _stderr_thread = std::thread([this]() { _stderr_read_loop(); });
    _write_thread = std::thread([this]() { _write_loop(); });

    return true;
}

int SubProcess::_poll_exit()
{
    std::lock_guard<std::mutex> lock(_exit_mutex);
    if (_exited) return _exit_code;
    if (_child_process != nullptr && WaitForSingleObject(_child_process, 0) == WAIT_OBJECT_0) {
        DWORD code = 0;
        BOOL known = GetExitCodeProcess(_child_process, &code);
        DWORD error = known ? 0 : GetLastError();
        if (known) {
            _exit_code = static_cast<int>(code);
            _diagnostics.exited("exit", code, 0);
        }
        if (!_closing) _record_failure("process_exit", "process", known ? static_cast<int64_t>(code) : -1, 0, error, false);
        _exited = true;
        call_deferred("_emit_process_exited", _generation.load(), _exit_code.load());
    }
    return _exit_code;
}

void SubProcess::stop()
{
    _stop(0, String());
}

int SubProcess::stop_gracefully(int grace_ms, const String &process_name)
{
    return _stop(grace_ms > 0 ? (grace_ms > 10000 ? 10000 : grace_ms) : 0, process_name);
}

int SubProcess::_stop(int grace_ms, const String &process_name)
{
    if (!_running) return _exit_code;
    _poll_exit();
    _diagnostics.stopping();
    _closing = true;
    // Keep the existing readers draining through child retirement, even for
    // immediate stop. Terminal evidence is finalized only after their join.
    _write_ready.notify_all();
    if (_write_thread.joinable()) {
        HANDLE writer = static_cast<HANDLE>(_write_thread.native_handle());
        while (WaitForSingleObject(writer, 10) == WAIT_TIMEOUT) CancelSynchronousIo(writer);
        _write_thread.join();
    }
    {
        std::lock_guard<std::mutex> lock(_write_mutex);
        while (!_write_queue.empty()) _write_queue.pop();
        _queued_write_bytes = 0;
    }
    close_handle(_stdin_wr);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(grace_ms);
    while (grace_ms > 0 && (_poll_exit(), !_exited) && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    if (grace_ms > 0 && (_poll_exit(), !_exited)) {
        const String reason = "stdin EOF grace expired after " + String::num_int64(grace_ms) + " ms; terminating owned child";
        UtilityFunctions::push_warning("SubProcess [" + process_name + "]: " + reason + " (stderr retained by the diagnostics owner)");
    }
    if (_child_process != nullptr) {
        const DWORD legacy_wait = grace_ms == 0 ? 100 : 0;
        if (WaitForSingleObject(_child_process, legacy_wait) != WAIT_OBJECT_0) {
            if (TerminateProcess(_child_process, 1)) _diagnostics.stopping(true);
            WaitForSingleObject(_child_process, 2000);
        }
        _poll_exit();
    }
    {
        const auto drain_deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(SubProcessIO::READER_DRAIN_MS);
        while ((!_stdout_done || !_stderr_done) && std::chrono::steady_clock::now() < drain_deadline)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    _running = false;
    // Descendants may inherit pipes: interrupt readers rather than waiting
    // for every inherited write handle to close after the owned child exits.
    for (std::thread *reader : {&_read_thread, &_stderr_thread}) {
        if (!reader->joinable()) continue;
        HANDLE handle = static_cast<HANDLE>(reader->native_handle());
        while (WaitForSingleObject(handle, 10) == WAIT_TIMEOUT) CancelSynchronousIo(handle);
        reader->join();
    }
    close_handle(_stdout_rd);
    close_handle(_stderr_rd);
    close_handle(_child_process);
    _diagnostics.finish();
    return _exit_code;
}

// ---------------------------------------------------------------------------
// stdout reader
// ---------------------------------------------------------------------------

void SubProcess::_read_loop()
{
    char buffer[4096];
    Utf8LineBuffer line_buffer;
    bool eof = false;
    while (_running) {
        DWORD bytes_read = 0;
        BOOL ok = ReadFile(_stdout_rd, buffer, sizeof(buffer), &bytes_read, nullptr);
        if (!ok) {
            DWORD error = GetLastError();
            if (error == ERROR_BROKEN_PIPE || error == ERROR_HANDLE_EOF) eof = true;
            else if (!_closing) {
                _stdout_failed = true;
                _record_failure("stdout_read_error", "stdout", 0, 0, error, false);
            }
            break;
        }
        if (bytes_read == 0) { eof = true; break; }
        if (_closing || _stdout_failed) { line_buffer.clear(); continue; }
        line_buffer.append(buffer, bytes_read);
        String line;
        size_t bytes = 0;
        while (!_stdout_failed && line_buffer.pop_line(line, true, &bytes)) {
            bool queued = false;
            {
                std::lock_guard<std::mutex> lock(_output_mutex);
                if (_closing) { line_buffer.clear(); break; }
                auto refused = SubProcessIO::stdout_admission(bytes, _output_queue.size(), _queued_output_bytes);
                if (refused.cause) {
                    _stdout_failed = true;
                    _record_failure(refused.cause, "stdout", refused.observed, refused.limit);
                } else {
                    _queued_output_bytes += bytes;
                    _output_queue.push({line, bytes});
                    queued = true;
                }
            }
            if (queued && !_output_notification_pending.exchange(true))
                call_deferred("_emit_output_ready", _generation.load());
        }
        {
            std::lock_guard<std::mutex> lock(_output_mutex);
            auto refused = SubProcessIO::stdout_pending(line_buffer.pending_payload_size(true), _queued_output_bytes);
            if (!_closing && !_stdout_failed && refused.cause) {
                _stdout_failed = true;
                _record_failure(refused.cause, "stdout", refused.observed, refused.limit);
            }
        }
        if (_stdout_failed) {
            // Once protocol bytes were lost, neither a queued prefix nor a
            // later suffix is a frame that callers may dispatch.
            std::lock_guard<std::mutex> lock(_output_mutex);
            while (!_output_queue.empty()) _output_queue.pop();
            _queued_output_bytes = 0;
            line_buffer.clear();
        }
    }
    _poll_exit();
    if (eof) {
        // Do not cancel earlier writes. Under this same lock, a new write is
        // either admitted before EOF or refused after EOF and its cause exist.
        // Lock order is write -> diagnostics, as for queue refusals below.
        std::lock_guard<std::mutex> lock(_write_mutex);
        _stdin_admission_closed = true;
        if (!_closing) _record_failure("stdout_eof", "stdout", line_buffer.size(), 0, 0, false);
    }
    _stdout_done = true;
}

// ---------------------------------------------------------------------------
// stderr reader
// ---------------------------------------------------------------------------

// stderr always drops oldest, including while running and while closing.
void SubProcess::_queue_stderr(const std::string &line)
{
    {
        std::lock_guard<std::mutex> lock(_stderr_mutex);
        while (SubProcessIO::stderr_needs_eviction(_stderr_queue.size(), _queued_stderr_bytes, line.size())) {
            size_t bytes = _stderr_queue.front().bytes;
            _queued_stderr_bytes -= bytes;
            _stderr_queue.pop();
            _diagnostics.drop(bytes);
        }
        _queued_stderr_bytes += line.size();
        _stderr_queue.push({String::utf8(line.data(), line.size()), line.size()});
        _diagnostics.remember(line);
    }
    if (!_stderr_notification_pending.exchange(true)) call_deferred("_emit_stderr_ready", _generation.load());
}

void SubProcess::_stderr_read_loop()
{
    char buffer[4096];
    SubProcessIO::StderrLines lines;
    bool eof = false;
    auto line = [this](const std::string &value) { _queue_stderr(value); };
    auto loss = [this](size_t bytes, bool first) { _diagnostics.truncate(bytes, first); };
    while (_running) {
        DWORD bytes_read = 0;
        BOOL ok = ReadFile(_stderr_rd, buffer, sizeof(buffer), &bytes_read, nullptr);
        if (!ok || bytes_read == 0) {
            DWORD error = ok ? 0 : GetLastError();
            eof = ok || error == ERROR_BROKEN_PIPE || error == ERROR_HANDLE_EOF;
            break;
        }
        lines.append(buffer, bytes_read, line, loss);
    }
    if (lines.has_tail()) lines.finish(line, loss);
    _diagnostics.stderr_finished(eof);
    _stderr_done = true;
}

// ---------------------------------------------------------------------------
// write / read accessors
// ---------------------------------------------------------------------------

bool SubProcess::write_data(const String &data)
{
    if (!_running || _closing || _io_overflow || _stdin_wr == nullptr || data.is_empty())
        return false;

    CharString utf8 = data.utf8();
    std::string bytes(utf8.get_data(), static_cast<size_t>(utf8.length()));
    {
        std::lock_guard<std::mutex> lock(_write_mutex);
        if (_stdin_admission_closed || !_running || _closing || _io_overflow) return false;
        if (_write_queue.size() >= SubProcessIO::STDIN_LINES) {
            _record_failure("stdin_queue_lines", "stdin", _write_queue.size() + 1, SubProcessIO::STDIN_LINES);
            return false;
        }
        if (_queued_write_bytes + bytes.size() > SubProcessIO::STDIN_BYTES) {
            _record_failure("stdin_queue_bytes", "stdin", _queued_write_bytes + bytes.size(), SubProcessIO::STDIN_BYTES);
            return false;
        }
        _queued_write_bytes += bytes.size();
        _write_queue.push(std::move(bytes));
    }
    _write_ready.notify_one();
    return true;
}

void SubProcess::_write_loop()
{
    while (_running && !_closing) {
        std::string data;
        {
            std::unique_lock<std::mutex> lock(_write_mutex);
            _write_ready.wait(lock, [this]() { return !_running || _closing || !_write_queue.empty(); });
            if (!_running || _closing) break;
            data = std::move(_write_queue.front());
            _queued_write_bytes -= data.size();
            _write_queue.pop();
        }
        size_t sent = 0;
        while (_running && !_closing && sent < data.size()) {
            DWORD written = 0;
            BOOL ok = WriteFile(_stdin_wr, data.data() + sent, static_cast<DWORD>(data.size() - sent), &written, nullptr);
            if (!ok || written == 0) {
                DWORD error = ok ? 0 : GetLastError();
                if (_running && !_closing)
                    _record_failure(error == ERROR_BROKEN_PIPE || error == ERROR_NO_DATA ? "stdin_broken_pipe" : "stdin_write_error",
                            "stdin", data.size() - sent, 0, error);
                break;
            }
            sent += written;
        }
    }
}

bool SubProcess::has_output()
{
    std::lock_guard<std::mutex> lock(_output_mutex);
    return !_stdout_failed && !_output_queue.empty();
}

String SubProcess::read_line()
{
    std::lock_guard<std::mutex> lock(_output_mutex);
    if (_stdout_failed || _output_queue.empty())
        return String();

    String line = _output_queue.front().text;
    _queued_output_bytes -= _output_queue.front().bytes;
    _output_queue.pop();
    return line;
}

String SubProcess::read_all()
{
    std::lock_guard<std::mutex> lock(_output_mutex);
    String result;
    if (_stdout_failed) return result;
    while (!_output_queue.empty()) {
        if (!result.is_empty())
            result += "\n";
        result += _output_queue.front().text;
        _queued_output_bytes -= _output_queue.front().bytes;
        _output_queue.pop();
    }
    return result;
}

bool SubProcess::has_stderr()
{
    std::lock_guard<std::mutex> lock(_stderr_mutex);
    return !_stderr_queue.empty();
}

String SubProcess::read_stderr_line()
{
    std::lock_guard<std::mutex> lock(_stderr_mutex);
    if (_stderr_queue.empty())
        return String();

    String line = _stderr_queue.front().text;
    _queued_stderr_bytes -= _stderr_queue.front().bytes;
    _stderr_queue.pop();
    return line;
}

void SubProcess::_record_failure(const char *cause, const char *channel, int64_t observed,
        int64_t limit, int64_t os_error, bool legacy_overflow)
{
    const bool first = _diagnostics.fail(cause, channel, observed, limit, os_error);
    const bool legacy = legacy_overflow && !_io_overflow.exchange(true);
    if (first || legacy) call_deferred("_emit_io_failure", _generation.load(), first, legacy);
}

Dictionary SubProcess::get_io_diagnostics(bool include_stderr)
{
    _poll_exit();
    return _diagnostics.snapshot(include_stderr);
}

Dictionary SubProcess::finalize_io(int64_t generation, bool include_stderr)
{
    if (generation != _generation) {
        Dictionary stale;
        stale["generation"] = _generation.load();
        stale["evidence_state"] = "stale_generation";
        return stale;
    }
    _stop(0, String());
    return _diagnostics.snapshot(include_stderr);
}

void SubProcess::_emit_io_failure(int64_t generation, bool first, bool legacy_overflow)
{
    if (generation != _generation) return;
    if (first) emit_signal("io_failed", generation);
    if (legacy_overflow && generation == _generation) emit_signal("io_overflow");
}

void SubProcess::_emit_process_exited(int64_t generation, int exit_code)
{
    if (generation == _generation) emit_signal("process_exited", exit_code);
}

void SubProcess::_emit_output_ready(int64_t generation)
{
    if (generation != _generation) return;
    _output_notification_pending = false;
    if (!_stdout_failed) emit_signal("output_ready");
}

void SubProcess::_emit_stderr_ready(int64_t generation)
{
    if (generation != _generation) return;
    _stderr_notification_pending = false;
    emit_signal("stderr_ready");
}

String SubProcess::read_all_stderr()
{
    std::lock_guard<std::mutex> lock(_stderr_mutex);
    String result;
    while (!_stderr_queue.empty()) {
        if (!result.is_empty())
            result += "\n";
        result += _stderr_queue.front().text;
        _queued_stderr_bytes -= _stderr_queue.front().bytes;
        _stderr_queue.pop();
    }
    return result;
}
