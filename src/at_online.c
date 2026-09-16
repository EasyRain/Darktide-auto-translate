// at_online.c — online provider request/response adapters. See at_online.h.
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "at_json.h"
#include "at_online.h"

static char g_error[512] = { 0 };

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
} LangMap;

static const LangMap LANG_MAP[] = {
    { "en",    "en",    "EN" },
    { "zh-cn", "zh-CN", "ZH-HANS" },
    { "zh-tw", "zh-TW", "ZH-HANT" },
    { "ja",    "ja",    "JA" },
    { "ko",    "ko",    "KO" },
    { "ru",    "ru",    "RU" },
    { "de",    "de",    "DE" },
    { "fr",    "fr",    "FR" },
    { "es",    "es",    "ES" },
    { "it",    "it",    "IT" },
    { "pl",    "pl",    "PL" },
    { "pt-br", "pt-BR", "PT-BR" },
    { "uk",    "uk",    "UK" },
};

int at_online_lang_code_for(const char* provider, const char* internal_lang, char* out, int cap)
{
    size_t i;
    int deepl;

    if (!internal_lang || !out || cap <= 0) {
        return 0;
    }
    deepl = provider && _stricmp(provider, "deepl") == 0;

    for (i = 0; i < sizeof(LANG_MAP) / sizeof(LANG_MAP[0]); i++) {
        if (_stricmp(LANG_MAP[i].internal, internal_lang) == 0) {
            strncpy_s(out, (size_t)cap, deepl ? LANG_MAP[i].deepl : LANG_MAP[i].google, _TRUNCATE);
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
           _stricmp(provider, "mymemory") == 0;
}

int at_online_needs_key(const char* provider)
{
    return provider && (_stricmp(provider, "google_api") == 0 || _stricmp(provider, "deepl") == 0);
}

int at_online_uses_post(const char* provider)
{
    return provider && _stricmp(provider, "deepl") == 0;
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
    } else if (_stricmp(provider, "mymemory") == 0) {
        host = "api.mymemory.translated.net";
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
    } else if (_stricmp(provider, "google_api") == 0) {
        if (!api_key || !*api_key) {
            free(encoded);
            set_error("this provider needs an API key");
            return 0;
        }
        written = _snprintf_s(out, (size_t)cap, _TRUNCATE,
                              "/language/translate/v2?key=%s&q=%s&source=%s&target=%s&format=text",
                              api_key, encoded, src, dst);
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

// google_api:
//   {"data":{"translations":[{"translatedText":"..."}]}}
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
    if (_stricmp(provider, "deepl") != 0) {
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

    written = _snprintf_s(out, (size_t)cap, _TRUNCATE,
                          "text=%s&source_lang=%s&target_lang=%s", encoded, src, dst);
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

    if (!provider || !texts || !out || cap <= 0) {
        set_error("missing argument");
        return 0;
    }
    if (_stricmp(provider, "deepl") != 0) {
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
        written = _snprintf_s(out + used, (size_t)(cap - used), _TRUNCATE, "text=%s&", encoded);
        free(encoded);
        if (written < 0) {
            _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, "request body too long (buffer: %d bytes)", cap);
            return 0;
        }
        used += written;
    }

    if (_snprintf_s(out + used, (size_t)(cap - used), _TRUNCATE,
                    "source_lang=%s&target_lang=%s", src, dst) < 0) {
        _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, "request body too long (buffer: %d bytes)", cap);
        return 0;
    }
    return 1;
}

// Whether this provider has a multi-text request form (see at_online_body_multi). The Lua layer
// asks instead of hard-coding a provider name: which services ship is the core's business.
int at_online_supports_multi_text(const char* provider)
{
    return provider && _stricmp(provider, "deepl") == 0;
}

int at_online_headers(const char* provider, const char* api_key, char* out, int cap)
{
    if (!provider || !out || cap <= 0) {
        set_error("missing argument");
        return 0;
    }
    out[0] = 0;

    if (_stricmp(provider, "deepl") == 0) {
        if (!api_key || !*api_key) {
            set_error("this provider needs an API key");
            return 0;
        }
        if (_snprintf_s(out, (size_t)cap, _TRUNCATE, "Authorization: DeepL-Auth-Key %s\r\n", api_key) < 0) {
            set_error("API key is too long for a header");
            return 0;
        }
    }
    return 1;
}

const char* at_online_content_type(const char* provider)
{
    if (provider && _stricmp(provider, "deepl") == 0) {
        return "application/x-www-form-urlencoded";
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

    if (_stricmp(provider, "deepl") != 0) {
        set_errorf("provider '%s' has no multi-text reply form%s", provider, "");
        return 0;
    }

    root = json_parse(body_utf8);
    if (!root) {
        set_error("response was not valid JSON");
        return 0;
    }
    _snprintf_s(path, sizeof(path), _TRUNCATE, "translations.%d.text", index);
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
    if (_stricmp(provider, "google_api") == 0) {
        return parse_google_api(body_utf8, out, cap);
    }

    set_errorf("unknown provider '%s'%s", provider, "");
    return -1;
}
