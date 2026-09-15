// at_download.c — streaming model download: resume, progress, cancel, checksum.
//
// Design notes worth keeping:
//
//   * Streamed to the file as it arrives, never buffered whole. The model is 1.4 GB and
//     the game is already holding 1.7 GB of it once loaded.
//   * Resume is the default, not a feature: an existing partial file is measured and the
//     request carries "Range: bytes=<size>-". A 206 answer appends; a 200 answer means the
//     server ignored the range, so the file is truncated and rewritten from the start
//     rather than silently producing a file with a hole in it.
//   * The mirror is tried automatically. huggingface.co and hf-mirror.com serve the same
//     tree, and which one works depends on where the player is: the first attempt uses the
//     host in the URL, a failure is retried once against the other one.
//   * A checksum mismatch does not delete anything - the file is renamed to "<name>.bad".
//     If the pinned hash were ever wrong, deleting a good 1.4 GB download would be the
//     worst possible answer.
//
// WinHTTP is used the same way at_core.c uses it for API calls, including the proxy: the
// proxy that the mod options (or the Windows settings) provide is fetched through
// at_proxy_wide() so a download works exactly when the API calls do.
#include <windows.h>
#include <winhttp.h>
#include <bcrypt.h>
#include <stdio.h>
#include <string.h>

#include "at_download.h"
#include "at_core.h"

#define DOWNLOAD_BUFFER (256 * 1024)   // read size; large enough to keep the socket busy
#define HOST_HF        "huggingface.co"
#define HOST_HF_MIRROR "hf-mirror.com"

enum {
    DL_IDLE = 0,
    DL_RUNNING = 1,
    DL_DONE = 2,
    DL_FAILED = 3,
    DL_CANCELLED = 4,
};

static volatile LONG g_status = DL_IDLE;
static volatile LONG64 g_received = 0;
static volatile LONG64 g_total = 0;
static volatile LONG g_cancel = 0;
static volatile LONG g_running = 0;      // a worker thread exists
static char g_error[512] = { 0 };
static char g_path[1024] = { 0 };
static char g_url[2048] = { 0 };

static void set_error(const char* text)
{
    _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, "%s", text ? text : "");
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
long long at_file_size64(const char* path_utf8)
{
    FILE* f;
    long long size;

    if (!path_utf8 || !path_utf8[0]) {
        return -1;
    }
    f = fopen(path_utf8, "rb");
    if (!f) {
        return -1;
    }
    if (_fseeki64(f, 0, SEEK_END) != 0) {
        fclose(f);
        return -1;
    }
    size = _ftelli64(f);
    fclose(f);
    return size < 0 ? -1 : size;
}

int at_delete_file(const char* path_utf8)
{
    if (!path_utf8 || !path_utf8[0]) {
        return 0;
    }
    if (DeleteFileA(path_utf8)) {
        return 1;
    }
    return GetLastError() == ERROR_FILE_NOT_FOUND ? 1 : 0;
}

// Lowercase hex SHA-256 of a file, via BCrypt (no OpenSSL anywhere in this build).
int at_sha256_file(const char* path_utf8, char* out_hex, int cap)
{
    BCRYPT_ALG_HANDLE alg = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    unsigned char* object = NULL;
    unsigned char* buffer = NULL;
    unsigned char digest[32];
    DWORD object_size = 0, digest_size = 0, produced = 0;
    FILE* f = NULL;
    int ok = 0;

    if (!path_utf8 || !out_hex || cap < 65) {
        return 0;
    }
    out_hex[0] = 0;

    f = fopen(path_utf8, "rb");
    if (!f) {
        return 0;
    }
    buffer = (unsigned char*)malloc(DOWNLOAD_BUFFER);
    if (!buffer) {
        fclose(f);
        return 0;
    }

    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0) != 0) {
        goto done;
    }
    if (BCryptGetProperty(alg, BCRYPT_OBJECT_LENGTH, (PUCHAR)&object_size, sizeof(object_size),
                          &produced, 0) != 0) {
        goto done;
    }

    // The object buffer belongs to the hash: CNG writes its state there and reads it back
    // on every update, so freeing it after BCryptCreateHash makes the hash fail (the first
    // version did exactly that and every checksum came back as "could not be read back").
    object = (unsigned char*)malloc(object_size);
    if (!object) {
        goto done;
    }
    if (BCryptCreateHash(alg, &hash, object, object_size, NULL, 0, 0) != 0) {
        goto done;
    }

    for (;;) {
        size_t got = fread(buffer, 1, DOWNLOAD_BUFFER, f);
        if (got > 0 && BCryptHashData(hash, buffer, (ULONG)got, 0) != 0) {
            goto done;
        }
        if (got < DOWNLOAD_BUFFER) {
            break;
        }
    }
    if (ferror(f)) {
        goto done;
    }

    if (BCryptFinishHash(hash, digest, (ULONG)sizeof(digest), 0) != 0) {
        goto done;
    }
    BCryptGetProperty(alg, BCRYPT_HASH_LENGTH, (PUCHAR)&digest_size, sizeof(digest_size), &produced, 0);
    if (digest_size != sizeof(digest)) {
        goto done;
    }

    {
        static const char* hex = "0123456789abcdef";
        int i;
        for (i = 0; i < (int)sizeof(digest); i++) {
            out_hex[i * 2] = hex[(digest[i] >> 4) & 0xF];
            out_hex[i * 2 + 1] = hex[digest[i] & 0xF];
        }
        out_hex[64] = 0;
        ok = 1;
    }

