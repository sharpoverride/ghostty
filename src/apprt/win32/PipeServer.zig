//! Named-pipe control API for the win32 apprt — the scripting surface that
//! lets agents (e.g. a CLI inside a terminal tab) drive the chrome: list
//! tabs, open tabs/browsers, navigate, evaluate JS in a browser pane.
//!
//! Transport: one JSON object per line on `\\.\pipe\ghostty-<pid>`, one
//! JSON response line back. The pipe name is exported to spawned shells as
//! GHOSTTY_PIPE (see Surface.defaultTermioEnv), so `ghostty-ctl` running
//! inside a tab finds its host window without configuration.
//!
//! Threading: a dedicated server thread owns the pipe. Each parsed request
//! is marshaled to the UI thread via WM_APP_PIPE_REQUEST (ChromeWindow
//! executes it — all tab state is UI-thread-only) and the server thread
//! blocks on the request's event until the UI thread (or, for `eval`, the
//! WebView2 completion callback) fills the response. The thread is a
//! daemon: it dies with the process, no join on shutdown.
const PipeServer = @This();

const std = @import("std");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.win32_pipe);

const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const HWND = windows.HWND;
const WPARAM = windows.WPARAM;
const LPARAM = windows.LPARAM;

const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
const PIPE_ACCESS_DUPLEX: DWORD = 0x00000003;
const PIPE_TYPE_BYTE: DWORD = 0x00000000;
const PIPE_READMODE_BYTE: DWORD = 0x00000000;
const PIPE_WAIT: DWORD = 0x00000000;
const WAIT_OBJECT_0: DWORD = 0;

