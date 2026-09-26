#ifndef CARRACHO_BOT_FILE_WATCH_H
#define CARRACHO_BOT_FILE_WATCH_H

#include <stddef.h>
#include <stdint.h>

#define CR_BOT_FILE_WATCH_MAX 32u
#define CR_BOT_FILE_WATCH_PATH_MAX 1024u
#define CR_BOT_FILE_WATCH_TEMPLATE_MAX 1024u

typedef struct cr_bot_file_watcher {
    char id[37];
    int enabled;
    char path[CR_BOT_FILE_WATCH_PATH_MAX + 1];
    uint32_t channel_id;
    char message_template[CR_BOT_FILE_WATCH_TEMPLATE_MAX + 1];
} cr_bot_file_watcher;

typedef int (*cr_bot_file_watch_should_stop_cb)(void *opaque);
typedef int (*cr_bot_file_watch_can_publish_cb)(void *opaque);
typedef int (*cr_bot_file_watch_publish_cb)(void *opaque,
                                             const cr_bot_file_watcher *watcher,
                                             const char *folder_path,
                                             const char *folder_name,
                                             const char *file_name);
typedef void (*cr_bot_file_watch_log_cb)(void *opaque, const char *message);

int cr_bot_file_watch_load(const char *config_path,
                           const char *files_root,
                           cr_bot_file_watcher *out,
                           size_t capacity,
                           size_t *out_count);

int cr_bot_file_watch_store(const char *config_path,
                            const char *files_root,
                            const cr_bot_file_watcher *watchers,
                            size_t count);

int cr_bot_file_watch_run(const char *config_path,
                          const char *files_root,
                          cr_bot_file_watch_should_stop_cb should_stop,
                          cr_bot_file_watch_can_publish_cb can_publish,
                          cr_bot_file_watch_publish_cb publish,
                          cr_bot_file_watch_log_cb log_cb,
                          void *opaque);

#endif
