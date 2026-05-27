//! D3D11 render pass.
//!
//! Holds a snapshot of the target + clear color, plus a back-reference
//! to the renderer's GraphicsAPI so each step can bind to the swap
//! chain's RTV. `step` does the per-draw binding (pipeline, cbuffer,
//! textures, buffers, topology, draw); the first step also handles the
//! clear.
const Self = @This();

const std = @import("std");
const d3d = @import("api.zig");
const D3D11 = @import("../D3D11.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const Pipeline = @import("Pipeline.zig");

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    attachments: []const Attachment,
    api: *const D3D11,

    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};

attachments: []const Options.Attachment,
api: *const D3D11,
step_number: usize = 0,

pub fn begin(opts: Options) Self {
    return .{
        .attachments = opts.attachments,
        .api = opts.api,
    };
}

pub fn step(self: *Self, s: anytype) void {
    const instance_count: usize = if (@hasField(@TypeOf(s.draw), "instance_count"))
        s.draw.instance_count
    else
        1;
    if (instance_count == 0 and self.step_number != 0) return;

    const api = self.api;
    const ctx = api.context;
    const rtv = api.swap.back_buffer_rtv orelse return;

    // Mark that real rendering happened this frame so drawFrameEnd will
    // present (see the FLIP_DISCARD note there).
    api.swap.did_render = true;

    // First step: bind the swap chain RTV + viewport + clear.
    if (self.step_number == 0) {
        const rtvs = [_]*d3d.ID3D11RenderTargetView{rtv};
        ctx.vtable.OMSetRenderTargets(ctx, 1, &rtvs, null);
        const vp: d3d.D3D11_VIEWPORT = .{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = @floatFromInt(api.swap.width),
            .Height = @floatFromInt(api.swap.height),
            .MinDepth = 0,
            .MaxDepth = 1,
        };
        const vps = [_]d3d.D3D11_VIEWPORT{vp};
        ctx.vtable.RSSetViewports(ctx, 1, &vps);
        if (self.attachments.len > 0) {
            if (self.attachments[0].clear_color) |c| {
                ctx.vtable.ClearRenderTargetView(ctx, rtv, &c);
            }
        }
    }
    defer self.step_number += 1;

    const pipeline: Pipeline = s.pipeline;
    ctx.vtable.VSSetShader(ctx, pipeline.vs, null, 0);
    ctx.vtable.PSSetShader(ctx, pipeline.ps, null, 0);
    ctx.vtable.IASetInputLayout(ctx, pipeline.layout);

    // Premultiplied-alpha blending so glyph edges + per-cell bg colors
    // composite over the background instead of overwriting it.
    ensureBlend(api);
    if (api.swap.blend) |blend| {
        ctx.vtable.OMSetBlendState(ctx, blend, null, 0xFFFFFFFF);
    }

    // Uniforms cbuffer at b1 (matches GLSL `layout(binding = 1)`).
    // s.uniforms is the BufferRef struct from our Buffer wrapper.
    if (@hasField(@TypeOf(s), "uniforms")) {
        const buffers = [_]*d3d.ID3D11Buffer{s.uniforms.handle};
        ctx.vtable.VSSetConstantBuffers(ctx, 1, 1, &buffers);
        ctx.vtable.PSSetConstantBuffers(ctx, 1, 1, &buffers);
    }

    // Texture atlases: t0 (grayscale), t1 (color).
    if (@hasField(@TypeOf(s), "textures")) {
        var slot: u32 = 0;
        inline for (s.textures) |tex_field| {
            if (slot < 2) {
                if (textureSrv(tex_field)) |srv| {
                    const one = [_]*d3d.ID3D11ShaderResourceView{srv};
                    ctx.vtable.PSSetShaderResources(ctx, slot, 1, &one);
                    ctx.vtable.VSSetShaderResources(ctx, slot, 1, &one);
                }
                slot += 1;
            }
        }
    }

    // Structured buffers: cells at t2, cells_bg at t3.
    if (@hasField(@TypeOf(s), "buffers")) {
        const tlen = comptime tupleOrSliceLen(@TypeOf(s.buffers));
        comptime var i: usize = 0;
        inline while (i < tlen) : (i += 1) {
            const elem = if (@typeInfo(@TypeOf(s.buffers)).pointer.size == .slice or
                @typeInfo(@TypeOf(s.buffers)) == .pointer)
                if (s.buffers.len > i) s.buffers[i] else continue
            else
                s.buffers[i];
            if (bufferElemSrv(elem)) |srv| {
                const slot: u32 = 2 + @as(u32, @intCast(i));
                const one = [_]*d3d.ID3D11ShaderResourceView{srv};
                ctx.vtable.PSSetShaderResources(ctx, slot, 1, &one);
                ctx.vtable.VSSetShaderResources(ctx, slot, 1, &one);
            }
        }
    }

    // Sampler at s0 (created lazily on first use).
    if (@hasField(@TypeOf(s), "textures") or @hasField(@TypeOf(s), "buffers")) {
        ensureSampler(api);
        if (api.swap.sampler) |samp| {
            const samps = [_]*d3d.ID3D11SamplerState{samp};
            ctx.vtable.PSSetSamplers(ctx, 0, 1, &samps);
            ctx.vtable.PSSetSamplers(ctx, 0, 1, &samps);
        }
    }

    const topology: d3d.D3D11_PRIMITIVE_TOPOLOGY = switch (s.draw.type) {
        .triangle => .TRIANGLELIST,
        .triangle_strip => .TRIANGLESTRIP,
        else => .TRIANGLELIST,
    };
    ctx.vtable.IASetPrimitiveTopology(ctx, topology);

    if (instance_count > 1) {
        ctx.vtable.DrawInstanced(ctx, @intCast(s.draw.vertex_count), @intCast(instance_count), 0, 0);
    } else {
        ctx.vtable.Draw(ctx, @intCast(s.draw.vertex_count), 0);
    }
}

