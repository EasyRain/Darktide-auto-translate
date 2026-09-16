// at_core.c — Auto Translate native core.
//
// Part 1 (this file): async HTTP GET on a worker thread via WinHTTP, so the Lua
// side can just enqueue requests and poll for results once per frame.
//
// Deliberately dependency-free: WinHTTP ships with Windows, so the mod needs no
// extra runtime. The same DLL will later host the CTranslate2 local-model
// inference (its own build step), which is why it is a separate native core.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "at_core.h"
#include "at_model.h"
#include "at_json.h"

// How much of a response body is kept. Almost every reply is a few hundred bytes (a
// translation API answers with JSON about the size of the text), but one is not: Bing's
// keyless flow needs its translator page, which measured 645,986 bytes with the session block
// at offset 579,411 - past 256 KB, where this used to stop, so the page arrived truncated and
// the session could never be read. The cap is applied by clamping the caller's buffer, so this
// constant and BODY_CAP in modules/online.lua have to agree; the memory is that buffer, once.
#define AT_MAX_BODY (1536 * 1024)
#define AT_TIMEOUT_MS 20000

typedef struct Job {
    int id;
    int post;              // 0 = GET, 1 = POST
    char* host;
    char* path;
    char* content_type;    // POST only
    char* headers;         // extra header block, "Name: value\r\n"
    char* body;            // POST only
    struct Job* next;
} Job;

typedef struct Result {
    int id;
    int status;      // 0 = the request completed, <0 = transport failure (-10..-15)
    int http_code;   // meaningful only when status == 0 (200, 404, ...)
    char* body;
    int len;
    DWORD win_error;
    struct Result* next;
} Result;

static CRITICAL_SECTION g_lock;
static int g_inited = 0;
static HANDLE g_thread = NULL;
static volatile LONG g_stop = 0;
static int g_next_id = 1;
static Job* g_jobs_head = NULL;
static Job* g_jobs_tail = NULL;
static Result* g_results_head = NULL;
static Result* g_results_tail = NULL;
static char g_error[256] = { 0 };
static DWORD g_win_error = 0;

// ---------------------------------------------------------------------------
// Proxy resolution
//
// WinHTTP keeps its own proxy configuration and does NOT read the Windows
// (WinINET) settings that VPN clients write when you flip their "system proxy"
// switch. On a machine that needs a proxy to reach Google, this is the difference
// between working and a bare 12029 "cannot connect".
//
// So: if Windows has a proxy enabled, use it. If the player types one in the mod
// options, that wins. If Windows has an address configured but switched off, say
// so instead of leaving them guessing.
// ---------------------------------------------------------------------------
static wchar_t g_proxy[256] = { 0 };        // explicit override (from the mod/CLI)
static wchar_t g_proxy_system[256] = { 0 }; // detected from the Windows settings
static wchar_t g_proxy_bypass[512] = { 0 };
static int g_proxy_system_enabled = 0;
static int g_proxy_system_known = 0;
static char g_proxy_hint[512] = { 0 };

static void set_error(const char* msg);

static void utf8_from_wide(const wchar_t* src, char* out, int cap)
{
    if (!out || cap <= 0) {
        return;
    }
    out[0] = 0;
    if (!src) {
        return;
    }
    WideCharToMultiByte(CP_UTF8, 0, src, -1, out, cap, NULL, NULL);
}

