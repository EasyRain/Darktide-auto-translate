// at_online.c — online provider request/response adapters. See at_online.h.
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "at_json.h"
#include "at_online.h"

static char g_error[512] = { 0 };

// Baidu signs every request with two values: an appid and a key. The key is the shared API key (so it
// travels the usual road); the appid is this one, and the path builder needs it, so it lives up here.
static char g_baidu_appid[64] = "";

static void set_error(const char* msg)
{
    strncpy_s(g_error, sizeof(g_error), msg ? msg : "", _TRUNCATE);
}

static void set_errorf(const char* fmt, const char* a, const char* b)
{
    _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, fmt, a ? a : "", b ? b : "");
}

const char* at_online_error(void)
{
    return g_error;
}

// ---------------------------------------------------------------------------
// Language codes
//
// Our internal codes are lower case and match the game's language ids; every
// provider wants its own spelling, and getting this wrong silently translates
// into the wrong language. DeepL for instance distinguishes Simplified and
// Traditional Chinese as ZH-HANS / ZH-HANT (ZH alone means "unspecified").
// ---------------------------------------------------------------------------
typedef struct {
    const char* internal;
    const char* google;
    const char* deepl;
    const char* bing;
    const char* yandex;
    const char* azure;
    const char* baidu;
} LangMap;

// The baidu column is NULL for Ukrainian on purpose, and this is not a disagreement with the vendor's
// table: that table does list ukr, and the user checked it. It is a measurement. The account we could test
// with (a free key from 2021) rejects ukr in *every* direction - en->ukr, zh->ukr, ukr->zh and the short
// en->uk all answered 58001 INVALID_TO_PARAM, while en->ru in the same session answered normally, so it is
// neither a language-pair restriction nor a spelling problem. Most likely the plan/product decides.
//
// A missing code makes at_online_lang_code_for fail, so the engine gives Ukrainian to another provider
// instead of spending a request that cannot work. A player whose plan does support it can put ukr back in
// this column - that is the whole change.
//
// The yandex column is empty for Traditional Chinese on purpose: measured 2026-10-10, that endpoint
// rejects every spelling of it (zh-TW, zh-tw, zh_tw, zh-Hant, zt: HTTP 400) and answers only zh. A
// missing code makes at_online_lang_code_for fail, which is exactly how providers_for() drops a
// provider for one language and keeps it for the rest.
static const LangMap LANG_MAP[] = {
    { "en",    "en",    "EN",      "en",      "en",      "en",      "en" },
    { "zh-cn", "zh-CN", "ZH-HANS", "zh-Hans", "zh",      "zh-Hans", "zh" },
    { "zh-tw", "zh-TW", "ZH-HANT", "zh-Hant", NULL,      "zh-Hant", "cht" },
    { "ja",    "ja",    "JA",      "ja",      "ja",      "ja",      "jp" },
    { "ko",    "ko",    "KO",      "ko",      "ko",      "ko",      "kor" },
    { "ru",    "ru",    "RU",      "ru",      "ru",      "ru",      "ru" },
    { "de",    "de",    "DE",      "de",      "de",      "de",      "de" },
    { "fr",    "fr",    "FR",      "fr",      "fr",      "fr",      "fra" },
    { "es",    "es",    "ES",      "es",      "es",      "es",      "spa" },
    { "it",    "it",    "IT",      "it",      "it",      "it",      "it" },
    { "pl",    "pl",    "PL",      "pl",      "pl",      "pl",      "pl" },
    { "pt-br", "pt-BR", "PT-BR",   "pt",      "pt",      "pt",      "pt" },
    { "uk",    "uk",    "UK",      "uk",      "uk",      "uk",      NULL  },
};

int at_online_lang_code_for(const char* provider, const char* internal_lang, char* out, int cap)
{
    size_t i;
    int deepl;
    int bing;
    int yandex;
    int azure;
    int baidu;

    if (!internal_lang || !out || cap <= 0) {
        return 0;
    }
    deepl = provider && _stricmp(provider, "deepl") == 0;
    bing = provider && _stricmp(provider, "bing") == 0;
    yandex = provider && _stricmp(provider, "yandex") == 0;
    azure = provider && _stricmp(provider, "azure") == 0;
    baidu = provider && _stricmp(provider, "baidu") == 0;

    for (i = 0; i < sizeof(LANG_MAP) / sizeof(LANG_MAP[0]); i++) {
        if (_stricmp(LANG_MAP[i].internal, internal_lang) == 0) {
            const char* code = yandex ? LANG_MAP[i].yandex
                                      : (bing ? LANG_MAP[i].bing
                                              : (deepl ? LANG_MAP[i].deepl
                                                       : (azure ? LANG_MAP[i].azure
                                                                : (baidu ? LANG_MAP[i].baidu
                                                                         : LANG_MAP[i].google))));
            if (!code) {
                // This provider does not offer this language at all; the caller treats it as a
                // provider that cannot be used for it.
                _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, "'%s' does not offer '%s'",
                            provider ? provider : "(null)", internal_lang);
                return 0;
            }
            strncpy_s(out, (size_t)cap, code, _TRUNCATE);
            return 1;
        }
    }
    return 0;
}

int at_online_lang_code(const char* internal_lang, char* out, int cap)
{
    return at_online_lang_code_for("google", internal_lang, out, cap);
}

// ---------------------------------------------------------------------------
// Percent encoding
//
// Everything except the unreserved set is escaped, so multi-byte UTF-8 text and
// '&', '|', '?' inside a mod string cannot break the query string.
// ---------------------------------------------------------------------------
static int url_encode(const char* src, char* out, int cap)
{
    static const char* hex = "0123456789ABCDEF";
    int used = 0;
    const unsigned char* p = (const unsigned char*)src;

    if (!src || !out || cap <= 0) {
        return 0;
    }

    for (; *p; p++) {
        unsigned char c = *p;
        int plain = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                    c == '-' || c == '_' || c == '.' || c == '~';
        if (plain) {
            if (used + 1 >= cap) {
                return 0;
            }
            out[used++] = (char)c;
        } else {
            if (used + 3 >= cap) {
                return 0;
            }
            out[used++] = '%';
            out[used++] = hex[(c >> 4) & 0xF];
            out[used++] = hex[c & 0xF];
        }
    }
    out[used] = 0;
    return 1;
}

