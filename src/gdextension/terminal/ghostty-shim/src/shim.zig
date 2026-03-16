const std = @import("std");
const ghostty = @import("ghostty-vt");

const Terminal = ghostty.Terminal;
const Page = ghostty.Page;
const Style = ghostty.Style;
const ReadonlyStream = ghostty.ReadonlyStream;

const allocator = std.heap.c_allocator;

// ── Terminal wrapper ────────────────────────────────────────────────
// Wraps the ghostty Terminal with a persistent VT stream (for parser
// state continuity across PTY reads) and a mutex (for thread safety
// between the output reader thread and the Godot main thread).

const TerminalState = struct {
    terminal: *Terminal,
    stream: ReadonlyStream,
    mutex: std.Thread.Mutex,

    fn init(cols: u16, rows: u16) !*TerminalState {
        const t = try allocator.create(Terminal);
        errdefer allocator.destroy(t);
        t.* = try Terminal.init(allocator, .{ .cols = cols, .rows = rows });

        const state = try allocator.create(TerminalState);
        state.* = .{
            .terminal = t,
            .stream = t.vtStream(),
            .mutex = .{},
        };
        return state;
    }

    fn deinit(self: *TerminalState) void {
        self.stream.deinit();
        self.terminal.deinit(allocator);
        allocator.destroy(self.terminal);
        allocator.destroy(self);
    }
};

// ── C-compatible structs (must match minerva_vt.h) ──────────────────

const ColorType = enum(u8) {
    none = 0,
    palette = 1,
    rgb = 2,
};

const MinervaColor = extern struct {
    type: ColorType,
    r: u8,
    g: u8,
    b: u8,
    palette_index: u8,
};

const MinervaWide = enum(u8) {
    narrow = 0,
    wide = 1,
    spacer_head = 2,
    spacer_tail = 3,
};

const MinervaCellInfo = extern struct {
    codepoint: u32,
    fg: MinervaColor,
    bg: MinervaColor,
    wide: MinervaWide,
    bold: bool,
    italic: bool,
    faint: bool,
    strikethrough: bool,
    inverse: bool,
    blink: bool,
    overline: bool,
    invisible: bool,
    underline: u8,
    has_style: bool,
};

const MinervaCursorInfo = extern struct {
    x: u16,
    y: u16,
    visible: bool,
    style: u8,
};

// ── Helpers ─────────────────────────────────────────────────────────

fn convertColor(c: Style.Color) MinervaColor {
    return switch (c) {
        .none => .{ .type = .none, .r = 0, .g = 0, .b = 0, .palette_index = 0 },
        .palette => |p| .{ .type = .palette, .r = 0, .g = 0, .b = 0, .palette_index = p },
        .rgb => |rgb| .{ .type = .rgb, .r = rgb.r, .g = rgb.g, .b = rgb.b, .palette_index = 0 },
    };
}

fn convertWide(w: ghostty.Cell.Wide) MinervaWide {
    return switch (w) {
        .narrow => .narrow,
        .wide => .wide,
        .spacer_head => .spacer_head,
        .spacer_tail => .spacer_tail,
    };
}

fn convertUnderline(u: anytype) u8 {
    return switch (u) {
        .none => 0,
        .single => 1,
        .double => 2,
        .curly => 3,
        .dotted => 4,
        .dashed => 5,
    };
}

const default_color: MinervaColor = .{ .type = .none, .r = 0, .g = 0, .b = 0, .palette_index = 0 };

// ── Exported C API ──────────────────────────────────────────────────

export fn minerva_vt_new(cols: u16, rows: u16) callconv(.c) ?*anyopaque {
    const state = TerminalState.init(cols, rows) catch return null;
    return @ptrCast(state);
}

export fn minerva_vt_free(term: ?*anyopaque) callconv(.c) void {
    const state: *TerminalState = @ptrCast(@alignCast(term orelse return));
    state.deinit();
}

export fn minerva_vt_write(term: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) void {
    const state: *TerminalState = @ptrCast(@alignCast(term orelse return));
    state.mutex.lock();
    defer state.mutex.unlock();
    // Feed bytes through the persistent VT stream — parser state is preserved
    // across calls so escape sequences spanning multiple PTY reads work correctly.
    for (data[0..len]) |byte| {
        state.stream.next(byte) catch {};
    }
}

