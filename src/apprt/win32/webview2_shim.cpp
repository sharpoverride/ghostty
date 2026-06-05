// Tiny C-ABI shim over the WebView2 COM API for the Zig win32 apprt.
//
// Design constraints (mirrors how src/simd/*.cpp is built — see
// SharedDeps.addWin32 / addSimd): NO WRL, NO STL, NO C++ runtime. We
// supply our own operator new/delete routed to the process heap, build
// with -fno-exceptions -fno-rtti, and implement the two COM completion
// handlers by hand. This keeps the shim linkable against zig's bundled
// mingw headers without pulling in libc++ or the MSVC Windows SDK.
//
// The loader (WebView2Loader.dll, vendored + installed beside ghostty.exe)
// is resolved at runtime via LoadLibrary/GetProcAddress — the same idiom as
// d3dcompiler_47 (renderer/d3d11/api.zig::loadD3DCompiler). The static
// loader lib is NOT linkable here: it's MSVC-built and drags in MSVC CRT
// internals (__security_cookie, _Init_thread_*, MSVC-mangled operators,
// /guard:cf stubs) that zig's mingw toolchain cannot provide.
//
// Exposed C entry points (see webview2.zig for the Zig side):
//   gv_webview_create  — async; navigates + shows once the controller is up
//   gv_webview_set_bounds / gv_webview_set_visible
//   gv_webview_destroy

#include <windows.h>
#include <objbase.h>

// WebView2.h references a few MSVC-only SAL/Control-Flow-Guard macros that
// zig's mingw headers don't define. Stub them before the include so the
// header parses under clang targeting *-windows-gnu.
#ifndef DECLSPEC_XFGVIRT
#define DECLSPEC_XFGVIRT(base, func)
#endif

#include "WebView2.h"

// --- minimal C++ runtime substitutes -------------------------------------
// No libc++: route allocation to the process heap and stub the pure-virtual
// trap (never hit — every interface method below is overridden).
void *operator new(size_t n) { return HeapAlloc(GetProcessHeap(), 0, n ? n : 1); }
void operator delete(void *p) noexcept {
    if (p) HeapFree(GetProcessHeap(), 0, p);
}
void operator delete(void *p, size_t) noexcept {
    if (p) HeapFree(GetProcessHeap(), 0, p);
}
extern "C" void __cxa_pure_virtual() {}

static const IID kIID_IUnknown =
    {0x00000000, 0x0000, 0x0000, {0xC0, 0, 0, 0, 0, 0, 0, 0x46}};

// Runtime-resolved CreateCoreWebView2EnvironmentWithOptions from
// WebView2Loader.dll (searched exe-dir first, so the installed copy wins).
// Resolved once, never freed — the loader stays for the process lifetime.
typedef HRESULT(STDAPICALLTYPE *gv_create_env_fn)(
    PCWSTR browserExecutableFolder, PCWSTR userDataFolder,
    ICoreWebView2EnvironmentOptions *environmentOptions,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *handler);

static gv_create_env_fn gv_load_create_env() {
    static gv_create_env_fn fn = nullptr;
    if (fn) return fn;
    HMODULE mod = LoadLibraryW(L"WebView2Loader.dll");
    if (!mod) return nullptr;
    fn = (gv_create_env_fn)GetProcAddress(
        mod, "CreateCoreWebView2EnvironmentWithOptions");
    return fn;
}

extern "C" typedef void (*gv_ready_cb)(void *ctx, void *handle, int ok);
// Document title changed; `title` is only valid for the duration of the call.
extern "C" typedef void (*gv_title_cb)(void *ctx, const wchar_t *title);
// Source URL changed (navigation committed); same lifetime rule as title.
extern "C" typedef void (*gv_url_cb)(void *ctx, const wchar_t *url);
// ExecuteScript completed. ok=1 with the JSON-encoded result, or ok=0 and
// result_json=null on failure. result_json only valid during the call.
extern "C" typedef void (*gv_script_cb)(void *ctx, const wchar_t *result_json, int ok);

