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
#include <shellapi.h>          // CommandLineToArgvW, for the UTF-8 argv below

#include "at_core.h"
#include "at_download.h"
#include "at_model.h"
#include "at_online.h"

#define BODY_CAP (4 * 1024 * 1024)

// argv with "--proxy <addr>" removed (it is handled once, before dispatch).
//
// 64 used to be the cap and anything beyond it was dropped *silently*: `queue` with 68
// strings reported "59 item(s), 0 problem(s)" and the last nine were never translated,
// which quietly halved the size of an A/B run. The array is generously sized now and
// exceeding it says so.
#define MAX_ARGV 1024
static char* g_argv[MAX_ARGV];
static int g_argc = 0;

// Windows hands `main` its arguments in the ANSI code page, so any non-ASCII text
// on the command line arrives as mojibake: "狂信徒" reached the model as "����ͽ",
// tokenised to a single invalid piece, and the answer was unk tokens. The wide
// command line is the only lossless source, so it is converted to UTF-8 up front
// and the rest of the program keeps using plain char*.
//
// The mod itself is unaffected - Lua hands the core UTF-8 strings directly - but
// nobody can test a non-English string without this.
static void use_utf8_argv(void)
{
    LPWSTR* wide;
    int count = 0;
    int i;

    wide = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!wide || count <= 0) {
        return;
    }

    g_argc = 0;
    if (count > MAX_ARGV) {
        fprintf(stderr, "warning: %d arguments given, only the first %d are used\n",
                count, MAX_ARGV);
        count = MAX_ARGV;
    }
    for (i = 0; i < count; ++i) {
        const int bytes = WideCharToMultiByte(CP_UTF8, 0, wide[i], -1, NULL, 0, NULL, NULL);
        if (bytes <= 0) {
            continue;
        }
        g_argv[g_argc] = (char*)malloc((size_t)bytes);
        if (!g_argv[g_argc]) {
            continue;
        }
        WideCharToMultiByte(CP_UTF8, 0, wide[i], -1, g_argv[g_argc], bytes, NULL, NULL);
        ++g_argc;
    }

    LocalFree(wide);
}

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
        if (g_argc >= MAX_ARGV) {
            fprintf(stderr, "warning: more than %d arguments, the rest are ignored\n", MAX_ARGV);
            break;
        }
        g_argv[g_argc++] = argv[i];
    }
}