// "http=1.2.3.4:80;https=1.2.3.4:443" -> "1.2.3.4:443". A bare "host:port" is
// used as is. WinINET stores either form depending on the client.
static int pick_proxy_from_list(const wchar_t* list, wchar_t* out, int cap)
{
    const wchar_t* p = list;
    int out_len = 0;

    out[0] = 0;

    if (!list || !*list) {
        return 0;
    }
    if (!wcschr(list, L'=')) {
        wcsncpy_s(out, (size_t)cap, list, _TRUNCATE);
        return out[0] != 0;
    }

    while (*p) {
        const wchar_t* eq = wcschr(p, L'=');
        const wchar_t* end;
        size_t name_len;
        int wanted = 0;

        if (!eq) {
            break;
        }
        end = wcschr(eq, L';');
        if (!end) {
            end = eq + wcslen(eq);
        }

        name_len = (size_t)(eq - p);
        if (name_len == 5 && _wcsnicmp(p, L"https", 5) == 0) {
            wanted = 1;
        } else if (name_len == 4 && _wcsnicmp(p, L"http", 4) == 0 && out[0] == 0) {
            wanted = 1; // fall back to the http entry when there is no https one
        }

        if (wanted) {
            size_t n = (size_t)(end - (eq + 1));
            if (n >= (size_t)cap) {
                n = (size_t)cap - 1;
            }
            memcpy(out, eq + 1, n * sizeof(wchar_t));
            out[n] = 0;
            out_len = (int)n;
            if (name_len == 5) {
                return out_len > 0; // https entry is the best match, stop here
            }
        }

        p = (*end == L';') ? end + 1 : end;
    }

    return out[0] != 0;
}

static void detect_system_proxy(void)
{
    HKEY key = NULL;
    DWORD enable = 0;
    DWORD size;
    DWORD type;
    wchar_t server[512];

    if (g_proxy_system_known) {
        return;
    }
    g_proxy_system_known = 1;

    if (RegOpenKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings",
                      0, KEY_READ, &key) != ERROR_SUCCESS) {
        return;
    }

    size = sizeof(enable);
    if (RegQueryValueExW(key, L"ProxyEnable", NULL, &type, (LPBYTE)&enable, &size) != ERROR_SUCCESS) {
        enable = 0;
    }

    server[0] = 0;
    size = sizeof(server);
    if (RegQueryValueExW(key, L"ProxyServer", NULL, &type, (LPBYTE)server, &size) != ERROR_SUCCESS) {
        server[0] = 0;
    }

    {
        wchar_t bypass[512];
        bypass[0] = 0;
        size = sizeof(bypass);
        if (RegQueryValueExW(key, L"ProxyOverride", NULL, &type, (LPBYTE)bypass, &size) == ERROR_SUCCESS) {
            wcsncpy_s(g_proxy_bypass, 512, bypass, _TRUNCATE);
        }
    }

    RegCloseKey(key);

    if (server[0]) {
        pick_proxy_from_list(server, g_proxy_system, 256);
    }

    if (enable && g_proxy_system[0]) {
        g_proxy_system_enabled = 1;
    } else if (!enable && g_proxy_system[0]) {
        // Configured but switched off - the classic "Clash system proxy is off" trap.
        _snprintf_s(g_proxy_hint, sizeof(g_proxy_hint), _TRUNCATE,
                    "Windows has a proxy configured (%ls) but it is switched off. WinHTTP does not read the "
                    "Windows proxy setting anyway: either turn the VPN's system proxy on and enter the same "
                    "address in this mod's 'Proxy' option, or use the VPN's TUN mode.",
                    g_proxy_system);
    }
}

// 1 when a proxy will be used, and fills `out` with it (wide).
static int effective_proxy(wchar_t* out, int cap)
{
    detect_system_proxy();
    if (g_proxy[0]) {
        wcsncpy_s(out, (size_t)cap, g_proxy, _TRUNCATE);
        return 1;
    }
    if (g_proxy_system_enabled && g_proxy_system[0]) {
        wcsncpy_s(out, (size_t)cap, g_proxy_system, _TRUNCATE);
        return 1;
    }
    return 0;
}

// The proxy in use, as a wide string, for code that opens its own WinHTTP session (the
// model downloader). Returns 1 when a proxy is configured, 0 for a direct connection.
int at_proxy_wide(wchar_t* out, int cap)
{
    if (!out || cap <= 0) {
        return 0;
    }
    out[0] = 0;
    return effective_proxy(out, cap);
}