done:
    if (hash) {
        BCryptDestroyHash(hash);
    }
    if (alg) {
        BCryptCloseAlgorithmProvider(alg, 0);
    }
    free(object);
    free(buffer);
    fclose(f);
    return ok;
}

static int hex_equal(const char* a, const char* b)
{
    if (!a || !b) {
        return 0;
    }
    for (; *a && *b; a++, b++) {
        char ca = (*a >= 'A' && *a <= 'F') ? (char)(*a - 'A' + 'a') : *a;
        char cb = (*b >= 'A' && *b <= 'F') ? (char)(*b - 'A' + 'a') : *b;
        if (ca != cb) {
            return 0;
        }
    }
    return *a == 0 && *b == 0;
}

// Swaps the host between huggingface.co and hf-mirror.com, keeping the rest of the URL.
// Returns 1 when something changed and the result fits.
static int swap_host(const char* url, char* out, int cap)
{
    const char* from = NULL;
    const char* to = NULL;
    const char* at;
    size_t prefix;

    if (!url || !out || cap <= 0) {
        return 0;
    }
    if (strstr(url, HOST_HF_MIRROR)) {
        from = HOST_HF_MIRROR;
        to = HOST_HF;
    } else if (strstr(url, HOST_HF)) {
        from = HOST_HF;
        to = HOST_HF_MIRROR;
    } else {
        return 0;                        // some other host: nothing to swap
    }

    at = strstr(url, from);
    prefix = (size_t)(at - url);
    if (prefix + strlen(to) + strlen(at + strlen(from)) + 1 > (size_t)cap) {
        return 0;
    }
    memcpy(out, url, prefix);
    strcpy_s(out + prefix, (size_t)cap - prefix, to);
    strcat_s(out, (size_t)cap, at + strlen(from));
    return 1;
}

// Splits "https://host[:port]/path" into its parts (all wide).
static int split_url(const char* url_utf8, wchar_t* host, int host_cap, wchar_t* path, int path_cap,
                     INTERNET_PORT* port, int* secure)
{
    wchar_t wide[2048];
    wchar_t* rest;
    wchar_t* slash;
    wchar_t* colon;

    if (MultiByteToWideChar(CP_UTF8, 0, url_utf8, -1, wide, 2048) <= 0) {
        return 0;
    }
    *secure = 1;
    *port = INTERNET_DEFAULT_HTTPS_PORT;
    rest = wide;

    if (wcsncmp(rest, L"https://", 8) == 0) {
        rest += 8;
    } else if (wcsncmp(rest, L"http://", 7) == 0) {
        rest += 7;
        *secure = 0;
        *port = INTERNET_DEFAULT_HTTP_PORT;
    }

    slash = wcschr(rest, L'/');
    if (!slash) {
        return 0;
    }
    *slash = 0;
    slash++;

    colon = wcschr(rest, L':');
    if (colon) {
        *colon = 0;
        *port = (INTERNET_PORT)wcstol(colon + 1, NULL, 10);
    }

    wcsncpy_s(host, (size_t)host_cap, rest, _TRUNCATE);
    _snwprintf_s(path, (size_t)path_cap, _TRUNCATE, L"/%s", slash);
    return 1;
}

