//! Win32 app runtime entrypoint.
//!
//! Owns a single Surface today (MVP). The Surface wraps an HWND + ConPTY
//! shell + WGL 4.3 context. When CoreSurface integration lands (B3) the
//! Surface will also own a `CoreSurface` and the renderer will draw via
//! the GL context we already create here.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const CoreApp = @import("../../App.zig");
const ParentWindow = @import("ParentWindow.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32);

core_app: *CoreApp,
parent: ?*ParentWindow = null,

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;
    self.* = .{ .core_app = core_app };
}

pub fn run(self: *App) !void {
    log.info("App.run: creating parent window", .{});
    const parent = try ParentWindow.create(self.core_app.alloc, self);
    self.parent = parent;
    defer {
        log.info("App.run: parent.deinit", .{});
        parent.deinit();
        self.parent = null;
        log.info("App.run: parent.deinit returned", .{});
    }

    log.info("App.run: creating initial tab", .{});
    try parent.newTab();

    log.info("App.run: entering message pump", .{});
    try parent.run();
    log.info("App.run: message pump exited", .{});
}

pub fn terminate(self: *App) void {
    _ = self;
}

pub fn wakeup(self: *App) void {
    // The engine calls this (from any thread) when it pushes an app/surface
    // message that needs processing — e.g. child_exited. Marshal a mailbox
    // drain onto the UI thread. Without this, surface messages are never
    // handled (the window wouldn't close when the shell exits).
    if (self.parent) |p| p.requestTick();
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    return switch (action) {
        .set_title => blk: {
            // .set_title is always per-surface — the engine never sends it
            // with .app target. Update the source surface's tab title (the
            // strip repaints from there). The window caption stays as the
            // watchdog-set "Ghostty - FPS=N" heartbeat string.
            const core_surface = switch (target) {
                .surface => |s| s,
                .app => break :blk false,
            };
            const parent = self.parent orelse break :blk false;
            const ws: *Surface = core_surface.rt_surface;
            parent.requestSetTabTitle(ws, value.title);
            break :blk true;
        },

        .ring_bell => blk: {
            const core_surface = switch (target) {
                .surface => |s| s,
                .app => break :blk false,
            };
            core_surface.rt_surface.window.ringBell();
            break :blk true;
        },

        // Everything else: engine gets graceful false. The features that
        // matter for the win32 MVP (resize, focus, scroll, clipboard) live
        // on the Surface and are wired through dedicated callbacks, not
        // through performAction.
        else => false,
    };
}

pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) !bool {
    _ = alloc;
    _ = target;
    _ = value;
    return switch (action) {
        else => false,
    };
}

pub fn redrawInspector(self: *App, surface: *Surface) void {
    _ = self;
    _ = surface;
}
