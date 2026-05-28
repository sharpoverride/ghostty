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
/// Posted by a Surface (possibly from a non-UI thread, e.g. on child-process
/// exit) to request that its tab be closed on the UI thread. wparam carries
/// the *Surface pointer.
const WM_APP_CLOSE_SURFACE: UINT = WM_APP + 2;
/// Posted by App.wakeup (the engine's "process your mailbox" signal, possibly
/// from another thread) to drain the core app mailbox on the UI thread. This
/// is how surface messages like child_exited actually get handled.
const WM_APP_TICK: UINT = WM_APP + 3;
/// Posted to set a Surface's tab title from a non-UI thread (set_title may
/// come from the engine/IO thread). wparam carries a heap-allocated
/// TabTitleMsg whose ownership the handler takes.
const WM_APP_SET_TAB_TITLE: UINT = WM_APP + 4;
const TabTitleMsg = struct { surface: *Surface, title: []u8 };

const SWP_NOZORDER: UINT = 0x0004;
const SWP_NOACTIVATE: UINT = 0x0010;
const SWP_SHOWWINDOW: UINT = 0x0040;

extern "user32" fn InvalidateRect(hWnd: ?HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;

// GDI bits for drawing the tab strip.
const HDC = *anyopaque;
const COLORREF = u32;
const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_SETTEXT: UINT = 0x000C;
const TRANSPARENT: i32 = 1;
const DT_LEFT: UINT = 0x0000;
const DT_CENTER: UINT = 0x0001;
const DT_VCENTER: UINT = 0x0004;
const DT_SINGLELINE: UINT = 0x0020;
const DT_END_ELLIPSIS: UINT = 0x8000;
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) ?HDC;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn FillRect(hDC: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(.winapi) i32;
extern "user32" fn DrawTextW(hdc: HDC, lpchText: [*]const u16, cchText: i32, lprc: *RECT, format: UINT) callconv(.winapi) i32;
extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) UINT;
extern "gdi32" fn CreateSolidBrush(color: COLORREF) callconv(.winapi) HBRUSH;
extern "gdi32" fn DeleteObject(ho: ?*anyopaque) callconv(.winapi) BOOL;
extern "gdi32" fn SetBkMode(hdc: HDC, mode: i32) callconv(.winapi) i32;
extern "gdi32" fn SetTextColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
extern "gdi32" fn SelectObject(hdc: HDC, h: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn CreateRoundRectRgn(left: i32, top: i32, right: i32, bottom: i32, w: i32, h: i32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn FillRgn(hdc: HDC, hrgn: ?*anyopaque, hbr: HBRUSH) callconv(.winapi) BOOL;
extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.winapi) ?HDC;
extern "gdi32" fn CreateCompatibleBitmap(hdc: HDC, cx: i32, cy: i32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) BOOL;
extern "gdi32" fn BitBlt(hdc: HDC, x: i32, y: i32, cx: i32, cy: i32, hdc_src: HDC, x1: i32, y1: i32, rop: DWORD) callconv(.winapi) BOOL;
const SRCCOPY: DWORD = 0x00CC0020;
extern "gdi32" fn CreateFontW(
    nHeight: i32, nWidth: i32, nEscapement: i32, nOrientation: i32,
    fnWeight: i32, fdwItalic: DWORD, fdwUnderline: DWORD, fdwStrikeOut: DWORD,
    fdwCharSet: DWORD, fdwOutputPrecision: DWORD, fdwClipPrecision: DWORD,
    fdwQuality: DWORD, fdwPitchAndFamily: DWORD, lpszFace: [*:0]const u16,
) callconv(.winapi) ?*anyopaque;
const FW_NORMAL: i32 = 400;
const DEFAULT_CHARSET: DWORD = 1;
const CLEARTYPE_QUALITY: DWORD = 5;

// Tab strip geometry (logical px at 96 DPI; scaled by DPI at runtime).
const tab_strip_base: i32 = 32;
const tab_fixed_w_base: i32 = 180;
const arrow_w_base: i32 = 28;
const new_btn_w: i32 = 32;
const tab_close_w: i32 = 22;

// ---------------------------------------------------------------------------
// Public API.
// ---------------------------------------------------------------------------

/// (Re)create the cached Segoe UI font sized for the window's current DPI.
fn ensureTabFont(self: *Self) void {
    if (self.tab_font) |f| _ = DeleteObject(f);
    const dpi: i32 = @intCast(GetDpiForWindow(self.hwnd));
    // Negative height = character height (vs cell height); 12px @ 96 DPI.
    const h = -@divTrunc(12 * dpi, 96);
    const face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
    self.tab_font = CreateFontW(
        h, 0, 0, 0, FW_NORMAL, 0, 0, 0,
        DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0,
        face,
    );
}

/// Height of the tab strip at the top of the client area, DPI-scaled.
/// The active surface child is laid out below this band; the band itself is
/// painted (and hit-tested) by the parent.
fn stripHeight(self: *const Self) i32 {
    const dpi: i32 = @intCast(GetDpiForWindow(self.hwnd));
    return @divTrunc(tab_strip_base * dpi, 96);
}

alloc: Allocator,
app: *ApprtApp,
hwnd: HWND,
/// One Surface per tab. Active tab is shown via ShowWindow(SW_SHOW);
/// inactive tabs are SW_HIDE'd but their CoreSurface, ConPTY, and
/// renderer thread keep running so scrollback / shell state survive
/// switching.
tabs: std.array_list.Managed(*Surface),
active: usize = 0,
/// Cached Segoe UI font for the tab strip. Recreated on DPI change.
tab_font: ?*anyopaque = null,
/// Index of the first visible tab in the strip when there are too many tabs
/// to fit. Adjusted by the `<` / `>` overflow buttons and auto-scrolled to
/// keep the active tab in view.
tab_scroll: i32 = 0,

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
    self.ensureTabFont();

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
    if (self.tab_font) |f| _ = DeleteObject(f);
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

/// Request that the tab hosting `surface` be closed. Thread-safe: posts to
/// the UI thread, which finds the tab and tears it down (tab teardown joins
/// the renderer/IO threads and must not run on those threads). Used by
/// `Surface.close()` when the child shell exits.
pub fn requestCloseSurface(self: *const Self, surface: *Surface) void {
    _ = PostMessageW(self.hwnd, WM_APP_CLOSE_SURFACE, @intFromPtr(surface), 0);
}

/// Thread-safe: ask the UI thread to update `surface`'s tab title. The title
/// is duplicated; the handler frees the duplicate (and the wrapper struct)
/// after applying or if the surface has gone away.
pub fn requestSetTabTitle(self: *const Self, surface: *Surface, title: []const u8) void {
    const alloc = std.heap.c_allocator;
    const msg = alloc.create(TabTitleMsg) catch return;
    msg.title = alloc.dupe(u8, title) catch {
        alloc.destroy(msg);
        return;
    };
    msg.surface = surface;
    if (PostMessageW(self.hwnd, WM_APP_SET_TAB_TITLE, @intFromPtr(msg), 0) == FALSE) {
        alloc.free(msg.title);
        alloc.destroy(msg);
    }
}

/// Thread-safe: ask the UI thread to drain the core app mailbox. Called by
/// App.wakeup, which the engine invokes whenever it pushes a surface/app
/// message (e.g. child_exited).
pub fn requestTick(self: *const Self) void {
    _ = PostMessageW(self.hwnd, WM_APP_TICK, 0, 0);
}

/// Drain the core app mailbox (dispatches surface messages to handleMessage).
/// Must run on the UI thread.
fn tickCoreApp(self: *Self) void {
    self.app.core_app.tick(self.app) catch |err|
        log.warn("core app tick failed: {}", .{err});
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
    // Auto-scroll so the active tab is in view (also re-clamps scroll on
    // resize/tab-removal).
    self.ensureActiveVisible();
    const strip = self.stripHeight();
    var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = GetClientRect(self.hwnd, &rect);
    const w = @max(0, rect.right - rect.left);
    const h = @max(0, rect.bottom - rect.top - strip);
    _ = SetWindowPos(
        surface.window.hwnd,
        null,
        0,
        strip,
        w,
        h,
        SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW,
    );
    _ = InvalidateRect(surface.window.hwnd, null, FALSE);
    // Repaint the strip band (tab count/active may have changed).
    self.invalidateStrip();
}

/// Mark the tab-strip band dirty so it repaints.
fn invalidateStrip(self: *const Self) void {
    var r: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = self.stripHeight() };
    _ = GetClientRect(self.hwnd, &r);
    r.top = 0;
    r.bottom = self.stripHeight();
    _ = InvalidateRect(self.hwnd, &r, FALSE);
}

