//! D3D11 pipeline.
//!
//! Bundles compiled vertex+pixel shaders and an optional input layout.
//! Owned by `shaders.Shaders.PipelineCollection`. Real blend/raster
//! state is bound per-step by the renderer; this struct holds only the
//! per-shader-program resources.
const Self = @This();

const std = @import("std");
const d3d = @import("api.zig");

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    device: *d3d.ID3D11Device,
    vs_bytecode: []const u8,
    ps_bytecode: []const u8,
    /// Input element descriptors, point-resolved by the renderer. Empty
    /// for full-screen draws that derive position from SV_VertexID.
    input_elements: []const d3d.D3D11_INPUT_ELEMENT_DESC = &.{},
};

vs: *d3d.ID3D11VertexShader,
ps: *d3d.ID3D11PixelShader,
layout: ?*d3d.ID3D11InputLayout,

pub fn init(opts: Options) !Self {
    var vs: ?*d3d.ID3D11VertexShader = null;
    var hr = opts.device.vtable.CreateVertexShader(
        opts.device,
        opts.vs_bytecode.ptr,
        opts.vs_bytecode.len,
        null,
        &vs,
    );
    if (d3d.failed(hr)) {
        log.err("CreateVertexShader failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.CreateVertexShaderFailed;
    }
    errdefer _ = vs.?.release();

    var ps: ?*d3d.ID3D11PixelShader = null;
    hr = opts.device.vtable.CreatePixelShader(
        opts.device,
        opts.ps_bytecode.ptr,
        opts.ps_bytecode.len,
        null,
        &ps,
    );
    if (d3d.failed(hr)) {
        log.err("CreatePixelShader failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.CreatePixelShaderFailed;
    }
    errdefer _ = ps.?.release();

    var layout: ?*d3d.ID3D11InputLayout = null;
    if (opts.input_elements.len > 0) {
        hr = opts.device.vtable.CreateInputLayout(
            opts.device,
            opts.input_elements.ptr,
            @intCast(opts.input_elements.len),
            opts.vs_bytecode.ptr,
            opts.vs_bytecode.len,
            &layout,
        );
        if (d3d.failed(hr)) {
            log.err("CreateInputLayout failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
            return error.CreateInputLayoutFailed;
        }
    }

    return .{ .vs = vs.?, .ps = ps.?, .layout = layout };
}

pub fn deinit(self: Self) void {
    if (self.layout) |l| _ = l.release();
    _ = self.ps.release();
    _ = self.vs.release();
}
