#ifndef CSHIMS_H
#define CSHIMS_H

#include <stdio.h>
#include <stddef.h>
#include <libssh2.h>
#include <libssh2_sftp.h>

/// One FTP/FTPS transfer or command batch, executed through libcurl.
typedef struct {
    const char *url;            // ftp://host:port/path (directories end with '/')
    const char *userpwd;        // "user:password"
    int use_tls;                // 1 = require explicit FTPS (AUTH TLS)
    const char *custom_request; // e.g. "MLSD" for directory listings, NULL otherwise
    const char *const *quote;   // commands sent after login (MKD, DELE, RNFR/RNTO, ...)
    int quote_count;
    int nobody;                 // 1 = no data transfer, only run the quote commands
    FILE *download_to;          // write body here instead of the memory buffer
    FILE *upload_from;          // non-NULL = STOR this stream
    long long upload_size;
    const char *range;          // "start-end" byte range for downloads, NULL for the whole file
} sm_ftp_request;

/// Returns the CURLcode (0 = success). When download_to is NULL the response body is
/// returned in *out_buf (malloc'ed, caller frees with sm_free). errbuf must hold 256 bytes.
int sm_ftp_perform(const sm_ftp_request *req, char **out_buf, size_t *out_len,
                   long *response_code, char *errbuf);

void sm_free(void *p);

#endif
