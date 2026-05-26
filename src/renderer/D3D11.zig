//! Graphics API wrapper for Direct3D 11.
//!
//! STATUS as of 2026-05-26: device + swap chain proof-of-life landed
//! in `apprt/win32/d3d11.zig` (clear-to-blue + present at startup,
//! validated on hardware feature level 11.1, BGRA8 flip-discard swap
//! chain). The COM bring-up is solid — d3d11/dxgi/d3dcompiler link
//! correctly, IDXGIFactory2/IDXGISwapChain1/ID3D11Device/...Context/
//! ID3D11RenderTargetView vtables match the real interface layouts.
//!
//! What this file still needs before `GenericRenderer(D3D11)` can
//! replace `GenericRenderer(OpenGL)` in `renderer.zig`:
//!
//!   1. `d3d11/shaders.zig` extern structs (Uniforms, CellText, Image,
//!      BgImage) — copy verbatim from `metal/shaders.zig`, they're
//!      shader-data layouts not backend-specific.
//!   2. The ~22 GraphicsAPI methods generic.zig calls:
//!        surfaceInit, finalizeSurfaceInit, threadEnter/Exit,
//!        loopEnter/Exit, displayRealized/Unrealized,
//!        drawFrameStart/End, surfaceSize, presentLastTarget,
//!        beginFrame, initTarget, initAtlasTexture, initShaders,
//!        plus the *BufferOptions / samplerOptions / textureOptions
//!        accessor families.
//!   3. HLSL shaders ported from `shaders/glsl/*.glsl` to
//!      `shaders/hlsl/*.hlsl`. Five shaders: bg_color, cell_bg,
//!      cell_text, image, bg_image. Account for HLSL ↔ GLSL deltas:
//!      row-major vs column-major matrices, NDC z range, sampler
//!      binding model.
//!   4. Real Buffer/Texture/Sampler implementations in
//!      `d3d11/{buffer,Texture,Sampler}.zig`. Each wraps the
//!      corresponding D3D11 object.
//!   5. Pipeline = vertex shader + pixel shader + input layout + blend
//!      state + rasterizer state, one per cell type. Built once in
//!      initShaders.
//!   6. Target = back-buffer-backed Texture2D + RTV (already prototyped
//!      in `apprt/win32/d3d11.zig::Context.createBackBufferRtv`).
//!   7. RenderPass = OMSetRenderTargets + ClearRenderTargetView +
//!      RSSetViewports prologue, draw work, no explicit epilogue.
//!
//! Estimated effort: 2-4 focused sessions on top of what's here.
//! `renderer.zig` keeps `.d3d11` falling back to `GenericRenderer(OpenGL)`
//! until all the above lands.
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
