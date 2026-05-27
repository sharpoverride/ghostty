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
// COM interfaces. Each is an extern struct with a leading vtable pointer.
// The vtables match the C ABI laid out by d3d11.h / dxgi1_2.h — only the
// methods our renderer actually calls are typed; everything before them
// is `*const anyopaque` padding so offsets stay correct.
//
// To call: `obj.vt().Method.?(obj, args...)` for each call site, or use
// the convenience wrappers defined per-interface.
// ---------------------------------------------------------------------------

// Each of the COM interfaces below is an extern struct with a leading
// vtable pointer. Only IUnknown::Release is typed — that's all our code
// touches; the real vtables have many more methods at later slots which
// we leave implicit.

pub const ID3D11Buffer = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *ID3D11Buffer) callconv(.winapi) u32,
    };
    pub fn release(self: *ID3D11Buffer) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11Texture2D = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *ID3D11Texture2D) callconv(.winapi) u32,
    };
    pub fn release(self: *ID3D11Texture2D) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11ShaderResourceView = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *ID3D11ShaderResourceView) callconv(.winapi) u32,
    };
    pub fn release(self: *ID3D11ShaderResourceView) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11SamplerState = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *ID3D11SamplerState) callconv(.winapi) u32,
    };
    pub fn release(self: *ID3D11SamplerState) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11VertexShader = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *ID3D11VertexShader) callconv(.winapi) u32,
    };
    pub fn release(self: *ID3D11VertexShader) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11PixelShader = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *ID3D11PixelShader) callconv(.winapi) u32,
    };
    pub fn release(self: *ID3D11PixelShader) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11InputLayout = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *ID3D11InputLayout) callconv(.winapi) u32,
    };
    pub fn release(self: *ID3D11InputLayout) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11BlendState = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *ID3D11BlendState) callconv(.winapi) u32,
    };
    pub fn release(self: *ID3D11BlendState) u32 {
        return self.vtable.Release(self);
    }
};
pub const ID3D11RasterizerState = opaque {};
pub const ID3D11DepthStencilState = opaque {};
pub const IDXGIAdapter = opaque {};

pub const ID3D11Resource = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *ID3D11Resource) callconv(.winapi) u32,
    };
    pub fn release(self: *ID3D11Resource) u32 {
        return self.vtable.Release(self);
    }
};

/// IDXGIFactory2: only CreateSwapChainForHwnd is typed; everything before
/// it is opaque padding. Method ordering follows dxgi1_2.h.
pub const IDXGIFactory2 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *IDXGIFactory2) callconv(.winapi) u32,
        // IDXGIObject (4)
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        // IDXGIFactory (5)
        EnumAdapters: *const anyopaque,
        MakeWindowAssociation: *const anyopaque,
        GetWindowAssociation: *const anyopaque,
        CreateSwapChain: *const anyopaque,
        CreateSoftwareAdapter: *const anyopaque,
        // IDXGIFactory1 (2)
        EnumAdapters1: *const anyopaque,
        IsCurrent: *const anyopaque,
        // IDXGIFactory2 (3 we need)
        IsWindowedStereoEnabled: *const anyopaque,
        CreateSwapChainForHwnd: *const fn (
            self: *IDXGIFactory2,
            pDevice: *anyopaque,
            hWnd: HWND,
            pDesc: *const DXGI_SWAP_CHAIN_DESC1,
            pFullscreenDesc: ?*const anyopaque,
            pRestrictToOutput: ?*anyopaque,
            ppSwapChain: *?*IDXGISwapChain1,
        ) callconv(.winapi) HRESULT,
        CreateSwapChainForCoreWindow: *const anyopaque,
        // ... more methods follow that we don't need
    };

    pub fn release(self: *IDXGIFactory2) u32 {
        return self.vtable.Release(self);
    }
};

