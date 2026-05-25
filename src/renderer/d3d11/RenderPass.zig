//! D3D11 render pass (skeleton).
//!
//! Wraps a single OMSetRenderTargets + a sequence of Step issues. Closes
//! by clearing the active RTV/SRVs.
const Self = @This();

const std = @import("std");
const d3d = @import("api.zig");
const Target = @import("Target.zig");

pub const Options = struct {
    context: *d3d.ID3D11DeviceContext,
    target: *Target,
    clear_color: ?[4]f32 = null,
};

pub const Step = struct {
    // Vertex / pixel shader pair + bound resources for a single draw call.
    // Fully populated when the renderer abstraction is wired.
};

context: *d3d.ID3D11DeviceContext,
target: *Target,

pub fn begin(opts: Options) !Self {
    _ = opts;
    return error.D3D11NotYetImplemented;
}

pub fn step(self: *Self, s: Step) !void {
    _ = self;
    _ = s;
    return error.D3D11NotYetImplemented;
}

pub fn end(self: *Self) void {
    _ = self;
}
