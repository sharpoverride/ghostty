//! WGL bring-up for the Ghostty win32 apprt.
//!
//! Owns the (HDC, HGLRC) pair backing a single HWND. Two-stage context
//! creation: a dummy OpenGL 2.1 context to fetch `wglCreateContextAttribsARB`,
//! then a 4.3 core profile context that matches what the renderer expects.
//!
//! Threading: a GL context can be current on at most one thread at a time.
//! Ghostty's renderer thread is the one that should call `makeCurrent`. The
//! UI thread (window message pump) MUST NOT also be current at the same time,
//! or `wglMakeCurrent` on the render thread will fail.

const std = @import("std");
const windows = std.os.windows;

const HWND = windows.HWND;
const HDC = ?*anyopaque;
const HGLRC = ?*anyopaque;
const HMODULE = windows.HMODULE;
const HINSTANCE = windows.HINSTANCE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const TRUE = windows.TRUE;
const FALSE = windows.FALSE;
const WORD = windows.WORD;
const BYTE = u8;
const LPCSTR = [*:0]const u8;

const log = std.log.scoped(.win32_gl);

// ---------------------------------------------------------------------------
// PIXELFORMATDESCRIPTOR + WGL externs.
// ---------------------------------------------------------------------------

pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: WORD,
    nVersion: WORD,
    dwFlags: DWORD,
    iPixelType: BYTE,
    cColorBits: BYTE,
    cRedBits: BYTE,
    cRedShift: BYTE,
    cGreenBits: BYTE,
    cGreenShift: BYTE,
    cBlueBits: BYTE,
    cBlueShift: BYTE,
    cAlphaBits: BYTE,
    cAlphaShift: BYTE,
    cAccumBits: BYTE,
    cAccumRedBits: BYTE,
    cAccumGreenBits: BYTE,
    cAccumBlueBits: BYTE,
    cAccumAlphaBits: BYTE,
    cDepthBits: BYTE,
    cStencilBits: BYTE,
    cAuxBuffers: BYTE,
    iLayerType: BYTE,
    bReserved: BYTE,
    dwLayerMask: DWORD,
    dwVisibleMask: DWORD,
    dwDamageMask: DWORD,
};

pub const PFD_DRAW_TO_WINDOW: DWORD = 0x00000004;
pub const PFD_SUPPORT_OPENGL: DWORD = 0x00000020;
pub const PFD_DOUBLEBUFFER: DWORD = 0x00000001;
pub const PFD_TYPE_RGBA: BYTE = 0;
pub const PFD_MAIN_PLANE: BYTE = 0;

// WGL_ARB_create_context attributes.
pub const WGL_CONTEXT_MAJOR_VERSION_ARB: i32 = 0x2091;
pub const WGL_CONTEXT_MINOR_VERSION_ARB: i32 = 0x2092;
pub const WGL_CONTEXT_FLAGS_ARB: i32 = 0x2094;
pub const WGL_CONTEXT_PROFILE_MASK_ARB: i32 = 0x9126;
pub const WGL_CONTEXT_DEBUG_BIT_ARB: i32 = 0x0001;
pub const WGL_CONTEXT_CORE_PROFILE_BIT_ARB: i32 = 0x0001;

extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) HDC;
extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.winapi) i32;
extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;
extern "gdi32" fn SetPixelFormat(hdc: HDC, format: i32, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
extern "gdi32" fn DescribePixelFormat(hdc: HDC, iPixelFormat: i32, nBytes: u32, ppfd: ?*PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;
extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;
extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) HGLRC;
extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglMakeCurrent(hdc: HDC, hglrc: HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglGetProcAddress(name: LPCSTR) callconv(.winapi) ?*anyopaque;
extern "opengl32" fn wglGetCurrentDC() callconv(.winapi) HDC;
extern "user32" fn WindowFromDC(hdc: HDC) callconv(.winapi) ?HWND;
extern "user32" fn GetClientRect(hwnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;

const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
extern "kernel32" fn GetModuleHandleA(lpModuleName: ?LPCSTR) callconv(.winapi) HMODULE;
extern "kernel32" fn LoadLibraryA(lpLibFileName: LPCSTR) callconv(.winapi) HMODULE;
extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: LPCSTR) callconv(.winapi) ?*anyopaque;

const WglCreateContextAttribsARB = *const fn (
    hdc: HDC,
    share: HGLRC,
    attribs: [*]const i32,
) callconv(.winapi) HGLRC;

// ---------------------------------------------------------------------------
// glad-compatible proc loader. glad's `gladLoadGLContext` accepts a function
// of signature `fn (name: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void`.
// On Windows the correct strategy is: try wglGetProcAddress first (for GL
// 1.2+ and extensions), fall back to GetProcAddress on opengl32.dll (for
// GL 1.0/1.1, which wglGetProcAddress refuses to return).
// ---------------------------------------------------------------------------

const GlProc = *const fn () callconv(.c) void;

/// Cached opengl32.dll handle for the GL 1.0/1.1 fallback path.
var opengl32_module: ?HMODULE = null;

pub fn getProcAddress(name: [*:0]const u8) callconv(.c) ?GlProc {
    // wglGetProcAddress can return 0, 1, 2, 3, or -1 for "not found" depending
    // on the driver. Anything in that range is invalid; treat as not-found.
    const p = wglGetProcAddress(name);
    if (p) |pp| {
        const ival = @intFromPtr(pp);
        if (ival > 3 and ival != std.math.maxInt(usize)) {
            return @ptrCast(pp);
        }
    }

    // Fallback: opengl32.dll exports the GL 1.0/1.1 entry points.
    if (opengl32_module == null) {
        opengl32_module = LoadLibraryA("opengl32.dll");
    }
    if (opengl32_module) |m| {
        if (GetProcAddress(m, name)) |pp| {
            return @ptrCast(pp);
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Context: pixel format + HGLRC for an HWND.
// ---------------------------------------------------------------------------

pub const Context = struct {
    hwnd: HWND,
    hdc: HDC,
    hglrc: HGLRC,

    pub fn init(hwnd: HWND) !Context {
        const hdc = GetDC(hwnd);
        if (hdc == null) return error.GetDCFailed;
        errdefer _ = ReleaseDC(hwnd, hdc);

        // Set up the pixel format on this DC. Once a window's pixel format is
        // set it cannot be changed, so this must succeed first try.
        var pfd: PIXELFORMATDESCRIPTOR = std.mem.zeroes(PIXELFORMATDESCRIPTOR);
        pfd.nSize = @sizeOf(PIXELFORMATDESCRIPTOR);
        pfd.nVersion = 1;
        pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
        pfd.iPixelType = PFD_TYPE_RGBA;
        pfd.cColorBits = 32;
        pfd.cAlphaBits = 8;
        pfd.cDepthBits = 24;
        pfd.cStencilBits = 8;
        pfd.iLayerType = PFD_MAIN_PLANE;

        const pixel_format = ChoosePixelFormat(hdc, &pfd);
        if (pixel_format == 0) return error.ChoosePixelFormatFailed;
        if (SetPixelFormat(hdc, pixel_format, &pfd) == FALSE) return error.SetPixelFormatFailed;

        // Stage 1: dummy legacy context so we can resolve
        // `wglCreateContextAttribsARB`.
        const dummy_hglrc = wglCreateContext(hdc);
        if (dummy_hglrc == null) return error.WglCreateContextFailed;
        defer _ = wglDeleteContext(dummy_hglrc);

        if (wglMakeCurrent(hdc, dummy_hglrc) == FALSE) return error.WglMakeCurrentFailed;
        // We'll either replace this with the real context (and re-make-current)
        // or, on error, drop down to wglMakeCurrent(null, null) before returning.
        errdefer _ = wglMakeCurrent(null, null);

        const create_attribs_ptr = wglGetProcAddress("wglCreateContextAttribsARB") orelse
            return error.MissingWglCreateContextAttribsARB;
        const create_attribs: WglCreateContextAttribsARB = @ptrCast(@alignCast(create_attribs_ptr));

        // Stage 2: 4.3 core context, with debug bit so GL_DEBUG_OUTPUT is
        // meaningful (OpenGL.zig enables it).
        const debug_flag: i32 = if (@import("builtin").mode == .Debug) WGL_CONTEXT_DEBUG_BIT_ARB else 0;
        const attribs = [_]i32{
            WGL_CONTEXT_MAJOR_VERSION_ARB, 4,
            WGL_CONTEXT_MINOR_VERSION_ARB, 3,
            WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            WGL_CONTEXT_FLAGS_ARB,         debug_flag,
            0, // terminator
        };
        const hglrc = create_attribs(hdc, null, &attribs);
        if (hglrc == null) return error.WglCreateContextAttribsFailed;
        errdefer _ = wglDeleteContext(hglrc);

        // Drop the dummy and make the real context current so the caller
        // (or threadEnter) can immediately load glad against it.
        _ = wglMakeCurrent(null, null);
        if (wglMakeCurrent(hdc, hglrc) == FALSE) return error.WglMakeCurrentRealFailed;

        log.info("WGL context created hwnd=0x{X} pixel_format={d}", .{ @intFromPtr(hwnd), pixel_format });

        return .{ .hwnd = hwnd, .hdc = hdc, .hglrc = hglrc };
    }

    pub fn deinit(self: *Context) void {
        _ = wglMakeCurrent(null, null);
        _ = wglDeleteContext(self.hglrc);
        _ = ReleaseDC(self.hwnd, self.hdc);
        self.* = undefined;
    }

    /// Bind this context to the calling thread. The previous context (if any)
    /// on this thread is unbound.
    pub fn makeCurrent(self: *const Context) !void {
        if (wglMakeCurrent(self.hdc, self.hglrc) == FALSE) return error.WglMakeCurrentFailed;
    }

    /// Unbind any GL context from the calling thread.
    pub fn clearCurrent(self: *const Context) void {
        _ = self;
        _ = wglMakeCurrent(null, null);
    }

    /// Present the back buffer.
    pub fn swap(self: *const Context) void {
        _ = SwapBuffers(self.hdc);
    }
};

/// Present the back buffer of whatever Context is current on this thread.
/// Used by the OpenGL backend's per-frame end hook — the backend doesn't
/// hold a Context pointer, but if `threadEnter` made our context current,
/// `wglGetCurrentDC` will return its HDC.
pub fn swapCurrent() void {
    const hdc = wglGetCurrentDC();
    if (hdc != null) _ = SwapBuffers(hdc);
}

/// Unbind whatever WGL context is current on this thread. Safe to call
/// when no context is current.
pub fn clearCurrentThread() void {
    _ = wglMakeCurrent(null, null);
}

/// Return the client-area size of the HWND backing whatever WGL context is
/// current on this thread. Used by the OpenGL backend's `surfaceSize` so
/// the renderer detects window resizes on Windows — querying `GL_VIEWPORT`
/// is useless because nothing on this platform updates the viewport
/// automatically on WM_SIZE.
pub fn currentDrawableSize() ?struct { w: u32, h: u32 } {
    const hdc = wglGetCurrentDC();
    if (hdc == null) return null;
    const hwnd = WindowFromDC(hdc) orelse return null;
    var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (GetClientRect(hwnd, &rect) == FALSE) return null;
    return .{
        .w = @intCast(@max(@as(i32, 0), rect.right - rect.left)),
        .h = @intCast(@max(@as(i32, 0), rect.bottom - rect.top)),
    };
}
