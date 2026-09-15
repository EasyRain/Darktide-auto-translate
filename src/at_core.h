// at_core.h — Auto Translate native core (HTTP + translation entry points)
//
// Async HTTP GET on a background thread so the game thread never blocks.
//   at_http_get(host, path) -> request id (>0) or 0 on failure
//   at_http_poll(...)       -> 1 = a result was handed back, 0 = none yet, <0 = internal error
// See the note on at_http_poll below: the transport outcome and the HTTP status
// are separate values on purpose.
#ifndef AT_CORE_H
#define AT_CORE_H

#include "at_api.h"

#ifdef __cplusplus
extern "C" {
#endif

AT_API int  at_available(void);
AT_API const char* at_error(void);
AT_API const char* at_version(void);

// Async HTTP GET (background thread).
//
// `host` may be "name", "name:port", "scheme://name[:port]" or "[v6]:port"; the
// port must be part of this string or omitted (never passed to WinHttpConnect
// separately by the caller). "https://" is the default and what every production
// call uses; "http://" exists so local endpoints can be smoke tested.
//
// at_http_poll returns 1 when it handed back a result, 0 when there is none yet,
// <0 on an internal error. The two outcomes of a request are reported separately
// and deliberately:
//     out_result    0  = the request completed; read out_http_code
//                   <0 = transport failure (-10..-15), and out_win_error is set
//     out_http_code    the HTTP status (200, 404, ...) when out_result == 0
// Keeping them apart matters: a single value where 0 means "no error" and 200
// means "success" is how callers end up treating every 200 as a failure.
AT_API int  at_http_get(const char* host_utf8, const char* path_utf8);
AT_API int  at_http_poll(int* out_id, int* out_result, int* out_http_code, char* out_body, int out_cap,
                         int* out_len, unsigned long* out_win_error);
AT_API int  at_http_pending(void);

// Decodes a code from at_http_poll into a message (FormatMessage). Static buffer.
AT_API const char* at_win_error_text(unsigned long code);

// ---------------------------------------------------------------------------
// Proxy
//
// WinHTTP does not read the Windows (WinINET) proxy settings, so on a machine
// that needs a proxy to reach Google a direct connection simply fails with
// 12029. The core therefore uses, in order: the address set here, then the
// Windows setting when it is enabled, then a direct connection.
//   at_set_proxy("127.0.0.1:7890")  -> use this
//   at_set_proxy("")                -> back to automatic
// ---------------------------------------------------------------------------
AT_API int  at_set_proxy(const char* hostport_utf8);

// What would actually be used, as a readable string ("none (direct connection)").
AT_API const char* at_proxy_in_use(void);

// Non-empty when Windows has a proxy configured but switched off - a hint worth
// showing, because that is exactly the "my VPN is on but nothing works" case.
AT_API const char* at_proxy_hint(void);

// Local model inference (same entry point the CLI uses). Not implemented yet:
// returns -1 and fills the error string, so callers/tests can be written now.
//   > 0 = number of bytes written to out_text
//   -1  = not implemented in this build
//   -2  = invalid arguments
//   -3  = model not loaded / not available
AT_API int  at_translate(const char* text_utf8, const char* target_lang_utf8,
                         char* out_text, int out_cap);

// 0 = no model, 1 = model files present, 2 = model loaded and ready.
AT_API int  at_model_status(void);

#ifdef __cplusplus
}
#endif

#endif // AT_CORE_H
