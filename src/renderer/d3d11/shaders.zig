//! D3D11 shader collection (skeleton).
//!
//! Satisfying the full `GenericRenderer` contract requires this module to
//! expose:
//!
//!   * `Shaders` — owns a `pipelines: PipelineCollection` (named pipelines
//!     `bg_color`, `cell_bg`, `cell_text`, `image`, `bg_image`), a
//!     `post_pipelines: []const Pipeline` slice, and a `defunct: bool`
//!     poison flag. Plus `init(alloc, device, post_shaders, pixel_format)`
//!     and `deinit(alloc)`.
//!   * `Uniforms` — extern struct with `projection_matrix`, `screen_size`,
//!     `cell_size`, `grid_padding`, `min_contrast`, `bg_color`, `palette`,
//!     `bools`. Layout MUST match the HLSL cbuffer; copy `metal/shaders.zig`'s
//!     `Uniforms` declaration verbatim — same layout, just compiled to HLSL
//!     instead of MSL.
//!   * Vertex attribute structs: `CellText`, `CellBg` (= `[4]u8`), `Image`,
//!     `BgImage` — copy `metal/shaders.zig` verbatim; D3D11 input layout
//!     descriptors will be derived from these.
//!
//! Until these are populated, `src/renderer.zig` keeps the `.d3d11` case
//! pointing at `GenericRenderer(OpenGL)` as a stand-in.
//!
//! Implementation order when picking this up next session:
//!   1. Port `metal/shaders.zig`'s data structs as-is into this file.
//!   2. Replace `PipelineCollection` field types with our local `Pipeline.zig`.
//!   3. In `Shaders.init`, compile each HLSL source via `D3DCompile` from
//!      `api.zig`, create vertex/pixel shaders + input layouts, store in the
//!      collection. Mirror `metal/shaders.zig::initLibrary` + `initPipeline`.
//!   4. HLSL source lives in `src/renderer/shaders/hlsl/*.hlsl` — port from
//!      the GLSL files in `src/renderer/shaders/glsl/*.glsl`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = @import("../../math.zig");
const d3d = @import("api.zig");
const Pipeline = @import("Pipeline.zig");

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
        _ = alloc;
        _ = device;
        _ = post_shaders;
        _ = pixel_format;
        return error.D3D11NotYetImplemented;
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

pub const PipelineCollection = struct {
    bg_color: Pipeline,
    cell_bg: Pipeline,
    cell_text: Pipeline,
    image: Pipeline,
    bg_image: Pipeline,
};

// Shader-data layouts ported from `metal/shaders.zig`. These are not
// backend-specific — they define the memory layout the HLSL shaders
// will consume via cbuffer + vertex input slots. Alignment annotations
// match Metal's MSL reference; HLSL will see the same byte layout.

pub const Uniforms = extern struct {
    /// World→NDC projection matrix (computed from screen + padding).
    projection_matrix: math.Mat align(16),

    /// Render target size in pixels.
    screen_size: [2]f32 align(8),

    /// Single cell size in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// Grid extent in (columns, rows).
    grid_size: [2]u16 align(4),

    /// Padding around the grid, in pixels: top, right, bottom, left.
    grid_padding: [4]f32 align(16),

    /// Which directions to extend cell colors into the padding band.
    padding_extend: PaddingExtend align(1),

    /// Minimum WCAG 2.0 contrast ratio for text.
    min_contrast: f32 align(4),

    /// Cursor cell position + color.
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),

    /// Surface-wide background color.
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

/// One instance per terminal cell with a glyph.
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

/// One instance per terminal cell, just the background color.
pub const CellBg = [4]u8;

/// One instance per inline image cell.
pub const Image = extern struct {
    grid_pos: [2]f32,
    cell_offset: [2]f32,
    source_rect: [4]f32,
    dest_size: [2]f32,
};

/// One instance for the background image (configured via `background-image`).
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
