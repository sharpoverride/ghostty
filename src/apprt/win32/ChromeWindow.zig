//! Direct2D-backed modern window chrome, gated behind `--new-chrome`
//! (or `GHOSTTY_NEW_CHROME=1`). Mirrors `ParentWindow`'s public API so
//! `App.zig` can dispatch between the two without other call-sites
//! caring.
//!
//! Slice 1 scope: single hosted Surface, D2D-painted left sidebar and
//! top header band. No tab rows, no buttons, no collapse — those land
//! in subsequent slices. Until then this just proves out the D2D
//! plumbing (factory, hwnd render target, brushes, BeginDraw/EndDraw)
//! and the layout (surface child fills client area minus sidebar minus
//! header).

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
const HRESULT = i32;

const log = std.log.scoped(.win32_chrome);

// ---------------------------------------------------------------------------
// Win32 constants & structs (subset; kept duplicated rather than shared with
// ParentWindow.zig to keep this slice self-contained).
// ---------------------------------------------------------------------------

const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
const WS_CLIPCHILDREN: DWORD = 0x02000000;
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
const WM_PAINT: UINT = 0x000F;
const WM_ERASEBKGND: UINT = 0x0014;
const WM_NCCREATE: UINT = 0x0081;
const WM_TIMER: UINT = 0x0113;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_KEYDOWN: UINT = 0x0100;
const WM_CHAR: UINT = 0x0102;
const WM_KILLFOCUS: UINT = 0x0008;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_LBUTTONDBLCLK: UINT = 0x0203;
const WM_MOUSELEAVE: UINT = 0x02A3;
const WM_SETCURSOR: UINT = 0x0020;
const CS_DBLCLKS: UINT = 0x0008;
const IDC_SIZEWE: usize = 32644;
const VK_BACK: u32 = 0x08;
const VK_RETURN: u32 = 0x0D;
const VK_ESCAPE: u32 = 0x1B;
extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn SetCursor(hCursor: HCURSOR) callconv(.winapi) HCURSOR;
extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) BOOL;
extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;
const HTCLIENT: i32 = 1;
const WM_DPICHANGED: UINT = 0x02E0;

const TME_LEAVE: DWORD = 0x00000002;
const TRACKMOUSEEVENT_S = extern struct {
    cbSize: DWORD,
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD,
};
extern "user32" fn TrackMouseEvent(lpEventTrack: *TRACKMOUSEEVENT_S) callconv(.winapi) BOOL;

// Menu API for the "+" new-tab dropdown.
const WM_COMMAND: UINT = 0x0111;
const MF_STRING: UINT = 0x0000;
const MF_SEPARATOR: UINT = 0x0800;
const TPM_RETURNCMD: UINT = 0x0100;
const TPM_LEFTALIGN: UINT = 0x0000;
const TPM_TOPALIGN: UINT = 0x0000;
const HMENU = ?*anyopaque;
extern "user32" fn CreatePopupMenu() callconv(.winapi) HMENU;
extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.winapi) BOOL;
extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: UINT, uIDNewItem: usize, lpNewItem: ?[*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: UINT, x: i32, y: i32, nReserved: i32, hWnd: HWND, prcRect: ?*const RECT) callconv(.winapi) i32;
extern "user32" fn ClientToScreen(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;
extern "kernel32" fn SearchPathW(
    lpPath: ?[*:0]const u16,
    lpFileName: [*:0]const u16,
    lpExtension: ?[*:0]const u16,
    nBufferLength: DWORD,
    lpBuffer: [*]u16,
    lpFilePart: ?*?[*:0]u16,
) callconv(.winapi) DWORD;

const AUTOHEAL_TIMER_ID: usize = 1;
const AUTOHEAL_INTERVAL_MS: UINT = 2_000;
const MONITOR_DEFAULTTONULL: DWORD = 0;

const SWP_NOZORDER: UINT = 0x0004;
const SWP_NOACTIVATE: UINT = 0x0010;
const SWP_SHOWWINDOW: UINT = 0x0040;

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
    hdc: *anyopaque,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
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
extern "user32" fn InvalidateRect(hWnd: ?HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) ?*anyopaque;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) UINT;

// ---------------------------------------------------------------------------
// Custom WM_APP messages.
// ---------------------------------------------------------------------------

const WM_APP: UINT = 0x8000;
const WM_APP_SET_TITLE: UINT = WM_APP + 1;
const WM_APP_CLOSE_SURFACE: UINT = WM_APP + 2;
const WM_APP_TICK: UINT = WM_APP + 3;
const WM_APP_SET_TAB_TITLE: UINT = WM_APP + 4;
const TabTitleMsg = struct { surface: *Surface, title: []u8 };

// ---------------------------------------------------------------------------
// Direct2D type definitions.
// ---------------------------------------------------------------------------

const D2D1_FACTORY_TYPE_SINGLE_THREADED: u32 = 0;
const D2D1_RENDER_TARGET_TYPE_DEFAULT: u32 = 0;
const D2D1_ALPHA_MODE_PREMULTIPLIED: u32 = 1;
const D2D1_ALPHA_MODE_IGNORE: u32 = 3;
const D2D1_PRESENT_OPTIONS_NONE: u32 = 0;
// Text antialias modes. CLEARTYPE gives crisp subpixel-rendered text on
// opaque render targets; the D2D default on a premultiplied-alpha target
// silently falls back to thin GRAYSCALE which looks fuzzy/washed-out.
const D2D1_TEXT_ANTIALIAS_MODE_DEFAULT: u32 = 0;
const D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE: u32 = 1;
const D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE: u32 = 2;
const D2D1_DEBUG_LEVEL_NONE: u32 = 0;
const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
const D2DERR_RECREATE_TARGET: HRESULT = @bitCast(@as(u32, 0x8899000C));

const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

// IID_ID2D1Factory = {06152247-6f50-465a-9245-118bfd3b6007}
const IID_ID2D1Factory = GUID{
    .Data1 = 0x06152247,
    .Data2 = 0x6f50,
    .Data3 = 0x465a,
    .Data4 = .{ 0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07 },
};

const D2D1_PIXEL_FORMAT = extern struct { format: u32, alphaMode: u32 };
const D2D1_SIZE_U = extern struct { width: u32, height: u32 };
const D2D1_SIZE_F = extern struct { width: f32, height: f32 };
const D2D1_POINT_2F = extern struct { x: f32, y: f32 };
const D2D1_RECT_F = extern struct { left: f32, top: f32, right: f32, bottom: f32 };
const D2D1_COLOR_F = extern struct { r: f32, g: f32, b: f32, a: f32 };
const D2D1_ROUNDED_RECT = extern struct {
    rect: D2D1_RECT_F,
    radiusX: f32,
    radiusY: f32,
};
const D2D1_MATRIX_3X2_F = extern struct {
    _11: f32, _12: f32,
    _21: f32, _22: f32,
    _31: f32, _32: f32,
};
const D2D1_BRUSH_PROPERTIES = extern struct {
    opacity: f32,
    transform: D2D1_MATRIX_3X2_F,
};

const D2D1_RENDER_TARGET_PROPERTIES = extern struct {
    type: u32,
    pixelFormat: D2D1_PIXEL_FORMAT,
    dpiX: f32,
    dpiY: f32,
    usage: u32,
    minLevel: u32,
};

const D2D1_HWND_RENDER_TARGET_PROPERTIES = extern struct {
    hwnd: HWND,
    pixelSize: D2D1_SIZE_U,
    presentOptions: u32,
};

const D2D1_FACTORY_OPTIONS = extern struct {
    debugLevel: u32,
};

// COM interfaces — full vtable layouts (unused slots typed as opaque
// function pointers so the layout is correct without us spelling out
// every signature). Only the slots we actually call are typed.

const ID2D1Factory = extern struct {
    vtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID2D1Factory) callconv(.winapi) u32,
        // ID2D1Factory
        ReloadSystemMetrics: *const anyopaque,
        GetDesktopDpi: *const anyopaque,
        CreateRectangleGeometry: *const anyopaque,
        CreateRoundedRectangleGeometry: *const anyopaque,
        CreateEllipseGeometry: *const anyopaque,
        CreateGeometryGroup: *const anyopaque,
        CreateTransformedGeometry: *const anyopaque,
        CreatePathGeometry: *const anyopaque,
        CreateStrokeStyle: *const anyopaque,
        CreateDrawingStateBlock: *const anyopaque,
        CreateWicBitmapRenderTarget: *const anyopaque,
        CreateHwndRenderTarget: *const fn (
            *ID2D1Factory,
            *const D2D1_RENDER_TARGET_PROPERTIES,
            *const D2D1_HWND_RENDER_TARGET_PROPERTIES,
            *?*ID2D1HwndRenderTarget,
        ) callconv(.winapi) HRESULT,
        CreateDxgiSurfaceRenderTarget: *const anyopaque,
        CreateDCRenderTarget: *const anyopaque,
    };
};

