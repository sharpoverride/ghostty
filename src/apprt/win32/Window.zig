//! Native win32 window for the Ghostty win32 apprt.
//!
//! Post-B3 role: owns just the HWND + the Win32 message pump. The shell,
//! terminal state, and rendering all live in CoreSurface (driven by
//! `Surface.zig`). WM_PAINT falls through to DefWindowProc; the renderer
//! thread paints via the WGL context owned by Surface and calls SwapBuffers
//! itself. WM_CHAR/WM_KEYDOWN/WM_SIZE will be forwarded to CoreSurface in
//! B4 via a back-pointer to the owning Surface.
const Self = @This();

const std = @import("std");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;
const input = @import("../../input.zig");
const apprt = @import("../../apprt.zig");
const Surface = @import("Surface.zig");

const HANDLE = windows.HANDLE;
const HWND = windows.HWND;
const HINSTANCE = windows.HINSTANCE;
const HICON = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const HMENU = ?*anyopaque;
const HMODULE = windows.HMODULE;
const HDC = ?*anyopaque;
const HFONT = ?*anyopaque;
const HGDIOBJ = ?*anyopaque;
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

const log = std.log.scoped(.win32_window);

// ---------------------------------------------------------------------------
// Win32 message constants and structs we use.
// ---------------------------------------------------------------------------

const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
const WS_VISIBLE: DWORD = 0x10000000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const CS_HREDRAW: UINT = 0x0002;
const CS_VREDRAW: UINT = 0x0001;
const CS_OWNDC: UINT = 0x0020;
const SW_SHOW: i32 = 5;
const SW_SHOWDEFAULT: i32 = 10;
const IDC_IBEAM: usize = 32513;
const COLOR_WINDOW: i32 = 5;
const GWLP_USERDATA: i32 = -21;
const WHITE_BRUSH: i32 = 0;
const BLACK_BRUSH: i32 = 4;

const WM_DESTROY: UINT = 0x0002;
const WM_SIZE: UINT = 0x0005;
const WM_PAINT: UINT = 0x000F;
const WM_CLOSE: UINT = 0x0010;
const WM_QUIT: UINT = 0x0012;
const WM_ERASEBKGND: UINT = 0x0014;
const WM_SETFOCUS: UINT = 0x0007;
const WM_KILLFOCUS: UINT = 0x0008;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_RBUTTONDOWN: UINT = 0x0204;
const WM_RBUTTONUP: UINT = 0x0205;
const WM_MBUTTONDOWN: UINT = 0x0207;
const WM_MBUTTONUP: UINT = 0x0208;
const WM_MOUSEWHEEL: UINT = 0x020A;
const WM_MOUSEHWHEEL: UINT = 0x020E;
const WHEEL_DELTA: f64 = 120.0;
const WM_KEYDOWN: UINT = 0x0100;
const WM_KEYUP: UINT = 0x0101;
const WM_CHAR: UINT = 0x0102;
const WM_SYSKEYDOWN: UINT = 0x0104;
const WM_SYSKEYUP: UINT = 0x0105;
const WM_SYSCHAR: UINT = 0x0106;
const WM_CREATE: UINT = 0x0001;
const WM_NCCREATE: UINT = 0x0081;

// Virtual-Key codes we care about for terminal input.
const VK_RETURN: WPARAM = 0x0D;
const VK_BACK: WPARAM = 0x08;
const VK_TAB: WPARAM = 0x09;
const VK_ESCAPE: WPARAM = 0x1B;
const VK_LEFT: WPARAM = 0x25;
const VK_UP: WPARAM = 0x26;
const VK_RIGHT: WPARAM = 0x27;
const VK_DOWN: WPARAM = 0x28;
const VK_HOME: WPARAM = 0x24;
const VK_END: WPARAM = 0x23;
const VK_PRIOR: WPARAM = 0x21;
const VK_NEXT: WPARAM = 0x22;
const VK_INSERT: WPARAM = 0x2D;
const VK_DELETE: WPARAM = 0x2E;
const VK_F1: WPARAM = 0x70;
const VK_F12: WPARAM = 0x7B;

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

const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

