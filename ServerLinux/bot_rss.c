#define _POSIX_C_SOURCE 200809L
#include "bot_rss.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <curl/curl.h>
#include <errno.h>
#include <json-c/json.h>
#include <libxml/HTMLparser.h>
#include <libxml/parser.h>
#include <libxml/tree.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define RSS_FEED_MAX_BYTES (2u * 1024u * 1024u)
#define RSS_MAX_ITEMS 128u

typedef struct rss_buffer {
    uint8_t *data;
    size_t len;
    size_t cap;
    size_t maximum;
    int failed;
} rss_buffer;

typedef struct rss_http_result {
    long status;
    rss_buffer body;
    char etag[512];
    char last_modified[512];
} rss_http_result;

typedef struct rss_parsed_item {
    cr_bot_rss_article article;
    int image_priority;
} rss_parsed_item;

typedef struct rss_feed_state {
    int initialized;
    double last_checked;
    char etag[512];
    char last_modified[512];
} rss_feed_state;

static pthread_once_t curl_once = PTHREAD_ONCE_INIT;
static void rss_curl_init_once(void) { (void)curl_global_init(CURL_GLOBAL_DEFAULT); }

static int has_line_break(const char *s) {
    return s && (strchr(s, '\n') || strchr(s, '\r'));
}

static int valid_uuid(const char *s) {
    if (!s || strlen(s) != 36) return 0;
    for (size_t i = 0; i < 36; ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (s[i] != '-') return 0;
        } else if (!isxdigit((unsigned char)s[i])) return 0;
    }
    return 1;
}

static int url_syntax_allowed(const char *url) {
    if (!url || !*url || strlen(url) > CR_BOT_RSS_URL_MAX || has_line_break(url)) return 0;
    pthread_once(&curl_once, rss_curl_init_once);
    CURLU *u = curl_url();
    if (!u) return 0;
    int ok = 0;
    if (curl_url_set(u, CURLUPART_URL, url, 0) == CURLUE_OK) {
        char *scheme = NULL, *host = NULL, *user = NULL, *password = NULL;
        CURLUcode sr = curl_url_get(u, CURLUPART_SCHEME, &scheme, 0);
        CURLUcode hr = curl_url_get(u, CURLUPART_HOST, &host, 0);
        CURLUcode ur = curl_url_get(u, CURLUPART_USER, &user, 0);
        CURLUcode pr = curl_url_get(u, CURLUPART_PASSWORD, &password, 0);
        int credentials = ur == CURLUE_OK || pr == CURLUE_OK;
        ok = sr == CURLUE_OK && hr == CURLUE_OK && scheme && host && *host && !credentials &&
             (!strcasecmp(scheme, "http") || !strcasecmp(scheme, "https"));
        curl_free(scheme); curl_free(host); curl_free(user); curl_free(password);
    }
    curl_url_cleanup(u);
    return ok;
}

int cr_bot_rss_feed_valid(const cr_bot_rss_feed *feed) {
    if (!feed || !valid_uuid(feed->id) || !feed->name[0] || strlen(feed->name) > CR_BOT_RSS_NAME_MAX ||
        has_line_break(feed->name) || !url_syntax_allowed(feed->url) || !feed->channel_id ||
        feed->poll_interval_minutes < 5 || feed->poll_interval_minutes > 1440 ||
        feed->summary_characters < 80 || feed->summary_characters > 1000 ||
        (feed->enabled != 0 && feed->enabled != 1) ||
        (feed->include_image != 0 && feed->include_image != 1)) return 0;
    return 1;
}

static int copy_json_string(json_object *object, const char *key, char *out, size_t cap) {
    json_object *v = NULL;
    if (!json_object_object_get_ex(object, key, &v) || !json_object_is_type(v, json_type_string)) return -1;
    const char *s = json_object_get_string(v);
    size_t n = s ? (size_t)json_object_get_string_len(v) : 0;
    if (!s || n >= cap || memchr(s, 0, n)) return -1;
    memcpy(out, s, n); out[n] = 0;
    return 0;
}

