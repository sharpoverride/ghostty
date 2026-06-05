//! A browser tab's content: a host child HWND (parented to the chrome
//! window) with a URL bar (native EDIT control) on top and a WebView2
//! instance filling the rest. Mirrors how a terminal `Surface` owns a child
//! HWND, so the chrome's tab machinery (show/hide/layout/close) treats both
//! uniformly — switching to a browser tab hides the terminal via the same
//! applyActiveVisibility loop, no special-casing or z-order tricks.
//!
//! Navigation: type in the bar, Enter navigates (https:// is assumed when
//! no scheme is given) and focus moves into the page. The bar tracks
//! committed navigations (SourceChanged) unless it's being edited, and the
//! page's document title becomes the tab title unless the user pinned a
//! rename.
const Self = @This();

const std = @import("std");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;
const webview2 = @import("webview2.zig");

const HWND = windows.HWND;
const HINSTANCE = windows.HINSTANCE;
const HMENU = ?*anyopaque;
const DWORD = windows.DWORD;
const LPVOID = ?*anyopaque;
const WPARAM = windows.WPARAM;
const LPARAM = windows.LPARAM;
const LRESULT = windows.LRESULT;
const UINT = windows.UINT;
const BOOL = windows.BOOL;
const HDC = windows.HDC;
const HFONT = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const COLORREF = DWORD;
const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const log = std.log.scoped(.win32_browser);

const WS_CHILD: DWORD = 0x40000000;
const WS_CLIPSIBLINGS: DWORD = 0x04000000;
const WS_CLIPCHILDREN: DWORD = 0x02000000;
const WS_VISIBLE: DWORD = 0x10000000;
const ES_AUTOHSCROLL: DWORD = 0x0080;

const WM_SETFOCUS: UINT = 0x0007;
const WM_KEYDOWN: UINT = 0x0100;
const WM_CHAR: UINT = 0x0102;
const WM_SETFONT: UINT = 0x0030;
const WM_CTLCOLOREDIT: UINT = 0x0133;
const EM_SETMARGINS: UINT = 0x00D3;
const EC_LEFTMARGIN: WPARAM = 1;
const EC_RIGHTMARGIN: WPARAM = 2;

const VK_RETURN: WPARAM = 0x0D;
const VK_ESCAPE: WPARAM = 0x1B;
const VK_CONTROL_I: i32 = 0x11;
const VK_MENU_I: i32 = 0x12;
const EM_SETSEL: UINT = 0x00B1;

const GWLP_WNDPROC: i32 = -4;
const GWLP_USERDATA: i32 = -21;

/// URL bar height in DIPs; scaled by the host's DPI.
const bar_height_base: i32 = 34;

// Dark theme for the bar — matches the chrome's palette (COLORREF is BGR).
const bar_bg: COLORREF = 0x00242424;
const bar_text: COLORREF = 0x00E0E0E0;

extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: ?[*:0]const u16,
    lpWindowName: ?[*:0]const u16,
    dwStyle: DWORD,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: HMENU,
    hInstance: ?HINSTANCE,
    lpParam: LPVOID,
) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.winapi) isize;
extern "user32" fn CallWindowProcW(lpPrevWndFunc: WNDPROC, hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SendMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: [*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]u16, nMaxCount: i32) callconv(.winapi) i32;
extern "user32" fn MoveWindow(hWnd: HWND, X: i32, Y: i32, nWidth: i32, nHeight: i32, bRepaint: BOOL) callconv(.winapi) BOOL;
extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
extern "user32" fn SetFocus(hWnd: ?HWND) callconv(.winapi) ?HWND;
extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.winapi) i16;
extern "user32" fn InvalidateRect(hWnd: ?HWND, lpRect: ?*const anyopaque, bErase: BOOL) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) UINT;
extern "gdi32" fn CreateFontW(
    cHeight: i32,
    cWidth: i32,
    cEscapement: i32,
    cOrientation: i32,
    cWeight: i32,
    bItalic: DWORD,
    bUnderline: DWORD,
    bStrikeOut: DWORD,
    iCharSet: DWORD,
    iOutPrecision: DWORD,
    iClipPrecision: DWORD,
    iQuality: DWORD,
    iPitchAndFamily: DWORD,
    pszFaceName: [*:0]const u16,
) callconv(.winapi) HFONT;
extern "gdi32" fn CreateSolidBrush(color: COLORREF) callconv(.winapi) HBRUSH;
extern "gdi32" fn DeleteObject(ho: ?*anyopaque) callconv(.winapi) BOOL;
extern "gdi32" fn SetTextColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
extern "gdi32" fn SetBkColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;