const LOGFONTW = extern struct {
    lfHeight: i32,
    lfWidth: i32,
    lfEscapement: i32,
    lfOrientation: i32,
    lfWeight: i32,
    lfItalic: u8,
    lfUnderline: u8,
    lfStrikeOut: u8,
    lfCharSet: u8,
    lfOutPrecision: u8,
    lfClipPrecision: u8,
    lfQuality: u8,
    lfPitchAndFamily: u8,
    lfFaceName: [32]u16,
};

const TEXTMETRICW = extern struct {
    tmHeight: i32,
    tmAscent: i32,
    tmDescent: i32,
    tmInternalLeading: i32,
    tmExternalLeading: i32,
    tmAveCharWidth: i32,
    tmMaxCharWidth: i32,
    tmWeight: i32,
    tmOverhang: i32,
    tmDigitizedAspectX: i32,
    tmDigitizedAspectY: i32,
    tmFirstChar: u16,
    tmLastChar: u16,
    tmDefaultChar: u16,
    tmBreakChar: u16,
    tmItalic: u8,
    tmUnderlined: u8,
    tmStruckOut: u8,
    tmPitchAndFamily: u8,
    tmCharSet: u8,
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
    hMenu: HMENU,
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
extern "user32" fn PostMessageW(hWnd: ?HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn InvalidateRect(hWnd: ?HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) HDC;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
// LoadCursorW takes LPCWSTR but with MAKEINTRESOURCE the value is a small
// integer pretending to be a pointer (top bits zero). Zig refuses to coerce
// that to an aligned [*:0]const u16, so accept usize and let Win32 do its
// magic at the FFI boundary.
extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: usize) callconv(.winapi) HCURSOR;
// Same MAKEINTRESOURCE trick as LoadCursorW: pass the integer ID via usize.
extern "user32" fn LoadIconW(hInstance: ?HINSTANCE, lpIconName: usize) callconv(.winapi) HICON;
extern "user32" fn GetStockObject(i: i32) callconv(.winapi) HGDIOBJ;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.winapi) isize;
extern "user32" fn SetFocus(hWnd: ?HWND) callconv(.winapi) ?HWND;
extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.winapi) i16;
extern "user32" fn GetKeyboardState(lpKeyState: [*]u8) callconv(.winapi) BOOL;
extern "user32" fn GetKeyboardLayout(idThread: DWORD) callconv(.winapi) ?*anyopaque;
extern "user32" fn ToUnicodeEx(
    wVirtKey: UINT,
    wScanCode: UINT,
    lpKeyState: [*]const u8,
    pwszBuff: [*]u16,
    cchBuff: i32,
    wFlags: UINT,
    dwhkl: ?*anyopaque,
) callconv(.winapi) i32;
extern "user32" fn MapVirtualKeyW(uCode: UINT, uMapType: UINT) callconv(.winapi) UINT;
extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.winapi) BOOL;
extern "user32" fn MessageBeep(uType: UINT) callconv(.winapi) BOOL;

const WM_APP: UINT = 0x8000;
/// Custom message: UI thread should set the window title from a heap
/// UTF-16 buffer. wparam = length (u16 units, incl. terminator),
/// lparam = pointer cast to LPARAM. UI thread takes ownership of the buf.
const WM_APP_SET_TITLE: UINT = WM_APP + 1;

const MAPVK_VK_TO_CHAR: UINT = 2;

extern "gdi32" fn CreateFontIndirectW(lplf: *const LOGFONTW) callconv(.winapi) HFONT;
extern "gdi32" fn SelectObject(hdc: HDC, h: HGDIOBJ) callconv(.winapi) HGDIOBJ;
extern "gdi32" fn DeleteObject(ho: HGDIOBJ) callconv(.winapi) BOOL;
extern "gdi32" fn SetTextColor(hdc: HDC, color: u32) callconv(.winapi) u32;
extern "gdi32" fn SetBkColor(hdc: HDC, color: u32) callconv(.winapi) u32;
extern "gdi32" fn TextOutW(hdc: HDC, x: i32, y: i32, lpString: [*]const u16, c: i32) callconv(.winapi) BOOL;
extern "gdi32" fn GetTextMetricsW(hdc: HDC, lptm: *TEXTMETRICW) callconv(.winapi) BOOL;
extern "gdi32" fn CreateSolidBrush(color: u32) callconv(.winapi) HBRUSH;
extern "gdi32" fn SetBkMode(hdc: HDC, mode: i32) callconv(.winapi) i32;
extern "user32" fn FillRect(hDC: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(.winapi) i32;

const TRANSPARENT_BKMODE: i32 = 1;

// ---------------------------------------------------------------------------
// Window state.
// ---------------------------------------------------------------------------

alloc: Allocator,
hwnd: HWND,
font: HFONT,
bg_brush: HBRUSH,
char_w: i32,
char_h: i32,
/// Back-pointer to the Surface that owns us. Set by Surface.create after
/// the Window is fully constructed. May be null during WM_CREATE / first
/// WM_SIZE — those callbacks must no-op when surface is null.
surface: ?*Surface = null,
/// Last cursor position seen via WM_MOUSEMOVE (client coords). Cached so
/// `Surface.getCursorPos()` can return a sane value when the engine queries
/// it outside of a move event.
last_mouse_x: i32 = 0,
last_mouse_y: i32 = 0,

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWin32");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");