// ---------------------------------------------------------------------------
// The transfer
// ---------------------------------------------------------------------------
// Returns 0 on success, -1 on a transport failure (worth retrying on the other host),
// -2 on a definitive failure (bad status, disk error, checksum).
static int transfer(const char* url, const char* out_path, const char* sha256_hex)
{
    wchar_t host[256] = { 0 };
    wchar_t path[1024] = { 0 };
    wchar_t proxy[256] = { 0 };
    INTERNET_PORT port = 0;
    int secure = 1;
    int has_proxy;
    HINTERNET session = NULL, connection = NULL, request = NULL;
    DWORD status_code = 0, status_size = sizeof(status_code);
    long long existing = at_file_size64(out_path);
    long long received = 0;
    long long total = 0;
    FILE* out = NULL;
    unsigned char* buffer = NULL;
    int rc = -2;
    char range_header[64] = { 0 };

    if (!split_url(url, host, 256, path, 1024, &port, &secure)) {
        set_error("the download URL could not be parsed");
        return -2;
    }
    if (existing < 0) {
        existing = 0;                       // no file yet
    }
    received = existing;

    has_proxy = at_proxy_wide(proxy, 256);
    session = WinHttpOpen(L"auto_translate/1.0", has_proxy ? WINHTTP_ACCESS_TYPE_NAMED_PROXY
                                                           : WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                          has_proxy ? proxy : WINHTTP_NO_PROXY_NAME,
                          has_proxy ? WINHTTP_NO_PROXY_BYPASS : NULL, 0);
    if (!session) {
        set_error("could not open an HTTP session");
        return -1;
    }
    WinHttpSetTimeouts(session, 30000, 30000, 60000, 60000);

    connection = WinHttpConnect(session, host, port, 0);
    if (!connection) {
        set_error("could not reach the download host");
        goto done;
    }
    request = WinHttpOpenRequest(connection, L"GET", path, NULL, WINHTTP_NO_REFERER,
                                 WINHTTP_DEFAULT_ACCEPT_TYPES, secure ? WINHTTP_FLAG_SECURE : 0);
    if (!request) {
        set_error("could not create the download request");
        goto done;
    }

    // Resume when there is something to resume from: the server answers 206 with just the
    // missing tail. A server that ignores the range answers 200 with the whole file, which
    // the code below handles by starting the destination over.
    if (existing > 0) {
        wchar_t range[64];
        _snprintf_s(range_header, sizeof(range_header), _TRUNCATE, "Range: bytes=%lld-", existing);
        if (MultiByteToWideChar(CP_UTF8, 0, range_header, -1, range, 64) > 0) {
            WinHttpAddRequestHeaders(request, range, (ULONG)-1L, WINHTTP_ADDREQ_FLAG_ADD);
        }
    }

    if (!WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) {
        set_error("the download request failed");
        rc = -1;
        goto done;
    }
    if (!WinHttpReceiveResponse(request, NULL)) {
        set_error("no answer from the download host");
        rc = -1;
        goto done;
    }

    if (!WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             WINHTTP_HEADER_NAME_BY_INDEX, &status_code, &status_size,
                             WINHTTP_NO_HEADER_INDEX)) {
        set_error("the download host did not report a status");
        goto done;
    }
    if (status_code != 200 && status_code != 206) {
        _snprintf_s(g_error, sizeof(g_error), _TRUNCATE, "the download host answered HTTP %lu",
                    (unsigned long)status_code);
        goto done;
    }

    {
        long long length = 0;
        DWORD size = sizeof(length);
        if (WinHttpQueryHeaders(request, WINHTTP_QUERY_CONTENT_LENGTH | WINHTTP_QUERY_FLAG_NUMBER64,
                                WINHTTP_HEADER_NAME_BY_INDEX, &length, &size, WINHTTP_NO_HEADER_INDEX)) {
            if (status_code == 206) {
                total = existing + length;          // the range length, not the whole file
            } else {
                total = length;
            }
        }
    }
    g_total = total;

    if (status_code == 200 && existing > 0) {
        // The server ignored the range: start the file over instead of appending to it.
        existing = 0;
        received = 0;
    }

    out = fopen(out_path, status_code == 206 && existing > 0 ? "ab" : "wb");
    if (!out) {
        set_error("the destination file could not be opened for writing");
        goto done;
    }

    buffer = (unsigned char*)malloc(DOWNLOAD_BUFFER);
    if (!buffer) {
        set_error("out of memory");
        goto done;
    }

    for (;;) {
        DWORD available = 0;
        DWORD got = 0;
        if (InterlockedCompareExchange(&g_cancel, 0, 0) != 0) {
            g_status = DL_CANCELLED;
            set_error("cancelled");
            rc = -2;
            goto done;
        }
        if (!WinHttpQueryDataAvailable(request, &available)) {
            set_error("the connection was lost while downloading");
            rc = -1;
            goto done;
        }
        if (available == 0) {
            break;                              // end of the body
        }
        if (available > DOWNLOAD_BUFFER) {
            available = DOWNLOAD_BUFFER;
        }
        if (!WinHttpReadData(request, buffer, available, &got)) {
            set_error("the connection was lost while downloading");
            rc = -1;
            goto done;
        }
        if (got == 0) {
            break;
        }
        if (fwrite(buffer, 1, got, out) != got) {
            set_error("writing the file failed (is the disk full?)");
            goto done;
        }
        received += got;
        g_received = received;
    }

    fclose(out);
    out = NULL;
    rc = 0;