// ---------------------------------------------------------------------------
// HTML entity decoding
//
// MyMemory and Google's Cloud API both escape their output ("&quot;", "&#39;").
// Left alone, the player sees &amp;#39; instead of an apostrophe.
// ---------------------------------------------------------------------------
static int entity_decode(const char* src, char* out, int cap)
{
    int used = 0;
    const char* p = src;

    if (!src || !out || cap <= 0) {
        return 0;
    }

    while (*p) {
        if (*p == '&') {
            const char* semi = strchr(p, ';');
            if (semi && (semi - p) <= 12) {
                char name[12];
                int n = (int)(semi - p) - 1;
                const char* replacement = NULL;
                char single[8];
                int single_len = 0;

                memcpy(name, p + 1, (size_t)n);
                name[n] = 0;

                if (_stricmp(name, "amp") == 0) {
                    replacement = "&";
                } else if (_stricmp(name, "quot") == 0) {
                    replacement = "\"";
                } else if (_stricmp(name, "apos") == 0 || _stricmp(name, "#39") == 0) {
                    replacement = "'";
                } else if (_stricmp(name, "lt") == 0) {
                    replacement = "<";
                } else if (_stricmp(name, "gt") == 0) {
                    replacement = ">";
                } else if (_stricmp(name, "nbsp") == 0) {
                    replacement = " ";
                } else if (name[0] == '#') {
                    unsigned int cp = 0;
                    int ok = 1;
                    if (name[1] == 'x' || name[1] == 'X') {
                        int i;
                        for (i = 2; name[i]; i++) {
                            char c = name[i];
                            cp <<= 4;
                            if (c >= '0' && c <= '9') {
                                cp |= (unsigned int)(c - '0');
                            } else if (c >= 'a' && c <= 'f') {
                                cp |= (unsigned int)(c - 'a' + 10);
                            } else if (c >= 'A' && c <= 'F') {
                                cp |= (unsigned int)(c - 'A' + 10);
                            } else {
                                ok = 0;
                                break;
                            }
                        }
                    } else {
                        int i;
                        for (i = 1; name[i]; i++) {
                            if (name[i] < '0' || name[i] > '9') {
                                ok = 0;
                                break;
                            }
                            cp = cp * 10 + (unsigned int)(name[i] - '0');
                        }
                    }
                    if (ok && cp > 0 && cp < 0x80) {
                        single[0] = (char)cp;
                        single_len = 1;
                    } else if (ok && cp >= 0x80 && cp <= 0x10FFFF) {
                        // re-encode as UTF-8
                        if (cp < 0x800) {
                            single[0] = (char)(0xC0 | (cp >> 6));
                            single[1] = (char)(0x80 | (cp & 0x3F));
                            single_len = 2;
                        } else if (cp < 0x10000) {
                            single[0] = (char)(0xE0 | (cp >> 12));
                            single[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
                            single[2] = (char)(0x80 | (cp & 0x3F));
                            single_len = 3;
                        } else {
                            single[0] = (char)(0xF0 | (cp >> 18));
                            single[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
                            single[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
                            single[3] = (char)(0x80 | (cp & 0x3F));
                            single_len = 4;
                        }
                    } else {
                        ok = 0;
                    }

                    if (ok) {
                        if (used + single_len + 1 >= cap) {
                            return 0;
                        }
                        memcpy(out + used, single, (size_t)single_len);
                        used += single_len;
                        p = semi + 1;
                        continue;
                    }
                }

                if (replacement) {
                    size_t rl = strlen(replacement);
                    if (used + (int)rl + 1 >= cap) {
                        return 0;
                    }
                    memcpy(out + used, replacement, rl);
                    used += (int)rl;
                    p = semi + 1;
                    continue;
                }
            }
        }

        if (used + 2 >= cap) {
            return 0;
        }
        out[used++] = *p++;
    }

    out[used] = 0;
    return 1;
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------
int at_online_provider_known(const char* provider)
{
    if (!provider) {
        return 0;
    }
    return _stricmp(provider, "deepl") == 0 ||
           _stricmp(provider, "google_api") == 0 ||
           _stricmp(provider, "google_clients5") == 0 ||
           _stricmp(provider, "google_gtx") == 0 ||
           _stricmp(provider, "bing") == 0 ||
           _stricmp(provider, "yandex") == 0 ||
           _stricmp(provider, "azure") == 0 ||
           _stricmp(provider, "baidu") == 0 ||
           _stricmp(provider, "mymemory") == 0;
}

int at_online_needs_key(const char* provider)
{
    return provider && (_stricmp(provider, "google_api") == 0 || _stricmp(provider, "deepl") == 0 ||
                        _stricmp(provider, "azure") == 0 || _stricmp(provider, "baidu") == 0);
}

int at_online_uses_post(const char* provider)
{
    return provider && (_stricmp(provider, "deepl") == 0 || _stricmp(provider, "bing") == 0 ||
                        _stricmp(provider, "yandex") == 0 || _stricmp(provider, "google_api") == 0 ||
                        _stricmp(provider, "azure") == 0 || _stricmp(provider, "baidu") == 0);
}

// ---------------------------------------------------------------------------
// Bing: a session token first, then the translation
// ---------------------------------------------------------------------------
// The keyless Microsoft endpoint is a two-step flow. https://cn.bing.com/translator carries
//
//     params_AbusePreventionHelper = [1789537836335,"GBaGdJt6oY...",3600000]
//     IG:"810EA0129C0F4C1E9A2E4B6D8F0A1B2C"
//
// and /ttranslatev3 wants the first two back as form fields and the IG in the query. One page
// load serves many translations - measured from a China residential IP: 15 requests at one per
// second, all accepted, with the same token still valid after 110 seconds - so the values are
// kept here and the Lua layer only asks for a refresh when a reply says the session expired.
//
// Which host to ask. Measured 2026-10-10 from two networks (China direct, Singapore through a
// proxy): cn.bing.com answers 301 to www.bing.com when the client is outside China, www.bing.com
// answers 302 to cn.bing.com when it is inside, and this farm host answered from both without a
// redirect. The core does not follow redirects (WinHTTP's default), so pinning either of the two
// market hosts breaks the other half of the world; pinning the farm host does not. cn.bing.com is
// kept as a fallback: a page whose parse fails advances the index, so a network that filters this
// host still gets a session on the next attempt.
//
// An earlier note here claimed www.bing.com returned a 0-byte 200. That was a probe that posted
// /ttranslatev3 back to the host it started from instead of the host that served the page, so the
// cookies and IG did not match. Sent to the host that answered, all three hosts return the same
// translation. The User-Agent, on the other hand, is real: without one every host answered 401, and
// with a browser one every host answered 200 (see the header the core sends in at_core.c).
static const char* const BING_HOSTS[] = { "www4.bing.com", "cn.bing.com" };
static int g_bing_host = 0;

static void bing_host_advance(void)
{
    g_bing_host = (g_bing_host + 1) % (int)(sizeof(BING_HOSTS) / sizeof(BING_HOSTS[0]));
}

// Yandex's keyless endpoint is the Android app's, and it wants a client id in the query. Nothing
// authenticates it - measured 2026-10-10, a fresh id per call answered fine on zh-cn and uk alike - but
// a stable one looks like an app install rather than a script, so it is generated once per run.
static const char* yandex_client_id(void)
{
    static char id[40];
    int i;

    if (id[0] == 0) {
        for (i = 0; i < 32; i++) {
            id[i] = "0123456789abcdef"[rand() % 16];
        }
        id[32] = 0;
    }
    return id;
}

static char g_bing_key[64];
static char g_bing_token[192];
static char g_bing_ig[64];

int at_online_bootstrap_needed(const char* provider)
{
    return provider && _stricmp(provider, "bing") == 0;
}

int at_online_bootstrap_ready(void)
{
    return g_bing_key[0] != 0 && g_bing_token[0] != 0 && g_bing_ig[0] != 0;
}

void at_online_bootstrap_clear(void)
{
    g_bing_key[0] = 0;
    g_bing_token[0] = 0;
    g_bing_ig[0] = 0;
}

// Copies [begin, end) into out, trimming the spaces and quotes the page wraps values in.
static int copy_span(const char* begin, const char* end, char* out, int cap)
{
    int n;

    if (!begin || !end || !out || cap <= 0 || end <= begin) {
        return 0;
    }
    while (begin < end && (*begin == ' ' || *begin == '\t' || *begin == '"')) {
        begin++;
    }
    while (end > begin && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '"')) {
        end--;
    }
    n = (int)(end - begin);
    if (n <= 0 || n >= cap) {
        return 0;
    }
    memcpy(out, begin, (size_t)n);
    out[n] = 0;
    return 1;
}

int at_online_bootstrap_path(const char* provider, char* out, int cap)
{
    if (!at_online_bootstrap_needed(provider)) {
        set_errorf("provider '%s' needs no session%s", provider ? provider : "(null)", "");
        return 0;
    }
    if (!out || cap <= 0) {
        set_error("missing argument");
        return 0;
    }
    strncpy_s(out, (size_t)cap, "/translator", _TRUNCATE);
    return 1;
}

int at_online_bootstrap_parse(const char* page_utf8)
{
    const char* abuse;
    const char* open;
    const char* comma;
    const char* first_quote;
    const char* second_quote;
    const char* ig;
    const char* ig_end;

    if (!page_utf8 || !*page_utf8) {
        set_error("bing's translator page was empty");
        bing_host_advance();
        return 0;
    }

    at_online_bootstrap_clear();

    abuse = strstr(page_utf8, "params_AbusePreventionHelper");
    if (!abuse) {
        // A redirect stub lands here too (the core does not follow redirects), which is exactly
        // when the other host is the right one to try.
        set_error("bing's page carried no session block (params_AbusePreventionHelper)");
        bing_host_advance();
        return 0;
    }
    open = strchr(abuse, '[');
    comma = open ? strchr(open, ',') : NULL;
    if (!comma || !copy_span(open + 1, comma, g_bing_key, (int)sizeof(g_bing_key))) {
        set_error("bing's session key could not be read");
        bing_host_advance();
        return 0;
    }
    first_quote = strchr(comma + 1, '"');
    second_quote = first_quote ? strchr(first_quote + 1, '"') : NULL;
    if (!second_quote ||
        !copy_span(first_quote + 1, second_quote, g_bing_token, (int)sizeof(g_bing_token))) {
        set_error("bing's session token could not be read");
        at_online_bootstrap_clear();
        bing_host_advance();
        return 0;
    }
    ig = strstr(abuse, "IG:\"");
    if (!ig) {
        ig = strstr(page_utf8, "IG:\"");
    }
    ig_end = ig ? strchr(ig + 4, '"') : NULL;
    if (!ig_end || !copy_span(ig + 4, ig_end, g_bing_ig, (int)sizeof(g_bing_ig))) {
        set_error("bing's session id (IG) could not be read");
        at_online_bootstrap_clear();
        bing_host_advance();
        return 0;
    }
    return 1;
}

// DeepL serves free and paid keys from different hosts. Free keys end in ":fx",
// which is what DeepL documents, so the suffix picks the host.
static const char* deepl_host(const char* api_key)
{
    size_t n;
    if (!api_key) {
        return "api-free.deepl.com";
    }
    n = strlen(api_key);
    if (n >= 3 && _stricmp(api_key + n - 3, ":fx") == 0) {
        return "api-free.deepl.com";
    }
    return "api.deepl.com";
}

int at_online_host(const char* provider, const char* api_key, char* out, int cap)
{
    const char* host = NULL;

    if (!provider || !out || cap <= 0) {
        return 0;
    }
    if (_stricmp(provider, "deepl") == 0) {
        host = deepl_host(api_key);
    } else if (_stricmp(provider, "google_clients5") == 0) {
        host = "clients5.google.com";
    } else if (_stricmp(provider, "google_gtx") == 0) {
        host = "translate.googleapis.com";
    } else if (_stricmp(provider, "baidu") == 0) {
        // The vendor's own demo uses api.fanyi.baidu.com; fanyi-api.baidu.com answers identically (both
        // were probed over HTTPS on 2026-10-12 and both returned Baidu's own 52003 for an unsigned
        // request), so this follows the demo.
        host = "api.fanyi.baidu.com";
    } else if (_stricmp(provider, "azure") == 0) {
        host = "api.cognitive.microsofttranslator.com";
    } else if (_stricmp(provider, "mymemory") == 0) {
        host = "api.mymemory.translated.net";
    } else if (_stricmp(provider, "bing") == 0) {
        // www4.bing.com by default; see BING_HOSTS above for why, and for the fallback.
        host = BING_HOSTS[g_bing_host];
    } else if (_stricmp(provider, "yandex") == 0) {
        host = "translate.yandex.net";
    } else if (_stricmp(provider, "google_api") == 0) {
        host = "translation.googleapis.com";
    } else {
        set_errorf("unknown provider '%s'%s", provider, "");
        return 0;
    }

    strncpy_s(out, (size_t)cap, host, _TRUNCATE);
    return 1;
}

int at_online_path(const char* provider, const char* api_key, const char* source_lang,
                   const char* target_lang, const char* text_utf8, char* out, int cap)
{
    char src[16];
    char dst[16];
    char* encoded;
    size_t need;
    int written = -1;

    if (!provider || !out || cap <= 0 || !text_utf8) {
        set_error("missing argument");
        return 0;
    }
    if (!at_online_lang_code_for(provider, source_lang ? source_lang : "en", src, (int)sizeof(src))) {
        set_errorf("unsupported source language '%s'%s", source_lang, "");
        return 0;
    }
    if (!at_online_lang_code_for(provider, target_lang, dst, (int)sizeof(dst))) {
        set_errorf("unsupported target language '%s'%s", target_lang, "");
        return 0;
    }

    // worst case every byte becomes %XX
    need = strlen(text_utf8) * 3 + 1;
    encoded = (char*)malloc(need);
    if (!encoded) {
        set_error("out of memory");
        return 0;
    }
    if (!url_encode(text_utf8, encoded, (int)need)) {
        free(encoded);
        set_error("text too long to encode");
        return 0;
    }

    if (_stricmp(provider, "deepl") == 0) {
        if (!api_key || !*api_key) {
            free(encoded);
            set_error("this provider needs an API key");
            return 0;
        }
        // The query travels in the POST body; see at_online_body().
        written = _snprintf_s(out, (size_t)cap, _TRUNCATE, "/v2/translate");
    } else if (_stricmp(provider, "google_clients5") == 0) {
        // The dictionary endpoint. Unlike the others it needs no dt= flag, and
        // "client=dict-chrome-ex" is what makes it answer with plain text.
        written = _snprintf_s(out, (size_t)cap, _TRUNCATE,
                              "/translate_a/t?client=dict-chrome-ex&sl=%s&tl=%s&q=%s",
                              src, dst, encoded);
    } else if (_stricmp(provider, "google_gtx") == 0) {
        // dt=t asks for the translated text; sl/tl pick the language pair.
        written = _snprintf_s(out, (size_t)cap, _TRUNCATE,
                              "/translate_a/single?client=gtx&sl=%s&tl=%s&dt=t&q=%s",
                              src, dst, encoded);
    } else if (_stricmp(provider, "mymemory") == 0) {
        written = _snprintf_s(out, (size_t)cap, _TRUNCATE,
                              "/get?q=%s&langpair=%s%%7C%s", encoded, src, dst);
    } else if (_stricmp(provider, "bing") == 0) {
        // The text and both languages travel in the body; the query carries the session id
        // and the vertical flag. `&&` is not a typo - it is what the web client sends.
        if (!at_online_bootstrap_ready()) {
            free(encoded);
            set_error("bing needs a session token before the first request");
            return 0;
        }
                              // `tone=Formal` on every request. The web client's tone selector (语气) offers standard /
        // informal / formal for every target language, and the tone changes the answer: measured on
        // the masked AutoMark tooltip ("Cancel the {2} mark ... {4}{5}Set to {0}0{1} to {3}.{6}..."),
        // the reply with no tone dropped the opening bracket of {0} in every round - and {0}0 puts the
        // token next to a literal digit, which is that string's fragile spot - while tone=Formal kept
        // every placeholder in five rounds of five. Only that spelling works: tone=standard/Standard
        // answer empty, lowercase `formal` lost a token once. Varying the IID (5021/5023/5024/5025/
        // 5028) changes nothing, so the tone is what the web client does differently here.
        written = _snprintf_s(out, (size_t)cap, _TRUNCATE,
                              "/ttranslatev3?isVertical=1&&IG=%s&IID=translator.5024.1&tone=Formal",
                              g_bing_ig);
    } else if (_stricmp(provider, "yandex") == 0) {
        // Yandex's keyless endpoint is the one its Android app uses: the client id goes in the query
        // (any hex id is accepted; a stable one looks like an app install), the direction is
        // "<source>-<target>", and the text travels in the body.
        written = _snprintf_s(out, (size_t)cap, _TRUNCATE,
                              "/api/v1/tr.json/translate?srv=android&id=%s-0-0&lang=%s-%s",
                              yandex_client_id(), src, dst);
    } else if (_stricmp(provider, "baidu") == 0) {
        // Every parameter rides in the query string and the body is empty, which is what the reference
        // client sends (requests.post(url, params=payload)); GET is the same parameter set and the
        // documented alternative, so this build uses the simpler road.
        //
        // The sign covers the *raw* text, not the percent-encoded form, and it is md5(appid + q + salt +
        // key) - so it cannot be a template and is computed here, where the text is known.
        char sign[33];
        char sign_input[1024];
        unsigned int salt = baidu_salt();

        if (!api_key || !*api_key) {
            free(encoded);
            set_error("this provider needs an API key");
            return 0;
        }
        if (!g_baidu_appid[0]) {
            free(encoded);
            set_error("Baidu needs an APP ID as well as its key");
            return 0;
        }
        _snprintf_s(sign_input, sizeof(sign_input), _TRUNCATE, "%s%s%u%s",
                    g_baidu_appid, text_utf8 ? text_utf8 : "", salt, api_key);
        if (strlen(g_baidu_appid) + (text_utf8 ? strlen(text_utf8) : 0) + strlen(api_key) + 16 >=
            sizeof(sign_input)) {
            free(encoded);
            set_error("the text is too long to sign");
            return 0;
        }
        at_online_md5_hex(sign_input, strlen(sign_input), sign);
        written = _snprintf_s(out, (size_t)cap, _TRUNCATE,
                              "/api/trans/vip/translate?q=%s&from=%s&to=%s&appid=%s&salt=%u&sign=%s",
                              encoded, src, dst, g_baidu_appid, salt, sign);
    } else if (_stricmp(provider, "azure") == 0) {
        // from and to live in the query string for api-version=3.0, never in the body; from is optional
        // (omitting it asks for auto-detection) and this build always sends it.
        written = _snprintf_s(out, (size_t)cap, _TRUNCATE,
                              "/translate?api-version=3.0&from=%s&to=%s", src, dst);
    } else if (_stricmp(provider, "google_api") == 0) {
        // Only the key is in the query string; q/source/target/format go in the body, which is how the
        // official client sends them and what lets a multi-text request repeat q= without a second shape.
        if (!api_key || !*api_key) {
            free(encoded);
            set_error("this provider needs an API key");
            return 0;
        }
        written = _snprintf_s(out, (size_t)cap, _TRUNCATE,
                              "/language/translate/v2?key=%s", api_key);
    } else {
        free(encoded);
        set_errorf("unknown provider '%s'%s", provider, "");
        return 0;
    }

    free(encoded);

    if (written < 0) {
        _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, "request path too long (buffer: %d bytes)", cap);
        return 0;
    }
    return 1;
}

// google_gtx answers with:
//   [[["译文","source",null,null,10],["more","source2",...]],null,"en",...]
// Long input is split into several segments, so all of them are concatenated.
static int parse_google_gtx(const char* body, char* out, int cap)
{
    JVal* root = json_parse(body);
    JVal* segments;
    int used = 0;
    int i;

    if (!root) {
        set_error("response was not valid JSON");
        return -1;
    }

    segments = json_at(root, 0);
    if (!segments) {
        json_free(root);
        set_error("the service returned no translation for this text");
        return -1;
    }
    if (segments->type == J_NULL) {
        // Google answers [null,null,"en",...] for text it declines to translate
        json_free(root);
        set_error("the service declined to translate this text");
        return -1;
    }
    if (segments->type != J_ARR) {
        json_free(root);
        set_error("unexpected response shape (expected an array of segments)");
        return -1;
    }

    for (i = 0; i < segments->count; i++) {
        const char* piece = json_str(json_at(json_at(segments, i), 0));
        size_t n;
        if (!piece) {
            continue;
        }
        n = strlen(piece);
        if (used + (int)n + 1 > cap) {
            json_free(root);
            set_error("translated text does not fit the output buffer");
            return -1;
        }
        memcpy(out + used, piece, n);
        used += (int)n;
    }

    json_free(root);

    if (used == 0) {
        set_error("response contained no translated text");
        return -1;
    }
    out[used] = 0;
    return used;
}

// mymemory:
//   {"responseData":{"translatedText":"..."},"responseStatus":200,"responseDetails":""}
//
// The trap: when MyMemory refuses a request it still reports responseStatus 200
// and puts the *error message* into responseData.translatedText, e.g.
//   "'XX-YY' IS AN INVALID TARGET LANGUAGE..."
//   "MYMEMORY WARNING: YOU USED ALL AVAILABLE FREE TRANSLATIONS FOR TODAY..."
// Storing that as a translation would look like a successful result and end up in
// the player's files, so refusals are detected explicitly.
// The fixed sentences MyMemory answers with when it refuses a request while still reporting
// responseStatus 200 and an empty responseDetails. Kept as a table because the service adds
// one now and then, and matched case-insensitively because it is not consistent about case.
//
// The first entry is a prefix match ("MYMEMORY WARNING: ..." carries the reason after the
// colon); the rest are substrings, since the message is wrapped in quotes and language codes.
static const char* MYMEMORY_REFUSAL_PHRASES[] = {
    "MYMEMORY WARNING",
    "IS AN INVALID TARGET LANGUAGE",
    "IS AN INVALID SOURCE LANGUAGE",
    "YOU USED ALL AVAILABLE FREE TRANSLATIONS",
    "QUERY LENGTH LIMIT EXCEEDED",
    "PLEASE SELECT TWO DISTINCT LANGUAGES",   // source == target: it echoes this instead
    "NO QUERY SPECIFIED",
    "AUTHENTICATION FAILED",
};

static const char* contains_nocase(const char* haystack, const char* needle)
{
    size_t n = strlen(needle);
    const char* p;

    if (n == 0 || !haystack) {
        return NULL;
    }
    for (p = haystack; *p; p++) {
        if (_strnicmp(p, needle, n) == 0) {
            return p;
        }
    }
    return NULL;
}

static int mymemory_text_looks_like_a_refusal(const char* text)
{
    size_t i;

    if (!text) {
        return 0;
    }
    for (i = 0; i < sizeof(MYMEMORY_REFUSAL_PHRASES) / sizeof(MYMEMORY_REFUSAL_PHRASES[0]); i++) {
        if (contains_nocase(text, MYMEMORY_REFUSAL_PHRASES[i])) {
            return 1;
        }
    }
    return 0;
}

static int parse_mymemory(const char* body, char* out, int cap)
{
    JVal* root = json_parse(body);
    JVal* data;
    JVal* quota;
    const char* text;
    const char* details;
    int status;
    char decoded[8192];
    int n;

    if (!root) {
        set_error("response was not valid JSON");
        return -1;
    }

    status = json_int(json_get(root, "responseStatus"), 200);
    details = json_str(json_get(root, "responseDetails"));
    quota = json_get(root, "quotaFinished");
    data = json_get(root, "responseData");
    text = data ? json_str(json_get(data, "translatedText")) : NULL;

    if (status != 200) {
        set_errorf("service refused the request: %s%s",
                   (details && *details) ? details : "no reason given", "");
        json_free(root);
        return -1;
    }
    if (quota && quota->type == J_BOOL && quota->bval) {
        set_error("the free daily quota for this service is exhausted");
        json_free(root);
        return -1;
    }
    if (!text || !*text) {
        set_errorf("service returned no text: %s%s",
                   (details && *details) ? details : "no reason given", "");
        json_free(root);
        return -1;
    }
    if (mymemory_text_looks_like_a_refusal(text)) {
        char message[256];
        _snprintf_s(message, sizeof(message), _TRUNCATE, "%.200s", text);
        json_free(root);
        set_errorf("service refused the request: %s%s", message, "");
        return -1;
    }

    json_free(root);

    if (cap <= 0 || (int)strlen(text) >= (int)sizeof(decoded)) {
        set_error("translated text does not fit the output buffer");
        return -1;
    }
    if (!entity_decode(text, decoded, (int)sizeof(decoded))) {
        set_error("could not decode the translated text");
        return -1;
    }
    n = (int)strlen(decoded);
    if (n >= cap) {
        set_error("translated text does not fit the output buffer");
        return -1;
    }
    memcpy(out, decoded, (size_t)n + 1);
    return n;
}

// ----------------------------------------------------------------------
// MD5, for a provider that signs each request (Baidu: md5(appid + text + salt + key)).
//
// Lua has no hash and the sign covers the text, so it cannot be a fixed template - which is why this
// lives here rather than in modules/services.lua. It is a plain RFC 1321 implementation, and the
// selftest checks it against the RFC's own vectors through the signed path it exists for.
// ----------------------------------------------------------------------
void at_online_md5_hex(const void* data, size_t len, char out[33])
{
    static const unsigned int S[64] = {
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
    };
    static const unsigned int K[64] = {
        0xd76aa478u, 0xe8c7b756u, 0x242070dbu, 0xc1bdceeeu, 0xf57c0fafu, 0x4787c62au, 0xa8304613u, 0xfd469501u,
        0x698098d8u, 0x8b44f7afu, 0xffff5bb1u, 0x895cd7beu, 0x6b901122u, 0xfd987193u, 0xa679438eu, 0x49b40821u,
        0xf61e2562u, 0xc040b340u, 0x265e5a51u, 0xe9b6c7aau, 0xd62f105du, 0x02441453u, 0xd8a1e681u, 0xe7d3fbc8u,
        0x21e1cde6u, 0xc33707d6u, 0xf4d50d87u, 0x455a14edu, 0xa9e3e905u, 0xfcefa3f8u, 0x676f02d9u, 0x8d2a4c8au,
        0xfffa3942u, 0x8771f681u, 0x6d9d6122u, 0xfde5380cu, 0xa4beea44u, 0x4bdecfa9u, 0xf6bb4b60u, 0xbebfbc70u,
        0x289b7ec6u, 0xeaa127fau, 0xd4ef3085u, 0x04881d05u, 0xd9d4d039u, 0xe6db99e5u, 0x1fa27cf8u, 0xc4ac5665u,
        0xf4292244u, 0x432aff97u, 0xab9423a7u, 0xfc93a039u, 0x655b59c3u, 0x8f0ccc92u, 0xffeff47du, 0x85845dd1u,
        0x6fa87e4fu, 0xfe2ce6e0u, 0xa3014314u, 0x4e0811a1u, 0xf7537e82u, 0xbd3af235u, 0x2ad7d2bbu, 0xeb86d391u
    };
    unsigned int h[4] = { 0x67452301u, 0xefcdab89u, 0x98badcfeu, 0x10325476u };
    unsigned char block[64];
    unsigned long long bits = (unsigned long long)len * 8ull;
    size_t offset;
    int i;

    for (offset = 0; offset + 64 <= len; offset += 64) {
        memcpy(block, (const unsigned char*)data + offset, 64);
        goto compress;   /* the loop body below is shared with the tail */
    compress:
        {
            unsigned int m[16];
            unsigned int a = h[0], b = h[1], c = h[2], d = h[3];
            for (i = 0; i < 16; i++) {
                m[i] = (unsigned int)block[i * 4] | ((unsigned int)block[i * 4 + 1] << 8) |
                       ((unsigned int)block[i * 4 + 2] << 16) | ((unsigned int)block[i * 4 + 3] << 24);
            }
            for (i = 0; i < 64; i++) {
                unsigned int f, g, tmp;
                if (i < 16) {
                    f = (b & c) | (~b & d);
                    g = (unsigned int)i;
                } else if (i < 32) {
                    f = (d & b) | (~d & c);
                    g = (unsigned int)(5 * i + 1) % 16u;
                } else if (i < 48) {
                    f = b ^ c ^ d;
                    g = (unsigned int)(3 * i + 5) % 16u;
                } else {
                    f = c ^ (b | ~d);
                    g = (unsigned int)(7 * i) % 16u;
                }
                tmp = d;
                d = c;
                c = b;
                f = a + f + K[i] + m[g];
                b = b + ((f << S[i]) | (f >> (32 - S[i])));
                a = tmp;
            }
            h[0] += a; h[1] += b; h[2] += c; h[3] += d;
        }
    }

    {
        unsigned char tail[128];
        size_t rest = len - offset;
        unsigned int m[16];
        unsigned int a, b, c, d;
        size_t total;

        memset(tail, 0, sizeof(tail));
        if (rest) {
            memcpy(tail, (const unsigned char*)data + offset, rest);
        }
        tail[rest] = 0x80;
        total = (rest + 1 <= 56) ? 64 : 128;
        tail[total - 8] = (unsigned char)(bits & 0xff);
        tail[total - 7] = (unsigned char)((bits >> 8) & 0xff);
        tail[total - 6] = (unsigned char)((bits >> 16) & 0xff);
        tail[total - 5] = (unsigned char)((bits >> 24) & 0xff);
        tail[total - 4] = (unsigned char)((bits >> 32) & 0xff);
        tail[total - 3] = (unsigned char)((bits >> 40) & 0xff);
        tail[total - 2] = (unsigned char)((bits >> 48) & 0xff);
        tail[total - 1] = (unsigned char)((bits >> 56) & 0xff);

        for (offset = 0; offset < total; offset += 64) {
            a = h[0]; b = h[1]; c = h[2]; d = h[3];
            for (i = 0; i < 16; i++) {
                m[i] = (unsigned int)tail[offset + i * 4] | ((unsigned int)tail[offset + i * 4 + 1] << 8) |
                       ((unsigned int)tail[offset + i * 4 + 2] << 16) | ((unsigned int)tail[offset + i * 4 + 3] << 24);
            }
            for (i = 0; i < 64; i++) {
                unsigned int f, g, tmp;
                if (i < 16) { f = (b & c) | (~b & d); g = (unsigned int)i; }
                else if (i < 32) { f = (d & b) | (~d & c); g = (unsigned int)(5 * i + 1) % 16u; }
                else if (i < 48) { f = b ^ c ^ d; g = (unsigned int)(3 * i + 5) % 16u; }
                else { f = c ^ (b | ~d); g = (unsigned int)(7 * i) % 16u; }
                tmp = d; d = c; c = b;
                f = a + f + K[i] + m[g];
                b = b + ((f << S[i]) | (f >> (32 - S[i])));
                a = tmp;
            }
            h[0] += a; h[1] += b; h[2] += c; h[3] += d;
        }
    }

    for (i = 0; i < 4; i++) {
        _snprintf_s(out + i * 8, 9, _TRUNCATE, "%02x%02x%02x%02x",
                    (unsigned)(h[i] & 0xff), (unsigned)((h[i] >> 8) & 0xff),
                    (unsigned)((h[i] >> 16) & 0xff), (unsigned)((h[i] >> 24) & 0xff));
    }
    out[32] = 0;
}

// baidu: {"from":"en","to":"zh","trans_result":[{"src":"hello","dst":"你好"}]}
//
// Two things make this one different from every other provider here: a refusal arrives with HTTP 200 and
// an error_code in the body (so the body has to be read for a status, like yandex), and error_code is a
// *string* in the client's own fixture ("54001") while being a number in older replies - so both are read.
static int parse_baidu(const char* body, char* out, int cap)
{
    JVal* root = json_parse(body);
    JVal* err;
    JVal* node;
    const char* text;
    const char* message;
    const char* code;
    int numeric;
    int n;

    if (!root) {
        set_error("response was not valid JSON");
        return -1;
    }

    err = json_get(root, "error_code");
    if (err) {
        code = json_str(err);
        numeric = json_int(err, 0);
        message = json_str(json_get(root, "error_msg"));
        if (code && *code) {
            _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, "Baidu error %s: %s",
                        code, message ? message : "no message");
        } else {
            _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, "Baidu error %d: %s",
                        numeric, message ? message : "no message");
        }
        json_free(root);
        return -1;
    }

    node = json_path(root, "trans_result.0.dst");
    text = json_str(node);
    if (!text || !*text) {
        set_error("response carried no translated text");
        json_free(root);
        return -1;
    }
    n = (int)strlen(text);
    if (n >= cap) {
        set_error("translated text does not fit the output buffer");
        json_free(root);
        return -1;
    }
    memcpy(out, text, (size_t)n + 1);
    json_free(root);
    return n;
}