pub fn create(alloc: Allocator) !*Self {
    // HMODULE and HINSTANCE are the same Win32 value (process module base)
    // but Zig models them as distinct opaque pointer types. Bridge with a
    // raw-pointer round-trip rather than @ptrCast (which doesn't compose).
    const hmodule = GetModuleHandleW(null);
    const hinstance: HINSTANCE = @ptrFromInt(@intFromPtr(hmodule));

    // Solid brush matching our text background. Shared between the class
    // background (initial erase) and per-paint FillRect, so the whole client
    // area stays the same dark color even with sub-rect repaints.
    const bg_brush = CreateSolidBrush(0x00181818) orelse return error.CreateBrushFailed;
    errdefer _ = DeleteObject(bg_brush);

    var wc: WNDCLASSEXW = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinstance;
    wc.hCursor = LoadCursorW(null, IDC_IBEAM);
    // ghostty.rc declares ID_ICON_GHOSTTY = 1 for ghostty.ico. Load it from
    // our own module's embedded resources so the title bar + taskbar show
    // the proper icon rather than the IDI_APPLICATION default.
    wc.hIcon = LoadIconW(hinstance, 1);
    wc.hIconSm = LoadIconW(hinstance, 1);
    wc.hbrBackground = bg_brush;
    wc.lpszClassName = class_name;
    // RegisterClassExW may fail if the class is already registered; ignore.
    _ = RegisterClassExW(&wc);

    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);

    self.* = .{
        .alloc = alloc,
        .hwnd = undefined,
        .font = null,
        .bg_brush = bg_brush,
        .char_w = 8,
        .char_h = 16,
    };

    const hwnd = CreateWindowExW(
        0,
        class_name,
        window_title,
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        1024,
        640,
        null,
        null,
        hinstance,
        @ptrCast(self),
    ) orelse return error.CreateWindowFailed;
    self.hwnd = hwnd;

    // Stash self pointer so WndProc can recover it.
    _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @intCast(@intFromPtr(self)));

    // Create a monospace font.
    var lf: LOGFONTW = std.mem.zeroes(LOGFONTW);
    lf.lfHeight = -16;
    lf.lfPitchAndFamily = 0x31; // FIXED_PITCH | FF_MODERN
    const face = std.unicode.utf8ToUtf16LeStringLiteral("Cascadia Mono");
    @memcpy(lf.lfFaceName[0..face.len], face);
    self.font = CreateFontIndirectW(&lf);

    // Sample char metrics by selecting font into the screen DC.
    {
        // GetDC(NULL) is the screen DC; reuse it for measurement.
        const extern_user = struct {
            extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) HDC;
            extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.winapi) i32;
        };
        const hdc = extern_user.GetDC(null);
        defer _ = extern_user.ReleaseDC(null, hdc);
        const prev = SelectObject(hdc, self.font);
        var tm: TEXTMETRICW = undefined;
        if (GetTextMetricsW(hdc, &tm) == TRUE) {
            self.char_w = tm.tmAveCharWidth;
            self.char_h = tm.tmHeight + tm.tmExternalLeading;
        }
        _ = SelectObject(hdc, prev);
    }

    _ = ShowWindow(hwnd, SW_SHOWDEFAULT);
    _ = UpdateWindow(hwnd);
    // Take foreground + keyboard focus explicitly. Without this, when launched
    // from a console the parent conhost keeps focus and WM_CHAR never arrives.
    _ = SetForegroundWindow(hwnd);
    _ = SetFocus(hwnd);

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.font) |f| _ = DeleteObject(f);
    if (self.bg_brush) |b| _ = DeleteObject(b);
    self.alloc.destroy(self);
}

