//! Win32 surface.
//!
//! Owns the GL context bound to a Window's HWND. The Window itself owns the
//! HWND, font, ConPTY, and the GDI message-pump pipeline (transitional —
//! that machinery is what Milestone B3+ will replace once CoreSurface is
//! wired in and the real renderer draws via our GL context).
//!
//! Surface is the type the engine sees as `apprt.runtime.Surface`. Most of
//! the apprt-required methods are still stubs because nothing instantiates
//! a CoreSurface yet; they will fill in as B3/B4 progress.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");
const ApprtApp = @import("App.zig");
const Window = @import("Window.zig");
const gl = @import("gl.zig");

const log = std.log.scoped(.win32_surface);

alloc: Allocator,
app: *ApprtApp,
window: *Window,
gl_ctx: gl.Context,
/// Owned Config, kept alive for the lifetime of CoreSurface (CoreSurface
/// only copies derived bits during init; some string slices may point back
/// into our config's arena).
config: configpkg.Config,
/// Engine-side surface. Embedded (not pointer) so the pointer is stable
/// from our allocation.
core_surface: CoreSurface,

/// Create a Surface backed by a fresh native window, a WGL 4.3 context, and
/// a fully-initialized engine-side CoreSurface (which spins up the renderer
/// thread and the termio/ConPTY shell). The Surface pointer is stable —
/// CoreSurface stores references back through `rt_surface = self`.
pub fn create(alloc: Allocator, app: *ApprtApp) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);

    const window = try Window.create(alloc);
    errdefer window.deinit();

    // WGL context: must succeed for the renderer thread to attach. If we
    // can't get a 4.3 core context we abort surface creation — there's no
    // graceful fallback once CoreSurface starts the renderer thread.
    const gl_ctx = try gl.Context.init(window.hwnd);
    // Drop currency on the UI thread so the renderer thread (started by
    // CoreSurface) can take ownership cleanly.
    gl_ctx.clearCurrent();
    log.info("WGL context initialized for hwnd=0x{X}", .{@intFromPtr(window.hwnd)});

    var config = try configpkg.Config.default(alloc);
    errdefer config.deinit();

    self.* = .{
        .alloc = alloc,
        .app = app,
        .window = window,
        .gl_ctx = gl_ctx,
        .config = config,
        // CoreSurface is filled in-place by its `init` method below.
        .core_surface = undefined,
    };

    // Wire back-pointer so Window's WndProc can forward input + resize to
    // CoreSurface. Must be set BEFORE `core_surface.init` because that call
    // pushes an initial resize through to the renderer which will trigger
    // a WM_SIZE round-trip on at least the first frame.
    window.surface = self;

    // This is where the engine first sees our apprt: starts the renderer
    // thread (which immediately calls OpenGL.threadEnter → our glMakeCurrent
    // + glad load), starts the termio thread (which spawns the shell via
    // pty.WindowsPty + ConPTY).
    try self.core_surface.init(alloc, &self.config, app.core_app, app, self);

    return self;
}

pub fn deinit(self: *Self) void {
    self.core_surface.deinit();
    self.config.deinit();
    self.gl_ctx.deinit();
    self.window.deinit();
    self.alloc.destroy(self);
}

/// Drive the Win32 message pump on the calling thread until WM_QUIT.
pub fn run(self: *Self) !void {
    try self.window.run();
}

/// Bind this Surface's GL context to the calling thread. Used by the
/// OpenGL backend's `threadEnter` to take ownership on the render thread.
pub fn glMakeCurrent(self: *Self) !void {
    try self.gl_ctx.makeCurrent();
}

/// Unbind this Surface's GL context from the calling thread.
pub fn glClearCurrent(self: *Self) void {
    self.gl_ctx.clearCurrent();
}

// ---------------------------------------------------------------------------
// apprt.runtime.Surface interface stubs. None of these are exercised at
// runtime today (no CoreSurface is instantiated). They exist so the type
// satisfies the comptime-resolved apprt interface and so the file compiles
// against any incidental references in upstream code.
// ---------------------------------------------------------------------------

pub fn core(self: *Self) *CoreSurface {
    _ = self;
    @panic("win32 Surface.core: not yet implemented");
}

pub fn rtApp(self: *Self) *ApprtApp {
    _ = self;
    @panic("win32 Surface.rtApp: not yet implemented");
}

pub fn close(self: *Self, process_active: bool) void {
    _ = self;
    _ = process_active;
}

pub fn getTitle(self: *Self) ?[:0]const u8 {
    _ = self;
    return null;
}

pub fn getContentScale(self: *const Self) !apprt.ContentScale {
    _ = self;
    return .{ .x = 1.0, .y = 1.0 };
}

pub fn getSize(self: *const Self) !apprt.SurfaceSize {
    const sz = self.window.clientSize();
    return .{ .width = sz.width, .height = sz.height };
}

pub fn getCursorPos(self: *const Self) !apprt.CursorPos {
    _ = self;
    return .{ .x = 0, .y = 0 };
}

pub fn supportsClipboard(self: *const Self, clipboard_type: apprt.Clipboard) bool {
    _ = self;
    _ = clipboard_type;
    return false;
}

pub fn clipboardRequest(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !bool {
    _ = self;
    _ = clipboard_type;
    _ = state;
    return false;
}

pub fn setClipboard(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    _ = self;
    _ = clipboard_type;
    _ = contents;
    _ = confirm;
}

pub fn defaultTermioEnv(self: *Self) !std.process.EnvMap {
    // Real env so the spawned shell inherits PATH, COMSPEC, USERPROFILE, etc.
    // Allocator is the Surface's so the map's lifetime is tied to us; callers
    // (termio.Exec) typically take ownership and call deinit.
    return try std.process.getEnvMap(self.alloc);
}

pub fn redrawInspector(self: *Self) void {
    _ = self;
}
