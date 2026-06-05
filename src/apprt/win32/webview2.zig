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
/// Document title changed. `title` is only valid for the duration of the
/// call — copy it if you need to keep it.
pub const TitleFn = *const fn (ctx: ?*anyopaque, title: [*:0]const u16) callconv(.c) void;
/// Source URL changed (navigation committed). Same lifetime rule as title.
pub const UrlFn = *const fn (ctx: ?*anyopaque, url: [*:0]const u16) callconv(.c) void;
/// ExecuteScript completed: ok=1 with the JSON-encoded result, or ok=0 and
/// result_json=null. result_json only valid during the call.
pub const ScriptFn = *const fn (ctx: ?*anyopaque, result_json: ?[*:0]const u16, ok: c_int) callconv(.c) void;

extern fn gv_webview_create(
    parent: ?*anyopaque,
    user_data_folder: ?[*:0]const u16,
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
    url: ?[*:0]const u16,
    cb: ?ReadyFn,
    title_cb: ?TitleFn,
    url_cb: ?UrlFn,
    ctx: ?*anyopaque,
) ?*anyopaque;

extern fn gv_webview_set_bounds(handle: ?*anyopaque, x: c_int, y: c_int, w: c_int, h: c_int) void;
extern fn gv_webview_set_visible(handle: ?*anyopaque, visible: c_int) void;
extern fn gv_webview_destroy(handle: ?*anyopaque) void;
extern fn gv_webview_navigate(handle: ?*anyopaque, url: [*:0]const u16) void;
extern fn gv_webview_back(handle: ?*anyopaque) void;
extern fn gv_webview_forward(handle: ?*anyopaque) void;
extern fn gv_webview_reload(handle: ?*anyopaque) void;
extern fn gv_webview_focus(handle: ?*anyopaque) void;
extern fn gv_webview_execute_script(
    handle: ?*anyopaque,
    js: [*:0]const u16,
    cb: ?ScriptFn,
    ctx: ?*anyopaque,
) c_int;

pub const create = gv_webview_create;
pub const setBounds = gv_webview_set_bounds;
pub const setVisible = gv_webview_set_visible;
pub const destroy = gv_webview_destroy;
pub const navigate = gv_webview_navigate;
pub const back = gv_webview_back;
pub const forward = gv_webview_forward;
pub const reload = gv_webview_reload;
pub const focus = gv_webview_focus;
pub const executeScript = gv_webview_execute_script;
