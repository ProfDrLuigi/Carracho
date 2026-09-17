#ifndef CARRACHO_BOT_RSS_H
#define CARRACHO_BOT_RSS_H

#include <stddef.h>
#include <stdint.h>

#define CR_BOT_RSS_MAX_FEEDS 16u
#define CR_BOT_RSS_NAME_MAX 96u
#define CR_BOT_RSS_URL_MAX 2048u
#define CR_BOT_RSS_SUMMARY_MAX 1000u
#define CR_BOT_RSS_TITLE_MAX 512u
#define CR_BOT_RSS_KEY_MAX 2048u
#define CR_BOT_RSS_IMAGE_MAX (4u * 1024u * 1024u)

typedef struct cr_bot_rss_feed {
    int enabled;
    int include_image;
    char id[37];
    char name[CR_BOT_RSS_NAME_MAX + 1];
    char url[CR_BOT_RSS_URL_MAX + 1];
    uint32_t channel_id;
    uint16_t poll_interval_minutes;
    uint16_t summary_characters;
} cr_bot_rss_feed;

typedef struct cr_bot_rss_article {
    char key[CR_BOT_RSS_KEY_MAX + 1];
    char title[CR_BOT_RSS_TITLE_MAX * 4 + 1];
    char summary[CR_BOT_RSS_SUMMARY_MAX * 4 + 1];
    char link[CR_BOT_RSS_URL_MAX + 1];
    char image_url[CR_BOT_RSS_URL_MAX + 1];
    char image_filename[256];
    uint8_t *image_data;
    size_t image_len;
} cr_bot_rss_article;

typedef int (*cr_bot_rss_publish_fn)(void *opaque, const cr_bot_rss_feed *feed,
                                     const cr_bot_rss_article *article);
typedef void (*cr_bot_rss_log_fn)(void *opaque, const char *message);

int cr_bot_rss_feed_valid(const cr_bot_rss_feed *feed);
int cr_bot_rss_load_feeds(const char *config_path, cr_bot_rss_feed *feeds,
                          size_t capacity, size_t *out_count);
int cr_bot_rss_store_feeds(const char *config_path, const cr_bot_rss_feed *feeds,
                           size_t count);
int cr_bot_rss_test_feed(const cr_bot_rss_feed *feed, cr_bot_rss_article *out);
int cr_bot_rss_poll(const char *config_path, const char *database_path,
                    cr_bot_rss_publish_fn publish, cr_bot_rss_log_fn log_fn,
                    void *opaque);
void cr_bot_rss_article_free(cr_bot_rss_article *article);

#endif