/// Layout of the tab strip for a given client width. Computed once per paint
/// or hit-test so both stay in sync.
const StripLayout = struct {
    tw: i32, // tab width (fixed)
    aw: i32, // arrow button width
    bw: i32, // "+" button width
    n: i32, // total tab count
    visible_count: i32, // how many tabs fit
    show_arrows: bool,
    tabs_right: i32, // x of right edge of the visible-tabs area
    x_lt: i32 = 0,
    x_gt: i32 = 0,
    x_plus: i32 = 0,
};

fn computeStripLayout(self: *Self, width: i32) StripLayout {
    const dpi: i32 = @intCast(GetDpiForWindow(self.hwnd));
    const tw = @divTrunc(tab_fixed_w_base * dpi, 96);
    const aw = @divTrunc(arrow_w_base * dpi, 96);
    const bw = @divTrunc(new_btn_w * dpi, 96);
    const n: i32 = @intCast(self.tabs.items.len);
    var L: StripLayout = .{
        .tw = tw, .aw = aw, .bw = bw, .n = n,
        .visible_count = 0,
        .show_arrows = false,
        .tabs_right = 0,
    };
    if (n == 0) {
        L.x_plus = 0;
        return L;
    }
    if (n * tw + bw <= width) {
        // Everything fits, no scrolling needed.
        L.visible_count = n;
        L.tabs_right = n * tw;
        L.x_plus = L.tabs_right;
    } else {
        // Overflow: reserve right side for arrows + plus.
        L.show_arrows = true;
        const tabs_area_w = @max(0, width - 2 * aw - bw);
        L.visible_count = @max(1, @divTrunc(tabs_area_w, tw));
        L.tabs_right = L.visible_count * tw;
        L.x_lt = L.tabs_right;
        L.x_gt = L.x_lt + aw;
        L.x_plus = L.x_gt + aw;
    }
    // Clamp scroll to [0, n - visible_count].
    const max_scroll = @max(0, n - L.visible_count);
    if (self.tab_scroll > max_scroll) self.tab_scroll = max_scroll;
    if (self.tab_scroll < 0) self.tab_scroll = 0;
    return L;
}