int cr_bot_rss_load_feeds(const char *config_path, cr_bot_rss_feed *feeds,
                          size_t capacity, size_t *out_count) {
    if (!config_path || !feeds || !out_count) return -1;
    *out_count = 0;
    if (access(config_path, F_OK) != 0) return errno == ENOENT ? 0 : -1;
    json_object *root = json_object_from_file(config_path);
    if (!root || !json_object_is_type(root, json_type_object)) { if (root) json_object_put(root); return -1; }
    json_object *array = NULL;
    if (!json_object_object_get_ex(root, "rssFeeds", &array)) { json_object_put(root); return 0; }
    if (!json_object_is_type(array, json_type_array)) { json_object_put(root); return -1; }
    size_t count = json_object_array_length(array);
    if (count > CR_BOT_RSS_MAX_FEEDS || count > capacity) { json_object_put(root); return -1; }
    for (size_t i = 0; i < count; ++i) {
        json_object *row = json_object_array_get_idx(array, i);
        json_object *enabled = NULL, *image = NULL, *channel = NULL, *interval = NULL, *summary = NULL;
        cr_bot_rss_feed feed; memset(&feed, 0, sizeof(feed));
        if (!row || !json_object_is_type(row, json_type_object) ||
            copy_json_string(row, "id", feed.id, sizeof(feed.id)) ||
            copy_json_string(row, "name", feed.name, sizeof(feed.name)) ||
            copy_json_string(row, "url", feed.url, sizeof(feed.url)) ||
            !json_object_object_get_ex(row, "enabled", &enabled) || !json_object_is_type(enabled, json_type_boolean) ||
            !json_object_object_get_ex(row, "includeImage", &image) || !json_object_is_type(image, json_type_boolean) ||
            !json_object_object_get_ex(row, "channelID", &channel) || !json_object_is_type(channel, json_type_int) ||
            !json_object_object_get_ex(row, "pollIntervalMinutes", &interval) || !json_object_is_type(interval, json_type_int) ||
            !json_object_object_get_ex(row, "summaryCharacters", &summary) || !json_object_is_type(summary, json_type_int)) {
            json_object_put(root); return -1;
        }
        int64_t ch = json_object_get_int64(channel), pi = json_object_get_int64(interval), sc = json_object_get_int64(summary);
        if (ch <= 0 || ch > UINT32_MAX || pi < 0 || pi > UINT16_MAX || sc < 0 || sc > UINT16_MAX) { json_object_put(root); return -1; }
        feed.enabled = json_object_get_boolean(enabled) ? 1 : 0;
        feed.include_image = json_object_get_boolean(image) ? 1 : 0;
        feed.channel_id = (uint32_t)ch;
        feed.poll_interval_minutes = (uint16_t)pi;
        feed.summary_characters = (uint16_t)sc;
        if (!cr_bot_rss_feed_valid(&feed)) { json_object_put(root); return -1; }
        feeds[i] = feed;
    }
    json_object_put(root);
    *out_count = count;
    return 0;
}

int cr_bot_rss_store_feeds(const char *config_path, const cr_bot_rss_feed *feeds, size_t count) {
    if (!config_path || (!feeds && count) || count > CR_BOT_RSS_MAX_FEEDS) return -1;
    for (size_t i = 0; i < count; ++i) {
        if (!cr_bot_rss_feed_valid(&feeds[i])) return -1;
        for (size_t j = 0; j < i; ++j) if (!strcasecmp(feeds[i].id, feeds[j].id)) return -1;
    }
    json_object *root = NULL;
    if (access(config_path, F_OK) == 0) root = json_object_from_file(config_path);
    else if (errno == ENOENT) root = json_object_new_object();
    if (!root || !json_object_is_type(root, json_type_object)) { if (root) json_object_put(root); return -1; }
    json_object *array = json_object_new_array();
    if (!array) { json_object_put(root); return -1; }
    for (size_t i = 0; i < count; ++i) {
        const cr_bot_rss_feed *f = &feeds[i];
        json_object *row = json_object_new_object();
        if (!row) { json_object_put(array); json_object_put(root); return -1; }
        json_object_object_add(row, "id", json_object_new_string(f->id));
        json_object_object_add(row, "enabled", json_object_new_boolean(f->enabled));
        json_object_object_add(row, "name", json_object_new_string(f->name));
        json_object_object_add(row, "url", json_object_new_string(f->url));
        json_object_object_add(row, "channelID", json_object_new_int64(f->channel_id));
        json_object_object_add(row, "pollIntervalMinutes", json_object_new_int(f->poll_interval_minutes));
        json_object_object_add(row, "includeImage", json_object_new_boolean(f->include_image));
        json_object_object_add(row, "summaryCharacters", json_object_new_int(f->summary_characters));
        json_object_array_add(array, row);
    }
    json_object_object_add(root, "rssFeeds", array);
    char tmp[4096];
    int n = snprintf(tmp, sizeof(tmp), "%s.tmp.%ld", config_path, (long)getpid());
    int rc = -1;
    if (n > 0 && (size_t)n < sizeof(tmp) && json_object_to_file_ext(tmp, root, JSON_C_TO_STRING_PRETTY) == 0) {
        (void)chmod(tmp, 0600);
        if (rename(tmp, config_path) == 0) rc = 0; else unlink(tmp);
    }
    json_object_put(root);
    return rc;
}