export fn minerva_vt_resize(term: ?*anyopaque, cols: u16, rows: u16) callconv(.c) bool {
    const state: *TerminalState = @ptrCast(@alignCast(term orelse return false));
    state.mutex.lock();
    defer state.mutex.unlock();
    state.terminal.resize(allocator, cols, rows) catch return false;
    return true;
}

export fn minerva_vt_get_size(term: ?*anyopaque, cols: ?*u16, rows: ?*u16) callconv(.c) void {
    const state: *TerminalState = @ptrCast(@alignCast(term orelse return));
    state.mutex.lock();
    defer state.mutex.unlock();
    if (cols) |c| c.* = state.terminal.cols;
    if (rows) |r| r.* = state.terminal.rows;
}

export fn minerva_vt_get_cell(term: ?*anyopaque, col: u16, row: u16, out: ?*MinervaCellInfo) callconv(.c) bool {
    const state: *TerminalState = @ptrCast(@alignCast(term orelse return false));
    const info = out orelse return false;
    state.mutex.lock();
    defer state.mutex.unlock();

    const t = state.terminal;
    const screen = t.screens.active;

    const pt: ghostty.point.Point = .{ .viewport = .{ .x = col, .y = row } };
    const pin = screen.pages.pin(pt) orelse return false;
    const page_data = &pin.node.data;
    const rac = page_data.getRowAndCell(pin.x, pin.y);
    const cell = rac.cell;

    info.codepoint = switch (cell.content_tag) {
        .codepoint => cell.content.codepoint,
        else => 0,
    };

    info.wide = convertWide(cell.wide);

    if (cell.style_id == 0) {
        info.fg = default_color;
        info.bg = default_color;
        info.bold = false;
        info.italic = false;
        info.faint = false;
        info.strikethrough = false;
        info.inverse = false;
        info.blink = false;
        info.overline = false;
        info.invisible = false;
        info.underline = 0;
        info.has_style = false;
    } else {
        const style = page_data.styles.get(page_data.memory, cell.style_id);
        info.fg = convertColor(style.fg_color);
        info.bg = convertColor(style.bg_color);
        info.bold = style.flags.bold;
        info.italic = style.flags.italic;
        info.faint = style.flags.faint;
        info.strikethrough = style.flags.strikethrough;
        info.inverse = style.flags.inverse;
        info.blink = style.flags.blink;
        info.overline = style.flags.overline;
        info.invisible = style.flags.invisible;
        info.underline = convertUnderline(style.flags.underline);
        info.has_style = true;
    }

    return true;
}

export fn minerva_vt_get_cursor(term: ?*anyopaque, out: ?*MinervaCursorInfo) callconv(.c) void {
    const state: *TerminalState = @ptrCast(@alignCast(term orelse return));
    const info = out orelse return;
    state.mutex.lock();
    defer state.mutex.unlock();

    const t = state.terminal;
    const screen = t.screens.active;
    info.x = screen.cursor.x;
    info.y = screen.cursor.y;
    info.visible = t.modes.get(.cursor_visible);
    info.style = switch (screen.cursor.cursor_style) {
        .block => 0,
        .bar => 1,
        .underline => 2,
        else => 0,
    };
}

export fn minerva_vt_plain_string(term: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const state: *TerminalState = @ptrCast(@alignCast(term orelse return null));
    state.mutex.lock();
    defer state.mutex.unlock();

    const t = state.terminal;
    const str = t.plainString(allocator) catch return null;
    const buf = allocator.allocSentinel(u8, str.len, 0) catch {
        allocator.free(str);
        return null;
    };
    @memcpy(buf[0..str.len], str);
    allocator.free(str);
    return buf.ptr;
}

export fn minerva_vt_free_string(str: ?[*:0]u8) callconv(.c) void {
    if (str) |s| {
        var len: usize = 0;
        while (s[len] != 0) : (len += 1) {}
        allocator.free(s[0 .. len + 1]);
    }
}

export fn minerva_vt_scroll_viewport(term: ?*anyopaque, lines: i32) callconv(.c) void {
    const state: *TerminalState = @ptrCast(@alignCast(term orelse return));
    state.mutex.lock();
    defer state.mutex.unlock();

    const t = state.terminal;
    if (lines == 0) {
        t.scrollViewport(.{ .bottom = {} });
    } else {
        t.scrollViewport(.{ .delta = @as(isize, @intCast(lines)) });
    }
}

