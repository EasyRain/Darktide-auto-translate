// at_download.h — streaming model download (WinHTTP) with resume and a checksum
//
// The model files are 1.4 GB, they come from a host that is unreachable from mainland
// China without the mirror, and the download has to survive a cancelled game, a dropped
// connection and a user who changes their mind. That is why this is not a one-shot
// "download to memory and write it out": the transfer is streamed to disk, resumed with
// an HTTP Range request, cancellable, and verified against a pinned SHA-256 when it
// finishes.
//
// One download at a time, on its own thread; the caller polls. Nothing here blocks the
// game thread.
#ifndef AT_DOWNLOAD_H
#define AT_DOWNLOAD_H

#include "at_api.h"

#ifdef __cplusplus
extern "C" {
#endif

// Starts downloading `url_utf8` to `out_path_utf8`.
//   `sha256_hex` may be NULL; when given, the finished file is hashed and a mismatch is a
//   failure (the file is renamed to "<out>.bad" instead of being left in place looking
//   like a usable model).
//
// A partial file at the destination is resumed rather than restarted, so a cancelled or
// interrupted download keeps what it already has. Returns 1 when the transfer started, 0
// when one is already running, <0 on bad arguments (at_download_error() says why).
AT_API int at_download_start(const char* url_utf8, const char* out_path_utf8, const char* sha256_hex);

// 0 = idle, 1 = running, 2 = finished, 3 = failed, 4 = cancelled.
AT_API int at_download_status(void);

// Bytes on disk so far and the expected total (0 when the server did not say).
AT_API long long at_download_received(void);
AT_API long long at_download_total(void);

// Asks the transfer to stop. The partial file is kept for the next attempt.
AT_API int at_download_cancel(void);

// Human readable failure reason ("" when there is none), and what is being fetched.
AT_API const char* at_download_error(void);
AT_API const char* at_download_path(void);

// Which route a download takes: <0 = decide per host (the default), 0 = never use the
// proxy, 1 = use it whenever one is configured.
//
// The default is the important one: hf-mirror.com only serves a Chinese IP, so it must go
// *direct*, while huggingface.co from China needs the proxy - routing the mirror through a
// VPN is the one reliable way to break it. at_download_route_is_proxied() reports what a
// given URL will do, for the log.
AT_API int at_download_use_proxy(int mode);
AT_API int at_download_proxy_mode(void);
AT_API int at_download_route_is_proxied(const char* url_utf8);

// SHA-256 of a file as lowercase hex; 1 on success. Used to verify a finished download
// and by the CLI/tests to check a directory by hand.
AT_API int at_sha256_file(const char* path_utf8, char* out_hex, int cap);

// Size of a file in bytes, or -1 when it cannot be read. _fseeki64/_ftelli64, because
// ftell cannot see past 2 GB on MSVC (that bug reported the 3.3B model as 10 MB).
AT_API long long at_file_size64(const char* path_utf8);

// Deletes a file. Returns 1 when it is gone (including "was not there"), 0 on failure.
AT_API int at_delete_file(const char* path_utf8);

#ifdef __cplusplus
}
#endif

#endif // AT_DOWNLOAD_H
