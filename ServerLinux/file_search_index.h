#ifndef CARRACHO_FILE_SEARCH_INDEX_H
#define CARRACHO_FILE_SEARCH_INDEX_H

#include "file_metadata.h"
#include "server_state.h"
#include <pthread.h>
#include <signal.h>
#include <sqlite3.h>
#include <stddef.h>
#include <stdint.h>
#include <limits.h>

typedef struct cr_file_search_index {
    sqlite3 *db;
    pthread_mutex_t mutex;
    char path[PATH_MAX];
    int ready;
} cr_file_search_index;

typedef struct cr_file_search_index_result {
    uint8_t path[4096]; size_t path_len;
    uint8_t name[256]; size_t name_len;
    int is_folder;
    uint32_t size;
    uint32_t timestamp;
} cr_file_search_index_result;

typedef int (*cr_file_search_index_callback)(void *context, const cr_file_search_index_result *result);

int cr_file_search_index_init(cr_file_search_index *index, const char *path);
void cr_file_search_index_destroy(cr_file_search_index *index);
int cr_file_search_index_rebuild(cr_file_search_index *index, const char *storage_root, cr_file_metadata_store *metadata,
                                 const cr_search_index_exclusions *exclusions);
int cr_file_search_index_rebuild_interruptible(cr_file_search_index *index, const char *storage_root,
                                               cr_file_metadata_store *metadata,
                                               const cr_search_index_exclusions *exclusions,
                                               const volatile sig_atomic_t *stop);
int cr_file_search_index_upsert_subtree(cr_file_search_index *index, const char *fs_path,
                                        const uint8_t *legacy_path, size_t legacy_path_len,
                                        cr_file_metadata_store *metadata,
                                        const cr_search_index_exclusions *exclusions);
int cr_file_search_index_remove_subtree(cr_file_search_index *index, const uint8_t *legacy_path, size_t legacy_path_len);
int cr_file_search_index_move_subtree(cr_file_search_index *index,
                                      const uint8_t *source, size_t source_len,
                                      const uint8_t *destination, size_t destination_len,
                                      const char *destination_fs_path,
                                      cr_file_metadata_store *metadata,
                                      const cr_search_index_exclusions *exclusions);
int cr_file_search_index_search(cr_file_search_index *index, const char *query,
                                const cr_search_index_exclusions *exclusions,
                                cr_file_search_index_callback callback, void *context,
                                size_t *result_count);

#endif
