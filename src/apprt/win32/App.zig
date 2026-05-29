//! Win32 app runtime entrypoint.
//!
//! Owns a single Surface today (MVP). The Surface wraps an HWND + ConPTY
//! shell + D3D11 swap chain (or WGL with `-Drenderer=opengl`). When
//! `--new-chrome` (or env `GHOSTTY_NEW_CHROME=1`) is passed, the modern
//! Direct2D-backed `ChromeWindow` hosts the surface instead of the
//! legacy GDI `ParentWindow`.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const CoreApp = @import("../../App.zig");
const ParentWindow = @import("ParentWindow.zig");
const ChromeWindow = @import("ChromeWindow.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32);

/// Tagged dispatch over the two chrome implementations. App.zig holds one;
/// each variant exposes the same method set (mirrored manually below).
pub const Chrome = union(enum) {
    legacy: *ParentWindow,
    modern: *ChromeWindow,

    pub fn deinit(self: Chrome) void {
        switch (self) {
            inline else => |p| p.deinit(),
        }
    }
    pub fn newTab(self: Chrome) !void {
        switch (self) {
            inline else => |p| try p.newTab(),
        }
    }
    pub fn run(self: Chrome) !void {
        switch (self) {
            inline else => |p| try p.run(),
        }
    }
    pub fn requestTick(self: Chrome) void {
        switch (self) {
            inline else => |p| p.requestTick(),
        }
    }
    pub fn requestSetTabTitle(self: Chrome, surface: *Surface, title: []const u8) void {
        switch (self) {
            inline else => |p| p.requestSetTabTitle(surface, title),
        }
    }
    pub fn requestCloseSurface(self: Chrome, surface: *Surface) void {
        switch (self) {
            inline else => |p| p.requestCloseSurface(surface),
        }
    }
    pub fn closeTab(self: Chrome, idx: usize) void {
        switch (self) {
            inline else => |p| p.closeTab(idx),
        }
    }
    pub fn switchTab(self: Chrome, idx: usize) void {
        switch (self) {
            inline else => |p| p.switchTab(idx),
        }
    }
    pub fn cycleTab(self: Chrome, offset: i32) void {
        switch (self) {
            inline else => |p| p.cycleTab(offset),
        }
    }
    pub fn activeIndex(self: Chrome) usize {
        return switch (self) {
            inline else => |p| p.active,
        };
    }
};

core_app: *CoreApp,
chrome: ?Chrome = null,
/// Optional shell command string for the *next* surface to be created.
/// ChromeWindow sets this before calling Surface.create() (via newTab) so
/// the new tab spawns with the user's chosen shell instead of the default.
/// Lifetime: borrowed; the chrome owns the underlying bytes.
pending_command: ?[:0]const u8 = null,

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;
    self.* = .{ .core_app = core_app };
}

/// Decide which chrome to use. The modern D2D chrome is now the DEFAULT.
/// Opt out to the legacy GDI tab strip with `--legacy-chrome` on argv or
/// `GHOSTTY_NEW_CHROME=0` in the environment. (`--new-chrome` /
/// `GHOSTTY_NEW_CHROME=1` still work but are now no-ops since modern is
/// the default.)
fn wantsNewChrome(alloc: Allocator) bool {
    if (std.process.getEnvVarOwned(alloc, "GHOSTTY_NEW_CHROME")) |val| {
        defer alloc.free(val);
        // Explicit env override wins: "0" forces legacy, anything else modern.
        return !(val.len > 0 and val[0] == '0');
    } else |_| {}

    const args = std.process.argsAlloc(alloc) catch return true;
    defer std.process.argsFree(alloc, args);
    for (args) |a| {
        if (std.mem.eql(u8, a, "--legacy-chrome")) return false;
    }
    return true;
}

pub fn run(self: *App) !void {
    const new_chrome = wantsNewChrome(self.core_app.alloc);
    log.info("App.run: chrome={s}", .{if (new_chrome) "modern" else "legacy"});

    if (new_chrome) {
        const w = try ChromeWindow.create(self.core_app.alloc, self);
        self.chrome = .{ .modern = w };
    } else {
        const w = try ParentWindow.create(self.core_app.alloc, self);
        self.chrome = .{ .legacy = w };
    }
    defer if (self.chrome) |c| {
        c.deinit();
        self.chrome = null;
    };

    // The modern chrome can restore the previous session (tabs +
    // scrollback). If it does, skip creating the default tab.
    const restored = switch (self.chrome.?) {
        .modern => |w| w.restoreSession(),
        .legacy => false,
    };
    if (!restored) {
        log.info("App.run: creating initial tab", .{});
        try self.chrome.?.newTab();
    } else {
        log.info("App.run: restored previous session", .{});
    }

    log.info("App.run: entering message pump", .{});
    try self.chrome.?.run();
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
    if (self.chrome) |c| c.requestTick();
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
            const chrome = self.chrome orelse break :blk false;
            const ws: *Surface = core_surface.rt_surface;
            chrome.requestSetTabTitle(ws, value.title);
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
