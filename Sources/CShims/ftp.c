#include "CShims.h"
#include <curl/curl.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

typedef struct {
    char *data;
    size_t len;
} membuf;

static size_t write_mem(char *ptr, size_t size, size_t nmemb, void *userdata) {
    membuf *mb = (membuf *)userdata;
    size_t n = size * nmemb;
    char *grown = realloc(mb->data, mb->len + n + 1);
    if (!grown) return 0;
    mb->data = grown;
    memcpy(mb->data + mb->len, ptr, n);
    mb->len += n;
    mb->data[mb->len] = 0;
    return n;
}

static pthread_once_t curl_once = PTHREAD_ONCE_INIT;
static void curl_global(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }

int sm_ftp_perform(const sm_ftp_request *req, char **out_buf, size_t *out_len,
                   long *response_code, char *errbuf) {
    pthread_once(&curl_once, curl_global);
    CURL *curl = curl_easy_init();
    if (!curl) return CURLE_FAILED_INIT;

    membuf mb = {0};
    struct curl_slist *quote = NULL;
    errbuf[0] = 0;

    curl_easy_setopt(curl, CURLOPT_URL, req->url);
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, errbuf);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 20L);
    curl_easy_setopt(curl, CURLOPT_FTP_USE_EPSV, 1L);
    if (req->userpwd) curl_easy_setopt(curl, CURLOPT_USERPWD, req->userpwd);
    if (req->use_tls) curl_easy_setopt(curl, CURLOPT_USE_SSL, (long)CURLUSESSL_ALL);
    if (req->custom_request) curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, req->custom_request);

    for (int i = 0; i < req->quote_count; i++) quote = curl_slist_append(quote, req->quote[i]);
    if (quote) curl_easy_setopt(curl, CURLOPT_POSTQUOTE, quote);
    if (req->nobody) curl_easy_setopt(curl, CURLOPT_NOBODY, 1L);
    if (req->range) curl_easy_setopt(curl, CURLOPT_RANGE, req->range);

    if (req->upload_from) {
        curl_easy_setopt(curl, CURLOPT_UPLOAD, 1L);
        curl_easy_setopt(curl, CURLOPT_READDATA, req->upload_from);
        curl_easy_setopt(curl, CURLOPT_INFILESIZE_LARGE, (curl_off_t)req->upload_size);
    } else if (req->download_to) {
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, req->download_to);
    } else {
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_mem);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &mb);
    }

    CURLcode rc = curl_easy_perform(curl);
    if (response_code) curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, response_code);

    if (out_buf) {
        *out_buf = mb.data;
        if (out_len) *out_len = mb.len;
    } else {
        free(mb.data);
    }
    curl_slist_free_all(quote);
    curl_easy_cleanup(curl);
    return (int)rc;
}

void sm_free(void *p) { free(p); }
