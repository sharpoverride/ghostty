//! D3D11 shader collection.
//!
//! Two real pipelines for Phase 3:
//!   * `bg_color` — fullscreen quad that reads `bg_color` from the
//!     `Uniforms` cbuffer and outputs it. Used for `bg_color`,
//!     `cell_bg`, `image`, and `bg_image` slots.
//!   * `cell_text` — per-instance glyph rendering. Reads CellText
//!     vertex attributes, computes screen position via the projection
//!     matrix, samples the grayscale atlas, outputs glyph alpha * color.
//!
//! Both share the `Uniforms` cbuffer at register b1.

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = @import("../../math.zig");
const d3d = @import("api.zig");
const Pipeline = @import("Pipeline.zig");

const log = std.log.scoped(.d3d11);

pub const Shaders = struct {
    pipelines: PipelineCollection,
    post_pipelines: []const Pipeline,
    defunct: bool = false,

    pub fn init(
        alloc: Allocator,
        device: *d3d.ID3D11Device,
        post_shaders: []const [:0]const u8,
        pixel_format: d3d.DXGI_FORMAT,
    ) !Shaders {
        _ = post_shaders;
        _ = pixel_format;

        if (!d3d.loadD3DCompiler()) {
            log.err("d3dcompiler_47.dll could not be loaded", .{});
            return error.D3DCompilerLoadFailed;
        }

        // bg_color shader — fullscreen, no vertex inputs.
        const bg = try compilePipeline(device, bg_color_hlsl, &.{});
        errdefer bg.deinit();
        // cell_bg — per-cell background colors (renders cursor block,
        // selection highlight, colored cell backgrounds).
        const cb = try compilePipeline(device, cell_bg_hlsl, &.{});
        errdefer cb.deinit();
        const img = try compilePipeline(device, bg_color_hlsl, &.{});
        errdefer img.deinit();
        const bgi = try compilePipeline(device, bg_color_hlsl, &.{});
        errdefer bgi.deinit();

        // cell_text shader — per-instance vertex data.
        const ct = try compilePipeline(device, cell_text_hlsl, cell_text_input_layout);
        errdefer ct.deinit();

        log.info("D3D11 shaders compiled — bg_color + cell_text pipelines", .{});

        return .{
            .pipelines = .{
                .bg_color = bg,
                .cell_bg = cb,
                .cell_text = ct,
                .image = img,
                .bg_image = bgi,
            },
            .post_pipelines = try alloc.alloc(Pipeline, 0),
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        self.pipelines.bg_color.deinit();
        self.pipelines.cell_bg.deinit();
        self.pipelines.cell_text.deinit();
        self.pipelines.image.deinit();
        self.pipelines.bg_image.deinit();
        alloc.free(self.post_pipelines);
    }
};

pub const PipelineCollection = struct {
    bg_color: Pipeline,
    cell_bg: Pipeline,
    cell_text: Pipeline,
    image: Pipeline,
    bg_image: Pipeline,
};

fn blobBytes(blob: *d3d.ID3DBlob) []const u8 {
    const ptr: [*]const u8 = @ptrCast(blob.bufferPointer());
    return ptr[0..blob.bufferSize()];
}

fn compileHlsl(source: []const u8, entry: [*:0]const u8, target: [*:0]const u8) !*d3d.ID3DBlob {
    var blob: ?*d3d.ID3DBlob = null;
    var err_blob: ?*d3d.ID3DBlob = null;
    const hr = d3d.D3DCompile.?(
        source.ptr,
        source.len,
        "shader.hlsl",
        null,
        null,
        entry,
        target,
        0,
        0,
        &blob,
        &err_blob,
    );
    if (d3d.failed(hr)) {
        if (err_blob) |b| {
            const ptr: [*]const u8 = @ptrCast(b.bufferPointer());
            log.err("HLSL compile failed ({s}/{s}): {s}", .{ entry, target, ptr[0..b.bufferSize()] });
            _ = b.release();
        }
        return error.HLSLCompileFailed;
    }
    return blob.?;
}

fn compilePipeline(
    device: *d3d.ID3D11Device,
    source: []const u8,
    input_elements: []const d3d.D3D11_INPUT_ELEMENT_DESC,
) !Pipeline {
    // shader_model 5_0 is required for StructuredBuffer support.
    const vs_blob = try compileHlsl(source, "vs_main", "vs_5_0");
    defer _ = vs_blob.release();
    const ps_blob = try compileHlsl(source, "ps_main", "ps_5_0");
    defer _ = ps_blob.release();

    return Pipeline.init(.{
        .device = device,
        .vs_bytecode = blobBytes(vs_blob),
        .ps_bytecode = blobBytes(ps_blob),
        .input_elements = input_elements,
    });
}

/// No input layout for cell_text — we read CellText records via a
/// structured buffer bound at register t2 and indexed by SV_InstanceID.
/// Avoids the D3D11 CreateInputLayout validation pitfalls (which were
/// rejecting our 7-element layout regardless of format choices).
const cell_text_input_layout: []const d3d.D3D11_INPUT_ELEMENT_DESC = &.{};

/// Background-color HLSL — fullscreen triangle, reads bg_color from
/// the Uniforms cbuffer (offset 128 = packoffset c8).
const bg_color_hlsl =
    \\cbuffer Uniforms : register(b1) {
    \\    uint bg_color_packed : packoffset(c8.x);
    \\};
    \\struct VsOut { float4 pos : SV_POSITION; };
    \\VsOut vs_main(uint id : SV_VertexID) {
    \\    VsOut o;
    \\    float2 p;
    \\    p.x = (id == 2) ? 3.0 : -1.0;
    \\    p.y = (id == 0) ? -3.0 : 1.0;
    \\    o.pos = float4(p, 0.0, 1.0);
    \\    return o;
    \\}
    \\float4 ps_main(VsOut i) : SV_TARGET {
    \\    float r = ((bg_color_packed >>  0) & 0xFFu) / 255.0;
    \\    float g = ((bg_color_packed >>  8) & 0xFFu) / 255.0;
    \\    float b = ((bg_color_packed >> 16) & 0xFFu) / 255.0;
    \\    float a = ((bg_color_packed >> 24) & 0xFFu) / 255.0;
    \\    return float4(r, g, b, a);
    \\}
;

/// Cell-background HLSL — fullscreen pass that, per output pixel,
/// computes the grid cell it falls in and outputs that cell's
/// background color from the bg_cells StructuredBuffer at register t3.
/// This is what draws the cursor block, selection highlight, and any
/// program-set cell backgrounds. Mirrors `cell_bg.f.glsl`.
const cell_bg_hlsl =
    \\cbuffer Uniforms : register(b1) {
    \\    float2 cell_size        : packoffset(c4.z); // bytes 72..80
    \\    uint   grid_size_packed : packoffset(c5.x); // bytes 80..84
    \\    float4 grid_padding     : packoffset(c6);   // bytes 96..112
    \\    uint   bg_color_packed  : packoffset(c8.x); // bytes 128..132
    \\};
    \\
    \\StructuredBuffer<uint> bg_cells : register(t3);
    \\
    \\struct VsOut { float4 pos : SV_POSITION; };
    \\VsOut vs_main(uint id : SV_VertexID) {
    \\    VsOut o;
    \\    float2 p;
    \\    p.x = (id == 2) ? 3.0 : -1.0;
    \\    p.y = (id == 0) ? -3.0 : 1.0;
    \\    o.pos = float4(p, 0.0, 1.0);
    \\    return o;
    \\}
    \\
    \\float4 unpack4u8(uint v) {
    \\    return float4(
    \\        ((v >>  0) & 0xFFu) / 255.0,
    \\        ((v >>  8) & 0xFFu) / 255.0,
    \\        ((v >> 16) & 0xFFu) / 255.0,
    \\        ((v >> 24) & 0xFFu) / 255.0
    \\    );
    \\}
    \\
    \\float4 ps_main(VsOut input) : SV_TARGET {
    \\    uint2 grid_size = uint2(grid_size_packed & 0xFFFFu, grid_size_packed >> 16);
    \\    // SV_Position.xy is pixel center, origin upper-left in D3D11.
    \\    // grid_padding is (top, right, bottom, left); .wx = (left, top).
    \\    float2 pos = input.pos.xy - float2(grid_padding.w, grid_padding.x);
    \\    int2 grid_pos = int2(floor(pos / cell_size));
    \\    if (grid_pos.x < 0 || grid_pos.x >= int(grid_size.x) ||
    \\        grid_pos.y < 0 || grid_pos.y >= int(grid_size.y)) {
    \\        discard;
    \\    }
    \\    uint idx = uint(grid_pos.y) * grid_size.x + uint(grid_pos.x);
    \\    float4 c = unpack4u8(bg_cells[idx]);
    \\    // Premultiply (matches load_color in the GLSL backend).
    \\    c.rgb *= c.a;
    \\    return c;
    \\}
;

/// Cell-text HLSL.
///
/// Reads per-cell data from a StructuredBuffer<CellText> at register t2
/// indexed by SV_InstanceID. Avoids the input layout entirely (which
/// fought us over format-vs-shader-signature validation). VS produces
/// quad corners via SV_VertexID; PS samples the appropriate atlas
/// texture (grayscale t0, color t1) and outputs glyph alpha * color.
///
/// Simplifications vs the GLSL source:
///   - No bg_cells lookup (no per-cell background blend).
///   - No min-contrast adjustment.
///   - No cursor-glyph color override.
const cell_text_hlsl =
    \\cbuffer Uniforms : register(b1) {
    \\    float4x4 projection_matrix : packoffset(c0);
    \\    float2   screen_size       : packoffset(c4.x);
    \\    float2   cell_size         : packoffset(c4.z);
    \\};
    \\
    \\struct CellText {
    \\    uint2 glyph_pos;       //  0..  8
    \\    uint2 glyph_size;      //  8.. 16
    \\    uint  bearings_packed; // 16.. 20  (i16 x i16)
    \\    uint  grid_pos_packed; // 20.. 24  (u16 x u16)
    \\    uint  color_packed;    // 24.. 28  (u8 x 4)
    \\    uint  atlas_bools;     // 28.. 32  (atlas u8, bools u8, 2 pad)
    \\};
    \\
    \\StructuredBuffer<CellText> cells : register(t2);
    \\Texture2D<float4> atlas_grayscale : register(t0);
    \\Texture2D<float4> atlas_color     : register(t1);
    \\SamplerState samp                 : register(s0);
    \\
    \\struct PsIn {
    \\    float4 pos       : SV_POSITION;
    \\    float2 tex_coord : TEXCOORD0;
    \\    float4 color     : COLOR0;
    \\    nointerpolation uint atlas_id : TEXCOORD1;
    \\    nointerpolation uint is_cursor : TEXCOORD3;
    \\};
    \\
    \\PsIn vs_main(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    \\    CellText c = cells[iid];
    \\
    \\    float2 corner;
    \\    corner.x = (vid == 1 || vid == 3) ? 1.0 : 0.0;
    \\    corner.y = (vid == 2 || vid == 3) ? 1.0 : 0.0;
    \\
    \\    // Unpack grid_pos (2x u16) and bearings (2x i16).
    \\    uint2 grid_pos = uint2(c.grid_pos_packed & 0xFFFFu, c.grid_pos_packed >> 16);
    \\    int2 bearings = int2(
    \\        (int)((c.bearings_packed << 16) >> 16),
    \\        (int)(c.bearings_packed >> 16)
    \\    );
    \\
    \\    float2 cell_pos = cell_size * float2(grid_pos);
    \\    float2 size = float2(c.glyph_size);
    \\    float2 offset = float2(bearings);
    \\    offset.y = cell_size.y - offset.y;
    \\    cell_pos = cell_pos + size * corner + offset;
    \\
    \\    PsIn o;
    \\    o.pos = mul(projection_matrix, float4(cell_pos.x, cell_pos.y, 0.0, 1.0));
    \\    o.tex_coord = float2(c.glyph_pos) + float2(c.glyph_size) * corner;
    \\
    \\    float4 color = float4(
    \\        ((c.color_packed >>  0) & 0xFFu) / 255.0,
    \\        ((c.color_packed >>  8) & 0xFFu) / 255.0,
    \\        ((c.color_packed >> 16) & 0xFFu) / 255.0,
    \\        ((c.color_packed >> 24) & 0xFFu) / 255.0
    \\    );
    \\    o.color = color;
    \\    o.atlas_id = c.atlas_bools & 0xFFu;
    \\    o.is_cursor = ((c.atlas_bools >> 9) & 0x1u); // is_cursor_glyph bit
    \\    return o;
    \\}
    \\
    \\float4 ps_main(PsIn input) : SV_TARGET {
    \\    // Block cursor: the cursor "glyph" is a procedural sprite that
    \\    // isn't present in our grayscale atlas (sprite-face generation
    \\    // gap), so sampling it yields nothing. Draw a solid filled block
    \\    // in the cursor color instead — correct for the default block
    \\    // cursor. (Bar/underline cursor styles would need the real
    \\    // sprite; tracked as a follow-up.)
    \\    if (input.is_cursor != 0u) {
    \\        return input.color;
    \\    }
    \\    if (input.atlas_id == 0) {
    \\        uint w, h;
    \\        atlas_grayscale.GetDimensions(w, h);
    \\        float2 uv = input.tex_coord / float2(w, h);
    \\        float a = atlas_grayscale.Sample(samp, uv).r;
    \\        return float4(input.color.rgb * a, a);
    \\    } else {
    \\        uint w, h;
    \\        atlas_color.GetDimensions(w, h);
    \\        float2 uv = input.tex_coord / float2(w, h);
    \\        return atlas_color.Sample(samp, uv);
    \\    }
    \\}
;

// ---------------------------------------------------------------------------
// Shader-data layouts ported from `metal/shaders.zig`.
// ---------------------------------------------------------------------------

pub const Uniforms = extern struct {
    projection_matrix: math.Mat align(16),
    screen_size: [2]f32 align(8),
    cell_size: [2]f32 align(8),
    grid_size: [2]u16 align(4),
    grid_padding: [4]f32 align(16),
    padding_extend: PaddingExtend align(1),
    min_contrast: f32 align(4),
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),
    bg_color: [4]u8 align(4),

    bools: extern struct {
        cursor_wide: bool align(1),
        use_display_p3: bool align(1),
        use_linear_blending: bool align(1),
        use_linear_correction: bool align(1) = false,
    },

    pub const PaddingExtend = packed struct(u8) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u4 = 0,
    };
};

pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    } align(1) = .{},

    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };

    test {
        try std.testing.expectEqual(32, @sizeOf(CellText));
    }
};

pub const CellBg = [4]u8;

pub const Image = extern struct {
    grid_pos: [2]f32,
    cell_offset: [2]f32,
    source_rect: [4]f32,
    dest_size: [2]f32,
};

pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),

    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,

        pub const Position = enum(u4) {
            tl = 0,
            tc = 1,
            tr = 2,
            ml = 3,
            mc = 4,
            mr = 5,
            bl = 6,
            bc = 7,
            br = 8,
        };

        pub const Fit = enum(u2) {
            contain = 0,
            cover = 1,
            stretch = 2,
            none = 3,
        };
    };
};
