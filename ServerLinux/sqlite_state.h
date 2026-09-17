#ifndef CARRACHO_SQLITE_STATE_H
#define CARRACHO_SQLITE_STATE_H

#include <json-c/json.h>
#include <sqlite3.h>
#include <stddef.h>
#include <stdint.h>

typedef struct cr_offline_message_blob {
    char id[37];
    uint64_t created_at;
    uint8_t *plaintext;
    size_t plaintext_len;
} cr_offline_message_blob;

int cr_sqlite_state_open(sqlite3 **out, const char *path);
int cr_sqlite_state_has_state(sqlite3 *db);
int cr_sqlite_state_save(sqlite3 *db, json_object *root);
json_object *cr_sqlite_state_load(sqlite3 *db);
int cr_sqlite_sync_account_transfer_rows(sqlite3 *db, json_object *accounts);
int cr_sqlite_record_account_transfer(sqlite3 *db, const char *account_id, const char *login, int is_download, uint64_t bytes);
int cr_sqlite_account_transfer_statistics(sqlite3 *db, const char *account_id,
                                          uint64_t *download_count, uint64_t *download_bytes,
                                          uint64_t *upload_count, uint64_t *upload_bytes);
int cr_sqlite_offline_message_put(sqlite3 *db, const char *recipient_account_id,
                                  const uint8_t *plaintext, size_t plaintext_len,
                                  uint64_t created_at, char out_id[37]);
int cr_sqlite_offline_message_count(sqlite3 *db, const char *recipient_account_id, size_t *out_count);
int cr_sqlite_offline_message_load(sqlite3 *db, const char *recipient_account_id,
                                   cr_offline_message_blob **out_messages, size_t *out_count);
void cr_sqlite_offline_message_free(cr_offline_message_blob *messages, size_t count);
int cr_sqlite_offline_message_ack(sqlite3 *db, const char *recipient_account_id,
                                  const char *const *ids, size_t count);

#endif
