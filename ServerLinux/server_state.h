#ifndef CARRACHO_SERVER_STATE_H
#define CARRACHO_SERVER_STATE_H

#include <json-c/json.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <limits.h>
#include <sqlite3.h>

#define CR_MAX_ACCOUNTS 1024
#define CR_MAX_ACCOUNT_GROUPS 256
#define CR_MAX_NEWSGROUPS 1024
#define CR_MAX_IP_RESTRICTIONS 1024
#define CR_MAX_IDENTITY_TEXT 16384
#define CR_MAX_SEARCH_INDEX_EXCLUSIONS 256
#define CR_MAX_SEARCH_INDEX_PATTERN 256
#define CR_LOCAL_BOT_ACCOUNT_ID "00000000-0000-0000-0000-00000000b070"

typedef enum cr_account_mode { CR_MODE_GUEST=0, CR_MODE_ACCOUNT=1, CR_MODE_ADMIN=2 } cr_account_mode;
typedef enum cr_personal_mode { CR_PERSONAL_NONE=0, CR_PERSONAL_NESTED=1, CR_PERSONAL_ROOT=2 } cr_personal_mode;

typedef struct cr_account_group {
    char id[64];
    char name[256];
    uint32_t color_rgb;
    cr_account_mode mode;
    uint64_t permission_bits;
    char files_root_path[1025];
    char files_root_name[257];
} cr_account_group;

typedef struct cr_account {
    char id[64];
    char login[256];
    char name[512];
    char profile_name[512];
    char legacy_password[512];
    int has_legacy_password;
    cr_account_mode mode;
    char group_id[64];
    cr_personal_mode personal;
    uint64_t permission_bits;
    uint32_t color_rgb;
    int has_color;
    uint8_t *picture;
    size_t picture_len;
    char email[512];
    char about[1024];
    char created_at[64];
    char modified_at[64];
    char last_login_at[64];
    int accepts_offline_messages;
    int local_login_only;
    char last_nickname[1024];
} cr_account;

typedef struct cr_newsgroup {
    char id[64];
    char name[512];
    uint32_t article_count;
    uint32_t expire_after_seconds;
    int admin_read, admin_post, account_read, account_post, guest_read, guest_post;
} cr_newsgroup;


typedef struct cr_search_index_exclusions {
    size_t count;
    char patterns[CR_MAX_SEARCH_INDEX_EXCLUSIONS][CR_MAX_SEARCH_INDEX_PATTERN];
} cr_search_index_exclusions;

typedef struct cr_ip_restriction {
    uint8_t network[4];
    uint8_t mask[4];
    int deny;
    uint8_t reserved;
} cr_ip_restriction;

typedef struct cr_identity {
    char name[512];
    char operator_name[512];
    char location[512];
    char description[CR_MAX_IDENTITY_TEXT + 1];
    char banner_url[4096];
    uint8_t *banner_data;
    size_t banner_len;
} cr_identity;

typedef struct cr_advanced {
    uint16_t control_port;
    uint16_t max_connections;
    uint16_t max_connections_per_ip;
    uint16_t max_simultaneous_file_transfers;
    uint16_t max_file_transfers_per_user;
    uint16_t max_folder_download_depth;
    uint8_t news_expiration_hour;
    uint8_t news_expiration_minute;
    uint32_t tracker_advertisement_flags;
    char tracker_description[512];
} cr_advanced;

typedef struct cr_startup_persistent_settings {
    char server_name[256];
    char description[CR_MAX_IDENTITY_TEXT + 1];
    int server_name_configured;
    int description_configured;
    int legacy_compatible;
    uint16_t control_port;
    uint16_t max_connections;
    uint16_t max_connections_per_ip;
    uint16_t max_simultaneous_file_transfers;
    uint16_t max_file_transfers_per_user;
    uint16_t max_folder_download_depth;
    uint8_t news_expiration_hour;
    uint8_t news_expiration_minute;
    char files_root[PATH_MAX];
    char legacy_files_root[PATH_MAX];
    uint64_t upload_bandwidth_limit_bytes_per_second;
    cr_search_index_exclusions search_index_exclusions;
    uint32_t search_index_rebuild_interval_hours;
} cr_startup_persistent_settings;

typedef struct cr_offline_message_blob cr_offline_message_blob;

