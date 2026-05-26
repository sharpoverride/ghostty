//! Minimal D3D11 + DXGI bootstrap for the win32 apprt. Lives parallel to
//! `gl.zig` and is intended to grow into the real D3D11 backend. For now
//! it owns just enough state to create a device + swap chain on a child
//! HWND and clear-to-color so we can validate the COM bring-up visually
//! before tackling shaders + the full GraphicsAPI surface.

const std = @import("std");
const windows = std.os.windows;
const d3d = @import("../../renderer/d3d11/api.zig");

const HWND = windows.HWND;
const HRESULT = windows.HRESULT;
const UINT = windows.UINT;
const TRUE = windows.TRUE;
const FALSE = windows.FALSE;

const log = std.log.scoped(.win32_d3d11);

/// Hardware feature levels we ask D3D11CreateDevice for, best-first.
const feature_levels = [_]d3d.D3D_FEATURE_LEVEL{ .@"11_1", .@"11_0" };

pub const Context = struct {
    hwnd: HWND,
    device: *d3d.ID3D11Device,
    context: *d3d.ID3D11DeviceContext,
    factory: *d3d.IDXGIFactory2,
    swap: *d3d.IDXGISwapChain1,
    rtv: *d3d.ID3D11RenderTargetView,
    /// Cached back-buffer size — recreated when the HWND resizes.
    width: UINT,
    height: UINT,

    pub fn init(hwnd: HWND) !Context {
        // 1. Create the D3D11 device + immediate context. Feature level
        //    11.0 is everywhere; 11.1 is preferred when available.
        var device: ?*d3d.ID3D11Device = null;
        var ctx: ?*d3d.ID3D11DeviceContext = null;
        var fl: d3d.D3D_FEATURE_LEVEL = .@"11_0";
        // Debug layer in Debug builds; production runs without it (the
        // SDK debug DLL is optional and not present on plain systems).
        const create_flags: d3d.D3D11_CREATE_DEVICE_FLAG = .{
            .debug = @import("builtin").mode == .Debug,
        };
        var hr = d3d.D3D11CreateDevice(
            null,
            .HARDWARE,
            null,
            @bitCast(create_flags),
            &feature_levels,
            feature_levels.len,
            d3d.D3D11_SDK_VERSION,
            &device,
            &fl,
            &ctx,
        );
        if (d3d.failed(hr) and create_flags.debug) {
            // Debug layer not installed — retry without it.
            log.info("D3D11CreateDevice with debug layer failed (0x{X:0>8}), retrying without", .{@as(u32, @bitCast(hr))});
            const no_debug: d3d.D3D11_CREATE_DEVICE_FLAG = .{};
            hr = d3d.D3D11CreateDevice(
                null,
                .HARDWARE,
                null,
                @bitCast(no_debug),
                &feature_levels,
                feature_levels.len,
                d3d.D3D11_SDK_VERSION,
                &device,
                &fl,
                &ctx,
            );
        }
        if (d3d.failed(hr)) {
            log.err("D3D11CreateDevice failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
            return error.D3D11CreateDeviceFailed;
        }
        errdefer _ = device.?.release();
        errdefer _ = ctx.?.release();

        // 2. Create the DXGI factory.
        var factory: ?*d3d.IDXGIFactory2 = null;
        hr = d3d.CreateDXGIFactory2(0, &d3d.IID_IDXGIFactory2, &factory);
        if (d3d.failed(hr)) {
            log.err("CreateDXGIFactory2 failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
            return error.CreateDXGIFactory2Failed;
        }
        errdefer _ = factory.?.release();

        // 3. Read client area for initial swap chain size.
        var rect: windows.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = GetClientRect(hwnd, &rect);
        const w: UINT = @intCast(@max(1, rect.right - rect.left));
        const h: UINT = @intCast(@max(1, rect.bottom - rect.top));

        // 4. Create the swap chain — flip-discard, double-buffered, BGRA8
        //    matches Windows' compositor surface format on most paths and
        //    avoids a conversion blit at present time.
        const desc: d3d.DXGI_SWAP_CHAIN_DESC1 = .{
            .Width = w,
            .Height = h,
            .Format = .B8G8R8A8_UNORM,
            .Stereo = FALSE,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = .{ .render_target_output = true },
            .BufferCount = 2,
            .Scaling = .STRETCH,
            .SwapEffect = .FLIP_DISCARD,
            .AlphaMode = .UNSPECIFIED,
            .Flags = 0,
        };
        var swap: ?*d3d.IDXGISwapChain1 = null;
        hr = factory.?.vtable.CreateSwapChainForHwnd(
            factory.?,
            @ptrCast(device.?),
            hwnd,
            &desc,
            null,
            null,
            &swap,
        );
        if (d3d.failed(hr)) {
            log.err("CreateSwapChainForHwnd failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
            return error.CreateSwapChainForHwndFailed;
        }
        errdefer _ = swap.?.release();

        // 5. Pull the back buffer + build a render target view we can
        //    clear/draw to.
        const rtv = try createBackBufferRtv(device.?, swap.?);

        log.info(
            "D3D11 context created hwnd=0x{X} feature_level=0x{X} {d}x{d}",
            .{ @intFromPtr(hwnd), @intFromEnum(fl), w, h },
        );

        return .{
            .hwnd = hwnd,
            .device = device.?,
            .context = ctx.?,
            .factory = factory.?,
            .swap = swap.?,
            .rtv = rtv,
            .width = w,
            .height = h,
        };
    }

    pub fn deinit(self: *Context) void {
        _ = self.rtv.release();
        _ = self.swap.release();
        _ = self.factory.release();
        _ = self.context.release();
        _ = self.device.release();
        self.* = undefined;
    }

    /// Clear the back buffer to the given RGBA color and present.
    pub fn clearAndPresent(self: *const Context, color: [4]f32) void {
        const rtvs = [_]*d3d.ID3D11RenderTargetView{self.rtv};
        self.context.vtable.OMSetRenderTargets(self.context, 1, &rtvs, null);

        const viewport: d3d.D3D11_VIEWPORT = .{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = @floatFromInt(self.width),
            .Height = @floatFromInt(self.height),
            .MinDepth = 0,
            .MaxDepth = 1,
        };
        const vps = [_]d3d.D3D11_VIEWPORT{viewport};
        self.context.vtable.RSSetViewports(self.context, 1, &vps);

        self.context.vtable.ClearRenderTargetView(self.context, self.rtv, &color);

        // SyncInterval=0 — no vsync, immediate present. Matches our WGL
        // wglSwapIntervalEXT(0) choice.
        _ = self.swap.vtable.Present(self.swap, 0, 0);
    }

    /// Resize the swap chain to a new client-area size. Caller invokes on
    /// WM_SIZE; engine integration will route this through the renderer
    /// thread eventually.
    pub fn resize(self: *Context, new_w: UINT, new_h: UINT) !void {
        if (new_w == 0 or new_h == 0) return;
        if (new_w == self.width and new_h == self.height) return;

        // Release the RTV before resizing; ResizeBuffers requires that
        // no views reference the old back buffer.
        _ = self.rtv.release();

        const hr = self.swap.vtable.ResizeBuffers(self.swap, 0, new_w, new_h, .UNKNOWN, 0);
        if (d3d.failed(hr)) {
            log.err("ResizeBuffers failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
            return error.ResizeBuffersFailed;
        }

        // Rebuild the RTV against the new back buffer.
        self.rtv = try createBackBufferRtv(self.device, self.swap);
        self.width = new_w;
        self.height = new_h;
    }
};

fn createBackBufferRtv(
    device: *d3d.ID3D11Device,
    swap: *d3d.IDXGISwapChain1,
) !*d3d.ID3D11RenderTargetView {
    var backbuffer: ?*anyopaque = null;
    var hr = swap.vtable.GetBuffer(swap, 0, &d3d.IID_ID3D11Texture2D, &backbuffer);
    if (d3d.failed(hr)) {
        log.err("swap.GetBuffer failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.GetBufferFailed;
    }
    const resource: *d3d.ID3D11Resource = @ptrCast(backbuffer.?);
    defer {
        // GetBuffer AddRef'd; we transfer ownership to the RTV which has
        // its own ref. Release our local ref through the IUnknown vtable
        // — we reuse the Device's vtable layout assumption that the
        // first three slots are QI/AddRef/Release on every COM object.
        const iface: *IUnknown = @ptrCast(@alignCast(backbuffer.?));
        _ = iface.vtable.Release(iface);
    }

    var rtv: ?*d3d.ID3D11RenderTargetView = null;
    hr = device.vtable.CreateRenderTargetView(device, resource, null, &rtv);
    if (d3d.failed(hr)) {
        log.err("CreateRenderTargetView failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.CreateRenderTargetViewFailed;
    }
    return rtv.?;
}

/// Minimal IUnknown wrapper just for Release on the back buffer — every
/// COM interface starts with the same three IUnknown slots.
const IUnknown = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *IUnknown) callconv(.winapi) u32,
    };
};

extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *windows.RECT) callconv(.winapi) windows.BOOL;