// azure: a *bare* array (no wrapper), one object per input, in request order:
//   [{"translations":[{"text":"...","to":"zh-Hans"}]}]
//
// A JSON object instead of an array means the service refused: {"error":{"code":401000,"message":"..."}}.
// The code is stable and machine-readable, which is why it leads the message the player is shown.
static int parse_azure(const char* body, char* out, int cap)
{
    JVal* root = json_parse(body);
    JVal* err;
    JVal* node;
    const char* text;
    const char* message;
    int code;
    int n;

    if (!root) {
        set_error("response was not valid JSON");
        return -1;
    }

    err = json_get(root, "error");
    if (err) {
        code = json_int(json_get(err, "code"), 0);
        message = json_str(json_get(err, "message"));
        _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, "Azure error %d: %s",
                    code, message ? message : "no message");
        json_free(root);
        return -1;
    }

    node = json_path(root, "0.translations.0.text");
    text = json_str(node);
    if (!text || !*text) {
        set_error("response carried no translated text");
        json_free(root);
        return -1;
    }
    n = (int)strlen(text);
    if (n >= cap) {
        set_error("translated text does not fit the output buffer");
        json_free(root);
        return -1;
    }
    memcpy(out, text, (size_t)n + 1);
    json_free(root);
    return n;
}