typedef struct cr_server_state {
    pthread_mutex_t mutex;
    char path[PATH_MAX];
    char legacy_json_path[PATH_MAX];
    char database_dir[PATH_MAX];
    char base_dir[PATH_MAX];
    sqlite3 *db;
    char storage_root[PATH_MAX];
    char legacy_storage_root[PATH_MAX];
    char personal_home_root[PATH_MAX];
    char metadata_path[PATH_MAX];
    char legacy_metadata_path[PATH_MAX];
    char news_db_path[PATH_MAX];
    char flat_news_path[PATH_MAX];
    char news_root[PATH_MAX];
    json_object *root;
    int legacy_compatible;
    cr_identity identity;
    cr_advanced advanced;
    int agreement_enabled;
    char *agreement_text;
    cr_account_group account_groups[CR_MAX_ACCOUNT_GROUPS];
    size_t account_group_count;
    cr_account accounts[CR_MAX_ACCOUNTS];
    size_t account_count;
    cr_newsgroup newsgroups[CR_MAX_NEWSGROUPS];
    size_t newsgroup_count;
    cr_ip_restriction ip_restrictions[CR_MAX_IP_RESTRICTIONS];
    size_t ip_restriction_count;
} cr_server_state;

int cr_state_open(cr_server_state *state, const char *path);
int cr_state_open_at_root(cr_server_state *state, const char *path, const char *support_root);
void cr_state_close(cr_server_state *state);
int cr_state_reload(cr_server_state *state);
int cr_state_save(cr_server_state *state);
int cr_state_save_locked(cr_server_state *state);
int cr_state_apply_authentication_mode_locked(cr_server_state *state, int legacy_compatible);
int cr_state_reconcile_startup_settings(cr_server_state *state, const cr_startup_persistent_settings *settings, unsigned *changed_count);
int cr_state_find_account(cr_server_state *state, const char *login);
int cr_account_has_permission(const cr_account *account, unsigned bit);
void cr_account_permission_bytes(const cr_account *account, uint8_t out[8]);
int cr_state_stat_add(cr_server_state *state, const char *name, int64_t delta);
int cr_state_record_account_transfer(cr_server_state *state, const char *account_id, const char *login, int is_download, uint64_t bytes);
int cr_state_offline_message_put(cr_server_state *state, const char *recipient_account_id,
                                 const uint8_t *plaintext, size_t plaintext_len,
                                 uint64_t created_at, char out_id[37]);
int cr_state_offline_message_count(cr_server_state *state, const char *recipient_account_id, size_t *out_count);
int cr_state_offline_message_load(cr_server_state *state, const char *recipient_account_id,
                                  cr_offline_message_blob **out_messages, size_t *out_count);
void cr_state_offline_message_free(cr_offline_message_blob *messages, size_t count);
int cr_state_offline_message_ack(cr_server_state *state, const char *recipient_account_id,
                                 const char *const *ids, size_t count);
int cr_state_record_login(cr_server_state *state, size_t account_index);
int cr_state_record_login_id(cr_server_state *state, const char *account_id, cr_account_mode mode);
int cr_state_record_disconnect(cr_server_state *state, cr_account_mode mode);
int cr_state_set_banner(cr_server_state *state, const uint8_t *data, size_t len, const char *url);
int cr_state_update_profile(cr_server_state *state, const char *account_id,
                            const char *name, int set_name,
                            const char *email, int set_email,
                            const char *about, int set_about,
                            const uint8_t *picture, size_t picture_len, int set_picture);
int cr_state_set_offline_message_preference(cr_server_state *state, const char *account_id,
                                            int enabled, const char *nickname);
int cr_state_prepend_ipv4_ban(cr_server_state *state, const uint8_t address[4]);
int cr_state_ensure_local_bot_account(cr_server_state *state);
int cr_state_account_upsert(cr_server_state *state, const char *old_login, const char *login,
                            const char *name, const char *password, uint64_t permission_bits,
                            const char *group_id, int has_color, uint32_t color_rgb, int *action_out);
int cr_state_account_set_picture(cr_server_state *state, const char *login, const uint8_t *picture, size_t picture_len);
int cr_state_set_account_groups(cr_server_state *state, const cr_account_group *groups, size_t count);
int cr_state_account_change_password(cr_server_state *state, const char *account_id, const char *password);
int cr_state_account_delete(cr_server_state *state, const char *login);
int cr_state_newsgroup_create(cr_server_state *state, const char *name, uint32_t expire_after_seconds, uint16_t flags);
int cr_state_newsgroup_modify(cr_server_state *state, const char *old_name, const char *new_name,
                              uint32_t expire_after_seconds, uint16_t flags);
int cr_state_newsgroup_delete(cr_server_state *state, const char *name);
int cr_state_set_newsgroup_article_count(cr_server_state *state, const char *group_id, uint32_t count);
int cr_state_ipv4_allowed(cr_server_state *state, const uint8_t address[4]);
int cr_state_refresh_parsed_locked(cr_server_state *state);

int cr_utf8_to_macroman(const char *utf8, uint8_t *out, size_t out_cap, size_t *out_len);
int cr_utf8_to_macroman_filtered(const char *utf8, uint8_t *out, size_t out_cap, size_t *out_len);
int cr_macroman_to_utf8(const uint8_t *mac, size_t mac_len, char *out, size_t out_cap);
uint32_t cr_iso8601_to_mac_timestamp(const char *text);
void cr_now_iso8601(char out[64]);

#endif
