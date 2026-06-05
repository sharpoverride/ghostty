//! Zig binding to the C++ WebView2 shim (webview2_shim.cpp).
//!
//! All entry points must be called on the UI thread. `create` is async: it
//! returns an opaque handle immediately and invokes `cb` (on the UI thread,
//! via the STA message pump) once the WebView is up — or with ok=0 on
//! failure. Bounds are physical pixels relative to the parent HWND's client
//! area.

/// Fired once the WebView controller is ready (ok=1) or creation failed
/// (ok=0). `handle` matches the value returned by `create`.
pub const ReadyFn = *const fn (ctx: ?*anyopaque, handle: ?*anyopaque, ok: c_int) callconv(.c) void;

extern fn gv_webview_create(
    parent: ?*anyopaque,
    user_data_folder: ?[*:0]const u16,
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
    url: ?[*:0]const u16,
    cb: ?ReadyFn,
    ctx: ?*anyopaque,
) ?*anyopaque;

extern fn gv_webview_set_bounds(handle: ?*anyopaque, x: c_int, y: c_int, w: c_int, h: c_int) void;
extern fn gv_webview_set_visible(handle: ?*anyopaque, visible: c_int) void;
extern fn gv_webview_destroy(handle: ?*anyopaque) void;

pub const create = gv_webview_create;
pub const setBounds = gv_webview_set_bounds;
pub const setVisible = gv_webview_set_visible;
pub const destroy = gv_webview_destroy;
