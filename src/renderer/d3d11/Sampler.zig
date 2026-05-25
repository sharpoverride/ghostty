//! D3D11 sampler wrapper (skeleton).
const Self = @This();

const std = @import("std");
const d3d = @import("api.zig");

pub const Options = struct {
    device: *d3d.ID3D11Device,
    filter: d3d.D3D11_FILTER = .MIN_MAG_MIP_LINEAR,
    address_u: d3d.D3D11_TEXTURE_ADDRESS_MODE = .CLAMP,
    address_v: d3d.D3D11_TEXTURE_ADDRESS_MODE = .CLAMP,
};

sampler: *d3d.ID3D11SamplerState,

pub fn init(opts: Options) !Self {
    _ = opts;
    return error.D3D11NotYetImplemented;
}

pub fn deinit(self: Self) void {
    _ = self;
}