static int blocked_sockaddr(const struct sockaddr *sa) {
    if (!sa) return 1;
    if (sa->sa_family == AF_INET) {
        const struct sockaddr_in *a = (const struct sockaddr_in *)sa;
        uint32_t ip = ntohl(a->sin_addr.s_addr);
        unsigned b0 = ip >> 24, b1 = (ip >> 16) & 255u;
        return b0 == 0 || b0 == 10 || b0 == 127 || b0 >= 224 ||
               (b0 == 100 && b1 >= 64 && b1 <= 127) ||
               (b0 == 169 && b1 == 254) ||
               (b0 == 172 && b1 >= 16 && b1 <= 31) ||
               (b0 == 192 && b1 == 168) ||
               (b0 == 198 && (b1 == 18 || b1 == 19));
    }
    if (sa->sa_family == AF_INET6) {
        const struct sockaddr_in6 *a = (const struct sockaddr_in6 *)sa;
        const uint8_t *b = a->sin6_addr.s6_addr;
        int all_zero = 1; for (int i = 0; i < 16; ++i) if (b[i]) { all_zero = 0; break; }
        int loop = 1; for (int i = 0; i < 15; ++i) if (b[i]) { loop = 0; break; }
        if (loop && b[15] != 1) loop = 0;
        return all_zero || loop || (b[0] & 0xfe) == 0xfc ||
               (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) || b[0] == 0xff;
    }
    return 1;
}

static curl_socket_t rss_open_socket(void *clientp, curlsocktype purpose, struct curl_sockaddr *address) {
    (void)clientp; (void)purpose;
    if (!address || blocked_sockaddr(&address->addr)) return CURL_SOCKET_BAD;
    return socket(address->family, address->socktype, address->protocol);
}

static int public_url_allowed(const char *url) {
    if (!url_syntax_allowed(url)) return 0;
    CURLU *u = curl_url(); if (!u) return 0;
    char *host = NULL; int ok = 0;
    if (curl_url_set(u, CURLUPART_URL, url, 0) == CURLUE_OK &&
        curl_url_get(u, CURLUPART_HOST, &host, 0) == CURLUE_OK && host) {
        size_t n = strlen(host);
        ok = strcasecmp(host, "localhost") && !(n >= 6 && !strcasecmp(host + n - 6, ".local"));
    }
    curl_free(host); curl_url_cleanup(u); return ok;
}

static size_t write_body(void *ptr, size_t size, size_t nmemb, void *opaque) {
    rss_buffer *b = opaque; size_t n = size * nmemb;
    if (!n) return 0;
    if (b->len > b->maximum || n > b->maximum - b->len) { b->failed = 1; return 0; }
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap * 2 : 8192;
        while (cap < b->len + n + 1) cap *= 2;
        if (cap > b->maximum + 1) cap = b->maximum + 1;
        uint8_t *p = realloc(b->data, cap); if (!p) { b->failed = 1; return 0; }
        b->data = p; b->cap = cap;
    }
    memcpy(b->data + b->len, ptr, n); b->len += n; b->data[b->len] = 0;
    return n;
}

static void trim_header_value(char *s) {
    if (!s) return;
    char *p = s; while (*p && isspace((unsigned char)*p)) ++p;
    if (p != s) memmove(s, p, strlen(p) + 1);
    size_t n = strlen(s); while (n && isspace((unsigned char)s[n - 1])) s[--n] = 0;
}

static size_t write_header(void *ptr, size_t size, size_t nmemb, void *opaque) {
    rss_http_result *result = opaque; size_t n = size * nmemb;
    const char *line = ptr;
    struct { const char *name; char *out; size_t cap; } fields[] = {
        {"ETag:", result->etag, sizeof(result->etag)},
        {"Last-Modified:", result->last_modified, sizeof(result->last_modified)},
    };
    for (size_t i = 0; i < sizeof(fields) / sizeof(fields[0]); ++i) {
        size_t prefix = strlen(fields[i].name);
        if (n > prefix && !strncasecmp(line, fields[i].name, prefix)) {
            size_t copy = n - prefix; if (copy >= fields[i].cap) copy = fields[i].cap - 1;
            memcpy(fields[i].out, line + prefix, copy); fields[i].out[copy] = 0; trim_header_value(fields[i].out);
        }
    }
    return n;
}