// ---------------------------------------------------------------------------
// small test harness
// ---------------------------------------------------------------------------
// The thread count as the player sees it: -1 means "every core", 0 means nothing loaded.
static const char* threads_text(void)
{
    static char buf[32];
    const int n = at_model_threads();
    if (n < 0) {
        return "all";
    }
    if (n == 0) {
        return "none";
    }
    snprintf(buf, sizeof(buf), "%d", n);
    return buf;
}
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
    char body[8192];
    const char* parts[2];

    parts[0] = "Alpha";
    parts[1] = "Beta";

    printf("at_core %s\n\n== language codes ==\n", at_version());
    expect_true("zh-cn -> zh-CN", at_online_lang_code("zh-cn", out, (int)sizeof(out)) && strcmp(out, "zh-CN") == 0);
    expect_true("zh-tw -> zh-TW", at_online_lang_code("zh-tw", out, (int)sizeof(out)) && strcmp(out, "zh-TW") == 0);
    expect_true("pt-br -> pt-BR", at_online_lang_code("pt-br", out, (int)sizeof(out)) && strcmp(out, "pt-BR") == 0);
    expect_true("uk -> uk", at_online_lang_code("uk", out, (int)sizeof(out)) && strcmp(out, "uk") == 0);
    expect_true("klingon is rejected", !at_online_lang_code("tlh", out, (int)sizeof(out)));

    printf("\n== request building ==\n");
    expect_true("google_clients5 host",
                at_online_host("google_clients5", NULL, out, (int)sizeof(out)) &&
                    strcmp(out, "clients5.google.com") == 0);
    expect_true("google_gtx host",
                at_online_host("google_gtx", NULL, out, (int)sizeof(out)) &&
                    strcmp(out, "translate.googleapis.com") == 0);
    expect_true("mymemory host",
                at_online_host("mymemory", NULL, out, (int)sizeof(out)) &&
                    strcmp(out, "api.mymemory.translated.net") == 0);
    expect_true("google_api host",
                at_online_host("google_api", NULL, out, (int)sizeof(out)) &&
                    strcmp(out, "translation.googleapis.com") == 0);
    expect_true("unknown host rejected", !at_online_host("nope", NULL, out, (int)sizeof(out)));

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

    // The key stays in the query; q/source/target/format moved to the body (2026-10-12), which is how the
    // official client sends them and what lets a multi-text request repeat q= without a second shape.
    expect_true("google_api path carries the key and nothing else",
                at_online_path("google_api", "KEY123", "en", "ko", "Hi", path, (int)sizeof(path)) &&
                    strcmp(path, "/language/translate/v2?key=KEY123") == 0);
    expect_true("google_api body carries the parameters",
                at_online_body("google_api", "en", "ko", "Hi", body, (int)sizeof(body)) &&
                    strcmp(body, "q=Hi&source=en&target=ko&format=text") == 0);
    expect_true("google_api body encodes the text",
                at_online_body("google_api", "en", "ko", "a&b c|d", body, (int)sizeof(body)) &&
                    strstr(body, "q=a%26b%20c%7Cd") != NULL);

    expect_true("google_api without a key is refused",
                !at_online_path("google_api", "", "en", "ko", "Hi", path, (int)sizeof(path)));

    // UTF-8 must survive encoding: 你好 = E4 BD A0 E5 A5 BD
    expect_true("gtx path encodes UTF-8 byte-wise",
                at_online_path("google_gtx", NULL, "en", "ja", "\xE4\xBD\xA0\xE5\xA5\xBD", path, (int)sizeof(path)) &&
                    strstr(path, "q=%E4%BD%A0%E5%A5%BD") != NULL);

    // DeepL serves free and paid keys from different hosts; the key decides.
    expect_true("deepl free key -> api-free",
                at_online_host("deepl", "abc:fx", out, (int)sizeof(out)) &&
                    strcmp(out, "api-free.deepl.com") == 0);
    expect_true("deepl paid key -> api",
                at_online_host("deepl", "abc-123", out, (int)sizeof(out)) &&
                    strcmp(out, "api.deepl.com") == 0);

    printf("\n== deepL ==\n");
    expect_true("deepl uses POST", at_online_uses_post("deepl") && !at_online_uses_post("mymemory"));
    expect_true("deepl path carries no query",
                at_online_path("deepl", "k", "en", "ja", "Hello", path, (int)sizeof(path)) &&
                    strcmp(path, "/v2/translate") == 0);
    // ZH-HANS / ZH-HANT are DeepL's explicit Simplified / Traditional codes
    printf("\n== md5 (RFC 1321 vectors, for the Baidu sign) ==\n");
    {
        static const struct { const char* label; const char* data; int len; const char* want; } CASES[] = {
            { "md5: empty string", "", 0, "d41d8cd98f00b204e9800998ecf8427e" },
            { "md5: abc", "abc", 3, "900150983cd24fb0d6963f7d28e17f72" },
            { "md5: message digest", "message digest", 14, "f96b697d7cb7938d525a2f31aaf161d0" },
            { "md5: the alphabet", "abcdefghijklmnopqrstuvwxyz", 26, "c3fcd3d76192e4007dfb496cca67e13b" },
            { "md5: 80 digits", "12345678901234567890123456789012345678901234567890123456789012345678901234567890", 80,
              "57edf4a22be3c955ac49da2e2107b67a" },
            /* The padding boundaries: 55 fits one block, 56 forces two, 64 is exactly one plus padding. */
            { "md5: 55 bytes", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 55, "ef1772b6dff9a122358552954ad0df65" },
            { "md5: 56 bytes", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 56, "3b0c8ac703f828b04c6c197006d17218" },
            { "md5: 64 bytes", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 64, "014842d480b571495a4a0363793f7367" }
        };
        char hex[33];
        int bad = 0;

        for (int i = 0; i < (int)(sizeof(CASES) / sizeof(CASES[0])); i++) {
            at_online_md5_hex(CASES[i].data, (size_t)CASES[i].len, hex);
            if (strcmp(hex, CASES[i].want) != 0) {
                printf("    %s -> %s (wanted %s)\n", CASES[i].label, hex, CASES[i].want);
                bad++;
            }
        }
        /* A 1000-byte input exercises the multi-block loop. */
        {
            char big[1000];
            memset(big, 'a', sizeof(big));
            at_online_md5_hex(big, sizeof(big), hex);
            if (strcmp(hex, "cabe45dcc9ae5b66ba86600cca6b8ba8") != 0) {
                printf("    md5: 1000 bytes -> %s\n", hex);
                bad++;
            }
        }
        expect_true("md5 matches RFC 1321 (8 vectors + a multi-block input)", bad == 0);
    }

    printf("\n== baidu ==\n");
    /* The sign is md5(appid + text + salt + key); this is that exact string for these values, so the
       vector above and the path below are checked against an independent implementation. */
    {
        char hex[33];
        at_online_md5_hex("123456" "Reload Speed" "50000" "SECRET", 29, hex);
        expect_true("md5: the Baidu sign input",
            strcmp(hex, "1a46df562a53c68c08ad0fd8bdcc99c7") == 0);
    }
    expect_true("baidu host (the vendor demo's)", at_online_host("baidu", "K", out, (int)sizeof(out)) &&
        strcmp(out, "api.fanyi.baidu.com") == 0);
    expect_true("baidu needs a key", at_online_needs_key("baidu") == 1);
    /* The vendor's own demo posts it with every parameter in the query and no body
       (requests.post(url, params=payload)), so this is a POST whose body is empty. */
    expect_true("baidu is a POST (the demo's shape)", at_online_uses_post("baidu") == 1);
    expect_true("baidu's body is empty", at_online_body("baidu", "en", "zh-cn", "Hi", body, (int)sizeof(body)) == 1 &&
        body[0] == 0);
    at_online_set_appid("123456");
    expect_true("baidu path is signed and carries the parameters",
        at_online_path("baidu", "SECRET", "en", "zh-cn", "Reload Speed", path, (int)sizeof(path)) &&
            strstr(path, "/api/trans/vip/translate?") != NULL &&
            strstr(path, "q=Reload%20Speed") != NULL &&
            strstr(path, "from=en") != NULL &&
            strstr(path, "to=zh") != NULL &&
            strstr(path, "appid=123456") != NULL &&
            strstr(path, "salt=") != NULL &&
            strstr(path, "sign=") != NULL);
    {
        /* The sign is 32 lowercase hex characters, and the salt rides beside it. */
        const char* sign = strstr(path, "sign=");
        int hexish = 1;
        int i;
        for (i = 0; i < 32 && sign && sign[5 + i]; i++) {
            char c = sign[5 + i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
                hexish = 0;
            }
        }
        expect_true("baidu sign is 32 hex characters", sign != NULL && hexish == 1 && sign[5 + 32] == 0);
    }
    /* Its Chinese codes differ from everyone else's: zh / cht / jp / kor / fra / spa. */
    expect_true("baidu zh-cn -> zh",
        at_online_lang_code_for("baidu", "zh-cn", out, (int)sizeof(out)) && strcmp(out, "zh") == 0);
    expect_true("baidu zh-tw -> cht",
        at_online_lang_code_for("baidu", "zh-tw", out, (int)sizeof(out)) && strcmp(out, "cht") == 0);
    expect_true("baidu ja -> jp",
        at_online_lang_code_for("baidu", "ja", out, (int)sizeof(out)) && strcmp(out, "jp") == 0);
    expect_true("baidu ko -> kor",
        at_online_lang_code_for("baidu", "ko", out, (int)sizeof(out)) && strcmp(out, "kor") == 0);
    expect_true("baidu fr -> fra",
        at_online_lang_code_for("baidu", "fr", out, (int)sizeof(out)) && strcmp(out, "fra") == 0);
    expect_true("baidu es -> spa",
        at_online_lang_code_for("baidu", "es", out, (int)sizeof(out)) && strcmp(out, "spa") == 0);
    expect_true("baidu pt-br -> pt",
        at_online_lang_code_for("baidu", "pt-br", out, (int)sizeof(out)) && strcmp(out, "pt") == 0);
    /* The vendor's own language table lists ukr, but the endpoint refuses it: measured 2026-10-12 with a
       real key, twice with a delay in between, both times 58001 INVALID_TO_PARAM. Declaring it
       unsupported is what makes the engine hand Ukrainian to someone else instead of sending a request
       that cannot work. */
    expect_true("baidu refuses uk (its own table is wrong about it)",
        !at_online_lang_code_for("baidu", "uk", out, (int)sizeof(out)));
    /* The reference client's own test fixture, verbatim. */
    expect_true("baidu reply (the client's fixture)",
        at_online_parse("baidu", "{\"from\":\"en\",\"to\":\"zh\",\"trans_result\":[{\"src\":\"hello\",\"dst\":\"\xE4\xBD\xA0\xE5\xA5\xBD\"}]}",
            out, (int)sizeof(out)) > 0 && strcmp(out, "\xE4\xBD\xA0\xE5\xA5\xBD") == 0);
    /* A refusal arrives with HTTP 200 and a *string* error_code, which is why the body is read. */
    expect_true("baidu refusal is an error with its code",
        at_online_parse("baidu", "{\"error_code\":\"54001\",\"error_msg\":\"Invalid Sign\"}",
            out, (int)sizeof(out)) < 0 && strstr(at_online_error(), "54001") != NULL);
    expect_true("baidu refusal names the message",
        at_online_parse("baidu", "{\"error_code\":\"52003\",\"error_msg\":\"UNAUTHORIZED USER\"}",
            out, (int)sizeof(out)) < 0 && strstr(at_online_error(), "UNAUTHORIZED USER") != NULL);
    at_online_set_appid("");
    expect_true("baidu without an appid refuses to build a request",
        !at_online_path("baidu", "SECRET", "en", "zh-cn", "Hi", path, (int)sizeof(path)));

    printf("\n== azure ==\n");
    expect_true("azure host", at_online_host("azure", "K", out, (int)sizeof(out)) &&
        strcmp(out, "api.cognitive.microsofttranslator.com") == 0);
    expect_true("azure uses POST", at_online_uses_post("azure") == 1);
    expect_true("azure needs a key", at_online_needs_key("azure") == 1);
    // The only Content-Type it accepts; anything else is its documented 415000.
    expect_true("azure content type", strcmp(at_online_content_type("azure"), "application/json; charset=UTF-8") == 0);
    // from/to live in the query string for api-version=3.0, and it wants zh-Hans rather than zh-CN.
    expect_true("azure path", at_online_path("azure", "K", "en", "zh-cn", "Hi", path, (int)sizeof(path)) &&
        strcmp(path, "/translate?api-version=3.0&from=en&to=zh-Hans") == 0);
    // The body is a JSON array even for one string (verbatim from the reference's own example).
    expect_true("azure body is an array of one",
        at_online_body("azure", "en", "zh-cn", "Hello, what is your name?", body, (int)sizeof(body)) &&
            strcmp(body, "[{\"Text\":\"Hello, what is your name?\"}]") == 0);
    expect_true("azure body escapes a quote",
        at_online_body("azure", "en", "de", "He said \"hi\"\\now", body, (int)sizeof(body)) &&
            strcmp(body, "[{\"Text\":\"He said \\\"hi\\\"\\\\now\"}]") == 0);
    expect_true("azure multi body is an array of objects",
        at_online_body_multi("azure", "en", "zh-cn", parts, 2, body, (int)sizeof(body)) &&
            strcmp(body, "[{\"Text\":\"Alpha\"},{\"Text\":\"Beta\"}]") == 0);
    expect_true("azure supports several texts", at_online_supports_multi_text("azure") == 1);
    // Reply fixtures are the reference page's own examples, verbatim.
    expect_true("azure single reply",
        at_online_parse("azure", "[{\"translations\":[{\"text\":\"Xin chao\",\"to\":\"zh-Hans\"}]}]",
            out, (int)sizeof(out)) > 0 && strcmp(out, "Xin chao") == 0);
    expect_true("azure reply keeps UTF-8",
        at_online_parse("azure",
            "[{\"translations\":[{\"text\":\"\xE4\xBD\xA0\xE5\xA5\xBD\",\"to\":\"zh-Hans\"}]}]",
            out, (int)sizeof(out)) > 0 && strcmp(out, "\xE4\xBD\xA0\xE5\xA5\xBD") == 0);
    expect_true("azure auto-detect reply (detectedLanguage present)",
        at_online_parse("azure",
            "[{\"detectedLanguage\":{\"language\":\"en\",\"score\":1.0},"
            "\"translations\":[{\"text\":\"Hallo\",\"to\":\"de\"}]}]",
            out, (int)sizeof(out)) > 0 && strcmp(out, "Hallo") == 0);
    // A bare array in request order; the second element is read by index.
    expect_true("azure multi reply by position",
        at_online_parse_at("azure",
            "[{\"translations\":[{\"text\":\"Alpha\",\"to\":\"zh-Hans\"}]},"
            "{\"translations\":[{\"text\":\"Beta\",\"to\":\"zh-Hans\"}]}]", 1, out, (int)sizeof(out)) &&
            strcmp(out, "Beta") == 0);
    // An object instead of an array is the service refusing, and its code is machine-readable.
    expect_true("azure error carries the code",
        at_online_parse("azure",
            "{\"error\":{\"code\":403001,\"message\":\"The operation isn't allowed because the "
            "subscription has exceeded its free quota.\"}}", out, (int)sizeof(out)) < 0 &&
            strstr(at_online_error(), "403001") != NULL);
    expect_true("azure missing key is 401000",
        at_online_parse("azure",
            "{\"error\":{\"code\":401000,\"message\":\"The request is not authorized because "
            "credentials are missing or invalid.\"}}", out, (int)sizeof(out)) < 0 &&
            strstr(at_online_error(), "401000") != NULL);
    // The region rides in its own header, and only when one was set.
    at_online_set_region("westeurope");
    expect_true("azure region header",
        at_online_headers("azure", "KEY", out, (int)sizeof(out)) &&
            strstr(out, "Ocp-Apim-Subscription-Key: KEY") != NULL &&
            strstr(out, "Ocp-Apim-Subscription-Region: westeurope") != NULL);
    at_online_set_region("");
    expect_true("azure without a region omits that header",
        at_online_headers("azure", "KEY", out, (int)sizeof(out)) &&
            strstr(out, "Ocp-Apim-Subscription-Region") == NULL);
    // Its Chinese and Portuguese spellings differ from Google's on purpose.
    expect_true("azure zh-cn -> zh-Hans",
        at_online_lang_code_for("azure", "zh-cn", out, (int)sizeof(out)) && strcmp(out, "zh-Hans") == 0);
    expect_true("azure zh-tw -> zh-Hant",
        at_online_lang_code_for("azure", "zh-tw", out, (int)sizeof(out)) && strcmp(out, "zh-Hant") == 0);
    expect_true("azure pt-br -> pt",
        at_online_lang_code_for("azure", "pt-br", out, (int)sizeof(out)) && strcmp(out, "pt") == 0);

    // Multi-text (2026-10-12): Google repeats q= in the form body, which is its documented batch form.
    expect_true("google_api supports several texts", at_online_supports_multi_text("google_api") == 1);
    expect_true("google_api multi body repeats q",
                at_online_body_multi("google_api", "en", "zh-cn", parts, 2, body, (int)sizeof(body)) &&
                    strcmp(body, "q=Alpha&q=Beta&source=en&target=zh-CN&format=text") == 0);
    expect_true("google_api multi reply is read by position",
                at_online_parse_at("google_api",
                    "{\"data\":{\"translations\":[{\"translatedText\":\"Alpha\"},"
                    "{\"translatedText\":\"Beta\"}]}}", 1, out, (int)sizeof(out)) &&
                    strcmp(out, "Beta") == 0);

    expect_true("deepl zh-cn -> ZH-HANS",
                at_online_lang_code_for("deepl", "zh-cn", out, (int)sizeof(out)) &&
                    strcmp(out, "ZH-HANS") == 0);
    expect_true("deepl zh-tw -> ZH-HANT",
                at_online_lang_code_for("deepl", "zh-tw", out, (int)sizeof(out)) &&
                    strcmp(out, "ZH-HANT") == 0);
    expect_true("google zh-cn stays zh-CN",
                at_online_lang_code_for("google_gtx", "zh-cn", out, (int)sizeof(out)) &&
                    strcmp(out, "zh-CN") == 0);
    expect_true("deepl body",
                at_online_body("deepl", "en", "zh-cn", "a&b", path, (int)sizeof(path)) &&
                    strcmp(path, "text=a%26b&source_lang=EN&target_lang=ZH-HANS") == 0);
    expect_true("deepl body rejected for a GET provider",
                !at_online_body("google_gtx", "en", "ja", "Hi", path, (int)sizeof(path)));
    expect_true("deepl auth header",
                at_online_headers("deepl", "KEY:fx", path, (int)sizeof(path)) &&
                    strstr(path, "User-Agent: ") == path &&
                    strstr(path, "Authorization: DeepL-Auth-Key KEY:fx\r\n") != NULL);
    expect_true("deepl is told we are Chrome",
                at_online_headers("deepl", "KEY:fx", path, (int)sizeof(path)) &&
                    strstr(path, "Chrome/") != NULL && strstr(path, "Edg/") == NULL);
    expect_true("bing is told we are Edge",
                at_online_headers("bing", NULL, path, (int)sizeof(path)) &&
                    strstr(path, "Edg/") != NULL);
    expect_true("the google hosts are told we are Chrome, not Edge",
                at_online_headers("google_gtx", NULL, path, (int)sizeof(path)) &&
                    strstr(path, "Chrome/") != NULL && strstr(path, "Edg/") == NULL &&
                    at_online_headers("google_clients5", NULL, path, (int)sizeof(path)) &&
                    strstr(path, "Edg/") == NULL);
    expect_true("a header block that cannot hold the key is refused",
                !at_online_headers("deepl", "KEY:fx", path, 40));
    expect_true("deepl without a key is refused",
                !at_online_headers("deepl", "", path, (int)sizeof(path)));
    expect_true("deepl content type",
                at_online_content_type("deepl") &&
                    strcmp(at_online_content_type("deepl"), "application/x-www-form-urlencoded") == 0);
    expect_true("got translation",
                at_online_parse("deepl",
                                "{\"translations\":[{\"detected_source_language\":\"EN\","
                                "\"text\":\"\xE3\x82\xAD\xE3\x83\xBC\"}]}",
                                out, (int)sizeof(out)) > 0 &&
                    strcmp(out, "\xE3\x82\xAD\xE3\x83\xBC") == 0);
    expect_true("deepl error surfaces the message",
                at_online_parse("deepl", "{\"message\":\"Wrong endpoint. Use api-free.deepl.com\"}",
                                out, (int)sizeof(out)) < 0 &&
                    strstr(at_online_error(), "Wrong endpoint") != NULL);
    expect_true("deepl without a key needs one", at_online_needs_key("deepl"));

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

    // The rest of the fixed sentences it answers with instead of a translation. Two of them
    // are not about quota at all, and one fires when source and target are the same language -
    // all three would otherwise be stored as the translation of the string that was asked for.
    expect_true("a source==target refusal is rejected",
                at_online_parse("mymemory",
                                "{\"responseData\":{\"translatedText\":\"PLEASE SELECT TWO DISTINCT LANGUAGES\"},"
                                "\"responseStatus\":200,\"responseDetails\":\"\"}",
                                out, (int)sizeof(out)) < 0 &&
                    strstr(at_online_error(), "DISTINCT LANGUAGES") != NULL);
    expect_true("an over-long query refusal is rejected",
                at_online_parse("mymemory",
                                "{\"responseData\":{\"translatedText\":\"QUERY LENGTH LIMIT EXCEEDED. MAX ALLOWED "
                                "QUERY : 500 CHARS\"},\"responseStatus\":200}",
                                out, (int)sizeof(out)) < 0);
    expect_true("an invalid source language refusal is rejected",
                at_online_parse("mymemory",
                                "{\"responseData\":{\"translatedText\":\"'EN-GB' IS AN INVALID SOURCE LANGUAGE\"},"
                                "\"responseStatus\":200}",
                                out, (int)sizeof(out)) < 0);
    // Case is not something the service is consistent about.
    expect_true("the refusal check ignores case",
                at_online_parse("mymemory",
                                "{\"responseData\":{\"translatedText\":\"Mymemory warning: quota\"},"
                                "\"responseStatus\":200}",
                                out, (int)sizeof(out)) < 0);
    // And a real answer that merely mentions one of the words is still a translation.
    expect_true("an ordinary answer is not mistaken for a refusal",
                at_online_parse("mymemory",
                                "{\"responseData\":{\"translatedText\":\"Bitte zwei Sprachen w\xC3\xA4hlen\"},"
                                "\"responseStatus\":200}",
                                out, (int)sizeof(out)) > 0);

    printf("\n== yandex: the keyless Android endpoint, one text per request ==\n");
    {
        char host[256];
        char path[512];
        char body[512];
        char out[256];
        char code[16];
        const char* id;

        expect_true("yandex is a known provider", at_online_provider_known("yandex") == 1);
        expect_true("yandex needs no API key", at_online_needs_key("yandex") == 0);
        expect_true("yandex uses POST", at_online_uses_post("yandex") == 1);
        expect_true("yandex is asked at its own host",
                    at_online_host("yandex", "", host, (int)sizeof(host)) == 1 &&
                        strcmp(host, "translate.yandex.net") == 0);
        expect_true("the path carries the client id and the direction",
                    at_online_path("yandex", "", "en", "uk", "Reload Speed", path, (int)sizeof(path)) == 1 &&
                        strstr(path, "/api/v1/tr.json/translate?srv=android&id=") == path &&
                        strstr(path, "&lang=en-uk") != NULL);
        id = strstr(path, "id=");
        expect_true("the client id is 32 hex digits followed by -0-0",
                    id != NULL && strspn(id + 3, "0123456789abcdef") == 32 &&
                        strncmp(id + 35, "-0-0&lang=en-uk", 15) == 0);
        expect_true("the body is only the text",
                    at_online_body("yandex", "en", "uk", "a&b", body, (int)sizeof(body)) == 1 &&
                        strcmp(body, "text=a%26b") == 0);
        expect_true("the reply envelope parses",
                    at_online_parse("yandex",
                                    "{\"code\":200,\"lang\":\"en-uk\",\"nmt_code\":200,"
                                    "\"text\":[\"\\u041f\\u0440\\u0438\\u0432\\u0456\\u0442\"]}",
                                    out, (int)sizeof(out)) > 0 &&
                        strcmp(out, "\xD0\x9F\xD1\x80\xD0\xB8\xD0\xB2\xD1\x96\xD1\x82") == 0);
        expect_true("a code that is not 200 is a refusal, not a translation",
                    at_online_parse("yandex", "{\"code\":401,\"message\":\"Unauthorized\"}",
                                    out, (int)sizeof(out)) < 0);
        expect_true("an empty text array is a refusal too",
                    at_online_parse("yandex", "{\"code\":200,\"text\":[]}", out,
                                    (int)sizeof(out)) < 0);
        // The endpoint rejects every spelling of Traditional Chinese (measured), so the provider has
        // to drop out for that target and stay available for the other eleven.
        expect_true("Traditional Chinese is not offered at all",
                    at_online_lang_code_for("yandex", "zh-tw", code, (int)sizeof(code)) == 0);
        expect_true("Simplified Chinese is",
                    at_online_lang_code_for("yandex", "zh-cn", code, (int)sizeof(code)) == 1 &&
                        strcmp(code, "zh") == 0);
        expect_true("and so are Ukrainian and Brazilian Portuguese",
                    at_online_lang_code_for("yandex", "uk", code, (int)sizeof(code)) == 1 &&
                        strcmp(code, "uk") == 0 &&
                        at_online_lang_code_for("yandex", "pt-br", code, (int)sizeof(code)) == 1 &&
                        strcmp(code, "pt") == 0);
    }

    printf("\n== bing: a session token first, then the request ==\n");
    {
        // The keyless Microsoft endpoint hands out a key, a token and an IG on one page load and
        // wants them back afterwards. The page text below is the shape the real page carried
        // (captured from cn.bing.com on 2026-09-16, values shortened); what the test pins is that
        // a missing block is refused rather than sent as a broken request, and that an expired
        // session is forgotten so the next attempt bootstraps a new one.
        const char* page =
            "<html><head><script>var _G={};IG:\"810EA0129C0F4C1E9A2E4B6D8F0A1B2C\","
            "params_AbusePreventionHelper = [1789537836335,\"GBaGdJt6oYKQ1Zz9Tk4m\",3600000];"
            "</script></head><body>translator</body></html>";
        char path[512];
        char body[1024];
        char out[256];

        at_online_bootstrap_clear();
        expect_true("bing reports that it needs a session", at_online_bootstrap_needed("bing") == 1);
        expect_true("another provider does not", at_online_bootstrap_needed("google_clients5") == 0);
        expect_true("a request without a session is refused",
                    at_online_path("bing", "", "en", "zh-cn", "Reload Speed", path,
                                   (int)sizeof(path)) == 0);
        expect_true("the bootstrap path is the translator page",
                    at_online_bootstrap_path("bing", path, (int)sizeof(path)) == 1 &&
                        strcmp(path, "/translator") == 0);
        expect_true("the page is parsed into a session",
                    at_online_bootstrap_parse(page) == 1 && at_online_bootstrap_ready() == 1);
        expect_true("a page without the block is refused",
                    at_online_bootstrap_parse("<html>nothing here</html>") == 0);
        expect_true("and a refused page leaves no session behind", at_online_bootstrap_ready() == 0);
        // A page that cannot be parsed is also the signal to try the other host: a redirect stub
        // lands here too, because the core does not follow redirects. The two hosts are the farm
        // host (answers from inside and outside China without redirecting) and the market host.
        {
            char host_first[128];
            char host_mid[128];
            char host_back[128];
            int ok_first = at_online_host("bing", "", host_first, (int)sizeof(host_first));

            expect_true("bing is asked through a known host",
                        ok_first == 1 &&
                            (strcmp(host_first, "www4.bing.com") == 0 ||
                             strcmp(host_first, "cn.bing.com") == 0));
            expect_true("a refused page moves to the other host",
                        at_online_bootstrap_parse("<html>nothing here</html>") == 0 &&
                            at_online_host("bing", "", host_mid, (int)sizeof(host_mid)) == 1 &&
                            strcmp(host_mid, host_first) != 0);
            expect_true("and the next refusal comes back, so the cycle is not one way",
                        at_online_bootstrap_parse("<html>nothing here</html>") == 0 &&
                            at_online_host("bing", "", host_back, (int)sizeof(host_back)) == 1 &&
                            strcmp(host_back, host_first) == 0 &&
                            strcmp(host_back, host_mid) != 0);
        }
        expect_true("so a good page is parsed again", at_online_bootstrap_parse(page) == 1);

        expect_true("bing spells the languages its own way",
                    at_online_lang_code_for("bing", "zh-cn", out, (int)sizeof(out)) == 1 &&
                        strcmp(out, "zh-Hans") == 0 &&
                        at_online_lang_code_for("bing", "zh-tw", out, (int)sizeof(out)) == 1 &&
                        strcmp(out, "zh-Hant") == 0 &&
                        at_online_lang_code_for("bing", "pt-br", out, (int)sizeof(out)) == 1 &&
                        strcmp(out, "pt") == 0);
        expect_true("it needs no API key", at_online_needs_key("bing") == 0);
        expect_true("it posts a form",
                    at_online_uses_post("bing") == 1 &&
                        strcmp(at_online_content_type("bing"), "application/x-www-form-urlencoded") == 0);
        expect_true("the query carries the session id",
                    at_online_path("bing", "", "en", "zh-cn", "Reload Speed", path,
                                   (int)sizeof(path)) == 1 &&
                        strstr(path, "/ttranslatev3") != NULL &&
                        strstr(path, "IG=810EA0129C0F4C1E9A2E4B6D8F0A1B2C") != NULL);
        expect_true("the body carries the text, the pair and the token",
                    at_online_body("bing", "en", "zh-cn", "Reload Speed", body,
                                   (int)sizeof(body)) == 1 &&
                        strstr(body, "text=Reload%20Speed") != NULL &&
                        strstr(body, "fromLang=en") != NULL &&
                        strstr(body, "to=zh-Hans") != NULL &&
                        strstr(body, "token=GBaGdJt6oYKQ1Zz9Tk4m") != NULL &&
                        strstr(body, "key=1789537836335") != NULL);
        expect_true("it keeps the marker path (no multi-text form)",
                    at_online_supports_multi_text("bing") == 0);

        expect_true("a translation is read from translations[0].text",
                    at_online_parse("bing",
                                    "[{\"translations\":[{\"text\":\"\xE9\x87\x8D\xE6\x96\xB0\xE8\xA3\x85"
                                    "\xE5\xA1\xAB\xE9\x80\x9F\xE5\xBA\xA6\",\"to\":\"zh-Hans\"}],"
                                    "\"usedLLM\":true}]",
                                    out, (int)sizeof(out)) > 0 &&
                        strcmp(out, "\xE9\x87\x8D\xE6\x96\xB0\xE8\xA3\x85\xE5\xA1\xAB\xE9\x80\x9F\xE5\xBA\xA6") == 0);
        expect_true("an unsupported language is refused",
                    at_online_parse("bing", "{\"statusCode\":400,\"errorMessage\":\"\"}", out,
                                    (int)sizeof(out)) < 0);
        expect_true("an empty reply is refused (this is what the international host answers)",
                    at_online_parse("bing", "", out, (int)sizeof(out)) < 0);
        at_online_bootstrap_parse(page);
        expect_true("an expired session is refused and forgotten",
                    at_online_parse("bing", "{\"statusCode\":205,\"errorMessage\":\"\"}", out,
                                    (int)sizeof(out)) < 0 &&
                        at_online_bootstrap_ready() == 0);
        at_online_bootstrap_clear();
    }

    printf("\n== the reply buffer ==\n");
    // The caller owns the reply buffer and the core clamps it to its own maximum, so the two
    // sizes have to agree. This is not theoretical: Bing's translator page measured 645,986 bytes
    // with its session block at offset 579,411, and a 256 KB cap cut the block off the end - the
    // page arrived, looked fine, and carried no session. modules/online.lua asserts its own side.
    expect_true("the core keeps at least a whole translator page", at_core_max_body() >= 1024 * 1024);
    expect_true("and the number is stable", at_core_max_body() == at_core_max_body());

    printf("\n== multi-text batches (DeepL's own form) ==\n");
    {
        // The Lua layer joins short labels with [n] markers; DeepL takes `text=` repeatedly
        // instead, which needs no markers and costs no extra characters. Providers without that
        // form must say so, because that is what sends the caller down the marker path.
        const char* texts[3];
        char body[512];

        texts[0] = "Reload Speed";
        texts[1] = "Ammo & More";
        texts[2] = "\xE8\xA3\x85\xE5\xBC\xB9";     // 装弹, to check UTF-8 survives encoding
        expect_true("deepl multi-text body builds",
                    at_online_body_multi("deepl", "en", "zh-cn", texts, 3, body, (int)sizeof(body)) == 1 &&
                        strcmp(body,
                               "text=Reload%20Speed&text=Ammo%20%26%20More&text=%E8%A3%85%E5%BC%B9&"
                               "source_lang=EN&target_lang=ZH-HANS") == 0);
        expect_true("a single text through the multi form equals the single form",
                    at_online_body_multi("deepl", "en", "zh-cn", texts, 1, body, (int)sizeof(body)) == 1 &&
                        strcmp(body, "text=Reload%20Speed&source_lang=EN&target_lang=ZH-HANS") == 0);
        expect_true("a provider without a multi-text form says so",
                    at_online_body_multi("mymemory", "en", "zh-cn", texts, 3, body, (int)sizeof(body)) == 0);
        expect_true("the count is bounded",
                    at_online_body_multi("deepl", "en", "zh-cn", texts, 0, body, (int)sizeof(body)) == 0);
        expect_true("an unsupported target is refused",
                    at_online_body_multi("deepl", "en", "xx", texts, 2, body, (int)sizeof(body)) == 0);

        expect_true("and the capability is reported per provider",
                    at_online_supports_multi_text("deepl") == 1 &&
                        at_online_supports_multi_text("mymemory") == 0 &&
                        at_online_supports_multi_text("google_clients5") == 0 &&
                        at_online_supports_multi_text("custom") == 0);

        // The reply: one translation per input, in order.
        {
            const char* reply =
                "{\"translations\":[{\"detected_source_language\":\"EN\",\"text\":\"\xE8\xA3\x85\xE5\xBC\xB9"
                "\xE9\x80\x9F\xE5\xBA\xA6\"},{\"detected_source_language\":\"EN\",\"text\":\"\xE5\xBC\xB9"
                "\xE8\x8D\xAF\"}]}";
            expect_true("index 0 is read out",
                        at_online_parse_at("deepl", reply, 0, body, (int)sizeof(body)) > 0 &&
                            strcmp(body, "\xE8\xA3\x85\xE5\xBC\xB9\xE9\x80\x9F\xE5\xBA\xA6") == 0);
            expect_true("index 1 is read out",
                        at_online_parse_at("deepl", reply, 1, body, (int)sizeof(body)) > 0 &&
                            strcmp(body, "\xE5\xBC\xB9\xE8\x8D\xAF") == 0);
            expect_true("an index past the end fails",
                        at_online_parse_at("deepl", reply, 2, body, (int)sizeof(body)) == 0 &&
                            strstr(at_online_error(), "index 2") != NULL);
            expect_true("a marker-style provider has no indexed reply",
                        at_online_parse_at("mymemory", "{}", 0, body, (int)sizeof(body)) == 0);
        }
    }

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
    expect_true("known providers", at_online_provider_known("deepl") &&
                                       at_online_provider_known("google_api") &&
                                       at_online_provider_known("google_clients5") &&
                                       at_online_provider_known("google_gtx") &&
                                       at_online_provider_known("mymemory"));
    expect_true("unknown provider rejected", !at_online_provider_known("deepl_free") &&
                                                 !at_online_provider_known(""));
    expect_true("only the official APIs need a key", !at_online_needs_key("google_clients5") &&
                                                         !at_online_needs_key("google_gtx") &&
                                                         !at_online_needs_key("mymemory") &&
                                                         at_online_needs_key("google_api") &&
                                                         at_online_needs_key("deepl"));

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

