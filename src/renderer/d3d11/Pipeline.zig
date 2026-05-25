//! D3D11 pipeline (skeleton).
//!
//! A `Pipeline` bundles compiled vertex+pixel shaders, an input layout,
//! blend state, and rasterizer state — the per-Step constants. These are
//! built ahead-of-time and cached by `shaders.zig`.
const Self = @This();

const std = @import("std");
const d3d = @import("api.zig");

pub const Options = struct {
    device: *d3d.ID3D11Device,
    vs_bytecode: []const u8,
    ps_bytecode: []const u8,
    input_layout: []const d3d.DXGI_FORMAT = &.{},
};

vs: *d3d.ID3D11VertexShader,
ps: *d3d.ID3D11PixelShader,
layout: ?*d3d.ID3D11InputLayout,
blend: ?*d3d.ID3D11BlendState,
raster: ?*d3d.ID3D11RasterizerState,

pub fn init(opts: Options) !Self {
    _ = opts;
    return error.D3D11NotYetImplemented;
}

pub fn deinit(self: Self) void {
    _ = self;
}
