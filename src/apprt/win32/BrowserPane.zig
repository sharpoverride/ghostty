//! A browser tab's content: a host child HWND (parented to the chrome
//! window) with a WebView2 instance filling it. Mirrors how a terminal
//! `Surface` owns a child HWND, so the chrome's tab machinery
//! (show/hide/layout/close) treats both uniformly — switching to a browser
//! tab hides the terminal via the same applyActiveVisibility loop, no
//! special-casing or z-order tricks.
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

const log = std.log.scoped(.win32_browser);

const WS_CHILD: DWORD = 0x40000000;
const WS_CLIPSIBLINGS: DWORD = 0x04000000;
const WS_CLIPCHILDREN: DWORD = 0x02000000;
const WS_VISIBLE: DWORD = 0x10000000;

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
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) windows.BOOL;

alloc: Allocator,
/// Host window the WebView2 controller renders into. Lives as a child of
/// the chrome HWND, positioned by ChromeWindow.layoutActive exactly like a
/// terminal surface's HWND.
host_hwnd: HWND,
/// Opaque WebView2 handle from the C++ shim. null if creation failed.
browser: ?*anyopaque = null,
/// Tab title (parity with Surface.title for rename + the tab strip).
/// c_allocator-owned. Defaults to a generic label drawn by the chrome.
title: ?[]u8 = null,
/// Once the user renames the tab, OSC-style title updates are ignored.
/// Browsers never push titles today, so this is only set by rename.
title_pinned: bool = false,

/// Create a host child HWND under `parent_hwnd` at the given content-rect
/// position/size and spin up a WebView2 in it navigating to `url`.
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
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const host = CreateWindowExW(
        0,
        class.ptr,
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

    self.* = .{ .alloc = alloc, .host_hwnd = host };

    // WebView2 fills the host's client area (origin-relative bounds).
    self.browser = webview2.create(host, null, 0, 0, w, h, url, null, null);
    if (self.browser == null) {
        _ = DestroyWindow(host);
        alloc.destroy(self);
        return error.WebViewCreateFailed;
    }
    log.info("BrowserPane created host=0x{X}", .{@intFromPtr(host)});
    return self;
}

/// Resize the WebView2 to fill the host's client area. The host HWND itself
/// is positioned by the chrome (SetWindowPos); we only need to track its
/// inner size for the WebView bounds.
pub fn setBounds(self: *Self, w: i32, h: i32) void {
    if (self.browser) |b| webview2.setBounds(b, 0, 0, w, h);
}

pub fn deinit(self: *Self) void {
    if (self.browser) |b| webview2.destroy(b);
    _ = DestroyWindow(self.host_hwnd);
    if (self.title) |t| std.heap.c_allocator.free(t);
    self.alloc.destroy(self);
}
