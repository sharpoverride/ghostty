//! Top-level parent window that hosts one or more Surface tabs as child
//! HWNDs. Owns the title bar, taskbar icon, tab strip chrome, and the
//! per-process message pump. Each Surface owns its own child HWND
//! embedded in the parent's client area; tab switching is just
//! ShowWindow(SW_SHOW)/SW_HIDE on the children.
//!
//! Today: tab strip is a placeholder header band (no rendering yet); we
//! only host a single Surface so the existing single-tab UX is preserved
//! while the new layering is exercised end-to-end. Multi-tab UI lands in
//! a follow-up commit on top of this scaffolding.

const Self = @This();

const std = @import("std");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;
const Surface = @import("Surface.zig");
const ApprtApp = @import("App.zig");

const HWND = windows.HWND;
const HINSTANCE = windows.HINSTANCE;
const HICON = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const HMODULE = windows.HMODULE;
const DWORD = windows.DWORD;
const UINT = windows.UINT;
const WORD = windows.WORD;
const BOOL = windows.BOOL;
const LRESULT = windows.LRESULT;
const LPARAM = windows.LPARAM;
const WPARAM = windows.WPARAM;
const ATOM = WORD;
const LPCWSTR = windows.LPCWSTR;
const LPVOID = ?*anyopaque;
const TRUE = windows.TRUE;
const FALSE = windows.FALSE;

const log = std.log.scoped(.win32_parent);

// ---------------------------------------------------------------------------
// Win32 constants and structs.
// ---------------------------------------------------------------------------

const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
const WS_CLIPCHILDREN: DWORD = 0x02000000;
const WS_CLIPSIBLINGS: DWORD = 0x04000000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const CS_HREDRAW: UINT = 0x0002;
const CS_VREDRAW: UINT = 0x0001;
const SW_SHOWDEFAULT: i32 = 10;
const IDC_ARROW: usize = 32512;
const GWLP_USERDATA: i32 = -21;
const BLACK_BRUSH: i32 = 4;

const WM_DESTROY: UINT = 0x0002;
const WM_SIZE: UINT = 0x0005;
const WM_ACTIVATE: UINT = 0x0006;
const WM_CLOSE: UINT = 0x0010;
const WM_QUIT: UINT = 0x0012;
const WM_NCCREATE: UINT = 0x0081;
const WM_PAINT: UINT = 0x000F;
const WM_ERASEBKGND: UINT = 0x0014;
const WM_TIMER: UINT = 0x0113;
const WM_DPICHANGED: UINT = 0x02E0;

const WA_INACTIVE: u16 = 0;
const MONITOR_DEFAULTTONULL: DWORD = 0;
const AUTOHEAL_TIMER_ID: usize = 1;
/// Period for the auto-heal sweep (off-screen drift + focus mismatch).
const AUTOHEAL_INTERVAL_MS: UINT = 2_000;

const POINT = extern struct { x: i32, y: i32 };
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};

const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: HICON,
    hCursor: HCURSOR,
    hbrBackground: HBRUSH,
    lpszMenuName: ?LPCWSTR,
    lpszClassName: LPCWSTR,
    hIconSm: HICON,
};

extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) HMODULE;
extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: LPCWSTR,
    lpWindowName: LPCWSTR,
    dwStyle: DWORD,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?*anyopaque,
    hInstance: HINSTANCE,
    lpParam: LPVOID,
) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.winapi) BOOL;
extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: usize) callconv(.winapi) HCURSOR;
extern "user32" fn LoadIconW(hInstance: ?HINSTANCE, lpIconName: usize) callconv(.winapi) HICON;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.winapi) isize;
extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?HWND, X: i32, Y: i32, cx: i32, cy: i32, uFlags: UINT) callconv(.winapi) BOOL;
extern "user32" fn GetStockObject(i: i32) callconv(.winapi) HBRUSH;
extern "user32" fn SetFocus(hWnd: ?HWND) callconv(.winapi) ?HWND;
extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
extern "user32" fn MonitorFromWindow(hWnd: HWND, dwFlags: DWORD) callconv(.winapi) ?*anyopaque;
extern "user32" fn SetTimer(hWnd: HWND, nIDEvent: usize, uElapse: UINT, lpTimerFunc: ?*anyopaque) callconv(.winapi) usize;
extern "user32" fn KillTimer(hWnd: HWND, uIDEvent: usize) callconv(.winapi) BOOL;
extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: [*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn PostMessageW(hWnd: ?HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;

const WM_APP: UINT = 0x8000;
/// Title-set custom message: wparam = u16 length (incl. NUL terminator),
/// lparam = pointer (cast) to a c-allocator-owned UTF-16 buffer. The
/// WndProc takes ownership and frees.
const WM_APP_SET_TITLE: UINT = WM_APP + 1;

const SWP_NOZORDER: UINT = 0x0004;
const SWP_NOACTIVATE: UINT = 0x0010;
const SWP_SHOWWINDOW: UINT = 0x0040;

extern "user32" fn InvalidateRect(hWnd: ?HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Public API.
// ---------------------------------------------------------------------------

/// Reserved height at the top of the client area for the (future) tab
/// strip. Set to 0 today so the existing single-tab UX is visually
/// identical; the multi-tab UI will bump this and start drawing.
pub const tab_strip_height: i32 = 0;

alloc: Allocator,
app: *ApprtApp,
hwnd: HWND,
/// One Surface per tab. Active tab is shown via ShowWindow(SW_SHOW);
/// inactive tabs are SW_HIDE'd but their CoreSurface, ConPTY, and
/// renderer thread keep running so scrollback / shell state survive
/// switching.
tabs: std.array_list.Managed(*Surface),
active: usize = 0,

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWin32Parent");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");

pub fn create(alloc: Allocator, app: *ApprtApp) !*Self {
    const hmodule = GetModuleHandleW(null);
    const hinstance: HINSTANCE = @ptrFromInt(@intFromPtr(hmodule));

    var wc: WNDCLASSEXW = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    // CLIPCHILDREN: don't paint over child windows; the child's WGL
    // surface owns its rect. CS_HREDRAW/VREDRAW so the parent repaints
    // chrome on resize.
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinstance;
    wc.hCursor = LoadCursorW(null, IDC_ARROW);
    wc.hIcon = LoadIconW(hinstance, 1);
    wc.hIconSm = LoadIconW(hinstance, 1);
    wc.hbrBackground = GetStockObject(BLACK_BRUSH);
    wc.lpszClassName = class_name;
    _ = RegisterClassExW(&wc);

    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .app = app,
        .hwnd = undefined,
        .tabs = std.array_list.Managed(*Surface).init(alloc),
    };

    const hwnd = CreateWindowExW(
        0,
        class_name,
        window_title,
        WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        1024,
        640,
        null,
        null,
        hinstance,
        @ptrCast(self),
    ) orelse return error.CreateParentWindowFailed;
    self.hwnd = hwnd;

    _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @intCast(@intFromPtr(self)));
    _ = ShowWindow(hwnd, SW_SHOWDEFAULT);
    _ = UpdateWindow(hwnd);

    // Auto-heal timer: catches edge cases where the window drifts off
    // all monitors after a multi-monitor reconfiguration, or where the
    // active child loses focus while we're the foreground. Periodic
    // rather than reactive because the OS-level events that should
    // trigger fixes (WM_ACTIVATE, monitor change) don't always fire
    // reliably in cross-DPI / cross-monitor drag scenarios.
    _ = SetTimer(hwnd, AUTOHEAL_TIMER_ID, AUTOHEAL_INTERVAL_MS, null);

    return self;
}

pub fn deinit(self: *Self) void {
    _ = KillTimer(self.hwnd, AUTOHEAL_TIMER_ID);
    for (self.tabs.items) |s| s.deinit();
    self.tabs.deinit();
    self.alloc.destroy(self);
}

