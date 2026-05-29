//! Quick Win32 tool to change a window's title.
//!
//! Usage:
//!   set_title "New title"                 -> targets class "GhosttyWin32Parent"
//!   set_title --class <classname> "Title"
//!   set_title --hwnd  <hex|dec>   "Title"
//!
//! Build:
//!   zig build-exe tools/set_title.zig -target x86_64-windows -O ReleaseSmall
//!
//! Run it while Ghostty is open and the title bar should flip instantly.

const std = @import("std");

const windows = std.os.windows;
const HWND = windows.HWND;
const BOOL = windows.BOOL;
const LPCWSTR = windows.LPCWSTR;

extern "user32" fn FindWindowW(lpClassName: ?LPCWSTR, lpWindowName: ?LPCWSTR) callconv(.winapi) ?HWND;
extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.winapi) BOOL;
extern "user32" fn IsWindow(hWnd: ?HWND) callconv(.winapi) BOOL;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    // The top-level Ghostty window is the tab-strip parent
    // (class "GhosttyWin32Parent"). The old "GhosttyWin32" class is
    // now a child surface and FindWindowW only finds top-level windows.
    var class_name: []const u8 = "GhosttyWin32Parent";
    var explicit_hwnd: ?usize = null;
    var title_utf8: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--class")) {
            i += 1;
            if (i >= args.len) return error.MissingClassArg;
            class_name = args[i];
        } else if (std.mem.eql(u8, a, "--hwnd")) {
            i += 1;
            if (i >= args.len) return error.MissingHwndArg;
            const s = args[i];
            const base: u8 = if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) 16 else 10;
            const sliced = if (base == 16) s[2..] else s;
            explicit_hwnd = try std.fmt.parseInt(usize, sliced, base);
        } else {
            title_utf8 = a;
        }
    }

    const title = title_utf8 orelse {
        std.debug.print("usage: set_title [--class <name>] [--hwnd <hex|dec>] \"new title\"\n", .{});
        return error.NoTitleProvided;
    };

    // UTF-8 -> UTF-16LE, null-terminated.
    const title_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, title);
    defer alloc.free(title_w);

    const hwnd: HWND = blk: {
        if (explicit_hwnd) |h| {
            const candidate: HWND = @ptrFromInt(h);
            if (IsWindow(candidate) == 0) {
                std.debug.print("hwnd 0x{X} is not a valid window\n", .{h});
                return error.InvalidHwnd;
            }
            break :blk candidate;
        }
        const class_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, class_name);
        defer alloc.free(class_w);
        const found = FindWindowW(class_w, null) orelse {
            std.debug.print("no window with class \"{s}\" found — is Ghostty running?\n", .{class_name});
            return error.WindowNotFound;
        };
        break :blk found;
    };

    if (SetWindowTextW(hwnd, title_w) == 0) {
        return error.SetWindowTextFailed;
    }

    std.debug.print("ok: hwnd=0x{X} title=\"{s}\"\n", .{ @intFromPtr(hwnd), title });
}
