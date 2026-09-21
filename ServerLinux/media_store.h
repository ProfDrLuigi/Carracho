#ifndef CARRACHO_MEDIA_STORE_H
#define CARRACHO_MEDIA_STORE_H

#include <limits.h>
#include <pthread.h>
#include <sqlite3.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#define CR_MEDIA_MAX_BYTES (4u * 1024u * 1024u)
#define CR_MEDIA_MAX_DIMENSION 4096u
#define CR_MEDIA_KIND_CHAT 1
#define CR_MEDIA_KIND_NEWS 2
#define CR_MEDIA_KIND_PRIVATE_MESSAGE 3

typedef struct cr_media_store {
  sqlite3 *db;
  pthread_mutex_t mutex;
  char objects_root[PATH_MAX];
} cr_media_store;

typedef struct cr_media_object {
  char id[37];
  char owner_account_id[64];
  char mime_type[32];
  char filename[1025];
  uint32_t width;
  uint32_t height;
  uint8_t *data;
  size_t data_len;
} cr_media_object;

int cr_media_store_init(cr_media_store *store, const char *db_path,
                        const char *objects_root);
void cr_media_store_destroy(cr_media_store *store);
int cr_media_store_pending(cr_media_store *store, const char *owner_account_id,
                           const char *filename, const uint8_t *data,
                           size_t data_len, char out_id[37]);
int cr_media_store_is_owned(cr_media_store *store, const char *id,
                            const char *owner_account_id);
/* 0 = deleted, 1 = not found/not owner, -1 = storage failure. */
int cr_media_store_delete_owned(cr_media_store *store, const char *id,
                                const char *owner_account_id);
int cr_media_store_bind(cr_media_store *store, const char *id,
                        const char *owner_account_id, int kind,
                        const char *scope, const char *message_id,
                        time_t expires_at);
int cr_media_store_has_ref(cr_media_store *store, const char *id, int kind,
                           const char *scope);
int cr_media_store_load(cr_media_store *store, const char *id,
                        cr_media_object *out);
void cr_media_object_free(cr_media_object *object);
int cr_media_store_remove_refs(cr_media_store *store, int kind,
                               const char *scope,
                               const char *const *message_ids,
                               size_t message_count);
/* Remove one specific message reference. object_deleted is set when this was the last
   reference and the media object/file was removed from the pool. */
int cr_media_store_remove_ref(cr_media_store *store, const char *id, int kind,
                              const char *scope, const char *message_id,
                              int *object_deleted);
int cr_media_store_cleanup(cr_media_store *store, time_t now);
int cr_media_store_prune_news(cr_media_store *store, const char *news_db_path);

#endif
