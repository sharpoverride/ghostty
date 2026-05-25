//! ConPTY (pseudoconsole) bindings + a Pty struct that owns the pseudoconsole,
//! the child process, and the I/O pipes for the lifetime of a Surface.
//!
//! Used by `Window.zig` for the MVP terminal. Same API will plug into the
//! eventual termio layer when Ghostty's engine integration lands.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const HANDLE = windows.HANDLE;
pub const HRESULT = windows.HRESULT;
pub const DWORD = windows.DWORD;
pub const BOOL = windows.BOOL;
pub const WORD = windows.WORD;
pub const FALSE = windows.FALSE;
pub const TRUE = windows.TRUE;

pub const COORD = extern struct { X: i16, Y: i16 };
pub const HPCON = *anyopaque;

pub const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?windows.LPWSTR,
    lpDesktop: ?windows.LPWSTR,
    lpTitle: ?windows.LPWSTR,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: WORD,
    cbReserved2: WORD,
    lpReserved2: ?[*]u8,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: BOOL,
};

pub const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 22 | 0x00020000;

pub extern "kernel32" fn CreatePseudoConsole(size: COORD, hInput: HANDLE, hOutput: HANDLE, dwFlags: DWORD, phPC: *HPCON) callconv(.winapi) HRESULT;
pub extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: COORD) callconv(.winapi) HRESULT;
pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;