alloc: Allocator,
/// Host window the URL bar + WebView2 controller render into. Lives as a
/// child of the chrome HWND, positioned by ChromeWindow.layoutActive exactly
/// like a terminal surface's HWND.
host_hwnd: HWND,
/// The chrome window — invalidated when the tab title changes so the
/// sidebar repaints.
chrome_hwnd: HWND,
/// Native single-line EDIT control across the top of the host.
url_edit: HWND,
/// Opaque WebView2 handle from the C++ shim. null if creation failed.
browser: ?*anyopaque = null,
/// Tab title (parity with Surface.title for rename + the tab strip).
/// c_allocator-owned. Updated from the page's document title unless pinned.
title: ?[]u8 = null,
/// Once the user renames the tab, page-title updates are ignored
/// (same contract as OSC titles on terminal tabs).
title_pinned: bool = false,
/// GDI resources for the URL bar; freed in deinit.
edit_font: HFONT = null,
edit_bg_brush: HBRUSH = null,
/// Original window procedures restored-by-destruction (the windows die in
/// deinit, so no explicit unsubclassing is needed).
orig_host_proc: ?WNDPROC = null,
orig_edit_proc: ?WNDPROC = null,

/// Create a host child HWND under `parent_hwnd` at the given content-rect
/// position/size, with a URL bar on top and a WebView2 below it navigating
/// to `url`.
pub fn create(
    alloc: Allocator,
    parent_hwnd: HWND,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    url: [*:0]const u16,
) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);

    // Bare STATIC container — predefined class, so no registration needed.
    // Created hidden; the chrome's applyActiveVisibility shows it when this
    // tab becomes active.
    const static_class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const host = CreateWindowExW(
        0,
        static_class.ptr,
        null,
        WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
        x,
        y,
        w,
        h,
        parent_hwnd,
        null,
        null,
        null,
    ) orelse return error.CreateHostWindowFailed;
    errdefer _ = DestroyWindow(host);

    const bar_h = barHeight(host);

    // URL bar: native single-line edit, dark-themed via WM_CTLCOLOREDIT in
    // the host subclass below.
    const edit_class = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
    const edit = CreateWindowExW(
        0,
        edit_class.ptr,
        null,
        WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL,
        0,
        0,
        w,
        bar_h,
        host,
        null,
        null,
        null,
    ) orelse return error.CreateUrlBarFailed;

    self.* = .{
        .alloc = alloc,
        .host_hwnd = host,
        .chrome_hwnd = parent_hwnd,
        .url_edit = edit,
    };

    // Segoe UI sized to the bar; margins keep the text off the edge.
    const dpi: i32 = @intCast(GetDpiForWindow(host));
    const face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
    self.edit_font = CreateFontW(
        -@divTrunc(bar_h * 2, 5), // ~40% of the bar
        0,
        0,
        0,
        400, // FW_NORMAL
        0,
        0,
        0,
        1, // DEFAULT_CHARSET
        0,
        0,
        5, // CLEARTYPE_QUALITY
        0,
        face.ptr,
    );
    if (self.edit_font) |f| _ = SendMessageW(edit, WM_SETFONT, @intFromPtr(f), 1);
    const margin: usize = @intCast(@divTrunc(8 * dpi, 96));
    _ = SendMessageW(edit, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, @bitCast(margin | (margin << 16)));
    self.edit_bg_brush = CreateSolidBrush(bar_bg);
    _ = SetWindowTextW(edit, url);

    // Subclass host (WM_CTLCOLOREDIT theming + focus forwarding) and edit
    // (Enter → navigate). GWLP_USERDATA carries *Self on both; EDIT and
    // STATIC keep their internals elsewhere so the slot is ours.
    _ = SetWindowLongPtrW(host, GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.orig_host_proc = @ptrFromInt(@as(usize, @bitCast(SetWindowLongPtrW(host, GWLP_WNDPROC, @bitCast(@intFromPtr(&hostProc))))));
    _ = SetWindowLongPtrW(edit, GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.orig_edit_proc = @ptrFromInt(@as(usize, @bitCast(SetWindowLongPtrW(edit, GWLP_WNDPROC, @bitCast(@intFromPtr(&editProc))))));

    // WebView2 fills the host's client area below the bar.
    self.browser = webview2.create(
        host,
        null,
        0,
        bar_h,
        w,
        @max(0, h - bar_h),
        url,
        null,
        &onTitleChanged,
        &onSourceChanged,
        &onAccel,
        self,
    );
    if (self.browser == null) {
        // Host + self are torn down by the errdefers above; the GDI
        // objects are ours to free here.
        if (self.edit_font) |f| _ = DeleteObject(f);
        if (self.edit_bg_brush) |bb| _ = DeleteObject(bb);
        return error.WebViewCreateFailed;
    }
    log.info("BrowserPane created host=0x{X}", .{@intFromPtr(host)});
    return self;
}

/// Resize the URL bar + WebView2 to fill the host's client area. The host
/// HWND itself is positioned by the chrome (SetWindowPos); we only need to
/// track its inner size.
pub fn setBounds(self: *Self, w: i32, h: i32) void {
    const bar_h = barHeight(self.host_hwnd);
    _ = MoveWindow(self.url_edit, 0, 0, w, bar_h, 1);
    if (self.browser) |b| webview2.setBounds(b, 0, bar_h, w, @max(0, h - bar_h));
}

/// Navigate to a UTF-8 URL. No scheme defaulting — programmatic callers
/// pass full URLs (the bar's Enter path defaults https:// itself).
pub fn navigateTo(self: *Self, url: []const u8) !void {
    const b = self.browser orelse return error.NotReady;
    var wurl: [2056:0]u16 = undefined;
    const wn = std.unicode.utf8ToUtf16Le(&wurl, url) catch return error.InvalidUrl;
    if (wn >= wurl.len) return error.InvalidUrl;
    wurl[wn] = 0;
    webview2.navigate(b, wurl[0..wn :0].ptr);
}

/// Evaluate JavaScript (UTF-8) in the page; `cb` fires later on the UI
/// thread with the JSON-encoded result. Errors if the WebView isn't up yet.
pub fn eval(self: *Self, js: []const u8, cb: webview2.ScriptFn, ctx: ?*anyopaque) !void {
    const b = self.browser orelse return error.NotReady;
    const wjs = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, js);
    defer std.heap.c_allocator.free(wjs);
    if (webview2.executeScript(b, wjs.ptr, cb, ctx) == 0) return error.NotReady;
}

