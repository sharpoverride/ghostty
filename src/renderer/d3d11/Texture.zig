//! D3D11 texture wrapper.
//!
//! Backs glyph atlases and image-cell content. Created with
//! SHADER_RESOURCE bind by default so the pixel shader can sample it.
//! Updated via UpdateSubresource (the texture is DEFAULT usage; we
//! avoid the Map(WRITE_DISCARD) path because atlas writes are sparse
//! regional updates, not whole-texture replacements).
const Self = @This();

const std = @import("std");
const d3d = @import("api.zig");

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    device: *d3d.ID3D11Device,
    context: *d3d.ID3D11DeviceContext,
    pixel_format: d3d.DXGI_FORMAT,
    usage: d3d.D3D11_USAGE = .DEFAULT,
    bind_flags: d3d.D3D11_BIND_FLAG = .{ .shader_resource = true },
    cpu_access: d3d.D3D11_CPU_ACCESS_FLAG = .{},
};

pub const Error = error{
    CreateTexture2DFailed,
    CreateShaderResourceViewFailed,
    UpdateSubresourceFailed,
};

opts: Options,
texture: *d3d.ID3D11Texture2D,
srv: *d3d.ID3D11ShaderResourceView,
width: usize,
height: usize,
bpp: usize,

pub fn init(opts: Options, width: usize, height: usize, data: ?[]const u8) Error!Self {
    const bpp = bytesPerPixel(opts.pixel_format);
    const w = @max(1, width);
    const h = @max(1, height);

    const desc: d3d.D3D11_TEXTURE2D_DESC = .{
        .Width = @intCast(w),
        .Height = @intCast(h),
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = opts.pixel_format,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = opts.usage,
        .BindFlags = opts.bind_flags,
        .CPUAccessFlags = opts.cpu_access,
        .MiscFlags = 0,
    };

    var initial: ?d3d.D3D11_SUBRESOURCE_DATA = null;
    var initial_arr: [1]d3d.D3D11_SUBRESOURCE_DATA = undefined;
    if (data) |bytes| {
        initial_arr[0] = .{
            .pSysMem = bytes.ptr,
            .SysMemPitch = @intCast(w * bpp),
            .SysMemSlicePitch = 0,
        };
        initial = initial_arr[0];
    }
    const initial_ptr: ?[*]const d3d.D3D11_SUBRESOURCE_DATA =
        if (initial != null) &initial_arr else null;

    var tex: ?*d3d.ID3D11Texture2D = null;
    var hr = opts.device.vtable.CreateTexture2D(opts.device, &desc, initial_ptr, &tex);
    if (d3d.failed(hr)) {
        log.err("CreateTexture2D failed: 0x{X:0>8} {d}x{d}", .{ @as(u32, @bitCast(hr)), w, h });
        return error.CreateTexture2DFailed;
    }
    errdefer _ = tex.?.release();

    var srv: ?*d3d.ID3D11ShaderResourceView = null;
    hr = opts.device.vtable.CreateShaderResourceView(
        opts.device,
        @ptrCast(tex.?),
        null,
        &srv,
    );
    if (d3d.failed(hr)) {
        log.err("CreateShaderResourceView failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.CreateShaderResourceViewFailed;
    }

    return .{
        .opts = opts,
        .texture = tex.?,
        .srv = srv.?,
        .width = w,
        .height = h,
        .bpp = bpp,
    };
}

pub fn deinit(self: Self) void {
    _ = self.srv.release();
    _ = self.texture.release();
}

/// Upload `data` into the rectangular region (x, y, w, h). `data` must
/// be `w * h * bpp` bytes, tightly packed at `w * bpp` row pitch.
pub fn replaceRegion(
    self: *const Self,
    x: usize,
    y: usize,
    w: usize,
    h: usize,
    data: []const u8,
) !void {
    const box: d3d.D3D11_BOX = .{
        .left = @intCast(x),
        .top = @intCast(y),
        .front = 0,
        .right = @intCast(x + w),
        .bottom = @intCast(y + h),
        .back = 1,
    };
    const ctx = self.opts.context;
    ctx.vtable.UpdateSubresource(
        ctx,
        @ptrCast(self.texture),
        0,
        &box,
        data.ptr,
        @intCast(w * self.bpp),
        0,
    );
}

fn bytesPerPixel(format: d3d.DXGI_FORMAT) usize {
    return switch (format) {
        .R8_UNORM => 1,
        .R8G8B8A8_UNORM, .B8G8R8A8_UNORM => 4,
        .R32G32_FLOAT => 8,
        .R32G32B32A32_FLOAT => 16,
        .R32_UINT => 4,
        else => 4,
    };
}