/// Periodic check for the two failure modes we've actually observed:
/// 1. Parent window center is off every monitor — usually after a
///    multi-monitor drag where the OS reported a position we accepted
///    but isn't reachable. Snap back to (100, 100).
/// 2. Parent has foreground activation but the active child doesn't
///    hold keyboard focus — input would silently go nowhere. SetFocus
///    on the active child.
fn autoHeal(self: *Self) void {
    // (1) off-screen
    if (MonitorFromWindow(self.hwnd, MONITOR_DEFAULTTONULL) == null) {
        log.warn("auto-heal: window has no monitor overlap, snapping to (100,100)", .{});
        var r: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = GetClientRect(self.hwnd, &r);
        const w = @max(800, r.right - r.left);
        const h = @max(600, r.bottom - r.top);
        _ = SetWindowPos(self.hwnd, null, 100, 100, w, h, SWP_NOZORDER);
    }

    // (2) focus mismatch
    if (GetForegroundWindow() == self.hwnd) {
        if (self.activeSurface()) |s| {
            if (GetFocus() != s.window.hwnd) {
                log.warn("auto-heal: foreground but child unfocused, restoring", .{});
                _ = SetFocus(s.window.hwnd);
            }
        }
    }
}

/// Active surface getter — returns the currently visible tab, or null
/// if there are no tabs (transient state during teardown).
pub fn activeSurface(self: *const Self) ?*Surface {
    if (self.tabs.items.len == 0) return null;
    return self.tabs.items[self.active];
}

/// Append a Surface as a new tab and switch focus to it. Caller
/// transfers ownership; ParentWindow's deinit will drop the Surface.
pub fn appendTab(self: *Self, surface: *Surface) !void {
    try self.tabs.append(surface);
    // Hide all the others, show the new one.
    self.active = self.tabs.items.len - 1;
    self.applyActiveVisibility();
    self.layoutActive();
}

/// Spawn a brand-new tab from scratch and switch to it.
pub fn newTab(self: *Self) !void {
    const surface = try Surface.create(self.alloc, self.app, @ptrCast(self.hwnd));
    errdefer surface.deinit();
    try self.appendTab(surface);
}

/// Close a tab by index. Closing the last tab tears down the window.
pub fn closeTab(self: *Self, idx: usize) void {
    if (idx >= self.tabs.items.len) return;
    const surface = self.tabs.orderedRemove(idx);
    surface.deinit();

    if (self.tabs.items.len == 0) {
        // Last tab gone — close the window.
        PostQuitMessage(0);
        return;
    }

    // Adjust active index and re-show.
    if (self.active >= self.tabs.items.len) {
        self.active = self.tabs.items.len - 1;
    } else if (self.active > idx) {
        self.active -= 1;
    }
    self.applyActiveVisibility();
    self.layoutActive();
}

/// Switch the active tab to `idx`.
pub fn switchTab(self: *Self, idx: usize) void {
    if (idx >= self.tabs.items.len or idx == self.active) return;
    self.active = idx;
    self.applyActiveVisibility();
    self.layoutActive();
}

/// Set the top-level window's title bar text from a UTF-8 string.
/// Thread-safe: posts a custom message to the UI thread which does the
/// SetWindowTextW call. Buffer ownership transfers to the message.
pub fn setTitle(self: *const Self, title: []const u8) !void {
    const alloc = std.heap.c_allocator;
    var buf = try alloc.alloc(u16, title.len + 1);
    errdefer alloc.free(buf);
    const written = try std.unicode.utf8ToUtf16Le(buf, title);
    buf[written] = 0;
    const ptr_lparam: LPARAM = @bitCast(@as(usize, @intFromPtr(buf.ptr)));
    const len_wparam: WPARAM = @intCast(buf.len);
    if (PostMessageW(self.hwnd, WM_APP_SET_TITLE, len_wparam, ptr_lparam) == FALSE) {
        alloc.free(buf);
        return;
    }
}

