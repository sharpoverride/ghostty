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

const WA_INACTIVE: u16 = 0;

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
hwnd: HWND,
/// Single tab today. Will become a list once multi-tab UI lands.
surface: ?*Surface = null,

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWin32Parent");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");

pub fn create(alloc: Allocator) !*Self {
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
        .hwnd = undefined,
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

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.surface) |s| s.deinit();
    self.alloc.destroy(self);
}

/// Attach a Surface as the (currently only) tab. Resizes its child HWND
/// to fill the client area below the tab strip. Caller transfers
/// ownership; ParentWindow's deinit will drop the Surface too.
pub fn attachSurface(self: *Self, surface: *Surface) void {
    self.surface = surface;
    self.layoutActive();
}

/// Resize the active tab's child HWND to fill the client area below the
/// tab strip. Invoked on WM_SIZE and on first attach.
fn layoutActive(self: *Self) void {
    const surface = self.surface orelse return;
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
        WM_ACTIVATE => {
            // When the parent regains activation (alt-tab back, monitor
            // switch with focus restore, click on title bar) we need to
            // restore focus to the active child explicitly. Windows
            // doesn't propagate focus through the parent automatically,
            // so without this the child stays unfocused → engine keeps
            // rendering paused (cursor blink off, no redraws) until the
            // user clicks back into the terminal area.
            const active_lo: u16 = @intCast(wparam & 0xFFFF);
            if (active_lo != WA_INACTIVE) {
                if (recoverSelf(hwnd)) |self| {
                    if (self.surface) |s| _ = SetFocus(s.window.hwnd);
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