int at_set_proxy(const char* hostport_utf8)
{
    wchar_t wide[256];

    g_proxy[0] = 0;
    if (hostport_utf8 && *hostport_utf8) {
        if (MultiByteToWideChar(CP_UTF8, 0, hostport_utf8, -1, wide, 256) <= 0) {
            set_error("proxy address is not valid UTF-8");
            return 0;
        }
        wcsncpy_s(g_proxy, 256, wide, _TRUNCATE);
    }
    return 1;
}

const char* at_proxy_in_use(void)
{
    static char buffer[320];
    wchar_t wide[256];

    if (effective_proxy(wide, 256)) {
        char narrow[256];
        utf8_from_wide(wide, narrow, (int)sizeof(narrow));
        _snprintf_s(buffer, sizeof(buffer), _TRUNCATE, "%s (%s)", narrow,
                    g_proxy[0] ? "set in the mod options" : "from the Windows settings");
    } else {
        _snprintf_s(buffer, sizeof(buffer), _TRUNCATE, "none (direct connection)");
    }
    return buffer;
}

const char* at_proxy_hint(void)
{
    detect_system_proxy();
    // moot once a proxy has been set explicitly
    if (g_proxy[0]) {
        return "";
    }
    return g_proxy_hint;
}

static void set_error(const char* msg)
{
    strncpy_s(g_error, sizeof(g_error), msg ? msg : "unknown", _TRUNCATE);
}

// Record the Win32/WinHTTP error of the call that just failed. A bare "-13" tells
// nobody anything; the CLI decodes this into the real message.
static int fail_with(int code)
{
    g_win_error = GetLastError();
    return code;
}

static DWORD last_win_error(void)
{
    return g_win_error;
}

static char* dup_str(const char* s)
{
    size_t n;
    char* out;
    if (!s) {
        return NULL;
    }
    n = strlen(s) + 1;
    out = (char*)malloc(n);
    if (out) {
        memcpy(out, s, n);
    }
    return out;
}

static void push_result(int id, int status, int http_code, char* body, int len, DWORD win_error)
{
    Result* r = (Result*)malloc(sizeof(Result));
    if (!r) {
        free(body);
        return;
    }
    r->id = id;
    r->status = status;
    r->http_code = http_code;
    r->body = body;
    r->len = len;
    r->win_error = win_error;
    r->next = NULL;

    EnterCriticalSection(&g_lock);
    if (g_results_tail) {
        g_results_tail->next = r;
    } else {
        g_results_head = r;
    }
    g_results_tail = r;
    LeaveCriticalSection(&g_lock);
}

// Reads the whole response body into a malloc'ed buffer.
static char* read_body(HINTERNET request, int* out_len)
{
    char* buffer = NULL;
    int capacity = 0;
    int used = 0;

    for (;;) {
        DWORD available = 0;
        DWORD read = 0;

        if (!WinHttpQueryDataAvailable(request, &available)) {
            break;
        }
        if (available == 0) {
            break;
        }
        if (used + (int)available + 1 > capacity) {
            int want = used + (int)available + 1;
            char* grown;
            if (want > AT_MAX_BODY) {
                want = AT_MAX_BODY;
            }
            if (want <= capacity) {
                break; // body limit reached
            }
            grown = (char*)realloc(buffer, want);
            if (!grown) {
                break;
            }
            buffer = grown;
            capacity = want;
        }
        if (!WinHttpReadData(request, buffer + used, (DWORD)(capacity - used - 1), &read)) {
            break;
        }
        used += (int)read;
    }

    if (buffer) {
        buffer[used] = 0;
    }
    *out_len = used;
    return buffer;
}

// Alternate host for a host that is served twice, or NULL.
//
// Google serves the Translation v2 API on both translation.googleapis.com and
// www.googleapis.com. Measured here: through a proxy tunnel the canonical host
// completes the CONNECT (HTTP 200) and then never finishes the TLS handshake,
// while the other one answers with Google's own "API key not valid" JSON - the
// same API, reachable. So a transport failure gets one retry on the alternate
// name rather than failing every Google translation on such a network.
static const char* fallback_host_for(const char* host)
{
    if (host && _stricmp(host, "translation.googleapis.com") == 0) {
        return "www.googleapis.com";
    }
    return NULL;
}