/// Adjust `tab_scroll` so the active tab is visible.
fn ensureActiveVisible(self: *Self) void {
    var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = GetClientRect(self.hwnd, &rect);
    const L = self.computeStripLayout(rect.right);
    const active: i32 = @intCast(self.active);
    if (active < self.tab_scroll) {
        self.tab_scroll = active;
    } else if (active >= self.tab_scroll + L.visible_count) {
        self.tab_scroll = active - L.visible_count + 1;
    }
}

/// Paint the tab strip. Called from WM_PAINT.
fn paintTabStrip(self: *Self, hdc: HDC, width: i32) void {
    const strip = self.stripHeight();
    const dpi: i32 = @intCast(GetDpiForWindow(self.hwnd));
    const radius = @max(6, @divTrunc(10 * dpi, 96));
    const pad_top = @max(3, @divTrunc(4 * dpi, 96));
    const close_w = @divTrunc(tab_close_w * dpi, 96);

    // Strip background.
    const strip_bg = CreateSolidBrush(0x002b2b2b);
    var full: RECT = .{ .left = 0, .top = 0, .right = width, .bottom = strip };
    _ = FillRect(hdc, &full, strip_bg);
    _ = DeleteObject(strip_bg);

    // Use the cached Segoe UI font; transparent text background. GDI font
    // linking falls back to Segoe UI Symbol / Segoe UI Emoji for glyphs the
    // base face lacks (monochrome — color emoji would need DirectWrite).
    if (self.tab_font) |f| _ = SelectObject(hdc, f);
    _ = SetBkMode(hdc, TRANSPARENT);

    const L = self.computeStripLayout(width);
    if (L.n == 0) return;

    // Draw the visible tab range starting at column 0 of the strip.
    var i: i32 = 0;
    while (i < L.visible_count) : (i += 1) {
        const tab_idx = i + self.tab_scroll;
        if (tab_idx < 0 or tab_idx >= L.n) break;
        const x = i * L.tw;
        const active = (@as(usize, @intCast(tab_idx)) == self.active);

        const tab_bg = CreateSolidBrush(if (active) 0x00181818 else 0x00333333);
        const rgn = CreateRoundRectRgn(x + 1, pad_top, x + L.tw - 1, strip + radius, radius * 2, radius * 2);
        if (rgn) |r| {
            _ = FillRgn(hdc, r, tab_bg);
            _ = DeleteObject(r);
        }
        _ = DeleteObject(tab_bg);

        // Title: per-tab if set (e.g. via OSC 2), else "Terminal N".
        var fbuf: [32]u8 = undefined;
        const surf = self.tabs.items[@intCast(tab_idx)];
        const label_utf8: []const u8 = if (surf.title) |t| t else (std.fmt.bufPrint(&fbuf, "Terminal {d}", .{tab_idx + 1}) catch "Terminal");
        var w16: [256]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&w16, label_utf8) catch w16.len;
        _ = SetTextColor(hdc, if (active) 0x00ffffff else 0x00aaaaaa);
        var lr: RECT = .{ .left = x + 14, .top = pad_top, .right = x + L.tw - close_w, .bottom = strip };
        _ = DrawTextW(hdc, &w16, @intCast(wlen), &lr, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);

        // Close "×".
        _ = SetTextColor(hdc, if (active) 0x00cccccc else 0x00888888);
        var cr: RECT = .{ .left = x + L.tw - close_w, .top = pad_top, .right = x + L.tw - 4, .bottom = strip };
        const x_glyph = [_]u16{0x00D7};
        _ = DrawTextW(hdc, &x_glyph, 1, &cr, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }

    // Overflow arrows (only if we don't fit). Greyed out when the action
    // they trigger is a no-op (already at the edge).
    if (L.show_arrows) {
        const lt_enabled = self.tab_scroll > 0;
        const gt_enabled = self.tab_scroll + L.visible_count < L.n;
        _ = SetTextColor(hdc, if (lt_enabled) 0x00cccccc else 0x00555555);
        var lr: RECT = .{ .left = L.x_lt, .top = pad_top, .right = L.x_lt + L.aw, .bottom = strip };
        const lt_glyph = [_]u16{0x2039}; // U+2039 SINGLE LEFT-POINTING ANGLE QUOTATION MARK
        _ = DrawTextW(hdc, &lt_glyph, 1, &lr, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        _ = SetTextColor(hdc, if (gt_enabled) 0x00cccccc else 0x00555555);
        var gr: RECT = .{ .left = L.x_gt, .top = pad_top, .right = L.x_gt + L.aw, .bottom = strip };
        const gt_glyph = [_]u16{0x203A}; // U+203A SINGLE RIGHT-POINTING ANGLE QUOTATION MARK
        _ = DrawTextW(hdc, &gt_glyph, 1, &gr, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }

    // New-tab "+".
    _ = SetTextColor(hdc, 0x00cccccc);
    var pr: RECT = .{ .left = L.x_plus, .top = pad_top, .right = L.x_plus + L.bw, .bottom = strip };
    const plus = [_]u16{'+'};
    _ = DrawTextW(hdc, &plus, 1, &pr, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

/// Handle a left-click in the tab strip. Returns true if it was handled.
fn onStripClick(self: *Self, x: i32, y: i32) bool {
    if (y < 0 or y >= self.stripHeight()) return false;
    var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = GetClientRect(self.hwnd, &rect);
    const L = self.computeStripLayout(rect.right);
    if (L.n == 0) return false;

    // Right-side widgets (when overflow): <, >, +.
    if (L.show_arrows) {
        if (x >= L.x_lt and x < L.x_gt) {
            if (self.tab_scroll > 0) self.tab_scroll -= 1;
            return true;
        }
        if (x >= L.x_gt and x < L.x_plus) {
            if (self.tab_scroll + L.visible_count < L.n) self.tab_scroll += 1;
            return true;
        }
    }
    if (x >= L.x_plus and x < L.x_plus + L.bw) {
        self.newTab() catch |e| log.warn("newTab failed: {}", .{e});
        return true;
    }

    // Tab body.
    if (x < 0 or x >= L.tabs_right or L.tw <= 0) return false;
    const visible_i = @divTrunc(x, L.tw);
    const tab_idx = visible_i + self.tab_scroll;
    if (tab_idx < 0 or tab_idx >= L.n) return false;

    const dpi: i32 = @intCast(GetDpiForWindow(self.hwnd));
    const close_w = @divTrunc(tab_close_w * dpi, 96);
    const x_in_tab = x - visible_i * L.tw;
    if (x_in_tab >= L.tw - close_w) {
        self.closeTab(@intCast(tab_idx));
    } else {
        self.switchTab(@intCast(tab_idx));
    }
    return true;
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
        WM_SETTEXT => {
            // External callers (e.g. tools/set_title.exe) set the window
            // caption to express "title this terminal". Mirror that into
            // the ACTIVE tab's title so the strip shows it. We still fall
            // through to DefWindowProcW so the actual caption updates too
            // (the heartbeat will overwrite it shortly with "Ghostty - FPS").
            if (recoverSelf(hwnd)) |self| settext: {
                const surf = self.activeSurface() orelse break :settext;
                if (lparam == 0) break :settext;
                const wptr: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lparam)));
                var wlen: usize = 0;
                while (wptr[wlen] != 0) : (wlen += 1) {}
                // Filter out our own watchdog/FPS heartbeat string so it
                // doesn't pollute tab titles every 2s — that path sets the
                // OS caption (which it still gets to do via DefWindowProc),
                // but we only want the tab to reflect explicit titles.
                const heartbeat = comptime std.unicode.utf8ToUtf16LeStringLiteral("Ghostty - FPS=");
                if (wlen >= heartbeat.len) {
                    var matches = true;
                    for (heartbeat[0..heartbeat.len], 0..) |c, i| {
                        if (wptr[i] != c) { matches = false; break; }
                    }
                    if (matches) break :settext;
                }
                var ubuf: [512]u8 = undefined;
                const ulen = std.unicode.utf16LeToUtf8(&ubuf, wptr[0..wlen]) catch break :settext;
                if (ulen == 0) break :settext;
                const alloc = std.heap.c_allocator;
                const dup = alloc.dupe(u8, ubuf[0..ulen]) catch break :settext;
                if (surf.title) |old| alloc.free(old);
                surf.title = dup;
                self.invalidateStrip();
            }
            // Fall through so DefWindowProcW also sets the OS caption.
        },
        WM_ERASEBKGND => {
            // We paint the strip ourselves (and child windows cover the rest
            // under WS_CLIPCHILDREN); suppressing the OS erase removes the
            // flash-of-class-brush that causes flicker before WM_PAINT.
            return 1;
        },
        WM_PAINT => {
            if (recoverSelf(hwnd)) |self| {
                var ps: PAINTSTRUCT = undefined;
                if (BeginPaint(hwnd, &ps)) |hdc| {
                    var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
                    _ = GetClientRect(hwnd, &rect);
                    const strip_h = self.stripHeight();
                    const w = rect.right;
                    // Double-buffer: paint into an off-screen DC, then blit
                    // once — no visible erase/repaint flicker as tab titles
                    // update on heartbeat / OSC 2.
                    if (CreateCompatibleDC(hdc)) |mem_dc| {
                        if (CreateCompatibleBitmap(hdc, w, strip_h)) |mem_bmp| {
                            const old = SelectObject(mem_dc, mem_bmp);
                            self.paintTabStrip(mem_dc, w);
                            _ = BitBlt(hdc, 0, 0, w, strip_h, mem_dc, 0, 0, SRCCOPY);
                            _ = SelectObject(mem_dc, old);
                            _ = DeleteObject(mem_bmp);
                        } else {
                            self.paintTabStrip(hdc, w);
                        }
                        _ = DeleteDC(mem_dc);
                    } else {
                        self.paintTabStrip(hdc, w);
                    }
                    _ = EndPaint(hwnd, &ps);
                }
            }
            return 0;
        },
        WM_LBUTTONDOWN => {
            if (recoverSelf(hwnd)) |self| {
                const x: i32 = @as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF))));
                const y: i32 = @as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF))));
                if (self.onStripClick(x, y)) {
                    self.invalidateStrip();
                    return 0;
                }
            }
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
            // Re-create the tab strip font for the new DPI.
            if (recoverSelf(hwnd)) |self| self.ensureTabFont();
            return 0;
        },
        WM_TIMER => {
            if (wparam == AUTOHEAL_TIMER_ID) {
                if (recoverSelf(hwnd)) |self| {
                    self.autoHeal();
                    // Fallback mailbox drain in case a wakeup was missed.
                    self.tickCoreApp();
                }
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
        WM_APP_TICK => {
            if (recoverSelf(hwnd)) |self| self.tickCoreApp();
            return 0;
        },
        WM_APP_SET_TAB_TITLE => {
            const alloc = std.heap.c_allocator;
            const tt: *TabTitleMsg = @ptrFromInt(wparam);
            var applied = false;
            if (recoverSelf(hwnd)) |self| {
                for (self.tabs.items) |s| {
                    if (s == tt.surface) {
                        if (s.title) |old| alloc.free(old);
                        s.title = tt.title;
                        applied = true;
                        self.invalidateStrip();
                        break;
                    }
                }
            }
            if (!applied) alloc.free(tt.title);
            alloc.destroy(tt);
            return 0;
        },
        WM_APP_CLOSE_SURFACE => {
            // A surface asked to close (typically its shell exited). Find the
            // matching tab and close it; closeTab tears down the window if it
            // was the last tab.
            const ptr_int: usize = @intCast(wparam);
            if (ptr_int != 0) {
                if (recoverSelf(hwnd)) |self| {
                    const surface: *Surface = @ptrFromInt(ptr_int);
                    for (self.tabs.items, 0..) |s, i| {
                        if (s == surface) {
                            self.closeTab(i);
                            break;
                        }
                    }
                }
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