const ID2D1HwndRenderTarget = extern struct {
    vtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID2D1HwndRenderTarget) callconv(.winapi) u32,
        // ID2D1Resource
        GetFactory: *const anyopaque,
        // ID2D1RenderTarget
        CreateBitmap: *const anyopaque,
        CreateBitmapFromWicBitmap: *const anyopaque,
        CreateSharedBitmap: *const anyopaque,
        CreateBitmapBrush: *const anyopaque,
        CreateSolidColorBrush: *const fn (
            *ID2D1HwndRenderTarget,
            *const D2D1_COLOR_F,
            ?*const D2D1_BRUSH_PROPERTIES,
            *?*ID2D1SolidColorBrush,
        ) callconv(.winapi) HRESULT,
        CreateGradientStopCollection: *const anyopaque,
        CreateLinearGradientBrush: *const anyopaque,
        CreateRadialGradientBrush: *const anyopaque,
        CreateCompatibleRenderTarget: *const anyopaque,
        CreateLayer: *const anyopaque,
        CreateMesh: *const anyopaque,
        DrawLine: *const anyopaque,
        DrawRectangle: *const anyopaque,
        FillRectangle: *const fn (
            *ID2D1HwndRenderTarget,
            *const D2D1_RECT_F,
            *ID2D1Brush,
        ) callconv(.winapi) void,
        DrawRoundedRectangle: *const anyopaque,
        FillRoundedRectangle: *const fn (
            *ID2D1HwndRenderTarget,
            *const D2D1_ROUNDED_RECT,
            *ID2D1Brush,
        ) callconv(.winapi) void,
        DrawEllipse: *const anyopaque,
        FillEllipse: *const anyopaque,
        DrawGeometry: *const anyopaque,
        FillGeometry: *const anyopaque,
        FillMesh: *const anyopaque,
        FillOpacityMask: *const anyopaque,
        DrawBitmap: *const anyopaque,
        DrawText: *const fn (
            *ID2D1HwndRenderTarget,
            [*]const u16,
            u32,
            *IDWriteTextFormat,
            *const D2D1_RECT_F,
            *ID2D1Brush,
            u32,
            u32,
        ) callconv(.winapi) void,
        DrawTextLayout: *const anyopaque,
        DrawGlyphRun: *const anyopaque,
        SetTransform: *const anyopaque,
        GetTransform: *const anyopaque,
        SetAntialiasMode: *const anyopaque,
        GetAntialiasMode: *const anyopaque,
        SetTextAntialiasMode: *const fn (*ID2D1HwndRenderTarget, u32) callconv(.winapi) void,
        GetTextAntialiasMode: *const anyopaque,
        SetTextRenderingParams: *const anyopaque,
        GetTextRenderingParams: *const anyopaque,
        SetTags: *const anyopaque,
        GetTags: *const anyopaque,
        PushLayer: *const anyopaque,
        PopLayer: *const anyopaque,
        Flush: *const anyopaque,
        SaveDrawingState: *const anyopaque,
        RestoreDrawingState: *const anyopaque,
        PushAxisAlignedClip: *const anyopaque,
        PopAxisAlignedClip: *const anyopaque,
        Clear: *const fn (*ID2D1HwndRenderTarget, ?*const D2D1_COLOR_F) callconv(.winapi) void,
        BeginDraw: *const fn (*ID2D1HwndRenderTarget) callconv(.winapi) void,
        EndDraw: *const fn (*ID2D1HwndRenderTarget, ?*u64, ?*u64) callconv(.winapi) HRESULT,
        GetPixelFormat: *const anyopaque,
        GetDpi: *const anyopaque,
        GetSize: *const anyopaque,
        GetPixelSize: *const anyopaque,
        GetMaximumBitmapSize: *const anyopaque,
        IsSupported: *const anyopaque,
        // ID2D1HwndRenderTarget
        CheckWindowState: *const anyopaque,
        Resize: *const fn (*ID2D1HwndRenderTarget, *const D2D1_SIZE_U) callconv(.winapi) HRESULT,
        GetHwnd: *const anyopaque,
    };
};

// We never need to call any methods on ID2D1Brush directly — only pass it
// to FillRectangle / FillRoundedRectangle. Define just the Release slot
// for ID2D1SolidColorBrush.
const ID2D1Brush = extern struct { vtbl: *const anyopaque };

const ID2D1SolidColorBrush = extern struct {
    vtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID2D1SolidColorBrush) callconv(.winapi) u32,
        GetFactory: *const anyopaque,
        SetOpacity: *const anyopaque,
        SetTransform: *const anyopaque,
        GetOpacity: *const anyopaque,
        GetTransform: *const anyopaque,
        SetColor: *const anyopaque,
        GetColor: *const anyopaque,
    };
};

// ---------------------------------------------------------------------------
// DirectWrite — needed for any text. CreateTextFormat once at startup,
// reused across paints; DrawText is on the D2D render target.
// ---------------------------------------------------------------------------

const DWRITE_FACTORY_TYPE_SHARED: u32 = 0;
const DWRITE_FONT_WEIGHT_NORMAL: u32 = 400;
const DWRITE_FONT_STYLE_NORMAL: u32 = 0;
const DWRITE_FONT_STRETCH_NORMAL: u32 = 5;
const DWRITE_TEXT_ALIGNMENT_LEADING: u32 = 0;
const DWRITE_TEXT_ALIGNMENT_TRAILING: u32 = 1;
const DWRITE_TEXT_ALIGNMENT_CENTER: u32 = 2;
// DWRITE_PARAGRAPH_ALIGNMENT: NEAR=0 (top), FAR=1 (bottom), CENTER=2.
// (This was previously set to 1 by mistake, which bottom-aligned all
// tab/search/icon text instead of vertically centering it.)
const DWRITE_PARAGRAPH_ALIGNMENT_CENTER: u32 = 2;
const DWRITE_WORD_WRAPPING_NO_WRAP: u32 = 1;

// IID_IDWriteFactory = {b859ee5a-d838-4b5b-a2e8-1adc7d93db48}
const IID_IDWriteFactory = GUID{
    .Data1 = 0xb859ee5a,
    .Data2 = 0xd838,
    .Data3 = 0x4b5b,
    .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 },
};

const IDWriteFactory = extern struct {
    vtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDWriteFactory) callconv(.winapi) u32,
        GetSystemFontCollection: *const anyopaque,
        CreateCustomFontCollection: *const anyopaque,
        RegisterFontCollectionLoader: *const anyopaque,
        UnregisterFontCollectionLoader: *const anyopaque,
        CreateFontFileReference: *const anyopaque,
        CreateCustomFontFileReference: *const anyopaque,
        CreateFontFace: *const anyopaque,
        CreateRenderingParams: *const anyopaque,
        CreateMonitorRenderingParams: *const anyopaque,
        CreateCustomRenderingParams: *const anyopaque,
        RegisterFontFileLoader: *const anyopaque,
        UnregisterFontFileLoader: *const anyopaque,
        CreateTextFormat: *const fn (
            *IDWriteFactory,
            [*:0]const u16, // fontFamilyName
            ?*anyopaque, // fontCollection (null = system)
            u32, // fontWeight
            u32, // fontStyle
            u32, // fontStretch
            f32, // fontSize (DIP)
            [*:0]const u16, // localeName
            *?*IDWriteTextFormat,
        ) callconv(.winapi) HRESULT,
        CreateTypography: *const anyopaque,
        GetGdiInterop: *const anyopaque,
        CreateTextLayout: *const anyopaque,
        CreateGdiCompatibleTextLayout: *const anyopaque,
        CreateEllipsisTrimmingSign: *const fn (
            *IDWriteFactory,
            *IDWriteTextFormat,
            *?*IDWriteInlineObject,
        ) callconv(.winapi) HRESULT,
        // ... remaining slots unused
    };
};

const IDWriteInlineObject = extern struct { vtbl: *const anyopaque };

const DWRITE_TRIMMING_GRANULARITY_CHARACTER: u32 = 1;
const DWRITE_TRIMMING = extern struct {
    granularity: u32,
    delimiter: u32,
    delimiterCount: u32,
};

const IDWriteTextFormat = extern struct {
    vtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDWriteTextFormat) callconv(.winapi) u32,
        SetTextAlignment: *const fn (*IDWriteTextFormat, u32) callconv(.winapi) HRESULT,
        SetParagraphAlignment: *const fn (*IDWriteTextFormat, u32) callconv(.winapi) HRESULT,
        SetWordWrapping: *const fn (*IDWriteTextFormat, u32) callconv(.winapi) HRESULT,
        SetReadingDirection: *const anyopaque,
        SetFlowDirection: *const anyopaque,
        SetIncrementalTabStop: *const anyopaque,
        SetTrimming: *const fn (
            *IDWriteTextFormat,
            *const DWRITE_TRIMMING,
            ?*IDWriteInlineObject,
        ) callconv(.winapi) HRESULT,
        // ... remaining slots unused
    };
};

extern "dwrite" fn DWriteCreateFactory(
    factoryType: u32,
    iid: *const GUID,
    factory: *?*IDWriteFactory,
) callconv(.winapi) HRESULT;

extern "d2d1" fn D2D1CreateFactory(
    factoryType: u32,
    riid: *const GUID,
    pFactoryOptions: ?*const D2D1_FACTORY_OPTIONS,
    ppIFactory: *?*ID2D1Factory,
) callconv(.winapi) HRESULT;

// ---------------------------------------------------------------------------
// Chrome dimensions (96-DPI base; scaled per-window).
// ---------------------------------------------------------------------------

/// Default sidebar width when expanded; users can drag the right edge
/// to override within [sidebar_min_base, sidebar_max_base].
const sidebar_expanded_base: i32 = 280;
const sidebar_min_base: i32 = 180;
const sidebar_max_base: i32 = 560;
/// Width (DIPs) of the splitter strip at the sidebar's right edge that
/// catches drag-to-resize.
const splitter_grab_base: i32 = 6;
/// Sidebar width when collapsed to an icon-only rail.
const sidebar_collapsed_base: i32 = 48;
/// Header band height (top bar with icon buttons).
const header_height_base: i32 = 40;
/// Per-tab row height in the sidebar.
const tab_row_height_base: i32 = 44;
/// Horizontal padding inside the sidebar.
const sidebar_pad_base: i32 = 10;
/// Left padding for the tab title text inside its pill (after the icon).
const tab_text_pad_base: i32 = 14;
/// Left padding for the tab icon inside its pill.
const tab_icon_pad_base: i32 = 12;
/// Width reserved for the tab's leading icon.
const tab_icon_w_base: i32 = 18;
/// Corner radius of the active/hover tab pill.
const tab_pill_radius_base: i32 = 8;
/// Header icon button (square hit-target) side length.
const header_btn_base: i32 = 32;
/// Left padding inside the header before the first icon.
const header_pad_base: i32 = 8;
/// Gap between header icons.
const header_gap_base: i32 = 4;
/// Corner radius for the hovered header-icon background.
const header_btn_radius_base: i32 = 6;
/// Search field height (only shown when sidebar is expanded).
const search_field_height_base: i32 = 32;
/// Corner radius of the search field's rounded background.
const search_field_radius_base: i32 = 6;