pub const IDXGISwapChain1 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *IDXGISwapChain1) callconv(.winapi) u32,
        // IDXGIObject
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        // IDXGIDeviceSubObject
        GetDevice: *const anyopaque,
        // IDXGISwapChain
        Present: *const fn (
            self: *IDXGISwapChain1,
            SyncInterval: UINT,
            Flags: UINT,
        ) callconv(.winapi) HRESULT,
        GetBuffer: *const fn (
            self: *IDXGISwapChain1,
            Buffer: UINT,
            riid: *const GUID,
            ppSurface: *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        SetFullscreenState: *const anyopaque,
        GetFullscreenState: *const anyopaque,
        GetDesc: *const anyopaque,
        ResizeBuffers: *const fn (
            self: *IDXGISwapChain1,
            BufferCount: UINT,
            Width: UINT,
            Height: UINT,
            NewFormat: DXGI_FORMAT,
            SwapChainFlags: UINT,
        ) callconv(.winapi) HRESULT,
        // ... more methods we don't need
    };

    pub fn release(self: *IDXGISwapChain1) u32 {
        return self.vtable.Release(self);
    }
};

pub const D3D11_SUBRESOURCE_DATA = extern struct {
    pSysMem: *const anyopaque,
    SysMemPitch: UINT = 0,
    SysMemSlicePitch: UINT = 0,
};

pub const D3D11_INPUT_CLASSIFICATION = enum(UINT) {
    PER_VERTEX_DATA = 0,
    PER_INSTANCE_DATA = 1,
};

pub const D3D11_INPUT_ELEMENT_DESC = extern struct {
    SemanticName: [*:0]const u8,
    SemanticIndex: UINT,
    Format: DXGI_FORMAT,
    InputSlot: UINT,
    AlignedByteOffset: UINT,
    InputSlotClass: D3D11_INPUT_CLASSIFICATION,
    InstanceDataStepRate: UINT,
};