// `out_status` is 0 when the request completed and negative on a transport
// failure; `out_http_code` carries the HTTP status in the completed case. They are
// separate on purpose: one value meaning both "no error" and "the 200 we got" is
// exactly how a caller ends up treating every successful response as a failure.
static void do_http(const Job* job, int* out_status, int* out_http_code, char** out_body, int* out_len)
{
    HINTERNET session = NULL;
    HINTERNET connect = NULL;
    HINTERNET request = NULL;
    wchar_t whost[256];
    wchar_t wpath[2048];
    wchar_t headers[1024];
    char hbuf[256];
    INTERNET_PORT port = INTERNET_DEFAULT_HTTPS_PORT;
    DWORD flags = WINHTTP_FLAG_SECURE;
    const char* bare_host = job->host;
    const char* path = job->path;
    int status = 0;
    int http_code = 0;
    int failure = 0;
    char* body = NULL;
    int len = 0;
    DWORD body_len = 0;

    *out_status = -1;
    *out_http_code = 0;
    *out_body = NULL;
    *out_len = 0;
    g_win_error = 0;

    // The caller may prefix the host with a scheme. Everything we talk to in
    // production is HTTPS; the plaintext branch exists so the CLI can smoke test
    // local endpoints without a certificate.
    if (_strnicmp(job->host, "http://", 7) == 0) {
        bare_host = job->host + 7;
        port = INTERNET_DEFAULT_HTTP_PORT;
        flags = 0;
    } else if (_strnicmp(job->host, "https://", 8) == 0) {
        bare_host = job->host + 8;
    }

    // An explicit ":port" (or "[v6]:port") overrides the scheme default. The port
    // must be removed from the host string: WinHttpConnect takes the port as its
    // own argument and would otherwise try to resolve "host:port" as a name.
    // hbuf lives in the function scope because bare_host points into it.
    {
        size_t n = strlen(bare_host);
        char* colon = NULL;

        if (n >= sizeof(hbuf)) {
            *out_status = -2;
            return;
        }
        memcpy(hbuf, bare_host, n + 1);

        if (hbuf[0] == '[') {
            char* close = strchr(hbuf, ']');
            if (close) {
                colon = (close[1] == ':') ? close + 1 : NULL;
                if (colon) {
                    *close = 0; // drop the ']' so only the address remains
                }
            }
        } else {
            colon = strrchr(hbuf, ':');
        }

        if (colon) {
            long parsed = strtol(colon + 1, NULL, 10);
            if (parsed > 0 && parsed <= 65535) {
                port = (INTERNET_PORT)parsed;
                *colon = 0;
            } else {
                *out_status = -4; // malformed port
                return;
            }
        }
        bare_host = hbuf;

        if (MultiByteToWideChar(CP_UTF8, 0, bare_host, -1, whost, 256) <= 0) {
            *out_status = -2;
            return;
        }
    }

    if (MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, 2048) <= 0) {
        *out_status = -3;
        return;
    }

    session = WinHttpOpen(L"AutoTranslate/0.1", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                          WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) {
        *out_status = fail_with(-10);
        return;
    }
    WinHttpSetTimeouts(session, AT_TIMEOUT_MS, AT_TIMEOUT_MS, AT_TIMEOUT_MS, AT_TIMEOUT_MS);

    // A session-level proxy is the portable way to do this: WinHttpSetOption
    // works on every supported Windows, unlike the AUTOMATIC_PROXY access type.
    {
        wchar_t proxy[256];
        if (effective_proxy(proxy, 256)) {
            WINHTTP_PROXY_INFO info;
            info.dwAccessType = WINHTTP_ACCESS_TYPE_NAMED_PROXY;
            info.lpszProxy = proxy;
            info.lpszProxyBypass = g_proxy_bypass[0] ? g_proxy_bypass : NULL;
            if (!WinHttpSetOption(session, WINHTTP_OPTION_PROXY, &info, sizeof(info))) {
                g_win_error = GetLastError();
            }
        }
    }

    connect = WinHttpConnect(session, whost, port, 0);
    if (!connect) {
        failure = fail_with(-11);
        goto done;
    }

    request = WinHttpOpenRequest(connect, job->post ? L"POST" : L"GET", wpath, NULL, WINHTTP_NO_REFERER,
                                 WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!request) {
        failure = fail_with(-12);
        goto done;
    }

    // Accept, plus whatever the caller needs (DeepL wants an Authorization line),
    // plus a Content-Type when there is a body.
    {
        wchar_t wextra[768];
        wchar_t wtype[128];

        headers[0] = 0;
        wcscat_s(headers, 1024, L"Accept: application/json\r\n");

        if (job->headers && job->headers[0] &&
            MultiByteToWideChar(CP_UTF8, 0, job->headers, -1, wextra, 768) > 0) {
            wcscat_s(headers, 1024, wextra);
        }
        if (job->post && job->content_type && job->content_type[0] &&
            MultiByteToWideChar(CP_UTF8, 0, job->content_type, -1, wtype, 128) > 0) {
            wcscat_s(headers, 1024, L"Content-Type: ");
            wcscat_s(headers, 1024, wtype);
            wcscat_s(headers, 1024, L"\r\n");
        }
    }

    if (job->post) {
        body_len = (DWORD)strlen(job->body ? job->body : "");
    }

    if (!WinHttpSendRequest(request, headers, (DWORD)-1L,
                            job->post ? (LPVOID)job->body : WINHTTP_NO_REQUEST_DATA,
                            body_len, body_len, 0)) {
        failure = fail_with(-13);
        goto done;
    }
    if (!WinHttpReceiveResponse(request, NULL)) {
        failure = fail_with(-14);
        goto done;
    }

    {
        DWORD code = 0;
        DWORD size = sizeof(code);
        if (WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                WINHTTP_HEADER_NAME_BY_INDEX, &code, &size, WINHTTP_NO_HEADER_INDEX)) {
            http_code = (int)code;
        } else {
            failure = fail_with(-15);
            goto done;
        }
    }

    body = read_body(request, &len);