static int http_fetch(const char *url, size_t maximum, const char *etag,
                      const char *last_modified, rss_http_result *out) {
    if (!url || !out || !public_url_allowed(url)) return -1;
    pthread_once(&curl_once, rss_curl_init_once);
    memset(out, 0, sizeof(*out)); out->body.maximum = maximum;
    CURL *curl = curl_easy_init(); if (!curl) return -1;
    struct curl_slist *headers = NULL;
    char etag_header[640], modified_header[640];
    if (etag && *etag) { snprintf(etag_header, sizeof(etag_header), "If-None-Match: %s", etag); headers = curl_slist_append(headers, etag_header); }
    if (last_modified && *last_modified) { snprintf(modified_header, sizeof(modified_header), "If-Modified-Since: %s", last_modified); headers = curl_slist_append(headers, modified_header); }
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "Carracho-Bot-RSS/1.0.7");
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 5L);
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 12L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 20L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_PROXY, "");
    curl_easy_setopt(curl, CURLOPT_OPENSOCKETFUNCTION, rss_open_socket);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_body);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &out->body);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, write_header);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, out);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    CURLcode rc = curl_easy_perform(curl);
    if (rc == CURLE_OK) (void)curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &out->status);
    curl_slist_free_all(headers); curl_easy_cleanup(curl);
    if (rc != CURLE_OK || out->body.failed) { free(out->body.data); memset(out, 0, sizeof(*out)); return -1; }
    return 0;
}

static void http_result_free(rss_http_result *r) { if (r) { free(r->body.data); memset(r, 0, sizeof(*r)); } }

static xmlNode *first_child_named(xmlNode *parent, const char *name) {
    for (xmlNode *n = parent ? parent->children : NULL; n; n = n->next)
        if (n->type == XML_ELEMENT_NODE && !strcasecmp((const char *)n->name, name)) return n;
    return NULL;
}

static void copy_xml_content(xmlNode *node, char *out, size_t cap) {
    if (!out || !cap) return;
    out[0] = 0;
    if (!node) return;
    xmlChar *value = xmlNodeGetContent(node); if (!value) return;
    snprintf(out, cap, "%s", (const char *)value); xmlFree(value);
}

static void normalize_space(char *s) {
    if (!s) return;
    char *r = s, *w = s;
    int space = 1;
    while (*r) {
        unsigned char c = (unsigned char)*r++;
        if (isspace(c)) { if (!space) *w++ = ' '; space = 1; }
        else { *w++ = (char)c; space = 0; }
    }
    if (w > s && w[-1] == ' ') --w;
    *w = 0;
}

static size_t utf8_prefix_bytes(const char *s, size_t characters) {
    size_t i = 0, count = 0, n = strlen(s);
    while (i < n && count < characters) {
        unsigned char c = (unsigned char)s[i]; size_t step = 1;
        if ((c & 0xe0) == 0xc0) step = 2; else if ((c & 0xf0) == 0xe0) step = 3; else if ((c & 0xf8) == 0xf0) step = 4;
        if (i + step > n) break;
        i += step;
        ++count;
    }
    return i;
}

static const char *case_find(const char *haystack, const char *needle) {
    if (!haystack || !needle || !*needle) return haystack;
    size_t n = strlen(needle);
    for (const char *p = haystack; *p; ++p)
        if (!strncasecmp(p, needle, n)) return p;
    return NULL;
}

static void strip_common_feed_footer(char *text) {
    if (!text || !*text) return;
    char *marker = (char *)case_find(text, " Der Artikel ");
    if (marker && case_find(marker, " erschien zuerst auf ")) { *marker = 0; return; }
    marker = (char *)case_find(text, " The post ");
    if (marker && case_find(marker, " appeared first on ")) *marker = 0;
}