// google_api:
//   {"data":{"translations":[{"translatedText":"..."}]}}
// {"code":200,"lang":"en-uk","nmt_code":200,"text":["\u041f\u043e\u043a\u0430\u0437\u0430\u0442\u0438 ..."]}
//
// The endpoint puts its own status in the body, so a code that is not 200 is the service refusing the
// request and must not be read as a translation. `text` is an array because the request may carry
// several strings (this build sends one - see at_online_supports_multi_text).
// Azure dresses the same text as JSON, so the body needs escaping rather than form encoding.
//
// Control characters use JSON's short escapes where it has them and \u00XX otherwise; UTF-8 passes through
// untouched, which is what the API wants (Content-Type says charset=UTF-8).
static int json_escape_into(const char* in, char* out, int cap)
{
    const unsigned char* p = (const unsigned char*)in;
    int used = 0;

    if (!in || !out || cap <= 0) {
        return 0;
    }
    for (; *p; p++) {
        const char* esc = NULL;
        char buf[8];
        switch (*p) {
        case '"':  esc = "\\\""; break;
        case '\\': esc = "\\\\"; break;
        case '\n': esc = "\\n"; break;
        case '\r': esc = "\\r"; break;
        case '\t': esc = "\\t"; break;
        case '\b': esc = "\\b"; break;
        case '\f': esc = "\\f"; break;
        default:
            if (*p < 0x20) {
                _snprintf_s(buf, sizeof(buf), _TRUNCATE, "\\u%04x", (unsigned)*p);
                esc = buf;
            }
            break;
        }
        if (esc) {
            size_t n = strlen(esc);
            if (used + (int)n + 1 > cap) {
                return 0;
            }
            memcpy(out + used, esc, n);
            used += (int)n;
        } else {
            if (used + 2 > cap) {
                return 0;
            }
            out[used++] = (char)*p;
        }
    }
    out[used] = 0;
    return 1;
}

