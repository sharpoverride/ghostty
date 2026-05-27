//! D3D11 buffer wrapper.
//!
//! Backs vertex / constant / structured buffer storage. Created DYNAMIC
//! with CPU write access by default so we can re-upload data each frame
//! via Map(WRITE_DISCARD) / Unmap. Grows in place by recreating with a
//! larger ByteWidth when `sync` is called with more elements than the
//! current capacity.
const std = @import("std");
const d3d = @import("api.zig");

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    device: *d3d.ID3D11Device,
    context: *d3d.ID3D11DeviceContext,
    usage: d3d.D3D11_USAGE = .DYNAMIC,
    bind_flags: d3d.D3D11_BIND_FLAG,
    cpu_access: d3d.D3D11_CPU_ACCESS_FLAG = .{ .write = true },
    /// Sets MiscFlags. Use BUFFER_STRUCTURED for structured-buffer
    /// shader resources.
    misc_flags: u32 = 0,
    /// Structure stride in bytes. Required when misc_flags includes
    /// BUFFER_STRUCTURED.
    structure_byte_stride: u32 = 0,
    /// Build a Shader Resource View for the buffer after creation.
    /// Used for structured-buffer access in shaders.
    create_srv: bool = false,
};

/// Handle exposed to the engine via Buffer's `.buffer` field. Holds
/// both the underlying ID3D11Buffer pointer and an optional Shader
/// Resource View for structured-buffer reads. Generic.zig passes this
/// through to `RenderPass.step` without inspecting its fields, so we
/// can plumb the SRV alongside the handle without forking the
/// cross-backend dispatch.
pub const BufferRef = struct {
    handle: *d3d.ID3D11Buffer,
    srv: ?*d3d.ID3D11ShaderResourceView = null,
};

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        opts: Options,
        buffer: BufferRef,
        /// Capacity in elements (not bytes).
        len: usize,

        pub fn init(opts: Options, len: usize) !Self {
            const buf = try createBuffer(opts, len, null);
            errdefer _ = buf.release();
            const srv = if (opts.create_srv) try createBufferSrv(opts, buf, len) else null;
            return .{ .opts = opts, .buffer = .{ .handle = buf, .srv = srv }, .len = len };
        }

        pub fn initFill(opts: Options, data: []const T) !Self {
            const buf = try createBuffer(opts, data.len, @ptrCast(data.ptr));
            errdefer _ = buf.release();
            const srv = if (opts.create_srv) try createBufferSrv(opts, buf, data.len) else null;
            return .{ .opts = opts, .buffer = .{ .handle = buf, .srv = srv }, .len = data.len };
        }

        pub fn deinit(self: *const Self) void {
            if (self.buffer.srv) |s| _ = s.release();
            _ = self.buffer.handle.release();
        }

        /// Replace the entire buffer's contents. Grows in place if
        /// `data.len` exceeds current capacity.
        pub fn sync(self: *Self, data: []const T) !void {
            if (data.len == 0) return;
            try self.ensureCapacity(data.len);
            try mapAndCopy(self.opts.context, self.buffer.handle, data);
        }

        /// Concatenate the elements of every ArrayListUnmanaged into the
        /// buffer in list order; return total element count written.
        pub fn syncFromArrayLists(
            self: *Self,
            lists: []const std.ArrayListUnmanaged(T),
        ) !usize {
            var total: usize = 0;
            for (lists) |list| total += list.items.len;
            if (total == 0) return 0;
            try self.ensureCapacity(total);

            var mapped: d3d.D3D11_MAPPED_SUBRESOURCE = .{
                .pData = null,
                .RowPitch = 0,
                .DepthPitch = 0,
            };
            const ctx = self.opts.context;
            const hr = ctx.vtable.Map(
                ctx,
                @ptrCast(self.buffer.handle),
                0,
                .WRITE_DISCARD,
                0,
                &mapped,
            );
            if (d3d.failed(hr)) {
                log.err("Buffer.syncFromArrayLists Map failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
                return error.MapFailed;
            }
            defer ctx.vtable.Unmap(ctx, @ptrCast(self.buffer.handle), 0);

            const dst: [*]T = @ptrCast(@alignCast(mapped.pData.?));
            var cursor: usize = 0;
            for (lists) |list| {
                if (list.items.len == 0) continue;
                @memcpy(dst[cursor .. cursor + list.items.len], list.items);
                cursor += list.items.len;
            }
            return total;
        }

        fn ensureCapacity(self: *Self, needed: usize) !void {
            if (self.len >= needed) return;
            const new_len = @max(needed, self.len * 2);
            const new_buf = try createBuffer(self.opts, new_len, null);
            errdefer _ = new_buf.release();
            const new_srv = if (self.opts.create_srv)
                try createBufferSrv(self.opts, new_buf, new_len)
            else
                null;
            if (self.buffer.srv) |s| _ = s.release();
            _ = self.buffer.handle.release();
            self.buffer = .{ .handle = new_buf, .srv = new_srv };
            self.len = new_len;
        }

        fn createBufferSrv(
            opts: Options,
            buf: *d3d.ID3D11Buffer,
            len_elements: usize,
        ) !*d3d.ID3D11ShaderResourceView {
            const n = @max(1, len_elements);
            const desc: d3d.D3D11_SHADER_RESOURCE_VIEW_DESC = .{
                .Format = .UNKNOWN,
                .ViewDimension = d3d.D3D11_SRV_DIMENSION_BUFFER,
                .Buffer = .{ .FirstElement = 0, .NumElements = @intCast(n) },
            };
            var srv: ?*d3d.ID3D11ShaderResourceView = null;
            const hr = opts.device.vtable.CreateShaderResourceView(
                opts.device,
                @ptrCast(buf),
                @ptrCast(&desc),
                &srv,
            );
            if (d3d.failed(hr)) {
                log.err("CreateShaderResourceView (buffer) failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
                return error.CreateBufferSrvFailed;
            }
            return srv.?;
        }

        fn createBuffer(
            opts: Options,
            len_elements: usize,
            initial_data: ?*const anyopaque,
        ) !*d3d.ID3D11Buffer {
            // D3D11 requires ByteWidth > 0; substitute 1 element if the
            // caller passed zero (renderer occasionally starts buffers at
            // size 1 and grows from there).
            const n = @max(1, len_elements);
            var byte_width: u32 = @intCast(n * @sizeOf(T));
            // Constant buffers require ByteWidth to be a multiple of 16
            // (D3D11 spec). Round up so the engine's `len = 1` start
            // works for cbuffers whose struct sizes aren't aligned.
            if (opts.bind_flags.constant_buffer) {
                byte_width = (byte_width + 15) & ~@as(u32, 15);
            }
            const desc: d3d.D3D11_BUFFER_DESC = .{
                .ByteWidth = byte_width,
                .Usage = opts.usage,
                .BindFlags = opts.bind_flags,
                .CPUAccessFlags = opts.cpu_access,
                .MiscFlags = opts.misc_flags,
                .StructureByteStride = opts.structure_byte_stride,
            };
            const init_data: ?d3d.D3D11_SUBRESOURCE_DATA = if (initial_data) |p|
                .{ .pSysMem = p, .SysMemPitch = 0, .SysMemSlicePitch = 0 }
            else
                null;
            const init_ptr: ?*const d3d.D3D11_SUBRESOURCE_DATA =
                if (init_data) |*v| v else null;

            var buf: ?*d3d.ID3D11Buffer = null;
            const hr = opts.device.vtable.CreateBuffer(
                opts.device,
                &desc,
                init_ptr,
                &buf,
            );
            if (d3d.failed(hr)) {
                log.err("CreateBuffer failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
                return error.CreateBufferFailed;
            }
            return buf.?;
        }

        fn mapAndCopy(
            ctx: *d3d.ID3D11DeviceContext,
            buf: *d3d.ID3D11Buffer,
            data: []const T,
        ) !void {
            var mapped: d3d.D3D11_MAPPED_SUBRESOURCE = .{
                .pData = null,
                .RowPitch = 0,
                .DepthPitch = 0,
            };
            const hr = ctx.vtable.Map(
                ctx,
                @ptrCast(buf),
                0,
                .WRITE_DISCARD,
                0,
                &mapped,
            );
            if (d3d.failed(hr)) {
                log.err("Buffer.sync Map failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
                return error.MapFailed;
            }
            defer ctx.vtable.Unmap(ctx, @ptrCast(buf), 0);

            const dst: [*]T = @ptrCast(@alignCast(mapped.pData.?));
            @memcpy(dst[0..data.len], data);
        }
    };
}