static void html_to_text(const char *html, char *out, size_t cap, size_t max_chars) {
    if (!out || !cap) return;
    out[0] = 0;
    if (!html || !*html) return;
    size_t n = strlen(html); size_t wrapper_len = n + 32;
    char *wrapper = malloc(wrapper_len); if (!wrapper) return;
    snprintf(wrapper, wrapper_len, "<html><body>%s</body></html>", html);
    htmlDocPtr doc = htmlReadMemory(wrapper, (int)strlen(wrapper), NULL, "UTF-8",
                                    HTML_PARSE_RECOVER | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING | HTML_PARSE_NONET);
    free(wrapper);
    if (doc) {
        xmlNode *root = xmlDocGetRootElement(doc), *body = NULL;
        if (root) body = first_child_named(root, "body");
        xmlChar *text = xmlNodeGetContent(body ? body : root);
        if (text) { snprintf(out, cap, "%s", (const char *)text); xmlFree(text); }
        xmlFreeDoc(doc);
    } else snprintf(out, cap, "%s", html);
    normalize_space(out);
    strip_common_feed_footer(out);
    normalize_space(out);
    size_t bytes = utf8_prefix_bytes(out, max_chars);
    if (out[bytes] && bytes + 4 < cap) { out[bytes] = 0; strcat(out, "…"); }
}

static void find_img_src(const char *html, char *out, size_t cap) {
    if (!out || !cap) return;
    out[0] = 0;
    if (!html) return;
    const char *p = html;
    while ((p = case_find(p, "<img")) != NULL) {
        const char *end = strchr(p, '>'); if (!end) return;
        const char *src = p;
        while ((src = case_find(src, "src")) != NULL && src < end) {
            const char *q = src + 3; while (q < end && isspace((unsigned char)*q)) ++q;
            if (q >= end || *q != '=') { src = q; continue; }
            ++q; while (q < end && isspace((unsigned char)*q)) ++q;
            if (q >= end || (*q != '\'' && *q != '"')) { src = q; continue; }
            char quote = *q++; const char *finish = memchr(q, quote, (size_t)(end - q)); if (!finish) return;
            size_t len = (size_t)(finish - q); if (len && len < cap) { memcpy(out, q, len); out[len] = 0; } return;
        }
        p = end + 1;
    }
}

static int namespace_is_media(xmlNode *node) {
    if (!node || !node->ns || !node->ns->href) return 0;
    const char *href = (const char *)node->ns->href;
    return strstr(href, "search.yahoo.com/mrss") != NULL || strstr(href, "media") != NULL;
}

static void consider_image(xmlNode *node, rss_parsed_item *item) {
    if (!node || !item || node->type != XML_ELEMENT_NODE) return;
    const char *name = (const char *)node->name; int priority = 0;
    if (!strcasecmp(name, "content") && namespace_is_media(node)) priority = 1;
    else if (!strcasecmp(name, "thumbnail") && namespace_is_media(node)) priority = 2;
    else if (!strcasecmp(name, "enclosure")) priority = 3;
    if (!priority || (item->image_priority && item->image_priority <= priority)) return;
    xmlChar *url = xmlGetProp(node, (const xmlChar *)"url");
    if (!url) return;
    const char *u = (const char *)url;
    if (strlen(u) <= CR_BOT_RSS_URL_MAX && url_syntax_allowed(u)) {
        snprintf(item->article.image_url, sizeof(item->article.image_url), "%s", u);
        item->image_priority = priority;
    }
    xmlFree(url);
}

static void scan_item_children(xmlNode *parent, rss_parsed_item *item,
                               char *body, size_t body_cap, int atom) {
    for (xmlNode *n = parent ? parent->children : NULL; n; n = n->next) {
        if (n->type != XML_ELEMENT_NODE) continue;
        const char *name = (const char *)n->name;
        consider_image(n, item);
        if (!strcasecmp(name, "title") && !item->article.title[0]) copy_xml_content(n, item->article.title, sizeof(item->article.title));
        else if ((!strcasecmp(name, "guid") || !strcasecmp(name, "id")) && !item->article.key[0]) copy_xml_content(n, item->article.key, sizeof(item->article.key));
        else if (!strcasecmp(name, "link") && !item->article.link[0]) {
            if (atom) {
                xmlChar *rel = xmlGetProp(n, (const xmlChar *)"rel");
                xmlChar *href = xmlGetProp(n, (const xmlChar *)"href");
                int alternate = !rel || !strcasecmp((const char *)rel, "alternate");
                if (href && alternate) snprintf(item->article.link, sizeof(item->article.link), "%s", (const char *)href);
                xmlFree(rel); xmlFree(href);
            } else copy_xml_content(n, item->article.link, sizeof(item->article.link));
        } else if (!strcasecmp(name, "description") || !strcasecmp(name, "summary") ||
                   !strcasecmp(name, "encoded") || (!strcasecmp(name, "content") && !namespace_is_media(n))) {
            char *candidate = calloc(1, RSS_FEED_MAX_BYTES + 1);
            if (candidate) {
                copy_xml_content(n, candidate, RSS_FEED_MAX_BYTES + 1);
                if (strlen(candidate) > strlen(body)) snprintf(body, body_cap, "%s", candidate);
                free(candidate);
            }
        }
        scan_item_children(n, item, body, body_cap, atom);
    }
}