// The region of the caller's Translator resource. It is part of the request, so it is set once next to the
// key rather than threaded through every builder; an empty one simply omits the header (a global resource
// does not need it, and sending it would be harmless either way).
static char g_azure_region[64] = "";

void at_online_set_appid(const char* appid)
{
    if (!appid) {
        g_baidu_appid[0] = 0;
        return;
    }
    _snprintf_s(g_baidu_appid, sizeof(g_baidu_appid), _TRUNCATE, "%s", appid);
}

void at_online_set_region(const char* region)
{
    if (!region) {
        g_azure_region[0] = 0;
        return;
    }
    _snprintf_s(g_azure_region, sizeof(g_azure_region), _TRUNCATE, "%s", region);
}

// Baidu wants a "salt" in the sign so the same text does not produce the same signature every time.
// Its value is not a secret and nothing verifies it; the reference client uses random.randint(32768,
// 65536), so the clock is as good as anything.
static unsigned int baidu_salt(void)
{
    return ((unsigned int)time(NULL) % 32769u) + 32768u;
}

// google_api: the parameters the path no longer carries.
//
// q is the text, already percent-encoded by the caller; format=text keeps the reply plain rather than
// HTML-escaped, which is the documented default otherwise.
static int body_google_api(const char* encoded, const char* src, const char* dst, char* out, int cap)
{
    int written = _snprintf_s(out, (size_t)cap, _TRUNCATE,
                              "q=%s&source=%s&target=%s&format=text", encoded, src, dst);
    if (written < 0) {
        _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, "request body too long (buffer: %d bytes)", cap);
        return -1;
    }
    return written;
}

