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

// argv with "--proxy <addr>" removed (it is handled once, before dispatch).
static char* g_argv[64];
static int g_argc = 0;

static void strip_proxy_args(int argc, char** argv)
{
    int i;
    g_argc = 0;
    for (i = 0; i < argc; i++) {
        if (_stricmp(argv[i], "--proxy") == 0 && i + 1 < argc) {
            if (!at_set_proxy(argv[i + 1])) {
                fprintf(stderr, "warning: %s\n", at_error());
            } else {
                printf("using proxy %s\n", argv[i + 1]);
            }
            i++;
            continue;
        }
        if (g_argc < 63) {
            g_argv[g_argc++] = argv[i];
        }
    }
}

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
    expect_true("google_clients5 host",
                at_online_host("google_clients5", out, (int)sizeof(out)) && strcmp(out, "clients5.google.com") == 0);
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

    expect_true("clients5 path",
                at_online_path("google_clients5", NULL, "en", "zh-cn", "Hello", path, (int)sizeof(path)) &&
                    strcmp(path, "/translate_a/t?client=dict-chrome-ex&sl=en&tl=zh-CN&q=Hello") == 0);

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

    printf("\n== google_clients5 parsing ==\n");
    expect_true("flat form (sl=en)",
                at_online_parse("google_clients5",
                                "[\"\xE3\x82\xAD\xE3\x83\xBC\xE3\x82\xB9\xE3\x83\x88\xE3\x83\xBC\xE3\x83\xB3\"]",
                                out, (int)sizeof(out)) > 0 &&
                    strcmp(out, "\xE3\x82\xAD\xE3\x83\xBC\xE3\x82\xB9\xE3\x83\x88\xE3\x83\xBC\xE3\x83\xB3") == 0);

    // sl=auto adds the detected language next to the text
    expect_true("detected-language form (sl=auto)",
                at_online_parse("google_clients5",
                                "[[\"\xE7\x9A\x87\xE5\xB8\x9D\",\"de\"]]",
                                out, (int)sizeof(out)) > 0 &&
                    strcmp(out, "\xE7\x9A\x87\xE5\xB8\x9D") == 0);

    expect_true("escaped angle brackets and kept placeholders",
                at_online_parse("google_clients5",
                                "[\"%s deals \\u003Ctag\\u003E damage %\"]",
                                out, (int)sizeof(out)) > 0 &&
                    strcmp(out, "%s deals <tag> damage %") == 0);

    expect_true("empty array fails",
                at_online_parse("google_clients5", "[]", out, (int)sizeof(out)) < 0);

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

    // MyMemory reports refusals with responseStatus 200 and the message in
    // translatedText. Storing that as a translation would look like success.
    expect_true("a refusal hidden in translatedText is rejected",
                at_online_parse("mymemory",
                                "{\"responseData\":{\"translatedText\":\"'XX-YY' IS AN INVALID TARGET LANGUAGE\"},"
                                "\"responseStatus\":200,\"responseDetails\":\"'XX-YY' IS AN INVALID\"}",
                                out, (int)sizeof(out)) < 0 &&
                    strstr(at_online_error(), "INVALID TARGET LANGUAGE") != NULL);

    expect_true("an exhausted daily quota is rejected",
                at_online_parse("mymemory",
                                "{\"responseData\":{\"translatedText\":\"MYMEMORY WARNING: YOU USED ALL AVAILABLE "
                                "FREE TRANSLATIONS FOR TODAY\"},\"quotaFinished\":true,\"responseStatus\":200}",
                                out, (int)sizeof(out)) < 0);

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
    expect_true("known providers", at_online_provider_known("google_clients5") &&
                                       at_online_provider_known("google_gtx") &&
                                       at_online_provider_known("mymemory") &&
                                       at_online_provider_known("google_api"));
    expect_true("unknown provider rejected", !at_online_provider_known("deepl"));
    expect_true("only google_api needs a key", !at_online_needs_key("google_clients5") &&
                                                   !at_online_needs_key("google_gtx") &&
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
                // 12029 = cannot connect: almost always the proxy, not the code
                if (win_error == 12029 || win_error == 12007) {
                    printf("proxy      : %s\n", at_proxy_in_use());
                    if (at_proxy_hint() && at_proxy_hint()[0]) {
                        printf("hint       : %s\n", at_proxy_hint());
                    } else {
                        printf("hint       : the host could not be reached. If you need a proxy to reach it,\n"
                               "             pass --proxy 127.0.0.1:7890 (or turn on your VPN's TUN mode).\n");
                    }
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
// probe — is each provider actually reachable from this machine?
//
// This is the check that answers "why is nothing translating": the difference
// between a blocked host, a missing proxy and a broken parser, in one command.
// ---------------------------------------------------------------------------
static int cmd_probe(int argc, char** argv)
{
    static const char* PROVIDERS[] = { "google_clients5", "google_gtx", "mymemory", NULL };
    const char* langs[2];
    const char* sample = "Keystone unlocked";
    int reachable = 0;
    int i;
    int l;

    // With no argument, check the two languages that behave most differently.
    if (argc >= 3) {
        langs[0] = argv[2];
        langs[1] = NULL;
    } else {
        langs[0] = "ja";
        langs[1] = "zh-cn";
    }

    printf("proxy in use : %s\n", at_proxy_in_use());
    if (at_proxy_hint() && at_proxy_hint()[0]) {
        printf("note         : %s\n", at_proxy_hint());
    }
    printf("sample       : \"%s\"\n\n", sample);

    for (i = 0; PROVIDERS[i]; i++) {
        for (l = 0; langs[l]; l++) {
            char host[256];
            char* path;
            char* body;
            char out[8192];
            int rc;

            if (!at_online_host(PROVIDERS[i], host, (int)sizeof(host))) {
                printf("%-15s %-6s  SKIPPED (%s)\n", PROVIDERS[i], langs[l], at_online_error());
                continue;
            }

            path = (char*)malloc(16384);
            body = (char*)malloc(BODY_CAP);
            if (!path || !body) {
                free(path);
                free(body);
                continue;
            }

            if (!at_online_path(PROVIDERS[i], "PROBE", "en", langs[l], sample, path, 16384)) {
                printf("%-15s %-6s  SKIPPED (%s)\n", PROVIDERS[i], langs[l], at_online_error());
                free(path);
                free(body);
                continue;
            }

            {
                int len = 0;
                rc = fetch(host, path, body, BODY_CAP, &len);
                if (rc == 0) {
                    body[len] = 0;
                    {
                        int n = at_online_parse(PROVIDERS[i], body, out, (int)sizeof(out));
                        if (n > 0) {
                            printf("%-15s %-6s  OK    %s\n", PROVIDERS[i], langs[l], out);
                            reachable++;
                        } else {
                            printf("%-15s %-6s  PARSE FAILED (%s)\n", PROVIDERS[i], langs[l], at_online_error());
                        }
                    }
                } else {
                    printf("%-15s %-6s  UNREACHABLE\n", PROVIDERS[i], langs[l]);
                }
            }

            free(path);
            free(body);
        }
    }

    printf("\n%d provider/language combination(s) work from this machine.\n", reachable);
    if (reachable == 0) {
        printf("Nothing is reachable. If you need a proxy, pass --proxy host:port (e.g. 127.0.0.1:7890).\n");
        return 3;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// parse — run the response parser over a saved body
//
// Real captured responses live in tests/fixtures/. Parsing those (rather than
// only hand-written samples) is what turns "the shape looks right" into a fact,
// and it needs neither the game nor the network.
// ---------------------------------------------------------------------------
static int cmd_parse(int argc, char** argv)
{
    FILE* f;
    char* body;
    long size;
    char out[8192];
    int n;

    if (argc < 4) {
        fprintf(stderr, "usage: at_cli.exe parse <provider> <file>\n");
        return 1;
    }

    f = fopen(argv[3], "rb");
    if (!f) {
        fprintf(stderr, "error: cannot open %s\n", argv[3]);
        return 1;
    }
    fseek(f, 0, SEEK_END);
    size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size < 0 || size > BODY_CAP) {
        fprintf(stderr, "error: file too large (%ld bytes)\n", size);
        fclose(f);
        return 1;
    }

    body = (char*)malloc((size_t)size + 1);
    if (!body) {
        fclose(f);
        fprintf(stderr, "error: out of memory\n");
        return 3;
    }
    if (fread(body, 1, (size_t)size, f) != (size_t)size) {
        fclose(f);
        free(body);
        fprintf(stderr, "error: could not read %s\n", argv[3]);
        return 1;
    }
    fclose(f);
    body[size] = 0;

    printf("provider : %s\nfile     : %s\nbytes    : %ld\n", argv[2], argv[3], size);

    n = at_online_parse(argv[2], body, out, (int)sizeof(out));
    free(body);

    if (n < 0) {
        fprintf(stderr, "parse failed: %s\n", at_online_error());
        return 3;
    }
    printf("result   : %s\nbytes    : %d\n", out, n);
    return 0;
}

// ---------------------------------------------------------------------------
// proxy — what would be used, and why
// ---------------------------------------------------------------------------
static int cmd_proxy(int argc, char** argv)
{
    const char* hint;

    if (argc >= 3) {
        if (!at_set_proxy(argv[2])) {
            fprintf(stderr, "error: %s\n", at_error());
            return 1;
        }
        printf("proxy set to: %s\n", argv[2]);
    }

    printf("proxy in use : %s\n", at_proxy_in_use());

    hint = at_proxy_hint();
    if (hint && hint[0]) {
        printf("note         : %s\n", hint);
    } else {
        printf("note         : Windows has no proxy configured, or it is enabled and being used.\n");
    }

    printf("\nusage: at_cli.exe proxy [host:port]   (no argument = show, empty string = automatic)\n");
    return 0;
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
    printf("proxy in use      : %s\n", at_proxy_in_use());
    if (at_proxy_hint() && at_proxy_hint()[0]) {
        printf("proxy note        : %s\n", at_proxy_hint());
    }
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
    printf("  at_cli.exe probe [target-lang]                         (is each provider reachable?)\n");
    printf("  at_cli.exe parse <provider> <file>                     (parse a captured response)\n");
    printf("  at_cli.exe proxy [host:port]                           (show / set the proxy)\n");
    printf("  at_cli.exe http <url>\n");
    printf("  at_cli.exe http <host> <path>\n");
    printf("  at_cli.exe provider <name> <target-lang> <text...> [--key <api-key>]\n");
    printf("  at_cli.exe translate <target-lang> <text...>\n\n");
    printf("providers: google_clients5, google_gtx, mymemory, google_api\n");
    printf("any command accepts --proxy <host:port> (e.g. --proxy 127.0.0.1:7890)\n");
}

int main(int argc, char** argv)
{
    int rc;

    // Make UTF-8 output readable instead of mojibake on a non-UTF-8 console.
    SetConsoleOutputCP(CP_UTF8);

    strip_proxy_args(argc, argv);
    argc = g_argc;
    argv = g_argv;

    if (argc < 2) {
        usage();
        return 1;
    }

    if (_stricmp(argv[1], "info") == 0) {
        rc = cmd_info();
    } else if (_stricmp(argv[1], "selftest") == 0) {
        rc = cmd_selftest();
    } else if (_stricmp(argv[1], "proxy") == 0) {
        rc = cmd_proxy(argc, argv);
    } else if (_stricmp(argv[1], "probe") == 0) {
        rc = cmd_probe(argc, argv);
    } else if (_stricmp(argv[1], "parse") == 0) {
        rc = cmd_parse(argc, argv);
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
