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
const clipboard = @import("clipboard.zig");

const log = std.log.scoped(.win32_surface);

alloc: Allocator,
app: *ApprtApp,
window: *Window,
gl_ctx: gl.Context,
/// Owned UTF-8 tab title (e.g. set via OSC 2/0). null = fall back to a
/// generic index-based label in the tab strip. Written by the UI thread
/// only (ParentWindow's WM_APP_SET_TAB_TITLE handler) so paintTabStrip can
/// read it lock-free. Allocated with std.heap.c_allocator.
title: ?[]u8 = null,
/// When true, the chrome ignores subsequent OSC 0/1/2 title updates
/// from the shell so the user-chosen rename sticks. Set by the chrome's
/// rename commit; never cleared (the user owns the title from then on).
title_pinned: bool = false,
/// The shell command this surface was launched with (argv0 path), if a
/// non-default one was chosen via the new-tab dropdown. Owned by
/// std.heap.c_allocator. Used by session save/restore to relaunch the
/// same shell. null = launched with the engine/config default.
launch_command: ?[]u8 = null,
/// Saved scrollback (VT bytes) to replay into the terminal once it's
/// live, set during session restore. Injected (and freed) by the
/// chrome's one-shot restore-inject timer AFTER the first WM_SIZE, so it
/// isn't wiped by the surface's initial resize/clear. c_allocator-owned.
pending_preamble: ?[]u8 = null,
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
pub fn create(alloc: Allocator, app: *ApprtApp, parent_hwnd: *anyopaque) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);

    const window = try Window.create(alloc, @ptrCast(parent_hwnd));
    errdefer window.deinit();

    // WGL context: must succeed for the renderer thread to attach. If we
    // can't get a 4.3 core context we abort surface creation — there's no
    // graceful fallback once CoreSurface starts the renderer thread.
    //
    // NOTE: the D3D11 swap-chain proof-of-life used to run here for ~2s
    // before WGL took over. It was removed once it became clear that
    // attaching a DXGI swap chain to the HWND first stops the subsequent
    // `SetPixelFormat` from being honoured by WGL — the on-screen output
    // sticks at the triangle instead of falling through to the GL
    // renderer. The proof code still lives in `apprt/win32/d3d11.zig`
    // for reference and is what `Phase 2` of the D3D11 backend will
    // hoist out of apprt-land entirely.
    const gl_ctx = try gl.Context.init(window.hwnd);
    // Drop currency on the UI thread so the renderer thread (started by
    // CoreSurface) can take ownership cleanly.
    gl_ctx.clearCurrent();
    log.info("WGL context initialized for hwnd=0x{X}", .{@intFromPtr(window.hwnd)});

    var config = try configpkg.Config.default(alloc);
    errdefer config.deinit();

    // Windows-friendly defaults that the engine's default config doesn't
    // already cover (the cross-platform default for these turns out to be
    // a Linux/macOS sensibility):
    //   * copy-on-select: auto-copy selection on drag end (matches
    //     Windows Terminal, PuTTY, conhost).
    //   * right-click-action: copy-or-paste, i.e. if there's a selection
    //     copy it, otherwise paste — also WT behaviour.
    // Applied BEFORE CLI parsing so the user can still override via
    // `--copy-on-select=false` or a config file.
    config.@"copy-on-select" = .true;
    config.@"right-click-action" = .@"copy-or-paste";
    // NOTE: ctrl+v → paste is handled directly in Window.zig's forwardKey
    // (not as a config keybind) so it works even when the app enables Win32
    // input mode, which bypasses keyCallback and the keybind system.

    // Parse the process command line. Supports the standard Ghostty CLI:
    //   ghostty.exe --command="pwsh.exe -NoLogo"
    //   ghostty.exe -e pwsh.exe -NoLogo
    //   ghostty.exe --working-directory="E:\proj"
    // loadCliArgs also flips `config-default-files = true` so a config
    // file at %APPDATA%/ghostty/config gets picked up on the next pass.
    config.loadCliArgs(alloc) catch |err| {
        log.warn("loadCliArgs failed (continuing with defaults): {}", .{err});
    };

    // If the chrome put a per-tab shell command in app.pending_command
    // (e.g. user picked "Command Prompt" from the new-tab dropdown), use
    // that instead of whatever config/CLI resolved to. Use `.direct`
    // (single-element argv) rather than `.shell` so paths containing
    // spaces — like `C:\Program Files\PowerShell\7\pwsh.exe` — aren't
    // tokenized by the shell-style parser.
    if (app.pending_command) |cmd| {
        const argv = try alloc.alloc([:0]const u8, 1);
        argv[0] = try alloc.dupeZ(u8, cmd);
        config.command = .{ .direct = argv };
    }

    // Start the new tab in the active tab's directory (OSC 7-reported cwd),
    // so opening a tab while working on D:\ or E:\ lands you on that same
    // drive/dir. Duped into the surface allocator; config holds the slice.
    if (app.pending_cwd) |cwd| {
        if (cwd.len > 0) {
            config.@"working-directory" = .{ .path = try alloc.dupe(u8, cwd) };
        }
    }

    // Remember the launch command (for session save/restore). Duped on
    // the c_allocator to match how `title` is owned.
    const launch_command: ?[]u8 = if (app.pending_command) |cmd|
        (std.heap.c_allocator.dupe(u8, cmd) catch null)
    else
        null;

    self.* = .{
        .alloc = alloc,
        .app = app,
        .window = window,
        .gl_ctx = gl_ctx,
        .config = config,
        .launch_command = launch_command,
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

    // Register with the core app so surface-targeted mailbox messages (e.g.
    // child_exited, which closes us when the shell exits) are dispatched to
    // our handleMessage. Without this, App.surfaceMessage's hasSurface check
    // silently drops them.
    errdefer self.core_surface.deinit();
    try app.core_app.addSurface(self);

    // core_surface (and its renderer_thread) is now live — let the
    // forced-refresh thread start signaling draws.
    window.render_ready.store(true, .seq_cst);

    return self;
}