static int parse_item(xmlNode *node, int atom, uint16_t summary_chars, rss_parsed_item *out) {
    memset(out, 0, sizeof(*out));
    char *body = calloc(1, RSS_FEED_MAX_BYTES + 1); if (!body) return -1;
    scan_item_children(node, out, body, RSS_FEED_MAX_BYTES + 1, atom);
    char raw_title[sizeof(out->article.title)];
    snprintf(raw_title,sizeof(raw_title),"%s",out->article.title);
    html_to_text(raw_title, out->article.title, sizeof(out->article.title), CR_BOT_RSS_TITLE_MAX);
    html_to_text(body, out->article.summary, sizeof(out->article.summary), summary_chars);
    if (!out->article.image_url[0]) find_img_src(body, out->article.image_url, sizeof(out->article.image_url));
    free(body);
    normalize_space(out->article.link); normalize_space(out->article.key);
    if (!out->article.title[0] || !out->article.link[0] || !url_syntax_allowed(out->article.link)) return -1;
    if (!out->article.key[0]) snprintf(out->article.key, sizeof(out->article.key), "%s", out->article.link);
    return 0;
}

static void collect_items(xmlNode *node, int atom, uint16_t summary_chars,
                          rss_parsed_item *items, size_t *count) {
    for (xmlNode *n = node; n && *count < RSS_MAX_ITEMS; n = n->next) {
        if (n->type == XML_ELEMENT_NODE &&
            ((!atom && !strcasecmp((const char *)n->name, "item")) ||
             (atom && !strcasecmp((const char *)n->name, "entry")))) {
            rss_parsed_item item;
            if (parse_item(n, atom, summary_chars, &item) == 0) items[(*count)++] = item;
        } else collect_items(n->children, atom, summary_chars, items, count);
    }
}

static int parse_feed(const uint8_t *data, size_t len, uint16_t summary_chars,
                      rss_parsed_item *items, size_t *out_count) {
    if (!data || !len || !items || !out_count || len > RSS_FEED_MAX_BYTES) return -1;
    *out_count = 0;
    xmlDocPtr doc = xmlReadMemory((const char *)data, (int)len, NULL, NULL,
                                  XML_PARSE_NONET | XML_PARSE_RECOVER | XML_PARSE_NOERROR | XML_PARSE_NOWARNING);
    if (!doc) return -1;
    xmlNode *root = xmlDocGetRootElement(doc);
    int atom = root && !strcasecmp((const char *)root->name, "feed");
    collect_items(root, atom, summary_chars, items, out_count);
    xmlFreeDoc(doc);
    return *out_count ? 0 : -1;
}

static int open_state_db(const char *path, sqlite3 **out) {
    if (!path || !out) return -1;
    *out = NULL;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return -1;
    }
    const char *schema = "PRAGMA journal_mode=WAL;PRAGMA synchronous=NORMAL;"
        "CREATE TABLE IF NOT EXISTS rss_feed_state(feed_key TEXT PRIMARY KEY,initialized INTEGER NOT NULL,last_checked REAL NOT NULL,etag TEXT,last_modified TEXT);"
        "CREATE TABLE IF NOT EXISTS rss_seen(feed_key TEXT NOT NULL,item_key TEXT NOT NULL,seen_at REAL NOT NULL,PRIMARY KEY(feed_key,item_key));"
        "CREATE INDEX IF NOT EXISTS rss_seen_time_idx ON rss_seen(seen_at);";
    if (sqlite3_exec(db, schema, NULL, NULL, NULL) != SQLITE_OK) { sqlite3_close(db); return -1; }
    *out = db; return 0;
}

static void state_key(const cr_bot_rss_feed *feed, char *out, size_t cap) {
    snprintf(out, cap, "%s|%s", feed->id, feed->url);
}

static int load_state(sqlite3 *db, const char *key, rss_feed_state *out) {
    memset(out, 0, sizeof(*out)); sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "SELECT initialized,last_checked,etag,last_modified FROM rss_feed_state WHERE feed_key=?", -1, &st, NULL) != SQLITE_OK) return -1;
    sqlite3_bind_text(st, 1, key, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW) {
        out->initialized = sqlite3_column_int(st, 0) != 0; out->last_checked = sqlite3_column_double(st, 1);
        const unsigned char *e = sqlite3_column_text(st, 2), *m = sqlite3_column_text(st, 3);
        if (e) snprintf(out->etag, sizeof(out->etag), "%s", (const char *)e);
        if (m) snprintf(out->last_modified, sizeof(out->last_modified), "%s", (const char *)m);
    }
    sqlite3_finalize(st); return 0;
}