static int parse_yandex(const char* body, char* out, int cap)
{
    JVal* root = json_parse(body);
    JVal* texts;
    const char* first;
    int code;
    int n;

    if (!root) {
        set_error("response was not valid JSON");
        return -1;
    }
    code = json_int(json_get(root, "code"), 200);
    if (code != 200) {
        _snprintf_s(g_error, sizeof(g_error), _TRUNCATE,
                    "service refused the request (code %d)", code);
        json_free(root);
        return -1;
    }
    texts = json_get(root, "text");
    first = texts ? json_str(json_at(texts, 0)) : NULL;
    if (!first || !*first) {
        json_free(root);
        set_error("the service returned no translation for this text");
        return -1;
    }
    n = entity_decode(first, out, cap);
    if (n <= 0) {
        json_free(root);
        set_error("translated text does not fit the output buffer");
        return -1;
    }
    json_free(root);
    return n;
}

static int parse_google_api(const char* body, char* out, int cap)
{
    JVal* root = json_parse(body);
    JVal* err;
    JVal* node;
    const char* text;
    const char* message;
    char decoded[8192];
    int n;

    if (!root) {
        set_error("response was not valid JSON");
        return -1;
    }

    err = json_get(root, "error");
    if (err) {
        message = json_str(json_get(err, "message"));
        set_errorf("API error: %s%s", message ? message : "unknown", "");
        json_free(root);
        return -1;
    }

    node = json_path(root, "data.translations.0.translatedText");
    text = json_str(node);
    if (!text || !*text) {
        set_error("response contained no translated text");
        json_free(root);
        return -1;
    }

    json_free(root);

    if (cap <= 0 || (int)strlen(text) >= (int)sizeof(decoded)) {
        set_error("translated text does not fit the output buffer");
        return -1;
    }
    if (!entity_decode(text, decoded, (int)sizeof(decoded))) {
        set_error("could not decode the translated text");
        return -1;
    }
    n = (int)strlen(decoded);
    if (n >= cap) {
        set_error("translated text does not fit the output buffer");
        return -1;
    }
    memcpy(out, decoded, (size_t)n + 1);
    return n;
}

// clients5.google.com answers with one of two shapes depending on sl:
//   sl=en  -> ["译文"]                 (flat)
//   sl=auto-> [["译文","de"]]          (the detected language rides along)
// Both are accepted; a long input still comes back as a single string.
static int parse_google_clients5(const char* body, char* out, int cap)
{
    JVal* root = json_parse(body);
    int used = 0;
    int i;

    if (!root) {
        set_error("response was not valid JSON");
        return -1;
    }
    if (root->type != J_ARR) {
        // an error body arrives as an object; surface something useful
        json_free(root);
        set_error("unexpected response shape (expected an array)");
        return -1;
    }

    for (i = 0; i < root->count; i++) {
        JVal* item = json_at(root, i);
        const char* piece = json_str(item);

        if (!piece) {
            piece = json_str(json_at(item, 0)); // the sl=auto form
        }
        if (!piece) {
            continue;
        }

        {
            size_t n = strlen(piece);
            if (used + (int)n + 1 > cap) {
                json_free(root);
                set_error("translated text does not fit the output buffer");
                return -1;
            }
            memcpy(out + used, piece, n);
            used += (int)n;
        }
    }

    json_free(root);

    if (used == 0) {
        set_error("response contained no translated text");
        return -1;
    }
    out[used] = 0;
    return used;
}

