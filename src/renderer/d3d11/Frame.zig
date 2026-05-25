//! D3D11 frame context (skeleton).
//!
//! Wraps a deferred command list (or the immediate context, depending on
//! threading model) plus the bookkeeping needed to fire the completion
//! callback after Present.
const Self = @This();

const std = @import("std");
const d3d = @import("api.zig");
const D3D11 = @import("../D3D11.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");
const Health = @import("../../renderer.zig").Health;

pub const Options = struct {
    context: *d3d.ID3D11DeviceContext,
};

context: *d3d.ID3D11DeviceContext,
target: *Target,

pub fn begin(
    opts: Options,
    api: anytype,
    target: *Target,
) !Self {
    _ = opts;
    _ = api;
    _ = target;
    return error.D3D11NotYetImplemented;
}

pub fn deinit(self: *Self) void {
    _ = self;
}