extern "kernel32" fn CreateNamedPipeW(
    lpName: [*:0]const u16,
    dwOpenMode: DWORD,
    dwPipeMode: DWORD,
    nMaxInstances: DWORD,
    nOutBufferSize: DWORD,
    nInBufferSize: DWORD,
    nDefaultTimeOut: DWORD,
    lpSecurityAttributes: ?*anyopaque,
) callconv(.winapi) HANDLE;
extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: DWORD, read: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: DWORD, written: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: BOOL, initial: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetEvent(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "user32" fn PostMessageW(hWnd: HWND, Msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;

/// Must match ChromeWindow's WM_APP_PIPE_REQUEST (WM_APP + 5). Kept here so
/// the dependency points chrome→server, not both ways.
pub const WM_APP_PIPE_REQUEST: u32 = 0x8000 + 5;

/// How long the server thread waits for the UI thread (or an async eval
/// completion) before answering with a timeout error. A timed-out request
/// is intentionally leaked — the completion may still fire later.
const request_timeout_ms: DWORD = 30_000;

/// A parsed command, arena-owned strings.
pub const Command = union(enum) {
    list,
    /// Optional shell command for the new tab (null = default shell).
    new_tab: ?[]const u8,
    /// Optional URL (null = default page).
    open_browser: ?[]const u8,
    navigate: struct { tab: usize, url: []const u8 },
    eval: struct { tab: usize, js: []const u8 },
    switch_tab: usize,
};

/// One in-flight request. Created by the server thread, completed exactly
/// once on the UI thread (or by the WebView2 eval completion), then written
/// back + freed by the server thread.
pub const Request = struct {
    arena: std.heap.ArenaAllocator,
    cmd: Command,
    /// Response JSON line (no trailing newline), c_allocator-owned.
    response: ?[]u8 = null,
    done_event: HANDLE,

    /// Set the response to a copy of `bytes` and wake the server thread.
    pub fn complete(self: *Request, bytes: []const u8) void {
        self.response = std.heap.c_allocator.dupe(u8, bytes) catch null;
        _ = SetEvent(self.done_event);
    }

    /// Take ownership of c_allocator-owned `bytes` as the response.
    pub fn completeOwned(self: *Request, bytes: []u8) void {
        self.response = bytes;
        _ = SetEvent(self.done_event);
    }

    /// Respond {"ok":false,"error":msg} (JSON-escaped).
    pub fn fail(self: *Request, msg: []const u8) void {
        var aw: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
        defer aw.deinit();
        std.json.Stringify.value(
            .{ .ok = false, .@"error" = msg },
            .{},
            &aw.writer,
        ) catch {
            _ = SetEvent(self.done_event);
            return;
        };
        self.response = std.heap.c_allocator.dupe(u8, aw.written()) catch null;
        _ = SetEvent(self.done_event);
    }

    fn deinit(self: *Request) void {
        if (self.response) |r| std.heap.c_allocator.free(r);
        _ = CloseHandle(self.done_event);
        self.arena.deinit();
        std.heap.c_allocator.destroy(self);
    }
};

/// JSON wire shape of a request line. Unknown fields are ignored so the
/// protocol can grow.
const Wire = struct {
    cmd: []const u8 = "",
    tab: ?usize = null,
    url: ?[]const u8 = null,
    command: ?[]const u8 = null,
    js: ?[]const u8 = null,
};

alloc: Allocator,
chrome_hwnd: HWND,
/// UTF-8 pipe name, e.g. `\\.\pipe\ghostty-1234`. Owned.
name: []u8,
/// UTF-16 of the same, for CreateNamedPipeW. Owned.
name_w: [:0]u16,
thread: std.Thread,

/// Create the server and start its thread. `chrome_hwnd` receives
/// WM_APP_PIPE_REQUEST messages with a *Request in lparam.
pub fn start(alloc: Allocator, chrome_hwnd: HWND) !*PipeServer {
    const self = try alloc.create(PipeServer);
    errdefer alloc.destroy(self);

    const pid = GetCurrentProcessId();
    const name = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\ghostty-{d}", .{pid});
    errdefer alloc.free(name);
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, name);
    errdefer alloc.free(name_w);

    self.* = .{
        .alloc = alloc,
        .chrome_hwnd = chrome_hwnd,
        .name = name,
        .name_w = name_w,
        .thread = undefined,
    };
    self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    self.thread.detach();
    log.info("pipe server listening on {s}", .{name});
    return self;
}

pub fn pipeName(self: *const PipeServer) []const u8 {
    return self.name;
}

fn threadMain(self: *PipeServer) void {
    while (true) {
        const pipe = CreateNamedPipeW(
            self.name_w.ptr,
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            1, // one instance; clients queue up
            64 * 1024,
            64 * 1024,
            0,
            null,
        );
        if (pipe == INVALID_HANDLE_VALUE) {
            log.warn("CreateNamedPipeW failed; pipe API disabled", .{});
            return;
        }
        defer _ = CloseHandle(pipe);

        if (ConnectNamedPipe(pipe, null) == 0) continue;
        defer _ = DisconnectNamedPipe(pipe);
        self.serveClient(pipe);
    }
}

/// Read newline-delimited JSON requests until the client disconnects.
fn serveClient(self: *PipeServer, pipe: HANDLE) void {
    var buf: [64 * 1024]u8 = undefined;
    var len: usize = 0;
    while (true) {
        // Pull out complete lines already buffered.
        while (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |nl| {
            const line = std.mem.trimRight(u8, buf[0..nl], "\r");
            if (line.len > 0) {
                if (!self.handleLine(pipe, line)) return;
            }
            std.mem.copyForwards(u8, &buf, buf[nl + 1 .. len]);
            len -= nl + 1;
        }
        if (len == buf.len) {
            writeAll(pipe, "{\"ok\":false,\"error\":\"request too long\"}\n");
            return;
        }
        var got: DWORD = 0;
        if (ReadFile(pipe, buf[len..].ptr, @intCast(buf.len - len), &got, null) == 0 or got == 0)
            return; // client gone
        len += got;
    }
}

/// Parse one request line, marshal it to the UI thread, await and write
/// the response. Returns false if the connection should be dropped.
fn handleLine(self: *PipeServer, pipe: HANDLE, line: []const u8) bool {
    const req = self.buildRequest(line) catch |e| {
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "{{\"ok\":false,\"error\":\"bad request: {s}\"}}\n",
            .{@errorName(e)},
        ) catch return false;
        writeAll(pipe, msg);
        return true;
    };

    if (PostMessageW(self.chrome_hwnd, WM_APP_PIPE_REQUEST, 0, @bitCast(@intFromPtr(req))) == 0) {
        req.deinit();
        writeAll(pipe, "{\"ok\":false,\"error\":\"window gone\"}\n");
        return false;
    }

    switch (WaitForSingleObject(req.done_event, request_timeout_ms)) {
        WAIT_OBJECT_0 => {
            const resp = req.response orelse "{\"ok\":false,\"error\":\"no response\"}";
            writeAll(pipe, resp);
            writeAll(pipe, "\n");
            req.deinit();
            return true;
        },
        else => {
            // The completion may still fire later: leak the request rather
            // than free under it. Rare (hung page script, dead webview).
            log.warn("pipe request timed out; leaking request", .{});
            writeAll(pipe, "{\"ok\":false,\"error\":\"timeout\"}\n");
            return true;
        },
    }
}

fn buildRequest(self: *PipeServer, line: []const u8) !*Request {
    _ = self;
    const c_alloc = std.heap.c_allocator;
    const req = try c_alloc.create(Request);
    errdefer c_alloc.destroy(req);

    req.* = .{
        .arena = std.heap.ArenaAllocator.init(c_alloc),
        .cmd = undefined,
        .done_event = CreateEventW(null, 0, 0, null) orelse return error.NoEvent,
    };
    errdefer req.arena.deinit();

    const a = req.arena.allocator();
    const wire = try std.json.parseFromSliceLeaky(Wire, a, line, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });

    req.cmd = if (std.mem.eql(u8, wire.cmd, "list"))
        .list
    else if (std.mem.eql(u8, wire.cmd, "new-tab"))
        .{ .new_tab = wire.command }
    else if (std.mem.eql(u8, wire.cmd, "open-browser"))
        .{ .open_browser = wire.url }
    else if (std.mem.eql(u8, wire.cmd, "navigate"))
        .{ .navigate = .{
            .tab = wire.tab orelse return error.MissingTab,
            .url = wire.url orelse return error.MissingUrl,
        } }
    else if (std.mem.eql(u8, wire.cmd, "eval"))
        .{ .eval = .{
            .tab = wire.tab orelse return error.MissingTab,
            .js = wire.js orelse return error.MissingJs,
        } }
    else if (std.mem.eql(u8, wire.cmd, "switch"))
        .{ .switch_tab = wire.tab orelse return error.MissingTab }
    else
        return error.UnknownCommand;

    return req;
}

fn writeAll(pipe: HANDLE, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        var written: DWORD = 0;
        if (WriteFile(pipe, bytes[off..].ptr, @intCast(bytes.len - off), &written, null) == 0)
            return;
        off += written;
    }
}
