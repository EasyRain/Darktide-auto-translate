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

// How much of a response body the core will hand back, in bytes (AT_MAX_BODY). Exposed because
// the caller owns the buffer and the core clamps it: a caller that asks for more silently gets
// less, and one that keeps a smaller buffer silently truncates. That is not hypothetical - Bing's
// translator page is 645,986 bytes and a 256 KB cap cut the session block off the end of it.
AT_API int at_core_max_body(void);

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

// POST with a body, for APIs that take their query in the request body (DeepL).
// `headers` is an extra header block ("Name: value\r\n") used for API keys;
// `content_type` may be NULL. Returns a request id like at_http_get.
AT_API int  at_http_post(const char* host_utf8, const char* path_utf8, const char* content_type,
                         const char* headers, const char* body_utf8);
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

// Local model inference (the same entry point the CLI uses). The heavy lifting is
// in at_model.cpp; this is the C surface the Lua side talks to.
//   > 0 = number of bytes written to out_text
//   -1  = no model loaded
//   -2  = invalid arguments (or a language with no FLORES-200 code)
//   -3  = tokenisation failed
//   -4  = inference failed / the result does not fit
AT_API int  at_translate(const char* text_utf8, const char* target_lang_utf8,
                         char* out_text, int out_cap);

// Remembers where the model lives so at_load_model()/at_model_status() can find it.
// Returns how many of the 4 model files are present (4 = complete, 0 = unusable).
AT_API int  at_set_model_dir(const char* dir_utf8);

// Loads the model from the directory set above. 1 = ready, 0 = failed; the reason
// is in at_model_error(). BLOCKS (about a second warm, several seconds cold) - inside
// the game use at_load_model_async().
AT_API int  at_load_model(void);

// Same, on a background thread: 1 = started, 0 = already loaded/loading, <0 = refused.
//
// One model per process: once something is loaded, a call naming another directory
// returns 0 and changes nothing (see the note in at_model.cpp - the objects are never
// released). at_model_loaded_dir() is what tells the caller whether its request was
// honoured or ignored.
AT_API int  at_load_model_async(void);

// A string out of a JSON response at a "a.b.0.c" path (numeric steps index arrays).
// 1 = found, 0 = not there or not a string (at_error() says which).
AT_API int  at_json_string_at(const char* json_utf8, const char* path_utf8, char* out, int cap);

// The proxy currently in use (mod option first, then the Windows setting), as a wide
// string, for code that opens its own WinHTTP session. Returns 1 when a proxy is set.
AT_API int  at_proxy_wide(wchar_t* out, int cap);

// Threads one translation may use: <0 = every core (the slowest, measured), 0 = automatic
// (min(cores/2, 8), the default), >0 = exactly that many. CTranslate2 would otherwise ask
// for every core on its own, and this runs inside the game. Set before loading; returns 0
// when a model is already loaded.
AT_API int  at_set_model_threads(int threads);

// Threads the loaded model uses (0 when nothing is loaded) and the machine's core
// count, for the HUD/log and for the CLI to report.
AT_API int  at_model_threads(void);
AT_API int  at_model_core_count(void);

// Directory of the loaded model ("" when none). A mismatch with the directory the mod
// asked for means the request did nothing and the game has to be restarted.
AT_API int  at_model_loaded_dir(char* out, int cap);

// The game-facing translation pair. at_submit hands a string over and returns at once
// (1 = accepted, 0 = busy, <0 = refused); at_poll collects it a few frames later
// (0 = still working, > 0 = bytes written, < 0 = failed). Neither ever blocks on
// inference, which is what keeps the frame callback honest.
AT_API int  at_submit(const char* text_utf8, const char* target_lang_utf8);
AT_API int  at_poll(char* out_text, int out_cap);

// 0 = no model files found, 1 = files present but not loaded, 2 = loaded and ready,
// 3 = a background load is running.
AT_API int  at_model_status(void);

// Size in bytes of the model files on disk, 0 when there is nothing to load.
AT_API long long at_model_disk_size(void);

// Last model failure, human readable. Never NULL.
AT_API const char* at_model_error(void);

#ifdef __cplusplus
}
#endif

#endif // AT_CORE_H