/// Cycle to the next (offset=+1) or previous (offset=-1) tab.
pub fn cycleTab(self: *Self, offset: i32) void {
    if (self.tabs.items.len < 2) return;
    const n: i32 = @intCast(self.tabs.items.len);
    const cur: i32 = @intCast(self.active);
    var next: i32 = @mod(cur + offset, n);
    if (next < 0) next += n;
    self.switchTab(@intCast(next));
}

/// Hide every inactive child, show + focus the active one.
fn applyActiveVisibility(self: *Self) void {
    for (self.tabs.items, 0..) |s, i| {
        const cmd: i32 = if (i == self.active) 5 else 0; // SW_SHOW vs SW_HIDE
        _ = ShowWindow(s.window.hwnd, cmd);
    }
    if (self.activeSurface()) |active| {
        _ = SetFocus(active.window.hwnd);
    }
}

/// Resize the active tab's child HWND to fill the client area below the
/// tab strip. Invoked on WM_SIZE and on first attach / tab switch.
fn layoutActive(self: *Self) void {
    const surface = self.activeSurface() orelse return;
    var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = GetClientRect(self.hwnd, &rect);
    const w = @max(0, rect.right - rect.left);
    const h = @max(0, rect.bottom - rect.top - tab_strip_height);
    _ = SetWindowPos(
        surface.window.hwnd,
        null,
        0,
        tab_strip_height,
        w,
        h,
        SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW,
    );
    _ = InvalidateRect(surface.window.hwnd, null, FALSE);
}

/// Run the win32 message pump until WM_QUIT.
pub fn run(self: *Self) !void {
    _ = self;
    log.info("ParentWindow.run: message pump start", .{});
    defer log.info("ParentWindow.run: message pump end", .{});
    var msg: MSG = undefined;
    while (true) {
        const r = GetMessageW(&msg, null, 0, 0);
        if (r == 0) break;
        if (r == -1) return error.GetMessageFailed;
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

// ---------------------------------------------------------------------------
// WndProc.
// ---------------------------------------------------------------------------

fn recoverSelf(hwnd: HWND) ?*Self {
    const p = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (p == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(p)));
}

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_SIZE => {
            if (recoverSelf(hwnd)) |self| self.layoutActive();
        },
        WM_DPICHANGED => {
            // lparam points to the OS-suggested RECT for the new DPI.
            // Honoring it verbatim is what Windows Terminal does (see
            // BaseWindow.h::HandleDpiChange). Without this the window
            // tends to drift between monitors during cross-DPI drag and
            // can land off-screen.
            const suggested: *const RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
            return 0;
        },
        WM_TIMER => {
            if (wparam == AUTOHEAL_TIMER_ID) {
                if (recoverSelf(hwnd)) |self| self.autoHeal();
                return 0;
            }
        },
        WM_APP_SET_TITLE => {
            const len: usize = @intCast(wparam);
            const ptr_int: usize = @bitCast(lparam);
            if (ptr_int != 0 and len > 0) {
                const ptr: [*]u16 = @ptrFromInt(ptr_int);
                _ = SetWindowTextW(hwnd, @ptrCast(ptr));
                std.heap.c_allocator.free(ptr[0..len]);
            }
            return 0;
        },
        WM_ACTIVATE => {
            // Restore focus to the active child on activation — but only
            // if it doesn't already have it. Unconditionally calling
            // SetFocus on every WM_ACTIVATE causes redundant KILLFOCUS/
            // SETFOCUS cycles that the engine treats as real focus
            // transitions, leading to focus-event spam and apparent
            // input loss during rapid alt-tab.
            const active_lo: u16 = @intCast(wparam & 0xFFFF);
            if (active_lo != WA_INACTIVE) {
                if (recoverSelf(hwnd)) |self| {
                    if (self.activeSurface()) |s| {
                        if (GetFocus() != s.window.hwnd) _ = SetFocus(s.window.hwnd);
                    }
                }
            }
        },
        WM_CLOSE, WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}
