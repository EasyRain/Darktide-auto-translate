// at_online.h — online translation providers: request building and response parsing.
//
// Split into pure functions on purpose. Building a request URL and turning a
// response body into translated text are the two places provider quirks live
// (MyMemory returning Traditional Chinese for zh-CN, MyMemory HTML-escaping its
// output, Google splitting long text into several segments), so both are
// ordinary functions that at_cli.exe can call with no game and no network.
//
// Providers currently declared (keep in sync with engines.FREE_PROVIDERS in Lua):
//   google_gtx   free, undocumented endpoint, returns raw UTF-8
//   mymemory     free public service, HTML-escapes its output
//   google_api   official Cloud Translation v2, needs an API key
#ifndef AT_ONLINE_H
#define AT_ONLINE_H

#include "at_api.h"

#ifdef __cplusplus
extern "C" {
#endif

// 1 when the provider is one we know how to talk to.
AT_API int at_online_provider_known(const char* provider);

// 1 when requests for this provider must carry a user supplied API key.
AT_API int at_online_needs_key(const char* provider);

// Host without the scheme ("translate.googleapis.com").
AT_API int at_online_host(const char* provider, char* out, int cap);

// Request path including the query string, with the text percent-encoded.
// `api_key` may be NULL for providers that do not need one.
AT_API int at_online_path(const char* provider, const char* api_key, const char* source_lang,
                          const char* target_lang, const char* text_utf8, char* out, int cap);

// Extracts the translated text from a successful response body.
// Returns the number of bytes written on success, or a negative value on failure
// (reason available from at_online_error()).
AT_API int at_online_parse(const char* provider, const char* body_utf8, char* out, int cap);

// Last parse failure, human readable. Never NULL.
AT_API const char* at_online_error(void);

// Maps an internal language code ("zh-cn", "pt-br") to the provider's spelling
// ("zh-CN", "pt-BR"). Returns 0 when the language is not supported.
AT_API int at_online_lang_code(const char* internal_lang, char* out, int cap);

#ifdef __cplusplus
}
#endif

#endif // AT_ONLINE_H
