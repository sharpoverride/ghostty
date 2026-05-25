//! D3D11 buffer wrapper (skeleton).
const std = @import("std");
const d3d = @import("api.zig");

pub const Options = struct {
    device: *d3d.ID3D11Device,
    context: *d3d.ID3D11DeviceContext,
    usage: d3d.D3D11_USAGE = .DEFAULT,
    bind_flags: d3d.D3D11_BIND_FLAG,
    cpu_access: d3d.D3D11_CPU_ACCESS_FLAG = .{},
};

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        opts: Options,
        buffer: *d3d.ID3D11Buffer,
        len: usize,

        pub fn init(opts: Options, len: usize) !Self {
            _ = opts;
            _ = len;
            return error.D3D11NotYetImplemented;
        }

        pub fn initFill(opts: Options, data: []const T) !Self {
            _ = opts;
            _ = data;
            return error.D3D11NotYetImplemented;
        }

        pub fn deinit(self: *const Self) void {
            _ = self;
        }

        pub fn sync(self: *Self, data: []const T) !void {
            _ = self;
            _ = data;
            return error.D3D11NotYetImplemented;
        }
    };
}
