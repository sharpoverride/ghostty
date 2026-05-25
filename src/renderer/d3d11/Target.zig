//! D3D11 render target wrapper (skeleton).
//!
//! Represents an ID3D11Texture2D + ID3D11RenderTargetView pair. For the
//! window surface this is backed by an IDXGISwapChain1's back buffer; for
//! offscreen passes it's a standalone texture.
const Self = @This();

const std = @import("std");
const d3d = @import("api.zig");

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
    _ = opts;
    return error.D3D11NotYetImplemented;
}

pub fn deinit(self: Self) void {
    _ = self;
}