done:
    if (request) {
        WinHttpCloseHandle(request);
    }
    if (connect) {
        WinHttpCloseHandle(connect);
    }
    if (session) {
        WinHttpCloseHandle(session);
    }

    // never let a later assignment hide an earlier failure
    *out_status = failure ? failure : 0;
    *out_http_code = failure ? 0 : http_code;
    *out_body = body;
    *out_len = len;
}

static DWORD WINAPI worker_main(LPVOID param)
{
    (void)param;

    for (;;) {
        Job* job = NULL;
        int stop;

        EnterCriticalSection(&g_lock);
        if (g_jobs_head) {
            job = g_jobs_head;
            g_jobs_head = job->next;
            if (!g_jobs_head) {
                g_jobs_tail = NULL;
            }
        }
        stop = (int)g_stop;
        LeaveCriticalSection(&g_lock);

        if (!job) {
            if (stop) {
                break;
            }
            Sleep(20);
            continue;
        }

        {
            int status = 0;
            int http_code = 0;
            char* body = NULL;
            int len = 0;
            DWORD win_error = 0;
            do_http(job, &status, &http_code, &body, &len);

            // One transport-level retry on an alternate host, for the single host
            // we know is served twice. A completed response is never retried, so a
            // 400 "API key not valid" stays a 400.
            if (status < 0) {
                const char* alternate_host = fallback_host_for(job->host);
                if (alternate_host) {
                    Job alternate = *job;
                    alternate.host = (char*)alternate_host;
                    do_http(&alternate, &status, &http_code, &body, &len);
                }
            }

            if (status < 0) {
                win_error = last_win_error();
            }
            push_result(job->id, status, http_code, body, len, win_error);
        }

        free(job->host);
        free(job->path);
        free(job->content_type);
        free(job->headers);
        free(job->body);
        free(job);
    }

    return 0;
}