// Segoe Fluent Icons / MDL2 Assets glyph codepoints. These work on both
// Win10 (Segoe MDL2 Assets) and Win11 (Segoe Fluent Icons).
const ICON_PANEL_TOGGLE: u16 = 0xE700; // GlobalNavButton (hamburger)
const ICON_SETTINGS: u16 = 0xE713; // Settings (gear)
const ICON_TILES: u16 = 0xE80A; // Tiles
const ICON_NEW_TAB: u16 = 0xE710; // Add (+)
const ICON_TAB_PROMPT: u16 = 0xE756; // CommandPrompt (>_)

// ---------------------------------------------------------------------------
// Public state.
// ---------------------------------------------------------------------------

alloc: Allocator,
app: *ApprtApp,
hwnd: HWND,
/// One Surface per tab (single tab today; tab list UI lands in slice 2).
tabs: std.array_list.Managed(*Surface),
active: usize = 0,

// D2D resources. Recreated on demand if EndDraw returns D2DERR_RECREATE_TARGET.
d2d_factory: ?*ID2D1Factory = null,
rt: ?*ID2D1HwndRenderTarget = null,
brush_sidebar: ?*ID2D1SolidColorBrush = null,
brush_header: ?*ID2D1SolidColorBrush = null,
brush_background: ?*ID2D1SolidColorBrush = null,
brush_tab_active: ?*ID2D1SolidColorBrush = null,
brush_tab_hover: ?*ID2D1SolidColorBrush = null,
brush_text: ?*ID2D1SolidColorBrush = null,
brush_text_dim: ?*ID2D1SolidColorBrush = null,

// DirectWrite — created once at startup, survives render-target loss.
dwrite_factory: ?*IDWriteFactory = null,
tab_text_format: ?*IDWriteTextFormat = null,
/// Inline ellipsis "..." sign used by tab_text_format for trimming
/// titles that overflow the pill width.
tab_ellipsis_sign: ?*IDWriteInlineObject = null,
/// Segoe Fluent Icons / MDL2 Assets — for header buttons + per-tab glyph.
icon_text_format: ?*IDWriteTextFormat = null,
/// Larger icon format for header buttons (slightly bigger than the
/// per-tab icon so the chrome controls feel like actionable buttons).
icon_text_format_header: ?*IDWriteTextFormat = null,

/// Index of tab currently under the mouse, if any. Used for hover state.
hover_tab: ?usize = null,
/// True after we've armed TrackMouseEvent for WM_MOUSELEAVE; reset on leave.
mouse_tracking: bool = false,

/// Which header chrome control is hovered, if any.
hover_header: ?HeaderControl = null,
/// Whether the sidebar is collapsed to an icon-only rail (~48 DIPs)
/// rather than the full expanded width (280 DIPs). Toggled by the
/// panel-toggle icon in the header.
collapsed: bool = false,

/// Available shell choices for the new-tab "+" dropdown. Populated
/// once at startup by probing PATH + well-known install dirs. The
/// strings inside are owned by `self.alloc`.
shells: std.array_list.Managed(Shell) = undefined,
/// Default shell to launch when `newTab` is called without an explicit
/// command (initial tab + keyboard `Ctrl+Shift+T`). Prefer pwsh.exe
/// (PowerShell 7+) when present; null falls through to Ghostty's
/// engine default (powershell.exe on Windows).
default_command: ?[:0]const u8 = null,

/// Tab currently being renamed (index into `tabs`), if any.
renaming: ?usize = null,
/// Edit buffer for the rename (UTF-8). Bounded; long titles get truncated
/// when entering rename mode. Used only while `renaming != null`.
rename_buf: [256]u8 = undefined,
rename_len: u32 = 0,

/// Filter query for the tab search field. Empty = no filter, every tab
/// is visible. Stored as UTF-8.
search_buf: [128]u8 = undefined,
search_len: u32 = 0,
/// True while the user is typing into the search field. Drives the
/// keyboard input routing in WM_CHAR / WM_KEYDOWN.
search_focused: bool = false,

/// User-chosen sidebar width override in DIPs. null = use default.
/// Set by the resize drag handle.
sidebar_width_override: ?i32 = null,
/// True while the user is dragging the sidebar's right edge.
dragging_splitter: bool = false,
/// Physical-px mouse X when drag started.
drag_anchor_x: i32 = 0,
/// Sidebar width (DIPs) when drag started.
drag_anchor_width: i32 = 0,

const HeaderControl = enum { panel_toggle, new_tab };

/// One entry in the new-tab dropdown. `command` is a shell command
/// string (i.e. an argv0 plus optional args, parsed by Ghostty's
/// config.Command.shell variant).
pub const Shell = struct {
    name: [:0]const u8,
    command: [:0]const u8,
};

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWin32ChromeParent");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");

// ---------------------------------------------------------------------------
// Lifecycle.
// ---------------------------------------------------------------------------

pub fn create(alloc: Allocator, app: *ApprtApp) !*Self {
    const hmodule = GetModuleHandleW(null);
    const hinstance: HINSTANCE = @ptrFromInt(@intFromPtr(hmodule));

    var wc: WNDCLASSEXW = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.style = CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS;
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
        .shells = std.array_list.Managed(Shell).init(alloc),
    };
    self.detectShells() catch |e| log.warn("shell detection failed: {}", .{e});

    // Direct2D factory — single-threaded, no debug layer. One per window.
    var factory: ?*ID2D1Factory = null;
    const hr_fact = D2D1CreateFactory(
        D2D1_FACTORY_TYPE_SINGLE_THREADED,
        &IID_ID2D1Factory,
        null,
        &factory,
    );
    if (hr_fact < 0 or factory == null) {
        log.err("D2D1CreateFactory failed hr=0x{x}", .{@as(u32, @bitCast(hr_fact))});
        return error.D2DFactoryFailed;
    }
    self.d2d_factory = factory;

    // DirectWrite factory + tab title text format. Segoe UI 13pt regular.
    var dwf: ?*IDWriteFactory = null;
    const hr_dw = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory, &dwf);
    if (hr_dw < 0 or dwf == null) {
        log.err("DWriteCreateFactory failed hr=0x{x}", .{@as(u32, @bitCast(hr_dw))});
        return error.DWriteFactoryFailed;
    }
    self.dwrite_factory = dwf;
    const segoe = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
    const en_us = std.unicode.utf8ToUtf16LeStringLiteral("en-us");
    var tf: ?*IDWriteTextFormat = null;
    const hr_tf = dwf.?.vtbl.CreateTextFormat(
        dwf.?,
        segoe,
        null,
        DWRITE_FONT_WEIGHT_NORMAL,
        DWRITE_FONT_STYLE_NORMAL,
        DWRITE_FONT_STRETCH_NORMAL,
        13.0,
        en_us,
        &tf,
    );
    if (hr_tf < 0 or tf == null) {
        log.err("CreateTextFormat failed hr=0x{x}", .{@as(u32, @bitCast(hr_tf))});
        return error.DWriteTextFormatFailed;
    }
    self.tab_text_format = tf;
    _ = tf.?.vtbl.SetTextAlignment(tf.?, DWRITE_TEXT_ALIGNMENT_LEADING);
    _ = tf.?.vtbl.SetParagraphAlignment(tf.?, DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    _ = tf.?.vtbl.SetWordWrapping(tf.?, DWRITE_WORD_WRAPPING_NO_WRAP);

    // Ellipsis trimming on the tab title: overflow renders as "...".
    var ellipsis: ?*IDWriteInlineObject = null;
    _ = dwf.?.vtbl.CreateEllipsisTrimmingSign(dwf.?, tf.?, &ellipsis);
    const trim = DWRITE_TRIMMING{
        .granularity = DWRITE_TRIMMING_GRANULARITY_CHARACTER,
        .delimiter = 0,
        .delimiterCount = 0,
    };
    _ = tf.?.vtbl.SetTrimming(tf.?, &trim, ellipsis);
    self.tab_ellipsis_sign = ellipsis;

    // Icon text formats — Segoe Fluent Icons on Win11, falls through to
    // Segoe MDL2 Assets on Win10 (codepoints overlap). DirectWrite font
    // fallback handles the resolution; we just spell the name.
    // Per-tab icon matches the tab title font size so they sit on the
    // same baseline; header buttons get a slightly larger glyph.
    self.icon_text_format = try self.createIconFormat(dwf.?, "Segoe Fluent Icons", 13.0);
    self.icon_text_format_header = try self.createIconFormat(dwf.?, "Segoe Fluent Icons", 16.0);

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
    ) orelse return error.CreateChromeWindowFailed;
    self.hwnd = hwnd;

    _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @intCast(@intFromPtr(self)));
    _ = ShowWindow(hwnd, SW_SHOWDEFAULT);
    _ = UpdateWindow(hwnd);

    _ = SetTimer(hwnd, AUTOHEAL_TIMER_ID, AUTOHEAL_INTERVAL_MS, null);

    return self;
}

pub fn deinit(self: *Self) void {
    _ = KillTimer(self.hwnd, AUTOHEAL_TIMER_ID);
    self.releaseRenderTargetResources();
    if (self.tab_ellipsis_sign) |s| {
        // IDWriteInlineObject's first vtable slot is QueryInterface; the
        // third is Release. We never typed it; just call the raw COM
        // Release through a casted vtable index.
        const vtbl_array: *const [3]*const fn (*IDWriteInlineObject) callconv(.winapi) u32 =
            @ptrCast(@alignCast(s.vtbl));
        _ = vtbl_array[2](s);
        self.tab_ellipsis_sign = null;
    }
    inline for (.{
        "tab_text_format",
        "icon_text_format",
        "icon_text_format_header",
    }) |fname| {
        if (@field(self, fname)) |tf| {
            _ = tf.vtbl.Release(tf);
            @field(self, fname) = null;
        }
    }
    if (self.dwrite_factory) |f| {
        _ = f.vtbl.Release(f);
        self.dwrite_factory = null;
    }
    if (self.d2d_factory) |f| {
        _ = f.vtbl.Release(f);
        self.d2d_factory = null;
    }
    for (self.tabs.items) |s| s.deinit();
    self.tabs.deinit();
    for (self.shells.items) |sh| {
        self.alloc.free(sh.name);
        self.alloc.free(sh.command);
    }
    self.shells.deinit();
    if (self.default_command) |c| self.alloc.free(c);
    self.alloc.destroy(self);
}

