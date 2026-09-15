#include "subprocess.h"
#include "common/utf8_line_buffer.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <string>

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
    ClassDB::bind_method(D_METHOD("stop"), &SubProcess::stop);
    ClassDB::bind_method(D_METHOD("write_data", "data"), &SubProcess::write_data);
    ClassDB::bind_method(D_METHOD("has_io_overflow"), &SubProcess::has_io_overflow);
    ClassDB::bind_method(D_METHOD("_emit_output_ready"), &SubProcess::_emit_output_ready);
    ClassDB::bind_method(D_METHOD("_emit_stderr_ready"), &SubProcess::_emit_stderr_ready);
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
    if (_running)
        return false;

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
        app.c_str(),
        &cmdbuf[0],
        nullptr,            // process security
        nullptr,            // thread security
        TRUE,               // inherit handles (the child-side pipe ends)
        CREATE_NO_WINDOW,   // no console window flashes for console subprocesses
        nullptr,            // inherit environment
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

    _running = true;
    _io_overflow = false;
	_output_notification_pending = false;
	_stderr_notification_pending = false;
	{
		std::lock_guard<std::mutex> lock(_write_mutex);
		while (!_write_queue.empty()) _write_queue.pop();
		_queued_write_bytes = 0;
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

void SubProcess::stop()
{
    if (!_running)
        return;

    _running = false;
	_write_ready.notify_all();
	if (_write_thread.joinable()) {
		HANDLE writer = static_cast<HANDLE>(_write_thread.native_handle());
		while (WaitForSingleObject(writer, 10) == WAIT_TIMEOUT)
			CancelSynchronousIo(writer);
		_write_thread.join();
	}

    // Close stdin to signal EOF to child (many stdio servers exit on stdin EOF).
    close_handle(_stdin_wr);

    // Give the process a moment to exit gracefully, then force it. Terminating
    // (or a graceful exit) closes the child's stdout/stderr write ends, which is
    // what unblocks the reader threads sitting in ReadFile below.
    if (_child_process != nullptr) {
        if (WaitForSingleObject(_child_process, 100) != WAIT_OBJECT_0) {
            TerminateProcess(_child_process, 1);
            WaitForSingleObject(_child_process, 2000);
        }
    }

    // Reader threads own _stdout_rd / _stderr_rd; join BEFORE closing them.
    if (_read_thread.joinable())
        _read_thread.join();
    if (_stderr_thread.joinable())
        _stderr_thread.join();

    close_handle(_stdout_rd);
    close_handle(_stderr_rd);
    close_handle(_child_process);
}

// ---------------------------------------------------------------------------
// stdout reader
// ---------------------------------------------------------------------------

void SubProcess::_read_loop()
{
    char buffer[4096];
    Utf8LineBuffer line_buffer;

    while (_running) {
        DWORD bytes_read = 0;
        BOOL ok = ReadFile(_stdout_rd, buffer, sizeof(buffer) - 1, &bytes_read, nullptr);

        if (ok && bytes_read > 0) {
            line_buffer.append(buffer, bytes_read);
            if (line_buffer.size() > MAX_QUEUED_BYTES) { line_buffer.clear(); _record_overflow(); }
            String line;
            while (line_buffer.pop_line(line, true)) {

                bool queued = false;
                {
                    std::lock_guard<std::mutex> lock(_output_mutex);
                    size_t bytes = static_cast<size_t>(line.utf8().length());
                    if (_output_queue.size() >= MAX_QUEUED_LINES || _queued_output_bytes + bytes > MAX_QUEUED_BYTES) {
                        _record_overflow();
                    } else {
                        _queued_output_bytes += bytes;
                        _output_queue.push(line);
                        queued = true;
                    }
                }
                if (queued && !_output_notification_pending.exchange(true))
                    call_deferred("_emit_output_ready");
            }
        } else {
            // ReadFile failed (broken pipe) or returned 0 bytes (EOF) — the
            // child closed stdout / exited.
            break;
        }
    }

    // Report exit code if the process has already terminated (non-blocking,
    // mirroring the unix waitpid(WNOHANG) behavior).
    if (_child_process != nullptr) {
        DWORD code = 0;
        if (GetExitCodeProcess(_child_process, &code) && code != STILL_ACTIVE) {
            call_deferred("emit_signal", "process_exited", static_cast<int>(code));
        }
    }
}

// ---------------------------------------------------------------------------
// stderr reader
// ---------------------------------------------------------------------------

void SubProcess::_stderr_read_loop()
{
    char buffer[4096];
    Utf8LineBuffer line_buffer;

    while (_running) {
        DWORD bytes_read = 0;
        BOOL ok = ReadFile(_stderr_rd, buffer, sizeof(buffer) - 1, &bytes_read, nullptr);

        if (ok && bytes_read > 0) {
            line_buffer.append(buffer, bytes_read);
            if (line_buffer.size() > MAX_QUEUED_BYTES) { line_buffer.clear(); _record_overflow(); }
            String line;
            while (line_buffer.pop_line(line, true)) {

                bool queued = false;
                {
                    std::lock_guard<std::mutex> lock(_stderr_mutex);
                    size_t bytes = static_cast<size_t>(line.utf8().length());
                    if (_stderr_queue.size() >= MAX_QUEUED_LINES || _queued_stderr_bytes + bytes > MAX_QUEUED_BYTES) {
                        _record_overflow();
                    } else {
                        _queued_stderr_bytes += bytes;
                        _stderr_queue.push(line);
                        queued = true;
                    }
                }
                if (queued && !_stderr_notification_pending.exchange(true))
                    call_deferred("_emit_stderr_ready");
            }
        } else {
            break;
        }
    }

    // Flush any remaining partial line.
    String tail = line_buffer.take_tail();
    if (!tail.is_empty()) {
        std::lock_guard<std::mutex> lock(_stderr_mutex);
        size_t bytes = static_cast<size_t>(tail.utf8().length());
        if (_stderr_queue.size() >= MAX_QUEUED_LINES || _queued_stderr_bytes + bytes > MAX_QUEUED_BYTES) _record_overflow();
        else {
            _queued_stderr_bytes += bytes;
            _stderr_queue.push(tail);
            if (!_stderr_notification_pending.exchange(true)) call_deferred("_emit_stderr_ready");
        }
    }
}

// ---------------------------------------------------------------------------
// write / read accessors
// ---------------------------------------------------------------------------

bool SubProcess::write_data(const String &data)
{
    if (!_running || _stdin_wr == nullptr || data.is_empty())
        return false;

    CharString utf8 = data.utf8();
    std::string bytes(utf8.get_data(), static_cast<size_t>(utf8.length()));
    {
        std::lock_guard<std::mutex> lock(_write_mutex);
        if (_write_queue.size() >= MAX_QUEUED_LINES || _queued_write_bytes + bytes.size() > MAX_QUEUED_WRITE_BYTES)
            return false;
        _queued_write_bytes += bytes.size();
        _write_queue.push(std::move(bytes));
    }
    _write_ready.notify_one();
    return true;
}

void SubProcess::_write_loop()
{
    while (_running) {
        std::string data;
        {
            std::unique_lock<std::mutex> lock(_write_mutex);
            _write_ready.wait(lock, [this]() { return !_running || !_write_queue.empty(); });
            if (!_running) break;
            data = std::move(_write_queue.front());
            _queued_write_bytes -= data.size();
            _write_queue.pop();
        }
        size_t sent = 0;
        while (_running && sent < data.size()) {
            DWORD written = 0;
            if (!WriteFile(_stdin_wr, data.data() + sent, static_cast<DWORD>(data.size() - sent), &written, nullptr) || written == 0)
                break;
            sent += written;
        }
        if (_running && sent != data.size()) _record_overflow();
    }
}

bool SubProcess::has_output()
{
    std::lock_guard<std::mutex> lock(_output_mutex);
    return !_output_queue.empty();
}

String SubProcess::read_line()
{
    std::lock_guard<std::mutex> lock(_output_mutex);
    if (_output_queue.empty())
        return String();

    String line = _output_queue.front();
    _output_queue.pop();
    _queued_output_bytes -= static_cast<size_t>(line.utf8().length());
    return line;
}

String SubProcess::read_all()
{
    std::lock_guard<std::mutex> lock(_output_mutex);
    String result;
    while (!_output_queue.empty()) {
        if (!result.is_empty())
            result += "\n";
        result += _output_queue.front();
        _queued_output_bytes -= static_cast<size_t>(_output_queue.front().utf8().length());
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

    String line = _stderr_queue.front();
    _stderr_queue.pop();
    _queued_stderr_bytes -= static_cast<size_t>(line.utf8().length());
    return line;
}

void SubProcess::_record_overflow()
{
    if (!_io_overflow.exchange(true))
        call_deferred("emit_signal", "io_overflow");
}

void SubProcess::_emit_output_ready()
{
    _output_notification_pending = false;
    emit_signal("output_ready");
}

void SubProcess::_emit_stderr_ready()
{
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
        result += _stderr_queue.front();
        _queued_stderr_bytes -= static_cast<size_t>(_stderr_queue.front().utf8().length());
        _stderr_queue.pop();
    }
    return result;
}
