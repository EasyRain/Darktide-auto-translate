// at_core.h — Auto Translate native core (HTTP part)
//
// Async HTTP GET on a background thread so the game thread never blocks.
//   at_http_get(host, path)                  -> request id (>0) or 0 on failure
//   at_http_poll(&id, &status, buf, cap, &len) -> 1 = a result was popped, 0 = none
//                                                 status: 0 ok, >0 http code, <0 network error
#ifndef AT_CORE_H
#define AT_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

__declspec(dllexport) int  at_available(void);
__declspec(dllexport) const char* at_error(void);
__declspec(dllexport) const char* at_version(void);

// Async HTTP GET (background thread).
//
// The host may carry a scheme prefix ("https://" is the default and what every
// production call uses; "http://" exists so local endpoints can be smoke tested).
// On failure the WinHTTP/Win32 code of the call that broke is handed back through
// out_win_error, so a bare negative status is not a dead end.
__declspec(dllexport) int  at_http_get(const char* host_utf8, const char* path_utf8);
__declspec(dllexport) int  at_http_poll(int* out_id, int* out_status, char* out_body, int out_cap,
                                        int* out_len, unsigned long* out_win_error);
__declspec(dllexport) int  at_http_pending(void);

// Decodes a code from at_http_poll into a message (FormatMessage). Static buffer.
__declspec(dllexport) const char* at_win_error_text(unsigned long code);

// Local model inference (same entry point the CLI uses). Not implemented yet:
// returns -1 and fills the error string, so callers/tests can be written now.
//   > 0 = number of bytes written to out_text
//   -1  = not implemented in this build
//   -2  = invalid arguments
//   -3  = model not loaded / not available
__declspec(dllexport) int  at_translate(const char* text_utf8, const char* target_lang_utf8,
                                        char* out_text, int out_cap);

// 0 = no model, 1 = model files present, 2 = model loaded and ready.
__declspec(dllexport) int  at_model_status(void);

#ifdef __cplusplus
}
#endif

#endif // AT_CORE_H
