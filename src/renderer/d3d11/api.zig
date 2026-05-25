//! D3D11 + DXGI API surface used by the Ghostty D3D11 renderer backend.
//!
//! STATUS: skeleton. COM interfaces are declared as `opaque {}` so the
//! sub-modules in this directory can name them and hold pointers, but no
//! actual method calls go through the vtables yet. When we wire real rendering
//! we'll expand each opaque into an `extern struct { vtable: *const VTable }`
//! with the IUnknown trio (QueryInterface/AddRef/Release) plus whichever
//! methods the call sites actually need — there's no value paying the cost
//! of a complete IDL transcription up-front.

const std = @import("std");
const windows = std.os.windows;

pub const HRESULT = windows.HRESULT;
pub const HWND = windows.HWND;
pub const HINSTANCE = windows.HINSTANCE;
pub const HANDLE = windows.HANDLE;
pub const UINT = windows.UINT;
pub const BOOL = windows.BOOL;
pub const GUID = windows.GUID;

// ---------------------------------------------------------------------------
// COM interfaces (opaque placeholders; vtables come when call sites land).
// ---------------------------------------------------------------------------

pub const ID3D11Device = opaque {};
pub const ID3D11DeviceContext = opaque {};
pub const ID3D11Buffer = opaque {};
pub const ID3D11Texture2D = opaque {};
pub const ID3D11RenderTargetView = opaque {};
pub const ID3D11ShaderResourceView = opaque {};
pub const ID3D11SamplerState = opaque {};
pub const ID3D11VertexShader = opaque {};
pub const ID3D11PixelShader = opaque {};
pub const ID3D11InputLayout = opaque {};
pub const ID3D11BlendState = opaque {};
pub const ID3D11RasterizerState = opaque {};
pub const ID3D11DepthStencilState = opaque {};
pub const ID3DBlob = opaque {};

pub const IDXGIFactory2 = opaque {};
pub const IDXGISwapChain1 = opaque {};
pub const IDXGIAdapter = opaque {};

// ---------------------------------------------------------------------------
// Descriptors and enums.
// ---------------------------------------------------------------------------

/// https://learn.microsoft.com/en-us/windows/win32/api/dxgiformat/ne-dxgiformat-dxgi_format
pub const DXGI_FORMAT = enum(UINT) {
    UNKNOWN = 0,
    R8G8B8A8_UNORM = 28,
    B8G8R8A8_UNORM = 87,
    R8_UNORM = 61,
    R32G32_FLOAT = 16,
    R32G32B32A32_FLOAT = 2,
    R32_UINT = 42,
    _,
};

pub const D3D_FEATURE_LEVEL = enum(UINT) {
    @"11_0" = 0xb000,
    @"11_1" = 0xb100,
    _,
};

pub const D3D_DRIVER_TYPE = enum(UINT) {
    UNKNOWN = 0,
    HARDWARE = 1,
    REFERENCE = 2,
    NULL = 3,
    SOFTWARE = 4,
    WARP = 5,
};

pub const D3D11_USAGE = enum(UINT) {
    DEFAULT = 0,
    IMMUTABLE = 1,
    DYNAMIC = 2,
    STAGING = 3,
};

pub const D3D11_CPU_ACCESS_FLAG = packed struct(UINT) {
    write: bool = false,
    read: bool = false,
    _pad: u30 = 0,
};

pub const D3D11_BIND_FLAG = packed struct(UINT) {
    vertex_buffer: bool = false,
    index_buffer: bool = false,
    constant_buffer: bool = false,
    shader_resource: bool = false,
    stream_output: bool = false,
    render_target: bool = false,
    depth_stencil: bool = false,
    unordered_access: bool = false,
    decoder: bool = false,
    video_encoder: bool = false,
    _pad: u22 = 0,
};

pub const D3D11_BUFFER_DESC = extern struct {
    ByteWidth: UINT,
    Usage: D3D11_USAGE,
    BindFlags: D3D11_BIND_FLAG,
    CPUAccessFlags: D3D11_CPU_ACCESS_FLAG,
    MiscFlags: UINT,
    StructureByteStride: UINT,
};

pub const D3D11_TEXTURE2D_DESC = extern struct {
    Width: UINT,
    Height: UINT,
    MipLevels: UINT,
    ArraySize: UINT,
    Format: DXGI_FORMAT,
    SampleDesc: DXGI_SAMPLE_DESC,
    Usage: D3D11_USAGE,
    BindFlags: D3D11_BIND_FLAG,
    CPUAccessFlags: D3D11_CPU_ACCESS_FLAG,
    MiscFlags: UINT,
};

pub const DXGI_SAMPLE_DESC = extern struct {
    Count: UINT,
    Quality: UINT,
};

pub const D3D11_FILTER = enum(UINT) {
    MIN_MAG_MIP_POINT = 0,
    MIN_MAG_LINEAR_MIP_POINT = 0x14,
    MIN_MAG_MIP_LINEAR = 0x15,
    _,
};

pub const D3D11_TEXTURE_ADDRESS_MODE = enum(UINT) {
    WRAP = 1,
    MIRROR = 2,
    CLAMP = 3,
    BORDER = 4,
    MIRROR_ONCE = 5,
};

// ---------------------------------------------------------------------------
// Global entry points. These are real exports of d3d11.dll / dxgi.dll /
// d3dcompiler_47.dll — they exist whether or not the rest of the renderer
// is implemented, which means linking against them in build.zig now is fine.
// ---------------------------------------------------------------------------

pub extern "d3d11" fn D3D11CreateDevice(
    pAdapter: ?*IDXGIAdapter,
    DriverType: D3D_DRIVER_TYPE,
    Software: ?HINSTANCE,
    Flags: UINT,
    pFeatureLevels: ?[*]const D3D_FEATURE_LEVEL,
    FeatureLevels: UINT,
    SDKVersion: UINT,
    ppDevice: ?*?*ID3D11Device,
    pFeatureLevel: ?*D3D_FEATURE_LEVEL,
    ppImmediateContext: ?*?*ID3D11DeviceContext,
) callconv(.winapi) HRESULT;

pub extern "dxgi" fn CreateDXGIFactory2(
    Flags: UINT,
    riid: *const GUID,
    ppFactory: *?*IDXGIFactory2,
) callconv(.winapi) HRESULT;

pub extern "d3dcompiler_47" fn D3DCompile(
    pSrcData: [*]const u8,
    SrcDataSize: usize,
    pSourceName: ?[*:0]const u8,
    pDefines: ?*anyopaque,
    pInclude: ?*anyopaque,
    pEntrypoint: [*:0]const u8,
    pTarget: [*:0]const u8,
    Flags1: UINT,
    Flags2: UINT,
    ppCode: *?*ID3DBlob,
    ppErrorMsgs: ?*?*ID3DBlob,
) callconv(.winapi) HRESULT;

pub const D3D11_SDK_VERSION: UINT = 7;

pub const IID_IDXGIFactory2: GUID = .{
    .Data1 = 0x50c83a1c,
    .Data2 = 0xe072,
    .Data3 = 0x4c48,
    .Data4 = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 },
};