fn releaseRenderTargetResources(self: *Self) void {
    inline for (.{
        "brush_sidebar",
        "brush_header",
        "brush_background",
        "brush_tab_active",
        "brush_tab_hover",
        "brush_text",
        "brush_text_dim",
    }) |fname| {
        if (@field(self, fname)) |b| {
            _ = b.vtbl.Release(b);
            @field(self, fname) = null;
        }
    }
    if (self.rt) |rt| {
        _ = rt.vtbl.Release(rt);
        self.rt = null;
    }
}

// ---------------------------------------------------------------------------
// Public API (matches ParentWindow surface used by App.zig).
// ---------------------------------------------------------------------------

pub fn run(self: *Self) !void {
    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
    _ = self;
}

pub fn activeSurface(self: *const Self) ?*Surface {
    if (self.tabs.items.len == 0) return null;
    return self.tabs.items[self.active];
}

pub fn appendTab(self: *Self, surface: *Surface) !void {
    try self.tabs.append(surface);
    self.active = self.tabs.items.len - 1;
    self.applyActiveVisibility();
    self.layoutActive();
}

pub fn newTab(self: *Self) !void {
    // If the caller didn't pre-set pending_command (e.g. initial tab
    // from App.run, or keyboard Ctrl+Shift+T), prefer pwsh.exe when
    // we detected one at startup.
    const prev = self.app.pending_command;
    const using_default = self.app.pending_command == null and self.default_command != null;
    if (using_default) self.app.pending_command = self.default_command;
    defer if (using_default) {
        self.app.pending_command = prev;
    };

    const surface = try Surface.create(self.alloc, self.app, @ptrCast(self.hwnd));
    errdefer surface.deinit();
    try self.appendTab(surface);
}

/// Spawn a new tab using `command` (a shell command string) instead of the
/// default. Pending-command is set on app for Surface.create to pick up.
pub fn newTabWithCommand(self: *Self, command: [:0]const u8) !void {
    const prev = self.app.pending_command;
    self.app.pending_command = command;
    defer self.app.pending_command = prev;
    try self.newTab();
}

// ---------------------------------------------------------------------------
// Shell discovery.
// ---------------------------------------------------------------------------

/// Resolve `exe` via the system PATH. Returns an owned absolute path or
/// null if not found. Caller owns the returned slice.
fn resolveOnPath(self: *Self, exe_utf8: []const u8) ?[:0]u8 {
    var name_buf: [260]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&name_buf, exe_utf8) catch return null;
    if (wlen >= name_buf.len) return null;
    name_buf[wlen] = 0;
    var out_buf: [windows.MAX_PATH]u16 = undefined;
    const n = SearchPathW(
        null,
        @ptrCast(&name_buf),
        null,
        out_buf.len,
        &out_buf,
        null,
    );
    if (n == 0 or n >= out_buf.len) return null;
    var u8_buf: [windows.MAX_PATH * 3]u8 = undefined;
    const u8_len = std.unicode.utf16LeToUtf8(&u8_buf, out_buf[0..n]) catch return null;
    return self.alloc.dupeZ(u8, u8_buf[0..u8_len]) catch null;
}

fn appendShell(self: *Self, name: []const u8, command: []const u8) !void {
    try self.shells.append(.{
        .name = try self.alloc.dupeZ(u8, name),
        .command = try self.alloc.dupeZ(u8, command),
    });
}

fn detectShells(self: *Self) !void {
    // PowerShell 7+ — typically `pwsh.exe` on PATH after install. We
    // try this FIRST so we can also make it the default for fresh tabs;
    // the legacy "Windows PowerShell" stays available in the dropdown
    // but doesn't get the default slot.
    if (self.resolveOnPath("pwsh.exe")) |p| {
        defer self.alloc.free(p);
        try self.appendShell("PowerShell 7", p);
        self.default_command = try self.alloc.dupeZ(u8, p);
    }

    // Always-available Windows shells.
    try self.appendShell("Windows PowerShell", "powershell.exe");
    try self.appendShell("Command Prompt", "cmd.exe");

    // Git for Windows ships `bash.exe` in its bin/.
    if (self.resolveOnPath("bash.exe")) |p| {
        defer self.alloc.free(p);
        try self.appendShell("Git Bash", p);
    }

    // WSL — `wsl.exe` on PATH means the WSL platform is available.
    if (self.resolveOnPath("wsl.exe")) |p| {
        defer self.alloc.free(p);
        try self.appendShell("WSL", p);
    }
}

// ---------------------------------------------------------------------------
// Inline tab rename (double-click a pill to start, Enter commit, Esc cancel).
// ---------------------------------------------------------------------------

fn startRename(self: *Self, idx: usize) void {
    if (idx >= self.tabs.items.len) return;
    self.renaming = idx;
    self.rename_len = 0;
    // Seed buffer with the friendly label so the user edits a clean name
    // (e.g. "PowerShell") rather than the raw exe path.
    var fbuf: [260]u8 = undefined;
    const seed = self.friendlyLabel(idx, &fbuf);
    const n = @min(seed.len, self.rename_buf.len);
    @memcpy(self.rename_buf[0..n], seed[0..n]);
    self.rename_len = @intCast(n);
    // Steal keyboard focus from the terminal child so we get WM_CHAR.
    _ = SetFocus(self.hwnd);
    _ = InvalidateRect(self.hwnd, null, FALSE);
}

fn commitRename(self: *Self) void {
    const idx = self.renaming orelse return;
    self.renaming = null;
    if (idx >= self.tabs.items.len) return;
    const surf = self.tabs.items[idx];
    if (surf.title) |old| self.alloc.free(old);
    surf.title = self.alloc.dupe(u8, self.rename_buf[0..self.rename_len]) catch null;
    surf.title_pinned = true; // OSC 0/1/2 from now on will be ignored.
    // Return focus to the active terminal so typing resumes there.
    if (self.activeSurface()) |s| _ = SetFocus(s.window.hwnd);
    _ = InvalidateRect(self.hwnd, null, FALSE);
}

fn cancelRename(self: *Self) void {
    self.renaming = null;
    if (self.activeSurface()) |s| _ = SetFocus(s.window.hwnd);
    _ = InvalidateRect(self.hwnd, null, FALSE);
}

/// Handle a WM_CHAR while the search field is focused. Same input model
/// as rename — Backspace removes a UTF-8 codepoint, printable chars
/// append.
fn handleSearchChar(self: *Self, ch: u16) void {
    if (!self.search_focused) return;
    if (ch == 0x08) {
        if (self.search_len > 0) {
            var n = self.search_len - 1;
            while (n > 0 and (self.search_buf[n] & 0xC0) == 0x80) : (n -= 1) {}
            self.search_len = n;
            _ = InvalidateRect(self.hwnd, null, FALSE);
        }
        return;
    }
    if (ch < 0x20) return;
    if (ch >= 0xD800 and ch <= 0xDFFF) return;
    var enc: [3]u8 = undefined;
    const n = std.unicode.utf8Encode(ch, &enc) catch return;
    if (self.search_len + n > self.search_buf.len) return;
    @memcpy(self.search_buf[self.search_len..][0..n], enc[0..n]);
    self.search_len += @intCast(n);
    _ = InvalidateRect(self.hwnd, null, FALSE);
}

fn clearAndUnfocusSearch(self: *Self) void {
    self.search_len = 0;
    self.search_focused = false;
    if (self.activeSurface()) |s| _ = SetFocus(s.window.hwnd);
    _ = InvalidateRect(self.hwnd, null, FALSE);
}

/// Handle a WM_CHAR while in rename mode. `ch` is a UTF-16 code unit;
/// supplementary plane surrogate pairs are skipped (rare in tab titles).
fn handleRenameChar(self: *Self, ch: u16) void {
    if (self.renaming == null) return;
    // VK_BACK is delivered as a WM_CHAR ASCII control char before
    // WM_KEYDOWN's separate path — handle here for simplicity.
    if (ch == 0x08) { // backspace
        if (self.rename_len > 0) {
            // Remove last UTF-8 codepoint, not just last byte.
            var n = self.rename_len - 1;
            while (n > 0 and (self.rename_buf[n] & 0xC0) == 0x80) : (n -= 1) {}
            self.rename_len = n;
            _ = InvalidateRect(self.hwnd, null, FALSE);
        }
        return;
    }
    if (ch < 0x20) return; // ignore other control chars (Enter handled in WM_KEYDOWN)
    if (ch >= 0xD800 and ch <= 0xDFFF) return; // skip surrogates

    // Encode UTF-16 code unit (BMP) → UTF-8 (1–3 bytes).
    var enc: [3]u8 = undefined;
    const n = std.unicode.utf8Encode(ch, &enc) catch return;
    if (self.rename_len + n > self.rename_buf.len) return; // buffer full
    @memcpy(self.rename_buf[self.rename_len..][0..n], enc[0..n]);
    self.rename_len += @intCast(n);
    _ = InvalidateRect(self.hwnd, null, FALSE);
}

// ---------------------------------------------------------------------------
// New-tab dropdown.
// ---------------------------------------------------------------------------