// Runs one request and hands back the body. Pass body == NULL for a GET.
// Returns 0 when the request completed with a 2xx status, non-zero otherwise.
static int fetch(const char* host, const char* path, const char* content_type,
                 const char* headers, const char* body, char* body_out, int cap, int* out_len)
{
    int id = body ? at_http_post(host, path, content_type, headers, body)
                  : at_http_get(host, path);
    int spins = 0;

    if (id <= 0) {
        fprintf(stderr, "error: request rejected (%s)\n", at_error() ? at_error() : "?");
        return 3;
    }

    // 60 s ceiling; results are delivered by the worker thread.
    while (spins < 600) {
        int got_id = 0;
        int result = 0;
        int http_code = 0;
        int len = 0;
        unsigned long win_error = 0;
        int rc = at_http_poll(&got_id, &result, &http_code, body_out, cap, &len, &win_error);

        if (rc < 0) {
            fprintf(stderr, "error: poll failed\n");
            return 3;
        }
        if (rc == 1) {
            // transport failure
            if (result != 0) {
                printf("request id : %d\ntransport  : %d\n", got_id, result);
                if (win_error) {
                    printf("win error  : %lu (%s)\n", win_error, at_win_error_text(win_error));
                }
                if (at_error() && at_error()[0]) {
                    printf("last error : %s\n", at_error());
                }
                // 12029 = cannot connect: almost always the proxy or a blocked host
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

            // completed: the HTTP status decides
            if (http_code < 200 || http_code >= 300) {
                printf("request id : %d\nhttp status: %d\n", got_id, http_code);
                if (len > 0) {
                    int shown = len > 300 ? 300 : len;
                    printf("--- body (first %d bytes) ---\n", shown);
                    fwrite(body_out, 1, (size_t)shown, stdout);
                    printf("\n");
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
        int rc = fetch(host, path, NULL, NULL, NULL, body, BODY_CAP, &len);
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
    const char* appid = NULL;
    const char* region = NULL;
    int i;
    int rc;

    if (argc < 5) {
        fprintf(stderr, "usage: at_cli.exe provider <name> <target-lang> <text...> "
                        "[--key <api-key>] [--appid <baidu-appid>] [--region <azure-region>]\n");
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
        /* Baidu signs with an appid beside its key, and Azure puts its resource's region in a header; both
           are set on the core before a request is built, exactly as the mod does it. */
        if (_stricmp(argv[i], "--appid") == 0 && i + 1 < argc) {
            appid = argv[++i];
            continue;
        }
        if (_stricmp(argv[i], "--region") == 0 && i + 1 < argc) {
            region = argv[++i];
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

    at_online_set_appid(appid ? appid : "");
    at_online_set_region(region ? region : "");

    if (!at_online_host(name, api_key, host, (int)sizeof(host))) {
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
    printf("path     : %s\n", path);

    {
        // Providers that POST (DeepL) carry the query in the body and often need
        // an auth header; the GET family puts everything in the URL.
        char* post_body = NULL;
        char* post_headers = NULL;
        const char* ctype = NULL;
        int rc2;

        if (at_online_uses_post(name)) {
            post_body = (char*)malloc(16384);
            post_headers = (char*)malloc(1024);
            if (!post_body || !post_headers) {
                fprintf(stderr, "error: out of memory\n");
                free(path); free(body); free(post_body); free(post_headers);
                return 3;
            }
            if (!at_online_body(name, "en", lang, text, post_body, 16384)) {
                fprintf(stderr, "error: %s\n", at_online_error());
                free(path); free(body); free(post_body); free(post_headers);
                return 1;
            }
            if (!at_online_headers(name, api_key, post_headers, 1024)) {
                fprintf(stderr, "error: %s\n", at_online_error());
                free(path); free(body); free(post_body); free(post_headers);
                return 1;
            }
            ctype = at_online_content_type(name);
            printf("method   : POST\nbody     : %s\nheaders  : %s", post_body, post_headers);
        } else {
            printf("method   : GET\n");
        }
        printf("\n");

        {
            int len = 0;
            rc2 = fetch(host, path, ctype, post_headers, post_body, body, BODY_CAP, &len);
            free(post_body);
            free(post_headers);
            if (rc2 != 0) {
                free(path);
                free(body);
                return rc2;
            }
            body[len] = 0;
        }
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
// probe — is each provider actually reachable from this machine?
//
// This is the check that answers "why is nothing translating": the difference
// between a blocked host, a missing proxy and a broken parser, in one command.
// ---------------------------------------------------------------------------
static int cmd_probe(int argc, char** argv)
{
    static const char* PROVIDERS[] = { "deepl", "google_api", "google_clients5", "mymemory", NULL };
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

            if (!at_online_host(PROVIDERS[i], "PROBE", host, (int)sizeof(host))) {
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
                rc = fetch(host, path, NULL, NULL, NULL, body, BODY_CAP, &len);
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
// model — the offline engine, end to end and without the game
//   at_cli.exe model <model-dir> <target-lang> <text...>
// ---------------------------------------------------------------------------
static int cmd_model(int argc, char** argv)
{
    char out[8192];
    char text[4096];
    int i;
    int n;
    int async_mode = 0;

    if (argc < 5) {
        fprintf(stderr, "usage: at_cli.exe model <model-dir> <target-lang> <text...> "
                        "[--src <lang>] [--async] [--compute int8|int8_float32|float32|auto|default]\n");
        return 1;
    }

    text[0] = 0;
    for (i = 4; i < argc; i++) {
        // --compute <type> steers how the weights are loaded; it is not part of the text.
        if (_stricmp(argv[i], "--compute") == 0 && i + 1 < argc) {
            if (!at_set_compute_type(argv[i + 1])) {
                fprintf(stderr, "compute type: %s\n", at_model_error());
                return 1;
            }
            ++i;
            continue;
        }
        // --src <lang> says what the text is written in; it defaults to English.
        if (_stricmp(argv[i], "--src") == 0 && i + 1 < argc) {
            if (!at_set_source_lang(argv[i + 1])) {
                fprintf(stderr, "source language: %s\n", at_model_error());
                return 1;
            }
            ++i;
            continue;
        }
        // --async goes through submit/poll instead of the blocking call.
        if (_stricmp(argv[i], "--async") == 0) {
            async_mode = 1;
            continue;
        }
        // --threads N caps how many cores one translation may use (0 = all of them).
        if (_stricmp(argv[i], "--threads") == 0 && i + 1 < argc) {
            at_set_model_threads(atoi(argv[i + 1]));
            ++i;
            continue;
        }
        {
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
    }

    {
        char missing[256] = { 0 };
        int files = at_model_check_dir(argv[2], missing, (int)sizeof(missing));
        long long bytes = at_model_dir_size(argv[2]);
        printf("model dir  : %s\n", argv[2]);
        printf("files      : %d/4 present%s%s\n", files,
               files < 4 ? ", missing: " : "", missing);
        printf("size       : %.1f MB\n", (double)bytes / (1024.0 * 1024.0));

        // How many of the table's languages this model file really covers.
        {
            char absent[256] = { 0 };
            const int have = at_model_check_vocab(argv[2], absent, (int)sizeof(absent));
            printf("languages  : %d/%d present%s%s\n", have, at_model_lang_count(),
                   have < at_model_lang_count() ? ", missing: " : "", absent);
        }

        char flores[32] = { 0 };
        if (at_model_lang_code(argv[3], flores, (int)sizeof(flores))) {
            printf("lang code  : %s -> %s\n", argv[3], flores);
        } else {
            printf("lang code  : %s -> (not supported)\n", argv[3]);
        }

        printf("target     : %s\nsource     : %s\n", argv[3], text);
        printf("compute    : %s\n", at_model_compute_type());
        printf("loading...\n");
        if (!at_model_load(argv[2])) {
            fprintf(stderr, "load failed: %s\n", at_model_error());
            return 3;
        }
        printf("loaded     : ok\n");
        printf("threads    : %s of %d core(s)\n", threads_text(), at_model_core_count());

        // Show exactly what the model is fed: the source language token has to be
        // there as a token of its own (SentencePiece would shred "eng_Latn" into
        // "▁eng|_|Lat|n"), and the source EOS is what keeps NLLB from degenerating.
        {
            char pieces[2048] = { 0 };
            char fed[4096] = { 0 };
            printf("src lang   : %s\n", at_model_source_lang());
            if (at_model_tokenize(text, pieces, (int)sizeof(pieces)) >= 0) {
                printf("text pieces: %s\n", pieces);
            }
            if (at_model_pieces(text, fed, (int)sizeof(fed)) >= 0) {
                printf("fed tokens : %s\n", fed);
            }
        }
    }

    // --async exercises the path the game uses: submit must return immediately and
    // the answer is collected by polling, so the frame callback never waits.
    if (async_mode) {
        DWORD start;
        DWORD waited = 0;
        int accepted;

        start = GetTickCount();
        accepted = at_model_submit(text, argv[3]);
        printf("submit     : %d after %lu ms (returns immediately)\n", accepted,
               (unsigned long)(GetTickCount() - start));
        if (accepted != 1) {
            fprintf(stderr, "submit refused: %s\n", at_model_error());
            return 3;
        }

        for (;;) {
            n = at_model_poll(out, (int)sizeof(out));
            if (n != 0) {
                break;
            }
            if (waited > 60000) {
                fprintf(stderr, "poll timed out\n");
                return 3;
            }
            Sleep(20);
            waited += 20;
        }
        printf("polled     : after ~%lu ms\n", (unsigned long)waited);
        if (n < 0) {
            fprintf(stderr, "translate failed: rc=%d (%s)\n", n, at_model_error());
            return 3;
        }
        printf("result     : %s\n", out);
        printf("bytes      : %d\n", n);
        return 0;
    }

    n = at_model_translate(text, argv[3], out, (int)sizeof(out));
    if (n < 0) {
        fprintf(stderr, "translate failed: rc=%d (%s)\n", n, at_model_error());
        return 3;
    }
    printf("result     : %s\n", out);
    printf("bytes      : %d\n", n);
    return 0;
}

// Collects a finished job, giving up after a minute.
//
// Every wait here needs a deadline: an unbounded `Sleep` loop that waits for a result
// nobody will produce looks exactly like a hang - the process sits at 0% CPU and never
// returns, which is what happened when the pairing check below ran with a single string.
#define POLL_TIMEOUT_MS 60000
static int poll_result(char* out, int cap)
{
    const DWORD start = GetTickCount();
    for (;;) {
        const int n = at_poll(out, cap);
        if (n != 0) {
            return n;
        }
        if (GetTickCount() - start > POLL_TIMEOUT_MS) {
            fprintf(stderr, "no result after %d ms\n", POLL_TIMEOUT_MS);
            return -100;
        }
        Sleep(5);
    }
}

// ---------------------------------------------------------------------------
// queue — translate several strings in sequence, the way the game's queue does
//
// This is the regression test for the pairing between a submitted string and the
// answer that comes back. One translate proves nothing here: an off-by-one only
// shows up on the second and later items, which is exactly the bug this
// reproduces (stored translations belonging to the previous key).
// ---------------------------------------------------------------------------
static int cmd_queue(int argc, char** argv)
{
    char out[8192] = { 0 };
    const char* dir;
    const char* lang;
    int i;
    int problems = 0;

    if (argc < 5) {
        fprintf(stderr, "usage: at_cli.exe queue <model-dir> <target-lang> <text> [text...] [--threads N]\n");
        return 1;
    }
    dir = argv[2];
    lang = argv[3];

    // --threads N is not part of the text; it caps how many cores one translation may
    // use, which is what the mod does so the game keeps its own.
    for (i = 4; i < argc; i++) {
        if (_stricmp(argv[i], "--threads") == 0 && i + 1 < argc) {
            at_set_model_threads(atoi(argv[i + 1]));
            continue;
        }
    }

    printf("loading     : %s\n", dir);
    if (!at_model_load(dir)) {
        fprintf(stderr, "load failed: %s\n", at_model_error());
        return 3;
    }
    printf("threads     : %s of %d core(s)\n", threads_text(), at_model_core_count());

    // The regression this command exists for: a submit issued while the previous
    // string is still being translated must be refused. It used to be accepted, and
    // the core then held two results while the caller polled one per frame, which
    // shifted every later translation onto the next key.
    //
    // It needs two strings, so it is skipped when only one was given - which is how
    // this command once ended up waiting forever for a result that was never
    // submitted.
    if (argc >= 6) {
        int first = at_submit(argv[4], lang);
        int second = first == 1 ? at_submit(argv[5], lang) : 0;
        int n;

        printf("double submit: first=%d second=%d (second must be 0)\n", first, second);
        if (first == 1 && second != 0) {
            printf("FAIL: a second submit was accepted while the first was running\n");
            problems++;
        }

        // Collect the first one; it must belong to the first string.
        n = poll_result(out, (int)sizeof(out));
        printf("first result : %s -> %s\n", argv[4], n > 0 ? out : at_model_error());

        // Then the second, which was refused and has to be submitted again.
        if (second == 0 && at_submit(argv[5], lang) != 1) {
            printf("FAIL: the refused string could not be submitted afterwards\n");
            problems++;
        } else {
            n = poll_result(out, (int)sizeof(out));
            printf("second result: %s -> %s\n", argv[5], n > 0 ? out : at_model_error());
        }
    }

    for (i = 4; i < argc; i++) {
        const char* text = argv[i];
        int accepted;
        int n;

        // Flags are not strings to translate. The index in the label counts only the
        // real strings, so it still lines up with the caller's list.
        if (_stricmp(text, "--threads") == 0) {
            continue;
        }

        accepted = at_submit(text, lang);
        if (accepted != 1) {
            printf("[%02d] %-34s -> submit refused (%d): %s\n", i - 3, text, accepted, at_model_error());
            problems++;
            continue;
        }

        n = poll_result(out, (int)sizeof(out));

        if (n < 0) {
            printf("[%02d] %-34s -> FAILED %s\n", i - 3, text, at_model_error());
            problems++;
        } else {
            printf("[%02d] %-34s -> %s\n", i - 3, text, out);
        }
    }

    printf("%d item(s), %d problem(s)\n", argc - 4, problems);
    return problems ? 1 : 0;
}

// ---------------------------------------------------------------------------
// switch — what happens when a second model is asked for
//
// The engine must never hold two models: the game process would carry 1.7 GB plus
// 3.8 GB for a queue that can only use one, and the objects of the first model are
// never released (see at_model.cpp). So the second request has to be a no-op, and the
// caller has to be able to *tell* - at_model_loaded_dir() is how. This command is the
// proof: load A, translate, ask for B, and show that the loaded directory, the thread
// count and the answer are all still A's.
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// fetch — the model downloader, driven from the command line
//
// Same code path the mod uses: streamed to disk, resumed when the file is already
// partially there, verified against a pinned checksum at the end, and cancellable.
// The mirror is chosen by the URL, and a failure retries the other Hugging Face host.
//
//   at_cli.exe fetch <url> <out-path> [--sha256 <hex>] [--cancel-after <ms>]
// ---------------------------------------------------------------------------
static int cmd_fetch(int argc, char** argv)
{
    const char* url;
    const char* out_path;
    const char* sha = NULL;
    int cancel_after = 0;
    int i;
    DWORD start;

    if (argc < 4) {
        fprintf(stderr, "usage: at_cli.exe fetch <url> <out-path> [--sha256 <hex>] [--cancel-after <ms>]\n");
        return 1;
    }
    url = argv[2];
    out_path = argv[3];
    for (i = 4; i < argc; i++) {
        if (_stricmp(argv[i], "--sha256") == 0 && i + 1 < argc) {
            sha = argv[++i];
        } else if (_stricmp(argv[i], "--cancel-after") == 0 && i + 1 < argc) {
            cancel_after = atoi(argv[++i]);
        } else if (_stricmp(argv[i], "--proxy-mode") == 0 && i + 1 < argc) {
            const char* mode = argv[++i];
            if (_stricmp(mode, "auto") == 0) {
                at_download_use_proxy(-1);
            } else if (_stricmp(mode, "direct") == 0) {
                at_download_use_proxy(0);
            } else if (_stricmp(mode, "proxy") == 0) {
                at_download_use_proxy(1);
            } else {
                fprintf(stderr, "--proxy-mode takes auto, direct or proxy\n");
                return 1;
            }
        }
    }

    printf("fetching   : %s\n", url);
    printf("to         : %s\n", out_path);
    printf("route      : %s%s\n",
           at_download_route_is_proxied(url) ? "through the proxy " : "direct ",
           at_download_proxy_mode() < 0 ? "(decided by host)" : "(forced)");
    {
        long long existing = at_file_size64(out_path);
        if (existing > 0) {
            printf("resuming   : %lld byte(s) already there\n", existing);
        }
    }

    if (at_download_start(url, out_path, sha) != 1) {
        fprintf(stderr, "cannot start: %s\n", at_download_error());
        return 3;
    }

    start = GetTickCount();
    for (;;) {
        int status = at_download_status();
        long long got = at_download_received();
        long long total = at_download_total();
        DWORD elapsed = GetTickCount() - start;

        if (cancel_after > 0 && (int)elapsed >= cancel_after) {
            printf("\ncancelling after %d ms\n", cancel_after);
            at_download_cancel();
            cancel_after = 0;              // once
        }

        if (status != 1) {
            printf("\n");
            if (status == 2) {
                printf("done       : %lld byte(s) in %.1f s\n", got, elapsed / 1000.0);
                if (sha) {
                    char actual[65] = { 0 };
                    if (at_sha256_file(out_path, actual, (int)sizeof(actual))) {
                        printf("sha256     : %s\n", actual);
                        printf("checksum   : %s\n", _stricmp(actual, sha) == 0 ? "ok" : "MISMATCH");
                    }
                }
                return 0;
            }
            if (status == 4) {
                printf("cancelled  : %lld byte(s) kept for the next attempt\n", got);
                return 4;
            }
            fprintf(stderr, "failed     : %s\n", at_download_error());
            return 3;
        }

        if (total > 0) {
            printf("\r  %lld / %lld MB (%.1f%%)", got / (1024 * 1024), total / (1024 * 1024),
                   100.0 * (double)got / (double)total);
        } else {
            printf("\r  %lld MB", got / (1024 * 1024));
        }
        fflush(stdout);
        Sleep(200);
    }
}

// hash — the checksum of a file (and its size), for verifying a model directory by hand.
static int cmd_hash(int argc, char** argv)
{
    char hex[65] = { 0 };
    long long size;

    if (argc < 3) {
        fprintf(stderr, "usage: at_cli.exe hash <file>\n");
        return 1;
    }
    size = at_file_size64(argv[2]);
    if (size < 0) {
        fprintf(stderr, "cannot read %s\n", argv[2]);
        return 3;
    }
    if (!at_sha256_file(argv[2], hex, (int)sizeof(hex))) {
        fprintf(stderr, "hashing %s failed\n", argv[2]);
        return 3;
    }
    printf("file   : %s\n", argv[2]);
    printf("size   : %lld\n", size);
    printf("sha256 : %s\n", hex);
    return 0;
}

// ---------------------------------------------------------------------------
// jsonpath — read one string out of a JSON file at a "a.b.0.c" path
//
// The custom API engine's response shape is a setting, not a constant, so the extraction
// has to be testable without a live endpoint: point this at a captured response and the
// path you configured.
//
//   at_cli.exe jsonpath <file.json> <path>
// ---------------------------------------------------------------------------
static int cmd_jsonpath(int argc, char** argv)
{
    FILE* f;
    long size;
    char* body;
    char out[8192] = { 0 };

    if (argc < 4) {
        fprintf(stderr, "usage: at_cli.exe jsonpath <file.json> <path like choices.0.message.content>\n");
        return 1;
    }
    f = fopen(argv[2], "rb");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", argv[2]);
        return 3;
    }
    fseek(f, 0, SEEK_END);
    size = ftell(f);
    fseek(f, 0, SEEK_SET);
    body = (char*)malloc((size_t)size + 1);
    if (!body) {
        fclose(f);
        return 3;
    }
    if (fread(body, 1, (size_t)size, f) != (size_t)size) {
        fprintf(stderr, "short read on %s\n", argv[2]);
        free(body);
        fclose(f);
        return 3;
    }
    body[size] = 0;
    fclose(f);

    if (!at_json_string_at(body, argv[3], out, (int)sizeof(out))) {
        fprintf(stderr, "no value: %s\n", at_error());
        free(body);
        return 3;
    }
    printf("%s\n", out);
    free(body);
    return 0;
}

static int cmd_switch(int argc, char** argv)
{
    char out[8192] = { 0 };
    char loaded[1024] = { 0 };
    const char* second;
    const char* lang = argc > 4 ? argv[4] : "zh-tw";
    int n;

    if (argc < 4) {
        fprintf(stderr, "usage: at_cli.exe switch <dir-a> <dir-b> [target-lang]\n");
        return 1;
    }
    second = argv[3];

    printf("load A       : %s -> %d\n", argv[2], at_model_load(argv[2]));
    at_model_loaded_dir(loaded, (int)sizeof(loaded));
    printf("loaded dir   : %s\n", loaded);
    printf("threads      : %s of %d core(s)\n", threads_text(), at_model_core_count());

    n = at_model_translate("Reload Speed", lang, out, (int)sizeof(out));
    printf("answer A     : %s\n", n > 0 ? out : at_model_error());

    printf("load B       : %s -> %d (1 = same model, <0 = refused: one model per process)\n",
           second, at_model_load(second));
    at_model_loaded_dir(loaded, (int)sizeof(loaded));
    printf("loaded dir   : %s\n", loaded);
    printf("threads      : %s of %d core(s)\n", threads_text(), at_model_core_count());

    n = at_model_translate("Reload Speed", lang, out, (int)sizeof(out));
    printf("answer B     : %s\n", n > 0 ? out : at_model_error());

    printf("\ntwo models resident would be ~5.5 GB; the working set of this process says whether it is one\n");
    return 0;
}

// ---------------------------------------------------------------------------
// load — the model startup path the game uses
//
// Start the load, then poll the status the way a frame callback would. The point is
// that nothing here waits on the disk: the first call returns at once and the loading
// happens on a background thread.
// ---------------------------------------------------------------------------
static int cmd_load(int argc, char** argv)
{
    char out[8192] = { 0 };
    char text[4096] = { 0 };
    const char* dir;
    DWORD start;
    int status;
    int rc;
    int i;
    int n;

    if (argc < 3) {
        fprintf(stderr, "usage: at_cli.exe load <model-dir> [target-lang] [text...]\n");
        return 1;
    }
    dir = argv[2];

    printf("model dir  : %s\n", dir);
    printf("files      : %d/4 present\n", at_set_model_dir(dir));

    start = GetTickCount();
    rc = at_load_model_async();
    printf("start      : rc=%d after %lu ms (returns immediately)\n", rc,
           (unsigned long)(GetTickCount() - start));
    if (rc < 0) {
        fprintf(stderr, "load refused: %s\n", at_model_error());
        return 3;
    }

    // What the frame callback does: read the status, keep drawing, come back.
    for (;;) {
        status = at_model_status();
        if (status != 3) {
            break;
        }
        if (GetTickCount() - start > 120000) {
            fprintf(stderr, "load timed out\n");
            return 3;
        }
        Sleep(50);
    }
    printf("status     : %d after %lu ms (%s)\n", status, (unsigned long)(GetTickCount() - start),
           status == 2 ? "loaded and ready" : "not loaded");
    if (status != 2) {
        fprintf(stderr, "load failed: %s\n", at_model_error());
        return 3;
    }

    if (argc >= 5) {
        for (i = 4; i < argc; i++) {
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

        rc = at_submit(text, argv[3]);
        printf("submit     : %d\n", rc);
        if (rc != 1) {
            fprintf(stderr, "submit refused: %s\n", at_model_error());
            return 3;
        }
        n = poll_result(out, (int)sizeof(out));
        if (n < 0) {
            fprintf(stderr, "translate failed: %s\n", at_model_error());
            return 3;
        }
        printf("result     : %s\n", out);
    }

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
    const char* names[4];
    char loaded[1024] = { 0 };
    names[0] = "no model";
    names[1] = "model files present";
    names[2] = "model loaded and ready";
    names[3] = "loading";

    printf("at_core available : %s\n", at_available() ? "yes" : "no");
    printf("at_core version   : %s\n", at_version() ? at_version() : "(null)");
    printf("model status      : %d (%s)\n", status,
           (status >= 0 && status <= 3) ? names[status] : "unknown");
    at_model_loaded_dir(loaded, (int)sizeof(loaded));
    if (loaded[0]) {
        printf("model loaded from : %s\n", loaded);
    }
    printf("threads           : %s of %d core(s)\n", threads_text(), at_model_core_count());
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
    printf("  at_cli.exe provider <name> <target-lang> <text...> [--key <k>] [--appid <baidu>] [--region <azure>]\n");
    printf("  at_cli.exe model <model-dir> <target-lang> <text...>  (offline NLLB, no network)\n");
    printf("             [--src en|zh-cn|ja|...] [--compute int8|int8_float32|float32|auto|default]\n");
    printf("             [--threads N]   (default: half the cores; 0 = all of them)\n");
    printf("  at_cli.exe load <model-dir> [target-lang] [text...]    (async load + submit/poll)\n");
    printf("  at_cli.exe switch <dir-a> <dir-b> [target-lang]        (what a second load does)\n");
    printf("  at_cli.exe fetch <url> <out-path> [--sha256 <hex>] [--cancel-after <ms>]\n");
    printf("             [--proxy-mode auto|direct|proxy]   (default: by host - the mirror direct)\n");
    printf("  at_cli.exe hash <file>\n\n");
    printf("providers: google_clients5, google_gtx, mymemory, google_api\n");
    printf("any command accepts --proxy <host:port> (e.g. --proxy 127.0.0.1:7890)\n");
}

int main(int argc, char** argv)
{
    int rc;

    // Make UTF-8 output readable instead of mojibake on a non-UTF-8 console.
    SetConsoleOutputCP(CP_UTF8);

    // ...and make UTF-8 *input* arrive intact (see use_utf8_argv).
    use_utf8_argv();

    strip_proxy_args(g_argc, g_argv);
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
    } else if (_stricmp(argv[1], "model") == 0) {
        rc = cmd_model(argc, argv);
    } else if (_stricmp(argv[1], "load") == 0) {
        rc = cmd_load(argc, argv);
    } else if (_stricmp(argv[1], "queue") == 0) {
        rc = cmd_queue(argc, argv);
    } else if (_stricmp(argv[1], "switch") == 0) {
        rc = cmd_switch(argc, argv);
    } else if (_stricmp(argv[1], "fetch") == 0) {
        rc = cmd_fetch(argc, argv);
    } else if (_stricmp(argv[1], "hash") == 0) {
        rc = cmd_hash(argc, argv);
    } else if (_stricmp(argv[1], "jsonpath") == 0) {
        rc = cmd_jsonpath(argc, argv);
    } else {
        fprintf(stderr, "unknown command: %s\n", argv[1]);
        usage();
        rc = 1;
    }

    return rc;
}