pub const ID3D11Device = extern struct {
    vtable: *const VTable,

    /// Method ordering follows d3d11.h's vtable layout exactly. Each entry
    /// must stay at its real index; unused slots stay `*const anyopaque`.
    pub const VTable = extern struct {
        // IUnknown
        QueryInterface: *const fn (
            self: *ID3D11Device,
            riid: *const GUID,
            ppvObject: *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        AddRef: *const anyopaque,
        Release: *const fn (self: *ID3D11Device) callconv(.winapi) u32,
        // ID3D11Device — slot 4..
        CreateBuffer: *const fn (
            self: *ID3D11Device,
            pDesc: *const D3D11_BUFFER_DESC,
            pInitialData: ?*const D3D11_SUBRESOURCE_DATA,
            ppBuffer: *?*ID3D11Buffer,
        ) callconv(.winapi) HRESULT,
        CreateTexture1D: *const anyopaque,
        CreateTexture2D: *const fn (
            self: *ID3D11Device,
            pDesc: *const D3D11_TEXTURE2D_DESC,
            pInitialData: ?[*]const D3D11_SUBRESOURCE_DATA,
            ppTexture2D: *?*ID3D11Texture2D,
        ) callconv(.winapi) HRESULT,
        CreateTexture3D: *const anyopaque,
        CreateShaderResourceView: *const fn (
            self: *ID3D11Device,
            pResource: *ID3D11Resource,
            pDesc: ?*const anyopaque,
            ppSRView: *?*ID3D11ShaderResourceView,
        ) callconv(.winapi) HRESULT,
        CreateUnorderedAccessView: *const anyopaque,
        CreateRenderTargetView: *const fn (
            self: *ID3D11Device,
            pResource: *ID3D11Resource,
            pDesc: ?*const anyopaque,
            ppRTView: *?*ID3D11RenderTargetView,
        ) callconv(.winapi) HRESULT,
        CreateDepthStencilView: *const anyopaque,
        CreateInputLayout: *const fn (
            self: *ID3D11Device,
            pInputElementDescs: [*]const D3D11_INPUT_ELEMENT_DESC,
            NumElements: UINT,
            pShaderBytecodeWithInputSignature: *const anyopaque,
            BytecodeLength: usize,
            ppInputLayout: *?*ID3D11InputLayout,
        ) callconv(.winapi) HRESULT,
        CreateVertexShader: *const fn (
            self: *ID3D11Device,
            pShaderBytecode: *const anyopaque,
            BytecodeLength: usize,
            pClassLinkage: ?*anyopaque,
            ppVertexShader: *?*ID3D11VertexShader,
        ) callconv(.winapi) HRESULT,
        CreateGeometryShader: *const anyopaque,
        CreateGeometryShaderWithStreamOutput: *const anyopaque,
        CreatePixelShader: *const fn (
            self: *ID3D11Device,
            pShaderBytecode: *const anyopaque,
            BytecodeLength: usize,
            pClassLinkage: ?*anyopaque,
            ppPixelShader: *?*ID3D11PixelShader,
        ) callconv(.winapi) HRESULT,
        CreateHullShader: *const anyopaque,
        CreateDomainShader: *const anyopaque,
        CreateComputeShader: *const anyopaque,
        CreateClassLinkage: *const anyopaque,
        CreateBlendState: *const fn (
            self: *ID3D11Device,
            pBlendStateDesc: *const D3D11_BLEND_DESC,
            ppBlendState: *?*ID3D11BlendState,
        ) callconv(.winapi) HRESULT,
        CreateDepthStencilState: *const anyopaque,
        CreateRasterizerState: *const anyopaque,
        CreateSamplerState: *const fn (
            self: *ID3D11Device,
            pSamplerDesc: *const D3D11_SAMPLER_DESC,
            ppSamplerState: *?*ID3D11SamplerState,
        ) callconv(.winapi) HRESULT,
        // ... rest opaque for now
    };

    pub fn release(self: *ID3D11Device) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11DeviceContext = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *ID3D11DeviceContext) callconv(.winapi) u32,
        // ID3D11DeviceChild
        GetDevice: *const anyopaque,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        // ID3D11DeviceContext
        VSSetConstantBuffers: *const fn (
            self: *ID3D11DeviceContext,
            StartSlot: UINT,
            NumBuffers: UINT,
            ppConstantBuffers: [*]const *ID3D11Buffer,
        ) callconv(.winapi) void,
        PSSetShaderResources: *const fn (
            self: *ID3D11DeviceContext,
            StartSlot: UINT,
            NumViews: UINT,
            ppShaderResourceViews: [*]const *ID3D11ShaderResourceView,
        ) callconv(.winapi) void,
        PSSetShader: *const fn (
            self: *ID3D11DeviceContext,
            pPixelShader: ?*ID3D11PixelShader,
            ppClassInstances: ?[*]const ?*anyopaque,
            NumClassInstances: UINT,
        ) callconv(.winapi) void,
        PSSetSamplers: *const fn (
            self: *ID3D11DeviceContext,
            StartSlot: UINT,
            NumSamplers: UINT,
            ppSamplers: [*]const *ID3D11SamplerState,
        ) callconv(.winapi) void,
        VSSetShader: *const fn (
            self: *ID3D11DeviceContext,
            pVertexShader: ?*ID3D11VertexShader,
            ppClassInstances: ?[*]const ?*anyopaque,
            NumClassInstances: UINT,
        ) callconv(.winapi) void,
        DrawIndexed: *const anyopaque,
        Draw: *const fn (
            self: *ID3D11DeviceContext,
            VertexCount: UINT,
            StartVertexLocation: UINT,
        ) callconv(.winapi) void,
        Map: *const fn (
            self: *ID3D11DeviceContext,
            pResource: *ID3D11Resource,
            Subresource: UINT,
            MapType: D3D11_MAP,
            MapFlags: UINT,
            pMappedResource: *D3D11_MAPPED_SUBRESOURCE,
        ) callconv(.winapi) HRESULT,
        Unmap: *const fn (
            self: *ID3D11DeviceContext,
            pResource: *ID3D11Resource,
            Subresource: UINT,
        ) callconv(.winapi) void,
        PSSetConstantBuffers: *const fn (
            self: *ID3D11DeviceContext,
            StartSlot: UINT,
            NumBuffers: UINT,
            ppConstantBuffers: [*]const *ID3D11Buffer,
        ) callconv(.winapi) void,
        IASetInputLayout: *const fn (
            self: *ID3D11DeviceContext,
            pInputLayout: ?*ID3D11InputLayout,
        ) callconv(.winapi) void,
        IASetVertexBuffers: *const fn (
            self: *ID3D11DeviceContext,
            StartSlot: UINT,
            NumBuffers: UINT,
            ppVertexBuffers: [*]const *ID3D11Buffer,
            pStrides: [*]const UINT,
            pOffsets: [*]const UINT,
        ) callconv(.winapi) void,
        IASetIndexBuffer: *const anyopaque,
        DrawIndexedInstanced: *const anyopaque,
        DrawInstanced: *const fn (
            self: *ID3D11DeviceContext,
            VertexCountPerInstance: UINT,
            InstanceCount: UINT,
            StartVertexLocation: UINT,
            StartInstanceLocation: UINT,
        ) callconv(.winapi) void,
        GSSetConstantBuffers: *const anyopaque,
        GSSetShader: *const anyopaque,
        IASetPrimitiveTopology: *const fn (
            self: *ID3D11DeviceContext,
            Topology: D3D11_PRIMITIVE_TOPOLOGY,
        ) callconv(.winapi) void,
        VSSetShaderResources: *const fn (
            self: *ID3D11DeviceContext,
            StartSlot: UINT,
            NumViews: UINT,
            ppShaderResourceViews: [*]const *ID3D11ShaderResourceView,
        ) callconv(.winapi) void,
        VSSetSamplers: *const anyopaque,
        Begin: *const anyopaque,
        End: *const anyopaque,
        GetData: *const anyopaque,
        SetPredication: *const anyopaque,
        GSSetShaderResources: *const anyopaque,
        GSSetSamplers: *const anyopaque,
        OMSetRenderTargets: *const fn (
            self: *ID3D11DeviceContext,
            NumViews: UINT,
            ppRenderTargetViews: ?[*]const *ID3D11RenderTargetView,
            pDepthStencilView: ?*anyopaque,
        ) callconv(.winapi) void,
        OMSetRenderTargetsAndUnorderedAccessViews: *const anyopaque,
        OMSetBlendState: *const fn (
            self: *ID3D11DeviceContext,
            pBlendState: ?*ID3D11BlendState,
            BlendFactor: ?*const [4]f32,
            SampleMask: UINT,
        ) callconv(.winapi) void,
        OMSetDepthStencilState: *const anyopaque,
        SOSetTargets: *const anyopaque,
        DrawAuto: *const anyopaque,
        DrawIndexedInstancedIndirect: *const anyopaque,
        DrawInstancedIndirect: *const anyopaque,
        Dispatch: *const anyopaque,
        DispatchIndirect: *const anyopaque,
        RSSetState: *const anyopaque,
        RSSetViewports: *const fn (
            self: *ID3D11DeviceContext,
            NumViewports: UINT,
            pViewports: [*]const D3D11_VIEWPORT,
        ) callconv(.winapi) void,
        RSSetScissorRects: *const anyopaque,
        CopySubresourceRegion: *const anyopaque,
        CopyResource: *const anyopaque,
        UpdateSubresource: *const fn (
            self: *ID3D11DeviceContext,
            pDstResource: *ID3D11Resource,
            DstSubresource: UINT,
            pDstBox: ?*const D3D11_BOX,
            pSrcData: *const anyopaque,
            SrcRowPitch: UINT,
            SrcDepthPitch: UINT,
        ) callconv(.winapi) void,
        CopyStructureCount: *const anyopaque,
        ClearRenderTargetView: *const fn (
            self: *ID3D11DeviceContext,
            pRenderTargetView: *ID3D11RenderTargetView,
            ColorRGBA: *const [4]f32,
        ) callconv(.winapi) void,
        // ... rest opaque
    };

    pub fn release(self: *ID3D11DeviceContext) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11RenderTargetView = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *ID3D11RenderTargetView) callconv(.winapi) u32,
        // ... rest opaque
    };

    pub fn release(self: *ID3D11RenderTargetView) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3DBlob = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (self: *ID3DBlob) callconv(.winapi) u32,
        GetBufferPointer: *const fn (self: *ID3DBlob) callconv(.winapi) *anyopaque,
        GetBufferSize: *const fn (self: *ID3DBlob) callconv(.winapi) usize,
    };

    pub fn release(self: *ID3DBlob) u32 {
        return self.vtable.Release(self);
    }

    pub fn bufferPointer(self: *ID3DBlob) *anyopaque {
        return self.vtable.GetBufferPointer(self);
    }

    pub fn bufferSize(self: *ID3DBlob) usize {
        return self.vtable.GetBufferSize(self);
    }
};

