#include "subprocess.h"
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

    _read_thread = std::thread([this]() { _read_loop(); });
    _stderr_thread = std::thread([this]() { _stderr_read_loop(); });

    return true;
}

void SubProcess::stop()
{
    if (!_running)
        return;

    _running = false;

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
    String line_buffer;

    while (_running) {
        DWORD bytes_read = 0;
        BOOL ok = ReadFile(_stdout_rd, buffer, sizeof(buffer) - 1, &bytes_read, nullptr);

        if (ok && bytes_read > 0) {
            String chunk = String::utf8(buffer, static_cast<int>(bytes_read));
            line_buffer += chunk;

            int newline_pos;
            while ((newline_pos = line_buffer.find("\n")) != -1) {
                String line = line_buffer.substr(0, newline_pos);
                // Strip a trailing CR so CRLF-terminated lines parse as clean
                // JSON-RPC (the unix pipe never sees CR; a Windows child might).
                if (!line.is_empty() && line[line.length() - 1] == '\r')
                    line = line.substr(0, line.length() - 1);
                line_buffer = line_buffer.substr(newline_pos + 1);

                {
                    std::lock_guard<std::mutex> lock(_output_mutex);
                    _output_queue.push(line);
                }

                call_deferred("emit_signal", "output_ready");
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
    String line_buffer;

    while (_running) {
        DWORD bytes_read = 0;
        BOOL ok = ReadFile(_stderr_rd, buffer, sizeof(buffer) - 1, &bytes_read, nullptr);

        if (ok && bytes_read > 0) {
            String chunk = String::utf8(buffer, static_cast<int>(bytes_read));
            line_buffer += chunk;

            int newline_pos;
            while ((newline_pos = line_buffer.find("\n")) != -1) {
                String line = line_buffer.substr(0, newline_pos);
                if (!line.is_empty() && line[line.length() - 1] == '\r')
                    line = line.substr(0, line.length() - 1);
                line_buffer = line_buffer.substr(newline_pos + 1);

                {
                    std::lock_guard<std::mutex> lock(_stderr_mutex);
                    _stderr_queue.push(line);
                }

                call_deferred("emit_signal", "stderr_ready");
            }
        } else {
            break;
        }
    }

    // Flush any remaining partial line.
    if (!line_buffer.is_empty()) {
        std::lock_guard<std::mutex> lock(_stderr_mutex);
        _stderr_queue.push(line_buffer);
        call_deferred("emit_signal", "stderr_ready");
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
    const char *ptr = utf8.get_data();
    size_t total = static_cast<size_t>(utf8.length());
    size_t sent = 0;

    // WriteFile on a blocking pipe normally writes everything, but loop in case
    // a large payload comes back partial so long inputs aren't truncated.
    while (sent < total) {
        DWORD written = 0;
        BOOL ok = WriteFile(_stdin_wr, ptr + sent, static_cast<DWORD>(total - sent), &written, nullptr);
        if (!ok)
            return false; // broken pipe, etc.
        if (written == 0)
            break;
        sent += written;
    }

    return sent == total;
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
    return line;
}

String SubProcess::read_all_stderr()
{
    std::lock_guard<std::mutex> lock(_stderr_mutex);
    String result;
    while (!_stderr_queue.empty()) {
        if (!result.is_empty())
            result += "\n";
        result += _stderr_queue.front();
        _stderr_queue.pop();
    }
    return result;
}