namespace {

struct GvWebView {
    HWND parent;
    ICoreWebView2Controller *controller;
    ICoreWebView2 *webview;
    gv_ready_cb cb;
    gv_title_cb title_cb;
    gv_url_cb url_cb;
    void *ctx;
    RECT bounds;
    wchar_t *url; // heap-owned, freed in destroy
};

wchar_t *dupw(const wchar_t *s) {
    if (!s) return nullptr;
    size_t len = 0;
    while (s[len]) len++;
    wchar_t *d = (wchar_t *)HeapAlloc(GetProcessHeap(), 0, (len + 1) * sizeof(wchar_t));
    if (!d) return nullptr;
    for (size_t i = 0; i <= len; i++) d[i] = s[i];
    return d;
}

void fail(GvWebView *wv) {
    if (wv && wv->cb) wv->cb(wv->ctx, wv, 0);
}

// Shared QI/refcount boilerplate for the single-interface event handlers
// below. `Derived` supplies its interface IID via kIID and inherits from it.
template <typename Iface, const IID &iid> class GvHandlerBase : public Iface {
public:
    GvWebView *wv;
    LONG ref;
    explicit GvHandlerBase(GvWebView *w) : wv(w), ref(1) {}
    virtual ~GvHandlerBase() {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppv) override {
        if (InlineIsEqualGUID(riid, kIID_IUnknown) ||
            InlineIsEqualGUID(riid, iid)) {
            *ppv = static_cast<Iface *>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&ref); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG c = InterlockedDecrement(&ref);
        if (c == 0) delete this;
        return (ULONG)c;
    }
};

// DocumentTitleChanged → gv_title_cb with the new title.
class TitleHandler
    : public GvHandlerBase<ICoreWebView2DocumentTitleChangedEventHandler,
                           IID_ICoreWebView2DocumentTitleChangedEventHandler> {
public:
    using GvHandlerBase::GvHandlerBase;
    HRESULT STDMETHODCALLTYPE Invoke(ICoreWebView2 *sender, IUnknown *) override {
        if (!wv->title_cb) return S_OK;
        LPWSTR title = nullptr;
        if (SUCCEEDED(sender->get_DocumentTitle(&title)) && title) {
            wv->title_cb(wv->ctx, title);
            CoTaskMemFree(title);
        }
        return S_OK;
    }
};

// SourceChanged → gv_url_cb with the new source URL.
class SourceHandler
    : public GvHandlerBase<ICoreWebView2SourceChangedEventHandler,
                           IID_ICoreWebView2SourceChangedEventHandler> {
public:
    using GvHandlerBase::GvHandlerBase;
    HRESULT STDMETHODCALLTYPE Invoke(ICoreWebView2 *sender,
                                     ICoreWebView2SourceChangedEventArgs *) override {
        if (!wv->url_cb) return S_OK;
        LPWSTR uri = nullptr;
        if (SUCCEEDED(sender->get_Source(&uri)) && uri) {
            wv->url_cb(wv->ctx, uri);
            CoTaskMemFree(uri);
        }
        return S_OK;
    }
};

// ExecuteScript completion → gv_script_cb. Carries its own ctx (per call),
// not the GvWebView ctx.
class ScriptHandler : public ICoreWebView2ExecuteScriptCompletedHandler {
public:
    gv_script_cb cb;
    void *ctx;
    LONG ref;
    ScriptHandler(gv_script_cb c, void *x) : cb(c), ctx(x), ref(1) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppv) override {
        if (InlineIsEqualGUID(riid, kIID_IUnknown) ||
            InlineIsEqualGUID(riid, IID_ICoreWebView2ExecuteScriptCompletedHandler)) {
            *ppv = static_cast<ICoreWebView2ExecuteScriptCompletedHandler *>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&ref); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG c = InterlockedDecrement(&ref);
        if (c == 0) delete this;
        return (ULONG)c;
    }
    HRESULT STDMETHODCALLTYPE Invoke(HRESULT result, LPCWSTR result_json) override {
        if (cb) cb(ctx, SUCCEEDED(result) ? result_json : nullptr,
                   SUCCEEDED(result) ? 1 : 0);
        return S_OK;
    }
};

