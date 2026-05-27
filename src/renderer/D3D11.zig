//! Graphics API wrapper for Direct3D 11.
//!
//! STATUS as of the windows-port branch: device + immediate context are
//! created in init; all 22 GraphicsAPI methods have signatures that
//! match what `generic.zig` calls. Runtime implementation of most
//! methods returns `error.D3D11NotYetImplemented` — flipping the
//! `renderer.zig` dispatch to GenericRenderer(D3D11) gets the build
//! through compile, and the first frame will surface concrete TODOs
//! by way of errors from whichever method gets called first.
//!
//! Swap chain lives on the apprt-side (`apprt/win32/d3d11.zig`) for now
//! because it needs the HWND. A future refactor may push it down here
//! once the surface lifecycle is settled.
pub const D3D11 = @This();

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const rendererpkg = @import("../renderer.zig");
const shadertoy = @import("shadertoy.zig");

const d3d = @import("d3d11/api.zig");

pub const GraphicsAPI = D3D11;
pub const Target = @import("d3d11/Target.zig");
pub const Frame = @import("d3d11/Frame.zig");
pub const RenderPass = @import("d3d11/RenderPass.zig");
pub const Pipeline = @import("d3d11/Pipeline.zig");
const bufferpkg = @import("d3d11/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("d3d11/Sampler.zig");
pub const Texture = @import("d3d11/Texture.zig");
pub const shaders = @import("d3d11/shaders.zig");

const Renderer = rendererpkg.GenericRenderer(D3D11);

pub const custom_shader_target: shadertoy.Target = .glsl;
pub const custom_shader_y_is_down = true;
pub const swap_chain_count = 3;

const log = std.log.scoped(.d3d11);

/// Per-surface swap-chain state. Heap-allocated so that methods on
/// `*const D3D11` (notably `threadEnter`) can still mutate it.
pub const SwapState = struct {
    swap_chain: ?*d3d.IDXGISwapChain1 = null,
    back_buffer_rtv: ?*d3d.ID3D11RenderTargetView = null,
    hwnd: ?*anyopaque = null,
    width: u32 = 0,
    height: u32 = 0,
    /// Default sampler used for atlas/glyph texture lookups. Created
    /// lazily on first use by RenderPass.step.
    sampler: ?*d3d.ID3D11SamplerState = null,
    /// Premultiplied-alpha blend state (One, InvSrcAlpha). Created
    /// lazily on first use by RenderPass.step.
    blend: ?*d3d.ID3D11BlendState = null,
    /// Set true by RenderPass.step when a real render pass draws into
    /// the back buffer this frame. drawFrameEnd only presents when this
    /// is set — otherwise (non-dirty frames where generic.zig early-
    /// returns without rendering) we'd Present an undefined FLIP_DISCARD
    /// back buffer and show a blank/garbage frame. Reset in drawFrameStart.
    did_render: bool = false,
};

alloc: Allocator,
device: *d3d.ID3D11Device,
context: *d3d.ID3D11DeviceContext,
blending: configpkg.Config.AlphaBlending,
/// DXGI factory used for swap chain construction. Created in init.
factory: *d3d.IDXGIFactory2,
/// Heap-allocated mutable state. See `SwapState`.
swap: *SwapState,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !D3D11 {
    comptime if (builtin.os.tag != .windows) @compileError("D3D11 backend requires Windows");

    var device: ?*d3d.ID3D11Device = null;
    var ctx: ?*d3d.ID3D11DeviceContext = null;
    var fl: d3d.D3D_FEATURE_LEVEL = .@"11_0";
    const feature_levels = [_]d3d.D3D_FEATURE_LEVEL{ .@"11_1", .@"11_0" };
    const flags: d3d.D3D11_CREATE_DEVICE_FLAG = .{};
    var hr = d3d.D3D11CreateDevice(
        null,
        .HARDWARE,
        null,
        @bitCast(flags),
        &feature_levels,
        feature_levels.len,
        d3d.D3D11_SDK_VERSION,
        &device,
        &fl,
        &ctx,
    );
    if (d3d.failed(hr)) {
        log.err("D3D11CreateDevice failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.D3D11CreateDeviceFailed;
    }
    errdefer _ = device.?.release();
    errdefer _ = ctx.?.release();

    var factory: ?*d3d.IDXGIFactory2 = null;
    hr = d3d.CreateDXGIFactory2(0, &d3d.IID_IDXGIFactory2, &factory);
    if (d3d.failed(hr)) {
        log.err("CreateDXGIFactory2 failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.CreateDXGIFactory2Failed;
    }
    errdefer _ = factory.?.release();

    const swap = try alloc.create(SwapState);
    swap.* = .{};
    errdefer alloc.destroy(swap);

    log.info("D3D11 device + DXGI factory created feature_level=0x{X}", .{@intFromEnum(fl)});

    return .{
        .alloc = alloc,
        .device = device.?,
        .context = ctx.?,
        .factory = factory.?,
        .swap = swap,
        .blending = opts.config.blending,
    };
}

pub fn deinit(self: *D3D11) void {
    if (self.swap.blend) |b| _ = b.release();
    if (self.swap.sampler) |s| _ = s.release();
    if (self.swap.back_buffer_rtv) |rtv| _ = rtv.release();
    if (self.swap.swap_chain) |sc| _ = sc.release();
    self.alloc.destroy(self.swap);
    _ = self.factory.release();
    _ = self.context.release();
    _ = self.device.release();
    self.* = undefined;
}

extern "user32" fn GetClientRect(hwnd: *anyopaque, lpRect: *windows.RECT) callconv(.winapi) c_int;

/// Create or recreate the swap chain attached to `hwnd` at the given
/// client-area size. Idempotent at the same size — if a swap chain
/// already exists, calls ResizeBuffers instead of rebuilding.
fn ensureSwapChain(self: *const D3D11, hwnd: *anyopaque, width: u32, height: u32) !void {
    const w = @max(1, width);
    const h = @max(1, height);
    const swap = self.swap;
    swap.hwnd = hwnd;

    if (swap.swap_chain) |sc| {
        if (swap.width == w and swap.height == h) return;
        if (swap.back_buffer_rtv) |rtv| {
            _ = rtv.release();
            swap.back_buffer_rtv = null;
        }
        const hr = sc.vtable.ResizeBuffers(sc, 0, w, h, .UNKNOWN, 0);
        if (d3d.failed(hr)) {
            log.err("ResizeBuffers failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
            return error.ResizeBuffersFailed;
        }
        swap.back_buffer_rtv = try createBackBufferRtv(self.device, sc);
        swap.width = w;
        swap.height = h;
        return;
    }

    const desc: d3d.DXGI_SWAP_CHAIN_DESC1 = .{
        .Width = w,
        .Height = h,
        .Format = .B8G8R8A8_UNORM,
        .Stereo = 0,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .BufferUsage = .{ .render_target_output = true },
        .BufferCount = 2,
        .Scaling = .STRETCH,
        .SwapEffect = .FLIP_DISCARD,
        .AlphaMode = .UNSPECIFIED,
        .Flags = 0,
    };
    var new_sc: ?*d3d.IDXGISwapChain1 = null;
    const hr = self.factory.vtable.CreateSwapChainForHwnd(
        self.factory,
        @ptrCast(self.device),
        @ptrCast(hwnd),
        &desc,
        null,
        null,
        &new_sc,
    );
    if (d3d.failed(hr)) {
        log.err("CreateSwapChainForHwnd failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.CreateSwapChainForHwndFailed;
    }
    errdefer _ = new_sc.?.release();

    swap.back_buffer_rtv = try createBackBufferRtv(self.device, new_sc.?);
    swap.swap_chain = new_sc.?;
    swap.width = w;
    swap.height = h;
    log.info("D3D11 swap chain created hwnd=0x{X} {d}x{d}", .{ @intFromPtr(hwnd), w, h });
}

fn createBackBufferRtv(
    device: *d3d.ID3D11Device,
    swap: *d3d.IDXGISwapChain1,
) !*d3d.ID3D11RenderTargetView {
    var back_buffer: ?*anyopaque = null;
    var hr = swap.vtable.GetBuffer(swap, 0, &d3d.IID_ID3D11Texture2D, &back_buffer);
    if (d3d.failed(hr)) {
        log.err("swap.GetBuffer failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.GetBufferFailed;
    }
    const tex: *d3d.ID3D11Texture2D = @ptrCast(@alignCast(back_buffer.?));
    defer _ = tex.release();

    var rtv: ?*d3d.ID3D11RenderTargetView = null;
    hr = device.vtable.CreateRenderTargetView(device, @ptrCast(tex), null, &rtv);
    if (d3d.failed(hr)) {
        log.err("CreateRenderTargetView failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.CreateRenderTargetViewFailed;
    }
    return rtv.?;
}

// ---------------------------------------------------------------------------
// Lifecycle / per-frame hooks.
// ---------------------------------------------------------------------------

pub fn surfaceInit(surface: *apprt.Surface) !void {
    _ = surface;
    // No per-thread GL-context-style binding for D3D11; the device +
    // immediate context are thread-affine but used only from the
    // renderer thread.
}

pub fn finalizeSurfaceInit(self: *const D3D11, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;
}

pub fn threadEnter(self: *const D3D11, surface: *apprt.Surface) !void {
    // The renderer thread is what owns the swap chain; create or attach
    // it lazily here. Reading the HWND's client area here gives us a
    // reasonable initial size; later resizes come through drawFrameStart.
    const hwnd = surface.window.hwnd;
    var rect: windows.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = GetClientRect(@ptrCast(hwnd), &rect);
    const w: u32 = @intCast(@max(1, rect.right - rect.left));
    const h: u32 = @intCast(@max(1, rect.bottom - rect.top));
    try self.ensureSwapChain(@ptrCast(hwnd), w, h);
}

pub fn threadExit(self: *const D3D11) void {
    _ = self;
}

pub fn displayRealized(self: *const D3D11) void {
    _ = self;
    @panic("displayRealized only used by GTK");
}

pub fn drawFrameStart(self: *D3D11) void {
    // Reset the per-frame render flag; RenderPass.step sets it when a
    // pass actually draws into the back buffer.
    self.swap.did_render = false;

    // Tick the FPS counter on every draw attempt (this reflects the
    // render-loop cadence — e.g. the 120fps forced refresh — rather than
    // the GPU present rate, which is content-gated). Published atomically
    // for the title bar.
    Fps.count += 1;
    const now_ms = std.time.milliTimestamp();
    if (Fps.last_ms == 0) Fps.last_ms = now_ms;
    if (now_ms - Fps.last_ms >= 1000) {
        Fps.value.store(Fps.count, .monotonic);
        Fps.count = 0;
        Fps.last_ms = now_ms;
    }

    // Keep the swap chain in sync with the HWND's client area. The
    // renderer thread is the only writer to swap.* so this is safe
    // outside any lock — width/height comparisons inside ensureSwapChain
    // make this a no-op the common case.
    if (self.swap.hwnd) |hwnd| {
        var rect: windows.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = GetClientRect(@ptrCast(hwnd), &rect);
        const w: u32 = @intCast(@max(1, rect.right - rect.left));
        const h: u32 = @intCast(@max(1, rect.bottom - rect.top));
        self.ensureSwapChain(hwnd, w, h) catch |e| {
            log.err("drawFrameStart ensureSwapChain failed: {}", .{e});
        };
    }
}

pub fn drawFrameEnd(self: *D3D11) void {
    const sc = self.swap.swap_chain orelse return;

    // Only present when a render pass actually drew this frame. With
    // FLIP_DISCARD the back buffer is undefined after a Present, so
    // presenting a frame we didn't render shows blank/garbage. On
    // non-dirty frames the screen simply keeps showing the last
    // presented content (no Present needed).
    if (!self.swap.did_render) return;

    // Present with sync interval 0 (no vsync). The ~3-frame freeze that
    // looked like a Present block was actually the SwapChain frame
    // semaphore (Frame.complete wasn't releasing it); now fixed. A plain
    // Present does not block indefinitely on a flip swap chain even when
    // occluded (it returns DXGI_STATUS_OCCLUDED), so DO_NOT_WAIT is
    // unnecessary and would just skip presents (leaving a stale frame).
    _ = sc.vtable.Present(sc, 0, 0);
}

const Fps = struct {
    var count: u32 = 0;
    var last_ms: i64 = 0;
    var value: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
};

/// Last frames-per-second sample (updated once/sec). Surfaced in the
/// win32 title bar.
pub fn currentFps() u32 {
    return Fps.value.load(.monotonic);
}

pub fn surfaceSize(self: *const D3D11) !struct { width: u32, height: u32 } {
    if (self.swap.width == 0 or self.swap.height == 0) {
        return .{ .width = 1, .height = 1 };
    }
    return .{ .width = self.swap.width, .height = self.swap.height };
}

// ---------------------------------------------------------------------------
// Resource construction.
// ---------------------------------------------------------------------------

pub fn initShaders(
    self: *const D3D11,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    return try shaders.Shaders.init(alloc, self.device, custom_shaders, .B8G8R8A8_UNORM);
}

pub fn initTarget(self: *const D3D11, width: usize, height: usize) !Target {
    return Target.init(.{
        .device = self.device,
        .width = width,
        .height = height,
        .pixel_format = .B8G8R8A8_UNORM,
    });
}

pub fn initAtlasTexture(
    self: *const D3D11,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    const format: d3d.DXGI_FORMAT = switch (atlas.format) {
        .grayscale => .R8_UNORM,
        .bgr => .R8G8B8A8_UNORM, // BGR not natively supported; will need conversion
        .bgra => .B8G8R8A8_UNORM,
    };
    return Texture.init(
        .{
            .device = self.device,
            .context = self.context,
            .pixel_format = format,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

pub inline fn beginFrame(
    self: *const D3D11,
    renderer: *Renderer,
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}

pub fn present(self: *D3D11, target: Target) !void {
    _ = self;
    _ = target;
    // No-op: real present happens in `drawFrameEnd` for now. Phase 3
    // will move the actual blit-from-target → back-buffer here.
}

pub fn presentLastTarget(self: *D3D11) !void {
    _ = self;
    // No-op: `drawFrameEnd` always presents.
}

// ---------------------------------------------------------------------------
// Options accessors. The renderer uses these to construct buffers,
// samplers, and textures with backend-appropriate defaults.
// ---------------------------------------------------------------------------

pub inline fn bufferOptions(self: D3D11) bufferpkg.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .usage = .DYNAMIC,
        .bind_flags = .{ .vertex_buffer = true },
        .cpu_access = .{ .write = true },
    };
}

pub inline fn instanceBufferOptions(self: D3D11) bufferpkg.Options {
    return self.bufferOptions();
}

pub inline fn uniformBufferOptions(self: D3D11) bufferpkg.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .usage = .DYNAMIC,
        .bind_flags = .{ .constant_buffer = true },
        .cpu_access = .{ .write = true },
    };
}

pub inline fn fgBufferOptions(self: D3D11) bufferpkg.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .usage = .DYNAMIC,
        .bind_flags = .{ .shader_resource = true },
        .cpu_access = .{ .write = true },
        .misc_flags = d3d.D3D11_RESOURCE_MISC_BUFFER_STRUCTURED,
        // CellText struct stride.
        .structure_byte_stride = 32,
        .create_srv = true,
    };
}

pub inline fn bgBufferOptions(self: D3D11) bufferpkg.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .usage = .DYNAMIC,
        .bind_flags = .{ .shader_resource = true },
        .cpu_access = .{ .write = true },
        .misc_flags = d3d.D3D11_RESOURCE_MISC_BUFFER_STRUCTURED,
        // CellBg = [4]u8 (4 bytes per cell).
        .structure_byte_stride = 4,
        .create_srv = true,
    };
}

pub inline fn imageBufferOptions(self: D3D11) bufferpkg.Options {
    return self.bufferOptions();
}

pub inline fn bgImageBufferOptions(self: D3D11) bufferpkg.Options {
    return self.bufferOptions();
}

pub inline fn textureOptions(self: D3D11) Texture.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .pixel_format = .B8G8R8A8_UNORM,
    };
}

pub inline fn samplerOptions(self: D3D11) Sampler.Options {
    return .{
        .device = self.device,
    };
}

pub const ImageTextureFormat = enum {
    gray,
    rgba,
    bgra,

    fn toDxgi(self: ImageTextureFormat) d3d.DXGI_FORMAT {
        return switch (self) {
            .gray => .R8_UNORM,
            .rgba => .R8G8B8A8_UNORM,
            .bgra => .B8G8R8A8_UNORM,
        };
    }
};

pub inline fn imageTextureOptions(
    self: D3D11,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = srgb;
    return .{
        .device = self.device,
        .context = self.context,
        .pixel_format = format.toDxgi(),
    };
}
