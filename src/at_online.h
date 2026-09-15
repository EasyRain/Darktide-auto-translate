// at_online.h — online translation providers: request building and response parsing.
//
// Split into pure functions on purpose. Building a request URL and turning a
// response body into translated text are the two places provider quirks live
// (MyMemory returning Traditional Chinese for zh-CN, MyMemory HTML-escaping its
// output, Google splitting long text into several segments), so both are
// ordinary functions that at_cli.exe can call with no game and no network.
//
// Providers currently declared:
//   deepl        official API, POST, needs a key. Reachable from mainland China
//                (verified), which is why it is the default API provider.
//   google_api   official Cloud Translation v2, needs a key. Implemented, but
//                translation.googleapis.com is reset during the TLS handshake in
//                China (verified), so it only works behind a proxy.
//   google_clients5 / google_gtx / mymemory
//                the free public endpoints. Kept working for testing and for
//                anyone who wants them, but no longer offered in the options:
//                they get rate limited and blocked too easily to rely on.
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

// 1 when this provider sends its query in a POST body instead of the URL.
AT_API int at_online_uses_post(const char* provider);

// Host without the scheme. `api_key` decides nothing for most providers, but
// DeepL serves free and paid keys from different hosts, so it is needed here.
AT_API int at_online_host(const char* provider, const char* api_key, char* out, int cap);

// Request path. For providers that POST this is just the endpoint; the query goes
// into at_online_body().
AT_API int at_online_path(const char* provider, const char* api_key, const char* source_lang,
                          const char* target_lang, const char* text_utf8, char* out, int cap);

// Body for providers that POST (form encoded). Returns 1 on success.
AT_API int at_online_body(const char* provider, const char* source_lang, const char* target_lang,
                          const char* text_utf8, char* out, int cap);

// Extra header block ("Name: value\r\n") for this provider, e.g. DeepL's
// Authorization line. Returns 1 on success (empty string when none is needed).
AT_API int at_online_headers(const char* provider, const char* api_key, char* out, int cap);

// Content-Type for this provider's POST, or NULL when it does not POST.
AT_API const char* at_online_content_type(const char* provider);

// Extracts the translated text from a successful response body.
// Returns the number of bytes written on success, or a negative value on failure
// (reason available from at_online_error()).
AT_API int at_online_parse(const char* provider, const char* body_utf8, char* out, int cap);

// Last failure, human readable. Never NULL.
AT_API const char* at_online_error(void);

// Maps an internal language code ("zh-cn", "pt-br") to the provider's spelling.
// Providers disagree about this ("zh-CN" vs "ZH-HANS"), so it is per provider.
AT_API int at_online_lang_code_for(const char* provider, const char* internal_lang, char* out, int cap);

// Same, using the Google spelling. Kept for callers that only need that family.
AT_API int at_online_lang_code(const char* internal_lang, char* out, int cap);

#ifdef __cplusplus
}
#endif

#endif // AT_ONLINE_H