/// Set the window title bar text from a UTF-8 string. Safe to call from
/// ANY thread — the engine often invokes us from the IO/renderer thread
/// when the shell emits OSC 0/2. Calling SetWindowTextW directly from a
/// non-owner thread degrades into a cross-thread SendMessage(WM_SETTEXT)
/// that BLOCKS the caller until the UI thread pumps. Under load (rapid
/// title updates while UI is busy) that path deadlocks the engine.
///
/// We instead allocate a UTF-16 buffer on the (thread-safe) c_allocator,
/// PostMessageW our custom WM_APP_SET_TITLE, and the UI thread's WndProc
/// calls SetWindowTextW locally + frees the buffer.
pub fn setTitle(self: *const Self, title: []const u8) !void {
    const alloc = std.heap.c_allocator;
    var buf = try alloc.alloc(u16, title.len + 1);
    errdefer alloc.free(buf);
    const written = try std.unicode.utf8ToUtf16Le(buf, title);
    buf[written] = 0;

    const ptr_lparam: LPARAM = @bitCast(@as(usize, @intFromPtr(buf.ptr)));
    const len_wparam: WPARAM = @intCast(buf.len);
    if (PostMessageW(self.hwnd, WM_APP_SET_TITLE, len_wparam, ptr_lparam) == FALSE) {
        // Queue full / window gone — drop the title silently, free the buf.
        alloc.free(buf);
        return;
    }
    // Buffer ownership now belongs to the queued message; WndProc frees.
}

/// Ring the system default beep — no payload, just a notify on terminal BEL.
pub fn ringBell(self: *const Self) void {
    _ = self;
    _ = MessageBeep(0xFFFFFFFF); // MB_OK (system default sound)
}

/// Return the current client-area size of this Window. Used by Surface to
/// satisfy apprt's `getSize` contract without exposing the HWND.
pub fn clientSize(self: *const Self) struct { width: u32, height: u32 } {
    var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = GetClientRect(self.hwnd, &rect);
    return .{
        .width = @intCast(@max(@as(i32, 0), rect.right - rect.left)),
        .height = @intCast(@max(@as(i32, 0), rect.bottom - rect.top)),
    };
}