export fn minerva_vt_encode_key(
    term: ?*anyopaque,
    key_code: c_int,
    action: c_int,
    mods: u16,
    utf8_ptr: ?[*]const u8,
    utf8_len: usize,
    out_buf: ?[*]u8,
    out_buf_size: usize,
) callconv(.c) usize {
    const state: *TerminalState = @ptrCast(@alignCast(term orelse return 0));
    const buf = out_buf orelse return 0;
    if (out_buf_size == 0) return 0;

    state.mutex.lock();
    defer state.mutex.unlock();

    const t = state.terminal;

    const ghostty_key = std.meta.intToEnum(ghostty.input.Key, key_code) catch return 0;
    const ghostty_action: ghostty.input.KeyAction = std.meta.intToEnum(ghostty.input.KeyAction, action) catch return 0;
    const ghostty_mods: ghostty.input.KeyMods = @bitCast(mods);

    const utf8_slice: []const u8 = if (utf8_ptr) |p| p[0..utf8_len] else "";
    const event: ghostty.input.KeyEvent = .{
        .action = ghostty_action,
        .key = ghostty_key,
        .mods = ghostty_mods,
        .consumed_mods = .{},
        .composing = false,
        .utf8 = utf8_slice,
        .unshifted_codepoint = 0,
    };

    const opts = ghostty.input.KeyEncodeOptions.fromTerminal(t);

    var writer: std.Io.Writer = .fixed(buf[0..out_buf_size]);
    if (ghostty.input.encodeKey(&writer, event, opts)) {
        const written = writer.buffered();
        return written.len;
    } else |_| {
        return 0;
    }
}

// ── Tests ───────────────────────────────────────────────────────────

test "create and destroy terminal" {
    const term = minerva_vt_new(80, 24);
    try std.testing.expect(term != null);
    minerva_vt_free(term);
}

test "write and read cell" {
    const term = minerva_vt_new(80, 24) orelse unreachable;
    defer minerva_vt_free(term);

    const data = "Hi";
    minerva_vt_write(term, data.ptr, data.len);

    var cell: MinervaCellInfo = undefined;
    const ok = minerva_vt_get_cell(term, 0, 0, &cell);
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(u32, 'H'), cell.codepoint);
}

test "cursor position after write" {
    const term = minerva_vt_new(80, 24) orelse unreachable;
    defer minerva_vt_free(term);

    const data = "Hello";
    minerva_vt_write(term, data.ptr, data.len);

    var cursor: MinervaCursorInfo = undefined;
    minerva_vt_get_cursor(term, &cursor);
    try std.testing.expectEqual(@as(u16, 5), cursor.x);
    try std.testing.expectEqual(@as(u16, 0), cursor.y);
}

test "resize terminal" {
    const term = minerva_vt_new(80, 24) orelse unreachable;
    defer minerva_vt_free(term);

    const ok = minerva_vt_resize(term, 120, 40);
    try std.testing.expect(ok);

    var cols: u16 = 0;
    var rows: u16 = 0;
    minerva_vt_get_size(term, &cols, &rows);
    try std.testing.expectEqual(@as(u16, 120), cols);
    try std.testing.expectEqual(@as(u16, 40), rows);
}

test "split escape sequence across writes" {
    const term = minerva_vt_new(80, 24) orelse unreachable;
    defer minerva_vt_free(term);

    // Write "A" then a color escape split across two writes
    minerva_vt_write(term, "A\x1b[", 3); // Start of escape
    minerva_vt_write(term, "31mB", 4); // Rest of escape + "B"

    // Cell 0 should be 'A' with default style
    var cell_a: MinervaCellInfo = undefined;
    try std.testing.expect(minerva_vt_get_cell(term, 0, 0, &cell_a));
    try std.testing.expectEqual(@as(u32, 'A'), cell_a.codepoint);
    try std.testing.expect(!cell_a.has_style);

    // Cell 1 should be 'B' with red foreground (SGR 31)
    var cell_b: MinervaCellInfo = undefined;
    try std.testing.expect(minerva_vt_get_cell(term, 1, 0, &cell_b));
    try std.testing.expectEqual(@as(u32, 'B'), cell_b.codepoint);
    try std.testing.expect(cell_b.has_style);
}