// ---------------------------------------------------------------------------
// Descriptors and enums.
// ---------------------------------------------------------------------------

/// https://learn.microsoft.com/en-us/windows/win32/api/dxgiformat/ne-dxgiformat-dxgi_format
pub const DXGI_FORMAT = enum(UINT) {
    UNKNOWN = 0,
    R32G32B32A32_FLOAT = 2,
    R32G32B32A32_UINT = 3,
    R32G32_FLOAT = 16,
    R32G32_UINT = 33,
    R32_UINT = 42,
    R8G8B8A8_UNORM = 28,
    R8G8B8A8_UINT = 30,
    R16G16_UINT = 36,
    R16G16_SINT = 38,
    R8G8_UINT = 50,
    R8_UNORM = 61,
    R8_UINT = 62,
    B8G8R8A8_UNORM = 87,
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
    _pad_lo: u16 = 0,
    // D3D11_CPU_ACCESS_WRITE = 0x10000 (bit 16)
    write: bool = false,
    // D3D11_CPU_ACCESS_READ = 0x20000 (bit 17)
    read: bool = false,
    _pad_hi: u14 = 0,
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

pub const D3D11_BLEND = enum(UINT) {
    ZERO = 1,
    ONE = 2,
    SRC_COLOR = 3,
    INV_SRC_COLOR = 4,
    SRC_ALPHA = 5,
    INV_SRC_ALPHA = 6,
    DEST_ALPHA = 7,
    INV_DEST_ALPHA = 8,
    DEST_COLOR = 9,
    INV_DEST_COLOR = 10,
    _,
};

pub const D3D11_BLEND_OP = enum(UINT) {
    ADD = 1,
    SUBTRACT = 2,
    REV_SUBTRACT = 3,
    MIN = 4,
    MAX = 5,
};

pub const D3D11_RENDER_TARGET_BLEND_DESC = extern struct {
    BlendEnable: BOOL = 0,
    SrcBlend: D3D11_BLEND = .ONE,
    DestBlend: D3D11_BLEND = .ZERO,
    BlendOp: D3D11_BLEND_OP = .ADD,
    SrcBlendAlpha: D3D11_BLEND = .ONE,
    DestBlendAlpha: D3D11_BLEND = .ZERO,
    BlendOpAlpha: D3D11_BLEND_OP = .ADD,
    RenderTargetWriteMask: u8 = 0x0F,
};

pub const D3D11_BLEND_DESC = extern struct {
    AlphaToCoverageEnable: BOOL = 0,
    IndependentBlendEnable: BOOL = 0,
    RenderTarget: [8]D3D11_RENDER_TARGET_BLEND_DESC,
};

pub const D3D11_RESOURCE_MISC_BUFFER_STRUCTURED: UINT = 0x40;

pub const D3D11_SRV_DIMENSION_BUFFER: UINT = 1;

pub const D3D11_BUFFER_SRV = extern struct {
    FirstElement: UINT = 0,
    NumElements: UINT,
    _pad_to_largest_union: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
};

pub const D3D11_SHADER_RESOURCE_VIEW_DESC = extern struct {
    Format: DXGI_FORMAT,
    ViewDimension: UINT,
    Buffer: D3D11_BUFFER_SRV,
};

pub const D3D11_SAMPLER_DESC = extern struct {
    Filter: D3D11_FILTER,
    AddressU: D3D11_TEXTURE_ADDRESS_MODE,
    AddressV: D3D11_TEXTURE_ADDRESS_MODE,
    AddressW: D3D11_TEXTURE_ADDRESS_MODE,
    MipLODBias: f32 = 0,
    MaxAnisotropy: UINT = 1,
    ComparisonFunc: UINT = 0,
    BorderColor: [4]f32 = .{ 0, 0, 0, 0 },
    MinLOD: f32 = 0,
    MaxLOD: f32 = 3.402823466e+38, // FLT_MAX
};

pub const DXGI_USAGE = packed struct(UINT) {
    _pad0: u4 = 0,
    shader_input: bool = false,
    render_target_output: bool = false,
    back_buffer: bool = false,
    shared: bool = false,
    read_only: bool = false,
    discard_on_present: bool = false,
    unordered_access: bool = false,
    _pad11: u21 = 0,
};

pub const DXGI_SCALING = enum(UINT) {
    STRETCH = 0,
    NONE = 1,
    ASPECT_RATIO_STRETCH = 2,
};

pub const DXGI_SWAP_EFFECT = enum(UINT) {
    DISCARD = 0,
    SEQUENTIAL = 1,
    FLIP_SEQUENTIAL = 3,
    FLIP_DISCARD = 4,
};

pub const DXGI_ALPHA_MODE = enum(UINT) {
    UNSPECIFIED = 0,
    PREMULTIPLIED = 1,
    STRAIGHT = 2,
    IGNORE = 3,
};

pub const DXGI_SWAP_CHAIN_DESC1 = extern struct {
    Width: UINT,
    Height: UINT,
    Format: DXGI_FORMAT,
    Stereo: BOOL,
    SampleDesc: DXGI_SAMPLE_DESC,
    BufferUsage: DXGI_USAGE,
    BufferCount: UINT,
    Scaling: DXGI_SCALING,
    SwapEffect: DXGI_SWAP_EFFECT,
    AlphaMode: DXGI_ALPHA_MODE,
    Flags: UINT,
};

pub const D3D11_VIEWPORT = extern struct {
    TopLeftX: f32,
    TopLeftY: f32,
    Width: f32,
    Height: f32,
    MinDepth: f32,
    MaxDepth: f32,
};

pub const D3D11_CREATE_DEVICE_FLAG = packed struct(UINT) {
    single_threaded: bool = false,
    debug: bool = false,
    _pad: u30 = 0,
};

pub const D3D11_BOX = extern struct {
    left: UINT,
    top: UINT,
    front: UINT,
    right: UINT,
    bottom: UINT,
    back: UINT,
};

pub const D3D11_MAP = enum(UINT) {
    READ = 1,
    WRITE = 2,
    READ_WRITE = 3,
    WRITE_DISCARD = 4,
    WRITE_NO_OVERWRITE = 5,
};

pub const D3D11_MAPPED_SUBRESOURCE = extern struct {
    pData: ?*anyopaque,
    RowPitch: UINT,
    DepthPitch: UINT,
};

pub const D3D11_PRIMITIVE_TOPOLOGY = enum(UINT) {
    UNDEFINED = 0,
    POINTLIST = 1,
    LINELIST = 2,
    LINESTRIP = 3,
    TRIANGLELIST = 4,
    TRIANGLESTRIP = 5,
    _,
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

/// Signature of the D3DCompile entry point in d3dcompiler_47.dll. The
/// DLL is loaded at runtime (LoadLibrary) rather than via static link so
/// that we don't pull MSVC's libcmt.lib into the final binary — which
/// would in turn require a WinMain entry point.
pub const D3DCompileFn = *const fn (
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

/// Lazily-loaded pointer to D3DCompile. Initialize with `loadD3DCompiler`
/// before first use, then call via `D3DCompile.?(...)`.
pub var D3DCompile: ?D3DCompileFn = null;

extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetProcAddress(hModule: HANDLE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;

pub fn loadD3DCompiler() bool {
    if (D3DCompile != null) return true;
    const handle = LoadLibraryA("d3dcompiler_47.dll") orelse return false;
    const proc = GetProcAddress(handle, "D3DCompile") orelse return false;
    D3DCompile = @ptrCast(@alignCast(proc));
    return true;
}

pub const D3D11_SDK_VERSION: UINT = 7;

pub const IID_IDXGIFactory2: GUID = .{
    .Data1 = 0x50c83a1c,
    .Data2 = 0xe072,
    .Data3 = 0x4c48,
    .Data4 = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 },
};

pub const IID_ID3D11Texture2D: GUID = .{
    .Data1 = 0x6f15aaf2,
    .Data2 = 0xd208,
    .Data3 = 0x4e89,
    .Data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c },
};

pub const IID_IDXGIDevice: GUID = .{
    .Data1 = 0x54ec77fa,
    .Data2 = 0x1377,
    .Data3 = 0x44e6,
    .Data4 = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c },
};

/// Helper for HRESULT success check.
pub inline fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

pub inline fn failed(hr: HRESULT) bool {
    return hr < 0;
}
