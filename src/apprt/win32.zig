// Native Win32 app runtime for Ghostty.
//
// STATUS: skeleton. Only the comptime API surface that the rest of the engine
// references is present; window management, input/IME, ConPTY plumbing, and
// D3D11 surface attach all live in `win32/` and are currently stubs that
// return `error.Win32NotYetImplemented`. The standalone ConPTY proof in
// E:\conpty_echo\main.zig validates the API calls we'll port into
// win32/ConPTY.zig once the surface lifecycle is wired up.

// The required comptime API for any apprt.
pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const resourcesDir = @import("../os/main.zig").resourcesDir;