static void shutdown_core(void)
{
    if (!g_inited) {
        return;
    }
    InterlockedExchange(&g_stop, 1);
    if (g_thread) {
        WaitForSingleObject(g_thread, 3000);
        CloseHandle(g_thread);
        g_thread = NULL;
    }

    while (g_jobs_head) {
        Job* j = g_jobs_head;
        g_jobs_head = j->next;
        free(j->host);
        free(j->path);
        free(j->content_type);
        free(j->headers);
        free(j->body);
        free(j);
    }
    while (g_results_head) {
        Result* r = g_results_head;
        g_results_head = r->next;
        free(r->body);
        free(r);
    }
    g_jobs_tail = NULL;
    g_results_tail = NULL;

    DeleteCriticalSection(&g_lock);
    g_inited = 0;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved)
{
    (void)instance;
    (void)reserved;

    if (reason == DLL_PROCESS_ATTACH) {
        InitializeCriticalSection(&g_lock);
        g_inited = 1;
        g_thread = CreateThread(NULL, 0, worker_main, NULL, 0, NULL);
        if (!g_thread) {
            set_error("could not start worker thread");
        }
    } else if (reason == DLL_PROCESS_DETACH) {
        shutdown_core();
    }
    return TRUE;
}

int at_available(void)
{
    return (g_inited && g_thread) ? 1 : 0;
}

// A string out of a JSON document, at a "choices.0.message.content" style path. This is
// what the custom API engine uses: the response shape of an endpoint nobody here has seen
// is a user setting, so the reading half has to be generic (walking the tree is json_path()
// in at_json.c, which already understands numeric array indices).
//
// 1 = a string was found and copied to out; 0 = no string there (at_error() says whether
// the document was malformed or the path simply absent).
int at_json_string_at(const char* json_utf8, const char* path_utf8, char* out, int cap)
{
    JVal* root;
    JVal* node;
    const char* text;

    if (!json_utf8 || !path_utf8 || !path_utf8[0] || !out || cap <= 0) {
        set_error("missing argument");
        return 0;
    }
    out[0] = 0;

    root = json_parse(json_utf8);
    if (!root) {
        set_error("the response is not valid JSON");
        return 0;
    }

    node = json_path(root, path_utf8);
    text = json_str(node);
    if (!text) {
        _snprintf_s(g_error, sizeof(g_error), _TRUNCATE,
                    "the response has no string at '%s'", path_utf8);
        json_free(root);
        return 0;
    }

    _snprintf_s(out, (size_t)cap, _TRUNCATE, "%s", text);
    json_free(root);
    return 1;
}

const char* at_error(void)
{
    return g_error;
}

// Shared by at_http_get and at_http_post. Takes ownership of nothing; every
// string is copied.
static int enqueue_job(int post, const char* host_utf8, const char* path_utf8,
                       const char* content_type, const char* headers, const char* body)
{
    Job* job;
    int id;

    if (!g_inited) {
        return 0;
    }
    if (!host_utf8 || !path_utf8 || !host_utf8[0] || !path_utf8[0]) {
        return 0;
    }

    job = (Job*)calloc(1, sizeof(Job));
    if (!job) {
        return 0;
    }
    job->post = post;
    job->host = dup_str(host_utf8);
    job->path = dup_str(path_utf8);
    job->content_type = dup_str(content_type);
    job->headers = dup_str(headers);
    job->body = dup_str(body);
    job->next = NULL;

    if (!job->host || !job->path || (post && !job->body)) {
        free(job->host);
        free(job->path);
        free(job->content_type);
        free(job->headers);
        free(job->body);
        free(job);
        return 0;
    }

    EnterCriticalSection(&g_lock);
    id = g_next_id++;
    job->id = id;
    if (g_jobs_tail) {
        g_jobs_tail->next = job;
    } else {
        g_jobs_head = job;
    }
    g_jobs_tail = job;
    LeaveCriticalSection(&g_lock);

    return id;
}