done:
    if (out) {
        fclose(out);
    }
    free(buffer);
    if (request) {
        WinHttpCloseHandle(request);
    }
    if (connection) {
        WinHttpCloseHandle(connection);
    }
    if (session) {
        WinHttpCloseHandle(session);
    }

    if (rc != 0) {
        return rc;
    }

    // Verify before declaring success: a truncated mirror answer is exactly what a
    // checksum is for.
    if (sha256_hex && sha256_hex[0]) {
        char actual[65] = { 0 };
        if (!at_sha256_file(out_path, actual, (int)sizeof(actual))) {
            set_error("the downloaded file could not be read back for verification");
            return -2;
        }
        if (!hex_equal(actual, sha256_hex)) {
            char bad[1100];
            _snprintf_s(bad, sizeof(bad), _TRUNCATE, "%s.bad", out_path);
            remove(bad);
            if (rename(out_path, bad) != 0) {
                _snprintf_s(g_error, sizeof(g_error), _TRUNCATE,
                            "the file does not match its checksum (wanted %s, got %s)",
                            sha256_hex, actual);
            } else {
                _snprintf_s(g_error, sizeof(g_error), _TRUNCATE,
                            "the file does not match its checksum (wanted %s, got %s); "
                            "it was renamed to %s", sha256_hex, actual, bad);
            }
            return -2;
        }
    }
    return 0;
}

static DWORD WINAPI worker(LPVOID param)
{
    char url[2048];
    char alternate[2048];
    const char* sha = (const char*)param;      // the pinned checksum, owned by at_download_start
    int rc;

    _snprintf_s(url, sizeof(url), _TRUNCATE, "%s", g_url);

    rc = transfer(url, g_path, sha);
    if (rc == -1 && swap_host(url, alternate, (int)sizeof(alternate))) {
        // One retry against the other Hugging Face host: which of the two is reachable
        // depends on where the player is, and they serve the same tree. Whatever the first
        // attempt wrote is resumed, not thrown away.
        long long keep = at_file_size64(g_path);
        g_received = keep > 0 ? keep : 0;
        rc = transfer(alternate, g_path, sha);
    }

    if (rc == 0) {
        g_status = DL_DONE;
        set_error("");
    } else if (InterlockedCompareExchange(&g_cancel, 0, 0) != 0) {
        g_status = DL_CANCELLED;
    } else {
        g_status = DL_FAILED;
    }

    InterlockedExchange(&g_running, 0);
    return 0;
}

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------
int at_download_start(const char* url_utf8, const char* out_path_utf8, const char* sha256_hex)
{
    if (!url_utf8 || !url_utf8[0] || !out_path_utf8 || !out_path_utf8[0]) {
        set_error("a download needs a URL and a destination file");
        return -1;
    }
    if (InterlockedCompareExchange(&g_running, 1, 0) != 0) {
        set_error("a download is already running");
        return 0;
    }

    _snprintf_s(g_url, sizeof(g_url), _TRUNCATE, "%s", url_utf8);
    _snprintf_s(g_path, sizeof(g_path), _TRUNCATE, "%s", out_path_utf8);
    // The checksum is handed to the worker through a static buffer, so the caller's string
    // does not have to outlive the call.
    {
        static char pinned[65];
        _snprintf_s(pinned, sizeof(pinned), _TRUNCATE, "%s", sha256_hex ? sha256_hex : "");
        InterlockedExchange(&g_cancel, 0);
        {
            const long long existing = at_file_size64(g_path);
            g_received = existing > 0 ? existing : 0;
        }
        g_total = 0;
        set_error("");
        g_status = DL_RUNNING;
        if (!CreateThread(NULL, 0, worker, pinned, 0, NULL)) {
            InterlockedExchange(&g_running, 0);
            g_status = DL_IDLE;
            set_error("could not start the download thread");
            return -1;
        }
    }
    return 1;
}

int at_download_status(void)
{
    return (int)InterlockedCompareExchange(&g_status, 0, 0);
}

long long at_download_received(void)
{
    return g_received;
}

long long at_download_total(void)
{
    return g_total;
}

int at_download_cancel(void)
{
    if (InterlockedCompareExchange(&g_running, 0, 0) == 0) {
        return 0;
    }
    InterlockedExchange(&g_cancel, 1);
    return 1;
}

const char* at_download_error(void)
{
    return g_error;
}

const char* at_download_path(void)
{
    return g_path;
}
