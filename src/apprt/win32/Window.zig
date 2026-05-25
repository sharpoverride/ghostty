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
const WM_KEYDOWN: UINT = 0x0100;
const WM_CHAR: UINT = 0x0102;
const WM_SYSKEYDOWN: UINT = 0x0104;
const WM_CREATE: UINT = 0x0001;
const WM_NCCREATE: UINT = 0x0081;
const WM_APP: UINT = 0x8000;
const WM_PTY_READY: UINT = WM_APP + 1;

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
extern "user32" fn GetStockObject(i: i32) callconv(.winapi) HGDIOBJ;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.winapi) isize;
extern "user32" fn SetFocus(hWnd: ?HWND) callconv(.winapi) ?HWND;
extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;

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
        WM_CHAR => forwardChar(hwnd, wparam),
        WM_SIZE => forwardSize(hwnd, lparam),
        WM_KEYDOWN, WM_SYSKEYDOWN => {
            // Non-text keys (arrows, F-keys, etc) — B4 follow-up will map
            // VK codes to input.Key and forward via keyCallback too.
            log.debug("WM_KEY vk=0x{X} (TODO map to input.Key)", .{wparam});
        },
        WM_CLOSE, WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn recoverSelf(hwnd: HWND) ?*Self {
    const p = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (p == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(p)));
}

fn forwardChar(hwnd: HWND, wparam: WPARAM) void {
    const self = recoverSelf(hwnd) orelse return;
    const surface = self.surface orelse return;
    const ch: u21 = @truncate(wparam);
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(ch, &buf) catch return;
    const event: input.KeyEvent = .{ .utf8 = buf[0..len] };
    _ = surface.core_surface.keyCallback(event) catch |e| {
        log.warn("keyCallback err: {}", .{e});
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