/// The bar's current text — tracks the last committed URL unless the user
/// is mid-edit. Written into `buf` as UTF-8; null when empty/unreadable.
pub fn currentUrl(self: *Self, buf: []u8) ?[]const u8 {
    var wbuf: [2048]u16 = undefined;
    const wlen: usize = @intCast(GetWindowTextW(self.url_edit, &wbuf, wbuf.len));
    if (wlen == 0) return null;
    const n = std.unicode.utf16LeToUtf8(buf, wbuf[0..wlen]) catch return null;
    if (n == 0) return null;
    return buf[0..n];
}

pub fn deinit(self: *Self) void {
    if (self.browser) |b| webview2.destroy(b);
    _ = DestroyWindow(self.host_hwnd); // destroys the edit too
    if (self.edit_font) |f| _ = DeleteObject(f);
    if (self.edit_bg_brush) |b| _ = DeleteObject(b);
    if (self.title) |t| std.heap.c_allocator.free(t);
    self.alloc.destroy(self);
}

fn barHeight(hwnd: HWND) i32 {
    const dpi: i32 = @intCast(GetDpiForWindow(hwnd));
    return @divTrunc(bar_height_base * dpi, 96);
}

fn selfFrom(hwnd: HWND) ?*Self {
    const v: usize = @bitCast(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (v == 0) return null;
    return @ptrFromInt(v);
}

/// Host subclass: dark URL bar colors + forward keyboard focus into the
/// page when the chrome focuses this tab's child HWND.
fn hostProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const self = selfFrom(hwnd) orelse return 0;
    switch (msg) {
        WM_CTLCOLOREDIT => {
            const hdc: HDC = @ptrFromInt(wparam);
            _ = SetTextColor(hdc, bar_text);
            _ = SetBkColor(hdc, bar_bg);
            return @bitCast(@intFromPtr(self.edit_bg_brush));
        },
        WM_SETFOCUS => {
            if (self.browser) |b| webview2.focus(b);
            return 0;
        },
        else => {},
    }
    return CallWindowProcW(self.orig_host_proc.?, hwnd, msg, wparam, lparam);
}

