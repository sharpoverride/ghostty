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

// Placeholder data structs. Real layouts will be ported from metal/shaders.zig
// when the d3d11 backend is switched in. Each must be `extern struct` with
// alignment matching the HLSL cbuffer / VS input layout exactly.
pub const Uniforms = extern struct {};
pub const CellText = extern struct {};
pub const CellBg = [4]u8;
pub const Image = extern struct {};
pub const BgImage = extern struct {};
