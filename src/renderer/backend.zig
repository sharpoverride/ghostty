const std = @import("std");
const WasmTarget = @import("../os/wasm/target.zig").Target;

/// Possible implementations, used for build options.
pub const Backend = enum {
    opengl,
    metal,
    webgl,
    d3d11,

    pub fn default(
        target: std.Target,
        wasm_target: WasmTarget,
    ) Backend {
        if (target.cpu.arch == .wasm32) {
            return switch (wasm_target) {
                .browser => .webgl,
            };
        }

        if (target.os.tag.isDarwin()) return .metal;
        // Windows: D3D11 is the default renderer (text, input, cursor,
        // per-cell backgrounds all working). Opt into the OpenGL/WGL
        // path with `-Drenderer=opengl` if needed.
        if (target.os.tag == .windows) return .d3d11;
        return .opengl;
    }
};