// ---------------------------------------------------------------------------
// POST support (DeepL)
// ---------------------------------------------------------------------------
int at_online_body(const char* provider, const char* source_lang, const char* target_lang,
                   const char* text_utf8, char* out, int cap)
{
    char src[16];
    char dst[16];
    char* encoded;
    size_t need;
    int written;

    if (!provider || !out || cap <= 0 || !text_utf8) {
        set_error("missing argument");
        return 0;
    }
    if (_stricmp(provider, "deepl") != 0 && _stricmp(provider, "bing") != 0 &&
        _stricmp(provider, "yandex") != 0 && _stricmp(provider, "google_api") != 0 &&
        _stricmp(provider, "azure") != 0 && _stricmp(provider, "baidu") != 0) {
        set_errorf("provider '%s' does not use a request body%s", provider, "");
        return 0;
    }
    if (!at_online_lang_code_for(provider, source_lang ? source_lang : "en", src, (int)sizeof(src))) {
        set_errorf("unsupported source language '%s'%s", source_lang, "");
        return 0;
    }
    if (!at_online_lang_code_for(provider, target_lang, dst, (int)sizeof(dst))) {
        set_errorf("unsupported target language '%s'%s", target_lang, "");
        return 0;
    }

    need = strlen(text_utf8) * 3 + 1;
    encoded = (char*)malloc(need);
    if (!encoded) {
        set_error("out of memory");
        return 0;
    }
    if (!url_encode(text_utf8, encoded, (int)need)) {
        free(encoded);
        set_error("text too long to encode");
        return 0;
    }

    if (_stricmp(provider, "baidu") == 0) {
        // The vendor's own demo posts with every parameter in the query string and no body at all
        // (requests.post(url, params=payload)), so this is that request.
        out[0] = 0;
        return 1;
    }

    if (_stricmp(provider, "azure") == 0) {
        // A JSON array even for one string; the reference is explicit that the body is an array.
        char escaped[8192];
        free(encoded);
        if (!json_escape_into(text_utf8, escaped, (int)sizeof(escaped))) {
            set_error("the text is too long to escape");
            return 0;
        }
        written = _snprintf_s(out, (size_t)cap, _TRUNCATE, "[{\"Text\":\"%s\"}]", escaped);
        if (written < 0) {
            _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, "request body too long (buffer: %d bytes)", cap);
            return 0;
        }
        return 1;
    }

    if (_stricmp(provider, "bing") == 0) {
        if (!at_online_bootstrap_ready()) {
            free(encoded);
            set_error("bing needs a session token before the first request");
            return 0;
        }
        // Bing spells the source as fromLang (empty means "detect"), and it is happy to be
        // told the language rather than guess.
        written = _snprintf_s(out, (size_t)cap, _TRUNCATE,
                              "text=%s&fromLang=%s&to=%s&token=%s&key=%s",
                              encoded, src, dst, g_bing_token, g_bing_key);
    } else if (_stricmp(provider, "google_api") == 0) {
        written = body_google_api(encoded, src, dst, out, cap);
    } else if (_stricmp(provider, "yandex") == 0) {
        // Yandex takes the direction in the query and only the text in the body. The parameter can be
        // repeated to send several strings at once (the reply is an array), but this build sends one
        // at a time until that is measured - see at_online_supports_multi_text.
        written = _snprintf_s(out, (size_t)cap, _TRUNCATE, "text=%s", encoded);
    } else {
        written = _snprintf_s(out, (size_t)cap, _TRUNCATE,
                              "text=%s&source_lang=%s&target_lang=%s", encoded, src, dst);
    }
    free(encoded);

    if (written < 0) {
        _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, "request body too long (buffer: %d bytes)", cap);
        return 0;
    }
    return 1;
}

// One request, several strings - the way DeepL's API is meant to be used.
//
// Batching in the Lua layer joins short labels into one text with [n] markers, which costs a few
// characters per label (billed, on a service that charges per character) and relies on the
// service copying the markers back. DeepL takes the same parameter repeatedly instead
// (text=a&text=b&...) and answers with one translations[i] per input, so for that provider the
// markers are unnecessary. Providers without such a form (Google's undocumented hosts, MyMemory,
// a custom endpoint) return 0 here and keep the marker path - which is what makes the two
// mechanisms interchangeable rather than a special case per provider.
//
// Returns 1 with the body in `out`, 0 when this provider has no multi-text form (the caller then
// batches the marker way). More than a handful of strings is refused: the request is a form body,
// and the point of batching here is the round trip, not a megabyte of parameters.
#define AT_MULTI_TEXT_MAX 16

int at_online_body_multi(const char* provider, const char* source_lang, const char* target_lang,
                         const char** texts, int count, char* out, int cap)
{
    char src[16];
    char dst[16];
    int i;
    int used;
    int written;

    if (!provider || !texts || !out || cap <= 0) {
        set_error("missing argument");
        return 0;
    }
    if (_stricmp(provider, "deepl") != 0 && _stricmp(provider, "google_api") != 0 &&
        _stricmp(provider, "azure") != 0) {
        set_errorf("provider '%s' has no multi-text request form%s", provider, "");
        return 0;
    }
    if (count < 1 || count > AT_MULTI_TEXT_MAX) {
        // set_errorf() formats two *strings*; anything with a number goes through g_error.
        _snprintf_s(g_error, sizeof(g_error), _TRUNCATE,
                    "multi-text count %d is out of range (1..%d)", count, AT_MULTI_TEXT_MAX);
        return 0;
    }
    if (!at_online_lang_code_for(provider, source_lang ? source_lang : "en", src, (int)sizeof(src))) {
        set_errorf("unsupported source language '%s'%s", source_lang, "");
        return 0;
    }
    if (!at_online_lang_code_for(provider, target_lang, dst, (int)sizeof(dst))) {
        set_errorf("unsupported target language '%s'%s", target_lang, "");
        return 0;
    }

    out[0] = 0;
    used = 0;

    if (_stricmp(provider, "azure") == 0) {
        // A JSON array of objects, one per text, in the order they were given. Azure documents that the
        // reply comes back in that same order, which is what lets the caller read it by index.
        char escaped[8192];

        for (i = 0; i < count; i++) {
            if (!json_escape_into(texts[i], escaped, (int)sizeof(escaped))) {
                set_error("a text is too long to escape");
                return 0;
            }
            written = _snprintf_s(out + used, (size_t)(cap - used), _TRUNCATE,
                                  i == 0 ? "[{\"Text\":\"%s\"}" : ",{\"Text\":\"%s\"}", escaped);
            if (written < 0) {
                _snprintf_s(g_error, sizeof(g_error), _TRUNCATE,
                            "request body too long (buffer: %d bytes)", cap);
                return 0;
            }
            used += written;
        }
        if (_snprintf_s(out + used, (size_t)(cap - used), _TRUNCATE, "]") < 0) {
            _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, "request body too long (buffer: %d bytes)", cap);
            return 0;
        }
        return 1;
    }

    for (i = 0; i < count; i++) {
        const char* text = texts[i] ? texts[i] : "";
        size_t need = strlen(text) * 3 + 1;
        char* encoded = (char*)malloc(need);
        int written;

        if (!encoded) {
            set_error("out of memory");
            return 0;
        }
        if (!url_encode(text, encoded, (int)need)) {
            free(encoded);
            set_error("text too long to encode");
            return 0;
        }
        written = _snprintf_s(out + used, (size_t)(cap - used), _TRUNCATE,
                              _stricmp(provider, "google_api") == 0 ? "q=%s&" : "text=%s&", encoded);
        free(encoded);
        if (written < 0) {
            _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, "request body too long (buffer: %d bytes)", cap);
            return 0;
        }
        used += written;
    }

    // The tail differs by spelling: DeepL wants source_lang/target_lang, Google v2 wants source/target
    // plus format=text (html is its documented default).
    if (_snprintf_s(out + used, (size_t)(cap - used), _TRUNCATE,
                    _stricmp(provider, "google_api") == 0
                        ? "source=%s&target=%s&format=text"
                        : "source_lang=%s&target_lang=%s", src, dst) < 0) {
        _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, "request body too long (buffer: %d bytes)", cap);
        return 0;
    }
    return 1;
}

// Whether this provider has a multi-text request form (see at_online_body_multi). The Lua layer
// asks instead of hard-coding a provider name: which services ship is the core's business.
int at_online_supports_multi_text(const char* provider)
{
    return provider && (_stricmp(provider, "deepl") == 0 || _stricmp(provider, "google_api") == 0 ||
                        _stricmp(provider, "azure") == 0);
}

// Which browser each service is told we are. Not decoration: Bing's keyless translator answers HTTP
// 401 to a request whose User-Agent looks like a script and 200 to a browser's (measured 2026-10-10 on
// all three of its hosts, from China and from outside it). Beyond that, each of these is the vendor
// feeding its own browser's traffic best - Edge for Microsoft, Chrome for Google - which costs nothing
// to send and may matter to a service that sorts requests by client.
static const char* UA_EDGE =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0";
static const char* UA_CHROME =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/131.0.0.0 Safari/537.36";

const char* at_online_user_agent(const char* provider)
{
    if (provider && _stricmp(provider, "bing") == 0) {
        return UA_EDGE;
    }
    return UA_CHROME;
}

