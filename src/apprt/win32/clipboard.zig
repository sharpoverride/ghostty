//! Win32 clipboard glue for the win32 apprt. Handles the CF_UNICODETEXT
//! format (UTF-16) and converts to/from UTF-8 for engine consumption.
//!
//! Clipboard access on Windows is synchronous — OpenClipboard takes a lock
//! shared with all other apps, so we keep our holding window as short as
//! possible (open → read/write → close, no callbacks between).

const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;

const HWND = windows.HWND;
const HANDLE = windows.HANDLE;
const HGLOBAL = ?*anyopaque;
const BOOL = windows.BOOL;
const TRUE = windows.TRUE;
const FALSE = windows.FALSE;
const UINT = windows.UINT;

const CF_UNICODETEXT: UINT = 13;
const GMEM_MOVEABLE: UINT = 0x0002;

extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.winapi) BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.winapi) ?HANDLE;
extern "user32" fn SetClipboardData(uFormat: UINT, hMem: HGLOBAL) callconv(.winapi) ?HANDLE;
extern "user32" fn IsClipboardFormatAvailable(format: UINT) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.winapi) HGLOBAL;
extern "kernel32" fn GlobalFree(hMem: HGLOBAL) callconv(.winapi) HGLOBAL;
extern "kernel32" fn GlobalLock(hMem: HGLOBAL) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: HGLOBAL) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalSize(hMem: HGLOBAL) callconv(.winapi) usize;

/// Read clipboard text as a freshly-allocated UTF-8 sentinel-terminated
/// string. Returns null if the clipboard has no text content or if access
/// fails (another app holds the clipboard lock — retrying is the caller's
/// call to make). Caller owns the returned bytes.
pub fn getText(alloc: Allocator, owner: ?HWND) !?[:0]u8 {
    if (IsClipboardFormatAvailable(CF_UNICODETEXT) == FALSE) return null;
    if (OpenClipboard(owner) == FALSE) return null;
    defer _ = CloseClipboard();

    const handle = GetClipboardData(CF_UNICODETEXT) orelse return null;
    const ptr = GlobalLock(handle) orelse return null;
    defer _ = GlobalUnlock(handle);

    // CF_UNICODETEXT is a null-terminated UTF-16 string. Scan for the
    // null so we can size the conversion exactly.
    const wide_ptr: [*]const u16 = @ptrCast(@alignCast(ptr));
    var len: usize = 0;
    while (wide_ptr[len] != 0) : (len += 1) {}
    if (len == 0) return try alloc.allocSentinel(u8, 0, 0);

    // Allocate UTF-8 — worst case is 3 bytes per BMP code unit, 4 per
    // surrogate pair. 4 bytes per code unit upper-bounds either.
    const buf = try alloc.alloc(u8, len * 4);
    errdefer alloc.free(buf);
    const written = std.unicode.utf16LeToUtf8(buf, wide_ptr[0..len]) catch return null;
    // Shrink to actual size + sentinel.
    const out = try alloc.allocSentinel(u8, written, 0);
    @memcpy(out, buf[0..written]);
    alloc.free(buf);
    return out;
}

/// Set clipboard text from a UTF-8 string. Empties the existing clipboard
/// content first, then installs CF_UNICODETEXT with our converted UTF-16.
pub fn setText(text: []const u8, owner: ?HWND) !void {
    if (OpenClipboard(owner) == FALSE) return error.OpenClipboardFailed;
    defer _ = CloseClipboard();
    _ = EmptyClipboard();

    // UTF-16 length upper bound: each UTF-8 byte becomes at most one
    // UTF-16 code unit (ASCII), at most ~1 unit per byte for BMP, and
    // worst case 2 units per 4 UTF-8 bytes for supplementary planes.
    // +1 for null terminator.
    const wide_cap = text.len + 1;
    const byte_cap = wide_cap * @sizeOf(u16);

    const handle = GlobalAlloc(GMEM_MOVEABLE, byte_cap) orelse return error.GlobalAllocFailed;
    errdefer _ = GlobalFree(handle);

    {
        const ptr = GlobalLock(handle) orelse return error.GlobalLockFailed;
        defer _ = GlobalUnlock(handle);
        const wide_ptr: [*]u16 = @ptrCast(@alignCast(ptr));
        const written = std.unicode.utf8ToUtf16Le(wide_ptr[0..wide_cap], text) catch
            return error.Utf8ToUtf16Failed;
        wide_ptr[written] = 0; // null-terminate
    }

    // Ownership transfers to the clipboard on success — don't free the
    // handle. On failure, the errdefer above runs.
    if (SetClipboardData(CF_UNICODETEXT, handle) == null) return error.SetClipboardDataFailed;
}