/// Edit subclass: Enter navigates, Escape returns focus to the page.
fn editProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const self = selfFrom(hwnd) orelse return 0;
    switch (msg) {
        WM_KEYDOWN => switch (wparam) {
            VK_RETURN => {
                self.navigateFromBar();
                return 0;
            },
            VK_ESCAPE => {
                if (self.browser) |b| webview2.focus(b);
                return 0;
            },
            else => {},
        },
        // Suppress the ding for the keys we handled above.
        WM_CHAR => if (wparam == 0x0D or wparam == 0x1B) return 0,
        else => {},
    }
    return CallWindowProcW(self.orig_edit_proc.?, hwnd, msg, wparam, lparam);
}

/// Read the bar, default the scheme to https:// when none is given, and
/// navigate. Focus moves into the page so the result is immediately
/// scrollable/clickable.
fn navigateFromBar(self: *Self) void {
    const b = self.browser orelse return;

    var wbuf: [2048]u16 = undefined;
    const wlen: usize = @intCast(GetWindowTextW(self.url_edit, &wbuf, wbuf.len));
    if (wlen == 0) return;

    // Round-trip through UTF-8 for easy trimming + scheme handling.
    var u8buf: [4096]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&u8buf, wbuf[0..wlen]) catch return;
    const trimmed = std.mem.trim(u8, u8buf[0..n], " \t");
    if (trimmed.len == 0) return;

    var final_buf: [4106]u8 = undefined;
    const final = if (std.mem.indexOf(u8, trimmed, "://") == null and
        !std.mem.startsWith(u8, trimmed, "about:"))
        std.fmt.bufPrint(&final_buf, "https://{s}", .{trimmed}) catch return
    else
        trimmed;

    var wurl: [2056:0]u16 = undefined;
    const wn = std.unicode.utf8ToUtf16Le(&wurl, final) catch return;
    wurl[wn] = 0;
    webview2.navigate(b, wurl[0..wn :0].ptr);
    webview2.focus(b);
}

/// DocumentTitleChanged (UI thread): page title becomes the tab title
/// unless the user pinned a rename. Repaints the sidebar.
fn onTitleChanged(ctx: ?*anyopaque, title: [*:0]const u16) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(ctx orelse return));
    if (self.title_pinned) return;
    const span = std.mem.span(title);
    const utf8 = std.unicode.utf16LeToUtf8Alloc(std.heap.c_allocator, span) catch return;
    if (utf8.len == 0) {
        std.heap.c_allocator.free(utf8);
        return;
    }
    if (self.title) |old| std.heap.c_allocator.free(old);
    self.title = utf8;
    _ = InvalidateRect(self.chrome_hwnd, null, 0);
}

/// SourceChanged (UI thread): reflect committed navigations in the bar,
/// unless the user is editing it.
fn onSourceChanged(ctx: ?*anyopaque, url: [*:0]const u16) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(ctx orelse return));
    if (GetFocus() == self.url_edit) return;
    _ = SetWindowTextW(self.url_edit, url);
}

/// AcceleratorKeyPressed (UI thread): browser-pane shortcuts while focus
/// is inside the web content. Ctrl+L focuses the bar (select-all, like
/// every browser), Alt+Left/Right navigate history, Ctrl+R / F5 reload.
fn onAccel(ctx: ?*anyopaque, vk: c_uint) callconv(.c) c_int {
    const self: *Self = @ptrCast(@alignCast(ctx orelse return 0));
    const b = self.browser orelse return 0;
    const ctrl = GetKeyState(VK_CONTROL_I) < 0;
    const alt = GetKeyState(VK_MENU_I) < 0;
    switch (vk) {
        'L' => if (ctrl) {
            _ = SetFocus(self.url_edit);
            _ = SendMessageW(self.url_edit, EM_SETSEL, 0, -1);
            return 1;
        },
        'R' => if (ctrl) {
            webview2.reload(b);
            return 1;
        },
        0x74 => { // VK_F5
            webview2.reload(b);
            return 1;
        },
        0x25 => if (alt) { // VK_LEFT
            webview2.back(b);
            return 1;
        },
        0x27 => if (alt) { // VK_RIGHT
            webview2.forward(b);
            return 1;
        },
        else => {},
    }
    return 0;
}
