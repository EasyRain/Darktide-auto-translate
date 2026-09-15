// at_cli.c — command line front end for the Auto Translate native core.
//
// Lets the core be tested without launching the game:
//   at_cli.exe info
//   at_cli.exe selftest                          (no network, no game)
//   at_cli.exe http <url> | http <host> <path>
//   at_cli.exe provider <name> <target-lang> <text...>
//   at_cli.exe translate <target-lang> <text...>
//
// Exit codes: 0 ok, 1 usage error, 2 core unavailable, 3 request/parse/test failure.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

#include "at_core.h"
#include "at_online.h"

#define BODY_CAP (4 * 1024 * 1024)

// ---------------------------------------------------------------------------
// small test harness
// ---------------------------------------------------------------------------
static int g_checks = 0;
static int g_failures = 0;

// Prints non-ASCII bytes as \xNN so a mismatched result is readable in a console
// that is not in UTF-8 mode.
static void print_escaped(const char* s)
{
    const unsigned char* p = (const unsigned char*)(s ? s : "(null)");
    for (; *p; p++) {
        if (*p >= 0x20 && *p < 0x7F) {
            putchar(*p);
        } else if (*p == '\n') {
            fputs("\\n", stdout);
        } else if (*p == '\t') {
            fputs("\\t", stdout);
        } else {
            printf("\\x%02X", *p);
        }
    }
}

static void expect_str(const char* label, const char* got, const char* want)
{
    g_checks++;
    if (got && want && strcmp(got, want) == 0) {
        printf("PASS  %s\n", label);
        return;
    }
    g_failures++;
    printf("FAIL  %s\n      want: ", label);
    print_escaped(want);
    printf("\n      got : ");
    print_escaped(got);
    printf("\n");
}

static void expect_true(const char* label, int cond)
{
    g_checks++;
    if (cond) {
        printf("PASS  %s\n", label);
        return;
    }
    g_failures++;
    printf("FAIL  %s\n", label);
}

static void expect_contains(const char* label, const char* haystack, const char* needle)
{
    g_checks++;
    if (haystack && needle && strstr(haystack, needle)) {
        printf("PASS  %s\n", label);
        return;
    }
    g_failures++;
    printf("FAIL  %s\n      wanted to contain: ", label);
    print_escaped(needle);
    printf("\n      in                : ");
    print_escaped(haystack);
    printf("\n");
}

