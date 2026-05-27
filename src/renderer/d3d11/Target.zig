//! D3D11 render target wrapper.
//!
//! Holds an offscreen ID3D11Texture2D + its render-target view. The
//! renderer draws into this; `D3D11.present(target)` blits it onto the
//! swap chain's back buffer (Phase 3 work — currently the swap chain
//! is the only target the present loop touches).
const Self = @This();

const std = @import("std");
const d3d = @import("api.zig");

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    device: *d3d.ID3D11Device,
    width: usize,
    height: usize,
    pixel_format: d3d.DXGI_FORMAT = .B8G8R8A8_UNORM,
};

texture: *d3d.ID3D11Texture2D,
rtv: *d3d.ID3D11RenderTargetView,
width: usize,
height: usize,

pub fn init(opts: Options) !Self {
    const w = @max(1, opts.width);
    const h = @max(1, opts.height);

    const desc: d3d.D3D11_TEXTURE2D_DESC = .{
        .Width = @intCast(w),
        .Height = @intCast(h),
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = opts.pixel_format,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .DEFAULT,
        .BindFlags = .{ .render_target = true, .shader_resource = true },
        .CPUAccessFlags = .{},
        .MiscFlags = 0,
    };

    var tex: ?*d3d.ID3D11Texture2D = null;
    var hr = opts.device.vtable.CreateTexture2D(opts.device, &desc, null, &tex);
    if (d3d.failed(hr)) {
        log.err("Target.init CreateTexture2D failed: 0x{X:0>8} {d}x{d}", .{ @as(u32, @bitCast(hr)), w, h });
        return error.CreateTexture2DFailed;
    }
    errdefer _ = tex.?.release();

    var rtv: ?*d3d.ID3D11RenderTargetView = null;
    hr = opts.device.vtable.CreateRenderTargetView(opts.device, @ptrCast(tex.?), null, &rtv);
    if (d3d.failed(hr)) {
        log.err("Target.init CreateRenderTargetView failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.CreateRenderTargetViewFailed;
    }

    return .{ .texture = tex.?, .rtv = rtv.?, .width = w, .height = h };
}

pub fn deinit(self: Self) void {
    _ = self.rtv.release();
    _ = self.texture.release();
}
