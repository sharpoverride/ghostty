//! ghostty-ctl — named-pipe control client for the win32 apprt.
//!
//! Talks the one-JSON-line-per-request protocol of
//! `src/apprt/win32/PipeServer.zig`. The pipe name comes from GHOSTTY_PIPE
//! (exported into every shell ghostty spawns) or `--pipe <name>`.
//!
//! Usage:
//!   ghostty-ctl list
//!   ghostty-ctl new-tab [command]
//!   ghostty-ctl open-browser [url]
//!   ghostty-ctl navigate <tab> <url>
//!   ghostty-ctl eval <tab> <js>
//!   ghostty-ctl switch <tab>
//!
//! Prints the JSON response on stdout. Exit codes: 0 ok, 1 usage/connect
//! error, 2 the window answered ok=false.

const std = @import("std");
const windows = std.os.windows;

const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;

const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const OPEN_EXISTING: DWORD = 3;
const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));

extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: DWORD, read: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: DWORD, written: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;

fn print(h: HANDLE, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        var written: DWORD = 0;
        if (WriteFile(h, bytes[off..].ptr, @intCast(bytes.len - off), &written, null) == 0) return;
        off += written;
    }
}

fn die(msg: []const u8) noreturn {
    print(GetStdHandle(STD_ERROR_HANDLE), msg);
    print(GetStdHandle(STD_ERROR_HANDLE), "\n");
    std.process.exit(1);
}

const usage =
    \\usage: ghostty-ctl [--pipe <name>] <command>
    \\  list                   show tabs (index, kind, title, url)
    \\  new-tab [command]      open a terminal tab (optional shell)
    \\  open-browser [url]     open a browser tab
    \\  navigate <tab> <url>   navigate a browser tab
    \\  eval <tab> <js>        evaluate JS in a browser tab, print result
    \\  switch <tab>           activate a tab
    \\
    \\pipe: GHOSTTY_PIPE env (set inside ghostty shells) or --pipe
;

/// Wire shape; null fields are omitted from the JSON.
const Wire = struct {
    cmd: []const u8,
    tab: ?usize = null,
    url: ?[]const u8 = null,
    command: ?[]const u8 = null,
    js: ?[]const u8 = null,
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa_state.allocator();

    const args = try std.process.argsAlloc(alloc);
    if (args.len < 2) die(usage);

    var pipe_override: ?[]const u8 = null;
    var i: usize = 1;
    if (std.mem.eql(u8, args[i], "--pipe")) {
        if (args.len < 4) die(usage);
        pipe_override = args[i + 1];
        i += 2;
    }

    const cmd = args[i];
    const rest = args[i + 1 ..];

    const wire: Wire = blk: {
        if (std.mem.eql(u8, cmd, "list")) {
            break :blk .{ .cmd = "list" };
        } else if (std.mem.eql(u8, cmd, "new-tab")) {
            break :blk .{ .cmd = "new-tab", .command = if (rest.len > 0) rest[0] else null };
        } else if (std.mem.eql(u8, cmd, "open-browser")) {
            break :blk .{ .cmd = "open-browser", .url = if (rest.len > 0) rest[0] else null };
        } else if (std.mem.eql(u8, cmd, "navigate")) {
            if (rest.len < 2) die(usage);
            break :blk .{
                .cmd = "navigate",
                .tab = std.fmt.parseInt(usize, rest[0], 10) catch die("bad tab index"),
                .url = rest[1],
            };
        } else if (std.mem.eql(u8, cmd, "eval")) {
            if (rest.len < 2) die(usage);
            break :blk .{
                .cmd = "eval",
                .tab = std.fmt.parseInt(usize, rest[0], 10) catch die("bad tab index"),
                .js = rest[1],
            };
        } else if (std.mem.eql(u8, cmd, "switch")) {
            if (rest.len < 1) die(usage);
            break :blk .{
                .cmd = "switch",
                .tab = std.fmt.parseInt(usize, rest[0], 10) catch die("bad tab index"),
            };
        }
        die(usage);
    };

    // Serialize the request (omit nulls).
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.json.Stringify.value(wire, .{ .emit_null_optional_fields = false }, &aw.writer);
    try aw.writer.writeByte('\n');

    // Resolve and open the pipe.
    const pipe_name = pipe_override orelse
        std.process.getEnvVarOwned(alloc, "GHOSTTY_PIPE") catch
            die("GHOSTTY_PIPE not set (run inside a ghostty tab, or pass --pipe)");
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, pipe_name);
    const pipe = CreateFileW(name_w.ptr, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, 0, null);
    if (pipe == windows.INVALID_HANDLE_VALUE) die("cannot open pipe (is ghostty running?)");
    defer _ = CloseHandle(pipe);

    // Send request.
    const req_bytes = aw.written();
    var off: usize = 0;
    while (off < req_bytes.len) {
        var written: DWORD = 0;
        if (WriteFile(pipe, req_bytes[off..].ptr, @intCast(req_bytes.len - off), &written, null) == 0)
            die("pipe write failed");
        off += written;
    }

    // Read one response line.
    var buf: [256 * 1024]u8 = undefined;
    var len: usize = 0;
    const line: []const u8 = while (true) {
        if (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |nl| break buf[0..nl];
        if (len == buf.len) die("response too long");
        var got: DWORD = 0;
        if (ReadFile(pipe, buf[len..].ptr, @intCast(buf.len - len), &got, null) == 0 or got == 0)
            die("pipe closed before a response arrived");
        len += got;
    };

    const stdout = GetStdHandle(STD_OUTPUT_HANDLE);
    print(stdout, line);
    print(stdout, "\n");

    // Exit 2 when the window reports failure so scripts can branch.
    if (std.mem.indexOf(u8, line, "\"ok\":true") == null) std.process.exit(2);
}
