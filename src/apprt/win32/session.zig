//! Session save/restore for the win32 apprt: persist the open tabs and a
//! slice of each tab's scrollback so a relaunch can show "where we left
//! off" — the previous output above a fresh live shell, à la Windows
//! Terminal.
//!
//! This module is intentionally decoupled from ChromeWindow/Surface: the
//! capture path takes a `*CoreSurface` and the persistence path takes a
//! plain data model, so it can be unit-reasoned and wired in separately.
//!
//! Captured scrollback is emitted as VT (`.vt`) — a linear stream of SGR
//! sequences + text + CRLF newlines (no absolute cursor moves / clears),
//! which replays cleanly via `Termio.processOutput` to reconstruct the
//! colored history before the new shell prints its first prompt.

const std = @import("std");
const Allocator = std.mem.Allocator;

const CoreSurface = @import("../../Surface.zig");
const terminal = @import("../../terminal/main.zig");
const Selection = terminal.Selection;
const ScreenFormatter = @import("../../terminal/formatter.zig").ScreenFormatter;

const log = std.log.scoped(.win32_session);

/// How many rows of history we capture per tab. ~3 pages at a typical
/// window height; the actual stored amount is min(this, available rows).
pub const default_capture_rows: usize = 120;

/// One persisted tab. All slices are owned by the arena/allocator the
/// SavedSession was built with.
pub const SavedTab = struct {
    /// "terminal" or "browser". Defaults keep pre-browser manifests
    /// parseable.
    kind: []const u8 = "terminal",
    /// Friendly title shown in the sidebar (may be a user rename).
    title: []const u8,
    /// True if the user renamed it (so restore re-pins it).
    title_pinned: bool,
    /// Shell command to relaunch (argv0; e.g. the pwsh.exe path). Empty
    /// means "use the default shell". Terminal tabs only.
    command: []const u8,
    /// Working directory to relaunch in, if known (empty = inherit).
    cwd: []const u8,
    /// Relative filename of the .vt scrollback sidecar for this tab.
    /// Empty for browser tabs (nothing to capture).
    scrollback_file: []const u8,
    /// Last committed URL. Browser tabs only.
    url: []const u8 = "",
};

/// The whole window's restorable state.
pub const SavedSession = struct {
    /// Schema version so a future format change can be detected/skipped.
    version: u32 = 1,
    /// Wall-clock ms when written (set by the caller; the engine clock
    /// isn't available here). Used to ignore stale sessions on restore.
    saved_at_ms: i64 = 0,
    /// Window placement, physical pixels.
    win_x: i32 = 0,
    win_y: i32 = 0,
    win_w: i32 = 0,
    win_h: i32 = 0,
    /// Sidebar UI state.
    sidebar_collapsed: bool = false,
    sidebar_width: i32 = 0,
    /// Index of the active tab.
    active: usize = 0,
    tabs: []SavedTab = &.{},
};

// ---------------------------------------------------------------------------
// Capture.
// ---------------------------------------------------------------------------

/// Dump the last `rows` lines of `core`'s active screen as VT bytes. The
/// returned slice is owned by `alloc`. Locks the renderer state for the
/// duration so it's safe to call from the UI thread while the IO thread
/// is live.
pub fn captureScrollback(
    alloc: Allocator,
    core: *CoreSurface,
    rows: usize,
) ![]u8 {
    core.renderer_state.mutex.lock();
    defer core.renderer_state.mutex.unlock();

    const screen = core.io.terminal.screens.active;

    // Bottom of the screen (incl. the active area). If the screen is
    // somehow empty, there's nothing to capture.
    const br = screen.pages.getBottomRight(.screen) orelse return error.EmptyScreen;

    // Walk up `rows` lines; if scrollback is shorter, clamp to the top.
    const tl = switch (br.upOverflow(rows)) {
        .offset => |p| p,
        .overflow => |o| o.end,
    };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    var formatter: ScreenFormatter = .init(screen, .{
        .emit = .vt,
        .unwrap = false,
        .trim = true,
    });
    formatter.content = .{ .selection = Selection.init(tl, br, false) };
    formatter.format(&aw.writer) catch return error.OutOfMemory;

    return try aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Persistence paths.
// ---------------------------------------------------------------------------

/// Absolute path to the session directory: %APPDATA%\ghostty\session.
/// Created if missing. Caller owns the returned slice.
pub fn sessionDir(alloc: Allocator) ![]u8 {
    const appdata = std.process.getEnvVarOwned(alloc, "APPDATA") catch
        return error.NoAppData;
    defer alloc.free(appdata);
    const dir = try std.fs.path.join(alloc, &.{ appdata, "ghostty", "session" });
    errdefer alloc.free(dir);
    std.fs.cwd().makePath(dir) catch |e| {
        log.warn("makePath({s}) failed: {}", .{ dir, e });
        return e;
    };
    return dir;
}

// ---------------------------------------------------------------------------
// Save.
// ---------------------------------------------------------------------------

/// Write `session` (manifest + already-captured scrollback blobs) to disk.
/// `blobs[i]` is the VT bytes for `session.tabs[i]`; this function writes
/// each to its `scrollback_file` and the manifest to session.json.
pub fn save(
    alloc: Allocator,
    session: SavedSession,
    blobs: []const []const u8,
) !void {
    std.debug.assert(blobs.len == session.tabs.len);
    const dir = try sessionDir(alloc);
    defer alloc.free(dir);

    var d = try std.fs.cwd().openDir(dir, .{});
    defer d.close();

    // Scrollback sidecars (browser tabs have none).
    for (session.tabs, blobs) |tab, blob| {
        if (tab.scrollback_file.len == 0) continue;
        d.writeFile(.{ .sub_path = tab.scrollback_file, .data = blob }) catch |e| {
            log.warn("write scrollback {s} failed: {}", .{ tab.scrollback_file, e });
        };
    }

    // Manifest as JSON.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    std.json.Stringify.value(session, .{ .whitespace = .indent_2 }, &aw.writer) catch
        return error.SerializeFailed;
    try d.writeFile(.{ .sub_path = "session.json", .data = aw.written() });

    log.info("saved session: {d} tab(s)", .{session.tabs.len});
}

// ---------------------------------------------------------------------------
// Load.
// ---------------------------------------------------------------------------

/// Parsed session plus the arena that owns it. Call `deinit` to free.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    session: SavedSession,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
    }
};

/// Read and parse session.json. Returns null if there's no session on
/// disk (first run, or it was cleared). Caller must `deinit` a non-null
/// result. Scrollback blobs are NOT read here — restore reads each
/// `scrollback_file` on demand via `readScrollback`.
pub fn load(alloc: Allocator) !?Loaded {
    const dir = sessionDir(alloc) catch return null;
    defer alloc.free(dir);

    var d = std.fs.cwd().openDir(dir, .{}) catch return null;
    defer d.close();

    const bytes = d.readFileAlloc(alloc, "session.json", 1 << 20) catch return null;
    defer alloc.free(bytes);

    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(
        SavedSession,
        arena.allocator(),
        bytes,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |e| {
        log.warn("parse session.json failed: {}", .{e});
        return null;
    };

    return .{ .arena = arena, .session = parsed };
}

/// Read a tab's scrollback sidecar. Caller owns the returned bytes.
pub fn readScrollback(alloc: Allocator, scrollback_file: []const u8) ![]u8 {
    const dir = try sessionDir(alloc);
    defer alloc.free(dir);
    var d = try std.fs.cwd().openDir(dir, .{});
    defer d.close();
    return d.readFileAlloc(alloc, scrollback_file, 4 << 20);
}
