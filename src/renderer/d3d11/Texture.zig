//! D3D11 texture wrapper (skeleton).
const Self = @This();

const std = @import("std");
const d3d = @import("api.zig");

pub const Options = struct {
    device: *d3d.ID3D11Device,
    context: *d3d.ID3D11DeviceContext,
    pixel_format: d3d.DXGI_FORMAT,
    usage: d3d.D3D11_USAGE = .DEFAULT,
    bind_flags: d3d.D3D11_BIND_FLAG = .{ .shader_resource = true },
    cpu_access: d3d.D3D11_CPU_ACCESS_FLAG = .{},
};

pub const Error = error{ D3D11Failed, D3D11NotYetImplemented };

texture: *d3d.ID3D11Texture2D,
srv: ?*d3d.ID3D11ShaderResourceView,
width: usize,
height: usize,
bpp: usize,

pub fn init(opts: Options, width: usize, height: usize, data: ?[]const u8) Error!Self {
    _ = opts;
    _ = width;
    _ = height;
    _ = data;
    return error.D3D11NotYetImplemented;
}

pub fn deinit(self: Self) void {
    _ = self;
}

pub fn replaceRegion(self: *const Self, x: usize, y: usize, w: usize, h: usize, data: []const u8) !void {
    _ = self;
    _ = x;
    _ = y;
    _ = w;
    _ = h;
    _ = data;
    return error.D3D11NotYetImplemented;
}