/// Run the win32 message pump on the calling thread until WM_QUIT.
pub fn run(self: *Self) !void {
    _ = self;
    var msg: MSG = undefined;
    while (true) {
        const r = GetMessageW(&msg, null, 0, 0);
        if (r == 0) break; // WM_QUIT
        if (r == -1) return error.GetMessageFailed;
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

// ---------------------------------------------------------------------------
// WndProc and helpers.
//
// B3 cutover: the Window no longer owns a pty or output buffer — CoreSurface
// owns the shell + terminal state, and the renderer thread paints via the
// WGL context owned by Surface, calling SwapBuffers on each frame. WM_PAINT
// therefore falls through to DefWindowProcW (the class brush still erases
// the client rect to bg color until the renderer thread takes over).
//
// WM_CHAR/WM_KEYDOWN/WM_SIZE currently just log — B4 wires them to
// `core_surface.charCallback`/`keyCallback`/`sizeCallback` via the Surface
// back-pointer.
// ---------------------------------------------------------------------------

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        // WM_KEYDOWN handles EVERYTHING: text + special keys + modifiers.
        // WM_CHAR is suppressed below so we don't get double input.
        WM_KEYDOWN, WM_SYSKEYDOWN => {
            forwardKey(hwnd, wparam, lparam, .press);
            // Fall through to DefWindowProcW so system keys (Alt+F4 etc.)
            // still work even if we forwarded them.
        },
        WM_KEYUP, WM_SYSKEYUP => forwardKey(hwnd, wparam, lparam, .release),
        // Eat WM_CHAR — we already handled the press via WM_KEYDOWN with
        // ToUnicodeEx providing the utf8. Letting it through here would
        // double-send every character to the pty.
        WM_CHAR, WM_SYSCHAR => return 0,
        WM_SETFOCUS => forwardFocus(hwnd, true),
        WM_KILLFOCUS => forwardFocus(hwnd, false),
        WM_MOUSEMOVE => forwardMouseMove(hwnd, lparam),
        WM_LBUTTONDOWN => forwardMouseButton(hwnd, .left, .press, true),
        WM_LBUTTONUP => forwardMouseButton(hwnd, .left, .release, false),
        WM_RBUTTONDOWN => forwardMouseButton(hwnd, .right, .press, false),
        WM_RBUTTONUP => forwardMouseButton(hwnd, .right, .release, false),
        WM_MBUTTONDOWN => forwardMouseButton(hwnd, .middle, .press, false),
        WM_MBUTTONUP => forwardMouseButton(hwnd, .middle, .release, false),
        WM_MOUSEWHEEL => forwardWheel(hwnd, wparam, .vertical),
        WM_MOUSEHWHEEL => forwardWheel(hwnd, wparam, .horizontal),
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
        WM_SIZE => forwardSize(hwnd, lparam),
        WM_CLOSE, WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn forwardFocus(hwnd: HWND, focused: bool) void {
    const self = recoverSelf(hwnd) orelse return;
    const surface = self.surface orelse return;
    surface.core_surface.focusCallback(focused) catch |e| {
        log.warn("focusCallback err: {}", .{e});
    };
}

fn forwardWheel(hwnd: HWND, wparam: WPARAM, axis: enum { vertical, horizontal }) void {
    const self = recoverSelf(hwnd) orelse return;
    const surface = self.surface orelse return;
    // Delta lives in the high word as a signed 16-bit value. WHEEL_DELTA
    // (120) is one notch — Ghostty expects yoff in notches with positive
    // meaning "scroll up" / lines moving towards the user. Windows uses
    // the same sign convention (positive = wheel forward = up).
    const raw_delta: u16 = @intCast((wparam >> 16) & 0xFFFF);
    const delta_i16: i16 = @bitCast(raw_delta);
    const notches: f64 = @as(f64, @floatFromInt(delta_i16)) / WHEEL_DELTA;
    const xoff: f64 = if (axis == .horizontal) notches else 0.0;
    const yoff: f64 = if (axis == .vertical) notches else 0.0;
    surface.core_surface.scrollCallback(xoff, yoff, .{}) catch |e| {
        log.warn("scrollCallback err: {}", .{e});
    };
}

/// Pull signed 16-bit x,y out of an lparam carrying client coordinates.
fn unpackXY(lparam: LPARAM) struct { x: i32, y: i32 } {
    const x_u16: u16 = @intCast(lparam & 0xFFFF);
    const y_u16: u16 = @intCast((lparam >> 16) & 0xFFFF);
    return .{
        .x = @as(i32, @as(i16, @bitCast(x_u16))),
        .y = @as(i32, @as(i16, @bitCast(y_u16))),
    };
}

fn forwardMouseMove(hwnd: HWND, lparam: LPARAM) void {
    const self = recoverSelf(hwnd) orelse return;
    const surface = self.surface orelse return;
    const xy = unpackXY(lparam);
    self.last_mouse_x = xy.x;
    self.last_mouse_y = xy.y;
    surface.core_surface.cursorPosCallback(.{
        .x = @floatFromInt(xy.x),
        .y = @floatFromInt(xy.y),
    }, null) catch |e| {
        log.warn("cursorPosCallback err: {}", .{e});
    };
}

fn forwardMouseButton(
    hwnd: HWND,
    button: input.MouseButton,
    state: input.MouseButtonState,
    capture: bool,
) void {
    const self = recoverSelf(hwnd) orelse return;
    const surface = self.surface orelse return;

    // SetCapture on left-button-down keeps WM_MOUSEMOVE flowing even when
    // the cursor leaves the client area — necessary for drag-selection that
    // ends past the window edge. The matching ReleaseCapture happens
    // automatically on WM_LBUTTONUP (Win32 contract), but call it
    // explicitly to be safe.
    if (capture) {
        _ = SetCapture(hwnd);
    } else if (state == .release and button == .left) {
        _ = ReleaseCapture();
    }

    const mods = currentMods();
    _ = surface.core_surface.mouseButtonCallback(state, button, mods) catch |e| {
        log.warn("mouseButtonCallback err: {}", .{e});
    };
}

fn recoverSelf(hwnd: HWND) ?*Self {
    const p = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (p == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(p)));
}

fn currentMods() input.Mods {
    const down: i16 = @bitCast(@as(u16, 0x8000));
    var mods: input.Mods = .{
        .shift = (GetKeyState(0x10) & down) != 0, // VK_SHIFT
        .ctrl = (GetKeyState(0x11) & down) != 0, // VK_CONTROL
        .alt = (GetKeyState(0x12) & down) != 0, // VK_MENU
    };

    // AltGr detection: on EU layouts (Romanian, German, French, etc.) the
    // AltGr key fires WM_KEYDOWN(VK_LCONTROL) immediately followed by
    // WM_KEYDOWN(VK_RMENU) — Windows surfaces it as Ctrl+Alt. We want
    // AltGr+key to produce the layout's special char (e.g. AltGr+2 = @
    // on Romanian), not to be treated as Ctrl+Alt+key which would skip
    // ToUnicodeEx and break unicode binding lookups. Heuristic: if both
    // Ctrl and Alt are down AND the right Alt is the one down, this is
    // AltGr — strip ctrl + alt so ToUnicodeEx runs.
    if (mods.ctrl and mods.alt) {
        const ralt_down = (GetKeyState(0xA5) & down) != 0; // VK_RMENU
        if (ralt_down) {
            mods.ctrl = false;
            mods.alt = false;
        }
    }

    return mods;
}

/// Map a Windows virtual-key code to an input.Key. Returns `.unidentified`
/// for unmapped keys (those still forward — utf8 + mods carry meaning).
fn vkToInputKey(vk: u32) input.Key {
    return switch (vk) {
        0x08 => .backspace,
        0x09 => .tab,
        0x0D => .enter,
        0x10 => .shift_left,
        0x11 => .control_left,
        0x12 => .alt_left,
        0x14 => .caps_lock,
        0x1B => .escape,
        0x20 => .space,
        0x21 => .page_up,
        0x22 => .page_down,
        0x23 => .end,
        0x24 => .home,
        0x25 => .arrow_left,
        0x26 => .arrow_up,
        0x27 => .arrow_right,
        0x28 => .arrow_down,
        0x2D => .insert,
        0x2E => .delete,
        0x30 => .digit_0,
        0x31 => .digit_1,
        0x32 => .digit_2,
        0x33 => .digit_3,
        0x34 => .digit_4,
        0x35 => .digit_5,
        0x36 => .digit_6,
        0x37 => .digit_7,
        0x38 => .digit_8,
        0x39 => .digit_9,
        0x41 => .key_a,
        0x42 => .key_b,
        0x43 => .key_c,
        0x44 => .key_d,
        0x45 => .key_e,
        0x46 => .key_f,
        0x47 => .key_g,
        0x48 => .key_h,
        0x49 => .key_i,
        0x4A => .key_j,
        0x4B => .key_k,
        0x4C => .key_l,
        0x4D => .key_m,
        0x4E => .key_n,
        0x4F => .key_o,
        0x50 => .key_p,
        0x51 => .key_q,
        0x52 => .key_r,
        0x53 => .key_s,
        0x54 => .key_t,
        0x55 => .key_u,
        0x56 => .key_v,
        0x57 => .key_w,
        0x58 => .key_x,
        0x59 => .key_y,
        0x5A => .key_z,
        0x70 => .f1,
        0x71 => .f2,
        0x72 => .f3,
        0x73 => .f4,
        0x74 => .f5,
        0x75 => .f6,
        0x76 => .f7,
        0x77 => .f8,
        0x78 => .f9,
        0x79 => .f10,
        0x7A => .f11,
        0x7B => .f12,
        0xBA => .semicolon, // VK_OEM_1
        0xBB => .equal, // VK_OEM_PLUS — also used for Ctrl+= font-size up
        0xBC => .comma, // VK_OEM_COMMA
        0xBD => .minus, // VK_OEM_MINUS — also used for Ctrl+- font-size down
        0xBE => .period, // VK_OEM_PERIOD
        0xBF => .slash, // VK_OEM_2
        0xC0 => .backquote, // VK_OEM_3
        0xDB => .bracket_left, // VK_OEM_4
        0xDC => .backslash, // VK_OEM_5
        0xDD => .bracket_right, // VK_OEM_6
        0xDE => .quote, // VK_OEM_7
        else => .unidentified,
    };
}

/// Run ToUnicodeEx against the current keyboard state to derive the text
/// that this key press generates with the user's layout. Caller passes the
/// utf8 buffer; we return the byte count actually written (0 = no text).
fn computeUtf8(vk: UINT, scan_code: UINT, utf8_buf: []u8) usize {
    var state: [256]u8 = undefined;
    if (GetKeyboardState(&state) == FALSE) return 0;
    var utf16: [4]u16 = undefined;
    const layout = GetKeyboardLayout(0);
    // wFlags = 4 (Win10+) tells ToUnicodeEx NOT to mutate the kernel's
    // dead-key state. Without this, layouts with dead keys (Romanian
    // Standard, German, etc.) accumulate stuck state between calls and
    // suppress translation of subsequent keys — manifest as random
    // characters silently disappearing.
    const n = ToUnicodeEx(vk, scan_code, &state, &utf16, utf16.len, 4, layout);
    if (n <= 0) return 0;
    return std.unicode.utf16LeToUtf8(utf8_buf, utf16[0..@intCast(n)]) catch 0;
}

fn forwardKey(hwnd: HWND, wparam: WPARAM, lparam: LPARAM, action: input.Action) void {
    const self = recoverSelf(hwnd) orelse return;
    const surface = self.surface orelse return;
    const vk: u32 = @intCast(wparam);
    const scan_code: u32 = @intCast((lparam >> 16) & 0xFF);
    const key = vkToInputKey(vk);
    const mods = currentMods();

    // NOTE: we deliberately do NOT promote press→repeat for held keys.
    // Ghostty's terminal encode path inserts text on every .press and
    // ignores .repeat. Auto-repeat at the OS level already delivers
    // WM_KEYDOWN on each repeat cycle; passing them all through as
    // .press is what a terminal wants.

    // Compute utf8 from the key + layout. We do this only for press events
    // and only when Ctrl/Alt aren't held — those combos go to the engine as
    // .key + .mods so it can decide between a keybinding (Ctrl+R) and a
    // VT encode (Ctrl+letter → control byte). Including utf8 in those would
    // double-send.
    var utf8_buf: [16]u8 = undefined;
    var utf8: []const u8 = "";
    if (action == .press and !mods.ctrl and !mods.alt) {
        const n = computeUtf8(vk, scan_code, &utf8_buf);
        utf8 = utf8_buf[0..n];
    }

    // Unshifted codepoint — what character this physical key produces with
    // no modifiers. Critical for unicode-based keybindings: Ghostty's
    // default font-size keybinds (Ctrl+=, Ctrl+-, Ctrl+0) match on
    // .unicode = '=' / '-' / '0', not on .key = .equal. Without this the
    // engine can't bridge from .key=.equal to the '=' codepoint trigger.
    // MAPVK_VK_TO_CHAR returns the layout-aware char for the VK with no
    // mods applied; dead-key bit (high bit) is ignored.
    const mapped: UINT = MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR);
    const unshifted: u21 = blk: {
        const ch: u32 = mapped & 0x7FFF_FFFF; // strip dead-key bit
        if (ch == 0 or ch > 0x10_FFFF) break :blk 0;
        break :blk @intCast(ch);
    };

    const event: input.KeyEvent = .{
        .action = action,
        .key = key,
        .mods = mods,
        .utf8 = utf8,
        .unshifted_codepoint = unshifted,
    };
    _ = surface.core_surface.keyCallback(event) catch |e| {
        log.warn("keyCallback err: vk=0x{X} key={} err={}", .{ vk, key, e });
    };
}

fn forwardSize(hwnd: HWND, lparam: LPARAM) void {
    const self = recoverSelf(hwnd) orelse return;
    const surface = self.surface orelse return;
    const w: u32 = @intCast(lparam & 0xFFFF);
    const h: u32 = @intCast((lparam >> 16) & 0xFFFF);
    surface.core_surface.sizeCallback(.{ .width = w, .height = h }) catch |e| {
        log.warn("sizeCallback err: {}", .{e});
    };
}
