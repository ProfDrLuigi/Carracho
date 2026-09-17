#ifndef CARRACHO_NEWS_STORE_H
#define CARRACHO_NEWS_STORE_H
#include "carracho_protocol.h"
#include <limits.h>
#include <pthread.h>
#include <sqlite3.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

typedef struct cr_news_store {
    char db_path[PATH_MAX];
    char legacy_root[PATH_MAX];
    sqlite3 *db;
    pthread_mutex_t mutex;
} cr_news_store;
int cr_news_store_init(cr_news_store *store,const char *db_path,const char *legacy_root);
void cr_news_store_destroy(cr_news_store *store);
int cr_news_count(cr_news_store *store,const char *group_id,uint32_t *count);
int cr_news_post(cr_news_store *store,const char *group_id,const uint8_t *subject,size_t subject_len,
                 const uint8_t *sender,size_t sender_len,uint32_t date,
                 const uint8_t *text,size_t text_len,const uint8_t *style,size_t style_len,
                 uint32_t parent_article_id,const char *owner_account_id,uint32_t *article_id);
int cr_news_update_owned(cr_news_store *store,const char *group_id,uint32_t article_id,
                         const char *requester_account_id,int can_moderate,const uint8_t *subject,size_t subject_len,
                         const uint8_t *text,size_t text_len,const uint8_t *style,size_t style_len);
int cr_news_index(cr_news_store *store,const char *group_id,const uint8_t *group,size_t group_len,cr_buffer *encoded);
int cr_news_threads(cr_news_store *store,const char *group_id,cr_buffer *encoded);
int cr_news_thread_posts(cr_news_store *store,const char *group_id,uint32_t thread_id,cr_buffer *encoded);
int cr_news_thread_capabilities(cr_news_store *store,const char *group_id,uint32_t thread_id,
                                const char *account_id,int can_moderate,cr_buffer *encoded);
int cr_news_reactions(cr_news_store *store,const char *group_id,uint32_t article_id,const char *account_id,cr_buffer *encoded);
/* Modern extension: u16 row count followed by (u8 reaction, string16 account_id) rows. */
int cr_news_reaction_accounts(cr_news_store *store,const char *group_id,uint32_t article_id,cr_buffer *encoded);
int cr_news_set_reaction(cr_news_store *store,const char *group_id,uint32_t article_id,const char *account_id,uint8_t reaction,cr_buffer *encoded);
int cr_news_reply(cr_news_store *store,const char *group_id,const uint8_t *group,size_t group_len,uint32_t article_id,
                  cr_buffer *metadata,cr_buffer *body);
int cr_news_delete(cr_news_store *store,const char *group_id,uint32_t article_id,int *deleted);
int cr_news_soft_delete(cr_news_store *store,const char *group_id,uint32_t article_id,
                        const char *requester_account_id,int can_moderate,int *deleted);
int cr_news_expire(cr_news_store *store,const char *group_id,uint32_t expire_after,time_t now,uint32_t *removed);
int cr_news_prune(cr_news_store *store,const char *const *group_ids,size_t group_count);
#endif
