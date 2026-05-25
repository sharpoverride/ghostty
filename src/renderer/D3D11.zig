//! Graphics API wrapper for Direct3D 11.
//!
//! STATUS: structural skeleton. All sub-modules (`d3d11/api.zig`,
//! `d3d11/{Target,Frame,RenderPass,Pipeline,Sampler,Texture,buffer,shaders}.zig`)
//! exist and pass `zig ast-check`, but their method bodies are stubs that
//! return `error.D3D11NotYetImplemented`. To make `GenericRenderer(D3D11)`
//! actually compile, two non-trivial pieces still need to land:
//!
//!   1. `d3d11/shaders.zig` must expose real `Uniforms`, `CellText`,
//!      `Image`, `BgImage` extern structs with the exact memory layout HLSL
//!      shaders will consume. Cleanest path: copy these from
//!      `metal/shaders.zig` verbatim — they're shader-data layouts, not
//!      backend-specific.
//!   2. This file must grow the ~22 GraphicsAPI methods generic.zig calls:
//!      surfaceInit, finalizeSurfaceInit, threadEnter/Exit, loopEnter/Exit,
//!      displayRealized/Unrealized, drawFrameStart/End, surfaceSize,
//!      presentLastTarget, beginFrame, initTarget, initAtlasTexture,
//!      initShaders, plus the *BufferOptions / samplerOptions /
//!      textureOptions accessor families.
//!
//! Until those land, `src/renderer.zig` keeps `.d3d11` mapped to
//! `GenericRenderer(OpenGL)` as a stand-in.
pub const D3D11 = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const shadertoy = @import("shadertoy.zig");

const d3d = @import("d3d11/api.zig");

pub const GraphicsAPI = D3D11;
pub const Target = @import("d3d11/Target.zig");
pub const Frame = @import("d3d11/Frame.zig");
pub const RenderPass = @import("d3d11/RenderPass.zig");
pub const Pipeline = @import("d3d11/Pipeline.zig");
const bufferpkg = @import("d3d11/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("d3d11/Sampler.zig");
pub const Texture = @import("d3d11/Texture.zig");
pub const shaders = @import("d3d11/shaders.zig");

// HLSL is the obvious target for user shaders. The shadertoy transpile step
// will need an HLSL emitter — until then we accept GLSL as a working stand-in.
pub const custom_shader_target: shadertoy.Target = .glsl;

// HLSL's clip-space matches Metal's: y goes down.
pub const custom_shader_y_is_down = true;

// Triple-buffered flip-model DXGI swap chain.
pub const swap_chain_count = 3;

device: *d3d.ID3D11Device,
context: *d3d.ID3D11DeviceContext,
blending: configpkg.Config.AlphaBlending,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !D3D11 {
    _ = alloc;
    _ = opts;
    comptime if (builtin.os.tag != .windows) @compileError("D3D11 backend requires Windows");
    return error.D3D11NotYetImplemented;
}

pub fn deinit(self: *D3D11) void {
    self.* = undefined;
}
