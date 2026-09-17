#ifndef CARRACHO_FILE_METADATA_H
#define CARRACHO_FILE_METADATA_H

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <limits.h>
#include <sqlite3.h>

typedef struct cr_file_metadata {
    uint16_t flags;
    uint8_t *comment;
    size_t comment_len;
    uint8_t finder_info[16];
    /* Modern-only Finder-style label number: 0 none, 1...7 colors. */
    uint8_t label;
    char created_at[64];
    int has_created_at;
} cr_file_metadata;

typedef struct cr_file_metadata_store {
    sqlite3 *db;
    int scope;
    pthread_mutex_t mutex;
} cr_file_metadata_store;

enum {
    CR_FILE_METADATA_SCOPE_PUBLISHED = 0,
    CR_FILE_METADATA_SCOPE_LEGACY = 1
};

int cr_file_metadata_store_init(cr_file_metadata_store *store, const char *database_path,
                                int scope, const char *legacy_json_path);
void cr_file_metadata_store_destroy(cr_file_metadata_store *store);
void cr_file_metadata_init(cr_file_metadata *metadata);
void cr_file_metadata_free(cr_file_metadata *metadata);
int cr_file_metadata_get(cr_file_metadata_store *store, const uint8_t *path, size_t path_len,
                         cr_file_metadata *out, int *found);
int cr_file_metadata_set(cr_file_metadata_store *store, const uint8_t *path, size_t path_len,
                         const cr_file_metadata *metadata);
int cr_file_metadata_remove(cr_file_metadata_store *store, const uint8_t *path, size_t path_len,
                            int including_descendants);
int cr_file_metadata_move(cr_file_metadata_store *store,
                          const uint8_t *source, size_t source_len,
                          const uint8_t *destination, size_t destination_len,
                          int including_descendants);

#endif
