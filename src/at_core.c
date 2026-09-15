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

#define AT_MAX_BODY (256 * 1024)
#define AT_TIMEOUT_MS 20000

typedef struct Job {
    int id;
    char* host;
    char* path;
    struct Job* next;
} Job;

typedef struct Result {
    int id;
    int status;
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

static void push_result(int id, int status, char* body, int len, DWORD win_error)
{
    Result* r = (Result*)malloc(sizeof(Result));
    if (!r) {
        free(body);
        return;
    }
    r->id = id;
    r->status = status;
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

static void do_http_get(const char* host, const char* path, int* out_status, char** out_body, int* out_len)
{
    HINTERNET session = NULL;
    HINTERNET connect = NULL;
    HINTERNET request = NULL;
    wchar_t whost[256];
    wchar_t wpath[2048];
    wchar_t headers[256];
    INTERNET_PORT port = INTERNET_DEFAULT_HTTPS_PORT;
    DWORD flags = WINHTTP_FLAG_SECURE;
    const char* bare_host = host;
    const char* scheme_note = "https";
    int status = 0;
    int failure = 0;
    char* body = NULL;
    int len = 0;

    *out_status = -1;
    *out_body = NULL;
    *out_len = 0;
    g_win_error = 0;

    // The caller may prefix the host with a scheme. Everything we talk to in
    // production is HTTPS; the plaintext branch exists so the CLI can smoke test
    // local endpoints without a certificate.
    if (_strnicmp(host, "http://", 7) == 0) {
        bare_host = host + 7;
        port = INTERNET_DEFAULT_HTTP_PORT;
        flags = 0;
        scheme_note = "http";
    } else if (_strnicmp(host, "https://", 8) == 0) {
        bare_host = host + 8;
    }
    (void)scheme_note;

    if (MultiByteToWideChar(CP_UTF8, 0, bare_host, -1, whost, 256) <= 0) {
        *out_status = -2;
        return;
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

    connect = WinHttpConnect(session, whost, port, 0);
    if (!connect) {
        failure = fail_with(-11);
        goto done;
    }

    request = WinHttpOpenRequest(connect, L"GET", wpath, NULL, WINHTTP_NO_REFERER,
                                 WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!request) {
        failure = fail_with(-12);
        goto done;
    }

    wcscpy_s(headers, 256, L"Accept: application/json\r\n");
    if (!WinHttpSendRequest(request, headers, (DWORD)-1L, WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) {
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
            status = (int)code;
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
    *out_status = failure ? failure : status;
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
            char* body = NULL;
            int len = 0;
            DWORD win_error = 0;
            do_http_get(job->host, job->path, &status, &body, &len);
            if (status < 0) {
                win_error = last_win_error();
            }
            push_result(job->id, status, body, len, win_error);
        }

        free(job->host);
        free(job->path);
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

const char* at_error(void)
{
    return g_error;
}

int at_http_get(const char* host_utf8, const char* path_utf8)
{
    Job* job;
    int id;

    if (!g_inited) {
        return 0;
    }
    if (!host_utf8 || !path_utf8 || !host_utf8[0] || !path_utf8[0]) {
        return 0;
    }

    job = (Job*)malloc(sizeof(Job));
    if (!job) {
        return 0;
    }
    job->host = dup_str(host_utf8);
    job->path = dup_str(path_utf8);
    job->next = NULL;
    if (!job->host || !job->path) {
        free(job->host);
        free(job->path);
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

int at_http_poll(int* out_id, int* out_status, char* out_body, int out_cap, int* out_len,
                 unsigned long* out_win_error)
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
    if (out_status) {
        *out_status = r->status;
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
    return "0.1.0-http";
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

// Local model inference — placeholder until the CTranslate2 core is built in.
// Kept in the same DLL/CLI so callers and tests can be written before it exists.
int at_translate(const char* text_utf8, const char* target_lang_utf8, char* out_text, int out_cap)
{
    if (!text_utf8 || !target_lang_utf8 || !out_text || out_cap <= 0) {
        return -2;
    }
    out_text[0] = 0;
    set_error("local model inference is not implemented in this build");
    return -1;
}

int at_model_status(void)
{
    return 0;
}