// Completion handler invoked once the WebView2 controller (and its render
// HWND, parented to GvWebView::parent) is ready. Sets bounds, shows it,
// grabs the ICoreWebView2 and navigates to the initial URL.
class ControllerHandler
    : public ICoreWebView2CreateCoreWebView2ControllerCompletedHandler {
public:
    GvWebView *wv;
    LONG ref;
    explicit ControllerHandler(GvWebView *w) : wv(w), ref(1) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppv) override {
        if (InlineIsEqualGUID(riid, kIID_IUnknown) ||
            InlineIsEqualGUID(
                riid,
                IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler)) {
            *ppv = static_cast<
                ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&ref); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG c = InterlockedDecrement(&ref);
        if (c == 0) delete this;
        return (ULONG)c;
    }
    HRESULT STDMETHODCALLTYPE Invoke(HRESULT result,
                                     ICoreWebView2Controller *controller) override {
        if (FAILED(result) || !controller) {
            fail(wv);
            return S_OK;
        }
        wv->controller = controller;
        controller->AddRef();
        controller->put_Bounds(wv->bounds);
        controller->put_IsVisible(TRUE);
        controller->get_CoreWebView2(&wv->webview);
        if (wv->webview) {
            // Event registrations live until controller->Close() in destroy;
            // tokens are not needed since we never selectively unregister.
            EventRegistrationToken tok;
            TitleHandler *th = new TitleHandler(wv);
            wv->webview->add_DocumentTitleChanged(th, &tok);
            th->Release();
            SourceHandler *sh = new SourceHandler(wv);
            wv->webview->add_SourceChanged(sh, &tok);
            sh->Release();
            if (wv->url) wv->webview->Navigate(wv->url);
        }
        if (wv->cb) wv->cb(wv->ctx, wv, 1);
        return S_OK;
    }
};

// Completion handler invoked once the WebView2 environment exists; it kicks
// off controller creation parented to the target HWND.
class EnvHandler
    : public ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler {
public:
    GvWebView *wv;
    LONG ref;
    explicit EnvHandler(GvWebView *w) : wv(w), ref(1) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppv) override {
        if (InlineIsEqualGUID(riid, kIID_IUnknown) ||
            InlineIsEqualGUID(
                riid,
                IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler)) {
            *ppv = static_cast<
                ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&ref); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG c = InterlockedDecrement(&ref);
        if (c == 0) delete this;
        return (ULONG)c;
    }
    HRESULT STDMETHODCALLTYPE Invoke(HRESULT result,
                                     ICoreWebView2Environment *env) override {
        if (FAILED(result) || !env) {
            fail(wv);
            return S_OK;
        }
        ControllerHandler *ch = new ControllerHandler(wv);
        HRESULT hr = env->CreateCoreWebView2Controller(wv->parent, ch);
        ch->Release(); // env holds its own ref while the op is in flight
        if (FAILED(hr)) fail(wv);
        return S_OK;
    }
};

} // namespace

