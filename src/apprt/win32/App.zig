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
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32);

core_app: *CoreApp,
surface: ?*Surface = null,

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;
    self.* = .{ .core_app = core_app };
}

pub fn run(self: *App) !void {
    const surface = try Surface.create(self.core_app.alloc, self);
    self.surface = surface;
    defer {
        surface.deinit();
        self.surface = null;
    }
    try surface.run();
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
    _ = target;
    _ = value;
    return false;
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