// ---------------------------------------------------------------------------
// selftest — provider parsing and request building, entirely offline
// ---------------------------------------------------------------------------
static int cmd_selftest(void)
{
    char out[8192];
    char path[8192];

    printf("at_core %s\n\n== language codes ==\n", at_version());
    expect_true("zh-cn -> zh-CN", at_online_lang_code("zh-cn", out, (int)sizeof(out)) && strcmp(out, "zh-CN") == 0);
    expect_true("zh-tw -> zh-TW", at_online_lang_code("zh-tw", out, (int)sizeof(out)) && strcmp(out, "zh-TW") == 0);
    expect_true("pt-br -> pt-BR", at_online_lang_code("pt-br", out, (int)sizeof(out)) && strcmp(out, "pt-BR") == 0);
    expect_true("uk -> uk", at_online_lang_code("uk", out, (int)sizeof(out)) && strcmp(out, "uk") == 0);
    expect_true("klingon is rejected", !at_online_lang_code("tlh", out, (int)sizeof(out)));

    printf("\n== request building ==\n");
    expect_true("google_gtx host",
                at_online_host("google_gtx", out, (int)sizeof(out)) && strcmp(out, "translate.googleapis.com") == 0);
    expect_true("mymemory host",
                at_online_host("mymemory", out, (int)sizeof(out)) && strcmp(out, "api.mymemory.translated.net") == 0);
    expect_true("google_api host",
                at_online_host("google_api", out, (int)sizeof(out)) && strcmp(out, "translation.googleapis.com") == 0);
    expect_true("unknown host rejected", !at_online_host("nope", out, (int)sizeof(out)));

    expect_true("gtx path",
                at_online_path("google_gtx", NULL, "en", "zh-cn", "Hello", path, (int)sizeof(path)) &&
                    strcmp(path, "/translate_a/single?client=gtx&sl=en&tl=zh-CN&dt=t&q=Hello") == 0);

    // a mod string containing &, | and a space must not be able to reshape the query
    expect_true("gtx path escapes & and spaces",
                at_online_path("google_gtx", NULL, "en", "ja", "a&b c|d", path, (int)sizeof(path)) &&
                    strstr(path, "q=a%26b%20c%7Cd") != NULL);

    expect_true("mymemory path (langpair pipe is escaped)",
                at_online_path("mymemory", NULL, "en", "ja", "Hello", path, (int)sizeof(path)) &&
                    strcmp(path, "/get?q=Hello&langpair=en%7Cja") == 0);

    expect_true("google_api path carries the key",
                at_online_path("google_api", "KEY123", "en", "ko", "Hi", path, (int)sizeof(path)) &&
                    strstr(path, "key=KEY123") != NULL && strstr(path, "target=ko") != NULL);

    expect_true("google_api without a key is refused",
                !at_online_path("google_api", "", "en", "ko", "Hi", path, (int)sizeof(path)));

    // UTF-8 must survive encoding: 你好 = E4 BD A0 E5 A5 BD
    expect_true("gtx path encodes UTF-8 byte-wise",
                at_online_path("google_gtx", NULL, "en", "ja", "\xE4\xBD\xA0\xE5\xA5\xBD", path, (int)sizeof(path)) &&
                    strstr(path, "q=%E4%BD%A0%E5%A5%BD") != NULL);

    printf("\n== google_gtx parsing ==\n");
    expect_true("single segment",
                at_online_parse("google_gtx", "[[[\"\xE4\xBD\xA0\xE5\xA5\xBD\",\"Hello\",null,null,10]],null,\"en\"]",
                                out, (int)sizeof(out)) > 0 &&
                    strcmp(out, "\xE4\xBD\xA0\xE5\xA5\xBD") == 0);

    // long input comes back as several segments that must be joined
    expect_true("segments are concatenated",
                at_online_parse("google_gtx",
                                "[[[\"\xE4\xBD\xA0\xE5\xA5\xBD\",\"Hello\",null,null,10],"
                                "[\"\xE4\xB8\x96\xE7\x95\x8C\",\"World\",null,null,10]],null,\"en\"]",
                                out, (int)sizeof(out)) > 0 &&
                    strcmp(out, "\xE4\xBD\xA0\xE5\xA5\xBD\xE4\xB8\x96\xE7\x95\x8C") == 0);

    expect_true("empty segment list fails",
                at_online_parse("google_gtx", "[[],null,\"en\"]", out, (int)sizeof(out)) < 0);

    printf("\n== mymemory parsing ==\n");
    expect_true("plain text",
                at_online_parse("mymemory",
                                "{\"responseData\":{\"translatedText\":\"\xE4\xBD\xA0\xE5\xA5\xBD\"},"
                                "\"responseStatus\":200,\"responseDetails\":\"\"}",
                                out, (int)sizeof(out)) > 0 &&
                    strcmp(out, "\xE4\xBD\xA0\xE5\xA5\xBD") == 0);

    expect_true("HTML entities are decoded",
                at_online_parse("mymemory",
                                "{\"responseData\":{\"translatedText\":\"It&#39;s a &quot;test&quot; &amp; more\"},"
                                "\"responseStatus\":200}",
                                out, (int)sizeof(out)) > 0 &&
                    strcmp(out, "It's a \"test\" & more") == 0);

    expect_true("quota refusal surfaces the service message",
                at_online_parse("mymemory",
                                "{\"responseData\":null,\"responseStatus\":403,"
                                "\"responseDetails\":\"QUERY LENGTH LIMIT EXCEEDED\"}",
                                out, (int)sizeof(out)) < 0 &&
                    strstr(at_online_error(), "QUERY LENGTH LIMIT EXCEEDED") != NULL);

    printf("\n== google_api parsing ==\n");
    expect_true("translatedText",
                at_online_parse("google_api",
                                "{\"data\":{\"translations\":[{\"translatedText\":\"\xE3\x81\x93\xE3\x82\x93"
                                "\xE3\x81\xAB\xE3\x81\xA1\xE3\x81\xAF\"}]}}",
                                out, (int)sizeof(out)) > 0 &&
                    strcmp(out, "\xE3\x81\x93\xE3\x82\x93\xE3\x81\xAB\xE3\x81\xA1\xE3\x81\xAF") == 0);

    expect_true("API error surfaces the message",
                at_online_parse("google_api", "{\"error\":{\"code\":400,\"message\":\"API key not valid\"}}",
                                out, (int)sizeof(out)) < 0 &&
                    strstr(at_online_error(), "API key not valid") != NULL);

    printf("\n== JSON reader ==\n");
    expect_true("\\u escapes",
                at_online_parse("mymemory",
                                "{\"responseData\":{\"translatedText\":\"\\u4f60\\u597d\"},\"responseStatus\":200}",
                                out, (int)sizeof(out)) > 0 &&
                    strcmp(out, "\xE4\xBD\xA0\xE5\xA5\xBD") == 0);

    expect_true("surrogate pairs decode to one character",
                at_online_parse("mymemory",
                                "{\"responseData\":{\"translatedText\":\"\\ud83d\\ude00\"},\"responseStatus\":200}",
                                out, (int)sizeof(out)) > 0 &&
                    strcmp(out, "\xF0\x9F\x98\x80") == 0);

    expect_true("nested structures and numbers",
                at_online_parse("mymemory",
                                "{\"responseStatus\":200,\"responseData\":{\"translatedText\":\"x\","
                                "\"extra\":[1,2.5,-3,{\"deep\":true},null]}}",
                                out, (int)sizeof(out)) > 0 &&
                    strcmp(out, "x") == 0);

    expect_true("malformed JSON is rejected",
                at_online_parse("mymemory", "{\"responseData\":{\"translatedText\":\"x\"}", out,
                                (int)sizeof(out)) < 0);

    expect_true("trailing garbage is rejected",
                at_online_parse("mymemory", "{\"responseData\":{\"translatedText\":\"x\"}} oops", out,
                                (int)sizeof(out)) < 0);

    expect_true("UTF-8 BOM is tolerated",
                at_online_parse("mymemory",
                                "\xEF\xBB\xBF{\"responseData\":{\"translatedText\":\"x\"},\"responseStatus\":200}",
                                out, (int)sizeof(out)) > 0 &&
                    strcmp(out, "x") == 0);

    printf("\n== provider table ==\n");
    expect_true("known providers", at_online_provider_known("google_gtx") &&
                                       at_online_provider_known("mymemory") &&
                                       at_online_provider_known("google_api"));
    expect_true("unknown provider rejected", !at_online_provider_known("deepl"));
    expect_true("only google_api needs a key", !at_online_needs_key("google_gtx") &&
                                                   !at_online_needs_key("mymemory") &&
                                                   at_online_needs_key("google_api"));

    printf("\n%d checks, %d failure(s)\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 3;
}

// ---------------------------------------------------------------------------
// helpers shared by the network commands
// ---------------------------------------------------------------------------
static int is_https(const char* url)
{
    return _strnicmp(url, "https://", 8) == 0;
}

// Splits an absolute URL into host[:port] and path. The scheme prefix is kept on
// the host: the core uses it to pick the port and whether to use TLS. Both
// buffers are caller owned.
static int split_url(const char* url, char* host, int host_cap, char* path, int path_cap)
{
    const char* p;
    const char* slash;
    int n;

    if (_strnicmp(url, "http://", 7) == 0) {
        p = url + 7;
    } else if (is_https(url)) {
        p = url + 8;
    } else {
        p = url;
    }

    slash = strchr(p, '/');
    if (!slash) {
        n = (int)strlen(url);
        if (n <= 0 || n >= host_cap) {
            return 0;
        }
        memcpy(host, url, (size_t)n);
        host[n] = 0;
        path[0] = '/';
        path[1] = 0;
        return 1;
    }

    // everything before the path, scheme included
    n = (int)(slash - url);
    if (n <= 0 || n >= host_cap) {
        return 0;
    }
    memcpy(host, url, (size_t)n);
    host[n] = 0;

    if ((int)strlen(slash) >= path_cap) {
        return 0;
    }
    strcpy(path, slash);
    return 1;
}

// Runs one GET and hands back the body. Returns 0 on success.
static int fetch(const char* host, const char* path, char* body_out, int cap, int* out_len)
{
    int id = at_http_get(host, path);
    int spins = 0;

    if (id <= 0) {
        fprintf(stderr, "error: request rejected (%s)\n", at_error() ? at_error() : "?");
        return 3;
    }

    // 60 s ceiling; results are delivered by the worker thread.
    while (spins < 600) {
        int got_id = 0;
        int status = 0;
        int len = 0;
        unsigned long win_error = 0;
        int rc = at_http_poll(&got_id, &status, body_out, cap, &len, &win_error);

        if (rc < 0) {
            fprintf(stderr, "error: poll failed\n");
            return 3;
        }
        if (rc == 1) {
            if (status != 0) {
                printf("request id : %d\nstatus     : %d\n", got_id, status);
                if (win_error) {
                    printf("win error  : %lu (%s)\n", win_error, at_win_error_text(win_error));
                }
                if (at_error() && at_error()[0]) {
                    printf("last error : %s\n", at_error());
                }
                return 3;
            }
            if (out_len) {
                *out_len = len;
            }
            return 0;
        }

        Sleep(100);
        spins++;
    }

    fprintf(stderr, "error: timed out\n");
    return 3;
}

// ---------------------------------------------------------------------------
// http — raw GET
// ---------------------------------------------------------------------------
static int cmd_http(int argc, char** argv)
{
    char host[512];
    char path[2048];
    char* body;

    if (argc < 3) {
        fprintf(stderr, "usage: at_cli.exe http <url> | http <host> <path>\n");
        return 1;
    }

    if (argc >= 4) {
        snprintf(host, sizeof(host), "%s", argv[2]);
        snprintf(path, sizeof(path), "%s", argv[3]);
    } else if (!split_url(argv[2], host, (int)sizeof(host), path, (int)sizeof(path))) {
        fprintf(stderr, "error: could not parse url\n");
        return 1;
    }

    printf("GET %s%s\n", host, path);

    body = (char*)malloc(BODY_CAP);
    if (!body) {
        fprintf(stderr, "error: out of memory\n");
        return 3;
    }

    {
        int len = 0;
        int rc = fetch(host, path, body, BODY_CAP, &len);
        if (rc != 0) {
            free(body);
            return rc;
        }
        body[len] = 0;
        printf("bytes      : %d\n", len);
        {
            int shown = len > 400 ? 400 : len;
            printf("--- body (first %d bytes) ---\n", shown);
            fwrite(body, 1, (size_t)shown, stdout);
            if (shown == 0 || body[shown - 1] != '\n') {
                printf("\n");
            }
            if (shown < len) {
                printf("... (%d more bytes)\n", len - shown);
            }
        }
    }

    free(body);
    return 0;
}

// ---------------------------------------------------------------------------
// provider — the full online path: build -> GET -> parse
// ---------------------------------------------------------------------------
static int cmd_provider(int argc, char** argv)
{
    char host[256];
    char* path;
    char* body;
    char out[8192];
    char text[4096];
    const char* name;
    const char* lang;
    const char* api_key = NULL;
    int i;
    int rc;

    if (argc < 5) {
        fprintf(stderr, "usage: at_cli.exe provider <name> <target-lang> <text...> [--key <api-key>]\n");
        return 1;
    }

    name = argv[2];
    lang = argv[3];

    text[0] = 0;
    for (i = 4; i < argc; i++) {
        size_t used;
        size_t need;

        if (_stricmp(argv[i], "--key") == 0 && i + 1 < argc) {
            api_key = argv[++i];
            continue;
        }
        used = strlen(text);
        need = strlen(argv[i]);
        if (used + need + 2 >= sizeof(text)) {
            break;
        }
        if (used) {
            text[used++] = ' ';
            text[used] = 0;
        }
        strcat(text, argv[i]);
    }

    if (!at_online_provider_known(name)) {
        fprintf(stderr, "error: unknown provider '%s' (google_gtx, mymemory, google_api)\n", name);
        return 1;
    }
    if (at_online_needs_key(name) && !api_key) {
        fprintf(stderr, "error: provider '%s' needs an API key; add --key <api-key>\n", name);
        return 1;
    }

    if (!at_online_host(name, host, (int)sizeof(host))) {
        fprintf(stderr, "error: %s\n", at_online_error());
        return 1;
    }

    path = (char*)malloc(16384);
    body = (char*)malloc(BODY_CAP);
    if (!path || !body) {
        fprintf(stderr, "error: out of memory\n");
        free(path);
        free(body);
        return 3;
    }

    if (!at_online_path(name, api_key, "en", lang, text, path, 16384)) {
        fprintf(stderr, "error: %s\n", at_online_error());
        free(path);
        free(body);
        return 1;
    }

    printf("provider : %s\nhost     : %s\ntarget   : %s\nsource   : %s\n", name, host, lang, text);
    printf("path     : %s\n\n", path);

    {
        int len = 0;
        rc = fetch(host, path, body, BODY_CAP, &len);
        if (rc != 0) {
            free(path);
            free(body);
            return rc;
        }
        body[len] = 0;
    }

    {
        int n = at_online_parse(name, body, out, (int)sizeof(out));
        if (n < 0) {
            fprintf(stderr, "parse failed: %s\n", at_online_error());
            free(path);
            free(body);
            return 3;
        }
        printf("result   : %s\n", out);
        printf("bytes    : %d\n", n);
    }

    free(path);
    free(body);
    return 0;
}

// ---------------------------------------------------------------------------
// translate — local model entry point (stub for now)
// ---------------------------------------------------------------------------
static int cmd_translate(int argc, char** argv)
{
    char out[8192];
    char text[4096];
    int i;
    int rc;

    if (argc < 4) {
        fprintf(stderr, "usage: at_cli.exe translate <target-lang> <text...>\n");
        return 1;
    }

    text[0] = 0;
    for (i = 3; i < argc; i++) {
        size_t used = strlen(text);
        size_t need = strlen(argv[i]);
        if (used + need + 2 >= sizeof(text)) {
            break;
        }
        if (used) {
            text[used++] = ' ';
            text[used] = 0;
        }
        strcat(text, argv[i]);
    }

    printf("target : %s\nsource : %s\n", argv[2], text);

    rc = at_translate(text, argv[2], out, (int)sizeof(out));
    if (rc > 0) {
        printf("result : %s\n", out);
        return 0;
    }

    fprintf(stderr, "translate failed: rc=%d (%s)\n", rc, at_error() ? at_error() : "?");
    return 3;
}

// ---------------------------------------------------------------------------
// info
// ---------------------------------------------------------------------------
static int cmd_info(void)
{
    int status = at_model_status();
    const char* names[3];
    names[0] = "no model";
    names[1] = "model files present";
    names[2] = "model loaded and ready";

    printf("at_core available : %s\n", at_available() ? "yes" : "no");
    printf("at_core version   : %s\n", at_version() ? at_version() : "(null)");
    printf("model status      : %d (%s)\n", status,
           (status >= 0 && status <= 2) ? names[status] : "unknown");
    if (at_error() && at_error()[0]) {
        printf("last error        : %s\n", at_error());
    }
    return at_available() ? 0 : 2;
}

static void usage(void)
{
    printf("at_cli %s — Auto Translate native core test tool\n\n",
           at_version() ? at_version() : "?");
    printf("usage:\n");
    printf("  at_cli.exe info\n");
    printf("  at_cli.exe selftest                                    (offline, no network)\n");
    printf("  at_cli.exe http <url>\n");
    printf("  at_cli.exe http <host> <path>\n");
    printf("  at_cli.exe provider <name> <target-lang> <text...> [--key <api-key>]\n");
    printf("  at_cli.exe translate <target-lang> <text...>\n\n");
    printf("providers: google_gtx, mymemory, google_api\n");
}

int main(int argc, char** argv)
{
    int rc;

    // Make UTF-8 output readable instead of mojibake on a non-UTF-8 console.
    SetConsoleOutputCP(CP_UTF8);

    if (argc < 2) {
        usage();
        return 1;
    }

    if (_stricmp(argv[1], "info") == 0) {
        rc = cmd_info();
    } else if (_stricmp(argv[1], "selftest") == 0) {
        rc = cmd_selftest();
    } else if (_stricmp(argv[1], "http") == 0) {
        rc = cmd_http(argc, argv);
    } else if (_stricmp(argv[1], "provider") == 0) {
        rc = cmd_provider(argc, argv);
    } else if (_stricmp(argv[1], "translate") == 0) {
        rc = cmd_translate(argc, argv);
    } else {
        fprintf(stderr, "unknown command: %s\n", argv[1]);
        usage();
        rc = 1;
    }

    return rc;
}