extern "C" void *gv_webview_create(void *parent, const wchar_t *user_data_folder,
                                   int x, int y, int w, int h,
                                   const wchar_t *url, gv_ready_cb cb,
                                   gv_title_cb title_cb, gv_url_cb url_cb,
                                   void *ctx) {
    // WebView2 needs an STA. Idempotent if the UI thread already initialized
    // COM (returns S_FALSE / RPC_E_CHANGED_MODE, both harmless here).
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    GvWebView *wv = new GvWebView();
    wv->parent = (HWND)parent;
    wv->controller = nullptr;
    wv->webview = nullptr;
    wv->cb = cb;
    wv->title_cb = title_cb;
    wv->url_cb = url_cb;
    wv->ctx = ctx;
    wv->bounds.left = x;
    wv->bounds.top = y;
    wv->bounds.right = x + w;
    wv->bounds.bottom = y + h;
    wv->url = dupw(url);

    // Resolve a writable user-data folder if the caller passed none. The exe
    // can live under Program Files (read-only), so default to
    // %LOCALAPPDATA%\ghostty\WebView2 (WebView2 creates leaf dirs itself, but
    // we pre-create the parents to be safe).
    wchar_t buf[MAX_PATH];
    const wchar_t *udf = user_data_folder;
    if (!udf || !udf[0]) {
        DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
        if (n > 0 && n < MAX_PATH - 24) {
            lstrcatW(buf, L"\\ghostty");
            CreateDirectoryW(buf, nullptr);
            lstrcatW(buf, L"\\WebView2");
            CreateDirectoryW(buf, nullptr);
            udf = buf;
        }
    }

    gv_create_env_fn create_env = gv_load_create_env();
    if (!create_env) {
        fail(wv);
        return wv;
    }
    EnvHandler *eh = new EnvHandler(wv);
    HRESULT hr = create_env(nullptr, udf, nullptr, eh);
    eh->Release();
    if (FAILED(hr)) fail(wv);
    return wv;
}

extern "C" void gv_webview_set_bounds(void *handle, int x, int y, int w, int h) {
    GvWebView *wv = (GvWebView *)handle;
    if (!wv || !wv->controller) return;
    RECT r = {x, y, x + w, y + h};
    wv->controller->put_Bounds(r);
}

extern "C" void gv_webview_set_visible(void *handle, int visible) {
    GvWebView *wv = (GvWebView *)handle;
    if (!wv || !wv->controller) return;
    wv->controller->put_IsVisible(visible ? TRUE : FALSE);
}

// Navigate to `url`. If the WebView is still initializing, replace the
// pending initial URL instead (it's navigated to once the controller is up).
extern "C" void gv_webview_navigate(void *handle, const wchar_t *url) {
    GvWebView *wv = (GvWebView *)handle;
    if (!wv || !url) return;
    if (wv->webview) {
        wv->webview->Navigate(url);
        return;
    }
    if (wv->url) HeapFree(GetProcessHeap(), 0, wv->url);
    wv->url = dupw(url);
}

extern "C" void gv_webview_back(void *handle) {
    GvWebView *wv = (GvWebView *)handle;
    if (wv && wv->webview) wv->webview->GoBack();
}

extern "C" void gv_webview_forward(void *handle) {
    GvWebView *wv = (GvWebView *)handle;
    if (wv && wv->webview) wv->webview->GoForward();
}

extern "C" void gv_webview_reload(void *handle) {
    GvWebView *wv = (GvWebView *)handle;
    if (wv && wv->webview) wv->webview->Reload();
}

// Move keyboard focus into the web content (programmatic reason).
extern "C" void gv_webview_focus(void *handle) {
    GvWebView *wv = (GvWebView *)handle;
    if (wv && wv->controller)
        wv->controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
}

// Evaluate JavaScript in the top frame. `cb` fires on the UI thread with the
// JSON-encoded result. Returns 1 if the call was issued, 0 if the WebView
// isn't ready (cb is NOT invoked in that case).
extern "C" int gv_webview_execute_script(void *handle, const wchar_t *js,
                                         gv_script_cb cb, void *ctx) {
    GvWebView *wv = (GvWebView *)handle;
    if (!wv || !wv->webview || !js) return 0;
    ScriptHandler *sh = new ScriptHandler(cb, ctx);
    HRESULT hr = wv->webview->ExecuteScript(js, sh);
    sh->Release();
    return SUCCEEDED(hr) ? 1 : 0;
}

extern "C" void gv_webview_destroy(void *handle) {
    GvWebView *wv = (GvWebView *)handle;
    if (!wv) return;
    if (wv->controller) {
        wv->controller->Close();
        wv->controller->Release();
    }
    if (wv->webview) wv->webview->Release();
    if (wv->url) HeapFree(GetProcessHeap(), 0, wv->url);
    delete wv;
}
