// Minimal stand-in for the Windows SDK's eventtoken.h.
//
// WebView2.h does `#include "EventToken.h"` purely to obtain the
// EventRegistrationToken type used by its add_/remove_ event APIs. The
// vendored WebView2 NuGet include dir does not ship this header, so we
// provide the one type it needs. Guarded to coexist with the real SDK
// header if it is ever pulled in first.
#ifndef _APISETEVENTTOKEN_
#define _APISETEVENTTOKEN_

#ifndef __EventToken_value_defined
#define __EventToken_value_defined
typedef struct EventRegistrationToken {
    __int64 value;
} EventRegistrationToken;
#endif

#endif // _APISETEVENTTOKEN_