static int save_state(sqlite3 *db, const char *key, const rss_feed_state *state) {
    sqlite3_stmt *st = NULL;
    const char *sql = "INSERT INTO rss_feed_state(feed_key,initialized,last_checked,etag,last_modified) VALUES(?,?,?,?,?) ON CONFLICT(feed_key) DO UPDATE SET initialized=excluded.initialized,last_checked=excluded.last_checked,etag=excluded.etag,last_modified=excluded.last_modified";
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) return -1;
    sqlite3_bind_text(st, 1, key, -1, SQLITE_TRANSIENT); sqlite3_bind_int(st, 2, state->initialized); sqlite3_bind_double(st, 3, state->last_checked);
    if (state->etag[0]) sqlite3_bind_text(st, 4, state->etag, -1, SQLITE_TRANSIENT); else sqlite3_bind_null(st, 4);
    if (state->last_modified[0]) sqlite3_bind_text(st, 5, state->last_modified, -1, SQLITE_TRANSIENT); else sqlite3_bind_null(st, 5);
    int rc = sqlite3_step(st) == SQLITE_DONE ? 0 : -1; sqlite3_finalize(st); return rc;
}

static int item_seen(sqlite3 *db, const char *feed_key, const char *item_key) {
    sqlite3_stmt *st = NULL; int seen = 0;
    if (sqlite3_prepare_v2(db, "SELECT 1 FROM rss_seen WHERE feed_key=? AND item_key=?", -1, &st, NULL) != SQLITE_OK) return 1;
    sqlite3_bind_text(st, 1, feed_key, -1, SQLITE_TRANSIENT); sqlite3_bind_text(st, 2, item_key, -1, SQLITE_TRANSIENT);
    seen = sqlite3_step(st) == SQLITE_ROW; sqlite3_finalize(st); return seen;
}

static int mark_seen(sqlite3 *db, const char *feed_key, const char *item_key) {
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO rss_seen(feed_key,item_key,seen_at) VALUES(?,?,?)", -1, &st, NULL) != SQLITE_OK) return -1;
    sqlite3_bind_text(st, 1, feed_key, -1, SQLITE_TRANSIENT); sqlite3_bind_text(st, 2, item_key, -1, SQLITE_TRANSIENT); sqlite3_bind_int64(st, 3, (sqlite3_int64)time(NULL));
    int rc = sqlite3_step(st) == SQLITE_DONE ? 0 : -1; sqlite3_finalize(st); return rc;
}

static void log_line(cr_bot_rss_log_fn fn, void *opaque, const char *feed, const char *text) {
    if (!fn) return;
    char line[1024];
    snprintf(line, sizeof(line), "Bot RSS %.120s: %.820s", feed ? feed : "", text ? text : "");
    fn(opaque, line);
}

static void filename_from_url(const char *url, char *out, size_t cap) {
    if (!out || !cap) return;
    snprintf(out, cap, "%s", "rss-image");
    if (!url) return;
    const char *slash = strrchr(url, '/'); const char *leaf = slash ? slash + 1 : url; const char *q = strchr(leaf, '?'); size_t n = q ? (size_t)(q - leaf) : strlen(leaf);
    if (n && n < cap) { memcpy(out, leaf, n); out[n] = 0; }
}

static void maybe_fetch_image(cr_bot_rss_article *article) {
    if (!article || !article->image_url[0]) return;
    rss_http_result image; memset(&image, 0, sizeof(image));
    if (http_fetch(article->image_url, CR_BOT_RSS_IMAGE_MAX, NULL, NULL, &image) == 0 && image.status == 200 && image.body.len) {
        article->image_data = image.body.data; article->image_len = image.body.len; image.body.data = NULL;
        filename_from_url(article->image_url, article->image_filename, sizeof(article->image_filename));
    }
    http_result_free(&image);
}

void cr_bot_rss_article_free(cr_bot_rss_article *article) {
    if (!article) return;
    free(article->image_data);
    article->image_data = NULL;
    article->image_len = 0;
}

