//! D3D11 sampler.
const Self = @This();

const std = @import("std");
const d3d = @import("api.zig");

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    device: *d3d.ID3D11Device,
    filter: d3d.D3D11_FILTER = .MIN_MAG_MIP_LINEAR,
    address_u: d3d.D3D11_TEXTURE_ADDRESS_MODE = .CLAMP,
    address_v: d3d.D3D11_TEXTURE_ADDRESS_MODE = .CLAMP,
};

sampler: *d3d.ID3D11SamplerState,

pub fn init(opts: Options) !Self {
    const desc: d3d.D3D11_SAMPLER_DESC = .{
        .Filter = opts.filter,
        .AddressU = opts.address_u,
        .AddressV = opts.address_v,
        .AddressW = .CLAMP,
    };
    var samp: ?*d3d.ID3D11SamplerState = null;
    const hr = opts.device.vtable.CreateSamplerState(opts.device, &desc, &samp);
    if (d3d.failed(hr)) {
        log.err("CreateSamplerState failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.CreateSamplerStateFailed;
    }
    return .{ .sampler = samp.? };
}

pub fn deinit(self: Self) void {
    _ = self.sampler.release();
}