int at_online_headers(const char* provider, const char* api_key, char* out, int cap)
{
    if (!provider || !out || cap <= 0) {
        set_error("missing argument");
        return 0;
    }
    out[0] = 0;

    if (_snprintf_s(out, (size_t)cap, _TRUNCATE, "User-Agent: %s\r\n", at_online_user_agent(provider)) < 0) {
        set_error("the user agent is too long for a header");
        return 0;
    }

    if (_stricmp(provider, "azure") == 0) {
        if (!api_key || !*api_key) {
            set_error("this provider needs an API key");
            return 0;
        }
        if (strlen(out) + strlen(api_key) + 80 > (size_t)cap ||
            _snprintf_s(out + strlen(out), (size_t)cap - strlen(out), _TRUNCATE,
                        "Ocp-Apim-Subscription-Key: %s\r\n", api_key) < 0) {
            set_error("API key is too long for a header");
            return 0;
        }
        // Optional for a global resource, required for a multi-service or regional one, and harmless
        // either way - so it is sent whenever the player supplied one.
        if (g_azure_region[0] &&
            (strlen(out) + strlen(g_azure_region) + 80 > (size_t)cap ||
             _snprintf_s(out + strlen(out), (size_t)cap - strlen(out), _TRUNCATE,
                         "Ocp-Apim-Subscription-Region: %s\r\n", g_azure_region) < 0)) {
            set_error("the region is too long for a header");
            return 0;
        }
    }

    if (_stricmp(provider, "deepl") == 0) {
        if (!api_key || !*api_key) {
            set_error("this provider needs an API key");
            return 0;
        }
        if (strlen(out) + strlen(api_key) + 40 > (size_t)cap ||
            _snprintf_s(out + strlen(out), (size_t)cap - strlen(out), _TRUNCATE,
                        "Authorization: DeepL-Auth-Key %s\r\n", api_key) < 0) {
            set_error("API key is too long for a header");
            return 0;
        }
    }
    return 1;
}

const char* at_online_content_type(const char* provider)
{
    if (provider && (_stricmp(provider, "deepl") == 0 || _stricmp(provider, "bing") == 0 ||
                     _stricmp(provider, "yandex") == 0 || _stricmp(provider, "google_api") == 0 ||
                     _stricmp(provider, "baidu") == 0)) {
        return "application/x-www-form-urlencoded";
    }
    // Azure accepts exactly this, and answers 415000 without it.
    if (provider && _stricmp(provider, "azure") == 0) {
        return "application/json; charset=UTF-8";
    }
    return NULL;
}

// deepl: {"translations":[{"detected_source_language":"EN","text":"..."}]}
static int parse_deepl(const char* body, char* out, int cap)
{
    JVal* root = json_parse(body);
    const char* message;
    const char* text;
    int n;

    if (!root) {
        set_error("response was not valid JSON");
        return -1;
    }

    // errors arrive as {"message":"..."} with a 4xx status
    message = json_str(json_get(root, "message"));
    if (message && *message) {
        set_errorf("API error: %s%s", message, "");
        json_free(root);
        return -1;
    }

    text = json_str(json_path(root, "translations.0.text"));
    if (!text || !*text) {
        set_error("response contained no translated text");
        json_free(root);
        return -1;
    }

    n = (int)strlen(text);
    if (n >= cap) {
        json_free(root);
        set_error("translated text does not fit the output buffer");
        return -1;
    }
    memcpy(out, text, (size_t)n + 1);
    json_free(root);
    return n;
}

// One answer out of a multi-text reply, by position.
//
// DeepL answers `text=a&text=b` with translations[0].text for a and translations[1].text for b,
// so the batch is attributed by index instead of by markers. Providers without that form return
// 0 and the caller uses the (already tested) marker splitter.
int at_online_parse_at(const char* provider, const char* body_utf8, int index, char* out, int cap)
{
    JVal* root;
    JVal* node;
    const char* text;
    char path[64];
    int n;

    if (!provider || !body_utf8 || !out || cap <= 0 || index < 0) {
        set_error("missing argument");
        return 0;
    }
    out[0] = 0;

    if (_stricmp(provider, "deepl") != 0 && _stricmp(provider, "google_api") != 0 &&
        _stricmp(provider, "azure") != 0) {
        set_errorf("provider '%s' has no multi-text reply form%s", provider, "");
        return 0;
    }

    root = json_parse(body_utf8);
    if (!root) {
        set_error("response was not valid JSON");
        return 0;
    }
    if (_stricmp(provider, "google_api") == 0) {
        _snprintf_s(path, sizeof(path), _TRUNCATE, "data.translations.%d.translatedText", index);
    } else if (_stricmp(provider, "azure") == 0) {
        // The top-level array is in request order; the inner translations array has one entry per `to`,
        // and this build always asks for one target, so index 0 is the right one.
        _snprintf_s(path, sizeof(path), _TRUNCATE, "%d.translations.0.text", index);
    } else {
        _snprintf_s(path, sizeof(path), _TRUNCATE, "translations.%d.text", index);
    }
    node = json_path(root, path);
    text = json_str(node);
    if (!text || !*text) {
        _snprintf_s(g_error, sizeof(g_error), _TRUNCATE,
                    "the reply has no translation at index %d", index);
        json_free(root);
        return 0;
    }
    n = (int)strlen(text);
    if (n >= cap) {
        json_free(root);
        set_error("translated text does not fit the output buffer");
        return 0;
    }
    memcpy(out, text, (size_t)n + 1);
    json_free(root);
    return n;
}

// Bing answers with one object per text:
//   [{"translations":[{"text":"重新装填速度","to":"zh-Hans"}],"usedLLM":true,...}]
// and reports a refusal *inside* an HTTP 200 as well:
//   {"statusCode":400,"errorMessage":""}    unsupported language
//   {"statusCode":205,"errorMessage":""}    session expired
// A 0-byte body is what the international host answers when it does not like the caller, so an
// empty reply is a failure here rather than an empty translation.
static int parse_bing(const char* body, char* out, int cap)
{
    JVal* root;
    JVal* node;
    const char* text;
    int status;
    int n;

    if (!body || !*body) {
        set_error("bing returned an empty reply (no session, or the host refused)");
        return -1;
    }

    root = json_parse(body);
    if (!root) {
        set_error("response was not valid JSON");
        return -1;
    }

    node = json_path(root, "0.translations.0.text");
    text = json_str(node);
    if (text && *text) {
        n = (int)strlen(text);
        if (n >= cap) {
            json_free(root);
            set_error("translated text does not fit the output buffer");
            return -1;
        }
        memcpy(out, text, (size_t)n + 1);
        json_free(root);
        return n;
    }

    status = json_int(json_get(root, "statusCode"), 0);
    json_free(root);
    if (status == 205) {
        // The session went stale. Forgetting it here means the next attempt bootstraps a new
        // one instead of replaying a token the service has already rejected.
        at_online_bootstrap_clear();
        set_error("bing's session expired (statusCode 205); a new session is needed");
        return -1;
    }
    if (status) {
        _snprintf_s(g_error, sizeof(g_error), _TRUNCATE,
                    "bing refused the request (statusCode %d)", status);
        return -1;
    }
    set_error("response contained no translated text");
    return -1;
}

int at_online_parse(const char* provider, const char* body_utf8, char* out, int cap)
{
    if (!provider || !body_utf8 || !out || cap <= 0) {
        set_error("missing argument");
        return -1;
    }
    out[0] = 0;

    if (_stricmp(provider, "deepl") == 0) {
        return parse_deepl(body_utf8, out, cap);
    }
    if (_stricmp(provider, "google_clients5") == 0) {
        return parse_google_clients5(body_utf8, out, cap);
    }
    if (_stricmp(provider, "google_gtx") == 0) {
        return parse_google_gtx(body_utf8, out, cap);
    }
    if (_stricmp(provider, "mymemory") == 0) {
        return parse_mymemory(body_utf8, out, cap);
    }
    if (_stricmp(provider, "yandex") == 0) {
        return parse_yandex(body_utf8, out, cap);
    }
    if (_stricmp(provider, "bing") == 0) {
        return parse_bing(body_utf8, out, cap);
    }
    if (_stricmp(provider, "google_api") == 0) {
        return parse_google_api(body_utf8, out, cap);
    }
    if (_stricmp(provider, "azure") == 0) {
        return parse_azure(body_utf8, out, cap);
    }
    if (_stricmp(provider, "baidu") == 0) {
        return parse_baidu(body_utf8, out, cap);
    }

    set_errorf("unknown provider '%s'%s", provider, "");
    return -1;
}
