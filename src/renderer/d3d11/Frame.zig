//! D3D11 frame context.
//!
//! Mirrors `opengl/Frame.zig`. Construction stores refs to the renderer
//! + target; `renderPass` returns a RenderPass (currently no-op step
//! impls) and `complete` is a no-op (Present happens in
//! `D3D11.drawFrameEnd`).
const Self = @This();

const std = @import("std");
const d3d = @import("api.zig");
const D3D11 = @import("../D3D11.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");
const Renderer = @import("../generic.zig").Renderer(D3D11);
const Health = @import("../../renderer.zig").Health;

pub const Options = struct {};

renderer: *Renderer,
target: *Target,

pub fn begin(
    opts: Options,
    renderer: *Renderer,
    target: *Target,
) !Self {
    _ = opts;
    return .{
        .renderer = renderer,
        .target = target,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn complete(self: *Self, sync: bool) void {
    _ = sync;
    // CRITICAL: signal frame completion so the renderer's SwapChain
    // semaphore is released. Without this, after `swap_chain_count`
    // frames the next `nextFrame()` blocks forever on `frame_sema.wait()`
    // and the whole renderer thread freezes (this was the ~3-frame
    // freeze). D3D11 present is effectively synchronous from our side
    // (no GPU fence wait), so we report healthy immediately.
    self.renderer.frameCompleted(.healthy);
}

pub fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    return RenderPass.begin(.{
        .attachments = attachments,
        .api = &self.renderer.api,
    });
}
