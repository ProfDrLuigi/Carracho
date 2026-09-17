#ifndef CARRACHO_FLAT_NEWS_STORE_H
#define CARRACHO_FLAT_NEWS_STORE_H
#include "carracho_protocol.h"
#include <limits.h>
#include <pthread.h>
#include <sqlite3.h>
#include <stddef.h>
#include <stdint.h>

typedef struct cr_flat_news_store {
    char db_path[PATH_MAX];
    char legacy_path[PATH_MAX];
    char classic_path[PATH_MAX];
    sqlite3 *db;
    pthread_mutex_t mutex;
} cr_flat_news_store;
int cr_flat_news_store_init(cr_flat_news_store *store,const char *db_path,const char *legacy_path,const char *classic_path);
void cr_flat_news_store_destroy(cr_flat_news_store *store);
int cr_flat_news_all(cr_flat_news_store *store,cr_buffer **entries,size_t *count);
void cr_flat_news_entries_free(cr_buffer *entries,size_t count);
int cr_flat_news_append(cr_flat_news_store *store,const uint8_t *entry,size_t len,uint32_t *index_out);
int cr_flat_news_delete(cr_flat_news_store *store,uint32_t wire_index);
int cr_flat_news_clear(cr_flat_news_store *store);
#endif