/// Show the native popup menu listing every detected shell. Pinned to
/// the bottom-left of the "+" header button so it visually drops down
/// from the chevron.
fn showNewTabMenu(self: *Self) void {
    const menu = CreatePopupMenu() orelse return;
    defer _ = DestroyMenu(menu);

    // Build menu items. ID 0 reserved as "no selection"; we start at 1.
    var w_buf: [256]u16 = undefined;
    for (self.shells.items, 0..) |sh, i| {
        const wlen = std.unicode.utf8ToUtf16Le(&w_buf, sh.name) catch continue;
        if (wlen >= w_buf.len) continue;
        w_buf[wlen] = 0;
        _ = AppendMenuW(menu, MF_STRING, i + 1, @ptrCast(&w_buf));
    }

    // Anchor the menu to the bottom-left of the "+" button in screen coords.
    const r = self.headerBtnRectDip(headerCtrlIndex(.new_tab));
    const dpi: i32 = self.currentDpi();
    var pt = POINT{
        .x = @intFromFloat(r.left * @as(f32, @floatFromInt(dpi)) / 96.0),
        .y = @intFromFloat(r.bottom * @as(f32, @floatFromInt(dpi)) / 96.0),
    };
    _ = ClientToScreen(self.hwnd, &pt);

    const id = TrackPopupMenu(
        menu,
        TPM_RETURNCMD | TPM_LEFTALIGN | TPM_TOPALIGN,
        pt.x,
        pt.y,
        0,
        self.hwnd,
        null,
    );
    if (id <= 0) return; // canceled
    const idx: usize = @intCast(@as(usize, @intCast(id)) - 1);
    if (idx >= self.shells.items.len) return;
    const cmd = self.shells.items[idx].command;
    self.newTabWithCommand(cmd) catch |e|
        log.warn("newTabWithCommand failed: {}", .{e});
}

pub fn closeTab(self: *Self, idx: usize) void {
    if (idx >= self.tabs.items.len) return;
    const surface = self.tabs.orderedRemove(idx);
    surface.deinit();
    if (self.tabs.items.len == 0) {
        PostQuitMessage(0);
        return;
    }
    if (self.active >= self.tabs.items.len) {
        self.active = self.tabs.items.len - 1;
    } else if (self.active > idx) {
        self.active -= 1;
    }
    self.applyActiveVisibility();
    self.layoutActive();
}

pub fn switchTab(self: *Self, idx: usize) void {
    if (idx >= self.tabs.items.len or idx == self.active) return;
    self.active = idx;
    self.applyActiveVisibility();
    self.layoutActive();
}

pub fn cycleTab(self: *Self, offset: i32) void {
    if (self.tabs.items.len < 2) return;
    const n: i32 = @intCast(self.tabs.items.len);
    const cur: i32 = @intCast(self.active);
    var next: i32 = @mod(cur + offset, n);
    if (next < 0) next += n;
    self.switchTab(@intCast(next));
}

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

pub fn requestCloseSurface(self: *const Self, surface: *Surface) void {
    _ = PostMessageW(self.hwnd, WM_APP_CLOSE_SURFACE, @intFromPtr(surface), 0);
}

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

pub fn requestTick(self: *const Self) void {
    _ = PostMessageW(self.hwnd, WM_APP_TICK, 0, 0);
}

fn tickCoreApp(self: *Self) void {
    self.app.core_app.tick(self.app) catch |err|
        log.warn("core app tick failed: {}", .{err});
}

// ---------------------------------------------------------------------------
// Layout.
// ---------------------------------------------------------------------------

/// DPI used by all geometry math. We sample GetDpiForWindow once per
/// frame in paint() and once per call in layoutActive() so that paint,
/// layout, and hit-test all agree on the same scale within a tick.
fn currentDpi(self: *const Self) i32 {
    return @intCast(GetDpiForWindow(self.hwnd));
}

fn scalePx(self: *const Self, base: i32) i32 {
    return @divTrunc(base * self.currentDpi(), 96);
}

/// Sidebar width in DIPs (logical units). Collapsed state forces the
/// rail width; otherwise the user override (set via splitter drag)
/// wins, falling back to `sidebar_expanded_base`.
fn sidebarBase(self: *const Self) i32 {
    if (self.collapsed) return sidebar_collapsed_base;
    if (self.sidebar_width_override) |w| return w;
    return sidebar_expanded_base;
}

fn sidebarWidth(self: *const Self) i32 {
    return self.scalePx(self.sidebarBase());
}

fn headerHeight(self: *const Self) i32 {
    return self.scalePx(header_height_base);
}

fn applyActiveVisibility(self: *Self) void {
    for (self.tabs.items, 0..) |s, i| {
        const cmd: i32 = if (i == self.active) 5 else 0; // SW_SHOW vs SW_HIDE
        _ = ShowWindow(s.window.hwnd, cmd);
    }
    if (self.activeSurface()) |active| _ = SetFocus(active.window.hwnd);
}

fn layoutActive(self: *Self) void {
    const surface = self.activeSurface() orelse return;
    const sb = self.sidebarWidth();
    var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = GetClientRect(self.hwnd, &rect);
    // Terminal fills the entire area to the right of the sidebar, from the
    // top of the client area down. There's no top header strip in the
    // modern chrome — the hamburger/new-tab buttons live in the sidebar's
    // own top region, so the console gets the full height beside it.
    const w = @max(0, rect.right - rect.left - sb);
    const h = @max(0, rect.bottom - rect.top);
    _ = SetWindowPos(
        surface.window.hwnd,
        null,
        sb,
        0,
        w,
        h,
        SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW,
    );
    _ = InvalidateRect(surface.window.hwnd, null, FALSE);
    _ = InvalidateRect(self.hwnd, null, FALSE);
}

fn autoHeal(self: *Self) void {
    if (MonitorFromWindow(self.hwnd, MONITOR_DEFAULTTONULL) == null) {
        var r: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = GetClientRect(self.hwnd, &r);
        const w = @max(800, r.right - r.left);
        const h = @max(600, r.bottom - r.top);
        _ = SetWindowPos(self.hwnd, null, 100, 100, w, h, SWP_NOZORDER);
    }
    if (GetForegroundWindow() == self.hwnd) {
        // Don't steal focus from the chrome when the user is mid-rename
        // or typing into the search field — those are the cases where
        // the chrome legitimately holds keyboard focus.
        if (self.renaming != null or self.search_focused) return;
        if (self.activeSurface()) |s| {
            if (GetFocus() != s.window.hwnd) _ = SetFocus(s.window.hwnd);
        }
    }
}

// ---------------------------------------------------------------------------
// D2D paint.
// ---------------------------------------------------------------------------

