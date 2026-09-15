// at_cli.c — command line front end for the Auto Translate native core.
//
// Lets the core be tested without launching the game:
//   at_cli.exe info
//   at_cli.exe http <url>            (GET, prints status / bytes / body)
//   at_cli.exe http <host> <path>
//   at_cli.exe translate <target> <text...>
//
// Exit codes: 0 ok, 1 usage error, 2 core unavailable, 3 http/translate failure.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

#include "at_core.h"

#define BODY_CAP (4 * 1024 * 1024)

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

static int cmd_http(int argc, char** argv)
{
    char host[512];
    char path[2048];
    int id;
    int rc;

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
    id = at_http_get(host, path);
    if (id <= 0) {
        fprintf(stderr, "error: request rejected (%s)\n", at_error() ? at_error() : "?");
        return 3;
    }

    {
        char* body = (char*)malloc(BODY_CAP);
        int got_id = 0;
        int status = 0;
        int len = 0;
        unsigned long win_error = 0;
        int spins = 0;

        if (!body) {
            fprintf(stderr, "error: out of memory\n");
            return 3;
        }

        // 60 s ceiling; results are delivered by the worker thread.
        while (spins < 600) {
            rc = at_http_poll(&got_id, &status, body, BODY_CAP, &len, &win_error);
            if (rc == 1) {
                break;
            }
            if (rc < 0) {
                fprintf(stderr, "error: poll failed\n");
                free(body);
                return 3;
            }
            Sleep(100);
            spins++;
        }

        if (spins >= 600) {
            fprintf(stderr, "error: timed out\n");
            free(body);
            return 3;
        }

        if (len < 0) {
            len = 0;
        }
        body[len] = 0;

        printf("request id : %d\n", got_id);
        printf("status     : %d\n", status);
        printf("bytes      : %d\n", len);
        if (status != 0) {
            if (win_error) {
                printf("win error  : %lu (%s)\n", win_error, at_win_error_text(win_error));
            }
            if (at_error() && at_error()[0]) {
                printf("last error : %s\n", at_error());
            }
            free(body);
            return 3;
        }

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
        free(body);
    }

    return 0;
}

static int cmd_translate(int argc, char** argv)
{
    char out[8192];
    int i;
    int rc;
    char text[4096];

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

    printf("target : %s\n", argv[2]);
    printf("source : %s\n", text);

    rc = at_translate(text, argv[2], out, (int)sizeof(out));
    if (rc > 0) {
        printf("result : %s\n", out);
        return 0;
    }

    fprintf(stderr, "translate failed: rc=%d (%s)\n", rc, at_error() ? at_error() : "?");
    return 3;
}

int main(int argc, char** argv)
{
    int rc;

    if (argc < 2) {
        printf("at_cli %s — Auto Translate native core test tool\n\n",
               at_version() ? at_version() : "?");
        printf("usage:\n");
        printf("  at_cli.exe info\n");
        printf("  at_cli.exe http <url>\n");
        printf("  at_cli.exe http <host> <path>\n");
        printf("  at_cli.exe translate <target-lang> <text...>\n");
        return 1;
    }

    if (_stricmp(argv[1], "info") == 0) {
        rc = cmd_info();
    } else if (_stricmp(argv[1], "http") == 0) {
        rc = cmd_http(argc, argv);
    } else if (_stricmp(argv[1], "translate") == 0) {
        rc = cmd_translate(argc, argv);
    } else {
        fprintf(stderr, "unknown command: %s\n", argv[1]);
        rc = 1;
    }

    return rc;
}