pub extern "kernel32" fn CreatePipe(hReadPipe: *HANDLE, hWritePipe: *HANDLE, lpPipeAttributes: ?*SECURITY_ATTRIBUTES, nSize: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn InitializeProcThreadAttributeList(lpAttributeList: ?*anyopaque, dwAttributeCount: DWORD, dwFlags: DWORD, lpSize: *usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn UpdateProcThreadAttribute(lpAttributeList: *anyopaque, dwFlags: DWORD, Attribute: usize, lpValue: *anyopaque, cbSize: usize, lpPreviousValue: ?*anyopaque, lpReturnSize: ?*usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: *anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn CreateProcessW(lpApplicationName: ?windows.LPCWSTR, lpCommandLine: ?windows.LPWSTR, lpProcessAttributes: ?*SECURITY_ATTRIBUTES, lpThreadAttributes: ?*SECURITY_ATTRIBUTES, bInheritHandles: BOOL, dwCreationFlags: DWORD, lpEnvironment: ?*anyopaque, lpCurrentDirectory: ?windows.LPCWSTR, lpStartupInfo: *STARTUPINFOW, lpProcessInformation: *PROCESS_INFORMATION) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetEnvironmentVariableW(lpName: windows.LPCWSTR, lpBuffer: ?windows.LPWSTR, nSize: DWORD) callconv(.winapi) DWORD;

pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));

pub const PtySize = struct { cols: u16, rows: u16 };

/// Owns a pseudoconsole + a spawned shell child + the read/write pipe halves
/// the caller talks to.
pub const Pty = struct {
    alloc: std.mem.Allocator,
    hpc: HPCON,
    in_write: HANDLE, // we write here, pty reads
    out_read: HANDLE, // pty writes here, we read
    proc: PROCESS_INFORMATION,
    attr_list: []align(16) u8,

    pub fn start(alloc: std.mem.Allocator, size: PtySize) !*Pty {
        comptime if (builtin.os.tag != .windows) @compileError("ConPTY requires Windows");

        var in_read: HANDLE = undefined;
        var in_write: HANDLE = undefined;
        var out_read: HANDLE = undefined;
        var out_write: HANDLE = undefined;
        if (CreatePipe(&in_read, &in_write, null, 0) == FALSE) return error.CreatePipeFailed;
        errdefer _ = windows.CloseHandle(in_write);
        if (CreatePipe(&out_read, &out_write, null, 0) == FALSE) {
            _ = windows.CloseHandle(in_read);
            return error.CreatePipeFailed;
        }
        errdefer _ = windows.CloseHandle(out_read);

        var hpc: HPCON = undefined;
        const coord: COORD = .{ .X = @intCast(size.cols), .Y = @intCast(size.rows) };
        const hr = CreatePseudoConsole(coord, in_read, out_write, 0, &hpc);
        // Once the pseudoconsole owns them we close our handles.
        _ = windows.CloseHandle(in_read);
        _ = windows.CloseHandle(out_write);
        if (hr < 0) return error.CreatePseudoConsoleFailed;
        errdefer ClosePseudoConsole(hpc);

        // Build the proc-thread attribute list with the pseudoconsole attached.
        var attr_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
        const attr_list = try alloc.alignedAlloc(u8, .@"16", attr_size);
        errdefer alloc.free(attr_list);
        if (InitializeProcThreadAttributeList(attr_list.ptr, 1, 0, &attr_size) == FALSE)
            return error.InitAttrListFailed;
        errdefer DeleteProcThreadAttributeList(attr_list.ptr);
        if (UpdateProcThreadAttribute(attr_list.ptr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, @sizeOf(HPCON), null, null) == FALSE)
            return error.UpdateAttrFailed;

        // Pick a shell. Honor %COMSPEC%, fall back to cmd.exe.
        var cmdline_buf: [windows.MAX_PATH + 16]u16 = undefined;
        const cmdline_ptr: [*:0]u16 = @ptrCast(&cmdline_buf);
        const cmdline_len = blk: {
            const env = std.unicode.utf8ToUtf16LeStringLiteral("COMSPEC");
            const n = GetEnvironmentVariableW(env, cmdline_ptr, cmdline_buf.len);
            if (n > 0 and n < cmdline_buf.len) break :blk @as(usize, n);
            const fallback = std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");
            @memcpy(cmdline_buf[0..fallback.len], fallback);
            break :blk fallback.len;
        };
        cmdline_buf[cmdline_len] = 0;

        var si: STARTUPINFOEXW = std.mem.zeroes(STARTUPINFOEXW);
        si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
        si.lpAttributeList = attr_list.ptr;
        var pi: PROCESS_INFORMATION = std.mem.zeroes(PROCESS_INFORMATION);

        if (CreateProcessW(null, cmdline_ptr, null, null, FALSE, EXTENDED_STARTUPINFO_PRESENT, null, null, @ptrCast(&si), &pi) == FALSE)
            return error.CreateProcessFailed;

        const self = try alloc.create(Pty);
        self.* = .{
            .alloc = alloc,
            .hpc = hpc,
            .in_write = in_write,
            .out_read = out_read,
            .proc = pi,
            .attr_list = attr_list,
        };
        return self;
    }

    pub fn deinit(self: *Pty) void {
        // Closing the pseudoconsole signals the child + flushes the pipes,
        // which unblocks any reader thread sitting on the out_read pipe.
        ClosePseudoConsole(self.hpc);
        _ = windows.CloseHandle(self.in_write);
        _ = windows.CloseHandle(self.out_read);
        _ = windows.CloseHandle(self.proc.hProcess);
        _ = windows.CloseHandle(self.proc.hThread);
        DeleteProcThreadAttributeList(self.attr_list.ptr);
        self.alloc.free(self.attr_list);
        self.alloc.destroy(self);
    }

    pub fn write(self: *Pty, data: []const u8) !usize {
        var n: DWORD = 0;
        if (WriteFile(self.in_write, data.ptr, @intCast(data.len), &n, null) == FALSE)
            return error.WriteFailed;
        return n;
    }

    pub fn read(self: *Pty, buf: []u8) !usize {
        var n: DWORD = 0;
        if (ReadFile(self.out_read, buf.ptr, @intCast(buf.len), &n, null) == FALSE)
            return 0; // EOF / pipe closed
        return n;
    }

    pub fn resize(self: *Pty, size: PtySize) !void {
        const coord: COORD = .{ .X = @intCast(size.cols), .Y = @intCast(size.rows) };
        const hr = ResizePseudoConsole(self.hpc, coord);
        if (hr < 0) return error.ResizeFailed;
    }
};

// Kept for the older skeleton call site; redirects to the new path so the
// build doesn't break while we transition.
pub fn runEchoProof() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const pty = try Pty.start(alloc, .{ .cols = 120, .rows = 30 });
    defer pty.deinit();

    _ = try pty.write("echo Hello from Ghostty win32 apprt\r");
    _ = try pty.write("exit\r");

    var buf: [4096]u8 = undefined;
    const stdout = GetStdHandle(STD_OUTPUT_HANDLE);
    while (true) {
        const n = pty.read(&buf) catch break;
        if (n == 0) break;
        var written: DWORD = 0;
        _ = WriteFile(stdout, &buf, @intCast(n), &written, null);
    }
}
