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
    const parent = try ParentWindow.create(self.core_app.alloc);
    self.parent = parent;
    defer {
        log.info("App.run: parent.deinit", .{});
        parent.deinit();
        self.parent = null;
        log.info("App.run: parent.deinit returned", .{});
    }

    log.info("App.run: creating initial surface", .{});
    const surface = try Surface.create(self.core_app.alloc, self, @ptrCast(parent.hwnd));
    parent.attachSurface(surface);

    log.info("App.run: entering message pump", .{});
    try parent.run();
    log.info("App.run: message pump exited", .{});
}

pub fn terminate(self: *App) void {
    _ = self;
}

pub fn wakeup(self: *App) void {
    _ = self;
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    _ = self;
    return switch (action) {
        .set_title => blk: {
            // .set_title is always per-surface — the engine never sends it
            // with .app target. CoreSurface stores back-pointers, so we go
            // CoreSurface → rt_surface (our apprt Surface) → window.
            const core_surface = switch (target) {
                .surface => |s| s,
                .app => break :blk false,
            };
            const rt_surface = core_surface.rt_surface;
            try rt_surface.window.setTitle(value.title);
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