pub fn complete(self: *Self) void {
    _ = self;
}

fn tupleOrSliceLen(comptime T: type) usize {
    const info = @typeInfo(T);
    if (info == .@"struct" and info.@"struct".is_tuple) return info.@"struct".fields.len;
    // Slice / many-pointer: length only known at runtime; we use a
    // conservative upper bound that's iterated with `if (.len > i)`
    // guarding the access.
    return 8;
}

fn textureSrv(tex_field: anytype) ?*d3d.ID3D11ShaderResourceView {
    const T = @TypeOf(tex_field);
    if (T == @TypeOf(null)) return null;
    if (@typeInfo(T) == .optional) {
        if (tex_field) |t| return t.srv;
        return null;
    }
    return tex_field.srv;
}

fn bufferElemSrv(elem: anytype) ?*d3d.ID3D11ShaderResourceView {
    const T = @TypeOf(elem);
    if (T == @TypeOf(null)) return null;
    if (@typeInfo(T) == .optional) {
        if (elem) |inner| return inner.srv;
        return null;
    }
    // BufferRef struct.
    if (@hasField(T, "srv")) return elem.srv;
    return null;
}

fn ensureBlend(api: *const D3D11) void {
    if (api.swap.blend != null) return;
    const default_rt: d3d.D3D11_RENDER_TARGET_BLEND_DESC = .{};
    var rt: [8]d3d.D3D11_RENDER_TARGET_BLEND_DESC = .{default_rt} ** 8;
    // Premultiplied-alpha "over": result = src + dst*(1-src.a).
    rt[0] = .{
        .BlendEnable = 1,
        .SrcBlend = .ONE,
        .DestBlend = .INV_SRC_ALPHA,
        .BlendOp = .ADD,
        .SrcBlendAlpha = .ONE,
        .DestBlendAlpha = .INV_SRC_ALPHA,
        .BlendOpAlpha = .ADD,
        .RenderTargetWriteMask = 0x0F,
    };
    const desc: d3d.D3D11_BLEND_DESC = .{
        .AlphaToCoverageEnable = 0,
        .IndependentBlendEnable = 0,
        .RenderTarget = rt,
    };
    var blend: ?*d3d.ID3D11BlendState = null;
    const hr = api.device.vtable.CreateBlendState(api.device, &desc, &blend);
    if (d3d.failed(hr)) {
        log.err("ensureBlend CreateBlendState failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return;
    }
    api.swap.blend = blend;
}

fn ensureSampler(api: *const D3D11) void {
    if (api.swap.sampler != null) return;
    const desc: d3d.D3D11_SAMPLER_DESC = .{
        .Filter = .MIN_MAG_MIP_LINEAR,
        .AddressU = .CLAMP,
        .AddressV = .CLAMP,
        .AddressW = .CLAMP,
    };
    var samp: ?*d3d.ID3D11SamplerState = null;
    const hr = api.device.vtable.CreateSamplerState(api.device, &desc, &samp);
    if (d3d.failed(hr)) {
        log.err("ensureSampler CreateSamplerState failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return;
    }
    api.swap.sampler = samp;
}