fn ensureRenderTarget(self: *Self) !void {
    if (self.rt != null) return;
    const factory = self.d2d_factory orelse return error.NoFactory;

    var client: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = GetClientRect(self.hwnd, &client);
    const w: u32 = @intCast(@max(1, client.right - client.left));
    const h: u32 = @intCast(@max(1, client.bottom - client.top));

    const dpi_f: f32 = @floatFromInt(GetDpiForWindow(self.hwnd));
    const rt_props = D2D1_RENDER_TARGET_PROPERTIES{
        .type = D2D1_RENDER_TARGET_TYPE_DEFAULT,
        .pixelFormat = .{
            .format = DXGI_FORMAT_B8G8R8A8_UNORM,
            // IGNORE (opaque) rather than PREMULTIPLIED: an HWND render
            // target is always opaque, and an opaque target is what lets
            // DirectWrite use ClearType subpixel antialiasing. With
            // premultiplied alpha, D2D silently downgrades text to thin
            // grayscale AA which reads as fuzzy/washed-out on-screen.
            .alphaMode = D2D1_ALPHA_MODE_IGNORE,
        },
        // RT scales DIPs → physical via this DPI. Coords inside paint()
        // are DIPs (literal base values like 280/40/44). SetWindowPos
        // for the surface child still uses physical px.
        .dpiX = dpi_f,
        .dpiY = dpi_f,
        .usage = 0,
        .minLevel = 0,
    };
    const hwnd_props = D2D1_HWND_RENDER_TARGET_PROPERTIES{
        .hwnd = self.hwnd,
        .pixelSize = .{ .width = w, .height = h },
        .presentOptions = D2D1_PRESENT_OPTIONS_NONE,
    };

    var rt: ?*ID2D1HwndRenderTarget = null;
    const hr = factory.vtbl.CreateHwndRenderTarget(factory, &rt_props, &hwnd_props, &rt);
    if (hr < 0 or rt == null) {
        log.err("CreateHwndRenderTarget failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.D2DRTFailed;
    }
    self.rt = rt;

    // Force ClearType text rendering. Crisp subpixel-AA tab/search text
    // instead of the fuzzy grayscale fallback.
    rt.?.vtbl.SetTextAntialiasMode(rt.?, D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);

    // Cache brushes for the chrome elements.
    self.brush_background = try createSolidBrush(rt.?, .{ .r = 0.07, .g = 0.07, .b = 0.07, .a = 1.0 });
    self.brush_sidebar = try createSolidBrush(rt.?, .{ .r = 0.12, .g = 0.12, .b = 0.13, .a = 1.0 });
    self.brush_header = try createSolidBrush(rt.?, .{ .r = 0.09, .g = 0.09, .b = 0.10, .a = 1.0 });
    self.brush_tab_active = try createSolidBrush(rt.?, .{ .r = 0.20, .g = 0.20, .b = 0.22, .a = 1.0 });
    self.brush_tab_hover = try createSolidBrush(rt.?, .{ .r = 0.16, .g = 0.16, .b = 0.18, .a = 1.0 });
    self.brush_text = try createSolidBrush(rt.?, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
    self.brush_text_dim = try createSolidBrush(rt.?, .{ .r = 0.65, .g = 0.65, .b = 0.65, .a = 1.0 });
}

fn createSolidBrush(rt: *ID2D1HwndRenderTarget, color: D2D1_COLOR_F) !*ID2D1SolidColorBrush {
    var brush: ?*ID2D1SolidColorBrush = null;
    const hr = rt.vtbl.CreateSolidColorBrush(rt, &color, null, &brush);
    if (hr < 0 or brush == null) return error.D2DBrushFailed;
    return brush.?;
}

/// Build an IDWriteTextFormat with center-aligned, single-line layout —
/// used for icon-font glyphs. `family_utf8` is the font family name.
fn createIconFormat(
    self: *Self,
    factory: *IDWriteFactory,
    comptime family_utf8: []const u8,
    size_dip: f32,
) !*IDWriteTextFormat {
    _ = self;
    const family = std.unicode.utf8ToUtf16LeStringLiteral(family_utf8);
    const en_us = std.unicode.utf8ToUtf16LeStringLiteral("en-us");
    var tf: ?*IDWriteTextFormat = null;
    const hr = factory.vtbl.CreateTextFormat(
        factory,
        family,
        null,
        DWRITE_FONT_WEIGHT_NORMAL,
        DWRITE_FONT_STYLE_NORMAL,
        DWRITE_FONT_STRETCH_NORMAL,
        size_dip,
        en_us,
        &tf,
    );
    if (hr < 0 or tf == null) return error.DWriteTextFormatFailed;
    _ = tf.?.vtbl.SetTextAlignment(tf.?, DWRITE_TEXT_ALIGNMENT_CENTER);
    _ = tf.?.vtbl.SetParagraphAlignment(tf.?, DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    _ = tf.?.vtbl.SetWordWrapping(tf.?, DWRITE_WORD_WRAPPING_NO_WRAP);
    return tf.?;
}

fn paint(self: *Self) void {
    self.ensureRenderTarget() catch |e| {
        log.warn("ensureRenderTarget failed: {}", .{e});
        return;
    };
    const rt = self.rt orelse return;

    // Coords inside paint() are DIPs (logical units). D2D scales by the
    // render target's DPI (set to GetDpiForWindow at creation). Client
    // rect → DIPs by dividing physical pixels by the DPI scale.
    var client: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = GetClientRect(self.hwnd, &client);
    const dpi: i32 = self.currentDpi();
    const fh: f32 = @as(f32, @floatFromInt((client.bottom - client.top) * 96)) / @as(f32, @floatFromInt(dpi));
    const fsb: f32 = @floatFromInt(self.sidebarBase());
    const fhd: f32 = @floatFromInt(header_height_base);

    const bg_color = D2D1_COLOR_F{ .r = 0.07, .g = 0.07, .b = 0.07, .a = 1.0 };
    rt.vtbl.BeginDraw(rt);
    rt.vtbl.Clear(rt, &bg_color);

    // Sidebar (left strip, rounded right edge).
    if (self.brush_sidebar) |b| {
        const brush_base: *ID2D1Brush = @ptrCast(b);
        const radius: f32 = 12.0;
        const rr = D2D1_ROUNDED_RECT{
            .rect = .{ .left = 0, .top = 0, .right = fsb, .bottom = fh },
            .radiusX = radius,
            .radiusY = radius,
        };
        rt.vtbl.FillRoundedRectangle(rt, &rr, brush_base);
        // Bleed the left edge so it doesn't show rounded corners on the
        // far side of the window — only the right side reads as rounded.
        const overlay = D2D1_RECT_F{ .left = 0, .top = 0, .right = fsb - radius, .bottom = fh };
        rt.vtbl.FillRectangle(rt, &overlay, brush_base);
    }

    // No top header band right of the sidebar: the console fills the full
    // height beside the sidebar. The hamburger/new-tab buttons sit in the
    // sidebar's own top region (drawn on the sidebar background below).

    // Search field (above tab rows, only when sidebar is expanded).
    if (!self.collapsed) self.paintSearchField(rt);

    // Tab rows.
    self.paintTabRows(rt, fsb, fhd);

    // Header icons (panel toggle, settings, grid).
    self.paintHeaderIcons(rt);

    const hr = rt.vtbl.EndDraw(rt, null, null);
    if (hr == D2DERR_RECREATE_TARGET) {
        log.info("D2D render target lost; releasing for next-frame recreate", .{});
        self.releaseRenderTargetResources();
    }
}

// ---------------------------------------------------------------------------
// Tab row geometry + paint + hit-test.
// ---------------------------------------------------------------------------

const TabGeom = struct {
    pill: D2D1_RECT_F,
    icon: D2D1_RECT_F,
    text: D2D1_RECT_F,
    radius: f32,
};

/// Y offset (in DIPs) where the first tab row starts. Accounts for the
/// header band and, when the sidebar is expanded, the search field.
fn tabsTopDip(self: *const Self) f32 {
    const fhd: f32 = @floatFromInt(header_height_base);
    const pad: f32 = @floatFromInt(sidebar_pad_base);
    if (self.collapsed) return fhd + pad;
    const fsh: f32 = @floatFromInt(search_field_height_base);
    return fhd + pad + fsh + pad;
}

/// Search field rect in DIPs. Only valid when sidebar is expanded.
fn searchFieldRectDip(self: *const Self) D2D1_RECT_F {
    const fhd: f32 = @floatFromInt(header_height_base);
    const fsb: f32 = @floatFromInt(self.sidebarBase());
    const pad: f32 = @floatFromInt(sidebar_pad_base);
    const fsh: f32 = @floatFromInt(search_field_height_base);
    return .{
        .left = pad,
        .top = fhd + pad,
        .right = fsb - pad,
        .bottom = fhd + pad + fsh,
    };
}

/// Produce a clean, human-friendly tab label from the surface's raw
/// title. The shell sets its window title to things like the full exe
/// path ("C:\Program Files\PowerShell\7\pwsh.exe") or the working
/// directory; neither reads well truncated in a narrow pill. Rules:
///   * empty title              → "Terminal N"
///   * known shell exe path     → friendly name ("PowerShell", "cmd"…)
///   * any other path           → leaf component (folder/file name)
///   * non-path title           → as-is
/// Writes into `buf` when transformation is needed; otherwise returns a
/// slice that may alias the surface title or a static string.
fn friendlyLabel(self: *const Self, i: usize, buf: []u8) []const u8 {
    const surf = self.tabs.items[i];
    const title = surf.title orelse
        return std.fmt.bufPrint(buf, "Terminal {d}", .{i + 1}) catch "Terminal";
    if (title.len == 0)
        return std.fmt.bufPrint(buf, "Terminal {d}", .{i + 1}) catch "Terminal";

    // Find the last path separator (handles both \ and /).
    const last_sep = blk: {
        var idx: ?usize = null;
        for (title, 0..) |c, j| {
            if (c == '\\' or c == '/') idx = j;
        }
        break :blk idx;
    };

    // No separator → not a path; show the title verbatim.
    const leaf = if (last_sep) |s| title[s + 1 ..] else title;

    // Known shell executables → friendly names.
    if (std.ascii.eqlIgnoreCase(leaf, "pwsh.exe") or
        std.ascii.eqlIgnoreCase(leaf, "powershell.exe"))
        return "PowerShell";
    if (std.ascii.eqlIgnoreCase(leaf, "cmd.exe")) return "Command Prompt";
    if (std.ascii.eqlIgnoreCase(leaf, "bash.exe")) return "Git Bash";
    if (std.ascii.eqlIgnoreCase(leaf, "wsl.exe")) return "WSL";

    // Other path → just the leaf (e.g. a working directory's folder).
    // Non-path title → the whole thing. Either way `leaf` is correct.
    return leaf;
}

/// True if the tab at `i` matches the current search query (or query is
/// empty — every tab matches in that case). Case-insensitive ASCII
/// substring against the friendly label.
fn tabMatchesQuery(self: *const Self, i: usize) bool {
    if (self.search_len == 0) return true;
    const query = self.search_buf[0..self.search_len];
    var fbuf: [260]u8 = undefined;
    const label = self.friendlyLabel(i, &fbuf);
    return std.ascii.indexOfIgnoreCase(label, query) != null;
}

/// tabGeomAt takes a *visible* index (post-filter), not the raw array
/// index. The visible index drives y-positioning so filtered-out tabs
/// don't leave gaps.
fn tabGeomAt(self: *const Self, visible_idx: usize) TabGeom {
    // All coords in DIPs. D2D scales to physical via the RT's DPI.
    const fsb: f32 = @floatFromInt(self.sidebarBase());
    const row_h: f32 = @floatFromInt(tab_row_height_base);
    const pad: f32 = @floatFromInt(sidebar_pad_base);
    const icon_pad: f32 = @floatFromInt(tab_icon_pad_base);
    const icon_w: f32 = @floatFromInt(tab_icon_w_base);
    const text_pad: f32 = @floatFromInt(tab_text_pad_base);
    const radius: f32 = @floatFromInt(tab_pill_radius_base);
    const row_gap: f32 = 2.0;
    const top = self.tabsTopDip() + @as(f32, @floatFromInt(visible_idx)) * (row_h + row_gap);

    if (self.collapsed) {
        // Icon-only rail: square pill, glyph centered.
        return .{
            .pill = .{
                .left = pad,
                .top = top,
                .right = fsb - pad,
                .bottom = top + row_h,
            },
            .icon = .{
                .left = pad,
                .top = top,
                .right = fsb - pad,
                .bottom = top + row_h,
            },
            .text = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
            .radius = radius,
        };
    }
    // Expanded: icon left, text after.
    return .{
        .pill = .{
            .left = pad,
            .top = top,
            .right = fsb - pad,
            .bottom = top + row_h,
        },
        .icon = .{
            .left = pad + icon_pad,
            .top = top,
            .right = pad + icon_pad + icon_w,
            .bottom = top + row_h,
        },
        .text = .{
            .left = pad + icon_pad + icon_w + 6.0,
            .top = top,
            .right = fsb - pad - text_pad,
            .bottom = top + row_h,
        },
        .radius = radius,
    };
}

/// Hit-test in physical client coordinates. tabGeomAt is in DIPs, so we
/// convert the physical click point to DIPs first.
fn hitTabRow(self: *const Self, x_px: i32, y_px: i32) ?usize {
    if (self.tabs.items.len == 0) return null;
    const dpi: i32 = self.currentDpi();
    const fx: f32 = @as(f32, @floatFromInt(x_px * 96)) / @as(f32, @floatFromInt(dpi));
    const fy: f32 = @as(f32, @floatFromInt(y_px * 96)) / @as(f32, @floatFromInt(dpi));
    var visible_idx: usize = 0;
    var i: usize = 0;
    while (i < self.tabs.items.len) : (i += 1) {
        if (!self.tabMatchesQuery(i)) continue;
        const g = self.tabGeomAt(visible_idx);
        if (fx >= g.pill.left and fx < g.pill.right and
            fy >= g.pill.top and fy < g.pill.bottom) return i;
        visible_idx += 1;
    }
    return null;
}

/// Render the "Search tabs..." input field above the tab list.
fn paintSearchField(self: *Self, rt: *ID2D1HwndRenderTarget) void {
    const tf = self.tab_text_format orelse return;
    const r = self.searchFieldRectDip();
    const radius: f32 = @floatFromInt(search_field_radius_base);

    // Background — slightly lighter than sidebar, even more so when focused.
    const bg_brush_opt = if (self.search_focused) self.brush_tab_active else self.brush_tab_hover;
    if (bg_brush_opt) |b| {
        const brush_base: *ID2D1Brush = @ptrCast(b);
        const rr = D2D1_ROUNDED_RECT{ .rect = r, .radiusX = radius, .radiusY = radius };
        rt.vtbl.FillRoundedRectangle(rt, &rr, brush_base);
    }

    // Text rect with horizontal padding.
    const inner_pad: f32 = 10.0;
    const text_rect = D2D1_RECT_F{
        .left = r.left + inner_pad,
        .top = r.top,
        .right = r.right - inner_pad,
        .bottom = r.bottom,
    };

    var w_buf: [256]u16 = undefined;
    var label_buf: [200]u8 = undefined;
    var text_brush: *ID2D1Brush = undefined;

    if (self.search_len == 0) {
        if (self.search_focused) {
            // Focused + empty: the placeholder disappears (like a real
            // input), leaving just a blinking-style caret.
            const caret = [_]u16{'|'};
            text_brush = @ptrCast(self.brush_text orelse return);
            rt.vtbl.DrawText(rt, &caret, 1, tf, &text_rect, text_brush, 0, 0);
        } else {
            // Unfocused + empty: show the dim placeholder.
            const placeholder = "Search tabs...";
            const wlen = std.unicode.utf8ToUtf16Le(&w_buf, placeholder) catch w_buf.len;
            text_brush = @ptrCast(self.brush_text_dim orelse return);
            rt.vtbl.DrawText(rt, &w_buf, @intCast(wlen), tf, &text_rect, text_brush, 0, 0);
        }
    } else {
        // Render the query + caret.
        const q = self.search_buf[0..self.search_len];
        const n = @min(q.len, label_buf.len - 1);
        @memcpy(label_buf[0..n], q[0..n]);
        var total = n;
        if (self.search_focused) {
            label_buf[total] = '|';
            total += 1;
        }
        const wlen = std.unicode.utf8ToUtf16Le(&w_buf, label_buf[0..total]) catch w_buf.len;
        text_brush = @ptrCast(self.brush_text orelse return);
        rt.vtbl.DrawText(rt, &w_buf, @intCast(wlen), tf, &text_rect, text_brush, 0, 0);
    }
}

/// Hit-test the splitter strip on the right edge of the sidebar.
/// `splitter_grab_base` DIPs wide, centered on the sidebar/surface
/// boundary; only valid when the sidebar is expanded.
fn hitSplitter(self: *const Self, x_px: i32, y_px: i32) bool {
    if (self.collapsed) return false;
    const dpi: i32 = self.currentDpi();
    const sb_px: i32 = self.scalePx(self.sidebarBase());
    const grab_px: i32 = self.scalePx(splitter_grab_base);
    const half = @divTrunc(grab_px, 2);
    _ = y_px;
    _ = dpi;
    return x_px >= sb_px - half and x_px < sb_px + half;
}

/// Hit-test the search field. Returns true if the click landed inside.
fn hitSearchField(self: *const Self, x_px: i32, y_px: i32) bool {
    if (self.collapsed) return false;
    const dpi: i32 = self.currentDpi();
    const fx: f32 = @as(f32, @floatFromInt(x_px * 96)) / @as(f32, @floatFromInt(dpi));
    const fy: f32 = @as(f32, @floatFromInt(y_px * 96)) / @as(f32, @floatFromInt(dpi));
    const r = self.searchFieldRectDip();
    return fx >= r.left and fx < r.right and fy >= r.top and fy < r.bottom;
}

fn paintTabRows(
    self: *Self,
    rt: *ID2D1HwndRenderTarget,
    fsb: f32,
    fhd: f32,
) void {
    _ = fsb;
    _ = fhd;
    const tf = self.tab_text_format orelse return;
    const icon_tf = self.icon_text_format orelse return;
    var name_buf: [256]u16 = undefined;
    var fbuf: [260]u8 = undefined;

    var visible_idx: usize = 0;
    var i: usize = 0;
    while (i < self.tabs.items.len) : (i += 1) {
        if (!self.tabMatchesQuery(i)) continue;
        const g = self.tabGeomAt(visible_idx);
        defer visible_idx += 1;
        const is_active = (i == self.active);
        const is_hover = if (self.hover_tab) |h| (h == i and !is_active) else false;

        if (is_active or is_hover) {
            const brush_opt = if (is_active) self.brush_tab_active else self.brush_tab_hover;
            if (brush_opt) |b| {
                const brush_base: *ID2D1Brush = @ptrCast(b);
                const rr = D2D1_ROUNDED_RECT{
                    .rect = g.pill,
                    .radiusX = g.radius,
                    .radiusY = g.radius,
                };
                rt.vtbl.FillRoundedRectangle(rt, &rr, brush_base);
            }
        }

        const text_brush_opt = if (is_active) self.brush_text else self.brush_text_dim;
        if (text_brush_opt == null) continue;
        const text_brush: *ID2D1Brush = @ptrCast(text_brush_opt.?);

        // Leading icon (shell-type glyph; slice 4 will pick per-shell).
        const icon_glyph = [_]u16{ICON_TAB_PROMPT};
        rt.vtbl.DrawText(
            rt,
            &icon_glyph,
            1,
            icon_tf,
            &g.icon,
            text_brush,
            0,
            0,
        );

        if (self.collapsed) continue; // No title text in icon-only mode.

        // Title (or rename buffer + caret when this tab is being renamed).
        const renaming_this = if (self.renaming) |r| r == i else false;
        var label_utf8: []const u8 = undefined;
        var rename_caret_buf: [260]u8 = undefined;
        if (renaming_this) {
            // Append a thin caret glyph so the user sees where they are.
            const buf = self.rename_buf[0..self.rename_len];
            const n = @min(buf.len, rename_caret_buf.len - 1);
            @memcpy(rename_caret_buf[0..n], buf[0..n]);
            rename_caret_buf[n] = '|';
            label_utf8 = rename_caret_buf[0 .. n + 1];
        } else {
            label_utf8 = self.friendlyLabel(i, &fbuf);
        }
        const wlen = std.unicode.utf8ToUtf16Le(&name_buf, label_utf8) catch name_buf.len;
        rt.vtbl.DrawText(
            rt,
            &name_buf,
            @intCast(wlen),
            tf,
            &g.text,
            text_brush,
            0,
            0,
        );
    }
}

/// Update hover_tab based on mouse client-coords. Returns true if it changed.
fn updateHover(self: *Self, x: i32, y: i32) bool {
    const new_hover = self.hitTabRow(x, y);
    const old = self.hover_tab;
    const changed = (old == null) != (new_hover == null) or
        (old != null and new_hover != null and old.? != new_hover.?);
    self.hover_tab = new_hover;
    return changed;
}

// ---------------------------------------------------------------------------
// Header chrome icons (panel toggle, settings, grid).
// ---------------------------------------------------------------------------

/// DIPs rect for a header icon button by index (0=panel toggle, 1=settings,
/// 2=grid). The first three sit at the left of the header band, inside the
/// sidebar's horizontal span when expanded so they "belong" to the sidebar.
fn headerBtnRectDip(self: *const Self, idx: i32) D2D1_RECT_F {
    const pad: f32 = @floatFromInt(header_pad_base);
    const gap: f32 = @floatFromInt(header_gap_base);
    const w: f32 = @floatFromInt(header_btn_base);
    const hd: f32 = @floatFromInt(header_height_base);
    _ = self;
    const x = pad + @as(f32, @floatFromInt(idx)) * (w + gap);
    const center_y = hd * 0.5;
    return .{
        .left = x,
        .top = center_y - w * 0.5,
        .right = x + w,
        .bottom = center_y + w * 0.5,
    };
}

/// Map a header-control enum to its on-screen index.
fn headerCtrlIndex(c: HeaderControl) i32 {
    return switch (c) {
        .panel_toggle => 0,
        .new_tab => 1,
    };
}

fn headerCtrlGlyph(c: HeaderControl) u16 {
    return switch (c) {
        .panel_toggle => ICON_PANEL_TOGGLE,
        .new_tab => ICON_NEW_TAB,
    };
}

/// Hit-test the header for one of the three icon buttons. Coords in
/// physical client px; converted to DIPs before comparing.
fn hitHeader(self: *const Self, x_px: i32, y_px: i32) ?HeaderControl {
    const dpi: i32 = self.currentDpi();
    const fx: f32 = @as(f32, @floatFromInt(x_px * 96)) / @as(f32, @floatFromInt(dpi));
    const fy: f32 = @as(f32, @floatFromInt(y_px * 96)) / @as(f32, @floatFromInt(dpi));
    inline for (.{ HeaderControl.panel_toggle, .new_tab }) |c| {
        const r = self.headerBtnRectDip(headerCtrlIndex(c));
        if (fx >= r.left and fx < r.right and fy >= r.top and fy < r.bottom) return c;
    }
    return null;
}

fn paintHeaderIcons(self: *Self, rt: *ID2D1HwndRenderTarget) void {
    const icon_tf = self.icon_text_format_header orelse return;
    const text_brush_opt = self.brush_text;
    if (text_brush_opt == null) return;
    const text_brush: *ID2D1Brush = @ptrCast(text_brush_opt.?);
    const radius: f32 = @floatFromInt(header_btn_radius_base);

    inline for (.{ HeaderControl.panel_toggle, .new_tab }) |c| {
        const r = self.headerBtnRectDip(headerCtrlIndex(c));
        const is_hover = if (self.hover_header) |h| h == c else false;

        if (is_hover) {
            if (self.brush_tab_hover) |b| {
                const brush_base: *ID2D1Brush = @ptrCast(b);
                const rr = D2D1_ROUNDED_RECT{ .rect = r, .radiusX = radius, .radiusY = radius };
                rt.vtbl.FillRoundedRectangle(rt, &rr, brush_base);
            }
        }
        const glyph = [_]u16{headerCtrlGlyph(c)};
        rt.vtbl.DrawText(rt, &glyph, 1, icon_tf, &r, text_brush, 0, 0);
    }
}

/// Update both hover_tab and hover_header based on the mouse position.
/// Returns true if anything changed (caller should invalidate).
fn updateHoverAll(self: *Self, x: i32, y: i32) bool {
    const new_tab = self.hitTabRow(x, y);
    const new_hdr = self.hitHeader(x, y);
    const tab_changed = (self.hover_tab == null) != (new_tab == null) or
        (self.hover_tab != null and new_tab != null and self.hover_tab.? != new_tab.?);
    const hdr_changed = (self.hover_header == null) != (new_hdr == null) or
        (self.hover_header != null and new_hdr != null and self.hover_header.? != new_hdr.?);
    self.hover_tab = new_tab;
    self.hover_header = new_hdr;
    return tab_changed or hdr_changed;
}

fn resizeRenderTarget(self: *Self, w: u32, h: u32) void {
    _ = w;
    _ = h;
    // ID2D1HwndRenderTarget::Resize was unreliable in practice — it
    // returned S_OK but the back buffer stayed at the original size,
    // so subsequent paints rendered into a small buffer that Windows
    // stretched to fit the new window (producing a 2x-too-large
    // chrome). Releasing the RT here forces a fresh CreateHwndRenderTarget
    // at the new pixel size on the next paint.
    if (self.rt != null) self.releaseRenderTargetResources();
}

// ---------------------------------------------------------------------------
// WndProc.
// ---------------------------------------------------------------------------

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const self_ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (self_ptr == 0) return DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Self = @ptrFromInt(@as(usize, @intCast(self_ptr)));

    switch (msg) {
        WM_PAINT => {
            var ps: PAINTSTRUCT = undefined;
            _ = BeginPaint(hwnd, &ps);
            self.paint();
            _ = EndPaint(hwnd, &ps);
            return 0;
        },
        WM_ERASEBKGND => return 1, // we paint the whole client area in WM_PAINT
        WM_MOUSEMOVE => {
            const x: i32 = @intCast(@as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))))));
            const y: i32 = @intCast(@as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)))));
            if (self.dragging_splitter) {
                // Move sidebar width to follow the mouse. Mouse coords
                // are physical px; convert delta back to DIPs for storage.
                const dpi: i32 = self.currentDpi();
                const delta_px: i32 = x - self.drag_anchor_x;
                const delta_dip: i32 = @divTrunc(delta_px * 96, dpi);
                const new_w = @max(sidebar_min_base, @min(sidebar_max_base, self.drag_anchor_width + delta_dip));
                self.sidebar_width_override = new_w;
                self.layoutActive();
                _ = InvalidateRect(hwnd, null, FALSE);
                return 0;
            }
            if (!self.mouse_tracking) {
                var tme = TRACKMOUSEEVENT_S{
                    .cbSize = @sizeOf(TRACKMOUSEEVENT_S),
                    .dwFlags = TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                _ = TrackMouseEvent(&tme);
                self.mouse_tracking = true;
            }
            if (self.updateHoverAll(x, y)) _ = InvalidateRect(hwnd, null, FALSE);
            return 0;
        },
        WM_LBUTTONUP => {
            if (self.dragging_splitter) {
                self.dragging_splitter = false;
                _ = ReleaseCapture();
            }
            return 0;
        },
        WM_SETCURSOR => {
            // Show the SizeWE cursor when hovering the splitter strip.
            // Default DefWindowProc cursor otherwise.
            const hit_test: i32 = @intCast(lparam & 0xFFFF);
            if (hit_test == HTCLIENT) {
                // Get current cursor position relative to client.
                var pt: POINT = .{ .x = 0, .y = 0 };
                _ = GetCursorPos(&pt);
                _ = ScreenToClient(hwnd, &pt);
                if (self.dragging_splitter or self.hitSplitter(pt.x, pt.y)) {
                    _ = SetCursor(LoadCursorW(null, IDC_SIZEWE));
                    return 1;
                }
            }
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_MOUSELEAVE => {
            self.mouse_tracking = false;
            if (self.hover_tab != null or self.hover_header != null) {
                self.hover_tab = null;
                self.hover_header = null;
                _ = InvalidateRect(hwnd, null, FALSE);
            }
            return 0;
        },
        WM_LBUTTONDBLCLK => {
            const x: i32 = @intCast(@as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))))));
            const y: i32 = @intCast(@as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)))));
            // Double-click on a tab pill starts inline rename. Ignored
            // when collapsed (no text area to edit) or on the header.
            if (!self.collapsed) {
                if (self.hitTabRow(x, y)) |idx| {
                    self.startRename(idx);
                    return 0;
                }
            }
            return 0;
        },
        WM_CHAR => {
            const ch: u16 = @intCast(wparam);
            if (self.renaming != null) {
                self.handleRenameChar(ch);
                return 0;
            }
            if (self.search_focused) {
                self.handleSearchChar(ch);
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_KEYDOWN => {
            const vk: u32 = @intCast(wparam);
            if (self.renaming != null) {
                switch (vk) {
                    VK_RETURN => self.commitRename(),
                    VK_ESCAPE => self.cancelRename(),
                    else => {},
                }
                return 0;
            }
            if (self.search_focused) {
                if (vk == VK_ESCAPE) self.clearAndUnfocusSearch();
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_KILLFOCUS => {
            // Clicking on the terminal child during a rename cancels.
            if (self.renaming != null) self.cancelRename();
            if (self.search_focused) {
                // Keep the query so it filters across re-focus; just stop
                // showing the caret. User clicks back in to keep typing.
                self.search_focused = false;
                _ = InvalidateRect(hwnd, null, FALSE);
            }
            return 0;
        },
        WM_LBUTTONDOWN => {
            const x: i32 = @intCast(@as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))))));
            const y: i32 = @intCast(@as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)))));
            // Splitter takes precedence — easier to grab the edge that
            // overlaps the leftmost edge of the surface.
            if (self.hitSplitter(x, y)) {
                self.dragging_splitter = true;
                self.drag_anchor_x = x;
                self.drag_anchor_width = self.sidebarBase();
                _ = SetCapture(hwnd);
                return 0;
            }
            if (self.hitSearchField(x, y)) {
                self.search_focused = true;
                _ = SetFocus(hwnd);
                _ = InvalidateRect(hwnd, null, FALSE);
                return 0;
            }
            if (self.hitHeader(x, y)) |ctrl| {
                switch (ctrl) {
                    .panel_toggle => {
                        self.collapsed = !self.collapsed;
                        self.layoutActive();
                        _ = InvalidateRect(hwnd, null, FALSE);
                    },
                    .new_tab => {
                        self.showNewTabMenu();
                        _ = InvalidateRect(hwnd, null, FALSE);
                    },
                }
                return 0;
            }
            if (self.hitTabRow(x, y)) |idx| {
                self.switchTab(idx);
                _ = InvalidateRect(hwnd, null, FALSE);
            }
            return 0;
        },
        WM_SIZE => {
            const w: u32 = @intCast(@as(i32, @intCast(lparam & 0xFFFF)));
            const h: u32 = @intCast(@as(i32, @intCast((lparam >> 16) & 0xFFFF)));
            self.resizeRenderTarget(w, h);
            self.layoutActive();
            return 0;
        },
        WM_TIMER => {
            if (wparam == AUTOHEAL_TIMER_ID) self.autoHeal();
            return 0;
        },
        WM_ACTIVATE => {
            // Re-focus child when window activates.
            if ((wparam & 0xFFFF) != 0) {
                if (self.activeSurface()) |s| _ = SetFocus(s.window.hwnd);
            }
            return 0;
        },
        WM_APP_TICK => {
            self.tickCoreApp();
            return 0;
        },
        WM_APP_SET_TITLE => {
            const len: usize = @intCast(wparam);
            const ptr: [*]u16 = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const buf = ptr[0..len];
            if (len > 0) _ = SetWindowTextW(hwnd, @ptrCast(ptr));
            std.heap.c_allocator.free(buf);
            return 0;
        },
        WM_APP_SET_TAB_TITLE => {
            const tt: *TabTitleMsg = @ptrFromInt(@as(usize, @intCast(wparam)));
            defer {
                std.heap.c_allocator.free(tt.title);
                std.heap.c_allocator.destroy(tt);
            }
            // Find the tab for this surface and update its title.
            for (self.tabs.items) |s| {
                if (s == tt.surface) {
                    if (s.title_pinned) break; // user renamed; ignore OSC.
                    if (s.title) |old| self.alloc.free(old);
                    s.title = self.alloc.dupe(u8, tt.title) catch null;
                    _ = InvalidateRect(hwnd, null, FALSE);
                    break;
                }
            }
            return 0;
        },
        WM_APP_CLOSE_SURFACE => {
            const target: *Surface = @ptrFromInt(@as(usize, @intCast(wparam)));
            for (self.tabs.items, 0..) |s, i| {
                if (s == target) {
                    self.closeTab(i);
                    break;
                }
            }
            return 0;
        },
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        WM_CLOSE => {
            // Close all tabs first (they own ConPTY/renderer threads).
            while (self.tabs.items.len > 0) self.closeTab(self.tabs.items.len - 1);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