pub fn deinit(self: *Self) void {
    // Unregister from the core app first so no further surface messages are
    // dispatched to us mid-teardown.
    self.app.core_app.deleteSurface(self);

    if (self.title) |t| std.heap.c_allocator.free(t);
    if (self.launch_command) |c| std.heap.c_allocator.free(c);
    if (self.pending_preamble) |p| std.heap.c_allocator.free(p);

    // Signal the renderer thread's manual loop to exit BEFORE
    // core_surface.deinit (which joins that thread). The xev stop async
    // isn't reliably delivered on Windows, so without this non-xev flag
    // the join would hang — that's the close-button freeze.
    self.core_surface.renderer_thread.quit.store(true, .seq_cst);

    log.info("Surface.deinit: core_surface.deinit start", .{});
    self.core_surface.deinit();
    log.info("Surface.deinit: core_surface.deinit returned", .{});
    self.config.deinit();
    log.info("Surface.deinit: config.deinit returned", .{});
    self.gl_ctx.deinit();
    log.info("Surface.deinit: gl_ctx.deinit returned", .{});
    self.window.deinit();
    log.info("Surface.deinit: window.deinit returned", .{});
    self.alloc.destroy(self);
}

// NOTE: the win32 message pump used to live on Surface.run -> Window.run
// when each Surface was a top-level window. With the parent/child split
// the pump moves up to ParentWindow.run; Surface no longer drives it.

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
    return &self.core_surface;
}

pub fn rtApp(self: *Self) *ApprtApp {
    return self.app;
}

pub fn close(self: *Self, process_active: bool) void {
    _ = process_active;
    // The engine calls this when the surface should close — notably when the
    // child shell exits (e.g. PowerShell `exit`). This can run on the
    // renderer/IO thread, so we marshal the actual teardown to the UI thread
    // via the parent window (tab teardown joins those very threads).
    if (self.app.chrome) |chrome| {
        chrome.requestCloseSurface(self);
    }
}

pub fn getTitle(self: *Self) ?[:0]const u8 {
    _ = self;
    return null;
}

pub fn getContentScale(self: *const Self) !apprt.ContentScale {
    const scale = self.window.dpiScale();
    return .{ .x = scale, .y = scale };
}

pub fn getSize(self: *const Self) !apprt.SurfaceSize {
    const sz = self.window.clientSize();
    return .{ .width = sz.width, .height = sz.height };
}

pub fn getCursorPos(self: *const Self) !apprt.CursorPos {
    return .{
        .x = @floatFromInt(self.window.last_mouse_x),
        .y = @floatFromInt(self.window.last_mouse_y),
    };
}

pub fn supportsClipboard(self: *const Self, clipboard_type: apprt.Clipboard) bool {
    _ = self;
    // Windows has a single system clipboard. Map .standard to it; .selection
    // and .primary don't exist on Windows, so the engine won't ask for them
    // anyway (returning false here keeps semantics honest).
    return clipboard_type == .standard;
}

pub fn clipboardRequest(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !bool {
    if (clipboard_type != .standard) return false;

    const text = (try clipboard.getText(self.alloc, self.window.hwnd)) orelse {
        // Empty clipboard or text-format unavailable — deliver empty string
        // so the paste path completes gracefully instead of stalling.
        const empty = try self.alloc.allocSentinel(u8, 0, 0);
        defer self.alloc.free(empty);
        try self.core_surface.completeClipboardRequest(state, empty, false);
        return true;
    };
    defer self.alloc.free(text);

    try self.core_surface.completeClipboardRequest(state, text, false);
    return true;
}

pub fn setClipboard(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    _ = confirm;
    if (clipboard_type != .standard) return;

    // Walk for the first text/plain entry. Ghostty may also pass image
    // mime types in the future; until we support those, plain text is
    // the only thing we round-trip.
    for (contents) |content| {
        if (std.mem.startsWith(u8, content.mime, "text/")) {
            try clipboard.setText(content.data, self.window.hwnd);
            return;
        }
    }
}

pub fn defaultTermioEnv(self: *Self) !std.process.EnvMap {
    // Real env so the spawned shell inherits PATH, COMSPEC, USERPROFILE, etc.
    // Allocator is the Surface's so the map's lifetime is tied to us; callers
    // (termio.Exec) typically take ownership and call deinit.
    var env = try std.process.getEnvMap(self.alloc);
    // Export the control-pipe name so `ghostty-ctl` inside this shell can
    // talk to its host window (see apprt/win32/PipeServer.zig).
    if (self.app.pipeName()) |name| env.put("GHOSTTY_PIPE", name) catch {};
    return env;
}

pub fn redrawInspector(self: *Self) void {
    _ = self;
}