int at_http_get(const char* host_utf8, const char* path_utf8)
{
    return enqueue_job(0, host_utf8, path_utf8, NULL, NULL, NULL);
}

// POST with a body. `headers` is an extra header block ("Name: value\r\n") used
// for API keys; `content_type` may be NULL to send no Content-Type.
int at_http_post(const char* host_utf8, const char* path_utf8, const char* content_type,
                 const char* headers, const char* body_utf8)
{
    return enqueue_job(1, host_utf8, path_utf8, content_type, headers, body_utf8);
}

int at_http_poll(int* out_id, int* out_result, int* out_http_code, char* out_body, int out_cap,
                 int* out_len, unsigned long* out_win_error)
{
    Result* r = NULL;

    if (!g_inited) {
        return 0;
    }

    EnterCriticalSection(&g_lock);
    if (g_results_head) {
        r = g_results_head;
        g_results_head = r->next;
        if (!g_results_head) {
            g_results_tail = NULL;
        }
    }
    LeaveCriticalSection(&g_lock);

    if (!r) {
        return 0;
    }

    if (out_id) {
        *out_id = r->id;
    }
    if (out_result) {
        *out_result = r->status;
    }
    if (out_http_code) {
        *out_http_code = r->http_code;
    }
    if (out_len) {
        *out_len = r->len;
    }
    if (out_win_error) {
        *out_win_error = (unsigned long)r->win_error;
    }
    if (out_body && out_cap > 0) {
        int n = r->len;
        if (n > out_cap - 1) {
            n = out_cap - 1;
        }
        if (n > 0 && r->body) {
            memcpy(out_body, r->body, (size_t)n);
        }
        out_body[n] = 0;
    }

    free(r->body);
    free(r);
    return 1;
}

int at_http_pending(void)
{
    int n = 0;
    if (!g_inited) {
        return 0;
    }
    EnterCriticalSection(&g_lock);
    {
        Job* j = g_jobs_head;
        while (j) {
            n++;
            j = j->next;
        }
        {
            Result* r = g_results_head;
            while (r) {
                n++;
                r = r->next;
            }
        }
    }
    LeaveCriticalSection(&g_lock);
    return n;
}

const char* at_version(void)
{
    // Kept in step with the .mod descriptor's version. The log line that reports the loaded core
    // is the first thing to compare when a player reports a problem, and two different numbers
    // there cost more than the discipline of bumping both.
    return "0.2.1-http";
}

int at_core_max_body(void)
{
    return AT_MAX_BODY;
}

// Turns a WinHTTP/Win32 code into readable text.
//
// WinHTTP's own messages (12000+) live in winhttp.dll's message table, not the
// system one, so FormatMessage needs that module as the source. Win32 codes
// (5, 10060, ...) come from the system table instead. Without this, a TLS
// failure reports nothing but "unknown error 12185".
const char* at_win_error_text(unsigned long code)
{
    static char buffer[512];
    static HMODULE winhttp = NULL;
    LPWSTR wide = NULL;
    DWORD flags;
    HMODULE source;

    buffer[0] = 0;
    if (code == 0) {
        return buffer;
    }

    if (!winhttp) {
        winhttp = LoadLibraryW(L"winhttp.dll");
    }

    if (code >= 12000 && code < 13000 && winhttp) {
        flags = FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_HMODULE | FORMAT_MESSAGE_IGNORE_INSERTS;
        source = winhttp;
    } else {
        flags = FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS;
        source = NULL;
    }

    if (FormatMessageW(flags, source, (DWORD)code, 0, (LPWSTR)&wide, 0, NULL) && wide) {
        char narrow[480];
        int n;
        size_t len;
        // strip the trailing CR/LF FormatMessage likes to append
        len = wcslen(wide);
        while (len > 0 && (wide[len - 1] == L'\r' || wide[len - 1] == L'\n' || wide[len - 1] == L' ')) {
            wide[--len] = 0;
        }
        n = WideCharToMultiByte(CP_UTF8, 0, wide, -1, narrow, (int)sizeof(narrow), NULL, NULL);
        LocalFree(wide);
        if (n > 0) {
            _snprintf_s(buffer, sizeof(buffer), _TRUNCATE, "%s", narrow);
            return buffer;
        }
    }

    _snprintf_s(buffer, sizeof(buffer), _TRUNCATE, "unknown error %lu", code);
    return buffer;
}