int cr_bot_rss_test_feed(const cr_bot_rss_feed *feed, cr_bot_rss_article *out) {
    if (!feed || !out || !cr_bot_rss_feed_valid(feed)) return -1;
    rss_http_result result; memset(&result, 0, sizeof(result));
    if (http_fetch(feed->url, RSS_FEED_MAX_BYTES, NULL, NULL, &result) || result.status != 200) { http_result_free(&result); return -1; }
    rss_parsed_item *items = calloc(RSS_MAX_ITEMS, sizeof(*items));
    if (!items) { http_result_free(&result); return -1; }
    size_t count = 0;
    int rc = parse_feed(result.body.data, result.body.len, feed->summary_characters, items, &count);
    if (!rc && count) {
        *out = items[0].article;
        if (feed->include_image) maybe_fetch_image(out);
    } else rc = -1;
    free(items); http_result_free(&result); return rc;
}

int cr_bot_rss_poll(const char *config_path, const char *database_path,
                    cr_bot_rss_publish_fn publish, cr_bot_rss_log_fn log_fn,
                    void *opaque) {
    if (!config_path || !database_path || !publish) return -1;
    cr_bot_rss_feed feeds[CR_BOT_RSS_MAX_FEEDS]; size_t feed_count = 0;
    if (cr_bot_rss_load_feeds(config_path, feeds, CR_BOT_RSS_MAX_FEEDS, &feed_count)) return -1;
    sqlite3 *db = NULL; if (open_state_db(database_path, &db)) return -1;
    double now = (double)time(NULL);
    for (size_t fi = 0; fi < feed_count; ++fi) {
        cr_bot_rss_feed *feed = &feeds[fi]; if (!feed->enabled) continue;
        char key[CR_BOT_RSS_URL_MAX + 64]; state_key(feed, key, sizeof(key)); rss_feed_state state;
        if (load_state(db, key, &state)) continue;
        if (now - state.last_checked < (double)feed->poll_interval_minutes * 60.0) continue;
        rss_http_result result; memset(&result, 0, sizeof(result));
        int fetch_rc = http_fetch(feed->url, RSS_FEED_MAX_BYTES, state.etag, state.last_modified, &result);
        state.last_checked = now;
        if (fetch_rc) { (void)save_state(db, key, &state); log_line(log_fn, opaque, feed->name, "fetch failed"); continue; }
        if (result.etag[0]) snprintf(state.etag, sizeof(state.etag), "%s", result.etag);
        if (result.last_modified[0]) snprintf(state.last_modified, sizeof(state.last_modified), "%s", result.last_modified);
        if (result.status == 304) { (void)save_state(db, key, &state); http_result_free(&result); continue; }
        if (result.status != 200) { char m[80]; snprintf(m, sizeof(m), "HTTP %ld", result.status); log_line(log_fn, opaque, feed->name, m); (void)save_state(db, key, &state); http_result_free(&result); continue; }
        rss_parsed_item *items = calloc(RSS_MAX_ITEMS, sizeof(*items)); size_t item_count = 0;
        if (!items || parse_feed(result.body.data, result.body.len, feed->summary_characters, items, &item_count)) { free(items); log_line(log_fn, opaque, feed->name, "feed has no usable articles"); (void)save_state(db, key, &state); http_result_free(&result); continue; }
        if (!state.initialized) {
            for (size_t i = 0; i < item_count; ++i) (void)mark_seen(db, key, items[i].article.key);
            state.initialized = 1; (void)save_state(db, key, &state); char m[100]; snprintf(m, sizeof(m), "initialized with %zu existing item(s)", item_count); log_line(log_fn, opaque, feed->name, m); free(items); http_result_free(&result); continue;
        }
        size_t unseen[RSS_MAX_ITEMS], unseen_count = 0;
        for (size_t i = 0; i < item_count; ++i) if (!item_seen(db, key, items[i].article.key)) unseen[unseen_count++] = i;
        size_t selected = unseen_count < 5 ? unseen_count : 5;
        for (size_t rev = selected; rev > 0; --rev) {
            rss_parsed_item *item = &items[unseen[rev - 1]];
            if (feed->include_image) maybe_fetch_image(&item->article);
            if (publish(opaque, feed, &item->article) == 0) (void)mark_seen(db, key, item->article.key);
            cr_bot_rss_article_free(&item->article);
        }
        for (size_t i = 5; i < unseen_count; ++i) (void)mark_seen(db, key, items[unseen[i]].article.key);
        (void)save_state(db, key, &state); free(items); http_result_free(&result);
    }
    sqlite3_close(db); return 0;
}