// Local model inference. The CTranslate2/SentencePiece half is C++ (at_model.cpp),
// so this is a thin forwarder: the Lua side only ever talks to the core.
// The directory is remembered rather than passed on every call, because loading
// is a one-off: it reads ~600 MB from disk.

static char g_model_dir[512] = { 0 };

static const char* at_model_dir(void)
{
    return g_model_dir;
}

int at_set_model_dir(const char* dir_utf8)
{
    if (!dir_utf8) {
        g_model_dir[0] = 0;
        set_error("no model directory given");
        return 0;
    }
    _snprintf_s(g_model_dir, sizeof(g_model_dir), _TRUNCATE, "%s", dir_utf8);

    char missing[256];
    return at_model_check_dir(g_model_dir, missing, (int)sizeof(missing));
}

int at_load_model(void)
{
    if (g_model_dir[0] == 0) {
        set_error("no model directory has been set");
        return 0;
    }
    return at_model_load(g_model_dir);
}

// Same, but the loading happens off the game thread. The Lua side polls
// at_model_status() and shows progress while it runs.
int at_load_model_async(void)
{
    if (g_model_dir[0] == 0) {
        set_error("no model directory has been set");
        return -2;
    }
    return at_model_load_async(g_model_dir);
}

int at_set_model_threads(int threads)
{
    return at_model_set_threads(threads);
}

int at_model_threads(void)
{
    return at_model_current_threads();
}

int at_model_core_count(void)
{
    return at_model_machine_cores();
}

int at_model_loaded_dir(char* out, int cap)
{
    return at_model_current_dir(out, cap);
}

// The game-facing translation entry point: submit now, collect later. Never blocks.
int at_submit(const char* text_utf8, const char* target_lang_utf8)
{
    if (!text_utf8 || !target_lang_utf8 || !text_utf8[0]) {
        set_error("missing argument");
        return -2;
    }
    if (!at_model_ready()) {
        set_error("the offline model is not loaded");
        return -1;
    }
    return at_model_submit(text_utf8, target_lang_utf8);
}

int at_poll(char* out_text, int out_cap)
{
    return at_model_poll(out_text, out_cap);
}

int at_translate(const char* text_utf8, const char* target_lang_utf8, char* out_text, int out_cap)
{
    if (!text_utf8 || !target_lang_utf8 || !out_text || out_cap <= 0) {
        return -2;
    }
    out_text[0] = 0;

    if (!at_model_ready()) {
        set_error("the offline model is not loaded");
        return -1;
    }

    return at_model_translate(text_utf8, target_lang_utf8, out_text, out_cap);
}

// 0 = no model on disk, 1 = model files present, 2 = loaded and ready,
// 3 = a background load is running (at_load_model_async).
int at_model_status(void)
{
    if (at_model_ready()) {
        return 2;
    }
    if (at_model_loading()) {
        return 3;
    }

    char missing[256];
    const int present = at_model_check_dir(at_model_dir(), missing, (int)sizeof(missing));
    return present > 0 ? 1 : 0;
}

long long at_model_disk_size(void)
{
    return at_model_dir_size(at_model_dir());
}
