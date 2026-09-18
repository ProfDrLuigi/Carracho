#define _GNU_SOURCE
#define _XOPEN_SOURCE 700
#define _POSIX_C_SOURCE 200809L
#include "server_runtime.h"
#include "sqlite_state.h"
#include "carracho_protocol.h"
#include "file_metadata.h"
#include "file_search_index.h"
#include "news_store.h"
#include "flat_news_store.h"
#include "media_store.h"
#include "bot_rss.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <ctype.h>
#include <stddef.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <openssl/rand.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <poll.h>
#include <pwd.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/time.h>
#if defined(__linux__)
#include <sys/syscall.h>
#endif
#include <time.h>
#include <unistd.h>

#define CMD_ERROR 0x00000000u
#define SETTING_SEARCH_INDEX_EXCLUSIONS 0xf0000003u
#define SETTING_ACCOUNT_GROUPS 0xf0000004u
#define SETTING_LEGACY_FILES_ROOT 0xf0000005u
#define SETTING_AUTHENTICATION_MODE 0xf0000006u
#define SETTING_SEARCH_INDEX_REBUILD_INTERVAL 0xf0000007u
#define USER_FIELD_GROUP_COLOR 0xf0000003u
#define USER_FIELD_LEGACY_TRANSPORT 0xf0000004u
#define CLIENT_FIELD_OPERATING_SYSTEM 0xf1000000u
#define CLIENT_FIELD_CPU_ARCHITECTURE 0xf1000001u
#define CLIENT_FIELD_VERSION 0xf1000002u
#define CLIENT_FIELD_BUILD 0xf1000003u
#define CLIENT_METADATA_MAX_BYTES 128u
#define CLASSIC_AVATAR_MAX_BYTES 0x27cu
#define LOGIN_FIELD_LEGACY_USER_IDS 0xf0000202u
#define ACCOUNT_FIELD_GROUP_ID 0xf0000010u
#define ACCOUNT_FIELD_COLOR_RGB 0xf0000011u
#define ACCOUNT_FIELD_PICTURE 0xf0000012u
#define ACCOUNT_FIELD_LOCAL_LOGIN_ONLY 0xf0000013u
#define ACCOUNT_FIELD_TRANSFER_STATISTICS 0xf0000014u
#define CMD_CHALLENGE 0x00000001u
#define CMD_LOGIN 0x00000002u
#define CMD_LOGIN_SUCCESS 0x00000003u
#define CMD_DISCONNECT_USER 0x00000004u
#define CMD_BAN_USER 0x00000005u
#define CMD_PRIVATE_MESSAGE 0x00000006u
#define CMD_USER_ARRIVED 0x00000007u
#define CMD_USER_DISCONNECTED 0x00000008u
#define CMD_DIRECTORY 0x00000009u
#define CMD_CHANNEL_DECLINE 0x0000000cu
#define CMD_CHANNEL_USER_MODE 0x0000000fu
#define CMD_EXTENDED_OWN_USER_INFO 0x00000016u
#define CMD_USER_INFO 0x00000017u
#define CMD_USER_UPDATE 0x00000018u
#define CMD_CREATE_FOLDER 0x00000010u
#define CMD_DELETE_FILE 0x00000011u
#define CMD_FILE_INFO 0x00000012u
#define CMD_SET_FILE_INFO 0x00000013u
#define CMD_MOVE_FILE 0x00000014u
#define CMD_EMPTY_TRASH 0x00000015u
#define CMD_REBUILD_SEARCH_INDEX 0x00000040u
#define CMD_CHANNEL_JOIN 0x00000080u
#define CMD_CHANNEL_LEAVE 0x00000081u
#define CMD_CHANNEL_CHAT 0x00000082u
#define CMD_CHANNEL_INVITE 0x00000089u
#define CMD_CHANNEL_SETTINGS 0x00000084u
#define CMD_CHANNEL_LIST 0x00000086u
#define CMD_CHANNEL_USER_JOINED 0x00000087u
#define CMD_CHANNEL_USER_LEFT 0x00000088u
#define CMD_NEWSGROUP_LIST 0x000000a0u
#define CMD_NEWSGROUP_LIST_REPLY 0x000000a1u
#define CMD_ARTICLE_READ 0x000000a2u
#define CMD_ARTICLE_DELETE 0x000000a9u
#define CMD_NEWSGROUP_CREATE 0x000000a5u
#define CMD_NEWSGROUP_DELETE 0x000000a6u
#define CMD_NEWSGROUP_MODIFY 0x000000a7u
#define CMD_ADMIN_NEWSGROUP_LIST 0x000000a8u
#define CMD_ADMIN_NEWSGROUP_LIST_REPLY 0x000000a4u
#define CMD_NEWSGROUP_UPDATE 0x000000aau
#define CMD_SERVER_SETTINGS_REPLY 0x000000c0u
#define CMD_REQUEST_SERVER_SETTINGS 0x000000c1u
#define CMD_SET_SERVER_SETTINGS 0x000000c2u
#define CMD_SERVER_INFO 0x000000c3u
#define CMD_ACCOUNT_REPLY 0x000000cau
#define CMD_ACCOUNT_SAVE 0x000000cbu
#define CMD_GET_ACCOUNT 0x000000ccu
#define CMD_ACCOUNT_LIST 0x000000cdu
#define CMD_ACCOUNT_UPDATE 0x000000ceu
#define CMD_ACCOUNT_DELETE 0x000000cfu
#define CMD_BROADCAST 0x000000d0u
#define CMD_BANNER_CHANGED 0x000000d1u
#define CMD_TRANSFER_INFO 0x000000e0u
#define CMD_FLAT_NEWS_POST 0x00fd0000u
#define CMD_FLAT_NEWS_LIST 0x00fd0001u
#define CMD_FLAT_NEWS_DELETE 0x00fd0002u
#define CMD_FLAT_NEWS_CLEAR 0x00fd0003u
#define CMD_TASK_COMPLETE 0x000000ffu
#define CMD_PRESENCE 0xf0000000u
#define CMD_FORCE_DISCONNECT 0xf00000a0u
#define CMD_OFFLINE_MESSAGE_SEND 0xf0000100u
#define CMD_OFFLINE_MESSAGE_NOTICE 0xf0000101u
#define CMD_OFFLINE_MESSAGE_FETCH 0xf0000102u
#define CMD_OFFLINE_MESSAGE_ACK 0xf0000103u
#define CMD_OFFLINE_MESSAGE_RECIPIENTS 0xf0000104u
#define CMD_OFFLINE_MESSAGE_PREFERENCE 0xf0000105u
#define CMD_FORUM_THREAD_LIST 0xf0000200u
#define CMD_FORUM_THREAD_ENTRIES 0xf0000201u
#define CMD_FORUM_ARTICLE_REACTIONS 0xf0000202u
#define CMD_FORUM_ARTICLE_REACTION_SET 0xf0000203u
#define CMD_FORUM_ARTICLE_REACTION_CHANGED 0xf0000205u
#define CMD_FORUM_ARTICLE_DELETE 0xf0000204u
#define CMD_CHANGE_OWN_PASSWORD 0xf0000300u
#define CMD_SERVER_LOG_REQUEST 0xf0000400u
#define CMD_SERVER_LOG_REPLY 0xf0000401u
#define CMD_SERVER_LOG_CLEAR 0xf0000402u
#define CMD_EVENT_LOG_REQUEST 0xf0000410u
#define CMD_EVENT_LOG_REPLY 0xf0000411u
#define CMD_EVENT_LOG_CLEAR 0xf0000412u
#define CMD_MEDIA_DELETED 0xf0000500u
#define CMD_FILE_LABEL_SET 0xf0000600u
#define CMD_BOT_STATUS_REQUEST 0xf0000700u
#define CMD_BOT_STATUS_REPLY 0xf0000701u
#define CMD_BOT_SET_ENABLED 0xf0000702u
#define CMD_BOT_SET_GREETING 0xf0000703u
#define CMD_BOT_SET_COMMAND_RULES 0xf0000704u
#define CMD_BOT_SET_RSS_FEEDS 0xf0000705u
#define CMD_BOT_TEST_RSS_FEED 0xf0000706u
#define CMD_BOT_RSS_FEED_TEST_REPLY 0xf0000707u
#define FILE_LABEL_FIELD 0xf0000600u
#define DIRECTORY_LABELS_FIELD 0xf0000601u
#define LOGIN_FIELD_MEDIA_CAPABILITIES 0xf0000200u
#define LOGIN_FIELD_FILES_ROOT_NAME 0xf0000201u
#define SERVER_INFO_FIELD_SOFTWARE_VERSION 0xf0000100u
#define SERVER_INFO_FIELD_UPTIME_TICKS 0xf0000101u
#define SERVER_INFO_FIELD_MAX_TRANSFERS 0xf0000102u
#define SERVER_INFO_FIELD_ACTIVE_TRANSFERS 0xf0000103u
#define SERVER_INFO_FIELD_MAX_USER_TRANSFERS 0xf0000104u
#define SERVER_INFO_FIELD_ACTIVE_USER_TRANSFERS 0xf0000105u
#define MEDIA_CAP_ATTACHMENTS_V1 0x00000001u
#define MEDIA_CAP_YOUTUBE_LINKS_V1 0x00000002u
#define MEDIA_CAP_OWNER_DELETE_V1 0x00000004u
#define MEDIA_CAP_CURRENT (MEDIA_CAP_ATTACHMENTS_V1 | MEDIA_CAP_YOUTUBE_LINKS_V1 | MEDIA_CAP_OWNER_DELETE_V1)

#define CHANNEL_FIELD_ID 0u
#define CHANNEL_FIELD_NAME 1u
#define CHANNEL_FIELD_MESSAGE 2u
#define CHANNEL_FIELD_ATTRIBUTE 3u
#define CHANNEL_FIELD_TOPIC 4u
#define CHANNEL_FIELD_MEMBERS 5u
#define CHANNEL_FIELD_SETTINGS 6u
#define CHANNEL_FIELD_USER_ID 7u
#define CHANNEL_FIELD_USER_MODE 8u
#define CHANNEL_FIELD_PASSWORD 9u
#define CHANNEL_LIST_PASSWORD_PROTECTED 0x0001u

#define PERM_DOWNLOAD 0x0a
#define PERM_UPLOAD 0x0b
#define PERM_UPLOAD_ANYWHERE 0x0c
#define PERM_VIEW_DROPBOXES 0x0d
#define PERM_CHANGE_FOLDER_MODE 0x0e
#define PERM_MOVE_FILES 0x0f
#define PERM_DELETE_FILES 0x10
#define PERM_RENAME_FILES 0x11
#define PERM_COMMENT_FILES 0x12
#define PERM_CREATE_FOLDERS 0x13
#define PERM_MOVE_FOLDERS 0x14
#define PERM_RENAME_FOLDERS 0x15
#define PERM_DELETE_FOLDERS 0x16
#define PERM_COMMENT_FOLDERS 0x17
#define PERM_DISCONNECT_USERS 0x18
#define PERM_EXTENDED_USER_INFO 0x19
#define PERM_JOIN_CHAT 0x1c
#define PERM_MANAGE_ACCOUNTS 0x21
#define PERM_MANAGE_NEWSGROUPS 0x22
#define PERM_VIEW_SERVER_LOG 0x23
#define PERM_EDIT_SERVER_INFO 0x24
#define PERM_EDIT_ADVANCED 0x25
#define PERM_MANAGE_TRANSFERS 0x26
#define PERM_EMPTY_TRASH 0x27
#define PERM_BROADCAST 0x28
#define PERM_BAN_USERS 0x2a
#define PERM_EDIT_AGREEMENT 0x2c
#define PERM_VIEW_STATISTICS 0x2d
#define PERM_EDIT_TRACKERS 0x2e
#define PERM_SEARCH_FILES 0x2f
#define PERM_POST_FLAT_NEWS 0x30
#define PERM_POST_NEWS 0x31 /* Carracho extension; original Classic has no equivalent bit. */

#define TRANSFER_ARTICLE_RECEIVER 4u
#define TRANSFER_MEDIA_UPLOAD 0xf100u
#define TRANSFER_MEDIA_DOWNLOAD 0xf101u
#define TRANSFER_MEDIA_DELETE 0xf102u
#define TRANSFER_NEWS_INDEX 5u
#define TRANSFER_BANNER_UPLOAD 8u
#define TRANSFER_FILE_SEARCH 9u
#define TRANSFER_ENCRYPTED_DOWNLOAD 10u
#define TRANSFER_ENCRYPTED_UPLOAD 11u
#define TRANSFER_BANNER_DOWNLOAD 15u
#define CR_SERVER_MAX_TRANSFER_CONNECTIONS 4096u
#define CR_SERVER_MAX_ACTIVE_TRANSFERS 2048u
#define CR_BOT_LOOPBACK_PEER "127.0.0.1"
#define CR_BOT_GREETING_MAX_BYTES 512u
#define CR_BOT_DEFAULT_GREETING "Welcome, {name}! Nice to have you here."
#define CR_BOT_MAX_COMMAND_RULES 64u
#define CR_BOT_COMMAND_MAX_BYTES 128u
#define CR_BOT_RESPONSE_MAX_BYTES 512u

#define CHANNEL_OPERATOR 0x80u
#define CHANNEL_SPEECH 0x40u
#define CHANNEL_RESTRICTED_CHAT 0x1000u
#define CHANNEL_PERMANENT 0x8000u

#define DIR_FLAG_FOLDER 0x8000u
#define FILETYPE_FOLDER 0x464c4452u
#define FILETYPE_SYMLINK 0x53594d4cu
#define CREATOR_FOLDER 0x43617253u
#define MAC_EPOCH_OFFSET 2082844800ULL

static const uint8_t k_client_hello[13]={'T','C','P','C','A','R','R','A','C','H','O',0,1};
static const uint8_t k_server_hello[13]={'T','C','P','C','A','R','R','A','C','H','O',0,2};
static const uint8_t k_server_hello_modern[13]={'T','C','P','C','A','R','R','A','C','H','O',0,3};
static const uint8_t k_initial_key[4]={'Y','O','Y','O'};

typedef struct cr_session {
    cr_server *server;
    int fd;
    char peer_ip[INET_ADDRSTRLEN];
    pthread_mutex_t send_mutex;
    int closed;
    int local_only; /* synthetic in-process user; never writes to a control socket */
    int authenticated;
    int announced; /* safe recipient for post-login asynchronous control packets */
    int bot_greeting_sent;
    uint32_t user_id;
    cr_account_mode mode;
    cr_personal_mode personal;
    uint64_t permission_bits;
    char account_id[64];
    char group_id[64];
    char files_root_path[1025];
    char files_root_name[257];
    uint32_t group_color_rgb;
    int has_group_color;
    char login[256];
    char profile_name[512];
    char email[512];
    char about[1024];
    uint8_t nickname[256];
    size_t nickname_len;
    uint8_t status_message[255];
    size_t status_message_len;
    uint8_t *picture;
    size_t picture_len;
    uint8_t key[72];
    size_t key_len;
    int modern_transport;
    uint8_t modern_salt[CR_MODERN_SESSION_SALT];
    uint8_t modern_server_public_key[32];
    uint8_t modern_handshake_authenticator[32];
    uint8_t control_send_key[32];
    uint8_t control_receive_key[32];
    uint64_t control_send_sequence;
    uint64_t control_receive_sequence;
    time_t login_at;
    time_t last_activity;
    char client_operating_system[CLIENT_METADATA_MAX_BYTES+1];
    char client_cpu_architecture[CLIENT_METADATA_MAX_BYTES+1];
    char client_version[CLIENT_METADATA_MAX_BYTES+1];
    char client_build[CLIENT_METADATA_MAX_BYTES+1];
    int sleeping;
    pthread_t thread;
    int thread_started;
    int finished;
} cr_session;

typedef struct cr_channel_member { uint32_t user_id; uint8_t mode; } cr_channel_member;
typedef struct cr_channel {
    int used;
    uint32_t id;
    uint8_t name[64]; size_t name_len;
    uint8_t password[32]; size_t password_len;
    uint8_t topic[256]; size_t topic_len;
    uint16_t flags;
    cr_channel_member members[CR_CHANNEL_MAX_MEMBERS];
    size_t member_count;
} cr_channel;

typedef struct cr_active_transfer {
    int used;
    uint32_t transfer_id;
    uint8_t kind;
    uint32_t user_id;
    char account_id[64];
    char login[256];
    uint8_t nickname[256];
    size_t nickname_len;
    char peer_ip[INET_ADDRSTRLEN];
    uint8_t path[4096];
    size_t path_len;
    uint64_t bytes_transferred;
    uint64_t wire_bytes_transferred;
    uint64_t total_bytes;
    int transfer_fd;
    int paused;
    int aborting;
    int is_directory;
    double next_download_send_at;
    uint64_t download_pacing_generation;
} cr_active_transfer;

struct cr_server {
    cr_server_state state;
    cr_file_metadata_store metadata;
    cr_file_metadata_store legacy_metadata;
    cr_file_search_index file_index;
    _Atomic int file_index_ready;
    int file_index_dirty; /* guarded by server mutex while a rebuild is in progress */
    pthread_t file_index_thread;
    int file_index_thread_started;
    int file_index_thread_running; /* guarded by server mutex */
    cr_news_store news;
    cr_flat_news_store flat_news;
    cr_media_store media;
    char trash_root[PATH_MAX];
    char config_path[PATH_MAX];
    cr_search_index_exclusions search_index_exclusions;
    uint32_t search_index_rebuild_interval_hours;
    time_t last_file_index_schedule_check;
    pthread_mutex_t mutex;
    int listener_fd;
    int transfer_listener_fd;
    uint16_t port;
    uint16_t transfer_port;
    time_t started_at;
    time_t last_news_expiration_minute;
    time_t last_tracker_registration;
    volatile sig_atomic_t stop;
    uint32_t next_user_id;
    uint32_t next_channel_id;
    cr_session *sessions[CR_SERVER_MAX_SESSIONS];
    size_t allocated_session_count;
    cr_channel channels[CR_SERVER_MAX_CHANNELS];
    cr_session *bot_session;
    pthread_t bot_thread;
    int bot_thread_started;
    pthread_t bot_rss_thread;
    int bot_rss_thread_started;
    int bot_fd;
    char bot_config_path[PATH_MAX];
    char bot_status_path[PATH_MAX];
    char bot_pipe_path[PATH_MAX];
    char bot_avatar_path[PATH_MAX];
    char bot_rss_db_path[PATH_MAX];
    char bot_last_error[512];
    pthread_t transfer_thread;
    pthread_cond_t transfer_cond;
    int transfer_fds[CR_SERVER_MAX_TRANSFER_CONNECTIONS];
    size_t active_transfer_connections;
    cr_active_transfer active_transfers[CR_SERVER_MAX_ACTIVE_TRANSFERS];
    uint32_t next_transfer_id;
    size_t active_file_transfers;
    uint64_t download_bandwidth_limit_bps;
    uint64_t download_bandwidth_generation;
    double download_traffic_window_started;
    double download_traffic_last_activity;
    uint64_t download_traffic_window_bytes;
    uint64_t download_traffic_bps;
};

static void repair_file_search_index(cr_server *s);
static void invalidate_file_search_index(cr_server *s,const char *reason);
static int file_search_index_incremental_available(cr_server *s);
static void refresh_connected_account_state(cr_server *server);
static void free_joined_session(cr_session *x);
static int validate_youtube_tokens(const uint8_t *data, size_t len, size_t maximum);
static void disconnect_local_bot(cr_server *s);
static void *bot_thread_main(void *opaque);
static void *bot_rss_thread_main(void *opaque);
static void broadcast_presence_state_locked(cr_server *server, uint32_t user_id, uint8_t state);

typedef struct accepted_ctx { cr_server *server; int fd; char peer[INET_ADDRSTRLEN]; } accepted_ctx;
typedef struct cr_transfer_access {
    uint32_t user_id;
    char account_id[64];
    uint64_t permission_bits;
    cr_account_mode mode;
    cr_personal_mode personal;
    char files_root_path[1025];
    char files_root_name[257];
    char login[256];
    uint8_t nickname[256];
    size_t nickname_len;
    char peer_ip[INET_ADDRSTRLEN];
    uint8_t key[72];
    size_t key_len;
    int modern_transport;
    uint8_t modern_salt[CR_MODERN_SESSION_SALT];
} cr_transfer_access;

typedef struct dir_item {
    char name[NAME_MAX+1];
    uint8_t wire_name[512];
    size_t wire_name_len;
    uint32_t size, timestamp, file_type, creator;
    uint16_t flags;
    uint8_t label;
} dir_item;

static pthread_mutex_t g_log_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_event_mutex = PTHREAD_MUTEX_INITIALIZER;
static char g_log_path[PATH_MAX];
static char g_event_path[PATH_MAX];

static int configure_log_path(const char *instance_root) {
    char directory[PATH_MAX];
    int n = snprintf(directory, sizeof(directory), "%s/logs", instance_root);
    if (n < 0 || (size_t)n >= sizeof(directory)) return -1;
    if (mkdir(directory, 0755) && errno != EEXIST) return -1;
    n = snprintf(g_log_path, sizeof(g_log_path), "%s/carracho-server.log", directory);
    if (n < 0 || (size_t)n >= sizeof(g_log_path)) { g_log_path[0] = '\0'; return -1; }
    FILE *probe = fopen(g_log_path, "a");
    if (!probe) { g_log_path[0] = '\0'; return -1; }
    fclose(probe);
    n = snprintf(g_event_path, sizeof(g_event_path), "%s/carracho-events.log", directory);
    if (n < 0 || (size_t)n >= sizeof(g_event_path)) { g_event_path[0] = '\0'; return -1; }
    probe = fopen(g_event_path, "a");
    if (!probe) { g_event_path[0] = '\0'; return -1; }
    fclose(probe);
    return 0;
}

static void log_msg(const char *fmt, ...) {
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char stamp[32], message[65536];
    strftime(stamp, sizeof(stamp), "%Y-%m-%dT%H:%M:%S%z", &tmv);
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(message, sizeof(message), fmt, ap);
    va_end(ap);
    for (char *p = message; *p; ++p) {
        if (*p == '\r' || *p == '\n') *p = ' ';
    }
    pthread_mutex_lock(&g_log_mutex);
    fprintf(stdout, "%s %s\n", stamp, message);
    fflush(stdout);
    if (g_log_path[0]) {
        FILE *file = fopen(g_log_path, "a");
        if (file) {
            fprintf(file, "%s %s\n", stamp, message);
            fflush(file);
            fclose(file);
        }
    }
    pthread_mutex_unlock(&g_log_mutex);
}

static int read_log_chunk(uint64_t requested_offset, size_t maximum_bytes,
                          uint64_t *total_bytes, uint64_t *actual_offset, cr_buffer *chunk) {
    if (!total_bytes || !actual_offset || !chunk || !maximum_bytes || maximum_bytes > 60u * 1024u) return -1;
    cr_buffer_init(chunk);
    pthread_mutex_lock(&g_log_mutex);
    int rc = -1;
    FILE *file = NULL;
    if (!g_log_path[0]) goto done;
    file = fopen(g_log_path, "rb");
    if (!file) {
        if (errno == ENOENT) { *total_bytes = 0; *actual_offset = 0; rc = 0; }
        goto done;
    }
    if (fseeko(file, 0, SEEK_END)) goto done;
    off_t end = ftello(file);
    if (end < 0) goto done;
    uint64_t total = (uint64_t)end;
    uint64_t start = requested_offset > total ? total : requested_offset;
    if (start > (uint64_t)INT64_MAX || fseeko(file, (off_t)start, SEEK_SET)) goto done;
    uint64_t available = total - start;
    size_t wanted = available < (uint64_t)maximum_bytes ? (size_t)available : maximum_bytes;
    uint8_t buffer[8192];
    size_t left = wanted;
    while (left) {
        size_t want = left < sizeof(buffer) ? left : sizeof(buffer);
        size_t n = fread(buffer, 1, want, file);
        if (!n) {
            if (ferror(file)) goto done;
            break;
        }
        if (cr_buffer_append(chunk, buffer, n)) goto done;
        left -= n;
    }
    *total_bytes = total;
    *actual_offset = start;
    rc = 0;
done:
    if (file) fclose(file);
    pthread_mutex_unlock(&g_log_mutex);
    if (rc) cr_buffer_free(chunk);
    return rc;
}

static int clear_log_file(void) {
    pthread_mutex_lock(&g_log_mutex);
    int rc = -1;
    if (g_log_path[0]) {
        FILE *file = fopen(g_log_path, "w");
        if (file) { rc = fclose(file) == 0 ? 0 : -1; }
    }
    pthread_mutex_unlock(&g_log_mutex);
    return rc;
}

static int read_event_chunk(uint64_t requested_offset, size_t maximum_bytes,
                            uint64_t *total_bytes, uint64_t *actual_offset, cr_buffer *chunk) {
    if (!total_bytes || !actual_offset || !chunk || !maximum_bytes || maximum_bytes > 60u * 1024u) return -1;
    cr_buffer_init(chunk);
    pthread_mutex_lock(&g_event_mutex);
    int rc=-1;FILE*file=NULL;
    if(!g_event_path[0])goto done;
    file=fopen(g_event_path,"rb");
    if(!file){if(errno==ENOENT){*total_bytes=0;*actual_offset=0;rc=0;}goto done;}
    if(fseeko(file,0,SEEK_END))goto done;
    off_t end=ftello(file);
    if(end<0)goto done;
    uint64_t total=(uint64_t)end,start=requested_offset>total?total:requested_offset;
    if(start>(uint64_t)INT64_MAX||fseeko(file,(off_t)start,SEEK_SET))goto done;
    uint64_t available=total-start;size_t wanted=available<(uint64_t)maximum_bytes?(size_t)available:maximum_bytes;
    uint8_t buffer[8192];size_t left=wanted;while(left){size_t want=left<sizeof(buffer)?left:sizeof(buffer);size_t n=fread(buffer,1,want,file);if(!n){if(ferror(file))goto done;break;}if(cr_buffer_append(chunk,buffer,n))goto done;left-=n;}
    *total_bytes=total;*actual_offset=start;rc=0;
done:if(file)fclose(file);pthread_mutex_unlock(&g_event_mutex);if(rc)cr_buffer_free(chunk);return rc;
}

static int clear_event_file(void){pthread_mutex_lock(&g_event_mutex);int rc=-1;if(g_event_path[0]){FILE*f=fopen(g_event_path,"w");if(f)rc=fclose(f)==0?0:-1;}pthread_mutex_unlock(&g_event_mutex);return rc;}

static void quote_log_value(char *out, size_t cap, const char *value) {
    if (!cap) return;
    size_t pos = 0;
    out[pos++] = '"';
    for (const unsigned char *p = (const unsigned char *)(value ? value : ""); *p && pos + 2 < cap; ++p) {
        const char *escape = NULL;
        switch (*p) {
        case '\\': escape = "\\\\"; break;
        case '"': escape = "\\\""; break;
        case '\r': escape = "\\r"; break;
        case '\n': escape = "\\n"; break;
        case '\t': escape = "\\t"; break;
        default: break;
        }
        if (escape) {
            size_t n = strlen(escape);
            if (pos + n + 1 >= cap) break;
            memcpy(out + pos, escape, n); pos += n;
        } else {
            out[pos++] = (char)*p;
        }
    }
    if (pos + 1 < cap) out[pos++] = '"';
    out[pos < cap ? pos : cap - 1] = '\0';
}

static void event_write_values(uint32_t user_id,const char*login,const char*nickname,const char*peer,
                               const char*category,const char*action,const char*detail){
    time_t now=time(NULL);struct tm tmv;localtime_r(&now,&tmv);char stamp[32];strftime(stamp,sizeof(stamp),"%Y-%m-%dT%H:%M:%S%z",&tmv);
    char qlogin[768],qnick[2048],qpeer[128],qcat[256],qaction[256],qdetail[32768];
    quote_log_value(qlogin,sizeof(qlogin),login);quote_log_value(qnick,sizeof(qnick),nickname);quote_log_value(qpeer,sizeof(qpeer),peer);
    quote_log_value(qcat,sizeof(qcat),category);quote_log_value(qaction,sizeof(qaction),action);quote_log_value(qdetail,sizeof(qdetail),detail);
    pthread_mutex_lock(&g_event_mutex);if(g_event_path[0]){FILE*f=fopen(g_event_path,"a");if(f){fprintf(f,"%s category=%s action=%s user_id=%u login=%s nickname=%s peer_ip=%s detail=%s\n",stamp,qcat,qaction,user_id,qlogin,qnick,qpeer,qdetail);fflush(f);fclose(f);}}pthread_mutex_unlock(&g_event_mutex);
}

static void event_msg(cr_session*s,const char*category,const char*action,const char*detail){
    char nickname[1024]="";if(s->nickname_len&&cr_macroman_to_utf8(s->nickname,s->nickname_len,nickname,sizeof(nickname)))snprintf(nickname,sizeof(nickname),"<invalid-macroman>");
    event_write_values(s->user_id,s->login,nickname,s->peer_ip,category,action,detail?detail:"");
}

static double monotonic_seconds(void){struct timespec ts;if(clock_gettime(CLOCK_MONOTONIC,&ts))return 0.0;return(double)ts.tv_sec+(double)ts.tv_nsec/1000000000.0;}
static void sleep_seconds(double seconds){if(seconds<=0.0)return;struct timespec req;req.tv_sec=(time_t)seconds;req.tv_nsec=(long)((seconds-(double)req.tv_sec)*1000000000.0);while(nanosleep(&req,&req)&&errno==EINTR){}}
static int account_perm(const cr_session*s,unsigned bit){return bit<64&&((s->permission_bits>>bit)&1ULL);}
static cr_active_transfer *active_transfer_by_id_locked(cr_server*s,uint32_t id){for(size_t i=0;i<CR_SERVER_MAX_ACTIVE_TRANSFERS;i++)if(s->active_transfers[i].used&&s->active_transfers[i].transfer_id==id)return&s->active_transfers[i];return NULL;}
static uint32_t begin_file_transfer(cr_server*s,const cr_session*session,uint8_t kind,int transfer_fd){
    int allowed=kind==1?account_perm(session,PERM_DOWNLOAD):account_perm(session,PERM_UPLOAD);if(!allowed)return 0;
    uint16_t max_total=0,max_user=0;pthread_mutex_lock(&s->state.mutex);max_total=s->state.advanced.max_simultaneous_file_transfers;max_user=s->state.advanced.max_file_transfers_per_user;pthread_mutex_unlock(&s->state.mutex);
    pthread_mutex_lock(&s->mutex);size_t user_count=0,slot=CR_SERVER_MAX_ACTIVE_TRANSFERS,download_count=0;for(size_t i=0;i<CR_SERVER_MAX_ACTIVE_TRANSFERS;i++){cr_active_transfer*t=&s->active_transfers[i];if(t->used&&t->user_id==session->user_id)user_count++;if(t->used&&t->kind==1)download_count++;if(!t->used&&slot==CR_SERVER_MAX_ACTIVE_TRANSFERS)slot=i;}if(slot==CR_SERVER_MAX_ACTIVE_TRANSFERS||s->active_file_transfers>=max_total||user_count>=max_user){pthread_mutex_unlock(&s->mutex);return 0;}while(!s->next_transfer_id||active_transfer_by_id_locked(s,s->next_transfer_id))s->next_transfer_id++;uint32_t id=s->next_transfer_id++;if(kind==1&&!download_count){s->download_traffic_window_started=0.0;s->download_traffic_last_activity=0.0;s->download_traffic_window_bytes=0;s->download_traffic_bps=0;}cr_active_transfer*t=&s->active_transfers[slot];memset(t,0,sizeof(*t));t->used=1;t->transfer_id=id;t->kind=kind;t->user_id=session->user_id;snprintf(t->account_id,sizeof(t->account_id),"%s",session->account_id);snprintf(t->login,sizeof(t->login),"%s",session->login);t->nickname_len=session->nickname_len;if(t->nickname_len>sizeof(t->nickname))t->nickname_len=sizeof(t->nickname);if(t->nickname_len)memcpy(t->nickname,session->nickname,t->nickname_len);snprintf(t->peer_ip,sizeof(t->peer_ip),"%s",session->peer_ip);t->transfer_fd=transfer_fd;s->active_file_transfers++;if(kind==1){s->download_bandwidth_generation++;if(!s->download_bandwidth_generation)s->download_bandwidth_generation=1;}pthread_mutex_unlock(&s->mutex);cr_state_stat_add(&s->state,kind==1?"downloadsInProgress":"uploadsInProgress",1);return id;
}
static void configure_transfer(cr_server*s,uint32_t id,const uint8_t*path,size_t path_len,uint64_t total){pthread_mutex_lock(&s->mutex);cr_active_transfer*t=active_transfer_by_id_locked(s,id);if(t){if(path&&path_len<=sizeof(t->path)){memcpy(t->path,path,path_len);t->path_len=path_len;}t->total_bytes=total;}pthread_mutex_unlock(&s->mutex);}
static void configure_transfer_directory(cr_server*s,uint32_t id,int is_directory){pthread_mutex_lock(&s->mutex);cr_active_transfer*t=active_transfer_by_id_locked(s,id);if(t)t->is_directory=is_directory?1:0;pthread_mutex_unlock(&s->mutex);}
static int transfer_wait_until_resumed(cr_server*s,uint32_t id){for(;;){int paused=0,aborting=0,found=0;pthread_mutex_lock(&s->mutex);cr_active_transfer*t=active_transfer_by_id_locked(s,id);if(t){found=1;paused=t->paused;aborting=t->aborting;}pthread_mutex_unlock(&s->mutex);if(!found||aborting)return-1;if(!paused)return 0;sleep_seconds(0.02);}}
static int control_active_transfer(cr_server*s,uint32_t id,uint8_t action){int fd=-1,download=0;pthread_mutex_lock(&s->mutex);cr_active_transfer*t=active_transfer_by_id_locked(s,id);if(!t){pthread_mutex_unlock(&s->mutex);return-1;}download=t->kind==1;if(action==1){if(t->aborting){pthread_mutex_unlock(&s->mutex);return-1;}t->paused=1;}else if(action==2){if(t->aborting){pthread_mutex_unlock(&s->mutex);return-1;}t->paused=0;}else if(action==3){t->aborting=1;t->paused=0;fd=t->transfer_fd;}else{pthread_mutex_unlock(&s->mutex);return-1;}if(download){s->download_bandwidth_generation++;if(!s->download_bandwidth_generation)s->download_bandwidth_generation=1;}pthread_mutex_unlock(&s->mutex);if(action==3&&fd>=0)shutdown(fd,SHUT_RDWR);return 0;}
static void record_download_traffic_locked(cr_server*s,uint64_t bytes,double now){if(s->download_traffic_window_started<=0.0)s->download_traffic_window_started=now;uint64_t next=s->download_traffic_window_bytes+bytes;s->download_traffic_window_bytes=next<s->download_traffic_window_bytes?UINT64_MAX:next;s->download_traffic_last_activity=now;double elapsed=now-s->download_traffic_window_started;if(elapsed>=0.5){double rate=(double)s->download_traffic_window_bytes/elapsed;s->download_traffic_bps=rate>=(double)UINT64_MAX?UINT64_MAX:(uint64_t)rate;s->download_traffic_window_bytes=0;s->download_traffic_window_started=now;}}
static uint64_t current_download_traffic_rate_locked(cr_server*s,double now){size_t downloads=0;for(size_t i=0;i<CR_SERVER_MAX_ACTIVE_TRANSFERS;i++)if(s->active_transfers[i].used&&s->active_transfers[i].kind==1)downloads++;if(!downloads||s->download_traffic_last_activity<=0.0||now-s->download_traffic_last_activity>1.5)return 0;double elapsed=now-s->download_traffic_window_started;if(elapsed>=0.15&&s->download_traffic_window_bytes){double raw=(double)s->download_traffic_window_bytes/elapsed;uint64_t partial=raw>=(double)UINT64_MAX?UINT64_MAX:(uint64_t)raw;if(!s->download_traffic_bps)return partial;return s->download_traffic_bps/2+partial/2;}return s->download_traffic_bps;}
static void set_download_bandwidth_limit(cr_server*s,uint64_t value){pthread_mutex_lock(&s->mutex);s->download_bandwidth_limit_bps=value;s->download_bandwidth_generation++;if(!s->download_bandwidth_generation)s->download_bandwidth_generation=1;pthread_mutex_unlock(&s->mutex);}
static size_t paced_download_chunk_size(cr_server*s,size_t maximum){pthread_mutex_lock(&s->mutex);uint64_t limit=s->download_bandwidth_limit_bps;if(!limit){pthread_mutex_unlock(&s->mutex);return maximum;}size_t count=0;for(size_t i=0;i<CR_SERVER_MAX_ACTIVE_TRANSFERS;i++)if(s->active_transfers[i].used&&s->active_transfers[i].kind==1&&!s->active_transfers[i].paused&&!s->active_transfers[i].aborting)count++;if(!count)count=1;uint64_t per=limit/(uint64_t)count;uint64_t target=per/8;if(target<4096)target=4096;if(target>65536)target=65536;pthread_mutex_unlock(&s->mutex);return target<maximum?(size_t)target:maximum;}
static void throttle_download(cr_server*s,uint32_t id,size_t bytes){if(!bytes)return;for(;;){double target;uint64_t generation;pthread_mutex_lock(&s->mutex);cr_active_transfer*t=active_transfer_by_id_locked(s,id);if(!t||t->kind!=1||!s->download_bandwidth_limit_bps){pthread_mutex_unlock(&s->mutex);return;}double now=monotonic_seconds();generation=s->download_bandwidth_generation;if(t->download_pacing_generation!=generation){t->download_pacing_generation=generation;t->next_download_send_at=now;}size_t count=0;for(size_t i=0;i<CR_SERVER_MAX_ACTIVE_TRANSFERS;i++)if(s->active_transfers[i].used&&s->active_transfers[i].kind==1&&!s->active_transfers[i].paused&&!s->active_transfers[i].aborting)count++;if(!count)count=1;double per=(double)s->download_bandwidth_limit_bps/(double)count;if(per<1.0)per=1.0;double base=t->next_download_send_at>now?t->next_download_send_at:now;target=base+(double)bytes/per;t->next_download_send_at=target;pthread_mutex_unlock(&s->mutex);for(;;){double remaining=target-monotonic_seconds();if(remaining<=0.0)return;sleep_seconds(remaining>0.1?0.1:remaining);pthread_mutex_lock(&s->mutex);int changed=!s->download_bandwidth_limit_bps||s->download_bandwidth_generation!=generation;pthread_mutex_unlock(&s->mutex);if(changed)break;}}}
static void add_transfer_progress(cr_server*s,uint32_t id,uint64_t bytes){if(!bytes)return;pthread_mutex_lock(&s->mutex);cr_active_transfer*t=active_transfer_by_id_locked(s,id);if(t){uint64_t next=t->bytes_transferred+bytes;if(next<t->bytes_transferred)next=UINT64_MAX;t->bytes_transferred=next;next=t->wire_bytes_transferred+bytes;if(next<t->wire_bytes_transferred)next=UINT64_MAX;t->wire_bytes_transferred=next;if(t->kind==1)record_download_traffic_locked(s,bytes,monotonic_seconds());}pthread_mutex_unlock(&s->mutex);}
static void add_transfer_resume_progress(cr_server*s,uint32_t id,uint64_t bytes){if(!bytes)return;pthread_mutex_lock(&s->mutex);cr_active_transfer*t=active_transfer_by_id_locked(s,id);if(t){uint64_t next=t->bytes_transferred+bytes;if(next<t->bytes_transferred)next=UINT64_MAX;t->bytes_transferred=next;}pthread_mutex_unlock(&s->mutex);}
static void end_file_transfer(cr_server*s,uint32_t id,uint8_t kind,int succeeded){
    char account_id[64]="",login[256]="",peer_ip[INET_ADDRSTRLEN]="";
    uint8_t nickname_mac[256]={0},path_mac[4096]={0};size_t nickname_len=0,path_len=0;
    uint32_t user_id=0;uint64_t wire_bytes=0,transferred_bytes=0,total_bytes=0;
    pthread_mutex_lock(&s->mutex);
    cr_active_transfer*t=active_transfer_by_id_locked(s,id);
    if(t){
        user_id=t->user_id;snprintf(account_id,sizeof(account_id),"%s",t->account_id);snprintf(login,sizeof(login),"%s",t->login);snprintf(peer_ip,sizeof(peer_ip),"%s",t->peer_ip);
        nickname_len=t->nickname_len;if(nickname_len>sizeof(nickname_mac))nickname_len=sizeof(nickname_mac);if(nickname_len)memcpy(nickname_mac,t->nickname,nickname_len);
        path_len=t->path_len;if(path_len>sizeof(path_mac))path_len=sizeof(path_mac);if(path_len)memcpy(path_mac,t->path,path_len);
        wire_bytes=t->wire_bytes_transferred;transferred_bytes=t->bytes_transferred;total_bytes=t->total_bytes;
        memset(t,0,sizeof(*t));if(s->active_file_transfers)s->active_file_transfers--;if(kind==1){s->download_bandwidth_generation++;if(!s->download_bandwidth_generation)s->download_bandwidth_generation=1;}
    }
    pthread_mutex_unlock(&s->mutex);
    cr_state_stat_add(&s->state,kind==1?"downloadsInProgress":"uploadsInProgress",-1);
    if(succeeded){cr_state_stat_add(&s->state,kind==1?"totalDownloads":"totalUploads",1);if(account_id[0])cr_state_record_account_transfer(&s->state,account_id,login,kind==1,wire_bytes);}
    if(t){
        char nickname[1024]="",path[16384]="",qlogin[768],qnickname[2048],qpeer[128],qpath[32768];
        if(nickname_len&&cr_macroman_to_utf8(nickname_mac,nickname_len,nickname,sizeof(nickname)))snprintf(nickname,sizeof(nickname),"<invalid-macroman>");
        if(path_len){for(size_t i=0;i<path_len;i++)if(path_mac[i]==1)path_mac[i]='/';if(cr_macroman_to_utf8(path_mac,path_len,path,sizeof(path)))snprintf(path,sizeof(path),"<invalid-macroman>");else{size_t pn=strlen(path);if(pn+2<=sizeof(path)){memmove(path+1,path,pn+1);path[0]='/';}}}
        quote_log_value(qlogin,sizeof(qlogin),login);quote_log_value(qnickname,sizeof(qnickname),nickname);quote_log_value(qpeer,sizeof(qpeer),peer_ip);quote_log_value(qpath,sizeof(qpath),path);
        uint64_t resumed=transferred_bytes>=wire_bytes?transferred_bytes-wire_bytes:0;
        log_msg("event=file_transfer direction=%s status=%s transfer_id=%u user_id=%u login=%s nickname=%s peer_ip=%s path=%s size_bytes=%llu transferred_bytes=%llu wire_bytes=%llu resumed_bytes=%llu",
                kind==1?"download":"upload",succeeded?"completed":"failed",id,user_id,qlogin,qnickname,qpeer,qpath,
                (unsigned long long)total_bytes,(unsigned long long)transferred_bytes,(unsigned long long)wire_bytes,(unsigned long long)resumed);
        char detail[20000];snprintf(detail,sizeof(detail),"status=%s path=%s bytes=%llu",succeeded?"completed":"failed",path[0]?path:"/",(unsigned long long)wire_bytes);
        event_write_values(user_id,login,nickname,peer_ip,"transfers",kind==1?"download":"upload",detail);
    }
}

static int session_send(cr_session*s,uint32_t cmd,uint32_t tx,const cr_tlv_out*f,size_t n){
    if(s->local_only)return 0;
    pthread_mutex_lock(&s->send_mutex);int rc=-1;
    if(!s->closed){
        if(s->modern_transport){
            cr_buffer plain,frame;cr_buffer_init(&plain);cr_buffer_init(&frame);
            if(cr_build_packet(cmd,tx,0,f,n,&plain)==0&&cr_encode_aead(plain.data,plain.len,s->control_send_key,s->control_send_sequence,"carracho/control/v1",&frame)==0&&cr_write_all(s->fd,frame.data,frame.len)==0){s->control_send_sequence++;rc=0;}
            cr_buffer_free(&plain);cr_buffer_free(&frame);
        }else rc=cr_send_packet(s->fd,s->key,s->key_len,cmd,tx,f,n);
    }
    pthread_mutex_unlock(&s->send_mutex);return rc;
}
static int session_send_key(cr_session*s,const uint8_t*key,size_t key_len,uint32_t cmd,uint32_t tx,const cr_tlv_out*f,size_t n){if(s->local_only)return 0;pthread_mutex_lock(&s->send_mutex);int rc=s->closed?-1:cr_send_packet(s->fd,key,key_len,cmd,tx,f,n);pthread_mutex_unlock(&s->send_mutex);return rc;}
static int send_error(cr_session*s,uint32_t tx,uint16_t code){uint8_t v[2];cr_write_be16(v,code);cr_tlv_out f={1,v,2};return session_send(s,CMD_ERROR,tx,&f,1);}
static int send_task_complete(cr_session *s, uint32_t tx) { return tx ? session_send(s, CMD_TASK_COMPLETE, tx, NULL, 0) : 0; }

static void configure_accepted_socket(int fd){
    int yes=1;
    (void)setsockopt(fd,SOL_SOCKET,SO_KEEPALIVE,&yes,sizeof(yes));

    /* Keep quiet but healthy sessions indefinitely. These options only detect transport peers
       that disappeared without a FIN (crash, network loss, sleeping/lost machine). With 60 s
       idle + four 15 s probes, a dead peer is normally reaped in roughly two minutes. */
#if defined(TCP_KEEPIDLE)
    int keepalive_idle=60;
    (void)setsockopt(fd,IPPROTO_TCP,TCP_KEEPIDLE,&keepalive_idle,sizeof(keepalive_idle));
#elif defined(TCP_KEEPALIVE)
    int keepalive_idle=60;
    (void)setsockopt(fd,IPPROTO_TCP,TCP_KEEPALIVE,&keepalive_idle,sizeof(keepalive_idle));
#endif
#if defined(TCP_KEEPINTVL)
    int keepalive_interval=15;
    (void)setsockopt(fd,IPPROTO_TCP,TCP_KEEPINTVL,&keepalive_interval,sizeof(keepalive_interval));
#endif
#if defined(TCP_KEEPCNT)
    int keepalive_count=4;
    (void)setsockopt(fd,IPPROTO_TCP,TCP_KEEPCNT,&keepalive_count,sizeof(keepalive_count));
#endif
#ifdef SO_NOSIGPIPE
    (void)setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
#endif
}

static int make_listener(uint16_t requested,uint16_t*actual){int fd=socket(AF_INET,SOCK_STREAM,0);if(fd<0)return-1;int yes=1;setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));
#ifdef SO_NOSIGPIPE
setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
#endif
struct sockaddr_in a;memset(&a,0,sizeof(a));a.sin_family=AF_INET;a.sin_port=htons(requested);a.sin_addr.s_addr=htonl(INADDR_ANY);if(bind(fd,(struct sockaddr*)&a,sizeof(a))||listen(fd,64)){close(fd);return-1;}socklen_t l=sizeof(a);if(getsockname(fd,(struct sockaddr*)&a,&l)){close(fd);return-1;}*actual=ntohs(a.sin_port);return fd;}
static int make_listener_pair(uint16_t requested,int*control,int*transfer,uint16_t*port,uint16_t*tport){
    if(requested){if(requested==65535)return-1;*control=make_listener(requested,port);if(*control<0)return-1;*transfer=make_listener((uint16_t)(requested+1),tport);if(*transfer<0){close(*control);return-1;}return 0;}
    for(int tries=0;tries<64;tries++){uint16_t p=0;int c=make_listener(0,&p);if(c<0)return-1;if(p==65535){close(c);continue;}uint16_t tp=0;int t=make_listener((uint16_t)(p+1),&tp);if(t>=0){*control=c;*transfer=t;*port=p;*tport=tp;return 0;}close(c);}return-1;
}

static int session_ready_for_async(const cr_session*x){return x&&x->authenticated&&x->announced&&!x->closed;}
static size_t announced_count_locked(cr_server*s){size_t n=0;for(size_t i=0;i<s->allocated_session_count;i++)if(session_ready_for_async(s->sessions[i]))n++;return n;}
static cr_session *find_session_locked(cr_server*s,uint32_t uid){for(size_t i=0;i<s->allocated_session_count;i++){cr_session*x=s->sessions[i];if(session_ready_for_async(x)&&x->user_id==uid)return x;}return NULL;}
static cr_session *find_session_account_locked(cr_server*s,const char*account_id){for(size_t i=0;i<s->allocated_session_count;i++){cr_session*x=s->sessions[i];if(session_ready_for_async(x)&&!strcmp(x->account_id,account_id))return x;}return NULL;}
static cr_channel *channel_by_id_locked(cr_server*s,uint32_t id){for(size_t i=0;i<CR_SERVER_MAX_CHANNELS;i++)if(s->channels[i].used&&s->channels[i].id==id)return&s->channels[i];return NULL;}
static int channel_member_index(cr_channel*c,uint32_t uid){for(size_t i=0;i<c->member_count;i++)if(c->members[i].user_id==uid)return(int)i;return-1;}
static cr_channel *allocate_channel_locked(cr_server*s,const uint8_t*name,size_t name_len,const uint8_t*pw,size_t pw_len){for(size_t i=0;i<CR_SERVER_MAX_CHANNELS;i++)if(!s->channels[i].used){cr_channel*c=&s->channels[i];memset(c,0,sizeof(*c));c->used=1;while(!s->next_channel_id||channel_by_id_locked(s,s->next_channel_id))s->next_channel_id++;c->id=s->next_channel_id++;memcpy(c->name,name,name_len);c->name_len=name_len;memcpy(c->password,pw,pw_len);c->password_len=pw_len;return c;}return NULL;}

static int classic_avatar_png(const uint8_t*source,size_t source_len,uint8_t**out,size_t*out_len){
    static const uint8_t sig[8]={0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a};
    *out=NULL;*out_len=0;
    /*
     * Classic 1.0b10r4 builds 16x16 CIcons directly from the packed user-list PNG.
     * Its live picture path also rejects payloads above 0x27c bytes. Without pulling
     * an image library into the native server, preserve already-Classic-sized PNGs
     * and suppress modern 128x128 avatars. Classic then uses its normal fallback
     * icon instead of interpreting a large PNG as palette garbage.
     */
    if(!source||source_len<24||source_len>CLASSIC_AVATAR_MAX_BYTES||
       memcmp(source,sig,sizeof(sig))||memcmp(source+12,"IHDR",4))return 0;
    uint32_t width=cr_read_be32(source+16),height=cr_read_be32(source+20);
    if(!width||!height||width>16||height>16)return 0;
    uint8_t*copy=malloc(source_len);if(!copy)return-1;
    memcpy(copy,source,source_len);*out=copy;*out_len=source_len;return 0;
}

static int encode_user_list(cr_server*s,cr_session*requester,int include_pictures,cr_buffer*out){
    cr_buffer_init(out);
    pthread_mutex_lock(&s->mutex);
    size_t count=0;
    for(size_t i=0;i<s->allocated_session_count;i++){cr_session*x=s->sessions[i];if(session_ready_for_async(x)||(x==requester&&x->authenticated&&!x->closed))count++;}
    if(cr_buffer_append_u32(out,(uint32_t)count)){pthread_mutex_unlock(&s->mutex);return-1;}
    for(size_t i=0;i<s->allocated_session_count;i++){
        cr_session*x=s->sessions[i];
        if(!(session_ready_for_async(x)||(x==requester&&x->authenticated&&!x->closed)))continue;
        uint8_t*classic_picture=NULL;size_t picture_len=0;
        if(include_pictures&&classic_avatar_png(x->picture,x->picture_len,&classic_picture,&picture_len)){
            pthread_mutex_unlock(&s->mutex);return-1;
        }
        if(picture_len>UINT32_MAX||
           cr_buffer_append_string16(out,x->nickname,x->nickname_len)||
           cr_buffer_append_u16(out,x->sleeping?0x0100:0)||
           cr_buffer_append_u32(out,x->user_id)||
           cr_buffer_append_u32(out,(uint32_t)picture_len)||
           cr_buffer_append(out,classic_picture,picture_len)){
            free(classic_picture);pthread_mutex_unlock(&s->mutex);return-1;
        }
        free(classic_picture);
    }
    pthread_mutex_unlock(&s->mutex);
    return 0;
}
static int encode_legacy_user_ids(cr_server*s,cr_session*requester,cr_buffer*out){
    cr_buffer_init(out);pthread_mutex_lock(&s->mutex);int rc=0;
    for(size_t i=0;i<s->allocated_session_count;i++){
        cr_session*x=s->sessions[i];
        if(!(session_ready_for_async(x)||(x==requester&&x->authenticated&&!x->closed))||x->modern_transport)continue;
        if(cr_buffer_append_u32(out,x->user_id)){rc=-1;break;}
    }
    pthread_mutex_unlock(&s->mutex);return rc;
}
static int encode_channel_members(cr_channel*c,cr_buffer*out){cr_buffer_init(out);if(cr_buffer_append_u32(out,(uint32_t)c->member_count))return-1;for(size_t i=0;i<c->member_count;i++)if(cr_buffer_append_u32(out,c->members[i].user_id)||cr_buffer_append_u8(out,c->members[i].mode))return-1;return 0;}
static int encode_channel_list(cr_server*s,cr_buffer*out){cr_buffer_init(out);pthread_mutex_lock(&s->mutex);size_t count=0;for(size_t i=0;i<CR_SERVER_MAX_CHANNELS;i++)if(s->channels[i].used)count++;if(cr_buffer_append_u32(out,(uint32_t)count)){pthread_mutex_unlock(&s->mutex);return-1;}for(size_t i=0;i<CR_SERVER_MAX_CHANNELS;i++){cr_channel*c=&s->channels[i];if(!c->used)continue;uint16_t list_flags=c->flags|(c->password_len?CHANNEL_LIST_PASSWORD_PROTECTED:0);if(cr_buffer_append_u32(out,c->id)||cr_buffer_append_u32(out,(uint32_t)c->member_count)||cr_buffer_append_u16(out,list_flags)||cr_buffer_append_string16(out,c->name,c->name_len)){pthread_mutex_unlock(&s->mutex);return-1;}}pthread_mutex_unlock(&s->mutex);return 0;}

static int safe_component(const char *s){return *s&&strcmp(s,".")&&strcmp(s,"..")&&!strchr(s,'/');}
static int is_transfer_staging_name(const char *s){size_t n=strlen(s);return (n>=9&&!strcmp(s+n-9,".carracho"))||!strncmp(s,".carracho.",10);}
static int valid_utf8_bytes(const uint8_t*s,size_t n){size_t i=0;while(i<n){uint8_t c=s[i++];if(c<0x80)continue;unsigned need=0;uint32_t cp=0,min=0;if((c&0xe0)==0xc0){need=1;cp=c&0x1f;min=0x80;}else if((c&0xf0)==0xe0){need=2;cp=c&0x0f;min=0x800;}else if((c&0xf8)==0xf0){need=3;cp=c&0x07;min=0x10000;}else return 0;if(i+need>n)return 0;for(unsigned j=0;j<need;j++){uint8_t d=s[i++];if((d&0xc0)!=0x80)return 0;cp=(cp<<6)|(d&0x3f);}if(cp<min||cp>0x10ffff||(cp>=0xd800&&cp<=0xdfff))return 0;}return 1;}

typedef struct {
    uint32_t scalar;
    const char *name;
    uint8_t emoji_presentation;
    uint8_t emoji;
} cr_unicode_emoji_name;

static const cr_unicode_emoji_name cr_unicode_emoji_names[] = {
#include "unicode_emoji_names.inc"
};

static const cr_unicode_emoji_name *unicode_emoji_name(uint32_t scalar) {
    size_t lo=0,hi=sizeof(cr_unicode_emoji_names)/sizeof(cr_unicode_emoji_names[0]);
    while(lo<hi){
        size_t mid=lo+(hi-lo)/2;
        uint32_t value=cr_unicode_emoji_names[mid].scalar;
        if(value==scalar)return &cr_unicode_emoji_names[mid];
        if(value<scalar)lo=mid+1;else hi=mid;
    }
    return NULL;
}

typedef struct {
    uint32_t scalar;
    const char *name;
} cr_emoji_short_name;

static const cr_emoji_short_name cr_emoji_short_names[] = {
    {0x2600u,"sun"},{0x2615u,"coffee"},{0x263au,"smile"},{0x26a1u,"lightning"},
    {0x2705u,"check"},{0x270cu,"victory"},{0x274cu,"cross"},{0x2764u,"heart"},
    {0x2b50u,"star"},{0x1f308u,"rainbow"},{0x1f319u,"moon"},{0x1f31fu,"glowing_star"},
    {0x1f339u,"rose"},{0x1f355u,"pizza"},{0x1f37au,"beer"},{0x1f382u,"cake"},
    {0x1f389u,"party"},{0x1f3b5u,"music"},{0x1f440u,"eyes"},{0x1f44au,"fist"},
    {0x1f44cu,"ok"},{0x1f44du,"thumbsup"},{0x1f44eu,"thumbsdown"},{0x1f44fu,"clap"},
    {0x1f47bu,"ghost"},{0x1f47du,"alien"},{0x1f480u,"skull"},{0x1f494u,"broken_heart"},
    {0x1f495u,"hearts"},{0x1f496u,"sparkling_heart"},{0x1f499u,"blue_heart"},
    {0x1f49au,"green_heart"},{0x1f49bu,"yellow_heart"},{0x1f49cu,"purple_heart"},
    {0x1f4a1u,"idea"},{0x1f4a9u,"poop"},{0x1f4aau,"muscle"},{0x1f4afu,"100"},
    {0x1f4ccu,"pin"},{0x1f4e6u,"package"},{0x1f525u,"fire"},{0x1f5a4u,"black_heart"},
    {0x1f600u,"grin"},{0x1f601u,"grinning"},{0x1f602u,"joy"},{0x1f603u,"smiley"},
    {0x1f604u,"laughing"},{0x1f605u,"sweat_smile"},{0x1f606u,"laugh"},
    {0x1f607u,"angel"},{0x1f608u,"devil"},{0x1f609u,"wink"},{0x1f60au,"blush"},
    {0x1f60bu,"yum"},{0x1f60du,"heart_eyes"},{0x1f60eu,"cool"},{0x1f610u,"neutral"},
    {0x1f612u,"unamused"},{0x1f614u,"pensive"},{0x1f618u,"kiss"},{0x1f61bu,"tongue"},
    {0x1f61cu,"wink_tongue"},{0x1f61eu,"disappointed"},{0x1f620u,"angry"},
    {0x1f621u,"rage"},{0x1f622u,"cry"},{0x1f62du,"crying"},{0x1f62eu,"surprised"},
    {0x1f631u,"scream"},{0x1f634u,"sleep"},{0x1f642u,"smile"},{0x1f643u,"upside_down"},
    {0x1f644u,"eyeroll"},{0x1f64fu,"pray"},{0x1f680u,"rocket"},{0x1f90du,"white_heart"},
    {0x1f90eu,"brown_heart"},{0x1f914u,"thinking"},{0x1f916u,"robot"},{0x1f917u,"hug"},
    {0x1f91du,"handshake"},{0x1f922u,"sick"},{0x1f923u,"rofl"},{0x1f925u,"lying"},
    {0x1f926u,"facepalm"},{0x1f92eu,"puke"},{0x1f92fu,"mindblown"},{0x1f937u,"shrug"},
    {0x1f973u,"partyface"},{0x1f9e1u,"orange_heart"}
};

static const char *emoji_short_name(uint32_t scalar) {
    for(size_t i=0;i<sizeof(cr_emoji_short_names)/sizeof(cr_emoji_short_names[0]);i++)
        if(cr_emoji_short_names[i].scalar==scalar)return cr_emoji_short_names[i].name;
    return NULL;
}

typedef struct {
    const char *utf8;
    const char *name;
} cr_emoji_sequence_short_name;

static const cr_emoji_sequence_short_name cr_emoji_sequence_short_names[] = {
    {"👨‍👩‍👧‍👦","family"},{"👩‍👩‍👧‍👦","family"},{"👨‍👨‍👧‍👦","family"},
    {"🏳️‍🌈","rainbow_flag"},{"🏳️‍⚧️","trans_flag"},
    {"👨‍💻","coder"},{"👩‍💻","coder"},
    {"🤦‍♂️","facepalm"},{"🤦‍♀️","facepalm"},
    {"🤷‍♂️","shrug"},{"🤷‍♀️","shrug"}
};

static const char *emoji_sequence_short_name(const uint8_t *utf8,size_t available,size_t *consumed) {
    const char *best=NULL;size_t best_len=0;
    for(size_t i=0;i<sizeof(cr_emoji_sequence_short_names)/sizeof(cr_emoji_sequence_short_names[0]);i++){
        size_t n=strlen(cr_emoji_sequence_short_names[i].utf8);
        if(n>best_len&&n<=available&&!memcmp(utf8,cr_emoji_sequence_short_names[i].utf8,n)){
            best=cr_emoji_sequence_short_names[i].name;best_len=n;
        }
    }
    if(consumed)*consumed=best_len;
    return best;
}

static int decode_utf8_scalar(const uint8_t*s,size_t n,uint32_t*out,size_t*used){
    if(!s||!n||!out||!used)return-1;
    uint8_t c=s[0];uint32_t cp=0,min=0;size_t need=0;
    if(c<0x80){*out=c;*used=1;return 0;}
    if((c&0xe0)==0xc0){need=1;cp=c&0x1f;min=0x80;}
    else if((c&0xf0)==0xe0){need=2;cp=c&0x0f;min=0x800;}
    else if((c&0xf8)==0xf0){need=3;cp=c&0x07;min=0x10000;}
    else return-1;
    if(need+1>n)return-1;
    for(size_t i=0;i<need;i++){uint8_t d=s[i+1];if((d&0xc0)!=0x80)return-1;cp=(cp<<6)|(d&0x3f);}
    if(cp<min||cp>0x10ffff||(cp>=0xd800&&cp<=0xdfff))return-1;
    *out=cp;*used=need+1;return 0;
}

static int append_classic_bytes(uint8_t*out,size_t cap,size_t*used,const void*src,size_t n){
    if(!out||!used||(!src&&n)||*used>cap||n>cap-*used)return-1;
    if(n)memcpy(out+*used,src,n);
    *used+=n;return 0;
}

static int append_unicode_name(uint8_t*out,size_t cap,size_t*used,const char*name,int with_separator){
    static const char sep[]=" + ";
    if(with_separator&&append_classic_bytes(out,cap,used,sep,sizeof(sep)-1))return-1;
    return append_classic_bytes(out,cap,used,name,strlen(name));
}

static int is_emoji_modifier(uint32_t cp){return cp>=0x1f3fb&&cp<=0x1f3ff;}
static int is_regional_indicator(uint32_t cp){return cp>=0x1f1e6&&cp<=0x1f1ff;}
static int is_emoji_tag(uint32_t cp){return cp>=0xe0020&&cp<=0xe007f;}
static int wire_is_tagged_utf8(const uint8_t*data,size_t len){return data&&len>=3&&data[0]==0xef&&data[1]==0xbb&&data[2]==0xbf;}

static int classic_text_describing_emoji(const uint8_t*wire,size_t wire_len,uint8_t*out,size_t cap,size_t*out_len){
    if(!wire||!out||!out_len)return-1;
    if(!wire_is_tagged_utf8(wire,wire_len)){
        if(wire_len>cap)return-1;
        if(wire_len)memcpy(out,wire,wire_len);
        *out_len=wire_len;return 0;
    }

    const uint8_t*utf8=wire+3;size_t utf8_len=wire_len-3;
    if(!utf8_len||!valid_utf8_bytes(utf8,utf8_len)||memchr(utf8,0,utf8_len))return-1;

    size_t pos=0,used=0;
    while(pos<utf8_len){
        size_t sequence_len=0;
        const char*sequence_alias=emoji_sequence_short_name(utf8+pos,utf8_len-pos,&sequence_len);
        if(sequence_alias){
            if(append_classic_bytes(out,cap,&used,"*",1)||
               append_unicode_name(out,cap,&used,sequence_alias,0)||
               append_classic_bytes(out,cap,&used,"*",1))return-1;
            pos+=sequence_len;continue;
        }

        uint32_t cp=0;size_t scalar_len=0;
        if(decode_utf8_scalar(utf8+pos,utf8_len-pos,&cp,&scalar_len))return-1;
        const cr_unicode_emoji_name*info=unicode_emoji_name(cp);

        char scalar[5];memcpy(scalar,utf8+pos,scalar_len);scalar[scalar_len]='\0';
        uint8_t mac[8];size_t mac_len=0;
        if(cr_utf8_to_macroman_filtered(scalar,mac,sizeof(mac),&mac_len))return-1;

        uint32_t next_cp=0;size_t next_len=0;int has_next=0;
        if(pos+scalar_len<utf8_len&&!decode_utf8_scalar(utf8+pos+scalar_len,utf8_len-pos-scalar_len,&next_cp,&next_len))has_next=1;
        int sequence_follows=has_next&&(next_cp==0xfe0e||next_cp==0xfe0f||next_cp==0x200d||
            next_cp==0x20e3||is_emoji_modifier(next_cp)||is_emoji_tag(next_cp)||
            (is_regional_indicator(cp)&&is_regional_indicator(next_cp)));
        int emoji_start=info&&info->emoji&&(info->emoji_presentation||mac_len==0||sequence_follows);

        if(!emoji_start){
            if(!mac_len||append_classic_bytes(out,cap,&used,mac,mac_len))return-1;
            pos+=scalar_len;continue;
        }

        const char*base_name=emoji_short_name(cp);
        if(!base_name)base_name=info->name;
        if(append_classic_bytes(out,cap,&used,"*",1)||append_unicode_name(out,cap,&used,base_name,0))return-1;
        pos+=scalar_len;

        if(is_regional_indicator(cp)&&pos<utf8_len){
            uint32_t ri=0;size_t rn=0;
            if(!decode_utf8_scalar(utf8+pos,utf8_len-pos,&ri,&rn)&&is_regional_indicator(ri)){
                const cr_unicode_emoji_name*ri_info=unicode_emoji_name(ri);
                if(!ri_info||append_unicode_name(out,cap,&used,ri_info->name,1))return-1;
                pos+=rn;
            }
        }

        while(pos<utf8_len){
            uint32_t component=0;size_t component_len=0;
            if(decode_utf8_scalar(utf8+pos,utf8_len-pos,&component,&component_len))return-1;
            if(component==0xfe0e||component==0xfe0f){pos+=component_len;continue;}
            if(is_emoji_modifier(component)){
                pos+=component_len;continue;
            }
            if(component==0x20e3||is_emoji_tag(component)){
                const cr_unicode_emoji_name*component_info=unicode_emoji_name(component);
                const char*component_name=emoji_short_name(component);
                if(!component_info||append_unicode_name(out,cap,&used,component_name?component_name:component_info->name,1))return-1;
                pos+=component_len;continue;
            }
            if(component==0x200d){
                pos+=component_len;
                if(pos>=utf8_len)return-1;
                uint32_t joined=0;size_t joined_len=0;
                if(decode_utf8_scalar(utf8+pos,utf8_len-pos,&joined,&joined_len))return-1;
                const cr_unicode_emoji_name*joined_info=unicode_emoji_name(joined);
                const char*joined_name=emoji_short_name(joined);
                if(!joined_info||!joined_info->emoji||
                   append_unicode_name(out,cap,&used,joined_name?joined_name:joined_info->name,1))return-1;
                pos+=joined_len;continue;
            }
            break;
        }
        if(append_classic_bytes(out,cap,&used,"*",1))return-1;
    }
    *out_len=used;return 0;
}

static int encode_file_name(const char*utf8,int modern,uint8_t*out,size_t cap,size_t*out_len){size_t classic_len=0;if(cr_utf8_to_macroman(utf8,out,cap,&classic_len))return-1;if(!modern){*out_len=classic_len;return 0;}char roundtrip[NAME_MAX*4+8];if(classic_len<cap&&!cr_macroman_to_utf8(out,classic_len,roundtrip,sizeof(roundtrip))&&!strcmp(roundtrip,utf8)){*out_len=classic_len;return 0;}size_t n=strlen(utf8);if(!valid_utf8_bytes((const uint8_t*)utf8,n)||n+3>cap)return-1;out[0]=0xef;out[1]=0xbb;out[2]=0xbf;memcpy(out+3,utf8,n);*out_len=n+3;return 0;}
static int decode_file_component(const cr_session*session,const uint8_t*wire,size_t n,char*out,size_t cap){if(n>=3&&wire[0]==0xef&&wire[1]==0xbb&&wire[2]==0xbf){if(!session->modern_transport||n==3||n-3>=cap||!valid_utf8_bytes(wire+3,n-3)||memchr(wire+3,0,n-3))return-1;memcpy(out,wire+3,n-3);out[n-3]='\0';return safe_component(out)?0:-1;}if(cr_macroman_to_utf8(wire,n,out,cap))return-1;return safe_component(out)?0:-1;}
static int join_path_component(char *out, size_t cap, const char *base, const char *component) {
    size_t a = strlen(base), b = strlen(component);
    if (a + 1 + b + 1 > cap) return -1;
    memcpy(out, base, a); out[a] = '/'; memcpy(out + a + 1, component, b + 1);
    return 0;
}
static int ensure_directory_tree(const char *path);
static int path_is_within_root(const char*path,const char*root){size_t n=strlen(root);if(n==1&&root[0]=='/')return path[0]=='/';return !strncmp(path,root,n)&&(!path[n]||path[n]=='/');}
static int session_uses_legacy_files_root(cr_server*s,const cr_session*session){
    return s && session && !session->modern_transport && s->state.legacy_storage_root[0];
}
static cr_file_metadata_store*session_metadata_store(cr_server*s,const cr_session*session){
    return session_uses_legacy_files_root(s,session)?&s->legacy_metadata:&s->metadata;
}
static int session_files_root_for_mode(cr_server*s,cr_session*session,int use_legacy_root,char*out,size_t cap){
    const char*base=use_legacy_root?s->state.legacy_storage_root:s->state.storage_root;if(!session->files_root_path[0]||session->personal==CR_PERSONAL_ROOT){if(strlen(base)+1>cap)return-1;strcpy(out,base);return 0;}
    char real_base[PATH_MAX];if(!realpath(base,real_base))return-1;
    char candidate[PATH_MAX];if(strlen(base)+1>sizeof(candidate))return-1;strcpy(candidate,base);const char*p=session->files_root_path;
    while(*p){
        const char*slash=strchr(p,'/');size_t n=slash?(size_t)(slash-p):strlen(p);int final_component=slash==NULL;
        if(!n||n>252||(n==1&&p[0]=='.')||(n==2&&p[0]=='.'&&p[1]=='.'))return-1;
        char component[253],next[PATH_MAX],resolved[PATH_MAX],parent_resolved[PATH_MAX];memcpy(component,p,n);component[n]=0;if(join_path_component(next,sizeof(next),candidate,component))return-1;
        struct stat st;
        if(lstat(next,&st)==0){
            if(!realpath(next,resolved)||stat(resolved,&st)||!S_ISDIR(st.st_mode))return-1;
            /* Only the final configured group root may intentionally resolve outside Files. */
            if(!final_component&&!path_is_within_root(resolved,real_base))return-1;
        }
        else if(errno==ENOENT){
            if(!realpath(candidate,parent_resolved)||!path_is_within_root(parent_resolved,real_base)||mkdir(next,0755)||!realpath(next,resolved)||!path_is_within_root(resolved,real_base))return-1;
        }
        else return-1;
        strcpy(candidate,next);if(!slash)break;p=slash+1;
    }
    if(strlen(candidate)+1>cap)return-1;
    strcpy(out,candidate);
    return 0;
}
static int session_files_root(cr_server*s,cr_session*session,char*out,size_t cap){
    return session_files_root_for_mode(s,session,session_uses_legacy_files_root(s,session),out,cap);
}

/* Files-Legacy remains the physical Classic tree. Direct directory symlinks in the
 * modern Files root are explicit administrator shares and are overlaid at the Classic
 * root as virtual folders. Any real Files-Legacy entry with the same name wins. */
static int legacy_share_overlay_root_for_path(cr_server*s,cr_session*session,
                                              const uint8_t*path,size_t path_len,
                                              const char*legacy_root,char*out,size_t cap){
    if(!session_uses_legacy_files_root(s,session)||!path_len||session->personal==CR_PERSONAL_ROOT)return 0;
    size_t n=0;while(n<path_len&&path[n]!=1)n++;
    if(!n||n>255)return 0;
    char component[1024];if(decode_file_component(session,path,n,component,sizeof(component)))return 0;
    if(session->personal==CR_PERSONAL_NESTED){
        char home_name[512];if(strlen(session->login)+2>sizeof(home_name))return-1;
        home_name[0]='~';strcpy(home_name+1,session->login);
        if(!strcmp(component,home_name))return 0;
    }

    char legacy_candidate[PATH_MAX];struct stat st;
    if(join_path_component(legacy_candidate,sizeof(legacy_candidate),legacy_root,component))return-1;
    if(lstat(legacy_candidate,&st)==0)return 0;
    if(errno!=ENOENT)return 0;

    char modern_root[PATH_MAX],modern_candidate[PATH_MAX],resolved[PATH_MAX];
    if(session_files_root_for_mode(s,session,0,modern_root,sizeof(modern_root)))return 0;
    if(join_path_component(modern_candidate,sizeof(modern_candidate),modern_root,component))return-1;
    if(lstat(modern_candidate,&st)||!S_ISLNK(st.st_mode)||!realpath(modern_candidate,resolved)||
       stat(resolved,&st)||!S_ISDIR(st.st_mode))return 0;
    if(strlen(modern_root)+1>cap)return-1;
    strcpy(out,modern_root);return 1;
}

static int resolve_legacy_path_ex(cr_server*s,cr_session*session,const uint8_t*path,size_t path_len,char*out,size_t cap,int require_existing){
    if(path_len>4096)return-1;
    char group_root[PATH_MAX];if(session_files_root(s,session,group_root,sizeof(group_root)))return-1;const char*root=group_root;size_t pos=0;int first=1;char virtual_home[512];
    if(strlen(session->login)+2>sizeof(virtual_home))return-1;
    virtual_home[0]='~';strcpy(virtual_home+1,session->login);
    char home[PATH_MAX]="";
    if(session->personal!=CR_PERSONAL_NONE){if(join_path_component(home,sizeof(home),s->state.personal_home_root,session->login))return-1;if(mkdir(home,0755)&&errno!=EEXIST)return-1;}
    if(session->personal==CR_PERSONAL_ROOT)root=home;
    char overlay_root[PATH_MAX];int overlay=legacy_share_overlay_root_for_path(s,session,path,path_len,group_root,overlay_root,sizeof(overlay_root));
    if(overlay<0)return-1;
    if(overlay>0)root=overlay_root;
    char resolved_scope[PATH_MAX];if(!realpath(root,resolved_scope))return-1;
    int allow_server_symlink_shares=session->personal!=CR_PERSONAL_ROOT;
    unsigned symlink_share_hops=0;
    if(strlen(root)+1>cap)return-1;
    strcpy(out,root);
    while(pos<path_len){
        size_t start=pos;while(pos<path_len&&path[pos]!=1)pos++;size_t n=pos-start;if(!n||n>255)return-1;
        char component[1024];if(decode_file_component(session,path+start,n,component,sizeof(component)))return-1;
        if(first&&session->personal==CR_PERSONAL_NESTED&&!strcmp(component,virtual_home)){
            if(strlen(home)+1>cap||!realpath(home,resolved_scope))return-1;
            allow_server_symlink_shares=0;
            strcpy(out,home);
        }
        else{size_t have=strlen(out),cn=strlen(component);if(have+1+cn+1>cap)return-1;out[have]='/';memcpy(out+have+1,component,cn+1);}
        int is_last=(pos>=path_len);struct stat st;
        if(lstat(out,&st)==0){
            int is_symlink=S_ISLNK(st.st_mode);
            char resolved[PATH_MAX];if(!realpath(out,resolved)||stat(resolved,&st))return-1;
            if(!path_is_within_root(resolved,resolved_scope)){
                if(!allow_server_symlink_shares||!is_symlink||!S_ISDIR(st.st_mode))return-1;
                if(++symlink_share_hops>32||strlen(resolved)+1>sizeof(resolved_scope))return-1;
                strcpy(resolved_scope,resolved);
            }
        }
        else if(errno==ENOENT){
            if(require_existing||!is_last)return-1;
            char parent[PATH_MAX],parent_resolved[PATH_MAX];snprintf(parent,sizeof(parent),"%s",out);char*slash=strrchr(parent,'/');if(!slash)return-1;if(slash==parent)slash[1]=0;else *slash=0;
            if(!realpath(parent,parent_resolved)||!path_is_within_root(parent_resolved,resolved_scope))return-1;
        }
        else return-1;
        first=0;if(pos<path_len)pos++;
    }
    if(require_existing){struct stat st;if(stat(out,&st))return-1;}
    return 0;
}
static int resolve_legacy_path(cr_server*s,cr_session*session,const uint8_t*path,size_t path_len,char*out,size_t cap){return resolve_legacy_path_ex(s,session,path,path_len,out,cap,1);}

static int build_legacy_child(const uint8_t*parent,size_t parent_len,const uint8_t*name,size_t name_len,uint8_t*out,size_t*out_len);
static uint32_t stat_mac_time(time_t t);
static int dir_item_cmp(const void*a,const void*b){const dir_item*x=a,*y=b;return strcasecmp(x->name,y->name);}
static int path_is_inside_dropbox(cr_server*s,cr_session*session,const uint8_t*path,size_t path_len){size_t pos=0;uint8_t current[4096];size_t clen=0;cr_file_metadata_store*metadata=session_metadata_store(s,session);while(pos<path_len){size_t start=pos;while(pos<path_len&&path[pos]!=1)pos++;size_t n=pos-start;if(!n)return 0;if(build_legacy_child(current,clen,path+start,n,current,&clen))return 0;cr_file_metadata m;int found=0;if(!cr_file_metadata_get(metadata,current,clen,&m,&found)){int drop=found&&((m.flags&0x2000u)!=0);cr_file_metadata_free(&m);if(drop)return 1;}if(pos<path_len)pos++;}return 0;}
static int path_is_upload_folder(cr_server*s,cr_session*session,const uint8_t*path,size_t path_len){
    cr_file_metadata m;int found=0;if(cr_file_metadata_get(session_metadata_store(s,session),path,path_len,&m,&found))return 0;
    int upload=found&&((m.flags&(0x4000u|0x2000u))!=0);cr_file_metadata_free(&m);return upload;
}
static uint32_t visible_directory_item_count(const char*dir,int modern){
    DIR*d=opendir(dir);if(!d)return 0;uint64_t count=0;struct dirent*de;
    while((de=readdir(d))){
        if(de->d_name[0]=='.'||is_transfer_staging_name(de->d_name))continue;
        char full[PATH_MAX];if(join_path_component(full,sizeof(full),dir,de->d_name))continue;
        struct stat st;if(lstat(full,&st)||(!S_ISREG(st.st_mode)&&!S_ISDIR(st.st_mode)&&!S_ISLNK(st.st_mode)))continue;
        uint8_t wire_name[512];size_t wn=0;if(encode_file_name(de->d_name,modern,wire_name,sizeof(wire_name),&wn)||!wn||wn>255||memchr(wire_name,1,wn))continue;
        count++;if(count>=UINT32_MAX){closedir(d);return UINT32_MAX;}
    }
    closedir(d);return(uint32_t)count;
}
static int classic_agreement_text(const char*utf8,uint8_t*out,size_t cap,size_t*out_len){
    if(!utf8||(!out&&cap))return-1;
    size_t input_len=strlen(utf8);
    char*normalized=malloc(input_len+1);
    uint8_t*filtered=malloc(input_len+1);
    if(!normalized||!filtered){free(normalized);free(filtered);return-1;}

    size_t src=0,dst=0;
    while(src<input_len){
        uint8_t c=(uint8_t)utf8[src];
        if(c=='\r'){
            normalized[dst++]='\r';
            src++;
            if(src<input_len&&utf8[src]=='\n')src++;
            continue;
        }
        if(c=='\n'){
            normalized[dst++]='\r';
            src++;
            continue;
        }
        if(src+2<input_len&&c==0xe2&&(uint8_t)utf8[src+1]==0x80&&
           ((uint8_t)utf8[src+2]==0xa8||(uint8_t)utf8[src+2]==0xa9)){
            normalized[dst++]='\r';
            src+=3;
            continue;
        }
        if((c<0x20&&c!='\t')||c==0x7f){src++;continue;}

        size_t scalar_len=1;
        if((c&0xe0)==0xc0)scalar_len=2;
        else if((c&0xf0)==0xe0)scalar_len=3;
        else if((c&0xf8)==0xf0)scalar_len=4;
        if(src+scalar_len>input_len){free(normalized);free(filtered);return-1;}
        memcpy(normalized+dst,utf8+src,scalar_len);
        dst+=scalar_len;src+=scalar_len;
    }
    normalized[dst]='\0';

    size_t filtered_len=0;
    int rc=cr_utf8_to_macroman_filtered(normalized,filtered,input_len+1,&filtered_len);
    if(!rc){
        size_t copy=filtered_len<cap?filtered_len:cap;
        if(copy)memcpy(out,filtered,copy);
        if(out_len)*out_len=copy;
    }
    free(normalized);free(filtered);
    return rc;
}

static size_t classic_agreement_style(uint8_t out[22]){
    static const uint8_t style[22]={
        0x00,0x01,                    /* one style run */
        0x00,0x00,0x00,0x00,          /* start char 0 */
        0x00,0x0e,                    /* height 14 */
        0x00,0x0b,                    /* ascent 11 */
        0x00,0x00,                    /* system font */
        0x00,0x00,                    /* normal face + pad */
        0x00,0x0c,                    /* 12 pt */
        0x00,0x00,0x00,0x00,0x00,0x00 /* black RGB */
    };
    memcpy(out,style,sizeof(style));
    return sizeof(style);
}

static int encode_directory(cr_server*s,cr_session*session,const uint8_t*legacy,size_t legacy_len,cr_buffer*out,cr_buffer*labels){
    cr_buffer_init(out);cr_buffer_init(labels);
    if(!account_perm(session,PERM_VIEW_DROPBOXES)&&path_is_inside_dropbox(s,session,legacy,legacy_len))return cr_buffer_append_string16(out,legacy,legacy_len)||cr_buffer_append_u16(out,0)?-1:0;
    char dir[PATH_MAX];if(resolve_legacy_path(s,session,legacy,legacy_len,dir,sizeof(dir)))return-1;struct stat rootst;if(stat(dir,&rootst)||!S_ISDIR(rootst.st_mode))return-1;DIR*d=opendir(dir);if(!d)return-1;dir_item*items=NULL;size_t count=0,cap=0;struct dirent*de;
    while((de=readdir(d))){
        if(de->d_name[0]=='.'||is_transfer_staging_name(de->d_name))continue;
        char full[PATH_MAX];if(join_path_component(full,sizeof(full),dir,de->d_name))continue;struct stat lst;if(lstat(full,&lst)||(!S_ISREG(lst.st_mode)&&!S_ISDIR(lst.st_mode)&&!S_ISLNK(lst.st_mode)))continue;
        int is_symlink=S_ISLNK(lst.st_mode);struct stat effective=lst;int target_accessible=!is_symlink;
        uint8_t wire_name[512];size_t wn=0;if(encode_file_name(de->d_name,session->modern_transport,wire_name,sizeof(wire_name),&wn)||!wn||wn>255||memchr(wire_name,1,wn))continue;
        uint8_t child[4096];size_t child_len=0;if(build_legacy_child(legacy,legacy_len,wire_name,wn,child,&child_len))continue;
        if(is_symlink){char resolved_child[PATH_MAX];if(!resolve_legacy_path_ex(s,session,child,child_len,resolved_child,sizeof(resolved_child),1)&&!stat(resolved_child,&effective)&&(S_ISREG(effective.st_mode)||S_ISDIR(effective.st_mode)))target_accessible=1;}
        if(count==cap){size_t nc=cap?cap*2:32;dir_item*ni=realloc(items,nc*sizeof(*ni));if(!ni){closedir(d);free(items);return-1;}items=ni;cap=nc;}dir_item*x=&items[count++];memset(x,0,sizeof(*x));snprintf(x->name,sizeof(x->name),"%s",de->d_name);memcpy(x->wire_name,wire_name,wn);x->wire_name_len=wn;
        if(target_accessible&&S_ISREG(effective.st_mode))x->size=(uint32_t)((uint64_t)effective.st_size>UINT32_MAX?UINT32_MAX:effective.st_size);
        else if(target_accessible&&S_ISDIR(effective.st_mode)){int hidden_dropbox=!account_perm(session,PERM_VIEW_DROPBOXES)&&path_is_inside_dropbox(s,session,child,child_len);if(!hidden_dropbox)x->size=visible_directory_item_count(full,session->modern_transport);}
        x->timestamp=stat_mac_time(target_accessible?effective.st_mtime:lst.st_mtime);if(target_accessible&&S_ISDIR(effective.st_mode))x->flags|=DIR_FLAG_FOLDER;if(target_accessible&&S_ISDIR(effective.st_mode)){x->file_type=FILETYPE_FOLDER;x->creator=CREATOR_FOLDER;}else if(is_symlink){x->file_type=FILETYPE_SYMLINK;x->creator=CREATOR_FOLDER;}
        if(target_accessible){cr_file_metadata m;int found=0;if(!cr_file_metadata_get(session_metadata_store(s,session),child,child_len,&m,&found)){if(found){x->flags|=m.flags;x->label=m.label;}cr_file_metadata_free(&m);}}
    }
    closedir(d);

    if(session_uses_legacy_files_root(s,session)&&legacy_len==0&&session->personal!=CR_PERSONAL_ROOT){
        char modern_root[PATH_MAX];
        if(!session_files_root_for_mode(s,session,0,modern_root,sizeof(modern_root))){
            DIR*md=opendir(modern_root);
            if(md){
                struct dirent*mde;
                while((mde=readdir(md))){
                    if(mde->d_name[0]=='.'||is_transfer_staging_name(mde->d_name))continue;
                    int duplicate=0;for(size_t i=0;i<count;i++)if(!strcasecmp(items[i].name,mde->d_name)){duplicate=1;break;}
                    if(duplicate)continue;

                    char full[PATH_MAX],resolved[PATH_MAX];struct stat lst,effective;
                    if(join_path_component(full,sizeof(full),modern_root,mde->d_name)||lstat(full,&lst)||
                       !S_ISLNK(lst.st_mode)||!realpath(full,resolved)||stat(resolved,&effective)||
                       !S_ISDIR(effective.st_mode))continue;

                    uint8_t wire_name[512];size_t wn=0;
                    if(encode_file_name(mde->d_name,0,wire_name,sizeof(wire_name),&wn)||!wn||wn>255||memchr(wire_name,1,wn))continue;
                    uint8_t child[4096];size_t child_len=0;
                    if(build_legacy_child(NULL,0,wire_name,wn,child,&child_len))continue;
                    char resolved_child[PATH_MAX];
                    if(resolve_legacy_path_ex(s,session,child,child_len,resolved_child,sizeof(resolved_child),1))continue;

                    if(count==cap){size_t nc=cap?cap*2:32;dir_item*ni=realloc(items,nc*sizeof(*ni));if(!ni){closedir(md);free(items);return-1;}items=ni;cap=nc;}
                    dir_item*x=&items[count++];memset(x,0,sizeof(*x));
                    snprintf(x->name,sizeof(x->name),"%s",mde->d_name);
                    memcpy(x->wire_name,wire_name,wn);x->wire_name_len=wn;
                    x->size=visible_directory_item_count(resolved_child,0);
                    x->timestamp=stat_mac_time(effective.st_mtime);
                    x->file_type=FILETYPE_FOLDER;x->creator=CREATOR_FOLDER;x->flags=DIR_FLAG_FOLDER;

                    cr_file_metadata m;int found=0;
                    if(!cr_file_metadata_get(&s->metadata,child,child_len,&m,&found)){
                        if(found)x->flags|=m.flags;
                        cr_file_metadata_free(&m);
                    }
                }
                closedir(md);
            }
        }
    }

    if(session->personal==CR_PERSONAL_NESTED&&legacy_len==0){char vh[512];if(strlen(session->login)+2>sizeof(vh)){free(items);return-1;}vh[0]='~';strcpy(vh+1,session->login);int exists=0;for(size_t i=0;i<count;i++)if(!strcasecmp(items[i].name,vh))exists=1;if(!exists){uint8_t wm[512];size_t wn=0;if(cr_utf8_to_macroman(vh,wm,sizeof(wm),&wn)){free(items);return-1;}if(count==cap){size_t nc=cap?cap*2:32;dir_item*ni=realloc(items,nc*sizeof(*ni));if(!ni){free(items);return-1;}items=ni;cap=nc;}dir_item*x=&items[count++];memset(x,0,sizeof(*x));snprintf(x->name,sizeof(x->name),"%s",vh);memcpy(x->wire_name,wm,wn);x->wire_name_len=wn;char homefs[PATH_MAX];if(!resolve_legacy_path(s,session,wm,wn,homefs,sizeof(homefs)))x->size=visible_directory_item_count(homefs,session->modern_transport);x->file_type=FILETYPE_FOLDER;x->creator=CREATOR_FOLDER;x->flags=DIR_FLAG_FOLDER;}}
    qsort(items,count,sizeof(*items),dir_item_cmp);if(count>UINT16_MAX){free(items);return-1;}if(cr_buffer_append_string16(out,legacy,legacy_len)||cr_buffer_append_u16(out,(uint16_t)count)){free(items);return-1;}
    for(size_t i=0;i<count;i++){dir_item*x=&items[i];if(x->wire_name_len>UINT16_MAX-20||cr_buffer_append_u16(out,(uint16_t)(x->wire_name_len+20))||cr_buffer_append_u16(out,(uint16_t)x->wire_name_len)||cr_buffer_append(out,x->wire_name,x->wire_name_len)||cr_buffer_append_u32(out,x->size)||cr_buffer_append_u32(out,x->timestamp)||cr_buffer_append_u32(out,x->file_type)||cr_buffer_append_u32(out,x->creator)||cr_buffer_append_u16(out,x->flags)||cr_buffer_append_u8(labels,x->label)){free(items);return-1;}}
    free(items);return 0;
}

static int send_login_success(cr_session*s){
    cr_buffer users;
    int include_pictures=s->modern_transport?0:1;
    if(encode_user_list(s->server,s,include_pictures,&users))return-1;
    if(users.len>UINT16_MAX&&include_pictures){
        cr_buffer_free(&users);
        if(encode_user_list(s->server,s,0,&users))return-1;
    }
    if(users.len>UINT16_MAX){cr_buffer_free(&users);return-1;}
    cr_buffer legacy_users;cr_buffer_init(&legacy_users);if(s->modern_transport&&encode_legacy_user_ids(s->server,s,&legacy_users)){cr_buffer_free(&users);return-1;}
    uint8_t session_info[12],perms[8],maxtr[2],ver[2],server_name[1024],agreement_text[65535],agreement_style[22];size_t sn=0,an=0,asn=0;uint16_t max_transfers=0;int agreement_enabled=0;
    pthread_mutex_lock(&s->server->state.mutex);
    max_transfers=s->server->state.advanced.max_file_transfers_per_user;
    int state_fail=cr_utf8_to_macroman(s->server->state.identity.name,server_name,sizeof(server_name),&sn);
    agreement_enabled=s->server->state.agreement_enabled&&s->server->state.agreement_text;
    if(!state_fail&&agreement_enabled){
        if(!s->modern_transport)asn=classic_agreement_style(agreement_style);
        size_t agreement_cap=s->modern_transport?sizeof(agreement_text)-8:(size_t)0xfc00-8-asn;
        state_fail=s->modern_transport
            ?cr_utf8_to_macroman(s->server->state.agreement_text,agreement_text,agreement_cap,&an)
            :classic_agreement_text(s->server->state.agreement_text,agreement_text,agreement_cap,&an);
    }
    pthread_mutex_unlock(&s->server->state.mutex);
    if(state_fail){cr_buffer_free(&users);return-1;}
    cr_account tmp;memset(&tmp,0,sizeof(tmp));tmp.permission_bits=s->permission_bits;cr_account_permission_bytes(&tmp,perms);if(!s->modern_transport)perms[PERM_POST_NEWS/8]&=(uint8_t)~(0x80u>>(PERM_POST_NEWS%8));cr_write_be32(session_info,s->user_id);memcpy(session_info+4,perms,8);cr_write_be16(maxtr,max_transfers);cr_write_be16(ver,s->modern_transport?3:2);
    cr_tlv_out f[16];size_t n=0;f[n++]=(cr_tlv_out){1,session_info,12};f[n++]=(cr_tlv_out){2,server_name,(uint16_t)sn};f[n++]=(cr_tlv_out){3,users.data,(uint16_t)users.len};
    cr_buffer agreement;cr_buffer_init(&agreement);if(agreement_enabled){cr_buffer_append_u32(&agreement,(uint32_t)an);cr_buffer_append(&agreement,agreement_text,an);cr_buffer_append_u32(&agreement,(uint32_t)asn);if(asn)cr_buffer_append(&agreement,agreement_style,asn);f[n++]=(cr_tlv_out){4,agreement.data,(uint16_t)agreement.len};}
    uint8_t media_caps[4];cr_write_be32(media_caps,s->modern_transport?MEDIA_CAP_CURRENT:0);
    const char*files_root_name=s->files_root_name[0]?s->files_root_name:"Allgemein";size_t files_root_name_len=strlen(files_root_name);if(!files_root_name_len||files_root_name_len>64){cr_buffer_free(&agreement);cr_buffer_free(&users);return-1;}
    f[n++]=(cr_tlv_out){0x21,maxtr,2};f[n++]=(cr_tlv_out){5,ver,2};f[n++]=(cr_tlv_out){LOGIN_FIELD_MEDIA_CAPABILITIES,media_caps,4};f[n++]=(cr_tlv_out){LOGIN_FIELD_FILES_ROOT_NAME,(const uint8_t*)files_root_name,(uint16_t)files_root_name_len};if(s->modern_transport){if(legacy_users.len>UINT16_MAX){cr_buffer_free(&legacy_users);cr_buffer_free(&agreement);cr_buffer_free(&users);return-1;}f[n++]=(cr_tlv_out){LOGIN_FIELD_LEGACY_USER_IDS,legacy_users.data,(uint16_t)legacy_users.len};f[n++]=(cr_tlv_out){6,s->modern_salt,CR_MODERN_SESSION_SALT};f[n++]=(cr_tlv_out){7,s->modern_server_public_key,32};f[n++]=(cr_tlv_out){8,s->modern_handshake_authenticator,32};}int rc=session_send_key(s,k_initial_key,sizeof(k_initial_key),CMD_LOGIN_SUCCESS,0,f,n);cr_buffer_free(&legacy_users);cr_buffer_free(&agreement);cr_buffer_free(&users);return rc;
}

static int state_group_files_root(cr_server_state*state,const char*group_id,char*path,size_t path_cap,char*name,size_t name_cap){
    if (!path || !path_cap || !name || !name_cap) return 0;
    path[0] = 0;
    snprintf(name, name_cap, "Allgemein");
    if (!group_id || !*group_id) return 0;
    int found=0;pthread_mutex_lock(&state->mutex);for(size_t i=0;i<state->account_group_count;i++)if(!strcasecmp(state->account_groups[i].id,group_id)){snprintf(path,path_cap,"%s",state->account_groups[i].files_root_path);snprintf(name,name_cap,"%s",state->account_groups[i].files_root_path[0]?state->account_groups[i].files_root_name:"Allgemein");found=1;break;}pthread_mutex_unlock(&state->mutex);return found;
}
static void append_session_group_color(cr_session*s,cr_tlv_out*fields,size_t*count,uint8_t color_bytes[4]){
    if(!s->has_group_color)return;
    cr_write_be32(color_bytes,s->group_color_rgb);
    fields[(*count)++]=(cr_tlv_out){USER_FIELD_GROUP_COLOR,color_bytes,4};
}
static int send_initial_user_updates(cr_session*recipient){
    if(!recipient||!recipient->modern_transport)return 0;
    cr_server*server=recipient->server;int rc=0;
    pthread_mutex_lock(&server->mutex);
    for(size_t i=0;i<server->allocated_session_count;i++){
        cr_session*source=server->sessions[i];
        if(!session_ready_for_async(source))continue;
        uint8_t uid[4],color[4];cr_write_be32(uid,source->user_id);
        cr_tlv_out fields[5];size_t n=0;
        fields[n++]=(cr_tlv_out){1,uid,4};
        fields[n++]=(cr_tlv_out){2,source->nickname,(uint16_t)source->nickname_len};
        if(source->picture_len<=UINT16_MAX)
            fields[n++]=(cr_tlv_out){0xb4,source->picture,(uint16_t)source->picture_len};
        fields[n++]=(cr_tlv_out){0xf0000002u,source->status_message,(uint16_t)source->status_message_len};
        append_session_group_color(source,fields,&n,color);
        if(session_send(recipient,CMD_USER_UPDATE,0,fields,n)){rc=-1;break;}
    }
    pthread_mutex_unlock(&server->mutex);
    return rc;
}
static void broadcast_user_arrived(cr_session*s){
    uint8_t uid[4],flags[2],color[4],legacy=(uint8_t)(s->modern_transport?0:1);
    uint8_t*classic_picture=NULL;size_t classic_picture_len=0;
    (void)classic_avatar_png(s->picture,s->picture_len,&classic_picture,&classic_picture_len);
    cr_write_be32(uid,s->user_id);cr_write_be16(flags,s->sleeping?0x0100:0);
    cr_tlv_out classic_fields[4]={{1,uid,4},{2,s->nickname,(uint16_t)s->nickname_len},{3,flags,2}};
    size_t classic_count=3;
    if(classic_picture_len)classic_fields[classic_count++]=(cr_tlv_out){0xb4,classic_picture,(uint16_t)classic_picture_len};
    cr_tlv_out modern_fields[7];size_t modern_count=0;
    modern_fields[modern_count++]=classic_fields[0];
    modern_fields[modern_count++]=classic_fields[1];
    modern_fields[modern_count++]=classic_fields[2];
    if(s->picture_len<=UINT16_MAX&&s->picture_len)
        modern_fields[modern_count++]=(cr_tlv_out){0xb4,s->picture,(uint16_t)s->picture_len};
    modern_fields[modern_count++]=(cr_tlv_out){0xf0000002u,s->status_message,(uint16_t)s->status_message_len};
    append_session_group_color(s,modern_fields,&modern_count,color);
    modern_fields[modern_count++]=(cr_tlv_out){USER_FIELD_LEGACY_TRANSPORT,&legacy,1};
    pthread_mutex_lock(&s->server->mutex);
    for(size_t i=0;i<s->server->allocated_session_count;i++){
        cr_session*x=s->server->sessions[i];
        if(!x||x==s||!session_ready_for_async(x))continue;
        if(x->modern_transport)session_send(x,CMD_USER_ARRIVED,0,modern_fields,modern_count);
        else session_send(x,CMD_USER_ARRIVED,0,classic_fields,classic_count);
    }
    pthread_mutex_unlock(&s->server->mutex);
    free(classic_picture);
}
static void session_unregister(cr_session*s){
    cr_server*server=s->server;
    pthread_mutex_lock(&server->mutex);
    int was_authenticated=s->authenticated,was_announced=s->announced;
    s->authenticated=0;
    s->announced=0;
    s->closed=1;

    /* Classic clients need the conference-leave event before the global disconnect. Once
       0x08 removed the global user, old clients can no longer resolve the 0x88 member row. */
    uint8_t uid[4];
    cr_write_be32(uid,s->user_id);
    for(size_t ci=0;ci<CR_SERVER_MAX_CHANNELS;ci++){
        cr_channel*c=&server->channels[ci];
        if(!c->used)continue;
        int idx=channel_member_index(c,s->user_id);
        if(idx<0)continue;
        memmove(&c->members[idx],&c->members[idx+1],(c->member_count-(size_t)idx-1)*sizeof(c->members[0]));
        c->member_count--;
        if(was_announced){
            uint8_t cid[4];
            cr_write_be32(cid,c->id);
            cr_tlv_out leave_fields[]={{CHANNEL_FIELD_ID,cid,4},{CHANNEL_FIELD_USER_ID,uid,4}};
            for(size_t mi=0;mi<c->member_count;mi++){
                cr_session*x=find_session_locked(server,c->members[mi].user_id);
                if(x&&session_ready_for_async(x))session_send(x,CMD_CHANNEL_USER_LEFT,0,leave_fields,2);
            }
        }
        if(c->member_count==0&&c->id!=1&&(c->flags&CHANNEL_PERMANENT)==0)c->used=0;
    }

    cr_tlv_out disconnected_field={1,uid,4};
    if(was_announced){
        for(size_t i=0;i<server->allocated_session_count;i++){
            cr_session*x=server->sessions[i];
            if(x&&x!=s&&session_ready_for_async(x))session_send(x,CMD_USER_DISCONNECTED,0,&disconnected_field,1);
        }
    }
    pthread_mutex_unlock(&server->mutex);
    if(was_authenticated){
        event_msg(s,"session","logout","disconnected");
        cr_state_record_disconnect(&server->state,s->mode);
    }
}

typedef struct cr_bot_command_rule {
    int enabled;
    char command[CR_BOT_COMMAND_MAX_BYTES + 1];
    char response[CR_BOT_RESPONSE_MAX_BYTES + 1];
} cr_bot_command_rule;

typedef struct cr_bot_configuration {
    int enabled;
    int avatar_configured;
    char avatar_path[128];
    int greet_new_users;
    char greeting_template[CR_BOT_GREETING_MAX_BYTES + 1];
    size_t command_rule_count;
    cr_bot_command_rule command_rules[CR_BOT_MAX_COMMAND_RULES];
} cr_bot_configuration;

static int bot_load_configuration(cr_server*s,cr_bot_configuration*out){
    if(!s||!out)return-1;
    memset(out,0,sizeof(*out));
    snprintf(out->greeting_template,sizeof(out->greeting_template),"%s",CR_BOT_DEFAULT_GREETING);
    if(access(s->bot_config_path,F_OK)!=0)return errno==ENOENT?0:-1;
    json_object*root=json_object_from_file(s->bot_config_path);
    if(!root||!json_object_is_type(root,json_type_object)){if(root)json_object_put(root);return-1;}
    json_object*enabled=NULL,*avatar=NULL,*greet=NULL,*greeting=NULL,*rules=NULL;
    if(json_object_object_get_ex(root,"enabled",&enabled)){
        if(!json_object_is_type(enabled,json_type_boolean)){json_object_put(root);return-1;}
        out->enabled=json_object_get_boolean(enabled)?1:0;
    }
    if(json_object_object_get_ex(root,"avatarPath",&avatar)){
        if(!json_object_is_type(avatar,json_type_string)){json_object_put(root);return-1;}
        const char*value=json_object_get_string(avatar);size_t n=value?strlen(value):0;
        if(n>=sizeof(out->avatar_path)){json_object_put(root);return-1;}
        out->avatar_configured=1;snprintf(out->avatar_path,sizeof(out->avatar_path),"%s",value?value:"");
    }
    if(json_object_object_get_ex(root,"greetNewUsers",&greet)){
        if(!json_object_is_type(greet,json_type_boolean)){json_object_put(root);return-1;}
        out->greet_new_users=json_object_get_boolean(greet)?1:0;
    }
    if(json_object_object_get_ex(root,"greetingTemplate",&greeting)){
        if(!json_object_is_type(greeting,json_type_string)){json_object_put(root);return-1;}
        const char*value=json_object_get_string(greeting);size_t n=value?(size_t)json_object_get_string_len(greeting):0;
        if(!n||n>CR_BOT_GREETING_MAX_BYTES||!valid_utf8_bytes((const uint8_t*)value,n)||memchr(value,0,n)||memchr(value,'\n',n)||memchr(value,'\r',n)){json_object_put(root);return-1;}
        memcpy(out->greeting_template,value,n);out->greeting_template[n]=0;
    }
    if(json_object_object_get_ex(root,"commandRules",&rules)){
        if(!json_object_is_type(rules,json_type_array)){json_object_put(root);return-1;}
        size_t count=json_object_array_length(rules);if(count>CR_BOT_MAX_COMMAND_RULES){json_object_put(root);return-1;}
        for(size_t i=0;i<count;i++){
            json_object*item=json_object_array_get_idx(rules,i),*renabled=NULL,*command=NULL,*response=NULL;
            if(!item||!json_object_is_type(item,json_type_object)||
               !json_object_object_get_ex(item,"enabled",&renabled)||!json_object_is_type(renabled,json_type_boolean)||
               !json_object_object_get_ex(item,"command",&command)||!json_object_is_type(command,json_type_string)||
               !json_object_object_get_ex(item,"response",&response)||!json_object_is_type(response,json_type_string)){json_object_put(root);return-1;}
            const char*c=json_object_get_string(command),*r=json_object_get_string(response);
            size_t cn=c?(size_t)json_object_get_string_len(command):0,rn=r?(size_t)json_object_get_string_len(response):0;
            if(!cn||cn>CR_BOT_COMMAND_MAX_BYTES||!rn||rn>CR_BOT_RESPONSE_MAX_BYTES||
               !valid_utf8_bytes((const uint8_t*)c,cn)||!valid_utf8_bytes((const uint8_t*)r,rn)||
               memchr(c,0,cn)||memchr(r,0,rn)||memchr(c,'\n',cn)||memchr(c,'\r',cn)||memchr(r,'\n',rn)||memchr(r,'\r',rn)){json_object_put(root);return-1;}
            cr_bot_command_rule*rule=&out->command_rules[out->command_rule_count++];rule->enabled=json_object_get_boolean(renabled)?1:0;
            memcpy(rule->command,c,cn);rule->command[cn]=0;memcpy(rule->response,r,rn);rule->response[rn]=0;
        }
    }
    json_object_put(root);return 0;
}

static int bot_store_enabled(cr_server*s,int enabled){
    if(!s||!s->bot_config_path[0])return-1;
    json_object*root=NULL;
    if(access(s->bot_config_path,F_OK)==0)root=json_object_from_file(s->bot_config_path);
    else if(errno==ENOENT)root=json_object_new_object();
    if(!root||!json_object_is_type(root,json_type_object)){if(root)json_object_put(root);return-1;}
    json_object_object_add(root,"enabled",json_object_new_boolean(enabled?1:0));
    char tmp[PATH_MAX];int n=snprintf(tmp,sizeof(tmp),"%s.tmp.%ld",s->bot_config_path,(long)getpid());int rc=-1;
    if(n>0&&(size_t)n<sizeof(tmp)&&json_object_to_file_ext(tmp,root,JSON_C_TO_STRING_PRETTY)==0){
        (void)chmod(tmp,0600);
        if(rename(tmp,s->bot_config_path)==0)rc=0;else unlink(tmp);
    }
    json_object_put(root);return rc;
}

static int bot_store_greeting(cr_server*s,int enabled,const uint8_t*template,size_t template_len){
    if(!s||!s->bot_config_path[0]||!template||!template_len||template_len>CR_BOT_GREETING_MAX_BYTES||
       !valid_utf8_bytes(template,template_len)||memchr(template,0,template_len)||memchr(template,'\n',template_len)||memchr(template,'\r',template_len))return-1;
    json_object*root=NULL;
    if(access(s->bot_config_path,F_OK)==0)root=json_object_from_file(s->bot_config_path);
    else if(errno==ENOENT)root=json_object_new_object();
    if(!root||!json_object_is_type(root,json_type_object)){if(root)json_object_put(root);return-1;}
    json_object_object_add(root,"greetNewUsers",json_object_new_boolean(enabled?1:0));
    json_object_object_add(root,"greetingTemplate",json_object_new_string_len((const char*)template,(int)template_len));
    char tmp[PATH_MAX];int n=snprintf(tmp,sizeof(tmp),"%s.tmp.%ld",s->bot_config_path,(long)getpid());int rc=-1;
    if(n>0&&(size_t)n<sizeof(tmp)&&json_object_to_file_ext(tmp,root,JSON_C_TO_STRING_PRETTY)==0){
        (void)chmod(tmp,0600);
        if(rename(tmp,s->bot_config_path)==0)rc=0;else unlink(tmp);
    }
    json_object_put(root);return rc;
}

static int bot_decode_command_rules(const uint8_t*data,size_t len,cr_bot_command_rule*out,size_t*out_count){
    if(!data||len<2||!out||!out_count) return -1;

    size_t off=0;
    uint16_t count=cr_read_be16(data);
    off=2;
    if(count>CR_BOT_MAX_COMMAND_RULES) return -1;

    for(uint16_t i=0;i<count;i++){
        if(off+3>len) return -1;
        uint8_t enabled=data[off++];
        if(enabled>1) return -1;

        uint16_t cn=cr_read_be16(data+off);
        off+=2;
        if(!cn||cn>CR_BOT_COMMAND_MAX_BYTES||off+cn+2>len) return -1;
        const uint8_t*c=data+off;
        off+=cn;

        uint16_t rn=cr_read_be16(data+off);
        off+=2;
        if(!rn||rn>CR_BOT_RESPONSE_MAX_BYTES||off+rn>len) return -1;
        const uint8_t*r=data+off;
        off+=rn;

        if(!valid_utf8_bytes(c,cn)||!valid_utf8_bytes(r,rn)||
           memchr(c,0,cn)||memchr(r,0,rn)||
           memchr(c,'\n',cn)||memchr(c,'\r',cn)||
           memchr(r,'\n',rn)||memchr(r,'\r',rn)) return -1;

        out[i].enabled=enabled?1:0;
        memcpy(out[i].command,c,cn);
        out[i].command[cn]=0;
        memcpy(out[i].response,r,rn);
        out[i].response[rn]=0;
    }

    if(off!=len) return -1;
    *out_count=count;
    return 0;
}

static int bot_encode_command_rules(const cr_bot_configuration*cfg,cr_buffer*out){
    if(!cfg||!out||cfg->command_rule_count>CR_BOT_MAX_COMMAND_RULES) return -1;
    cr_buffer_init(out);
    if(cr_buffer_append_u16(out,(uint16_t)cfg->command_rule_count)) return -1;

    for(size_t i=0;i<cfg->command_rule_count;i++){
        const cr_bot_command_rule*r=&cfg->command_rules[i];
        size_t cn=strlen(r->command);
        size_t rn=strlen(r->response);
        if(!cn||cn>CR_BOT_COMMAND_MAX_BYTES||!rn||rn>CR_BOT_RESPONSE_MAX_BYTES||
           cr_buffer_append_u8(out,r->enabled?1:0)||
           cr_buffer_append_string16(out,(const uint8_t*)r->command,cn)||
           cr_buffer_append_string16(out,(const uint8_t*)r->response,rn)){
            cr_buffer_free(out);
            return -1;
        }
    }
    return 0;
}

static int bot_read_string16_utf8(const uint8_t*data,size_t len,size_t*off,char*out,size_t cap,int allow_empty){
    if(!data||!off||!out||*off+2>len)return-1;
    uint16_t n=cr_read_be16(data+*off);*off+=2;
    if((!allow_empty&&!n)||n>=cap||*off+n>len)return-1;
    if(n&&(!valid_utf8_bytes(data+*off,n)||memchr(data+*off,0,n)||memchr(data+*off,'\n',n)||memchr(data+*off,'\r',n)))return-1;
    memcpy(out,data+*off,n);out[n]=0;*off+=n;return 0;
}

static int bot_decode_rss_feeds(const uint8_t*data,size_t len,cr_bot_rss_feed*out,size_t*out_count){
    if(!data||len<2||!out||!out_count)return-1;
    size_t off=0;uint16_t count=cr_read_be16(data);off=2;
    if(count>CR_BOT_RSS_MAX_FEEDS)return-1;
    for(uint16_t i=0;i<count;i++){
        if(off+10>len)return-1;
        cr_bot_rss_feed f;memset(&f,0,sizeof(f));
        f.enabled=data[off++];f.include_image=data[off++];
        f.channel_id=cr_read_be32(data+off);off+=4;
        f.poll_interval_minutes=cr_read_be16(data+off);off+=2;
        f.summary_characters=cr_read_be16(data+off);off+=2;
        if(bot_read_string16_utf8(data,len,&off,f.id,sizeof(f.id),0)||
           bot_read_string16_utf8(data,len,&off,f.name,sizeof(f.name),0)||
           bot_read_string16_utf8(data,len,&off,f.url,sizeof(f.url),0)||
           !cr_bot_rss_feed_valid(&f))return-1;
        out[i]=f;
    }
    if(off!=len) return -1;
    *out_count=count;
    return 0;
}

static int bot_encode_rss_feeds(const cr_bot_rss_feed*feeds,size_t count,cr_buffer*out){
    if(!out||(!feeds&&count)||count>CR_BOT_RSS_MAX_FEEDS)return-1;
    cr_buffer_init(out);if(cr_buffer_append_u16(out,(uint16_t)count))return-1;
    for(size_t i=0;i<count;i++){
        const cr_bot_rss_feed*f=&feeds[i];size_t idn=strlen(f->id),nn=strlen(f->name),un=strlen(f->url);
        if(!cr_bot_rss_feed_valid(f)||cr_buffer_append_u8(out,(uint8_t)f->enabled)||cr_buffer_append_u8(out,(uint8_t)f->include_image)||
           cr_buffer_append_u32(out,f->channel_id)||cr_buffer_append_u16(out,f->poll_interval_minutes)||cr_buffer_append_u16(out,f->summary_characters)||
           cr_buffer_append_string16(out,(const uint8_t*)f->id,idn)||cr_buffer_append_string16(out,(const uint8_t*)f->name,nn)||
           cr_buffer_append_string16(out,(const uint8_t*)f->url,un)){cr_buffer_free(out);return-1;}
    }
    return 0;
}

static int bot_encode_rss_preview(const cr_bot_rss_article*a,cr_buffer*out){
    if(!a||!out) return -1;
    cr_buffer_init(out);
    const char*values[4]={a->title,a->summary,a->link,a->image_url};
    for(size_t i=0;i<4;i++){size_t n=strlen(values[i]);if(n>UINT16_MAX||cr_buffer_append_string16(out,(const uint8_t*)values[i],n)){cr_buffer_free(out);return-1;}}
    return 0;
}

static int bot_store_command_rules(cr_server*s,const uint8_t*data,size_t len){
    if(!s||!s->bot_config_path[0]) return -1;

    cr_bot_command_rule rules[CR_BOT_MAX_COMMAND_RULES];
    memset(rules,0,sizeof(rules));
    size_t count=0;
    if(bot_decode_command_rules(data,len,rules,&count)) return -1;

    json_object*root=NULL;
    if(access(s->bot_config_path,F_OK)==0){
        root=json_object_from_file(s->bot_config_path);
    }else if(errno==ENOENT){
        root=json_object_new_object();
    }
    if(!root||!json_object_is_type(root,json_type_object)){
        if(root) json_object_put(root);
        return -1;
    }

    json_object*array=json_object_new_array();
    if(!array){
        json_object_put(root);
        return -1;
    }
    for(size_t i=0;i<count;i++){
        json_object*item=json_object_new_object();
        if(!item){
            json_object_put(array);
            json_object_put(root);
            return -1;
        }
        json_object_object_add(item,"enabled",json_object_new_boolean(rules[i].enabled));
        json_object_object_add(item,"command",json_object_new_string(rules[i].command));
        json_object_object_add(item,"response",json_object_new_string(rules[i].response));
        json_object_array_add(array,item);
    }
    json_object_object_add(root,"commandRules",array);

    char tmp[PATH_MAX];
    int n=snprintf(tmp,sizeof(tmp),"%s.tmp.%ld",s->bot_config_path,(long)getpid());
    int rc=-1;
    if(n>0&&(size_t)n<sizeof(tmp)&&json_object_to_file_ext(tmp,root,JSON_C_TO_STRING_PRETTY)==0){
        (void)chmod(tmp,0600);
        if(rename(tmp,s->bot_config_path)==0) rc=0;
        else unlink(tmp);
    }
    json_object_put(root);
    return rc;
}

static void bot_set_error(cr_server*s,const char*message){
    if(!s)return;
    snprintf(s->bot_last_error,sizeof(s->bot_last_error),"%s",message?message:"");
}

static int bot_avatar_png_valid(const uint8_t*data,size_t len){
    static const uint8_t sig[8]={0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a};
    if(!data||len<24||len>UINT16_MAX||memcmp(data,sig,sizeof(sig))||memcmp(data+12,"IHDR",4))return 0;
    return cr_read_be32(data+16)==128&&cr_read_be32(data+20)==128;
}

static int bot_apply_avatar(cr_server*s,const uint8_t*picture,size_t picture_len){
    char login[256]="";int same=0,found=0;
    pthread_mutex_lock(&s->state.mutex);
    for(size_t i=0;i<s->state.account_count;i++){
        cr_account*a=&s->state.accounts[i];if(strcasecmp(a->id,CR_LOCAL_BOT_ACCOUNT_ID))continue;
        found=1;snprintf(login,sizeof(login),"%s",a->login);
        same=a->picture_len==picture_len&&(!picture_len||!memcmp(a->picture,picture,picture_len));break;
    }
    pthread_mutex_unlock(&s->state.mutex);
    if(!found||!login[0]){bot_set_error(s,"Bot avatar could not find the persistent local Bot account");return-1;}
    if(same)return 0;
    if(cr_state_account_set_picture(&s->state,login,picture,picture_len)){bot_set_error(s,"Bot avatar could not be persisted");return-1;}
    refresh_connected_account_state(s);
    log_msg("Local Bot avatar %s",picture_len?"updated":"removed");
    return 0;
}

static int bot_sync_avatar(cr_server*s,const cr_bot_configuration*cfg){
    if(!s||!cfg||!cfg->avatar_configured)return 0;
    if(!cfg->avatar_path[0])return bot_apply_avatar(s,NULL,0);
    if(strcmp(cfg->avatar_path,"etc/carracho-bot-avatar.png")){
        bot_set_error(s,"Bot avatar path in carracho-bot.json is not supported");return-1;
    }
    struct stat st;if(stat(s->bot_avatar_path,&st)){bot_set_error(s,"Bot avatar file could not be read");return-1;}
    if(!S_ISREG(st.st_mode)||st.st_size<24||st.st_size>UINT16_MAX){bot_set_error(s,"Bot avatar must be a regular PNG no larger than 65535 bytes");return-1;}
    size_t len=(size_t)st.st_size;uint8_t*data=malloc(len);if(!data){bot_set_error(s,"Bot avatar allocation failed");return-1;}
    FILE*f=fopen(s->bot_avatar_path,"rb");if(!f){free(data);bot_set_error(s,"Bot avatar file could not be opened");return-1;}
    size_t got=fread(data,1,len,f);int read_error=ferror(f);fclose(f);
    if(read_error||got!=len){free(data);bot_set_error(s,"Bot avatar file could not be read completely");return-1;}
    if(!bot_avatar_png_valid(data,len)){free(data);bot_set_error(s,"Bot avatar must be a valid 128 x 128 PNG no larger than 65535 bytes");return-1;}
    int rc=bot_apply_avatar(s,data,len);free(data);return rc;
}

static int bot_connected(cr_server*s){
    int connected=0;
    pthread_mutex_lock(&s->mutex);
    connected=s->bot_session&&session_ready_for_async(s->bot_session);
    pthread_mutex_unlock(&s->mutex);
    return connected;
}

static void bot_write_status(cr_server*s){
    if(!s||!s->bot_status_path[0])return;
    char now[64];cr_now_iso8601(now);
    json_object*root=json_object_new_object();if(!root)return;
    json_object_object_add(root,"pid",json_object_new_int64((int64_t)getpid()));
    json_object_object_add(root,"updatedAt",json_object_new_string(now));
    json_object_object_add(root,"connected",json_object_new_boolean(bot_connected(s)));
    json_object_object_add(root,"pipePath",json_object_new_string(s->bot_pipe_path));
    if(s->bot_last_error[0])json_object_object_add(root,"lastError",json_object_new_string(s->bot_last_error));
    char tmp[PATH_MAX];int n=snprintf(tmp,sizeof(tmp),"%s.tmp.%ld",s->bot_status_path,(long)getpid());
    if(n>0&&(size_t)n<sizeof(tmp)&&json_object_to_file_ext(tmp,root,JSON_C_TO_STRING_PLAIN)==0){
        (void)chmod(tmp,0600);
        (void)rename(tmp,s->bot_status_path);
    }
    json_object_put(root);
}

static int bot_fifo_start(cr_server*s){
    if(!s)return-1;
    if(s->bot_fd>=0)return 0;
    struct stat st;
    if(lstat(s->bot_pipe_path,&st)==0){
        if(!S_ISFIFO(st.st_mode)){char message[512];snprintf(message,sizeof(message),"Bot interface cannot use %.400s because another file already exists there",s->bot_pipe_path);bot_set_error(s,message);return-1;}
        if(unlink(s->bot_pipe_path)){char message[512];snprintf(message,sizeof(message),"Bot interface could not replace its FIFO: %s",strerror(errno));bot_set_error(s,message);return-1;}
    }else if(errno!=ENOENT){char message[512];snprintf(message,sizeof(message),"Bot interface could not inspect its FIFO: %s",strerror(errno));bot_set_error(s,message);return-1;}
    if(mkfifo(s->bot_pipe_path,0600)){char message[512];snprintf(message,sizeof(message),"Bot interface could not create its FIFO: %s",strerror(errno));bot_set_error(s,message);return-1;}
    int fd=open(s->bot_pipe_path,O_RDWR|O_NONBLOCK);
    if(fd<0){char message[512];snprintf(message,sizeof(message),"Bot interface could not open its FIFO: %s",strerror(errno));bot_set_error(s,message);unlink(s->bot_pipe_path);return-1;}
    (void)chmod(s->bot_pipe_path,0600);
    s->bot_fd=fd;
    return 0;
}

static void bot_fifo_stop(cr_server*s){
    if(!s)return;
    if(s->bot_fd>=0){close(s->bot_fd);s->bot_fd=-1;}
    struct stat st;
    if(lstat(s->bot_pipe_path,&st)==0&&S_ISFIFO(st.st_mode))(void)unlink(s->bot_pipe_path);
}

static int connect_local_bot(cr_server*s){
    if(!s)return-1;
    cr_account account;memset(&account,0,sizeof(account));char bot_files_root_path[1025]="",bot_files_root_name[257]="Allgemein";
    pthread_mutex_lock(&s->state.mutex);
    int found=0;
    for(size_t i=0;i<s->state.account_count;i++){
        cr_account*a=&s->state.accounts[i];
        if(strcasecmp(a->id,CR_LOCAL_BOT_ACCOUNT_ID))continue;
        if(!a->local_login_only||!cr_account_has_permission(a,PERM_JOIN_CHAT))break;
        account=*a;account.picture=NULL;
        for(size_t gi=0;gi<s->state.account_group_count;gi++)if(!strcasecmp(s->state.account_groups[gi].id,a->group_id)){snprintf(bot_files_root_path,sizeof(bot_files_root_path),"%s",s->state.account_groups[gi].files_root_path);snprintf(bot_files_root_name,sizeof(bot_files_root_name),"%s",s->state.account_groups[gi].files_root_path[0]?s->state.account_groups[gi].files_root_name:"Allgemein");break;}
        if(a->picture_len){account.picture=malloc(a->picture_len);if(!account.picture){pthread_mutex_unlock(&s->state.mutex);bot_set_error(s,"Bot avatar allocation failed");return-1;}memcpy(account.picture,a->picture,a->picture_len);account.picture_len=a->picture_len;}
        found=1;break;
    }
    pthread_mutex_unlock(&s->state.mutex);
    if(!found){free(account.picture);bot_set_error(s,"Local Bot account is unavailable or does not have chat permission");return-1;}
    uint8_t nickname[256];size_t nickname_len=0;const char*display=account.name[0]?account.name:account.login;
    if(cr_utf8_to_macroman(display,nickname,sizeof(nickname),&nickname_len)||!nickname_len){free(account.picture);bot_set_error(s,"Local Bot account has no usable nickname");return-1;}
    if(nickname_len>64)nickname_len=64;

    pthread_mutex_lock(&s->mutex);
    if(s->bot_session){pthread_mutex_unlock(&s->mutex);free(account.picture);return 0;}
    size_t slot=CR_SERVER_MAX_SESSIONS;
    for(size_t i=0;i<s->allocated_session_count;i++)if(!s->sessions[i]){slot=i;break;}
    if(slot==CR_SERVER_MAX_SESSIONS&&s->allocated_session_count<CR_SERVER_MAX_SESSIONS)slot=s->allocated_session_count++;
    cr_channel*pub=channel_by_id_locked(s,1);
    if(slot==CR_SERVER_MAX_SESSIONS||!pub||pub->member_count>=CR_CHANNEL_MAX_MEMBERS){pthread_mutex_unlock(&s->mutex);free(account.picture);bot_set_error(s,"Bot could not be registered because the local session or Public conference is full");return-1;}
    cr_session*x=calloc(1,sizeof(*x));
    if(!x){pthread_mutex_unlock(&s->mutex);free(account.picture);bot_set_error(s,"Bot session allocation failed");return-1;}
    x->server=s;x->fd=-1;x->local_only=1;x->modern_transport=1;x->authenticated=1;x->announced=1;
    x->user_id=s->next_user_id++;x->mode=account.mode;x->personal=account.personal;x->permission_bits=account.permission_bits;
    snprintf(x->account_id,sizeof(x->account_id),"%s",account.id);snprintf(x->group_id,sizeof(x->group_id),"%s",account.group_id);
    snprintf(x->files_root_path,sizeof(x->files_root_path),"%s",bot_files_root_path);snprintf(x->files_root_name,sizeof(x->files_root_name),"%s",bot_files_root_name);
    x->group_color_rgb=account.color_rgb;x->has_group_color=account.has_color;
    snprintf(x->login,sizeof(x->login),"%s",account.login);snprintf(x->profile_name,sizeof(x->profile_name),"%s",account.name);snprintf(x->email,sizeof(x->email),"%s",account.email);snprintf(x->about,sizeof(x->about),"%s",account.about);
    /* The Bot is an in-process session, not a TCP client. Keep its visible peer identity fixed
       to IPv4 loopback so no configuration or future caller can redirect it off-host. */
    snprintf(x->peer_ip,sizeof(x->peer_ip),"%s",CR_BOT_LOOPBACK_PEER);memcpy(x->nickname,nickname,nickname_len);x->nickname_len=nickname_len;
    x->picture=account.picture;x->picture_len=account.picture_len;account.picture=NULL;account.picture_len=0;
    memcpy(x->status_message,"Local server bot",16);x->status_message_len=16;x->login_at=x->last_activity=time(NULL);
    if(pthread_mutex_init(&x->send_mutex,NULL)!=0){free(x->picture);free(x);pthread_mutex_unlock(&s->mutex);bot_set_error(s,"Bot session mutex initialization failed");return-1;}
    s->sessions[slot]=x;s->bot_session=x;uint8_t mode=x->mode==CR_MODE_ADMIN?CHANNEL_OPERATOR:0;
    pub->members[pub->member_count++]=(cr_channel_member){x->user_id,mode};
    pthread_mutex_unlock(&s->mutex);

    (void)cr_state_record_login_id(&s->state,x->account_id,x->mode);
    event_msg(x,"session","login","local-bot connected");broadcast_user_arrived(x);
    uint8_t cid[4],uid[4];cr_write_be32(cid,1);cr_write_be32(uid,x->user_id);cr_tlv_out joined[]={{CHANNEL_FIELD_ID,cid,4},{CHANNEL_FIELD_USER_ID,uid,4},{CHANNEL_FIELD_USER_MODE,&mode,1}};
    pthread_mutex_lock(&s->mutex);pub=channel_by_id_locked(s,1);if(pub)for(size_t i=0;i<pub->member_count;i++){if(pub->members[i].user_id==x->user_id)continue;cr_session*r=find_session_locked(s,pub->members[i].user_id);if(r)session_send(r,CMD_CHANNEL_USER_JOINED,0,joined,3);}pthread_mutex_unlock(&s->mutex);
    bot_set_error(s,"");log_msg("Local Bot account %s connected as user %u and joined Public",x->login,x->user_id);return 0;
}

static void disconnect_local_bot(cr_server*s){
    if(!s)return;
    pthread_mutex_lock(&s->mutex);cr_session*x=s->bot_session;s->bot_session=NULL;pthread_mutex_unlock(&s->mutex);
    if(!x)return;
    session_unregister(x);
    pthread_mutex_lock(&s->mutex);
    for(size_t i=0;i<s->allocated_session_count;i++)if(s->sessions[i]==x){s->sessions[i]=NULL;break;}
    while(s->allocated_session_count&&!s->sessions[s->allocated_session_count-1])s->allocated_session_count--;
    pthread_mutex_unlock(&s->mutex);
    free_joined_session(x);
    log_msg("Local Bot disconnected");
}

static int bot_line_blank(const uint8_t*data,size_t len){
    if(!data||!len)return 1;
    for(size_t i=0;i<len;i++)if(data[i]!=' '&&data[i]!='\t'&&data[i]!='\r'&&data[i]!='\n'&&data[i]!='\v'&&data[i]!='\f')return 0;
    return 1;
}

static int bot_encode_wire_text(const uint8_t*utf8,size_t utf8_len,uint8_t*wire,size_t wire_cap,size_t*wire_len,int*tagged,char*text,size_t text_cap){
    if(!utf8||!utf8_len||utf8_len>=text_cap||
       !valid_utf8_bytes(utf8,utf8_len)||memchr(utf8,0,utf8_len)||bot_line_blank(utf8,utf8_len)) return -1;

    memcpy(text,utf8,utf8_len);
    text[utf8_len]=0;

    uint8_t classic[0x8000];
    size_t classic_len=0;
    char roundtrip[0x18001];
    if(cr_utf8_to_macroman(text,classic,sizeof(classic),&classic_len)==0&&
       classic_len<=wire_cap&&
       cr_macroman_to_utf8(classic,classic_len,roundtrip,sizeof(roundtrip))==0&&
       !strcmp(roundtrip,text)){
        memcpy(wire,classic,classic_len);
        *wire_len=classic_len;
        *tagged=0;
        return 0;
    }

    if(utf8_len+3>wire_cap) return -1;
    wire[0]=0xef;
    wire[1]=0xbb;
    wire[2]=0xbf;
    memcpy(wire+3,utf8,utf8_len);
    *wire_len=utf8_len+3;
    *tagged=1;
    return 0;
}

static int bot_post_channel_message(cr_server*s,uint32_t channel_id,const uint8_t*utf8,size_t utf8_len,const char*source){
    if(!s||utf8_len>0x800) return -1;

    char text[0x801];
    uint8_t wire[0x800];
    size_t wire_len=0;
    int tagged=0;
    if(bot_encode_wire_text(utf8,utf8_len,wire,sizeof(wire),&wire_len,&tagged,text,sizeof(text))||
       validate_youtube_tokens(wire,wire_len,4)) return -1;

    pthread_mutex_lock(&s->mutex);
    cr_session*bot=s->bot_session;
    cr_channel*c=channel_by_id_locked(s,channel_id);
    if(!bot||!c||!account_perm(bot,PERM_JOIN_CHAT)){
        pthread_mutex_unlock(&s->mutex);
        return -1;
    }

    int idx=channel_member_index(c,bot->user_id);
    uint8_t mode=bot->mode==CR_MODE_ADMIN?CHANNEL_OPERATOR:0;
    if(idx<0){
        if(c->member_count>=CR_CHANNEL_MAX_MEMBERS){
            pthread_mutex_unlock(&s->mutex);
            return -1;
        }
        uint8_t cid_join[4],uid_join[4];
        cr_write_be32(cid_join,channel_id);
        cr_write_be32(uid_join,bot->user_id);
        c->members[c->member_count++]=(cr_channel_member){bot->user_id,mode};
        cr_tlv_out joined[]={{CHANNEL_FIELD_ID,cid_join,4},{CHANNEL_FIELD_USER_ID,uid_join,4},{CHANNEL_FIELD_USER_MODE,&mode,1}};
        for(size_t i=0;i<c->member_count;i++){
            if(c->members[i].user_id==bot->user_id) continue;
            cr_session*x=find_session_locked(s,c->members[i].user_id);
            if(x) session_send(x,CMD_CHANNEL_USER_JOINED,0,joined,3);
        }
        idx=channel_member_index(c,bot->user_id);
    }

    if(idx<0){
        pthread_mutex_unlock(&s->mutex);
        return -1;
    }
    mode=c->members[idx].mode;
    if((c->flags&CHANNEL_RESTRICTED_CHAT)&&!(mode&(CHANNEL_OPERATOR|CHANNEL_SPEECH))){
        pthread_mutex_unlock(&s->mutex);
        return -2;
    }

    bot->last_activity=time(NULL);
    if(bot->sleeping){
        bot->sleeping=0;
        broadcast_presence_state_locked(s,bot->user_id,0);
    }

    uint8_t cid[4],uid[4],attribute=0;
    cr_write_be32(cid,channel_id);
    cr_write_be32(uid,bot->user_id);
    for(size_t i=0;i<c->member_count;i++){
        cr_session*x=find_session_locked(s,c->members[i].user_id);
        if(!x) continue;

        const uint8_t*out=wire;
        size_t out_len=wire_len;
        uint8_t legacy[0x800];
        if(tagged&&!x->modern_transport){
            size_t classic_len=0;
            if(classic_text_describing_emoji(wire,wire_len,legacy,sizeof(legacy),&classic_len)||!classic_len) continue;
            out=legacy;
            out_len=classic_len;
        }
        cr_tlv_out fields[]={{CHANNEL_FIELD_ID,cid,4},{CHANNEL_FIELD_USER_ID,uid,4},{CHANNEL_FIELD_MESSAGE,out,(uint16_t)out_len},{CHANNEL_FIELD_ATTRIBUTE,&attribute,1}};
        (void)session_send(x,CMD_CHANNEL_CHAT,0,fields,4);
    }
    pthread_mutex_unlock(&s->mutex);

    (void)cr_state_stat_add(&s->state,"totalMessages",1);
    char detail[128];
    snprintf(detail,sizeof(detail),"channel=%u source=%s",channel_id,source&&*source?source:"bot");
    event_msg(bot,"chat","message",detail);
    return 0;
}

static int bot_post_message(cr_server*s,const uint8_t*utf8,size_t utf8_len,const char*source){
    return bot_post_channel_message(s,1,utf8,utf8_len,source);
}

static int bot_post_private_message(cr_server*s,cr_session*target,const uint8_t*utf8,size_t utf8_len,const char*source){
    if(!s||!target||utf8_len>CR_BOT_RESPONSE_MAX_BYTES) return -1;

    char text[CR_BOT_RESPONSE_MAX_BYTES+1];
    uint8_t wire[CR_BOT_RESPONSE_MAX_BYTES+3];
    size_t wire_len=0;
    int tagged=0;
    if(bot_encode_wire_text(utf8,utf8_len,wire,sizeof(wire),&wire_len,&tagged,text,sizeof(text))) return -1;

    pthread_mutex_lock(&s->mutex);
    cr_session*bot=s->bot_session;
    if(!bot){
        pthread_mutex_unlock(&s->mutex);
        return -1;
    }
    uint32_t bot_uid=bot->user_id;
    bot->last_activity=time(NULL);
    if(bot->sleeping){
        bot->sleeping=0;
        broadcast_presence_state_locked(s,bot_uid,0);
    }
    pthread_mutex_unlock(&s->mutex);

    const uint8_t*out=wire;
    size_t out_len=wire_len;
    uint8_t legacy[CR_BOT_RESPONSE_MAX_BYTES];
    if(tagged&&!target->modern_transport){
        size_t classic_len=0;
        if(classic_text_describing_emoji(wire,wire_len,legacy,sizeof(legacy),&classic_len)||!classic_len) return -1;
        out=legacy;
        out_len=classic_len;
    }

    uint8_t uid[4];
    cr_write_be32(uid,bot_uid);
    cr_tlv_out fields[]={{1,uid,4},{2,out,(uint16_t)out_len}};
    if(session_send(target,CMD_PRIVATE_MESSAGE,0,fields,2)) return -1;

    (void)cr_state_stat_add(&s->state,"totalMessages",1);
    char detail[128];
    snprintf(detail,sizeof(detail),"source=%s",source&&*source?source:"bot");
    event_msg(bot,"messages","private-message",detail);
    return 0;
}

static int bot_expand_template(const char*template,const cr_session*target,char*out,size_t cap,size_t*out_len){
    if(!template||!target||!out||!cap||!out_len) return -1;

    char name[1024];
    if(cr_macroman_to_utf8(target->nickname,target->nickname_len,name,sizeof(name))){
        snprintf(name,sizeof(name),"%s",target->login);
    }

    const char*parts[2]={name,target->login};
    const char*tokens[2]={"{name}","{login}"};
    const char*p=template;
    size_t used=0;
    while(*p){
        int replaced=0;
        for(size_t i=0;i<2;i++){
            size_t tn=strlen(tokens[i]);
            if(!strncmp(p,tokens[i],tn)){
                size_t n=strlen(parts[i]);
                if(used+n>=cap) return -1;
                memcpy(out+used,parts[i],n);
                used+=n;
                p+=tn;
                replaced=1;
                break;
            }
        }
        if(replaced) continue;
        if(used+1>=cap) return -1;
        out[used++]=*p++;
    }
    out[used]=0;
    *out_len=used;
    return used?0:-1;
}

static int bot_expand_greeting(const cr_bot_configuration*cfg,const cr_session*target,char*out,size_t cap,size_t*out_len){
    return cfg?bot_expand_template(cfg->greeting_template,target,out,cap,out_len):-1;
}

static int bot_decode_wire_text(const uint8_t*wire,size_t wire_len,char*out,size_t cap){
    if(!wire||!wire_len||!out||!cap) return -1;
    if(wire_len>=3&&wire[0]==0xef&&wire[1]==0xbb&&wire[2]==0xbf){
        size_t n=wire_len-3;
        if(!n||n>=cap||!valid_utf8_bytes(wire+3,n)||memchr(wire+3,0,n)) return -1;
        memcpy(out,wire+3,n);
        out[n]=0;
        return 0;
    }
    return cr_macroman_to_utf8(wire,wire_len,out,cap);
}

static char*bot_trim_ascii(char*s){
    while(*s==' '||*s=='\t'||*s=='\r'||*s=='\n') s++;
    size_t n=strlen(s);
    while(n&&(s[n-1]==' '||s[n-1]=='\t'||s[n-1]=='\r'||s[n-1]=='\n')) s[--n]=0;
    return s;
}

static const char*bot_extract_command(const uint8_t*wire,size_t wire_len,int require_prefix,char*storage,size_t cap){
    if(bot_decode_wire_text(wire,wire_len,storage,cap)) return NULL;
    char*text=bot_trim_ascii(storage);
    if(!*text) return NULL;

    if(require_prefix){
        if(*text!='#') return NULL;
        char*command=bot_trim_ascii(text+1);
        return *command?command:NULL;
    }
    return text;
}

static int bot_match_command(cr_server*s,cr_session*sender,const uint8_t*wire,size_t wire_len,int require_prefix,char*out,size_t cap,size_t*out_len){
    if(!s||!sender||sender->local_only||!bot_connected(s)) return 0;

    char input[0x8001];
    const char*command=bot_extract_command(wire,wire_len,require_prefix,input,sizeof(input));
    if(!command) return 0;

    cr_bot_configuration cfg;
    if(bot_load_configuration(s,&cfg)) return 0;
    for(size_t i=0;i<cfg.command_rule_count;i++){
        cr_bot_command_rule*rule=&cfg.command_rules[i];
        if(!rule->enabled||strcasecmp(command,rule->command)) continue;
        if(bot_expand_template(rule->response,sender,out,cap,out_len)) return 0;
        return 1;
    }
    return 0;
}

static void bot_maybe_reply_channel(cr_session*sender,uint32_t channel_id,const uint8_t*wire,size_t wire_len){
    char response[0x801];
    size_t n=0;
    if(bot_match_command(sender->server,sender,wire,wire_len,1,response,sizeof(response),&n)==1){
        int rc=bot_post_channel_message(sender->server,channel_id,(const uint8_t*)response,n,"command");
        if(rc) log_msg("Local Bot command reply failed in channel %u (error %d)",channel_id,rc);
    }
}

static void bot_maybe_reply_private(cr_session*sender,const uint8_t*wire,size_t wire_len){
    char response[0x801];
    size_t n=0;
    if(bot_match_command(sender->server,sender,wire,wire_len,0,response,sizeof(response),&n)==1){
        int rc=bot_post_private_message(sender->server,sender,(const uint8_t*)response,n,"command");
        if(rc) log_msg("Local Bot private command reply failed (error %d)",rc);
    }
}

static void bot_maybe_greet_session(cr_session*target){
    if(!target||target->local_only||target->bot_greeting_sent) return;
    target->bot_greeting_sent=1;

    cr_bot_configuration cfg;
    if(bot_load_configuration(target->server,&cfg)||!cfg.greet_new_users||!bot_connected(target->server)) return;

    char text[0x801];
    size_t text_len=0;
    if(bot_expand_greeting(&cfg,target,text,sizeof(text),&text_len)){
        log_msg("Local Bot greeting could not be rendered for user %u",target->user_id);
        return;
    }
    int rc=bot_post_message(target->server,(const uint8_t*)text,text_len,"greeting");
    if(rc) log_msg("Local Bot greeting failed for user %u (error %d)",target->user_id,rc);
    else log_msg("Local Bot greeted user %u in Public",target->user_id);
}

static void *bot_thread_main(void*opaque){
    cr_server*s=opaque;uint8_t pending[128*1024];size_t pending_len=0;time_t last_status=0;
    while(!s->stop){
        cr_bot_configuration cfg;int config_ok=bot_load_configuration(s,&cfg)==0;int enabled=config_ok?cfg.enabled:0;
        if(!config_ok){
            bot_set_error(s,"Bot configuration is invalid or unreadable");
        }else if(enabled){
            if(s->bot_fd<0&&bot_fifo_start(s)==0&&connect_local_bot(s)!=0)bot_fifo_stop(s);
            else if(s->bot_fd>=0&&!bot_connected(s)&&connect_local_bot(s)!=0)bot_fifo_stop(s);
            if(bot_sync_avatar(s,&cfg)==0&&bot_connected(s)&&!strncmp(s->bot_last_error,"Bot avatar",10))bot_set_error(s,"");
        }else{
            disconnect_local_bot(s);bot_fifo_stop(s);pending_len=0;
            if(bot_sync_avatar(s,&cfg)==0)bot_set_error(s,"");
        }

        if(enabled&&s->bot_fd>=0&&bot_connected(s)){
            struct pollfd pfd={.fd=s->bot_fd,.events=POLLIN};int ready=poll(&pfd,1,250);
            if(ready>0&&(pfd.revents&POLLIN)){
                uint8_t buf[4096];
                for(;;){ssize_t n=read(s->bot_fd,buf,sizeof(buf));if(n>0){if(pending_len+(size_t)n>sizeof(pending)){pending_len=0;bot_set_error(s,"Bot interface discarded an oversized input line");break;}memcpy(pending+pending_len,buf,(size_t)n);pending_len+=(size_t)n;continue;}if(n<0&&errno==EINTR)continue;break;}
                for(;;){uint8_t*nl=memchr(pending,'\n',pending_len);if(!nl)break;size_t line_len=(size_t)(nl-pending);if(line_len&&pending[line_len-1]=='\r')line_len--;if(line_len){int rc=bot_post_message(s,pending,line_len,"fifo");if(rc==-2)bot_set_error(s,"Bot cannot speak in the restricted Public conference");else if(rc)bot_set_error(s,"Bot interface rejected an invalid or oversized UTF-8 line");else bot_set_error(s,"");}size_t consumed=(size_t)(nl-pending)+1;memmove(pending,pending+consumed,pending_len-consumed);pending_len-=consumed;}
            }else if(ready<0&&errno!=EINTR){char message[512];snprintf(message,sizeof(message),"Bot interface poll failed: %s",strerror(errno));bot_set_error(s,message);}
        }else sleep_seconds(0.25);

        time_t now=time(NULL);if(now!=last_status){bot_write_status(s);last_status=now;}
    }
    disconnect_local_bot(s);bot_fifo_stop(s);bot_write_status(s);return NULL;
}

static int handle_server_info(cr_session*s,const cr_packet*p){
    uint8_t a[1024],b[1024],c[1024],d[CR_MAX_IDENTITY_TEXT+1],uptime[4],max_total[2],active_total[2],max_user[2],active_user[2];
    const uint8_t version[]="Carracho Server 1.0";
    size_t an=0,bn=0,cn=0,dn=0;uint16_t limit_total=0,limit_user=0;
    pthread_mutex_lock(&s->server->state.mutex);
    int fail=cr_utf8_to_macroman(s->server->state.identity.name,a,sizeof(a),&an)||
             cr_utf8_to_macroman(s->server->state.identity.location,b,sizeof(b),&bn)||
             cr_utf8_to_macroman(s->server->state.identity.operator_name,c,sizeof(c),&cn)||
             cr_utf8_to_macroman(s->server->state.identity.description,d,sizeof(d),&dn);
    limit_total=s->server->state.advanced.max_simultaneous_file_transfers;
    limit_user=s->server->state.advanced.max_file_transfers_per_user;
    pthread_mutex_unlock(&s->server->state.mutex);
    if(fail)return send_error(s,p->transaction_id,200);
    size_t total=0,user=0;pthread_mutex_lock(&s->server->mutex);total=s->server->active_file_transfers;
    for(size_t i=0;i<CR_SERVER_MAX_ACTIVE_TRANSFERS;i++)if(s->server->active_transfers[i].used&&s->server->active_transfers[i].user_id==s->user_id)user++;
    pthread_mutex_unlock(&s->server->mutex);
    time_t now=time(NULL);double sec=difftime(now,s->server->started_at);if(sec<0)sec=0;
    uint64_t ticks=(uint64_t)(sec*60.0);if(ticks>UINT32_MAX)ticks=UINT32_MAX;cr_write_be32(uptime,(uint32_t)ticks);
    cr_write_be16(max_total,limit_total);cr_write_be16(max_user,limit_user);
    cr_write_be16(active_total,(uint16_t)(total>UINT16_MAX?UINT16_MAX:total));cr_write_be16(active_user,(uint16_t)(user>UINT16_MAX?UINT16_MAX:user));
    cr_tlv_out f[]={{2,a,(uint16_t)an},{6,b,(uint16_t)bn},{7,c,(uint16_t)cn},{8,d,(uint16_t)dn},
                    {SERVER_INFO_FIELD_SOFTWARE_VERSION,version,(uint16_t)(sizeof(version)-1)},{SERVER_INFO_FIELD_UPTIME_TICKS,uptime,4},
                    {SERVER_INFO_FIELD_MAX_TRANSFERS,max_total,2},{SERVER_INFO_FIELD_ACTIVE_TRANSFERS,active_total,2},
                    {SERVER_INFO_FIELD_MAX_USER_TRANSFERS,max_user,2},{SERVER_INFO_FIELD_ACTIVE_USER_TRANSFERS,active_user,2}};
    return session_send(s,CMD_SERVER_INFO,p->transaction_id,f,10);
}
static int handle_directory(cr_session*s,const cr_packet*p){const cr_tlv*path=cr_packet_field(p,1);const uint8_t*pv=path?path->value:NULL;size_t pn=path?path->length:0;cr_buffer listing,labels;if(encode_directory(s->server,s,pv,pn,&listing,&labels)){cr_buffer_free(&listing);cr_buffer_free(&labels);return send_error(s,p->transaction_id,200);}if(listing.len>UINT16_MAX||labels.len>UINT16_MAX){cr_buffer_free(&listing);cr_buffer_free(&labels);return send_error(s,p->transaction_id,200);}cr_tlv_out f[2];size_t n=0;f[n++]=(cr_tlv_out){2,listing.data,(uint16_t)listing.len};if(s->modern_transport)f[n++]=(cr_tlv_out){DIRECTORY_LABELS_FIELD,labels.data,(uint16_t)labels.len};int rc=session_send(s,CMD_DIRECTORY,p->transaction_id,f,n);cr_buffer_free(&listing);cr_buffer_free(&labels);return rc;}
static int handle_channel_list(cr_session*s,const cr_packet*p){cr_buffer b;if(encode_channel_list(s->server,&b))return-1;if(b.len>UINT16_MAX){cr_buffer_free(&b);return send_error(s,p->transaction_id,200);}cr_tlv_out f={0x0a,b.data,(uint16_t)b.len};int rc=session_send(s,CMD_CHANNEL_LIST,p->transaction_id,&f,1);cr_buffer_free(&b);return rc;}
static int handle_newsgroups(cr_session*s,const cr_packet*p){cr_buffer b;cr_buffer_init(&b);pthread_mutex_lock(&s->server->state.mutex);size_t count=0;for(size_t i=0;i<s->server->state.newsgroup_count;i++){cr_newsgroup*g=&s->server->state.newsgroups[i];int visible=s->mode==CR_MODE_ADMIN?g->admin_read:s->mode==CR_MODE_ACCOUNT?g->account_read:g->guest_read;if(visible)count++;}int fail=cr_buffer_append_u32(&b,(uint32_t)count);for(size_t i=0;!fail&&i<s->server->state.newsgroup_count;i++){cr_newsgroup*g=&s->server->state.newsgroups[i];int visible=s->mode==CR_MODE_ADMIN?g->admin_read:s->mode==CR_MODE_ACCOUNT?g->account_read:g->guest_read;if(!visible)continue;uint8_t name[1024];size_t n=0;if(cr_utf8_to_macroman(g->name,name,sizeof(name),&n)||cr_buffer_append_string16(&b,name,n))fail=1;}pthread_mutex_unlock(&s->server->state.mutex);if(fail||b.len>UINT16_MAX){cr_buffer_free(&b);return send_error(s,p->transaction_id,200);}cr_tlv_out f={1,b.data,(uint16_t)b.len};int rc=session_send(s,CMD_NEWSGROUP_LIST_REPLY,p->transaction_id,&f,1);cr_buffer_free(&b);return rc;}

static int handle_channel_join(cr_session*s,const cr_packet*p){if(!account_perm(s,PERM_JOIN_CHAT))return send_error(s,p->transaction_id,2);const cr_tlv*id=cr_packet_field(p,CHANNEL_FIELD_ID),*name=cr_packet_field(p,CHANNEL_FIELD_NAME),*pw=cr_packet_field(p,CHANNEL_FIELD_PASSWORD);uint32_t requested=id&&id->length==4?cr_read_be32(id->value):0;const uint8_t*nv=name?name->value:NULL;size_t nn=name?name->length:0;const uint8_t*pv=pw?pw->value:NULL;size_t pn=pw?pw->length:0;if(nn>64||pn>32||(!requested&&!nn))return send_error(s,p->transaction_id,200);
    cr_server*server=s->server;pthread_mutex_lock(&server->mutex);size_t joined=0;for(size_t i=0;i<CR_SERVER_MAX_CHANNELS;i++)if(server->channels[i].used&&channel_member_index(&server->channels[i],s->user_id)>=0)joined++;if(joined>=6){pthread_mutex_unlock(&server->mutex);return send_error(s,p->transaction_id,0xd1);}cr_channel*c=requested?channel_by_id_locked(server,requested):NULL;if(!c&&!requested){for(size_t i=0;i<CR_SERVER_MAX_CHANNELS;i++){cr_channel*x=&server->channels[i];if(x->used&&x->name_len==nn&&!strncasecmp((const char*)x->name,(const char*)nv,nn)){c=x;break;}}}if(!c&&nn)c=allocate_channel_locked(server,nv,nn,pv,pn);if(!c){pthread_mutex_unlock(&server->mutex);return send_error(s,p->transaction_id,200);}if(c->password_len&&(c->password_len!=pn||memcmp(c->password,pv,pn))){pthread_mutex_unlock(&server->mutex);return send_error(s,p->transaction_id,0xca);}if(channel_member_index(c,s->user_id)>=0){pthread_mutex_unlock(&server->mutex);return send_error(s,p->transaction_id,0xce);}if(c->member_count>=CR_CHANNEL_MAX_MEMBERS){pthread_mutex_unlock(&server->mutex);return send_error(s,p->transaction_id,200);}uint8_t mode=0;if((c->member_count==0&&c->id!=1)||(c->id==1&&s->mode==CR_MODE_ADMIN))mode|=CHANNEL_OPERATOR;c->members[c->member_count++]=(cr_channel_member){s->user_id,mode};cr_buffer members;encode_channel_members(c,&members);uint8_t cid[4],settings[2];cr_write_be32(cid,c->id);cr_write_be16(settings,c->flags);uint32_t channel_id=c->id;uint8_t cname[64],topic[256];size_t cname_n=c->name_len,topic_n=c->topic_len;memcpy(cname,c->name,cname_n);memcpy(topic,c->topic,topic_n);uint8_t uid[4];cr_write_be32(uid,s->user_id);cr_tlv_out joinedf[]={{CHANNEL_FIELD_ID,cid,4},{CHANNEL_FIELD_USER_ID,uid,4},{CHANNEL_FIELD_USER_MODE,&mode,1}};for(size_t i=0;i<c->member_count;i++){if(c->members[i].user_id==s->user_id)continue;cr_session*x=find_session_locked(server,c->members[i].user_id);if(x)session_send(x,CMD_CHANNEL_USER_JOINED,0,joinedf,3);}pthread_mutex_unlock(&server->mutex);
    cr_tlv_out f[]={{CHANNEL_FIELD_ID,cid,4},{CHANNEL_FIELD_NAME,cname,(uint16_t)cname_n},{CHANNEL_FIELD_TOPIC,topic,(uint16_t)topic_n},{CHANNEL_FIELD_MEMBERS,members.data,(uint16_t)members.len},{CHANNEL_FIELD_SETTINGS,settings,2}};int rc=session_send(s,CMD_CHANNEL_JOIN,p->transaction_id,f,5);cr_buffer_free(&members);if(channel_id==1)bot_maybe_greet_session(s);log_msg("Channel %u joined by user %u",channel_id,s->user_id);return rc;}
static int handle_channel_leave(cr_session*s,const cr_packet*p){const cr_tlv*id=cr_packet_field(p,CHANNEL_FIELD_ID);if(!id||id->length!=4)return send_error(s,p->transaction_id,200);uint32_t cid=cr_read_be32(id->value);uint8_t cb[4],ub[4];cr_write_be32(cb,cid);cr_write_be32(ub,s->user_id);cr_tlv_out f[]={{CHANNEL_FIELD_ID,cb,4},{CHANNEL_FIELD_USER_ID,ub,4}};pthread_mutex_lock(&s->server->mutex);cr_channel*c=channel_by_id_locked(s->server,cid);if(c){int idx=channel_member_index(c,s->user_id);if(idx>=0){memmove(&c->members[idx],&c->members[idx+1],(c->member_count-(size_t)idx-1)*sizeof(c->members[0]));c->member_count--;for(size_t i=0;i<c->member_count;i++){cr_session*x=find_session_locked(s->server,c->members[i].user_id);if(x)session_send(x,CMD_CHANNEL_USER_LEFT,0,f,2);}if(c->member_count==0&&c->id!=1&&(c->flags&CHANNEL_PERMANENT)==0)c->used=0;}}pthread_mutex_unlock(&s->server->mutex);return session_send(s,CMD_CHANNEL_LEAVE,p->transaction_id,NULL,0);}

static int media_uuid_text_valid(const char*s){if(!s||strlen(s)!=36)return 0;for(int i=0;i<36;i++){if(i==8||i==13||i==18||i==23){if(s[i]!='-')return 0;}else if(!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f')||(s[i]>='A'&&s[i]<='F')))return 0;}return 1;}
static int extract_media_ids(const uint8_t*data,size_t len,char ids[][37],size_t max,size_t*out_count){
    static const char prefix[]="[[carracho-image:";const size_t pn=sizeof(prefix)-1;size_t count=0;
    for(size_t i=0;i+pn+36+2<=len;i++){if(memcmp(data+i,prefix,pn))continue;char id[37];memcpy(id,data+i+pn,36);id[36]='\0';if(data[i+pn+36]!=']'||data[i+pn+37]!=']'||!media_uuid_text_valid(id))continue;int dup=0;for(size_t j=0;j<count;j++)if(!strcasecmp(ids[j],id)){dup=1;break;}if(!dup){if(count>=max)return-1;for(int k=0;k<36;k++)ids[count][k]=(char)tolower((unsigned char)id[k]);ids[count][36]='\0';count++;}i+=pn+37;}
    *out_count=count;return 0;
}
static int media_message_id(char out[33]){uint8_t b[16];if(RAND_bytes(b,sizeof(b))!=1)return-1;for(size_t i=0;i<16;i++)snprintf(out+i*2,3,"%02x",b[i]);return 0;}

static int bot_rss_html_escape(const char*src,char*out,size_t cap,int attribute){
    if(!src||!out||!cap) return -1;
    size_t used=0;
    for(const unsigned char*p=(const unsigned char*)src;*p;p++){
        const char*replacement=NULL;
        if(*p=='&')replacement="&amp;";else if(*p=='<')replacement="&lt;";else if(*p=='>')replacement="&gt;";else if(attribute&&*p=='\"')replacement="&quot;";
        if(replacement){size_t n=strlen(replacement);if(used+n>=cap)return-1;memcpy(out+used,replacement,n);used+=n;}
        else{if(used+1>=cap)return-1;out[used++]=(char)*p;}
    }
    out[used]=0;return 0;
}

static void bot_rss_shorten_utf8(char*s){
    if(!s||!*s) return;
    size_t n=strlen(s),target=n*3/4;
    if(target<80) target=n>80?80:n;
    while(target&&(((unsigned char)s[target]&0xc0u)==0x80u))target--;
    s[target]=0;if(target&&target+3<CR_BOT_RSS_SUMMARY_MAX*4)strcat(s,"…");
}

static int bot_publish_rss_article_to_server(cr_server*s,const cr_bot_rss_feed*feed,const cr_bot_rss_article*article){
    if(!s||!feed||!article||!bot_connected(s))return-1;
    char media_token[96]="";
    if(feed->include_image&&article->image_data&&article->image_len){
        char media_id[37],scope[32],message_id[33];snprintf(scope,sizeof(scope),"%u",feed->channel_id);
        if(!cr_media_store_pending(&s->media,CR_LOCAL_BOT_ACCOUNT_ID,article->image_filename[0]?article->image_filename:"rss-image",article->image_data,article->image_len,media_id)&&
           !media_message_id(message_id)&&
           !cr_media_store_bind(&s->media,media_id,CR_LOCAL_BOT_ACCOUNT_ID,CR_MEDIA_KIND_CHAT,scope,message_id,time(NULL)+7*24*60*60)){
            snprintf(media_token,sizeof(media_token),"[[carracho-image:%s]]\n",media_id);
        }
    }
    char title[CR_BOT_RSS_TITLE_MAX*8+64],link_text[CR_BOT_RSS_URL_MAX*6+64],link_attr[CR_BOT_RSS_URL_MAX*6+64];
    if(bot_rss_html_escape(article->title,title,sizeof(title),0)||bot_rss_html_escape(article->link,link_text,sizeof(link_text),0)||bot_rss_html_escape(article->link,link_attr,sizeof(link_attr),1))return-1;
    char summary[sizeof(article->summary)];snprintf(summary,sizeof(summary),"%s",article->summary);
    for(int attempt=0;attempt<10;attempt++){
        char escaped_summary[CR_BOT_RSS_SUMMARY_MAX*8+64];if(bot_rss_html_escape(summary,escaped_summary,sizeof(escaped_summary),0))return-1;
        char message[0x801];int n=snprintf(message,sizeof(message),"%s<b>%s</b>%s%s\n<a href=\"%s\">%s</a>",media_token,title,*escaped_summary?"\n":"",escaped_summary,link_attr,link_text);
        if(n>0&&n<=0x800){int rc=bot_post_channel_message(s,feed->channel_id,(const uint8_t*)message,(size_t)n,"rss");if(!rc)log_msg("Bot RSS %s posted: %s",feed->name,article->title);return rc;}
        if(!*summary) break;
        if(strlen(summary)<=80) summary[0]=0;
        else bot_rss_shorten_utf8(summary);
    }
    log_msg("Bot RSS %s article was too large for a conference message",feed->name);return-1;
}

static int bot_publish_rss_article(void*opaque,const cr_bot_rss_feed*feed,const cr_bot_rss_article*article){
    return bot_publish_rss_article_to_server((cr_server*)opaque,feed,article);
}

static void bot_rss_log_callback(void*opaque,const char*message){(void)opaque;if(message&&*message)log_msg("%s",message);}

static void *bot_rss_thread_main(void*opaque){
    cr_server*s=opaque;time_t next=time(NULL)+5;
    while(!s->stop){
        time_t now=time(NULL);
        if(now>=next){
            if(bot_connected(s)&&cr_bot_rss_poll(s->bot_config_path,s->bot_rss_db_path,bot_publish_rss_article,bot_rss_log_callback,s))log_msg("Bot RSS poll failed");
            next=now+30;
        }
        sleep_seconds(1.0);
    }
    return NULL;
}
static int validate_youtube_tokens(const uint8_t*data,size_t len,size_t maximum){
    static const char prefix[]="[[carracho-youtube:";const size_t pn=sizeof(prefix)-1;size_t count=0;
    for(size_t i=0;i+pn<=len;i++){
        if(memcmp(data+i,prefix,pn))continue;
        if(i+pn+11+2>len)return-1;
        for(size_t j=0;j<11;j++){uint8_t c=data[i+pn+j];if(!((c>='A'&&c<='Z')||(c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='_'||c=='-'))return-1;}
        if(data[i+pn+11]!=']'||data[i+pn+12]!=']'||++count>maximum)return-1;
        i+=pn+12;
    }
    return 0;
}
static int bind_media_tokens(cr_server*s,cr_session*session,const uint8_t*data,size_t len,size_t maximum,int kind,const char*scope,const char*message_id,time_t expires){
    char ids[10][37];size_t count=0;if(maximum>10||extract_media_ids(data,len,ids,maximum,&count))return-1;for(size_t i=0;i<count;i++)if(!cr_media_store_is_owned(&s->media,ids[i],session->account_id))return-1;for(size_t i=0;i<count;i++)if(cr_media_store_bind(&s->media,ids[i],session->account_id,kind,scope,message_id,expires))return-1;return 0;
}

static int handle_channel_chat(cr_session*s,const cr_packet*p){
    const cr_tlv*id=cr_packet_field(p,CHANNEL_FIELD_ID),*msg=cr_packet_field(p,CHANNEL_FIELD_MESSAGE),*attr=cr_packet_field(p,CHANNEL_FIELD_ATTRIBUTE);
    if(!id||id->length!=4||!msg||!msg->length||msg->length>0x800)return 0;
    int tagged=wire_is_tagged_utf8(msg->value,msg->length);
    if(tagged&&(!s->modern_transport||msg->length==3||!valid_utf8_bytes(msg->value+3,msg->length-3)||memchr(msg->value+3,0,msg->length-3)))return 0;
    uint8_t classic[0x800];size_t classic_len=0;
    int classic_ready=!tagged||!classic_text_describing_emoji(msg->value,msg->length,classic,sizeof(classic),&classic_len);

    uint32_t cid=cr_read_be32(id->value);uint8_t attribute=attr&&attr->length?attr->value[0]:0;uint8_t cb[4],ub[4];cr_write_be32(cb,cid);cr_write_be32(ub,s->user_id);
    pthread_mutex_lock(&s->server->mutex);cr_channel*c=channel_by_id_locked(s->server,cid);int idx=c?channel_member_index(c,s->user_id):-1;if(idx<0){pthread_mutex_unlock(&s->server->mutex);return 0;}uint8_t mode=c->members[idx].mode;uint16_t flags=c->flags;if((flags&CHANNEL_RESTRICTED_CHAT)&&!(mode&(CHANNEL_OPERATOR|CHANNEL_SPEECH))){pthread_mutex_unlock(&s->server->mutex);return p->transaction_id?send_error(s,p->transaction_id,0xcb):0;}pthread_mutex_unlock(&s->server->mutex);
    if(validate_youtube_tokens(msg->value,msg->length,4)){log_msg("Channel YouTube reference rejected for user %u",s->user_id);return 0;}
    char scope[32],message_id[33];snprintf(scope,sizeof(scope),"%u",cid);if(media_message_id(message_id)||bind_media_tokens(s->server,s,msg->value,msg->length,4,CR_MEDIA_KIND_CHAT,scope,message_id,time(NULL)+7*24*60*60)){log_msg("Channel media reference rejected for user %u",s->user_id);return 0;}

    pthread_mutex_lock(&s->server->mutex);
    c=channel_by_id_locked(s->server,cid);
    if(c)for(size_t i=0;i<c->member_count;i++){
        cr_session*x=find_session_locked(s->server,c->members[i].user_id);if(!x)continue;
        const uint8_t*wire=msg->value;size_t wire_len=msg->length;
        if(tagged&&!x->modern_transport){
            if(!classic_ready||!classic_len)continue;
            wire=classic;wire_len=classic_len;
        }
        cr_tlv_out f[]={{CHANNEL_FIELD_ID,cb,4},{CHANNEL_FIELD_USER_ID,ub,4},{CHANNEL_FIELD_MESSAGE,wire,(uint16_t)wire_len},{CHANNEL_FIELD_ATTRIBUTE,&attribute,1}};
        session_send(x,CMD_CHANNEL_CHAT,0,f,4);
    }
    pthread_mutex_unlock(&s->server->mutex);
    cr_state_stat_add(&s->server->state,"totalMessages",1);bot_maybe_reply_channel(s,cid,msg->value,msg->length);return 0;
}


static int legacy_leaf(const uint8_t*path,size_t path_len,const uint8_t**leaf,size_t*leaf_len){if(!path_len)return-1;size_t start=0;for(size_t i=0;i<path_len;i++)if(path[i]==1)start=i+1;if(start>=path_len)return-1;*leaf=path+start;*leaf_len=path_len-start;return 0;}
static size_t legacy_parent_length(const uint8_t*path,size_t path_len){for(size_t i=path_len;i>0;i--)if(path[i-1]==1)return i-1;return 0;}
static int validate_legacy_leaf(const uint8_t*name,size_t len,size_t maximum){if(!len||len>maximum)return-1;for(size_t i=0;i<len;i++)if(name[i]==1||name[i]==0)return-1;char text[1024];if(cr_macroman_to_utf8(name,len,text,sizeof(text)))return-1;return safe_component(text)?0:-1;}
static int build_legacy_child(const uint8_t*parent,size_t parent_len,const uint8_t*name,size_t name_len,uint8_t*out,size_t*out_len){size_t n=parent_len+(parent_len?1:0)+name_len;if(n>4096)return-1;if(parent_len)memcpy(out,parent,parent_len);size_t p=parent_len;if(parent_len)out[p++]=1;memcpy(out+p,name,name_len);*out_len=n;return 0;}
static int resource_kind(const char*path,int*is_folder,int*is_file,struct stat*st_out){struct stat st;if(stat(path,&st)||(!S_ISDIR(st.st_mode)&&!S_ISREG(st.st_mode)))return-1;if(is_folder)*is_folder=S_ISDIR(st.st_mode);if(is_file)*is_file=S_ISREG(st.st_mode);if(st_out)*st_out=st;return 0;}
static uint32_t stat_mac_time(time_t t){if(t<0)return 0;uint64_t v=(uint64_t)t+MAC_EPOCH_OFFSET;return v>UINT32_MAX?UINT32_MAX:(uint32_t)v;}
static int can_delete(cr_session*s,int folder){return account_perm(s,folder?PERM_DELETE_FOLDERS:PERM_DELETE_FILES);}
static int can_move(cr_session*s,int folder){return account_perm(s,folder?PERM_MOVE_FOLDERS:PERM_MOVE_FILES);}
static int can_rename(cr_session*s,int folder){return s->mode==CR_MODE_ADMIN&&account_perm(s,folder?PERM_RENAME_FOLDERS:PERM_RENAME_FILES);}
static int can_comment(cr_session*s,int folder){return account_perm(s,folder?PERM_COMMENT_FOLDERS:PERM_COMMENT_FILES);}
static int recursive_remove_path(const char*path){struct stat st;if(lstat(path,&st))return errno==ENOENT?0:-1;if(S_ISLNK(st.st_mode)||S_ISREG(st.st_mode))return unlink(path);if(!S_ISDIR(st.st_mode))return-1;DIR*d=opendir(path);if(!d)return-1;struct dirent*de;int rc=0;while((de=readdir(d))){if(!strcmp(de->d_name,".")||!strcmp(de->d_name,".."))continue;char child[PATH_MAX];if(join_path_component(child,sizeof(child),path,de->d_name)||recursive_remove_path(child)){rc=-1;break;}}closedir(d);if(!rc&&rmdir(path))rc=-1;return rc;}
static int unique_trash_path(cr_server*s,const char*source,char*out,size_t cap){
    const char*leaf=strrchr(source,'/');leaf=leaf?leaf+1:source;
    uint8_t rnd[16];if(RAND_bytes(rnd,sizeof(rnd))!=1)return-1;
    char id[33];for(size_t i=0;i<16;i++)snprintf(id+i*2,3,"%02x",rnd[i]);
    size_t root_len=strlen(s->trash_root),leaf_len=strlen(leaf),id_len=strlen(id);
    size_t need=root_len+1+id_len+1+leaf_len+1;if(need>cap)return-1;
    size_t pos=0;memcpy(out+pos,s->trash_root,root_len);pos+=root_len;out[pos++]='/';
    memcpy(out+pos,id,id_len);pos+=id_len;out[pos++]='-';
    memcpy(out+pos,leaf,leaf_len);pos+=leaf_len;out[pos]='\0';
    return 0;
}

static int handle_create_folder(cr_session*s,const cr_packet*p){
    if(!account_perm(s,PERM_CREATE_FOLDERS))return send_error(s,p->transaction_id,1);
    const cr_tlv*parent=cr_packet_field(p,1),*flagsf=cr_packet_field(p,2),*name=cr_packet_field(p,3);if(!flagsf||flagsf->length!=2||!name||validate_legacy_leaf(name->value,name->length,0xfa))return send_error(s,p->transaction_id,1);const uint8_t*pp=parent?parent->value:NULL;size_t pl=parent?parent->length:0;char parent_fs[PATH_MAX];if(resolve_legacy_path_ex(s->server,s,pp,pl,parent_fs,sizeof(parent_fs),1))return send_error(s,p->transaction_id,1);int folder=0;if(resource_kind(parent_fs,&folder,NULL,NULL)||!folder)return send_error(s,p->transaction_id,1);uint8_t child[4096];size_t cl=0;if(build_legacy_child(pp,pl,name->value,name->length,child,&cl))return send_error(s,p->transaction_id,1);char target[PATH_MAX];if(resolve_legacy_path_ex(s->server,s,child,cl,target,sizeof(target),0)||mkdir(target,0755))return send_error(s,p->transaction_id,1);cr_file_metadata m;cr_file_metadata_init(&m);m.flags=cr_read_be16(flagsf->value)&~DIR_FLAG_FOLDER;cr_now_iso8601(m.created_at);m.has_created_at=1;if(cr_file_metadata_set(session_metadata_store(s->server,s),child,cl,&m)){rmdir(target);return send_error(s,p->transaction_id,1);}if(file_search_index_incremental_available(s->server)&&!session_uses_legacy_files_root(s->server,s)&&!s->files_root_path[0]&&cr_file_search_index_upsert_subtree(&s->server->file_index,target,child,cl,&s->server->metadata,&s->server->search_index_exclusions)){log_msg("File-search index update failed for created folder");invalidate_file_search_index(s->server,"incremental folder update failure");}log_msg("Folder created: %s",target);return send_task_complete(s,p->transaction_id);
}
static int handle_delete_file(cr_session*s,const cr_packet*p){const cr_tlv*pf=cr_packet_field(p,1);if(!pf||!pf->length)return send_error(s,p->transaction_id,1);if(!account_perm(s,PERM_VIEW_DROPBOXES)&&path_is_inside_dropbox(s->server,s,pf->value,pf->length))return send_error(s,p->transaction_id,1);char source[PATH_MAX];if(resolve_legacy_path_ex(s->server,s,pf->value,pf->length,source,sizeof(source),1))return send_error(s,p->transaction_id,1);int folder=0;if(resource_kind(source,&folder,NULL,NULL)||!can_delete(s,folder))return send_error(s,p->transaction_id,1);if(mkdir(s->server->trash_root,0755)&&errno!=EEXIST)return send_error(s,p->transaction_id,1);char dest[PATH_MAX];if(unique_trash_path(s->server,source,dest,sizeof(dest))||rename(source,dest))return send_error(s,p->transaction_id,1);if(cr_file_metadata_remove(session_metadata_store(s->server,s),pf->value,pf->length,folder)){rename(dest,source);return send_error(s,p->transaction_id,1);}if(file_search_index_incremental_available(s->server)&&!session_uses_legacy_files_root(s->server,s)&&!s->files_root_path[0]&&cr_file_search_index_remove_subtree(&s->server->file_index,pf->value,pf->length)){log_msg("File-search index delete failed");invalidate_file_search_index(s->server,"incremental delete failure");}return send_task_complete(s,p->transaction_id);}
static int handle_file_info(cr_session*s,const cr_packet*p){const cr_tlv*pf=cr_packet_field(p,1);if(!pf||!pf->length)return send_error(s,p->transaction_id,1);if(!account_perm(s,PERM_VIEW_DROPBOXES)&&path_is_inside_dropbox(s->server,s,pf->value,pf->length))return send_error(s,p->transaction_id,1);char path[PATH_MAX];struct stat st;int folder=0;if(resolve_legacy_path_ex(s->server,s,pf->value,pf->length,path,sizeof(path),1)||resource_kind(path,&folder,NULL,&st))return send_error(s,p->transaction_id,1);cr_file_metadata m;int found=0;if(cr_file_metadata_get(session_metadata_store(s->server,s),pf->value,pf->length,&m,&found))return send_error(s,p->transaction_id,1);uint8_t meta[30];memset(meta,0,sizeof(meta));cr_write_be16(meta,(uint16_t)(m.flags|(folder?DIR_FLAG_FOLDER:0)));uint64_t sz=folder?0:(uint64_t)(st.st_size<0?0:st.st_size);cr_write_be32(meta+2,sz>UINT32_MAX?UINT32_MAX:(uint32_t)sz);cr_write_be32(meta+6,m.has_created_at?cr_iso8601_to_mac_timestamp(m.created_at):stat_mac_time(st.st_mtime));cr_write_be32(meta+10,stat_mac_time(st.st_mtime));memcpy(meta+14,m.finder_info,16);const uint8_t*leaf=NULL;size_t ll=0;if(legacy_leaf(pf->value,pf->length,&leaf,&ll)){cr_file_metadata_free(&m);return send_error(s,p->transaction_id,1);}cr_tlv_out f[5];size_t n=0;f[n++]=(cr_tlv_out){1,pf->value,pf->length};f[n++]=(cr_tlv_out){2,leaf,(uint16_t)ll};f[n++]=(cr_tlv_out){3,meta,30};f[n++]=(cr_tlv_out){4,m.comment,(uint16_t)m.comment_len};if(s->modern_transport)f[n++]=(cr_tlv_out){FILE_LABEL_FIELD,&m.label,1};int rc=session_send(s,CMD_MOVE_FILE,p->transaction_id,f,n);cr_file_metadata_free(&m);return rc;}
static int handle_set_file_info(cr_session*s,const cr_packet*p){const cr_tlv*pf=cr_packet_field(p,1),*name=cr_packet_field(p,2),*flagsf=cr_packet_field(p,3),*comment=cr_packet_field(p,4),*labelf=s->modern_transport?cr_packet_field(p,FILE_LABEL_FIELD):NULL;if(!pf||!pf->length||!name||validate_legacy_leaf(name->value,name->length,0x200)||!flagsf||flagsf->length!=2||!comment||comment->length>255||(labelf&&(labelf->length!=1||labelf->value[0]>7)))return send_error(s,p->transaction_id,1);if(!account_perm(s,PERM_VIEW_DROPBOXES)&&path_is_inside_dropbox(s->server,s,pf->value,pf->length))return send_error(s,p->transaction_id,1);char source[PATH_MAX];int folder=0;struct stat st;if(resolve_legacy_path_ex(s->server,s,pf->value,pf->length,source,sizeof(source),1)||resource_kind(source,&folder,NULL,&st))return send_error(s,p->transaction_id,1);cr_file_metadata m;int found=0;if(cr_file_metadata_get(session_metadata_store(s->server,s),pf->value,pf->length,&m,&found))return send_error(s,p->transaction_id,1);const uint8_t*oldleaf=NULL;size_t oldlen=0;if(legacy_leaf(pf->value,pf->length,&oldleaf,&oldlen)){cr_file_metadata_free(&m);return send_error(s,p->transaction_id,1);}uint16_t requested=(uint16_t)(cr_read_be16(flagsf->value)&~DIR_FLAG_FOLDER),oldflags=(uint16_t)(m.flags&~DIR_FLAG_FOLDER);int rename_req=oldlen!=name->length||memcmp(oldleaf,name->value,oldlen),comment_req=m.comment_len!=comment->length||(m.comment_len&&memcmp(m.comment,comment->value,m.comment_len)),flags_req=folder&&requested!=oldflags,label_req=labelf&&m.label!=labelf->value[0];if((rename_req&&!can_rename(s,folder))||(comment_req&&!can_comment(s,folder))||(label_req&&!can_comment(s,folder))||(flags_req&&!account_perm(s,PERM_CHANGE_FOLDER_MODE))){cr_file_metadata_free(&m);return send_error(s,p->transaction_id,1);}uint8_t final_path[4096];size_t final_len=pf->length;memcpy(final_path,pf->value,pf->length);char final_fs[PATH_MAX];strcpy(final_fs,source);if(rename_req){size_t parent_len=legacy_parent_length(pf->value,pf->length);if(build_legacy_child(pf->value,parent_len,name->value,name->length,final_path,&final_len)||resolve_legacy_path_ex(s->server,s,final_path,final_len,final_fs,sizeof(final_fs),0)||rename(source,final_fs)){cr_file_metadata_free(&m);return send_error(s,p->transaction_id,1);}if(cr_file_metadata_move(session_metadata_store(s->server,s),pf->value,pf->length,final_path,final_len,folder)){rename(final_fs,source);cr_file_metadata_free(&m);return send_error(s,p->transaction_id,1);}}
    cr_file_metadata_free(&m);if(cr_file_metadata_get(session_metadata_store(s->server,s),final_path,final_len,&m,&found)){if(rename_req)rename(final_fs,source);return send_error(s,p->transaction_id,1);}free(m.comment);m.comment=NULL;m.comment_len=comment->length;if(comment->length){m.comment=malloc(comment->length);if(!m.comment){cr_file_metadata_free(&m);return send_error(s,p->transaction_id,1);}memcpy(m.comment,comment->value,comment->length);}if(folder)m.flags=requested;if(labelf)m.label=labelf->value[0];if(!m.has_created_at){cr_now_iso8601(m.created_at);m.has_created_at=1;}if(cr_file_metadata_set(session_metadata_store(s->server,s),final_path,final_len,&m)){cr_file_metadata_free(&m);return send_error(s,p->transaction_id,1);}cr_file_metadata_free(&m);if(file_search_index_incremental_available(s->server)&&!session_uses_legacy_files_root(s->server,s)&&!s->files_root_path[0]){int irc=rename_req?cr_file_search_index_move_subtree(&s->server->file_index,pf->value,pf->length,final_path,final_len,final_fs,&s->server->metadata,&s->server->search_index_exclusions):cr_file_search_index_upsert_subtree(&s->server->file_index,final_fs,final_path,final_len,&s->server->metadata,&s->server->search_index_exclusions);if(irc){log_msg("File-search index metadata/rename update failed");invalidate_file_search_index(s->server,"incremental metadata/rename failure");}}return send_task_complete(s,p->transaction_id);}
static int handle_set_file_label(cr_session*s,const cr_packet*p){
    const cr_tlv*pf=cr_packet_field(p,1),*labelf=cr_packet_field(p,FILE_LABEL_FIELD);
    if(!s->modern_transport||!pf||!pf->length||!labelf||labelf->length!=1||labelf->value[0]>7)return send_error(s,p->transaction_id,1);
    if(!account_perm(s,PERM_VIEW_DROPBOXES)&&path_is_inside_dropbox(s->server,s,pf->value,pf->length))return send_error(s,p->transaction_id,1);
    char path[PATH_MAX];int folder=0;if(resolve_legacy_path_ex(s->server,s,pf->value,pf->length,path,sizeof(path),1)||resource_kind(path,&folder,NULL,NULL)||!can_comment(s,folder))return send_error(s,p->transaction_id,1);
    cr_file_metadata m;int found=0;if(cr_file_metadata_get(session_metadata_store(s->server,s),pf->value,pf->length,&m,&found))return send_error(s,p->transaction_id,1);m.label=labelf->value[0];if(cr_file_metadata_set(session_metadata_store(s->server,s),pf->value,pf->length,&m)){cr_file_metadata_free(&m);return send_error(s,p->transaction_id,1);}cr_file_metadata_free(&m);log_msg("File label updated: %s -> %u",path,(unsigned)labelf->value[0]);return send_task_complete(s,p->transaction_id);
}

static int handle_move_file(cr_session*s,const cr_packet*p){const cr_tlv*src=cr_packet_field(p,1),*dst=cr_packet_field(p,2);if(!src||!src->length||!dst||!dst->length||(src->length==dst->length&&!memcmp(src->value,dst->value,src->length)))return send_error(s,p->transaction_id,1);if(!account_perm(s,PERM_VIEW_DROPBOXES)&&path_is_inside_dropbox(s->server,s,src->value,src->length))return send_error(s,p->transaction_id,1);char source[PATH_MAX],dest[PATH_MAX];int folder=0;if(resolve_legacy_path_ex(s->server,s,src->value,src->length,source,sizeof(source),1)||resource_kind(source,&folder,NULL,NULL)||!can_move(s,folder))return send_error(s,p->transaction_id,1);if(folder&&dst->length>src->length&&!memcmp(dst->value,src->value,src->length)&&dst->value[src->length]==1)return send_error(s,p->transaction_id,1);const uint8_t*leaf=NULL;size_t ll=0;if(legacy_leaf(dst->value,dst->length,&leaf,&ll)||validate_legacy_leaf(leaf,ll,0x200)||resolve_legacy_path_ex(s->server,s,dst->value,dst->length,dest,sizeof(dest),0))return send_error(s,p->transaction_id,1);size_t parent_len=legacy_parent_length(dst->value,dst->length);char parent[PATH_MAX];int parent_folder=0;if(resolve_legacy_path_ex(s->server,s,dst->value,parent_len,parent,sizeof(parent),1)||resource_kind(parent,&parent_folder,NULL,NULL)||!parent_folder||rename(source,dest))return send_error(s,p->transaction_id,1);if(cr_file_metadata_move(session_metadata_store(s->server,s),src->value,src->length,dst->value,dst->length,folder)){rename(dest,source);return send_error(s,p->transaction_id,1);}if(file_search_index_incremental_available(s->server)&&!session_uses_legacy_files_root(s->server,s)&&!s->files_root_path[0]&&cr_file_search_index_move_subtree(&s->server->file_index,src->value,src->length,dst->value,dst->length,dest,&s->server->metadata,&s->server->search_index_exclusions)){log_msg("File-search index move failed");invalidate_file_search_index(s->server,"incremental move failure");}return send_task_complete(s,p->transaction_id);}
static int handle_empty_trash(cr_session*s,const cr_packet*p){if(!account_perm(s,PERM_EMPTY_TRASH))return send_error(s,p->transaction_id,1);DIR*d=opendir(s->server->trash_root);if(!d){if(errno==ENOENT){if(mkdir(s->server->trash_root,0755))return send_error(s,p->transaction_id,1);}else return send_error(s,p->transaction_id,1);}else{struct dirent*de;int fail=0;while((de=readdir(d))){if(de->d_name[0]=='.'&&(!de->d_name[1]||(de->d_name[1]=='.'&&!de->d_name[2])))continue;char child[PATH_MAX];if(join_path_component(child,sizeof(child),s->server->trash_root,de->d_name)||recursive_remove_path(child)){fail=1;break;}}closedir(d);if(fail)return send_error(s,p->transaction_id,1);}return send_task_complete(s,p->transaction_id);}
static int handle_rebuild_search_index(cr_session*s,const cr_packet*p){
    if(!account_perm(s,PERM_EDIT_ADVANCED)||!s->server->file_index.ready)return send_error(s,p->transaction_id,1);
    repair_file_search_index(s->server);
    log_msg("File-search index rebuild requested remotely by user %u",s->user_id);
    return send_task_complete(s,p->transaction_id);
}

static int packet_target_user(const cr_packet *p, uint32_t *out) {
    const cr_tlv *f = cr_packet_field(p, 1);
    if (!f || f->length != 4) return -1;
    *out = cr_read_be32(f->value);
    return 0;
}

static int handle_private_message(cr_session *s, const cr_packet *p) {
    uint32_t target_id;
    const cr_tlv *message = cr_packet_field(p, 2), *extra = cr_packet_field(p, 3);
    if (packet_target_user(p, &target_id) || !message || !message->length || message->length > 0x8000 ||
        (extra && extra->length > 0x8000)) return p->transaction_id ? send_error(s,p->transaction_id,1) : 0;
    int tagged=wire_is_tagged_utf8(message->value,message->length);
    if(tagged&&(!s->modern_transport||message->length==3||!valid_utf8_bytes(message->value+3,message->length-3)||memchr(message->value+3,0,message->length-3)))
        return p->transaction_id?send_error(s,p->transaction_id,1):0;

    uint8_t classic[0x8000];size_t classic_len=0;
    int classic_ready=!tagged||!classic_text_describing_emoji(message->value,message->length,classic,sizeof(classic),&classic_len);
    uint8_t uid[4]; cr_write_be32(uid, s->user_id);

    pthread_mutex_lock(&s->server->mutex);
    cr_session *target = find_session_locked(s->server, target_id);
    const uint8_t*wire=message->value;size_t wire_len=message->length;
    if(target&&tagged&&!target->modern_transport){
        if(!classic_ready||!classic_len)target=NULL;
        else{wire=classic;wire_len=classic_len;}
    }
    cr_tlv_out fields[3]; size_t n=0;
    fields[n++] = (cr_tlv_out){1,uid,4}; fields[n++] = (cr_tlv_out){2,wire,(uint16_t)wire_len};
    if (extra && extra->length) fields[n++] = (cr_tlv_out){3,extra->value,extra->length};
    int target_is_bot = target && target == s->server->bot_session && target->local_only;
    int send_rc = target ? session_send(target,CMD_PRIVATE_MESSAGE,0,fields,n) : -1;
    pthread_mutex_unlock(&s->server->mutex);
    if (send_rc) return p->transaction_id ? send_error(s,p->transaction_id,1) : 0;
    cr_state_stat_add(&s->server->state,"totalMessages",1);
    if(target_is_bot)bot_maybe_reply_private(s,message->value,message->length);
    return send_task_complete(s,p->transaction_id);
}


static int handle_offline_message_send(cr_session *s,const cr_packet *p){
    const cr_tlv *login=cr_packet_field(p,1),*message=cr_packet_field(p,2);
    if(!login||!login->length||login->length>63||!message||!message->length||message->length>4096)return send_error(s,p->transaction_id,1);
    char recipient_login[256],recipient_id[64];recipient_id[0]=0;int recipient_accepts=0;
    if(cr_macroman_to_utf8(login->value,login->length,recipient_login,sizeof(recipient_login)))return send_error(s,p->transaction_id,1);
    pthread_mutex_lock(&s->server->state.mutex);int aidx=cr_state_find_account(&s->server->state,recipient_login);if(aidx>=0){snprintf(recipient_id,sizeof(recipient_id),"%s",s->server->state.accounts[aidx].id);recipient_accepts=s->server->state.accounts[aidx].accepts_offline_messages;}pthread_mutex_unlock(&s->server->state.mutex);
    if(aidx<0||!recipient_id[0]||!recipient_accepts||!strcmp(recipient_id,s->account_id))return send_error(s,p->transaction_id,1);
    pthread_mutex_lock(&s->server->mutex);cr_session*target=find_session_account_locked(s->server,recipient_id);if(target){uint8_t uid[4];cr_write_be32(uid,s->user_id);cr_tlv_out f[]={{1,uid,4},{2,message->value,message->length}};int rc=session_send(target,CMD_PRIVATE_MESSAGE,0,f,2);pthread_mutex_unlock(&s->server->mutex);if(rc)return send_error(s,p->transaction_id,1);cr_state_stat_add(&s->server->state,"totalMessages",1);return send_task_complete(s,p->transaction_id);}pthread_mutex_unlock(&s->server->mutex);
    size_t count=0;if(cr_state_offline_message_count(&s->server->state,recipient_id,&count)||count>=24)return send_error(s,p->transaction_id,1);
    uint8_t sender_login[256];size_t sender_login_len=0;if(cr_utf8_to_macroman(s->login,sender_login,sizeof(sender_login),&sender_login_len))return send_error(s,p->transaction_id,1);
    cr_buffer payload;cr_buffer_init(&payload);if(cr_buffer_append_string16(&payload,sender_login,sender_login_len)||cr_buffer_append_string16(&payload,s->nickname,s->nickname_len)||cr_buffer_append_string16(&payload,message->value,message->length)){cr_buffer_free(&payload);return send_error(s,p->transaction_id,1);}char id[37];int rc=cr_state_offline_message_put(&s->server->state,recipient_id,payload.data,payload.len,(uint64_t)time(NULL),id);cr_buffer_free(&payload);if(rc)return send_error(s,p->transaction_id,1);cr_state_stat_add(&s->server->state,"totalMessages",1);return send_task_complete(s,p->transaction_id);
}

static int handle_offline_message_recipients(cr_session*s,const cr_packet*p){
    cr_buffer *records=calloc(CR_MAX_ACCOUNTS,sizeof(*records));cr_tlv_out *fields=calloc(CR_MAX_ACCOUNTS,sizeof(*fields));if(!records||!fields){free(records);free(fields);return send_error(s,p->transaction_id,1);}size_t n=0;int failed=0;
    pthread_mutex_lock(&s->server->state.mutex);
    for(size_t i=0;i<s->server->state.account_count&&n<CR_MAX_ACCOUNTS;i++){
        const cr_account*a=&s->server->state.accounts[i];if(!a->accepts_offline_messages||!strcmp(a->id,s->account_id))continue;
        uint8_t login_mac[512],nick_mac[2048];size_t ln=0,nn=0;const char*nick=a->last_nickname[0]?a->last_nickname:(a->name[0]?a->name:a->login);
        if(cr_utf8_to_macroman(a->login,login_mac,sizeof(login_mac),&ln)||!ln||ln>63||cr_utf8_to_macroman(nick,nick_mac,sizeof(nick_mac),&nn)||nn>255){failed=1;break;}
        cr_buffer_init(&records[n]);if(cr_buffer_append_string16(&records[n],login_mac,ln)||cr_buffer_append_string16(&records[n],nick_mac,nn)||records[n].len>UINT16_MAX){failed=1;break;}
        fields[n]=(cr_tlv_out){1,records[n].data,(uint16_t)records[n].len};n++;
    }
    pthread_mutex_unlock(&s->server->state.mutex);
    int rc=failed?send_error(s,p->transaction_id,1):session_send(s,CMD_OFFLINE_MESSAGE_RECIPIENTS,p->transaction_id,fields,n);
    for(size_t i=0;i<n;i++)cr_buffer_free(&records[i]);
    free(records);
    free(fields);
    return rc;
}

static int handle_offline_message_preference(cr_session*s,const cr_packet*p){
    const cr_tlv*f=cr_packet_field(p,1);if(!f||f->length!=1||f->value[0]>1)return send_error(s,p->transaction_id,1);
    char nickname[1024];if(cr_macroman_to_utf8(s->nickname,s->nickname_len,nickname,sizeof(nickname)))return send_error(s,p->transaction_id,1);
    if(cr_state_set_offline_message_preference(&s->server->state,s->account_id,f->value[0]==1,nickname))return send_error(s,p->transaction_id,1);
    return send_task_complete(s,p->transaction_id);
}

static int handle_offline_message_fetch(cr_session*s,const cr_packet*p){
    cr_offline_message_blob *messages=NULL;size_t count=0;if(cr_state_offline_message_load(&s->server->state,s->account_id,&messages,&count))return send_error(s,p->transaction_id,1);if(count>24){cr_state_offline_message_free(messages,count);return send_error(s,p->transaction_id,1);}cr_buffer records[24];cr_tlv_out fields[24];size_t n=0;int failed=0;for(size_t i=0;i<count;i++){cr_buffer_init(&records[i]);size_t idlen=strlen(messages[i].id);if(idlen>UINT16_MAX||cr_buffer_append_string16(&records[i],messages[i].id,idlen)||cr_buffer_append_u64(&records[i],messages[i].created_at)||cr_buffer_append(&records[i],messages[i].plaintext,messages[i].plaintext_len)||records[i].len>UINT16_MAX){failed=1;break;}fields[n++]=(cr_tlv_out){1,records[i].data,(uint16_t)records[i].len};}int rc=failed?send_error(s,p->transaction_id,1):session_send(s,CMD_OFFLINE_MESSAGE_FETCH,p->transaction_id,fields,n);for(size_t i=0;i<n;i++)cr_buffer_free(&records[i]);cr_state_offline_message_free(messages,count);return rc;
}

static int handle_offline_message_ack(cr_session *s, const cr_packet *p) {
  if (!p->field_count || p->field_count > 24)
    return send_error(s, p->transaction_id, 1);
  char ids[24][65];
  const char *ptrs[24];
  size_t n = 0;
  for (uint16_t i = 0; i < p->field_count; i++) {
    const cr_tlv *f = &p->fields[i];
    if (f->type != 1 || !f->length || f->length > 64)
      return send_error(s, p->transaction_id, 1);
    memcpy(ids[n], f->value, f->length);
    ids[n][f->length] = 0;
    ptrs[n] = ids[n];
    n++;
  }
  if (cr_state_offline_message_ack(&s->server->state, s->account_id, ptrs, n))
    return send_error(s, p->transaction_id, 1);
  return send_task_complete(s, p->transaction_id);
}

static void send_offline_message_notice(cr_session*s){size_t count=0;if(cr_state_offline_message_count(&s->server->state,s->account_id,&count)||!count)return;uint8_t c[4];cr_write_be32(c,count>UINT32_MAX?UINT32_MAX:(uint32_t)count);cr_tlv_out f={1,c,4};(void)session_send(s,CMD_OFFLINE_MESSAGE_NOTICE,0,&f,1);}

static void broadcast_presence_state_locked(cr_server *server, uint32_t user_id, uint8_t state) {
    uint8_t uid[4];cr_write_be32(uid,user_id);cr_tlv_out fields[]={{1,uid,4},{0xf0000001u,&state,1}};
    for(size_t i=0;i<server->allocated_session_count;i++){
        cr_session*x=server->sessions[i];
        if(session_ready_for_async(x)&&x->modern_transport)session_send(x,CMD_PRESENCE,0,fields,2);
    }
}

static void broadcast_presence_state(cr_server *server, uint32_t user_id, uint8_t state) {
    pthread_mutex_lock(&server->mutex);
    broadcast_presence_state_locked(server,user_id,state);
    pthread_mutex_unlock(&server->mutex);
}

static int command_is_user_activity(uint32_t command) {
    switch(command) {
    case CMD_DIRECTORY: case CMD_CREATE_FOLDER: case CMD_DELETE_FILE: case CMD_FILE_INFO:
    case CMD_SET_FILE_INFO: case CMD_FILE_LABEL_SET: case CMD_MOVE_FILE: case CMD_EMPTY_TRASH:
    case CMD_PRIVATE_MESSAGE: case CMD_OFFLINE_MESSAGE_SEND: case CMD_EXTENDED_OWN_USER_INFO:
    case CMD_USER_UPDATE: case CMD_CHANNEL_JOIN: case CMD_CHANNEL_LEAVE: case CMD_CHANNEL_CHAT:
    case CMD_CHANNEL_SETTINGS: case CMD_CHANNEL_USER_MODE: case CMD_CHANNEL_INVITE: case CMD_CHANNEL_DECLINE:
    case CMD_ARTICLE_READ: case CMD_FORUM_THREAD_ENTRIES:
    case CMD_FORUM_ARTICLE_REACTION_SET: case CMD_FORUM_ARTICLE_DELETE: case CMD_ARTICLE_DELETE:
    case CMD_FLAT_NEWS_LIST: case CMD_FLAT_NEWS_POST: case CMD_FLAT_NEWS_DELETE: case CMD_FLAT_NEWS_CLEAR:
    case CMD_NEWSGROUP_CREATE: case CMD_NEWSGROUP_MODIFY: case CMD_NEWSGROUP_DELETE:
    case CMD_BROADCAST: case CMD_CHANGE_OWN_PASSWORD:
        return 1;
    default:
        return 0;
    }
}

static void mark_user_active(cr_session *s) {
    int woke=0;uint32_t user_id=0;
    pthread_mutex_lock(&s->server->mutex);
    if(s->authenticated&&!s->closed){
        s->last_activity=time(NULL);user_id=s->user_id;
        if(s->sleeping){s->sleeping=0;woke=1;}
    }
    pthread_mutex_unlock(&s->server->mutex);
    if(woke)broadcast_presence_state(s->server,user_id,0);
}

static unsigned automatic_sleep_seconds(void) {
    const char *override=getenv("CARRACHO_IDLE_SLEEP_SECONDS");
    if(override&&*override){char*end=NULL;unsigned long v=strtoul(override,&end,10);if(end&&!*end&&v>=1&&v<=86400)return (unsigned)v;}
    return 5u*60u;
}

static void maybe_sleep_idle_users(cr_server *server) {
    uint32_t ids[CR_SERVER_MAX_SESSIONS];size_t count=0;time_t now=time(NULL);unsigned threshold=automatic_sleep_seconds();
    pthread_mutex_lock(&server->mutex);
    for(size_t i=0;i<server->allocated_session_count;i++){
        cr_session*s=server->sessions[i];
        if(!s||!s->authenticated||s->closed||s->sleeping)continue;
        int transferring=0;for(size_t j=0;j<CR_SERVER_MAX_ACTIVE_TRANSFERS;j++){cr_active_transfer*t=&server->active_transfers[j];if(t->used&&t->user_id==s->user_id){transferring=1;break;}}
        if(transferring)continue;
        if(difftime(now,s->last_activity)>=(double)threshold){s->sleeping=1;if(count<CR_SERVER_MAX_SESSIONS)ids[count++]=s->user_id;}
    }
    pthread_mutex_unlock(&server->mutex);
    for(size_t i=0;i<count;i++)broadcast_presence_state(server,ids[i],1);
}

static int handle_presence(cr_session *s, const cr_packet *p) {
    const cr_tlv *id = cr_packet_field(p,1), *state = cr_packet_field(p,0xf0000001u);
    if (!id || id->length!=4 || cr_read_be32(id->value)!=s->user_id || !state || state->length!=1 || state->value[0]>1)
        return p->transaction_id ? send_error(s,p->transaction_id,1) : 0;
    pthread_mutex_lock(&s->server->mutex);
    s->last_activity=time(NULL);
    s->sleeping = state->value[0] == 1;
    pthread_mutex_unlock(&s->server->mutex);
    broadcast_presence_state(s->server,s->user_id,state->value[0]);
    return send_task_complete(s,p->transaction_id);
}

static int handle_extended_own_user_info(cr_session *s, const cr_packet *p) {
    const cr_tlv *nf=cr_packet_field(p,0xb0), *ef=cr_packet_field(p,0xb1), *af=cr_packet_field(p,0xb2);
    if ((!nf&&!ef&&!af) || (nf&&nf->length>64) || (ef&&ef->length>64) || (af&&af->length>128)) return send_error(s,p->transaction_id,1);
    char name[512], email[512], about[1024];
    if(nf&&cr_macroman_to_utf8(nf->value,nf->length,name,sizeof(name)))return send_error(s,p->transaction_id,1);
    if(ef&&cr_macroman_to_utf8(ef->value,ef->length,email,sizeof(email)))return send_error(s,p->transaction_id,1);
    if(af&&cr_macroman_to_utf8(af->value,af->length,about,sizeof(about)))return send_error(s,p->transaction_id,1);
    if(cr_state_update_profile(&s->server->state,s->account_id,name,nf!=NULL,email,ef!=NULL,about,af!=NULL,NULL,0,0))return send_error(s,p->transaction_id,1);
    pthread_mutex_lock(&s->server->mutex);
    if(nf)snprintf(s->profile_name,sizeof(s->profile_name),"%s",name);
    if(ef)snprintf(s->email,sizeof(s->email),"%s",email);
    if(af)snprintf(s->about,sizeof(s->about),"%s",about);
    pthread_mutex_unlock(&s->server->mutex);
    return send_task_complete(s,p->transaction_id);
}

static int handle_user_update(cr_session *s, const cr_packet *p) {
    const cr_tlv *nick=cr_packet_field(p,2), *pic=cr_packet_field(p,5), *status=cr_packet_field(p,0xf0000002u);
    const uint8_t *nickname=nick?nick->value:s->nickname; size_t nickname_len=nick?nick->length:s->nickname_len;
    const uint8_t *picture=pic?pic->value:s->picture; size_t picture_len=pic?pic->length:s->picture_len;
    const uint8_t *status_message=status?status->value:s->status_message; size_t status_len=status?status->length:s->status_message_len;
    if(!nickname_len||nickname_len>64||picture_len>UINT16_MAX||status_len>255)return p->transaction_id?send_error(s,p->transaction_id,1):0;
    if(pic&&cr_state_update_profile(&s->server->state,s->account_id,NULL,0,NULL,0,NULL,0,picture,picture_len,1))return p->transaction_id?send_error(s,p->transaction_id,1):0;
    uint8_t *picture_copy=picture_len?malloc(picture_len):NULL;if(picture_len&&!picture_copy)return-1;if(picture_len)memcpy(picture_copy,picture,picture_len);
    uint8_t event_nick[256],event_status[255];
    pthread_mutex_lock(&s->server->mutex);
    s->nickname_len=nickname_len;memcpy(s->nickname,nickname,nickname_len);
    if(status){s->status_message_len=status_len;if(status_len)memcpy(s->status_message,status_message,status_len);}
    if(pic){free(s->picture);s->picture=picture_copy;s->picture_len=picture_len;picture_copy=NULL;}
    memcpy(event_nick,s->nickname,s->nickname_len);size_t en=s->nickname_len;size_t ep=s->picture_len;size_t es=s->status_message_len;if(es)memcpy(event_status,s->status_message,es);
    uint8_t uid[4],color[4];cr_write_be32(uid,s->user_id);
    uint8_t*classic_picture=NULL;size_t classic_picture_len=0;
    if(pic&&picture_len)(void)classic_avatar_png(s->picture,s->picture_len,&classic_picture,&classic_picture_len);
    cr_tlv_out classic_fields[3]={{1,uid,4},{2,event_nick,(uint16_t)en}};size_t classic_count=2;
    if(pic&&(!picture_len||classic_picture_len))
        classic_fields[classic_count++]=(cr_tlv_out){0xb4,classic_picture,(uint16_t)classic_picture_len};
    cr_tlv_out modern_fields[5];size_t modern_count=0;
    modern_fields[modern_count++]=classic_fields[0];
    modern_fields[modern_count++]=classic_fields[1];
    modern_fields[modern_count++]=(cr_tlv_out){0xb4,s->picture,(uint16_t)ep};
    modern_fields[modern_count++]=(cr_tlv_out){0xf0000002u,event_status,(uint16_t)es};
    append_session_group_color(s,modern_fields,&modern_count,color);
    for(size_t i=0;i<s->server->allocated_session_count;i++){
        cr_session*x=s->server->sessions[i];
        if(!session_ready_for_async(x))continue;
        if(x->modern_transport)session_send(x,CMD_USER_UPDATE,0,modern_fields,modern_count);
        else session_send(x,CMD_USER_UPDATE,0,classic_fields,classic_count);
    }
    free(classic_picture);
    pthread_mutex_unlock(&s->server->mutex);free(picture_copy);
    if(nick){
        char nick_utf8[1024];int enabled=1;
        if(!cr_macroman_to_utf8(nickname,nickname_len,nick_utf8,sizeof(nick_utf8))){
            pthread_mutex_lock(&s->server->state.mutex);for(size_t i=0;i<s->server->state.account_count;i++)if(!strcmp(s->server->state.accounts[i].id,s->account_id)){enabled=s->server->state.accounts[i].accepts_offline_messages;break;}pthread_mutex_unlock(&s->server->state.mutex);
            (void)cr_state_set_offline_message_preference(&s->server->state,s->account_id,enabled,nick_utf8);
        }
    }
    return send_task_complete(s,p->transaction_id);
}

static int handle_user_info(cr_session *s, const cr_packet *p) {
    uint32_t uid;if(packet_target_user(p,&uid))return send_error(s,p->transaction_id,1);
    uint8_t nickname[256],status_message[255];size_t nn=0,status_len=0;char name[512]="",email[512]="",about[1024]="",login[256]="",peer[INET_ADDRSTRLEN]="";char client_os[CLIENT_METADATA_MAX_BYTES+1]="",client_arch[CLIENT_METADATA_MAX_BYTES+1]="",client_version[CLIENT_METADATA_MAX_BYTES+1]="",client_build[CLIENT_METADATA_MAX_BYTES+1]="";time_t login_at=0,last=0;int found=0,has_group_color=0;uint32_t group_color=0;
    cr_buffer picture,tasklist;cr_buffer_init(&picture);cr_buffer_init(&tasklist);
    pthread_mutex_lock(&s->server->mutex);
    cr_session*t=find_session_locked(s->server,uid);
    if(t){found=1;nn=t->nickname_len;memcpy(nickname,t->nickname,nn);status_len=t->status_message_len;if(status_len)memcpy(status_message,t->status_message,status_len);if(t->picture_len>UINT16_MAX||cr_buffer_append(&picture,t->picture,t->picture_len)){pthread_mutex_unlock(&s->server->mutex);cr_buffer_free(&picture);cr_buffer_free(&tasklist);return send_error(s,p->transaction_id,1);}snprintf(name,sizeof(name),"%s",t->profile_name);snprintf(email,sizeof(email),"%s",t->email);snprintf(about,sizeof(about),"%s",t->about);snprintf(login,sizeof(login),"%s",t->login);snprintf(peer,sizeof(peer),"%s",t->peer_ip);snprintf(client_os,sizeof(client_os),"%s",t->client_operating_system);snprintf(client_arch,sizeof(client_arch),"%s",t->client_cpu_architecture);snprintf(client_version,sizeof(client_version),"%s",t->client_version);snprintf(client_build,sizeof(client_build),"%s",t->client_build);login_at=t->login_at;last=t->last_activity;has_group_color=t->has_group_color;group_color=t->group_color_rgb;}
    if(found&&account_perm(s,PERM_EXTENDED_USER_INFO)){size_t tc=0;for(size_t i=0;i<CR_SERVER_MAX_ACTIVE_TRANSFERS;i++)if(s->server->active_transfers[i].used&&s->server->active_transfers[i].user_id==uid)tc++;if(tc>UINT16_MAX||cr_buffer_append_u16(&tasklist,(uint16_t)tc)){pthread_mutex_unlock(&s->server->mutex);cr_buffer_free(&picture);cr_buffer_free(&tasklist);return send_error(s,p->transaction_id,1);}for(size_t i=0;i<CR_SERVER_MAX_ACTIVE_TRANSFERS;i++){cr_active_transfer*a=&s->server->active_transfers[i];if(!a->used||a->user_id!=uid)continue;uint8_t percent=0;if(a->total_bytes){uint64_t x=a->bytes_transferred>=a->total_bytes?100:(a->bytes_transferred*100/a->total_bytes);percent=(uint8_t)(x>100?100:x);}if(cr_buffer_append_u32(&tasklist,a->transfer_id)||cr_buffer_append_u8(&tasklist,a->kind)||cr_buffer_append_string16(&tasklist,a->path,a->path_len)||cr_buffer_append_u8(&tasklist,percent)){pthread_mutex_unlock(&s->server->mutex);cr_buffer_free(&picture);cr_buffer_free(&tasklist);return send_error(s,p->transaction_id,1);}}}
    pthread_mutex_unlock(&s->server->mutex);if(!found){cr_buffer_free(&picture);cr_buffer_free(&tasklist);return send_error(s,p->transaction_id,1);}
    uint8_t name_m[1024],email_m[1024],about_m[2048],login_m[512];size_t namel=0,emaill=0,aboutl=0,loginl=0;
    if(cr_utf8_to_macroman(name,name_m,sizeof(name_m),&namel)||cr_utf8_to_macroman(email,email_m,sizeof(email_m),&emaill)||cr_utf8_to_macroman(about,about_m,sizeof(about_m),&aboutl)||cr_utf8_to_macroman(login,login_m,sizeof(login_m),&loginl)){cr_buffer_free(&picture);cr_buffer_free(&tasklist);return send_error(s,p->transaction_id,1);}
    cr_tlv_out f[16];size_t n=0;f[n++]=(cr_tlv_out){4,nickname,(uint16_t)nn};f[n++]=(cr_tlv_out){0xb0,name_m,(uint16_t)namel};f[n++]=(cr_tlv_out){0xb1,email_m,(uint16_t)emaill};f[n++]=(cr_tlv_out){0xb2,about_m,(uint16_t)aboutl};f[n++]=(cr_tlv_out){0xb4,picture.data,(uint16_t)picture.len};f[n++]=(cr_tlv_out){0xf0000002u,status_message,(uint16_t)status_len};
    uint8_t ip[4]={0},login_time[4],idle[4],color_bytes[4];if(has_group_color){cr_write_be32(color_bytes,group_color);f[n++]=(cr_tlv_out){USER_FIELD_GROUP_COLOR,color_bytes,4};}
    time_t now=time(NULL);double secs=difftime(now,last);if(secs<0)secs=0;uint64_t ticks=(uint64_t)(secs*60.0);if(ticks>UINT32_MAX)ticks=UINT32_MAX;cr_write_be32(idle,(uint32_t)ticks);f[n++]=(cr_tlv_out){0x87,idle,4};
    if(account_perm(s,PERM_EXTENDED_USER_INFO)){struct in_addr addr;if(inet_pton(AF_INET,peer,&addr)==1)memcpy(ip,&addr,4);uint64_t mt=(uint64_t)(login_at<0?0:login_at)+MAC_EPOCH_OFFSET;if(mt>UINT32_MAX)mt=UINT32_MAX;cr_write_be32(login_time,(uint32_t)mt);f[n++]=(cr_tlv_out){0x84,ip,4};f[n++]=(cr_tlv_out){0x85,login_time,4};f[n++]=(cr_tlv_out){0x86,tasklist.data,(uint16_t)tasklist.len};f[n++]=(cr_tlv_out){0x88,login_m,(uint16_t)loginl};if(client_os[0])f[n++]=(cr_tlv_out){CLIENT_FIELD_OPERATING_SYSTEM,(const uint8_t*)client_os,(uint16_t)strlen(client_os)};if(client_arch[0])f[n++]=(cr_tlv_out){CLIENT_FIELD_CPU_ARCHITECTURE,(const uint8_t*)client_arch,(uint16_t)strlen(client_arch)};if(client_version[0])f[n++]=(cr_tlv_out){CLIENT_FIELD_VERSION,(const uint8_t*)client_version,(uint16_t)strlen(client_version)};if(client_build[0])f[n++]=(cr_tlv_out){CLIENT_FIELD_BUILD,(const uint8_t*)client_build,(uint16_t)strlen(client_build)};}
    int rc=session_send(s,CMD_USER_INFO,p->transaction_id,f,n);cr_buffer_free(&picture);cr_buffer_free(&tasklist);return rc;
}

static int handle_transfer_info(cr_session*s,const cr_packet*p){
    if(s->mode!=CR_MODE_ADMIN&&!account_perm(s,PERM_MANAGE_TRANSFERS))return send_error(s,p->transaction_id,2);
    const cr_tlv*requested_limit=cr_packet_field(p,2);
    if(requested_limit){
        /* Field 2 is one aggregate server-outbound cap. It must never be scoped to
           the administrator connection that changed it. Transfer managers may still
           inspect/control transfers, but only administrators may change this global setting. */
        if(s->mode!=CR_MODE_ADMIN)return send_error(s,p->transaction_id,2);
        if(requested_limit->length!=8)return send_error(s,p->transaction_id,1);
        set_download_bandwidth_limit(s->server,cr_read_be64(requested_limit->value));
    }
    const cr_tlv*control=cr_packet_field(p,5);
    if(control){
        if(control->length!=5)return send_error(s,p->transaction_id,1);
        uint32_t transfer_id=cr_read_be32(control->value);
        uint8_t action=control->value[4];
        if(control_active_transfer(s->server,transfer_id,action))return send_error(s,p->transaction_id,1);
    }

    cr_buffer values[CR_SERVER_MAX_ACTIVE_TRANSFERS*2];
    cr_tlv_out fields[CR_SERVER_MAX_ACTIVE_TRANSFERS*2+2];
    for(size_t i=0;i<CR_SERVER_MAX_ACTIVE_TRANSFERS*2;i++)cr_buffer_init(&values[i]);
    size_t n=0;
    int fail=0;
    uint8_t limit_bytes[8],rate_bytes[8];
    pthread_mutex_lock(&s->server->mutex);
    for(size_t i=0;i<CR_SERVER_MAX_ACTIVE_TRANSFERS&&!fail;i++){
        cr_active_transfer*a=&s->server->active_transfers[i];
        if(!a->used)continue;
        cr_buffer*classic=&values[n];
        if(cr_buffer_append_u8(classic,a->kind)||cr_buffer_append_u32(classic,a->user_id)||
           cr_buffer_append_string16(classic,a->path,a->path_len)||
           cr_buffer_append_u64(classic,a->bytes_transferred)||cr_buffer_append_u64(classic,a->total_bytes)||
           cr_buffer_append_u64(classic,0)||classic->len>UINT16_MAX){fail=1;break;}
        fields[n]=(cr_tlv_out){1,classic->data,(uint16_t)classic->len};n++;

        cr_buffer*managed=&values[n];
        /* Managed transfer flags: bit 0 paused, bit 1 aborting, bit 2 directory.
           The classic transfer descriptor above stays byte-for-byte unchanged. */
        uint8_t flags=(uint8_t)((a->paused?1:0)|(a->aborting?2:0)|(a->is_directory?4:0));
        if(cr_buffer_append_u32(managed,a->transfer_id)||cr_buffer_append_u8(managed,a->kind)||
           cr_buffer_append_u32(managed,a->user_id)||cr_buffer_append_string16(managed,a->path,a->path_len)||
           cr_buffer_append_u64(managed,a->bytes_transferred)||cr_buffer_append_u64(managed,a->total_bytes)||
           cr_buffer_append_u8(managed,flags)||managed->len>UINT16_MAX){fail=1;break;}
        fields[n]=(cr_tlv_out){4,managed->data,(uint16_t)managed->len};n++;
    }
    uint64_t limit=s->server->download_bandwidth_limit_bps;
    uint64_t rate=current_download_traffic_rate_locked(s->server,monotonic_seconds());
    pthread_mutex_unlock(&s->server->mutex);
    cr_write_be64(limit_bytes,limit);cr_write_be64(rate_bytes,rate);
    fields[n++]=(cr_tlv_out){2,limit_bytes,8};
    fields[n++]=(cr_tlv_out){3,rate_bytes,8};
    int rc=fail?send_error(s,p->transaction_id,1):session_send(s,CMD_TRANSFER_INFO,p->transaction_id,fields,n);
    for(size_t i=0;i<CR_SERVER_MAX_ACTIVE_TRANSFERS*2;i++)cr_buffer_free(&values[i]);
    return rc;
}
static int handle_disconnect_user(cr_session *s, const cr_packet *p, int ban) {
    unsigned permission=ban?PERM_BAN_USERS:PERM_DISCONNECT_USERS;if(!account_perm(s,permission))return send_error(s,p->transaction_id,1);uint32_t uid;if(packet_target_user(p,&uid)||uid==s->user_id)return send_error(s,p->transaction_id,1);
    pthread_mutex_lock(&s->server->mutex);cr_session*t=find_session_locked(s->server,uid);if(!t){pthread_mutex_unlock(&s->server->mutex);return send_error(s,p->transaction_id,1);}
    if(ban){struct in_addr addr;if(inet_pton(AF_INET,t->peer_ip,&addr)!=1||cr_state_prepend_ipv4_ban(&s->server->state,(const uint8_t*)&addr)){pthread_mutex_unlock(&s->server->mutex);return send_error(s,p->transaction_id,1);}}
    session_send(t,CMD_FORCE_DISCONNECT,0,NULL,0);shutdown(t->fd,SHUT_RDWR);pthread_mutex_unlock(&s->server->mutex);
    int rc=send_task_complete(s,p->transaction_id);log_msg("User %u %s by user %u",uid,ban?"banned":"disconnected",s->user_id);return rc;
}

static void broadcast_all_sessions(cr_server*s,uint32_t command,const cr_tlv_out*fields,size_t field_count){pthread_mutex_lock(&s->mutex);for(size_t i=0;i<s->allocated_session_count;i++){cr_session*x=s->sessions[i];if(session_ready_for_async(x))session_send(x,command,0,fields,field_count);}pthread_mutex_unlock(&s->mutex);}

static int flat_news_header(cr_session*s,cr_buffer*out){
    static const char*wday[]={"Sun","Mon","Tue","Wed","Thu","Fri","Sat"};static const char*mon[]={"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"};
    time_t now=time(NULL);struct tm t;localtime_r(&now,&t);char date[64];snprintf(date,sizeof(date),"%s, %02d %s %04d %02d:%02d:%02d",wday[t.tm_wday],t.tm_mday,mon[t.tm_mon],t.tm_year+1900,t.tm_hour,t.tm_min,t.tm_sec);
    uint8_t login[512];size_t ln=0;if(cr_utf8_to_macroman(s->login,login,sizeof(login),&ln))return-1;out->len=0;
    return cr_buffer_append(out,"From: ",6)||cr_buffer_append(out,s->nickname,s->nickname_len)||cr_buffer_append(out," (",2)||cr_buffer_append(out,login,ln)||cr_buffer_append(out,")\rDate: ",8)||cr_buffer_append(out,date,strlen(date))||cr_buffer_append(out,"\r\r",2)?-1:0;
}
static int flat_news_is_tagged_utf8(const uint8_t*data,size_t len){return data&&len>=3&&data[0]==0xef&&data[1]==0xbb&&data[2]==0xbf;}
static int flat_news_content_blank(const uint8_t*data,size_t len){
    if(!data||!len)return 1;
    size_t start=flat_news_is_tagged_utf8(data,len)?3:0;
    if(start==len)return 1;
    for(size_t i=start;i<len;i++){
        uint8_t c=data[i];
        if(c!=0&&c!=' '&&c!='\t'&&c!='\r'&&c!='\n'&&c!='\v'&&c!='\f'&&c!=0xcau)return 0;
    }
    return 1;
}
static int flat_news_make_entry(cr_session*s,const uint8_t*content,size_t content_len,cr_buffer*out){
    cr_buffer header;cr_buffer_init(&header);out->len=0;
    if(flat_news_header(s,&header)){cr_buffer_free(&header);return-1;}
    if(flat_news_is_tagged_utf8(content,content_len)){
        if(!s->modern_transport||content_len==3||!valid_utf8_bytes(content+3,content_len-3)||memchr(content+3,0,content_len-3)){cr_buffer_free(&header);return-1;}
        char header_utf8[4096];
        if(cr_macroman_to_utf8(header.data,header.len,header_utf8,sizeof(header_utf8))){cr_buffer_free(&header);return-1;}
        static const uint8_t bom[3]={0xef,0xbb,0xbf};
        if(cr_buffer_append(out,bom,sizeof(bom))||cr_buffer_append(out,header_utf8,strlen(header_utf8))||cr_buffer_append(out,content+3,content_len-3)){cr_buffer_free(&header);return-1;}
    }else if(cr_buffer_append(out,header.data,header.len)||cr_buffer_append(out,content,content_len)){cr_buffer_free(&header);return-1;}
    cr_buffer_free(&header);
    return out->len<=UINT16_MAX?0:-1;
}
static int flat_news_wire_entry(const cr_buffer*stored,int modern,cr_buffer*out){
    out->len=0;
    if(modern||!flat_news_is_tagged_utf8(stored->data,stored->len))return cr_buffer_append(out,stored->data,stored->len);
    if(stored->len==3||!valid_utf8_bytes(stored->data+3,stored->len-3)||memchr(stored->data+3,0,stored->len-3))return-1;
    char*utf8=malloc(stored->len-2);if(!utf8)return-1;
    memcpy(utf8,stored->data+3,stored->len-3);utf8[stored->len-3]=0;
    uint8_t*mac=malloc(stored->len?stored->len:1);if(!mac){free(utf8);return-1;}size_t mn=0;
    int rc=cr_utf8_to_macroman(utf8,mac,stored->len,&mn)||mn>UINT16_MAX||cr_buffer_append(out,mac,mn);
    free(mac);free(utf8);return rc?-1:0;
}
static void broadcast_flat_news_entry(cr_server*server,const cr_buffer*stored){
    pthread_mutex_lock(&server->mutex);
    for(size_t i=0;i<server->allocated_session_count;i++){
        cr_session*x=server->sessions[i];if(!session_ready_for_async(x))continue;
        cr_buffer wire;cr_buffer_init(&wire);
        if(!flat_news_wire_entry(stored,x->modern_transport,&wire)){
            cr_tlv_out f={CMD_FLAT_NEWS_POST,wire.data,(uint16_t)wire.len};session_send(x,CMD_FLAT_NEWS_POST,0,&f,1);
        }
        cr_buffer_free(&wire);
    }
    pthread_mutex_unlock(&server->mutex);
}
static int handle_flat_news_post(cr_session*s,const cr_packet*p){
    const cr_tlv*content=cr_packet_field(p,CMD_FLAT_NEWS_POST);if(!account_perm(s,PERM_POST_FLAT_NEWS)||!content||flat_news_content_blank(content->value,content->length))return send_error(s,p->transaction_id,2);
    if(flat_news_is_tagged_utf8(content->value,content->length)&&!s->modern_transport)return send_error(s,p->transaction_id,2);
    cr_buffer entry;cr_buffer_init(&entry);if(flat_news_make_entry(s,content->value,content->length,&entry)){cr_buffer_free(&entry);return send_error(s,p->transaction_id,1);}uint32_t idx=0;if(cr_flat_news_append(&s->server->flat_news,entry.data,entry.len,&idx)){cr_buffer_free(&entry);return send_error(s,p->transaction_id,1);}broadcast_flat_news_entry(s->server,&entry);int rc=send_task_complete(s,p->transaction_id);cr_buffer_free(&entry);log_msg("Flat news article %u posted by user %u",idx,s->user_id);return rc;
}
static int handle_flat_news_list(cr_session*s,const cr_packet*p){
    cr_buffer*entries=NULL;size_t count=0;if(cr_flat_news_all(&s->server->flat_news,&entries,&count)||count>CR_MAX_TLVS){cr_flat_news_entries_free(entries,count);return send_error(s,p->transaction_id,1);}
    cr_tlv_out*fields=calloc(count?count:1,sizeof(*fields));cr_buffer*wire=calloc(count?count:1,sizeof(*wire));if(!fields||!wire){free(fields);free(wire);cr_flat_news_entries_free(entries,count);return send_error(s,p->transaction_id,1);}
    int failed=0;for(size_t i=0;i<count;i++){cr_buffer_init(&wire[i]);if(flat_news_wire_entry(&entries[i],s->modern_transport,&wire[i])||wire[i].len>UINT16_MAX){failed=1;break;}fields[i]=(cr_tlv_out){CMD_FLAT_NEWS_POST,wire[i].data,(uint16_t)wire[i].len};}
    int rc=failed?send_error(s,p->transaction_id,1):session_send(s,CMD_FLAT_NEWS_LIST,p->transaction_id,fields,count);
    for(size_t i=0;i<count;i++) {
        cr_buffer_free(&wire[i]);
    }
    free(wire);
    free(fields);
    cr_flat_news_entries_free(entries,count);
    return rc;
}

static int handle_flat_news_delete(cr_session*s,const cr_packet*p){if(!account_perm(s,PERM_MANAGE_NEWSGROUPS))return send_error(s,p->transaction_id,2);const cr_tlv*f=cr_packet_field(p,CMD_FLAT_NEWS_DELETE);if(!f||f->length!=4)return send_error(s,p->transaction_id,2);uint32_t index=cr_read_be32(f->value);if(cr_flat_news_delete(&s->server->flat_news,index))return send_error(s,p->transaction_id,1);broadcast_all_sessions(s->server,CMD_FLAT_NEWS_DELETE,(cr_tlv_out[]){{CMD_FLAT_NEWS_DELETE,f->value,4}},1);return send_task_complete(s,p->transaction_id);}
static int handle_flat_news_clear(cr_session*s,const cr_packet*p){if(!account_perm(s,PERM_MANAGE_NEWSGROUPS))return send_error(s,p->transaction_id,2);if(cr_flat_news_clear(&s->server->flat_news))return send_error(s,p->transaction_id,1);broadcast_all_sessions(s->server,CMD_FLAT_NEWS_CLEAR,NULL,0);return send_task_complete(s,p->transaction_id);}

static int handle_broadcast(cr_session *s, const cr_packet *p) {
    const cr_tlv *message=cr_packet_field(p,1);
    if(!account_perm(s,PERM_BROADCAST)||!message||!message->length||message->length>0x200)return send_error(s,p->transaction_id,2);
    int tagged=wire_is_tagged_utf8(message->value,message->length);
    if(tagged){
        size_t utf8_len=message->length-3;
        if(!s->modern_transport||!utf8_len||!valid_utf8_bytes(message->value+3,utf8_len)||memchr(message->value+3,0,utf8_len))return send_error(s,p->transaction_id,2);
    }
    uint8_t classic[0x200];size_t classic_len=0;
    int classic_ready=!tagged||!classic_text_describing_emoji(message->value,message->length,classic,sizeof(classic),&classic_len);
    uint8_t uid[4];
    cr_write_be32(uid,s->user_id);
    pthread_mutex_lock(&s->server->mutex);
    for(size_t i=0;i<s->server->allocated_session_count;i++){
        cr_session*x=s->server->sessions[i];
        if(!session_ready_for_async(x))continue;
        const uint8_t*wire=message->value;
        size_t wire_len=message->length;
        if(tagged&&!x->modern_transport){
            if(!classic_ready||!classic_len)continue;
            wire=classic;wire_len=classic_len;
        }
        cr_tlv_out f[]={{1,wire,(uint16_t)wire_len},{2,uid,4}};
        session_send(x,CMD_BROADCAST,0,f,2);
    }
    pthread_mutex_unlock(&s->server->mutex);
    cr_state_stat_add(&s->server->state,"totalMessages",1);
    return send_task_complete(s,p->transaction_id);
}

static int handle_channel_settings(cr_session*s,const cr_packet*p){
    const cr_tlv*id=cr_packet_field(p,CHANNEL_FIELD_ID);if(!id||id->length!=4)return 0;uint32_t cid=cr_read_be32(id->value);const cr_tlv*topic=cr_packet_field(p,CHANNEL_FIELD_TOPIC),*settings=cr_packet_field(p,CHANNEL_FIELD_SETTINGS);if(topic&&topic->length>0x100)return 0;uint16_t requested=settings&&settings->length==2?cr_read_be16(settings->value):0;
    uint8_t out_topic[256];size_t out_topic_n=0;uint16_t flags=0;uint8_t cb[4],fb[2];cr_write_be32(cb,cid);
    pthread_mutex_lock(&s->server->mutex);cr_channel*c=channel_by_id_locked(s->server,cid);int idx=c?channel_member_index(c,s->user_id):-1;if(idx<0){pthread_mutex_unlock(&s->server->mutex);return 0;}int isop=(c->members[idx].mode&CHANNEL_OPERATOR)!=0;if(topic&&(topic->length!=c->topic_len||memcmp(topic->value,c->topic,topic->length))){if((c->flags&0x2000u)&&!isop){pthread_mutex_unlock(&s->server->mutex);return p->transaction_id?send_error(s,p->transaction_id,0xcd):0;}c->topic_len=topic->length;memcpy(c->topic,topic->value,topic->length);}if(isop&&cid!=1){uint16_t preserved=c->flags&(CHANNEL_PERMANENT|0x4000u);c->flags=(requested&~(CHANNEL_PERMANENT|0x4000u))|preserved;c->flags&=~CHANNEL_PERMANENT;}out_topic_n=c->topic_len;memcpy(out_topic,c->topic,out_topic_n);flags=c->flags;cr_write_be16(fb,flags);cr_tlv_out f[]={{CHANNEL_FIELD_ID,cb,4},{CHANNEL_FIELD_TOPIC,out_topic,(uint16_t)out_topic_n},{CHANNEL_FIELD_SETTINGS,fb,2}};for(size_t i=0;i<c->member_count;i++){cr_session*x=find_session_locked(s->server,c->members[i].user_id);if(x)session_send(x,CMD_CHANNEL_SETTINGS,0,f,3);}pthread_mutex_unlock(&s->server->mutex);return send_task_complete(s,p->transaction_id);
}

static int handle_channel_user_mode(cr_session*s,const cr_packet*p){
    const cr_tlv*id=cr_packet_field(p,CHANNEL_FIELD_ID),*target=cr_packet_field(p,CHANNEL_FIELD_USER_ID),*modef=cr_packet_field(p,CHANNEL_FIELD_USER_MODE);if(!id||id->length!=4||!target||target->length!=4||!modef||modef->length<1)return 0;uint32_t cid=cr_read_be32(id->value),uid=cr_read_be32(target->value);uint8_t mode=modef->value[0],cb[4],ub[4];cr_write_be32(cb,cid);cr_write_be32(ub,uid);cr_tlv_out f[]={{CHANNEL_FIELD_ID,cb,4},{CHANNEL_FIELD_USER_ID,ub,4},{CHANNEL_FIELD_USER_MODE,&mode,1}};
    pthread_mutex_lock(&s->server->mutex);cr_channel*c=channel_by_id_locked(s->server,cid);int ridx=c?channel_member_index(c,s->user_id):-1,tidx=c?channel_member_index(c,uid):-1;if(ridx<0||tidx<0||(c->members[ridx].mode&CHANNEL_OPERATOR)==0){pthread_mutex_unlock(&s->server->mutex);return p->transaction_id?send_error(s,p->transaction_id,0xcc):0;}c->members[tidx].mode=mode;for(size_t i=0;i<c->member_count;i++){cr_session*x=find_session_locked(s->server,c->members[i].user_id);if(x)session_send(x,CMD_CHANNEL_USER_MODE,0,f,3);}pthread_mutex_unlock(&s->server->mutex);return send_task_complete(s,p->transaction_id);
}

static int handle_channel_invite(cr_session*s,const cr_packet*p){
    const cr_tlv*id=cr_packet_field(p,CHANNEL_FIELD_ID),*target=cr_packet_field(p,CHANNEL_FIELD_USER_ID);if(!id||id->length!=4||!target||target->length!=4)return 0;uint32_t cid=cr_read_be32(id->value),uid=cr_read_be32(target->value);uint8_t name[64];size_t nn=0;uint8_t cb[4],inv[4];cr_write_be32(cb,cid);cr_write_be32(inv,s->user_id);
    pthread_mutex_lock(&s->server->mutex);cr_channel*c=channel_by_id_locked(s->server,cid);cr_session*t=find_session_locked(s->server,uid);if(c&&t&&channel_member_index(c,uid)<0){nn=c->name_len;memcpy(name,c->name,nn);cr_tlv_out f[]={{CHANNEL_FIELD_ID,cb,4},{0x0b,inv,4},{CHANNEL_FIELD_NAME,name,(uint16_t)nn}};session_send(t,CMD_CHANNEL_INVITE,0,f,3);}else t=NULL;pthread_mutex_unlock(&s->server->mutex);if(!t)return 0;return send_task_complete(s,p->transaction_id);
}

static int handle_channel_decline(cr_session*s,const cr_packet*p){
    const cr_tlv*id=cr_packet_field(p,CHANNEL_FIELD_ID),*inviter=cr_packet_field(p,0x0b);if(!id||id->length!=4||!inviter||inviter->length!=4)return 0;uint32_t cid=cr_read_be32(id->value),iid=cr_read_be32(inviter->value);uint8_t cb[4],ub[4];cr_write_be32(cb,cid);cr_write_be32(ub,s->user_id);cr_tlv_out f[]={{CHANNEL_FIELD_ID,cb,4},{CHANNEL_FIELD_USER_ID,ub,4}};
    pthread_mutex_lock(&s->server->mutex);cr_channel*c=channel_by_id_locked(s->server,cid);cr_session*t=find_session_locked(s->server,iid);int valid=c&&t&&channel_member_index(c,iid)>=0;if(valid)session_send(t,CMD_CHANNEL_DECLINE,0,f,2);pthread_mutex_unlock(&s->server->mutex);return valid?0:0;
}

static size_t fixed_cstring_length(const uint8_t *data, size_t width) {
    size_t n=0; while(n<width && data[n]) n++; return n;
}
static int append_fixed_cstring(cr_buffer *out,const uint8_t *data,size_t len,size_t width){
    if(len>=width)return-1;
    if(cr_buffer_reserve(out,width))return-1;
    memset(out->data+out->len,0,width); if(len)memcpy(out->data+out->len,data,len); out->len+=width; return 0;
}
static uint64_t permission_bits_from_wire_bytes(const uint8_t bytes[8]){
    uint64_t bits=0;for(unsigned bit=0;bit<64;bit++)if(bytes[bit/8]&(uint8_t)(0x80u>>(bit%8)))bits|=1ULL<<bit;return bits;
}
static int encode_account_summary(const cr_account *a,cr_buffer*out){
    uint8_t login[512],name[1024];size_t ln=0,nn=0;
    if(cr_utf8_to_macroman(a->login,login,sizeof(login),&ln)||cr_utf8_to_macroman(a->name,name,sizeof(name),&nn))return-1;
    uint8_t mode=a->mode==CR_MODE_ADMIN?2:a->mode==CR_MODE_ACCOUNT?1:0;
    if(append_fixed_cstring(out,login,ln,64)||append_fixed_cstring(out,name,nn,66)||cr_buffer_append_u32(out,cr_iso8601_to_mac_timestamp(a->last_login_at))||cr_buffer_append_u8(out,mode)||cr_buffer_append_u8(out,0))return-1;
    return 0;
}
static int encode_account_record(const cr_account *a,int include_password,int include_extensions,cr_buffer*out){
    uint8_t login[512],name[1024],pw[1024],perms[8];size_t ln=0,nn=0,pn=0;
    if(cr_utf8_to_macroman(a->login,login,sizeof(login),&ln)||cr_utf8_to_macroman(a->name,name,sizeof(name),&nn))return-1;
    if(include_password&&a->has_legacy_password&&cr_utf8_to_macroman(a->legacy_password,pw,sizeof(pw),&pn))return-1;
    cr_account_permission_bytes(a,perms);
    if(!include_extensions)perms[PERM_POST_NEWS/8]&=(uint8_t)~(0x80u>>(PERM_POST_NEWS%8));
    if(append_fixed_cstring(out,login,ln,64)||append_fixed_cstring(out,name,nn,65)||append_fixed_cstring(out,pw,pn,65)||
       cr_buffer_append_u32(out,cr_iso8601_to_mac_timestamp(a->created_at))||cr_buffer_append_u32(out,cr_iso8601_to_mac_timestamp(a->modified_at))||
       cr_buffer_append_u32(out,cr_iso8601_to_mac_timestamp(a->last_login_at))||cr_buffer_append(out,perms,8))return-1;
    return 0;
}
static int decode_account_record(const uint8_t *raw,size_t len,char*login,size_t login_cap,char*name,size_t name_cap,char*password,size_t pw_cap,uint64_t*permission_bits){
    if(len!=0xd6)return-1;
    size_t ln=fixed_cstring_length(raw,64),nn=fixed_cstring_length(raw+64,65),pn=fixed_cstring_length(raw+129,65);
    if(!ln||cr_macroman_to_utf8(raw,ln,login,login_cap)||cr_macroman_to_utf8(raw+64,nn,name,name_cap)||cr_macroman_to_utf8(raw+129,pn,password,pw_cap))return-1;
    *permission_bits=permission_bits_from_wire_bytes(raw+206);return 0;
}
static void broadcast_to_permission(cr_server*s,unsigned permission,uint32_t command,const cr_tlv_out*fields,size_t field_count){
    pthread_mutex_lock(&s->mutex);
    for(size_t i=0;i<s->allocated_session_count;i++){cr_session*x=s->sessions[i];if(session_ready_for_async(x)&&account_perm(x,permission))session_send(x,command,0,fields,field_count);}
    pthread_mutex_unlock(&s->mutex);
}
static void broadcast_to_modern_permission(cr_server*s,unsigned permission,uint32_t command,const cr_tlv_out*fields,size_t field_count){
    pthread_mutex_lock(&s->mutex);
    for(size_t i=0;i<s->allocated_session_count;i++){cr_session*x=s->sessions[i];if(session_ready_for_async(x)&&x->modern_transport&&account_perm(x,permission))session_send(x,command,0,fields,field_count);}
    pthread_mutex_unlock(&s->mutex);
}
static int handle_bot_status(cr_session*s,const cr_packet*p){
    if(!s->modern_transport||!account_perm(s,PERM_MANAGE_ACCOUNTS))return send_error(s,p->transaction_id,1);
    cr_bot_configuration cfg;if(bot_load_configuration(s->server,&cfg))return send_error(s,p->transaction_id,1);
    char login[256]="",name[512]="";int found=0;
    pthread_mutex_lock(&s->server->state.mutex);
    for(size_t i=0;i<s->server->state.account_count;i++){
        cr_account*a=&s->server->state.accounts[i];if(strcasecmp(a->id,CR_LOCAL_BOT_ACCOUNT_ID))continue;
        if(!a->local_login_only)break;
        snprintf(login,sizeof(login),"%s",a->login);
        snprintf(name,sizeof(name),"%s",a->name);
        found=1;
        break;
    }
    pthread_mutex_unlock(&s->server->state.mutex);if(!found)return send_error(s,p->transaction_id,1);
    uint8_t desired=(uint8_t)(cfg.enabled?1:0),connected=(uint8_t)(bot_connected(s->server)?1:0),greet=(uint8_t)(cfg.greet_new_users?1:0);
    cr_buffer rules;if(bot_encode_command_rules(&cfg,&rules)||rules.len>UINT16_MAX){cr_buffer_free(&rules);return send_error(s,p->transaction_id,1);}
    cr_bot_rss_feed feeds[CR_BOT_RSS_MAX_FEEDS];size_t feed_count=0;cr_buffer rss;cr_buffer_init(&rss);
    if(cr_bot_rss_load_feeds(s->server->bot_config_path,feeds,CR_BOT_RSS_MAX_FEEDS,&feed_count)||
       bot_encode_rss_feeds(feeds,feed_count,&rss)||rss.len>UINT16_MAX){cr_buffer_free(&rules);cr_buffer_free(&rss);return send_error(s,p->transaction_id,1);}
    cr_tlv_out fields[]={{1,&desired,1},{2,&connected,1},{3,(const uint8_t*)login,(uint16_t)strlen(login)},{4,(const uint8_t*)name,(uint16_t)strlen(name)},
                         {6,&greet,1},{7,(const uint8_t*)cfg.greeting_template,(uint16_t)strlen(cfg.greeting_template)},{8,rules.data,(uint16_t)rules.len},
                         {9,rss.data,(uint16_t)rss.len}};
    int rc=session_send(s,CMD_BOT_STATUS_REPLY,p->transaction_id,fields,8);cr_buffer_free(&rules);cr_buffer_free(&rss);return rc;
}
static int handle_bot_set_enabled(cr_session*s,const cr_packet*p){
    if(!s->modern_transport||!account_perm(s,PERM_MANAGE_ACCOUNTS))return send_error(s,p->transaction_id,1);
    const cr_tlv*f=cr_packet_field(p,1);if(!f||f->length!=1||f->value[0]>1)return send_error(s,p->transaction_id,1);
    if(bot_store_enabled(s->server,f->value[0]!=0))return send_error(s,p->transaction_id,1);
    return send_task_complete(s,p->transaction_id);
}

static int handle_bot_set_greeting(cr_session*s,const cr_packet*p){
    if(!s->modern_transport||!account_perm(s,PERM_MANAGE_ACCOUNTS))return send_error(s,p->transaction_id,1);
    const cr_tlv*enabled=cr_packet_field(p,6),*template=cr_packet_field(p,7);
    if(!enabled||enabled->length!=1||enabled->value[0]>1||!template||!template->length||template->length>CR_BOT_GREETING_MAX_BYTES||
       !valid_utf8_bytes(template->value,template->length)||memchr(template->value,0,template->length)||memchr(template->value,'\n',template->length)||memchr(template->value,'\r',template->length))return send_error(s,p->transaction_id,1);
    if(bot_store_greeting(s->server,enabled->value[0]!=0,template->value,template->length))return send_error(s,p->transaction_id,1);
    log_msg("Bot greeting configuration updated remotely: enabled=%s",enabled->value[0]?"true":"false");
    return send_task_complete(s,p->transaction_id);
}

static int handle_bot_set_command_rules(cr_session*s,const cr_packet*p){
    if(!s->modern_transport||!account_perm(s,PERM_MANAGE_ACCOUNTS))return send_error(s,p->transaction_id,1);
    const cr_tlv*rules=cr_packet_field(p,8);if(!rules||rules->length<2)return send_error(s,p->transaction_id,1);
    if(bot_store_command_rules(s->server,rules->value,rules->length))return send_error(s,p->transaction_id,1);
    log_msg("Bot command rules updated remotely");return send_task_complete(s,p->transaction_id);
}

static int handle_bot_set_rss_feeds(cr_session*s,const cr_packet*p){
    if(!s->modern_transport||!account_perm(s,PERM_MANAGE_ACCOUNTS))return send_error(s,p->transaction_id,1);
    const cr_tlv*field=cr_packet_field(p,9);if(!field||field->length<2)return send_error(s,p->transaction_id,1);
    cr_bot_rss_feed feeds[CR_BOT_RSS_MAX_FEEDS];size_t count=0;
    if(bot_decode_rss_feeds(field->value,field->length,feeds,&count)||
       cr_bot_rss_store_feeds(s->server->bot_config_path,feeds,count))return send_error(s,p->transaction_id,1);
    log_msg("Bot RSS feeds updated remotely: %zu feed(s)",count);
    return send_task_complete(s,p->transaction_id);
}

static int handle_bot_test_rss_feed(cr_session*s,const cr_packet*p){
    if(!s->modern_transport||!account_perm(s,PERM_MANAGE_ACCOUNTS))return send_error(s,p->transaction_id,1);
    const cr_tlv*field=cr_packet_field(p,9);if(!field||field->length<2)return send_error(s,p->transaction_id,1);
    cr_bot_rss_feed feeds[CR_BOT_RSS_MAX_FEEDS];size_t count=0;
    if(bot_decode_rss_feeds(field->value,field->length,feeds,&count)||count!=1)return send_error(s,p->transaction_id,1);
    cr_bot_rss_feed test_feed=feeds[0];test_feed.channel_id=1;
    cr_bot_rss_article article;memset(&article,0,sizeof(article));
    if(cr_bot_rss_test_feed(&test_feed,&article))return send_error(s,p->transaction_id,1);
    cr_buffer preview;int fail=bot_encode_rss_preview(&article,&preview);
    if(fail||preview.len>UINT16_MAX){cr_buffer_free(&preview);cr_bot_rss_article_free(&article);return send_error(s,p->transaction_id,1);}
    cr_tlv_out response={10,preview.data,(uint16_t)preview.len};
    int rc=session_send(s,CMD_BOT_RSS_FEED_TEST_REPLY,p->transaction_id,&response,1);
    cr_buffer_free(&preview);
    if(rc){cr_bot_rss_article_free(&article);return rc;}
    /* Reply first, then emit the asynchronous conference event. A failed RSS test post is
       not a fatal control-session error and must never disconnect the administrator. */
    if(bot_publish_rss_article_to_server(s->server,&test_feed,&article))
        log_msg("Bot RSS test fetched an article but could not post it to Public");
    cr_bot_rss_article_free(&article);
    return 0;
}

static int handle_account_list(cr_session*s,const cr_packet*p){
    if(!account_perm(s,PERM_MANAGE_ACCOUNTS))return send_error(s,p->transaction_id,1);
    cr_buffer b,stats;cr_buffer_init(&b);cr_buffer_init(&stats);
    pthread_mutex_lock(&s->server->state.mutex);
    size_t count=s->server->state.account_count;
    int fail=cr_buffer_append_u32(&b,(uint32_t)count);
    int stats_fail=s->modern_transport?cr_buffer_append_u32(&stats,(uint32_t)count):0;
    for(size_t i=0;!fail&&!stats_fail&&i<count;i++){
        cr_account*a=&s->server->state.accounts[i];
        fail=encode_account_summary(a,&b);
        if(s->modern_transport){
            uint64_t dc=0,db=0,uc=0,ub=0;
            if(cr_sqlite_account_transfer_statistics(s->server->state.db,a->id,&dc,&db,&uc,&ub)||
               cr_buffer_append_u64(&stats,dc)||cr_buffer_append_u64(&stats,db)||
               cr_buffer_append_u64(&stats,uc)||cr_buffer_append_u64(&stats,ub))stats_fail=1;
        }
    }
    pthread_mutex_unlock(&s->server->state.mutex);
    if(fail||stats_fail||b.len>UINT16_MAX||stats.len>UINT16_MAX){cr_buffer_free(&stats);cr_buffer_free(&b);return send_error(s,p->transaction_id,1);}
    cr_tlv_out fields[2];size_t n=0;
    fields[n++]=(cr_tlv_out){0x10,b.data,(uint16_t)b.len};
    if(s->modern_transport)fields[n++]=(cr_tlv_out){ACCOUNT_FIELD_TRANSFER_STATISTICS,stats.data,(uint16_t)stats.len};
    int rc=session_send(s,CMD_ACCOUNT_LIST,p->transaction_id,fields,n);
    cr_buffer_free(&stats);cr_buffer_free(&b);return rc;
}
static int handle_get_account(cr_session*s,const cr_packet*p){
    if(!account_perm(s,PERM_MANAGE_ACCOUNTS))return send_error(s,p->transaction_id,1);
    const cr_tlv*lf=cr_packet_field(p,2);if(!lf||!lf->length||lf->length>31)return send_error(s,p->transaction_id,1);char login[256];if(cr_macroman_to_utf8(lf->value,lf->length,login,sizeof(login)))return send_error(s,p->transaction_id,1);cr_buffer b;cr_buffer_init(&b);int fail=1;
    char group_id[64]="";uint32_t account_color=0;int has_color=0,local_only=0;uint8_t*picture=NULL;size_t picture_len=0;pthread_mutex_lock(&s->server->state.mutex);int idx=cr_state_find_account(&s->server->state,login);if(idx>=0){cr_account*a=&s->server->state.accounts[idx];fail=encode_account_record(a,s->server->state.legacy_compatible,s->modern_transport,&b);snprintf(group_id,sizeof(group_id),"%s",a->group_id);account_color=a->color_rgb;has_color=a->has_color;local_only=a->local_login_only;if(a->picture_len){picture=malloc(a->picture_len);if(!picture)fail=1;else{memcpy(picture,a->picture,a->picture_len);picture_len=a->picture_len;}}}pthread_mutex_unlock(&s->server->state.mutex);
    if(fail||b.len!=0xd6||picture_len>UINT16_MAX){free(picture);cr_buffer_free(&b);return send_error(s,p->transaction_id,1);}cr_tlv_out f[5];size_t n=0;uint8_t color_wire[4],local_wire=(uint8_t)(local_only?1:0);f[n++]=(cr_tlv_out){1,b.data,(uint16_t)b.len};if(s->modern_transport&&group_id[0])f[n++]=(cr_tlv_out){ACCOUNT_FIELD_GROUP_ID,(const uint8_t*)group_id,(uint16_t)strlen(group_id)};if(s->modern_transport&&has_color){cr_write_be32(color_wire,account_color);f[n++]=(cr_tlv_out){ACCOUNT_FIELD_COLOR_RGB,color_wire,4};}if(s->modern_transport){f[n++]=(cr_tlv_out){ACCOUNT_FIELD_PICTURE,picture,(uint16_t)picture_len};f[n++]=(cr_tlv_out){ACCOUNT_FIELD_LOCAL_LOGIN_ONLY,&local_wire,1};}int rc=session_send(s,CMD_ACCOUNT_REPLY,p->transaction_id,f,n);free(picture);cr_buffer_free(&b);return rc;
}
static int synchronize_personal_account_home(cr_server*s,const char*old_login,cr_personal_mode old_personal,const char*new_login,cr_personal_mode new_personal){
    if(new_personal==CR_PERSONAL_NONE)return 0;
    if(!safe_component(new_login)||(old_login&&*old_login&&!safe_component(old_login)))return-1;
    char target[PATH_MAX];if(join_path_component(target,sizeof(target),s->state.personal_home_root,new_login))return-1;
    if(old_login&&*old_login&&strcmp(old_login,new_login)&&old_personal!=CR_PERSONAL_NONE){
        char old[PATH_MAX];if(join_path_component(old,sizeof(old),s->state.personal_home_root,old_login))return-1;
        struct stat ost,tst;int old_exists=lstat(old,&ost)==0,target_exists=lstat(target,&tst)==0;
        if(old_exists&&S_ISDIR(ost.st_mode)&&!S_ISLNK(ost.st_mode)&&!target_exists){if(rename(old,target))return-1;target_exists=1;}
    }
    if(mkdir(target,0755)&&errno!=EEXIST)return-1;
    return 0;
}

static int handle_account_save(cr_session*s,const cr_packet*p){
    if(!account_perm(s,PERM_MANAGE_ACCOUNTS))return send_error(s,p->transaction_id,1);
    const cr_tlv*rf=cr_packet_field(p,1),*of=cr_packet_field(p,3);const cr_tlv*gf=s->modern_transport?cr_packet_field(p,ACCOUNT_FIELD_GROUP_ID):NULL,*cf=s->modern_transport?cr_packet_field(p,ACCOUNT_FIELD_COLOR_RGB):NULL,*pf=s->modern_transport?cr_packet_field(p,ACCOUNT_FIELD_PICTURE):NULL;if(!rf)return send_error(s,p->transaction_id,1);char login[256],name[512],password[512],old_login[256]="",group_id[64]="";uint64_t bits=0;uint32_t account_color=0;int has_color=0;if(decode_account_record(rf->value,rf->length,login,sizeof(login),name,sizeof(name),password,sizeof(password),&bits))return send_error(s,p->transaction_id,1);if(of){if(of->length>63||cr_macroman_to_utf8(of->value,of->length,old_login,sizeof(old_login)))return send_error(s,p->transaction_id,1);}if(gf){if(!gf->length||gf->length>=sizeof(group_id))return send_error(s,p->transaction_id,1);memcpy(group_id,gf->value,gf->length);group_id[gf->length]=0;}if(cf){if(cf->length!=4)return send_error(s,p->transaction_id,1);account_color=cr_read_be32(cf->value);if(account_color>0x00ffffffu)return send_error(s,p->transaction_id,1);has_color=1;}
    cr_personal_mode old_personal=CR_PERSONAL_NONE;pthread_mutex_lock(&s->server->state.mutex);if(*old_login){int oi=cr_state_find_account(&s->server->state,old_login);if(oi>=0){old_personal=s->server->state.accounts[oi].personal;if(!s->modern_transport&&(s->server->state.accounts[oi].permission_bits&(1ULL<<PERM_POST_NEWS)))bits|=1ULL<<PERM_POST_NEWS;}}else if(!s->modern_transport){cr_account_mode intended=(bits&1ULL)?CR_MODE_ADMIN:(bits&(1ULL<<1))?CR_MODE_ACCOUNT:CR_MODE_GUEST;for(size_t gi=0;gi<s->server->state.account_group_count;gi++){cr_account_group*g=&s->server->state.account_groups[gi];if(g->mode==intended&&(g->permission_bits&(1ULL<<PERM_POST_NEWS))){bits|=1ULL<<PERM_POST_NEWS;break;}}}pthread_mutex_unlock(&s->server->state.mutex);
    int action=0;if(cr_state_account_upsert(&s->server->state,old_login,login,name,password,bits,group_id,has_color,account_color,&action))return send_error(s,p->transaction_id,1);
    if(pf&&cr_state_account_set_picture(&s->server->state,login,pf->value,pf->length))return send_error(s,p->transaction_id,1);
    refresh_connected_account_state(s->server);
    cr_personal_mode new_personal=CR_PERSONAL_NONE;cr_buffer summary;cr_buffer_init(&summary);pthread_mutex_lock(&s->server->state.mutex);int idx=cr_state_find_account(&s->server->state,login);int fail=idx<0?1:encode_account_summary(&s->server->state.accounts[idx],&summary);if(idx>=0)new_personal=s->server->state.accounts[idx].personal;pthread_mutex_unlock(&s->server->state.mutex);if(fail||synchronize_personal_account_home(s->server,old_login,old_personal,login,new_personal)){cr_buffer_free(&summary);return send_error(s,p->transaction_id,1);}
    int rc=send_task_complete(s,p->transaction_id);uint8_t av=(uint8_t)action;cr_tlv_out event[3];size_t n=0;event[n++]=(cr_tlv_out){0x11,&av,1};if(of)event[n++]=(cr_tlv_out){3,of->value,of->length};event[n++]=(cr_tlv_out){1,summary.data,(uint16_t)summary.len};broadcast_to_modern_permission(s->server,PERM_MANAGE_ACCOUNTS,CMD_ACCOUNT_UPDATE,event,n);cr_buffer_free(&summary);log_msg("Account %s: %s",action?"modified":"created",login);return rc;
}
static int handle_change_own_password(cr_session*s,const cr_packet*p){
    const cr_tlv*pf=cr_packet_field(p,1);if(!pf||pf->length>64)return send_error(s,p->transaction_id,1);
    char password[512];if(cr_macroman_to_utf8(pf->value,pf->length,password,sizeof(password)))return send_error(s,p->transaction_id,1);
    if(cr_state_account_change_password(&s->server->state,s->account_id,password))return send_error(s,p->transaction_id,1);
    log_msg("Account password changed by user: %s",s->login);
    return send_task_complete(s,p->transaction_id);
}

static int handle_account_delete(cr_session*s,const cr_packet*p){
    if(!account_perm(s,PERM_MANAGE_ACCOUNTS))return send_error(s,p->transaction_id,1);
    const cr_tlv*lf=cr_packet_field(p,2);if(!lf||!lf->length||lf->length>31)return send_error(s,p->transaction_id,1);char login[256];if(cr_macroman_to_utf8(lf->value,lf->length,login,sizeof(login)))return send_error(s,p->transaction_id,1);if(cr_state_account_delete(&s->server->state,login))return send_error(s,p->transaction_id,1);int rc=send_task_complete(s,p->transaction_id);uint8_t av=2;cr_tlv_out event[]={{0x11,&av,1},{3,lf->value,lf->length}};broadcast_to_modern_permission(s->server,PERM_MANAGE_ACCOUNTS,CMD_ACCOUNT_UPDATE,event,2);log_msg("Account deleted: %s",login);return rc;
}
static uint16_t newsgroup_flags(const cr_newsgroup*g){uint16_t f=0;if(g->admin_read)f|=0x8000;if(g->admin_post)f|=0x4000;if(g->account_read)f|=0x2000;if(g->account_post)f|=0x1000;if(g->guest_read)f|=0x0800;if(g->guest_post)f|=0x0400;return f;}

static int lookup_newsgroup(cr_server*s,const uint8_t*wire,size_t wire_len,cr_newsgroup*out){if(!wire||!wire_len||wire_len>64)return-1;char name[512];if(cr_macroman_to_utf8(wire,wire_len,name,sizeof(name)))return-1;int found=0;pthread_mutex_lock(&s->state.mutex);for(size_t i=0;i<s->state.newsgroup_count;i++)if(!strcasecmp(s->state.newsgroups[i].name,name)){*out=s->state.newsgroups[i];found=1;break;}pthread_mutex_unlock(&s->state.mutex);return found?0:-1;}
static int group_can_read(const cr_newsgroup*g,cr_account_mode mode){return mode==CR_MODE_ADMIN?g->admin_read:mode==CR_MODE_ACCOUNT?g->account_read:g->guest_read;}
static int group_can_post(const cr_newsgroup*g,cr_account_mode mode){return mode==CR_MODE_ADMIN?g->admin_post:mode==CR_MODE_ACCOUNT?g->account_post:g->guest_post;}
static int synchronize_news_state(cr_server*s){char ids[CR_MAX_NEWSGROUPS][64];const char*ptrs[CR_MAX_NEWSGROUPS];size_t n=0;pthread_mutex_lock(&s->state.mutex);n=s->state.newsgroup_count;if(n>CR_MAX_NEWSGROUPS)n=CR_MAX_NEWSGROUPS;for(size_t i=0;i<n;i++){snprintf(ids[i],sizeof(ids[i]),"%s",s->state.newsgroups[i].id);ptrs[i]=ids[i];}pthread_mutex_unlock(&s->state.mutex);if(cr_news_prune(&s->news,ptrs,n))return-1;for(size_t i=0;i<n;i++){uint32_t count=0;if(cr_news_count(&s->news,ids[i],&count)||cr_state_set_newsgroup_article_count(&s->state,ids[i],count))return-1;}return cr_media_store_prune_news(&s->media,s->state.news_db_path);}
static int run_news_expiration(cr_server*s,time_t now){cr_newsgroup groups[CR_MAX_NEWSGROUPS];size_t n=0;pthread_mutex_lock(&s->state.mutex);n=s->state.newsgroup_count;if(n>CR_MAX_NEWSGROUPS)n=CR_MAX_NEWSGROUPS;memcpy(groups,s->state.newsgroups,n*sizeof(groups[0]));pthread_mutex_unlock(&s->state.mutex);int removed_total=0;for(size_t i=0;i<n;i++){uint32_t removed=0,count=0;if(cr_news_expire(&s->news,groups[i].id,groups[i].expire_after_seconds,now,&removed)||cr_news_count(&s->news,groups[i].id,&count)||cr_state_set_newsgroup_article_count(&s->state,groups[i].id,count))return-1;removed_total+=(int)removed;}if(cr_media_store_prune_news(&s->media,s->state.news_db_path))return-1;if(removed_total)log_msg("Expired %d article(s)",removed_total);return removed_total;}
static void maybe_run_news_expiration(cr_server*s){time_t now=time(NULL);struct tm tmv;localtime_r(&now,&tmv);uint8_t h=0,m=0;pthread_mutex_lock(&s->state.mutex);h=s->state.advanced.news_expiration_hour;m=s->state.advanced.news_expiration_minute;pthread_mutex_unlock(&s->state.mutex);time_t minute=now/60;if(tmv.tm_hour==h&&tmv.tm_min==m&&s->last_news_expiration_minute!=minute){s->last_news_expiration_minute=minute;(void)run_news_expiration(s,now);}}
static int handle_article_read(cr_session*s,const cr_packet*p){const cr_tlv*gf=cr_packet_field(p,1),*af=cr_packet_field(p,2);if(!gf||!af||af->length!=4)return send_error(s,p->transaction_id,1);cr_newsgroup g;if(lookup_newsgroup(s->server,gf->value,gf->length,&g)||!group_can_read(&g,s->mode))return send_error(s,p->transaction_id,1);cr_buffer meta,body;cr_buffer_init(&meta);cr_buffer_init(&body);int r=cr_news_reply(&s->server->news,g.id,gf->value,gf->length,cr_read_be32(af->value),&meta,&body);if(r){cr_buffer_free(&meta);cr_buffer_free(&body);return send_error(s,p->transaction_id,1);}if(meta.len>UINT16_MAX||body.len>UINT16_MAX){cr_buffer_free(&meta);cr_buffer_free(&body);return send_error(s,p->transaction_id,1);}cr_tlv_out f[]={{1,meta.data,(uint16_t)meta.len},{2,body.data,(uint16_t)body.len}};int rc=session_send(s,CMD_NEWSGROUP_LIST_REPLY,p->transaction_id,f,2);cr_buffer_free(&meta);cr_buffer_free(&body);return rc;}
static int handle_article_delete(cr_session*s,const cr_packet*p){if(!account_perm(s,PERM_MANAGE_NEWSGROUPS))return send_error(s,p->transaction_id,1);const cr_tlv*gf=cr_packet_field(p,1),*af=cr_packet_field(p,2);if(!gf||!af||af->length!=4)return send_error(s,p->transaction_id,1);cr_newsgroup g;if(lookup_newsgroup(s->server,gf->value,gf->length,&g))return send_error(s,p->transaction_id,1);int deleted=0;if(cr_news_delete(&s->server->news,g.id,cr_read_be32(af->value),&deleted)||!deleted)return send_error(s,p->transaction_id,1);uint32_t count=0;if(cr_news_count(&s->server->news,g.id,&count)||cr_state_set_newsgroup_article_count(&s->server->state,g.id,count)||cr_media_store_prune_news(&s->server->media,s->server->state.news_db_path))return send_error(s,p->transaction_id,1);return send_task_complete(s,p->transaction_id);}

static int handle_admin_newsgroup_list(cr_session*s,const cr_packet*p){
    if(!account_perm(s,PERM_MANAGE_NEWSGROUPS))return send_error(s,p->transaction_id,1);
    cr_buffer b;cr_buffer_init(&b);pthread_mutex_lock(&s->server->state.mutex);size_t count=s->server->state.newsgroup_count;int fail=cr_buffer_append_u32(&b,(uint32_t)count);for(size_t i=0;!fail&&i<count;i++){cr_newsgroup*g=&s->server->state.newsgroups[i];uint8_t name[1024];size_t nn=0;if(cr_utf8_to_macroman(g->name,name,sizeof(name),&nn)||cr_buffer_append_string16(&b,name,nn)||cr_buffer_append_u32(&b,g->article_count)||cr_buffer_append_u32(&b,g->expire_after_seconds)||cr_buffer_append_u16(&b,newsgroup_flags(g)))fail=1;}pthread_mutex_unlock(&s->server->state.mutex);if(fail||b.len>UINT16_MAX){cr_buffer_free(&b);return send_error(s,p->transaction_id,1);}cr_tlv_out f={2,b.data,(uint16_t)b.len};int rc=session_send(s,CMD_ADMIN_NEWSGROUP_LIST_REPLY,p->transaction_id,&f,1);cr_buffer_free(&b);return rc;
}
static int decode_newsgroup_fields(const cr_packet*p,char*name,size_t cap,uint32_t*expire,uint16_t*flags,const cr_tlv**name_field){const cr_tlv*n=cr_packet_field(p,1),*e=cr_packet_field(p,2),*f=cr_packet_field(p,3);if(!n||!n->length||n->length>64||!e||e->length!=4||!f||f->length!=2||cr_macroman_to_utf8(n->value,n->length,name,cap))return-1;*expire=cr_read_be32(e->value);*flags=cr_read_be16(f->value);if(name_field)*name_field=n;return 0;}
static int handle_newsgroup_admin_mutation(cr_session*s,const cr_packet*p,int action){
    if(!account_perm(s,PERM_MANAGE_NEWSGROUPS))return send_error(s,p->transaction_id,1);
    char name[512],old_name[512];uint32_t expire=0;uint16_t flags=0;const cr_tlv*namef=NULL,*oldf=NULL;if(action==2){namef=cr_packet_field(p,1);if(!namef||!namef->length||namef->length>64||cr_macroman_to_utf8(namef->value,namef->length,name,sizeof(name)))return send_error(s,p->transaction_id,1);if(cr_state_newsgroup_delete(&s->server->state,name))return send_error(s,p->transaction_id,1);}else{if(decode_newsgroup_fields(p,name,sizeof(name),&expire,&flags,&namef))return send_error(s,p->transaction_id,1);if(action==0){if(cr_state_newsgroup_create(&s->server->state,name,expire,flags))return send_error(s,p->transaction_id,1);}else{oldf=cr_packet_field(p,4);if(!oldf||!oldf->length||oldf->length>64||cr_macroman_to_utf8(oldf->value,oldf->length,old_name,sizeof(old_name))||cr_state_newsgroup_modify(&s->server->state,old_name,name,expire,flags))return send_error(s,p->transaction_id,1);}}
    if(synchronize_news_state(s->server))return send_error(s,p->transaction_id,1);
    int rc=send_task_complete(s,p->transaction_id);uint8_t av=(uint8_t)action;uint8_t eb[4],fb[2];cr_write_be32(eb,expire);cr_write_be16(fb,flags);cr_tlv_out ev[5];size_t n=0;ev[n++]=(cr_tlv_out){5,&av,1};ev[n++]=(cr_tlv_out){1,namef->value,namef->length};if(action!=2){ev[n++]=(cr_tlv_out){2,eb,4};ev[n++]=(cr_tlv_out){3,fb,2};}if(action==1)ev[n++]=(cr_tlv_out){4,oldf->value,oldf->length};broadcast_to_permission(s->server,PERM_MANAGE_NEWSGROUPS,CMD_NEWSGROUP_UPDATE,ev,n);log_msg("Newsgroup %s: %s",action==0?"created":action==1?"modified":"deleted",name);return rc;
}



typedef struct cr_tracker_target { char name[512]; char address[512]; } cr_tracker_target;
static void advertised_ipv4(uint8_t out[4]){
    out[0]=127;out[1]=0;out[2]=0;out[3]=1;struct ifaddrs*head=NULL;if(getifaddrs(&head)!=0)return;uint8_t fallback[4]={127,0,0,1};int have_fallback=0;
    for(struct ifaddrs*p=head;p;p=p->ifa_next){if(!p->ifa_addr||p->ifa_addr->sa_family!=AF_INET)continue;struct sockaddr_in*sin=(struct sockaddr_in*)p->ifa_addr;uint8_t b[4];memcpy(b,&sin->sin_addr,4);if(b[0]==127){if(!have_fallback){memcpy(fallback,b,4);have_fallback=1;}continue;}if(b[0]||b[1]||b[2]||b[3]){memcpy(out,b,4);freeifaddrs(head);return;}}
    if(have_fallback)memcpy(out,fallback,4);
    freeifaddrs(head);
}
static int parse_tracker_endpoint(const char*raw,char*host,size_t host_cap,uint16_t*port){while(*raw&&isspace((unsigned char)*raw))raw++;size_t len=strlen(raw);while(len&&isspace((unsigned char)raw[len-1]))len--;if(!len||len>=512)return-1;char value[512];memcpy(value,raw,len);value[len]=0;char*last=strrchr(value,':');if(last&&last!=value&&!memchr(value,':',(size_t)(last-value))){char*end=NULL;errno=0;unsigned long p=strtoul(last+1,&end,10);if(!errno&&end&&!*end&&p>0&&p<=65535){*last=0;if(!*value||strlen(value)+1>host_cap)return-1;strcpy(host,value);*port=(uint16_t)p;return 0;}}if(strlen(value)+1>host_cap)return-1;strcpy(host,value);*port=6702;return 0;}
static int connect_tracker(const char*host,uint16_t port){struct addrinfo hints,*res=NULL;memset(&hints,0,sizeof(hints));hints.ai_socktype=SOCK_STREAM;hints.ai_family=AF_UNSPEC;char service[16];snprintf(service,sizeof(service),"%u",port);if(getaddrinfo(host,service,&hints,&res)!=0)return-1;int result=-1;for(struct addrinfo*a=res;a;a=a->ai_next){int fd=socket(a->ai_family,a->ai_socktype,a->ai_protocol);if(fd<0)continue;int flags=fcntl(fd,F_GETFL,0);if(flags<0){close(fd);continue;}if(fcntl(fd,F_SETFL,flags|O_NONBLOCK)<0){close(fd);continue;}int c=connect(fd,a->ai_addr,a->ai_addrlen);if(c<0&&errno!=EINPROGRESS){close(fd);continue;}if(c<0){struct pollfd pfd={.fd=fd,.events=POLLOUT};int ready=poll(&pfd,1,1000);if(ready<=0){close(fd);continue;}int error=0;socklen_t el=sizeof(error);if(getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&el)||error){close(fd);continue;}}(void)fcntl(fd,F_SETFL,flags);result=fd;break;}freeaddrinfo(res);return result;}
static int tracker_ipv4_private_or_local(const uint8_t ip[4]){
    if(ip[0]==0||ip[0]==10||ip[0]==127||ip[0]>=224)return 1;
    if(ip[0]==100&&ip[1]>=64&&ip[1]<=127)return 1;
    if(ip[0]==169&&ip[1]==254)return 1;
    if(ip[0]==172&&ip[1]>=16&&ip[1]<=31)return 1;
    if(ip[0]==192&&ip[1]==168)return 1;
    return 0;
}
static int tracker_parse_ipv4_text(const char*text,uint8_t out[4]){
    if(!text)return-1;
    while(*text&&isspace((unsigned char)*text))text++;
    char value[64];size_t n=0;
    while(text[n]&&!isspace((unsigned char)text[n])&&n+1<sizeof(value)){value[n]=text[n];n++;}value[n]=0;
    struct in_addr address;if(!n||inet_pton(AF_INET,value,&address)!=1)return-1;memcpy(out,&address,4);return 0;
}
static int discover_public_tracker_ipv4(uint8_t out[4]){
    const char*override=getenv("CARRACHO_PUBLIC_IPV4");
    if(override&&!tracker_parse_ipv4_text(override,out)&&!tracker_ipv4_private_or_local(out))return 0;
    int fd=connect_tracker("checkip.amazonaws.com",80);if(fd<0)return-1;
    struct timeval timeout={.tv_sec=2,.tv_usec=500000};
    (void)setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    const char request[]="GET / HTTP/1.1\r\nHost: checkip.amazonaws.com\r\nConnection: close\r\nUser-Agent: carracho-server/1\r\n\r\n";
    if(cr_write_all(fd,(const uint8_t*)request,sizeof(request)-1)){shutdown(fd,SHUT_RDWR);close(fd);return-1;}
    char response[4096];size_t used=0;while(used+1<sizeof(response)){ssize_t n=recv(fd,response+used,sizeof(response)-1-used,0);if(n>0){used+=(size_t)n;continue;}if(n<0&&errno==EINTR)continue;break;}
    shutdown(fd,SHUT_RDWR);close(fd);response[used]=0;
    char*body=strstr(response,"\r\n\r\n");if(!body)return-1;body+=4;
    if(tracker_parse_ipv4_text(body,out)||tracker_ipv4_private_or_local(out))return-1;
    return 0;
}

static void send_tracker_registrations(cr_server *s) {
    cr_tracker_target *targets = calloc(256, sizeof(*targets));
    if (!targets) {
        log_msg("Tracker registration skipped: out of memory");
        return;
    }

    size_t count = 0;
    uint32_t flags = 0;
    char server_name[512] = "";
    char description[512] = "";

    pthread_mutex_lock(&s->state.mutex);
    flags = s->state.advanced.tracker_advertisement_flags;
    snprintf(server_name, sizeof(server_name), "%s", s->state.identity.name);
    snprintf(description, sizeof(description), "%s", s->state.advanced.tracker_description);
    json_object *advanced = NULL, *arr = NULL;
    if (json_object_object_get_ex(s->state.root, "advanced", &advanced) &&
        json_object_object_get_ex(advanced, "trackers", &arr) &&
        json_object_is_type(arr, json_type_array)) {
        size_t n = json_object_array_length(arr);
        if (n > 256) n = 256;
        for (size_t i = 0; i < n; i++) {
            json_object *t = json_object_array_get_idx(arr, i), *v = NULL;
            int64_t reserved_value = 0;
            if (json_object_object_get_ex(t, "reservedValue", &v) && json_object_is_type(v, json_type_int))
                reserved_value = json_object_get_int64(v);
            if (((uint32_t)reserved_value & 0x80000000u) != 0) continue;
            if (json_object_object_get_ex(t, "name", &v))
                snprintf(targets[count].name, sizeof(targets[count].name), "%s", json_object_get_string(v));
            if (json_object_object_get_ex(t, "address", &v)) {
                snprintf(targets[count].address, sizeof(targets[count].address), "%s", json_object_get_string(v));
                if (targets[count].address[0]) count++;
            }
        }
    }
    pthread_mutex_unlock(&s->state.mutex);

    if (!(flags & 0x00800000u) || !count) {
        free(targets);
        return;
    }
    uint8_t name[512], desc[512];
    size_t nn = 0, dn = 0;
    if (cr_utf8_to_macroman(server_name, name, sizeof(name), &nn) ||
        cr_utf8_to_macroman(description, desc, sizeof(desc), &dn) || nn > 255 || dn > 255) {
        log_msg("Tracker registration skipped: server name/description is not representable in Classic limits");
        free(targets);
        return;
    }

    uint16_t users = 0;
    pthread_mutex_lock(&s->mutex);
    size_t uc = announced_count_locked(s);
    users = (uint16_t)(uc > UINT16_MAX ? UINT16_MAX : uc);
    pthread_mutex_unlock(&s->mutex);

    uint8_t ip[4];
    if(discover_public_tracker_ipv4(ip)){
        advertised_ipv4(ip);
        log_msg("Public IPv4 discovery failed; tracker registration uses local %u.%u.%u.%u",ip[0],ip[1],ip[2],ip[3]);
    }
    cr_buffer wire;
    cr_buffer_init(&wire);
    uint8_t magic[4] = {'C', 'T', 'T', 1};
    if (cr_buffer_append(&wire, magic, 4) ||
        cr_buffer_append(&wire, ip, 4) ||
        cr_buffer_append_u16(&wire, s->port) ||
        cr_buffer_append_u8(&wire, (uint8_t)nn) ||
        cr_buffer_append(&wire, name, nn) ||
        cr_buffer_append_u8(&wire, (uint8_t)dn) ||
        cr_buffer_append(&wire, desc, dn) ||
        cr_buffer_append_u16(&wire, users) ||
        cr_buffer_append_u32(&wire, flags)) {
        cr_buffer_free(&wire);
        free(targets);
        return;
    }

    for (size_t i = 0; i < count; i++) {
        char host[512];
        uint16_t port = 0;
        if (parse_tracker_endpoint(targets[i].address, host, sizeof(host), &port)) {
            log_msg("Tracker registration failed for %s: invalid address", targets[i].address);
            continue;
        }
        int fd = connect_tracker(host, port);
        if (fd < 0) {
            log_msg("Tracker registration failed for %s: connect/resolve", targets[i].address);
            continue;
        }
        if (cr_write_all(fd, wire.data, wire.len) == 0)
            log_msg("Tracker registration sent to %s (%s)",
                    targets[i].name[0] ? targets[i].name : targets[i].address,
                    targets[i].address);
        else
            log_msg("Tracker registration failed for %s: send", targets[i].address);
        shutdown(fd, SHUT_RDWR);
        close(fd);
    }
    cr_buffer_free(&wire);
    free(targets);
}
static void request_tracker_refresh(cr_server*s){pthread_mutex_lock(&s->mutex);s->last_tracker_registration=0;pthread_mutex_unlock(&s->mutex);}
static void maybe_send_tracker_registration(cr_server*s){time_t now=time(NULL);int should=0;pthread_mutex_lock(&s->mutex);if(!s->last_tracker_registration||difftime(now,s->last_tracker_registration)>=300){s->last_tracker_registration=now;should=1;}pthread_mutex_unlock(&s->mutex);if(should)send_tracker_registrations(s);}

static int handle_server_log_request(cr_session*s,const cr_packet*p){
    if(!account_perm(s,PERM_VIEW_SERVER_LOG))return send_error(s,p->transaction_id,1);
    const cr_tlv*offset=cr_packet_field(p,1),*maximum=cr_packet_field(p,2);
    if(!offset||offset->length!=8||!maximum||maximum->length!=4)return send_error(s,p->transaction_id,1);
    uint32_t max_bytes=cr_read_be32(maximum->value);
    if(!max_bytes||max_bytes>60u*1024u)return send_error(s,p->transaction_id,1);
    uint64_t total=0,start=0;cr_buffer chunk;
    if(read_log_chunk(cr_read_be64(offset->value),(size_t)max_bytes,&total,&start,&chunk))return send_error(s,p->transaction_id,1);
    uint8_t total_wire[8],start_wire[8];cr_write_be64(total_wire,total);cr_write_be64(start_wire,start);
    cr_tlv_out fields[]={{1,total_wire,8},{2,start_wire,8},{3,chunk.data,(uint16_t)chunk.len}};
    int rc=session_send(s,CMD_SERVER_LOG_REPLY,p->transaction_id,fields,3);
    cr_buffer_free(&chunk);return rc;
}

static int handle_server_log_clear(cr_session*s,const cr_packet*p){
    if(!account_perm(s,PERM_VIEW_SERVER_LOG)||p->field_count)return send_error(s,p->transaction_id,1);
    if(clear_log_file())return send_error(s,p->transaction_id,1);
    int rc=send_task_complete(s,p->transaction_id);
    log_msg("Server log cleared remotely by user %u",s->user_id);
    return rc;
}

static int handle_event_log_request(cr_session*s,const cr_packet*p){
    if(!account_perm(s,PERM_VIEW_SERVER_LOG))return send_error(s,p->transaction_id,1);
    const cr_tlv*offset=cr_packet_field(p,1),*maximum=cr_packet_field(p,2);if(!offset||offset->length!=8||!maximum||maximum->length!=4)return send_error(s,p->transaction_id,1);
    uint32_t max_bytes=cr_read_be32(maximum->value);if(!max_bytes||max_bytes>60u*1024u)return send_error(s,p->transaction_id,1);
    uint64_t total=0,start=0;cr_buffer chunk;if(read_event_chunk(cr_read_be64(offset->value),(size_t)max_bytes,&total,&start,&chunk))return send_error(s,p->transaction_id,1);
    uint8_t total_wire[8],start_wire[8];cr_write_be64(total_wire,total);cr_write_be64(start_wire,start);cr_tlv_out fields[]={{1,total_wire,8},{2,start_wire,8},{3,chunk.data,(uint16_t)chunk.len}};
    int rc=session_send(s,CMD_EVENT_LOG_REPLY,p->transaction_id,fields,3);cr_buffer_free(&chunk);return rc;
}
static int handle_event_log_clear(cr_session*s,const cr_packet*p){if(!account_perm(s,PERM_VIEW_SERVER_LOG)||p->field_count)return send_error(s,p->transaction_id,1);if(clear_event_file())return send_error(s,p->transaction_id,1);int rc=send_task_complete(s,p->transaction_id);event_msg(s,"administration","clear-events","event log cleared");return rc;}

static int server_setting_permission(uint32_t field,int write){
    switch(field){
        case 0x04:return PERM_EDIT_AGREEMENT;
        case 0x05:case 0x06:case 0x07:case 0x08:return PERM_EDIT_SERVER_INFO;
        case 0x0c:return PERM_MANAGE_NEWSGROUPS;
        case SETTING_ACCOUNT_GROUPS:return PERM_MANAGE_ACCOUNTS;
        case 0x09:case 0x20:case 0x21:case 0x22:case 0x23:case 0x35:case 0x2f:case SETTING_SEARCH_INDEX_EXCLUSIONS:case SETTING_LEGACY_FILES_ROOT:case SETTING_AUTHENTICATION_MODE:case SETTING_SEARCH_INDEX_REBUILD_INTERVAL:return PERM_EDIT_ADVANCED;
        case 0x30:case 0x32:case 0x33:return PERM_EDIT_TRACKERS;
        case 0x24:case 0x25:case 0x26:case 0x27:case 0x28:case 0x29:case 0x2a:case 0x2b:case 0x2c:case 0x2d:case 0x2e:case 0x34:return write?-1:PERM_VIEW_STATISTICS;
        case 0x36:return write?-1:PERM_EDIT_ADVANCED;
        default:return -1;
    }
}
static uint32_t clamp_u32_i64(int64_t v){if(v<=0)return 0;if((uint64_t)v>UINT32_MAX)return UINT32_MAX;return(uint32_t)v;}
static int append_macroman_text(cr_buffer*b,const char*text){uint8_t tmp[65535];size_t n=0;if(cr_utf8_to_macroman(text?text:"",tmp,sizeof(tmp),&n))return-1;return cr_buffer_append(b,tmp,n);}
static int json_base64_four(const uint8_t bytes[4],char out[9]){int n=EVP_EncodeBlock((unsigned char*)out,bytes,4);if(n!=8)return-1;out[8]='\0';return 0;}
static json_object *ensure_json_object_member(json_object*parent,const char*key){json_object*o=NULL;if(!json_object_object_get_ex(parent,key,&o)||!json_object_is_type(o,json_type_object)){o=json_object_new_object();json_object_object_add(parent,key,o);}return o;}
static int decode_search_index_exclusions_field(const cr_tlv*f,cr_search_index_exclusions*out){
    if(!f||!out||f->length<2)return-1;
    memset(out,0,sizeof(*out));
    size_t pos=0;
    uint16_t count=cr_read_be16(f->value);
    pos=2;
    if(count>CR_MAX_SEARCH_INDEX_EXCLUSIONS)return-1;
    for(uint16_t i=0;i<count;i++){if(pos+2>f->length)return-1;uint16_t n=cr_read_be16(f->value+pos);pos+=2;if(!n||n>=CR_MAX_SEARCH_INDEX_PATTERN||pos+n>f->length)return-1;char pattern[CR_MAX_SEARCH_INDEX_PATTERN];if(cr_macroman_to_utf8(f->value+pos,n,pattern,sizeof(pattern))||strchr(pattern,'/')||strchr(pattern,'\\'))return-1;snprintf(out->patterns[i],sizeof(out->patterns[i]),"%s",pattern);pos+=n;}out->count=count;return pos==f->length?0:-1;
}
static int append_search_index_exclusions(cr_buffer*b,const cr_search_index_exclusions*x){
    if(!b||!x||x->count>CR_MAX_SEARCH_INDEX_EXCLUSIONS||cr_buffer_append_u16(b,(uint16_t)x->count))return-1;
    for(size_t i=0;i<x->count;i++){uint8_t raw[512];size_t n=0;if(cr_utf8_to_macroman(x->patterns[i],raw,sizeof(raw),&n)||!n||n>255||cr_buffer_append_string16(b,raw,n))return-1;}return 0;
}
static int persist_legacy_files_root_config(cr_server*s,const char*path){
    if(!s||!path||!s->config_path[0])return-1;
    json_object*root=json_object_from_file(s->config_path);
    if(!root||!json_object_is_type(root,json_type_object)){if(root)json_object_put(root);return-1;}
    json_object_object_add(root,"legacyFilesRoot",json_object_new_string(path));
    char tmp[PATH_MAX];int n=snprintf(tmp,sizeof(tmp),"%s.tmp",s->config_path);int rc=-1;
    if(n>0&&(size_t)n<sizeof(tmp)&&json_object_to_file_ext(tmp,root,JSON_C_TO_STRING_PRETTY)==0&&rename(tmp,s->config_path)==0)rc=0;else unlink(tmp);
    json_object_put(root);return rc;
}

static int persist_search_index_exclusions_config(cr_server*s,const cr_search_index_exclusions*x){
    if(!s||!x||!s->config_path[0])return-1;
    json_object*root=json_object_from_file(s->config_path);
    if(!root||!json_object_is_type(root,json_type_object)){if(root)json_object_put(root);return-1;}
    json_object*array=json_object_new_array();
    if(!array){json_object_put(root);return-1;}
    for(size_t i=0;i<x->count;i++)json_object_array_add(array,json_object_new_string(x->patterns[i]));
    json_object_object_add(root,"searchIndexExclusions",array);
    char tmp[PATH_MAX];
    int n=snprintf(tmp,sizeof(tmp),"%s.tmp",s->config_path);
    int rc=-1;
    if(n>0&&(size_t)n<sizeof(tmp)&&json_object_to_file_ext(tmp,root,JSON_C_TO_STRING_PRETTY)==0&&rename(tmp,s->config_path)==0)rc=0;else unlink(tmp);
    json_object_put(root);
    return rc;
}

static int persist_startup_configuration_config(cr_server*s){
    if(!s||!s->config_path[0])return-1;
    json_object*root=json_object_from_file(s->config_path);
    if(!root||!json_object_is_type(root,json_type_object)){if(root)json_object_put(root);return-1;}

    pthread_mutex_lock(&s->state.mutex);
    json_object_object_add(root,"serverName",json_object_new_string(s->state.identity.name));
    json_object_object_add(root,"description",json_object_new_string(s->state.identity.description));
    json_object_object_add(root,"serverPort",json_object_new_int(s->state.advanced.control_port));
    json_object_object_add(root,"authenticationMode",json_object_new_string(s->state.legacy_compatible?"legacyCompatible":"modernOnly"));
    json_object_object_add(root,"maxConnections",json_object_new_int(s->state.advanced.max_connections));
    json_object_object_add(root,"maxConnectionsPerIP",json_object_new_int(s->state.advanced.max_connections_per_ip));
    json_object_object_add(root,"maxSimultaneousFileTransfers",json_object_new_int(s->state.advanced.max_simultaneous_file_transfers));
    json_object_object_add(root,"maxFileTransfersPerUser",json_object_new_int(s->state.advanced.max_file_transfers_per_user));
    json_object_object_add(root,"maxFolderDownloadDepth",json_object_new_int(s->state.advanced.max_folder_download_depth));
    json_object_object_add(root,"newsExpirationHour",json_object_new_int(s->state.advanced.news_expiration_hour));
    json_object_object_add(root,"newsExpirationMinute",json_object_new_int(s->state.advanced.news_expiration_minute));
    json_object_object_add(root,"legacyFilesRoot",json_object_new_string(s->state.legacy_storage_root));
    json_object*runtime=NULL,*v=NULL;
    if(json_object_object_get_ex(s->state.root,"runtime",&runtime)&&json_object_is_type(runtime,json_type_object)){
        if(json_object_object_get_ex(runtime,"uploadBandwidthLimitBytesPerSecond",&v)&&json_object_is_type(v,json_type_int))
            json_object_object_add(root,"uploadBandwidthLimitBytesPerSecond",json_object_new_int64(json_object_get_int64(v)));
        if(json_object_object_get_ex(runtime,"searchIndexRebuildIntervalHours",&v)&&json_object_is_type(v,json_type_int))
            json_object_object_add(root,"searchIndexRebuildIntervalHours",json_object_new_int64(json_object_get_int64(v)));
        json_object*ex=NULL;if(json_object_object_get_ex(runtime,"searchIndexExclusions",&ex)&&json_object_is_type(ex,json_type_array)){
            json_object*copy=json_object_new_array();
            if(!copy){pthread_mutex_unlock(&s->state.mutex);json_object_put(root);return-1;}
            for(size_t i=0;i<json_object_array_length(ex);i++){
                json_object*x=json_object_array_get_idx(ex,i);
                if(x&&json_object_is_type(x,json_type_string))json_object_array_add(copy,json_object_new_string(json_object_get_string(x)));
            }
            json_object_object_add(root,"searchIndexExclusions",copy);
        }
    }
    pthread_mutex_unlock(&s->state.mutex);

    char tmp[PATH_MAX];int n=snprintf(tmp,sizeof(tmp),"%s.tmp",s->config_path);int rc=-1;
    if(n>0&&(size_t)n<sizeof(tmp)&&json_object_to_file_ext(tmp,root,JSON_C_TO_STRING_PRETTY)==0&&rename(tmp,s->config_path)==0)rc=0;else unlink(tmp);
    json_object_put(root);return rc;
}

static const char*tracker_bandwidth_title(uint8_t code){
    switch(code){
        case 1:return "28.8K - Modem";case 2:return "33.6K - Modem";case 3:return "56K - Modem";
        case 5:return "56K - ISDN";case 6:return "64K - ISDN";case 7:return "112K - 2 x ISDN";
        case 8:return "128K - 2 x ISDN";case 10:return "T1";case 11:return "T3";case 13:return "Other Speed";
        default:return NULL;
    }
}

/* Tracker registration remains database-managed, but carracho-server.json mirrors the complete
   public registration setup so operators can inspect the effective configuration in one place. */
static int persist_tracker_registration_config(cr_server*s){
    if(!s||!s->config_path[0])return-1;
    json_object*root=json_object_from_file(s->config_path);
    if(!root||!json_object_is_type(root,json_type_object)){if(root)json_object_put(root);return-1;}
    json_object*registration=json_object_new_object(),*targets=json_object_new_array();
    if(!registration||!targets){if(registration)json_object_put(registration);if(targets)json_object_put(targets);json_object_put(root);return-1;}

    pthread_mutex_lock(&s->state.mutex);
    uint32_t flags=s->state.advanced.tracker_advertisement_flags;
    char description[sizeof(s->state.advanced.tracker_description)];
    snprintf(description,sizeof(description),"%s",s->state.advanced.tracker_description);
    json_object*advanced=NULL,*arr=NULL;
    if(json_object_object_get_ex(s->state.root,"advanced",&advanced)&&json_object_is_type(advanced,json_type_object)&&
       json_object_object_get_ex(advanced,"trackers",&arr)&&json_object_is_type(arr,json_type_array)){
        size_t count=json_object_array_length(arr);if(count>256)count=256;
        for(size_t i=0;i<count;i++){
            json_object*t=json_object_array_get_idx(arr,i),*v=NULL,*copy=json_object_new_object();
            if(!t||!copy){if(copy)json_object_put(copy);continue;}
            const char*name="",*address="",*reserved="";int64_t reserved_value=0;
            if(json_object_object_get_ex(t,"name",&v)&&json_object_is_type(v,json_type_string))name=json_object_get_string(v);
            if(json_object_object_get_ex(t,"address",&v)&&json_object_is_type(v,json_type_string))address=json_object_get_string(v);
            if(json_object_object_get_ex(t,"reservedString",&v)&&json_object_is_type(v,json_type_string))reserved=json_object_get_string(v);
            if(json_object_object_get_ex(t,"reservedValue",&v)&&json_object_is_type(v,json_type_int))reserved_value=json_object_get_int64(v);
            json_object_object_add(copy,"name",json_object_new_string(name?name:""));
            json_object_object_add(copy,"address",json_object_new_string(address?address:""));
            json_object_object_add(copy,"enabled",json_object_new_boolean((((uint32_t)reserved_value)&0x80000000u)==0));
            json_object_object_add(copy,"reservedString",json_object_new_string(reserved?reserved:""));
            json_object_object_add(copy,"reservedValue",json_object_new_int64(reserved_value));
            json_object_array_add(targets,copy);
        }
    }
    pthread_mutex_unlock(&s->state.mutex);

    uint8_t bandwidth=(uint8_t)(flags>>24);const char*title=tracker_bandwidth_title(bandwidth);char unknown[64];
    if(!title){if(!bandwidth)title="Not specified";else{snprintf(unknown,sizeof(unknown),"Unknown (code %u)",(unsigned)bandwidth);title=unknown;}}
    json_object_object_add(registration,"enabled",json_object_new_boolean((flags&0x00800000u)!=0));
    json_object_object_add(registration,"private",json_object_new_boolean((flags&0x00400000u)!=0));
    json_object_object_add(registration,"bandwidthCode",json_object_new_int((int)bandwidth));
    json_object_object_add(registration,"bandwidth",json_object_new_string(title));
    json_object_object_add(registration,"flags",json_object_new_int64((int64_t)flags));
    json_object_object_add(registration,"description",json_object_new_string(description));
    json_object_object_add(registration,"trackers",targets);
    json_object_object_add(root,"trackerRegistration",registration);

    char tmp[PATH_MAX];int n=snprintf(tmp,sizeof(tmp),"%s.tmp",s->config_path);int rc=-1;
    if(n>0&&(size_t)n<sizeof(tmp)&&json_object_to_file_ext(tmp,root,JSON_C_TO_STRING_PRETTY)==0&&rename(tmp,s->config_path)==0)rc=0;else unlink(tmp);
    json_object_put(root);return rc;
}

static void account_group_permission_bytes(const cr_account_group*g,uint8_t out[8]){
    uint64_t bits=g->permission_bits;if(g->mode==CR_MODE_ADMIN)bits|=1ULL<<0;else if(g->mode==CR_MODE_ACCOUNT)bits|=1ULL<<1;
    memset(out,0,8);for(unsigned bit=0;bit<64;bit++)if((bits>>bit)&1ULL)out[bit/8]|=(uint8_t)(0x80u>>(bit%8));
}
static int append_account_groups_locked(cr_server_state*st,cr_buffer*b){
    if(st->account_group_count>256||cr_buffer_append_u16(b,(uint16_t)st->account_group_count|0x8000u))return-1;
    for(size_t i=0;i<st->account_group_count;i++){
        cr_account_group*g=&st->account_groups[i];size_t idn=strlen(g->id),nn=strlen(g->name),rpn=strlen(g->files_root_path);const char*root_name=rpn?g->files_root_name:"Allgemein";size_t rnn=strlen(root_name);
        if (!idn || idn > 63 || !nn || nn > 64 || rpn > 1024 || !rnn || rnn > 64) return -1;
        uint8_t perms[8];
        account_group_permission_bytes(g, perms);
        uint8_t mode = g->mode == CR_MODE_ADMIN ? 2 : g->mode == CR_MODE_ACCOUNT ? 1 : 0;
        size_t members=0;for(size_t ai=0;ai<st->account_count;ai++)if(!strcasecmp(st->accounts[ai].group_id,g->id))members++;if(members>UINT16_MAX)return-1;
        if(cr_buffer_append_string16(b,g->id,idn)||cr_buffer_append_string16(b,g->name,nn)||cr_buffer_append_u32(b,g->color_rgb)||cr_buffer_append_u8(b,mode)||cr_buffer_append(b,perms,8)||cr_buffer_append_u16(b,(uint16_t)members))return-1;
        for(size_t ai=0;ai<st->account_count;ai++)if(!strcasecmp(st->accounts[ai].group_id,g->id)){size_t ln=strlen(st->accounts[ai].login);if(!ln||ln>63||cr_buffer_append_string16(b,st->accounts[ai].login,ln))return-1;}
        if(cr_buffer_append_string16(b,g->files_root_path,rpn)||cr_buffer_append_string16(b,root_name,rnn))return-1;
    }
    return 0;
}
static int decode_account_groups_field(const cr_tlv*f,cr_account_group groups[CR_MAX_ACCOUNT_GROUPS],size_t*out_count){
    if(!f||f->length<2||!out_count)return-1;
    size_t pos=0;uint16_t raw_count=cr_read_be16(f->value);pos=2;int extended=(raw_count&0x8000u)!=0;uint16_t count=(uint16_t)(raw_count&0x7fffu);
    if(count>CR_MAX_ACCOUNT_GROUPS)return-1;
    for(uint16_t i=0;i<count;i++){
        cr_account_group*g=&groups[i];memset(g,0,sizeof(*g));if(pos+2>f->length)return-1;uint16_t idn=cr_read_be16(f->value+pos);pos+=2;if(!idn||idn>=sizeof(g->id)||pos+idn+2>f->length)return-1;memcpy(g->id,f->value+pos,idn);g->id[idn]=0;pos+=idn;
        uint16_t nn=cr_read_be16(f->value+pos);pos+=2;if(!nn||nn>64||nn>=sizeof(g->name)||pos+nn+4+1+8+2>f->length||!valid_utf8_bytes(f->value+pos,nn))return-1;memcpy(g->name,f->value+pos,nn);g->name[nn]=0;pos+=nn;
        g->color_rgb=cr_read_be32(f->value+pos);pos+=4;if(g->color_rgb>0x00ffffffu)return-1;uint8_t mode=f->value[pos++];if(mode>2)return-1;g->mode=mode==2?CR_MODE_ADMIN:mode==1?CR_MODE_ACCOUNT:CR_MODE_GUEST;
        uint64_t bits=permission_bits_from_wire_bytes(f->value+pos);pos+=8;bits&=~((1ULL<<0)|(1ULL<<1)|(1ULL<<3)|(1ULL<<4));g->permission_bits=bits;
        uint16_t members=cr_read_be16(f->value+pos);pos+=2;for(uint16_t m=0;m<members;m++){if(pos+2>f->length)return-1;uint16_t ln=cr_read_be16(f->value+pos);pos+=2;if(!ln||ln>63||pos+ln>f->length||!valid_utf8_bytes(f->value+pos,ln))return-1;pos+=ln;}
        if(extended){
            if (pos + 2 > f->length) return -1;
            uint16_t rpn = cr_read_be16(f->value + pos);
            pos += 2;
            if (rpn > 1024 || rpn >= sizeof(g->files_root_path) || pos + rpn + 2 > f->length ||
                !valid_utf8_bytes(f->value + pos, rpn) || memchr(f->value + pos, 0, rpn)) return -1;
            memcpy(g->files_root_path, f->value + pos, rpn);
            g->files_root_path[rpn] = 0;
            pos += rpn;
            uint16_t rnn=cr_read_be16(f->value+pos);pos+=2;if(!rnn||rnn>64||rnn>=sizeof(g->files_root_name)||pos+rnn>f->length||!valid_utf8_bytes(f->value+pos,rnn)||memchr(f->value+pos,0,rnn))return-1;memcpy(g->files_root_name,f->value+pos,rnn);g->files_root_name[rnn]=0;pos+=rnn;
        }else{g->files_root_path[0]=0;snprintf(g->files_root_name,sizeof(g->files_root_name),"Allgemein");}
        for(uint16_t j=0;j<i;j++)if(!strcmp(groups[j].id,g->id)||!strcasecmp(groups[j].name,g->name))return-1;
    }
    if(pos!=f->length)return-1;
    *out_count=count;
    return 0;
}

static int setting_value_locked(cr_server*s,uint32_t field,cr_buffer*b){
    cr_server_state*st=&s->state;cr_buffer_init(b);json_object*stats=NULL,*v=NULL,*advanced=NULL;
    switch(field){
        case 0x04:{uint8_t text[65535];size_t n=0;if(cr_utf8_to_macroman(st->agreement_text?st->agreement_text:"",text,sizeof(text)-9,&n))return-1;return cr_buffer_append_u8(b,st->agreement_enabled?1:0)||cr_buffer_append_u32(b,(uint32_t)n)||cr_buffer_append(b,text,n)||cr_buffer_append_u32(b,0)?-1:0;}
        case 0x05:return append_macroman_text(b,st->identity.name);
        case 0x06:return append_macroman_text(b,st->identity.location);
        case 0x07:return append_macroman_text(b,st->identity.operator_name);
        case 0x08:return append_macroman_text(b,st->identity.description);
        case 0x09:return cr_buffer_append_u16(b,st->advanced.control_port);
        case 0x0c:return cr_buffer_append_u16(b,(uint16_t)(((uint16_t)st->advanced.news_expiration_hour<<8)|st->advanced.news_expiration_minute));
        case 0x20:return cr_buffer_append_u16(b,st->advanced.max_simultaneous_file_transfers);
        case 0x21:return cr_buffer_append_u16(b,st->advanced.max_file_transfers_per_user);
        case 0x22:return cr_buffer_append_u16(b,st->advanced.max_connections);
        case 0x23:return cr_buffer_append_u16(b,st->advanced.max_connections_per_ip);
        case 0x35:return cr_buffer_append_u16(b,st->advanced.max_folder_download_depth);
        case SETTING_ACCOUNT_GROUPS:return append_account_groups_locked(st,b);
        case SETTING_LEGACY_FILES_ROOT:{json_object*runtime=NULL,*v=NULL;const char*path="";if(json_object_object_get_ex(st->root,"runtime",&runtime)&&json_object_is_type(runtime,json_type_object)&&json_object_object_get_ex(runtime,"legacyFilesRoot",&v)&&json_object_is_type(v,json_type_string))path=json_object_get_string(v);return cr_buffer_append(b,path?path:"",path?strlen(path):0);}
        case SETTING_AUTHENTICATION_MODE:return cr_buffer_append_u8(b,st->legacy_compatible?0:1);
        case SETTING_SEARCH_INDEX_REBUILD_INTERVAL:{json_object*runtime=NULL,*v=NULL;uint32_t hours=0;if(json_object_object_get_ex(st->root,"runtime",&runtime)&&json_object_is_type(runtime,json_type_object)&&json_object_object_get_ex(runtime,"searchIndexRebuildIntervalHours",&v)&&json_object_is_type(v,json_type_int)){int64_t x=json_object_get_int64(v);if(x>0)hours=x>UINT32_MAX?UINT32_MAX:(uint32_t)x;}return cr_buffer_append_u32(b,hours);}
        case SETTING_SEARCH_INDEX_EXCLUSIONS:{json_object*runtime=NULL,*arr=NULL;cr_search_index_exclusions x;memset(&x,0,sizeof(x));if(json_object_object_get_ex(st->root,"runtime",&runtime)&&json_object_is_type(runtime,json_type_object)&&json_object_object_get_ex(runtime,"searchIndexExclusions",&arr)&&json_object_is_type(arr,json_type_array)){size_t count=json_object_array_length(arr);if(count>CR_MAX_SEARCH_INDEX_EXCLUSIONS)return-1;for(size_t i=0;i<count;i++){json_object*v=json_object_array_get_idx(arr,i);if(!v||!json_object_is_type(v,json_type_string))return-1;const char*p=json_object_get_string(v);if(!p||!*p||strlen(p)>=CR_MAX_SEARCH_INDEX_PATTERN)return-1;snprintf(x.patterns[i],sizeof(x.patterns[i]),"%s",p);}x.count=count;}return append_search_index_exclusions(b,&x);}
        case 0x2f:{if(cr_buffer_append_u32(b,(uint32_t)st->ip_restriction_count))return-1;for(size_t i=0;i<st->ip_restriction_count;i++){cr_ip_restriction*r=&st->ip_restrictions[i];if(cr_buffer_append(b,r->network,4)||cr_buffer_append(b,r->mask,4)||cr_buffer_append_u8(b,r->deny?1:0)||cr_buffer_append_u8(b,r->reserved))return-1;}return 0;}
        case 0x30:{
            if(!json_object_object_get_ex(st->root,"advanced",&advanced))return cr_buffer_append_u16(b,0);
            json_object*arr=NULL;if(!json_object_object_get_ex(advanced,"trackers",&arr)||!json_object_is_type(arr,json_type_array))return cr_buffer_append_u16(b,0);
            size_t count=json_object_array_length(arr);if(count>UINT16_MAX)return-1;if(cr_buffer_append_u16(b,(uint16_t)count))return-1;
            for(size_t i=0;i<count;i++){json_object*t=json_object_array_get_idx(arr,i),*x=NULL;const char*name="",*address="",*reserved="";uint32_t rv=0;if(json_object_object_get_ex(t,"name",&x))name=json_object_get_string(x);if(json_object_object_get_ex(t,"address",&x))address=json_object_get_string(x);if(json_object_object_get_ex(t,"reservedString",&x))reserved=json_object_get_string(x);if(json_object_object_get_ex(t,"reservedValue",&x))rv=(uint32_t)json_object_get_int64(x);uint8_t nm[128],am[256],rm[128];size_t nn=0,an=0,rn=0;if(cr_utf8_to_macroman(name,nm,sizeof(nm),&nn)||nn>32||cr_utf8_to_macroman(address,am,sizeof(am),&an)||an>64||cr_utf8_to_macroman(reserved,rm,sizeof(rm),&rn)||rn>16)return-1;if(cr_buffer_append_string16(b,nm,nn)||cr_buffer_append_string16(b,am,an)||cr_buffer_append_string16(b,rm,rn)||cr_buffer_append_u32(b,rv))return-1;}return 0;}
        case 0x32:{uint32_t f=st->advanced.tracker_advertisement_flags;uint8_t x[3]={(uint8_t)(f>>24),(uint8_t)(f>>16),(uint8_t)(f>>8)};return cr_buffer_append(b,x,3);}
        case 0x33:return append_macroman_text(b,st->advanced.tracker_description);
        case 0x36:{time_t now=time(NULL);double sec=difftime(now,s->started_at);if(sec<0)sec=0;uint64_t ticks=(uint64_t)(sec*60.0);if(ticks>UINT32_MAX)ticks=UINT32_MAX;return cr_buffer_append_u32(b,(uint32_t)ticks);}
        default:break;
    }
    if(!json_object_object_get_ex(st->root,"statistics",&stats)||!json_object_is_type(stats,json_type_object))return cr_buffer_append_u32(b,0);
    const char*key=NULL;
    switch(field){case 0x24:key="hits";break;case 0x25:key="connectionPeak";break;case 0x26:key="incorrectLogins";break;case 0x27:key="adminsConnected";break;case 0x28:key="accountHoldersConnected";break;case 0x29:key="guestsConnected";break;case 0x2a:key="downloadsInProgress";break;case 0x2b:key="totalDownloads";break;case 0x2c:key="uploadsInProgress";break;case 0x2d:key="totalUploads";break;case 0x34:key="totalMessages";break;case 0x2e:{int64_t total=0;const char*ks[]={"adminsConnected","accountHoldersConnected","guestsConnected"};for(int i=0;i<3;i++)if(json_object_object_get_ex(stats,ks[i],&v))total+=json_object_get_int64(v);return cr_buffer_append_u32(b,clamp_u32_i64(total));}default:return-1;}
    int64_t value=json_object_object_get_ex(stats,key,&v)?json_object_get_int64(v):0;return cr_buffer_append_u32(b,clamp_u32_i64(value));
}
static int handle_server_settings_request(cr_session*s,const cr_packet*p){
    cr_buffer values[CR_MAX_TLVS];cr_tlv_out out[CR_MAX_TLVS];size_t n=0;for(size_t i=0;i<CR_MAX_TLVS;i++)cr_buffer_init(&values[i]);int fail=0;
    pthread_mutex_lock(&s->server->state.mutex);
    for(uint16_t i=0;i<p->field_count&&!fail;i++){const cr_tlv*r=&p->fields[i];if(r->length){fail=1;break;}int perm=server_setting_permission(r->type,0);if(perm<0||!account_perm(s,(unsigned)perm))continue;if(setting_value_locked(s->server,r->type,&values[n])||values[n].len>UINT16_MAX){fail=1;break;}out[n]=(cr_tlv_out){r->type,values[n].data,(uint16_t)values[n].len};n++;}
    pthread_mutex_unlock(&s->server->state.mutex);int rc=fail?send_error(s,p->transaction_id,1):session_send(s,CMD_SERVER_SETTINGS_REPLY,p->transaction_id,out,n);for(size_t i=0;i<CR_MAX_TLVS;i++)cr_buffer_free(&values[i]);return rc;
}
static int validate_setting_field(cr_session*s,const cr_tlv*f){int perm=server_setting_permission(f->type,1);if(perm<0||!account_perm(s,(unsigned)perm))return-1;switch(f->type){case 0x04:{if(f->length<1||f->length>0xfc00||f->value[0]>1)return-1;if(f->length==1)return 0;if(f->length<9)return-1;uint32_t tn=cr_read_be32(f->value+1);if((size_t)tn+9>f->length)return-1;size_t pos=5u+tn;uint32_t sn=cr_read_be32(f->value+pos);return pos+4u+sn==f->length?0:-1;}case 0x05:return f->length>0&&f->length<=255?0:-1;case 0x06:case 0x07:return f->length<=255?0:-1;case 0x08:return f->length<=16384?0:-1;case 0x09:case 0x0c:case 0x20:case 0x21:case 0x22:case 0x23:case 0x35:return f->length==2?0:-1;case 0x2f:{if(f->length<4)return-1;uint32_t count=cr_read_be32(f->value);return count<=4096&&4u+(size_t)count*10u==f->length?0:-1;}case 0x30:{if(f->length<2)return-1;size_t pos=2;uint16_t count=cr_read_be16(f->value);for(uint16_t i=0;i<count;i++){if(pos+2>f->length)return-1;uint16_t a=cr_read_be16(f->value+pos);pos+=2;if(a>32||pos+a+2>f->length)return-1;pos+=a;uint16_t b=cr_read_be16(f->value+pos);pos+=2;if(!b||b>64||pos+b+2>f->length)return-1;pos+=b;uint16_t c=cr_read_be16(f->value+pos);pos+=2;if(c>16||pos+c+4>f->length)return-1;pos+=c+4;}return pos==f->length?0:-1;}case 0x32:return f->length==4?0:-1;case 0x33:return f->length<=255?0:-1;case SETTING_ACCOUNT_GROUPS:{cr_account_group*groups=calloc(CR_MAX_ACCOUNT_GROUPS,sizeof(*groups));if(!groups)return-1;size_t count=0;int rc=decode_account_groups_field(f,groups,&count);free(groups);return rc;}case SETTING_LEGACY_FILES_ROOT:return f->length<PATH_MAX&&valid_utf8_bytes(f->value,f->length)&&!memchr(f->value,0,f->length)&&(!f->length||f->value[0]=='/')?0:-1;case SETTING_AUTHENTICATION_MODE:return f->length==1&&f->value[0]<=1?0:-1;case SETTING_SEARCH_INDEX_REBUILD_INTERVAL:return f->length==4?0:-1;case SETTING_SEARCH_INDEX_EXCLUSIONS:{cr_search_index_exclusions x;return decode_search_index_exclusions_field(f,&x);}default:return-1;}}
static int decode_setting_text(const cr_tlv*f,char*out,size_t cap){return cr_macroman_to_utf8(f->value,f->length,out,cap);}
static int apply_settings_locked(cr_server*s,const cr_packet*p){
    cr_server_state*st=&s->state;json_object*identity=ensure_json_object_member(st->root,"identity"),*advanced=ensure_json_object_member(st->root,"advanced"),*agreement=ensure_json_object_member(st->root,"agreement"),*runtime=ensure_json_object_member(st->root,"runtime");
    for(uint16_t i=0;i<p->field_count;i++){const cr_tlv*f=&p->fields[i];char text[CR_MAX_IDENTITY_TEXT+1];switch(f->type){
        case 0x04:{int enabled=f->value[0]!=0;char*agreement_text=NULL;if(f->length==1){agreement_text=strdup("");}else{uint32_t n=cr_read_be32(f->value+1);size_t cap=(size_t)n*3u+1u;agreement_text=malloc(cap);if(!agreement_text||cr_macroman_to_utf8(f->value+5,n,agreement_text,cap)){free(agreement_text);return-1;}}if(!agreement_text)return-1;json_object_object_add(agreement,"text",json_object_new_string(agreement_text));json_object_object_add(agreement,"enabled",json_object_new_boolean(enabled));free(agreement_text);break;}
        case 0x05:if(decode_setting_text(f,text,sizeof(text))||!*text)return-1;json_object_object_add(identity,"name",json_object_new_string(text));break;
        case 0x06:if(decode_setting_text(f,text,sizeof(text)))return-1;json_object_object_add(identity,"location",json_object_new_string(text));break;
        case 0x07:if(decode_setting_text(f,text,sizeof(text)))return-1;json_object_object_add(identity,"operatorName",json_object_new_string(text));break;
        case 0x08:if(decode_setting_text(f,text,sizeof(text)))return-1;json_object_object_add(identity,"description",json_object_new_string(text));break;
        case 0x09:{uint16_t v=cr_read_be16(f->value);if(!v||v==UINT16_MAX)return-1;json_object_object_add(advanced,"controlPort",json_object_new_int(v));break;}
        case 0x0c:{uint16_t v=cr_read_be16(f->value);uint8_t h=(uint8_t)(v>>8),m=(uint8_t)v;if(h>=24||m>=60)return-1;json_object_object_add(advanced,"newsExpirationHour",json_object_new_int(h));json_object_object_add(advanced,"newsExpirationMinute",json_object_new_int(m));break;}
        case 0x20:case 0x21:case 0x22:case 0x23:case 0x35:{uint16_t v=cr_read_be16(f->value);if((f->type!=0x35)&&!v)return-1;const char*k=f->type==0x20?"maxSimultaneousFileTransfers":f->type==0x21?"maxFileTransfersPerUser":f->type==0x22?"maxConnections":f->type==0x23?"maxConnectionsPerIP":"maxFolderDownloadDepth";json_object_object_add(advanced,k,json_object_new_int(v));break;}
        case 0x2f:{uint32_t count=cr_read_be32(f->value);json_object*arr=json_object_new_array();size_t pos=4;for(uint32_t j=0;j<count;j++){const uint8_t*n=f->value+pos,*m=n+4;char nb[9],mb[9];if(json_base64_four(n,nb)||json_base64_four(m,mb)){json_object_put(arr);return-1;}json_object*r=json_object_new_object();json_object_object_add(r,"network",json_object_new_string(nb));json_object_object_add(r,"mask",json_object_new_string(mb));json_object_object_add(r,"deny",json_object_new_boolean(f->value[pos+8]!=0));json_object_object_add(r,"reserved",json_object_new_int(f->value[pos+9]));json_object_array_add(arr,r);pos+=10;}json_object_object_add(advanced,"ipRestrictions",arr);break;}
        case 0x30:{uint16_t count=cr_read_be16(f->value);size_t pos=2;json_object*arr=json_object_new_array();for(uint16_t j=0;j<count;j++){uint16_t nn=cr_read_be16(f->value+pos);pos+=2;char name[256];if(cr_macroman_to_utf8(f->value+pos,nn,name,sizeof(name))){json_object_put(arr);return-1;}pos+=nn;uint16_t an=cr_read_be16(f->value+pos);pos+=2;char address[512];if(cr_macroman_to_utf8(f->value+pos,an,address,sizeof(address))){json_object_put(arr);return-1;}pos+=an;uint16_t rn=cr_read_be16(f->value+pos);pos+=2;char reserved[256];if(cr_macroman_to_utf8(f->value+pos,rn,reserved,sizeof(reserved))){json_object_put(arr);return-1;}pos+=rn;uint32_t rv=cr_read_be32(f->value+pos);pos+=4;json_object*t=json_object_new_object();json_object_object_add(t,"name",json_object_new_string(name));json_object_object_add(t,"address",json_object_new_string(address));json_object_object_add(t,"reservedString",json_object_new_string(reserved));json_object_object_add(t,"reservedValue",json_object_new_int64(rv));json_object_array_add(arr,t);}json_object_object_add(advanced,"trackers",arr);break;}
        case 0x32:json_object_object_add(advanced,"trackerAdvertisementFlags",json_object_new_int64(cr_read_be32(f->value)));break;
        case 0x33:if(decode_setting_text(f,text,sizeof(text)))return-1;json_object_object_add(advanced,"trackerDescription",json_object_new_string(text));break;
        case SETTING_ACCOUNT_GROUPS:break;
        case SETTING_LEGACY_FILES_ROOT:{char path[PATH_MAX];if(f->length>=sizeof(path))return-1;memcpy(path,f->value,f->length);path[f->length]=0;json_object_object_add(runtime,"legacyFilesRoot",json_object_new_string(path));break;}
        case SETTING_AUTHENTICATION_MODE:if(cr_state_apply_authentication_mode_locked(st,f->value[0]==0))return-1;break;
        case SETTING_SEARCH_INDEX_REBUILD_INTERVAL:json_object_object_add(runtime,"searchIndexRebuildIntervalHours",json_object_new_int64(cr_read_be32(f->value)));break;
        case SETTING_SEARCH_INDEX_EXCLUSIONS:{cr_search_index_exclusions x;if(decode_search_index_exclusions_field(f,&x))return-1;json_object*arr=json_object_new_array();if(!arr)return-1;for(size_t j=0;j<x.count;j++)json_object_array_add(arr,json_object_new_string(x.patterns[j]));json_object_object_add(runtime,"searchIndexExclusions",arr);break;}
        default:return-1;
    }}
    if(cr_state_save_locked(st))return-1;
    return cr_state_refresh_parsed_locked(st);
}
typedef struct cr_session_account_ref { uint32_t user_id; char account_id[64]; } cr_session_account_ref;
static void refresh_connected_account_state(cr_server*server){
    pthread_mutex_lock(&server->mutex);size_t count=0;
    for(size_t i=0;i<server->allocated_session_count;i++)if(session_ready_for_async(server->sessions[i]))count++;
    cr_session_account_ref*refs=calloc(count?count:1,sizeof(*refs));size_t n=0;
    if(refs)for(size_t i=0;i<server->allocated_session_count;i++){cr_session*x=server->sessions[i];if(session_ready_for_async(x)){refs[n].user_id=x->user_id;snprintf(refs[n].account_id,sizeof(refs[n].account_id),"%s",x->account_id);n++;}}
    pthread_mutex_unlock(&server->mutex);if(!refs)return;
    for(size_t i=0;i<n;i++){
        cr_account_mode mode=CR_MODE_GUEST;cr_personal_mode personal=CR_PERSONAL_NONE;uint64_t bits=0;char group_id[64]="",login[256]="",name[512]="",files_root_path[1025]="",files_root_name[257]="Allgemein";uint32_t color=0;int has_color=0,local_only=0,found=0;uint8_t*picture=NULL;size_t picture_len=0;
        pthread_mutex_lock(&server->state.mutex);
        for(size_t ai=0;ai<server->state.account_count;ai++){
            cr_account*a=&server->state.accounts[ai];if(strcmp(a->id,refs[i].account_id))continue;
            found=1;mode=a->mode;personal=a->personal;bits=a->permission_bits;local_only=a->local_login_only;snprintf(group_id,sizeof(group_id),"%s",a->group_id);snprintf(login,sizeof(login),"%s",a->login);snprintf(name,sizeof(name),"%s",a->name);color=a->color_rgb;has_color=a->has_color;
            for(size_t gi=0;gi<server->state.account_group_count;gi++)if(!strcasecmp(server->state.account_groups[gi].id,a->group_id)){snprintf(files_root_path,sizeof(files_root_path),"%s",server->state.account_groups[gi].files_root_path);snprintf(files_root_name,sizeof(files_root_name),"%s",server->state.account_groups[gi].files_root_path[0]?server->state.account_groups[gi].files_root_name:"Allgemein");break;}
            if(local_only&&a->picture_len){picture=malloc(a->picture_len);if(picture){memcpy(picture,a->picture,a->picture_len);picture_len=a->picture_len;}}
            break;
        }
        pthread_mutex_unlock(&server->state.mutex);if(!found){free(picture);continue;}
        pthread_mutex_lock(&server->mutex);cr_session*x=find_session_locked(server,refs[i].user_id);
        if(x&&!strcmp(x->account_id,refs[i].account_id)){
            x->mode=mode;x->personal=personal;x->permission_bits=bits;snprintf(x->group_id,sizeof(x->group_id),"%s",group_id);snprintf(x->files_root_path,sizeof(x->files_root_path),"%s",files_root_path);snprintf(x->files_root_name,sizeof(x->files_root_name),"%s",files_root_name);x->has_group_color=has_color;x->group_color_rgb=color;snprintf(x->login,sizeof(x->login),"%s",login);snprintf(x->profile_name,sizeof(x->profile_name),"%s",name);
            if(x->local_only&&local_only){uint8_t nick[512];size_t nn=0;const char*display=name[0]?name:login;if(!cr_utf8_to_macroman(display,nick,sizeof(nick),&nn)&&nn){if(nn>64)nn=64;memcpy(x->nickname,nick,nn);x->nickname_len=nn;}free(x->picture);x->picture=picture;x->picture_len=picture_len;picture=NULL;picture_len=0;}
        }
        pthread_mutex_unlock(&server->mutex);free(picture);
    }
    free(refs);
    pthread_mutex_lock(&server->mutex);
    for(size_t si=0;si<server->allocated_session_count;si++){
        cr_session*source=server->sessions[si];if(!session_ready_for_async(source))continue;
        uint8_t uid[4],color[4];cr_write_be32(uid,source->user_id);
        cr_tlv_out classic_fields[2]={{1,uid,4},{2,source->nickname,(uint16_t)source->nickname_len}};
        cr_tlv_out modern_fields[5];size_t modern_count=0;
        modern_fields[modern_count++]=classic_fields[0];
        modern_fields[modern_count++]=classic_fields[1];
        modern_fields[modern_count++]=(cr_tlv_out){0xb4,source->picture,(uint16_t)source->picture_len};
        modern_fields[modern_count++]=(cr_tlv_out){0xf0000002u,source->status_message,(uint16_t)source->status_message_len};
        append_session_group_color(source,modern_fields,&modern_count,color);
        for(size_t ri=0;ri<server->allocated_session_count;ri++){
            cr_session*dest=server->sessions[ri];
            if(!session_ready_for_async(dest))continue;
            if(dest->modern_transport)session_send(dest,CMD_USER_UPDATE,0,modern_fields,modern_count);
            else session_send(dest,CMD_USER_UPDATE,0,classic_fields,2);
        }
    }
    pthread_mutex_unlock(&server->mutex);
}

static int handle_server_settings_update(cr_session *s, const cr_packet *p) {
    int tracker_changed = 0, exclusions_changed = 0, groups_changed = 0, legacy_root_changed = 0;
    int rebuild_interval_changed = 0;
    uint32_t rebuild_interval_hours = 0;
    int rc = -1;
    cr_search_index_exclusions exclusions;
    memset(&exclusions, 0, sizeof(exclusions));
    cr_account_group *account_groups = calloc(CR_MAX_ACCOUNT_GROUPS, sizeof(*account_groups));
    size_t account_group_count = 0;
    char legacy_root[PATH_MAX] = "";
    if (!account_groups) return send_error(s, p->transaction_id, 1);

    for (uint16_t i = 0; i < p->field_count; i++) {
        const cr_tlv *field = &p->fields[i];
        if (validate_setting_field(s, field)) {
            log_msg("Server-settings validation failed for field 0x%08x", field->type);
            rc = send_error(s, p->transaction_id, 1);
            goto done;
        }
        if (field->type == 0x30 || field->type == 0x32 || field->type == 0x33)
            tracker_changed = 1;
        if (field->type == SETTING_SEARCH_INDEX_EXCLUSIONS) {
            if (decode_search_index_exclusions_field(field, &exclusions)) {
                rc = send_error(s, p->transaction_id, 1);
                goto done;
            }
            exclusions_changed = 1;
        }
        if (field->type == SETTING_SEARCH_INDEX_REBUILD_INTERVAL) {
            rebuild_interval_hours = cr_read_be32(field->value);
            rebuild_interval_changed = 1;
        }
        if (field->type == SETTING_LEGACY_FILES_ROOT) {
            if (field->length >= sizeof(legacy_root)) { rc = send_error(s,p->transaction_id,1); goto done; }
            memcpy(legacy_root,field->value,field->length);legacy_root[field->length]=0;legacy_root_changed=1;
        }
        if (field->type == SETTING_ACCOUNT_GROUPS) {
            if (decode_account_groups_field(field, account_groups, &account_group_count)) {
                log_msg("Account-group setting decode failed");
                rc = send_error(s, p->transaction_id, 1);
                goto done;
            }
            groups_changed = 1;
        }
    }

    if (exclusions_changed && persist_search_index_exclusions_config(s->server, &exclusions)) {
        log_msg("Could not persist search-index exclusions to %s", s->server->config_path);
        rc = send_error(s, p->transaction_id, 1);
        goto done;
    }

    if (legacy_root_changed) {
        if ((legacy_root[0] && ensure_directory_tree(legacy_root)) || persist_legacy_files_root_config(s->server,legacy_root)) {
            log_msg("Could not apply/persist legacy Files root '%s'",legacy_root);
            rc=send_error(s,p->transaction_id,1);goto done;
        }
    }

    pthread_mutex_lock(&s->server->state.mutex);
    rc = apply_settings_locked(s->server, p);
    pthread_mutex_unlock(&s->server->state.mutex);
    if (rc) {
        log_msg("Server-settings base state apply failed");
        rc = send_error(s, p->transaction_id, 1);
        goto done;
    }

    if (persist_startup_configuration_config(s->server)) {
        log_msg("Could not persist startup configuration mirror to %s", s->server->config_path);
        rc = send_error(s, p->transaction_id, 1);
        goto done;
    }

    if (tracker_changed && persist_tracker_registration_config(s->server)) {
        log_msg("Could not persist tracker registration mirror to %s", s->server->config_path);
        rc = send_error(s, p->transaction_id, 1);
        goto done;
    }

    if (groups_changed) {
        if (cr_state_set_account_groups(&s->server->state, account_groups, account_group_count)) {
            log_msg("Account-group state update failed for %zu group(s)", account_group_count);
            rc = send_error(s, p->transaction_id, 1);
            goto done;
        }
        refresh_connected_account_state(s->server);
    }

    if (exclusions_changed) {
        pthread_mutex_lock(&s->server->mutex);
        s->server->search_index_exclusions = exclusions;
        pthread_mutex_unlock(&s->server->mutex);
        log_msg("Search-index exclusions updated; removals take full effect on the next manual or scheduled rebuild");
    }
    if (rebuild_interval_changed) {
        s->server->search_index_rebuild_interval_hours = rebuild_interval_hours;
        s->server->last_file_index_schedule_check = 0;
        log_msg(rebuild_interval_hours
            ? "Automatic full search-index rebuild interval updated"
            : "Automatic full search-index rebuilds disabled");
    }

    log_msg("Server settings updated remotely");
    rc = send_task_complete(s, p->transaction_id);
    if (tracker_changed) {
        request_tracker_refresh(s->server);
        send_tracker_registrations(s->server);
        pthread_mutex_lock(&s->server->mutex);
        s->server->last_tracker_registration = time(NULL);
        pthread_mutex_unlock(&s->server->mutex);
    }

done:
    free(account_groups);
    return rc;
}

static int handle_forum_thread_list(cr_session*s,const cr_packet*p){
    const cr_tlv*group=cr_packet_field(p,1);if(!group||!group->length||group->length>64)return send_error(s,p->transaction_id,1);
    cr_newsgroup g;if(lookup_newsgroup(s->server,group->value,group->length,&g)||!group_can_read(&g,s->mode))return send_error(s,p->transaction_id,1);
    cr_buffer b;cr_buffer_init(&b);int rc=-1;if(cr_news_threads(&s->server->news,g.id,&b)||b.len>UINT16_MAX){cr_buffer_free(&b);return send_error(s,p->transaction_id,1);}cr_tlv_out f={1,b.data,(uint16_t)b.len};rc=session_send(s,CMD_FORUM_THREAD_LIST,p->transaction_id,&f,1);cr_buffer_free(&b);return rc;
}
static int handle_forum_thread_entries(cr_session*s,const cr_packet*p){
    const cr_tlv*group=cr_packet_field(p,1),*thread=cr_packet_field(p,2);if(!group||!group->length||group->length>64||!thread||thread->length!=4)return send_error(s,p->transaction_id,1);
    cr_newsgroup g;if(lookup_newsgroup(s->server,group->value,group->length,&g)||!group_can_read(&g,s->mode))return send_error(s,p->transaction_id,1);
    uint32_t tid=cr_read_be32(thread->value);cr_buffer posts,caps;cr_buffer_init(&posts);cr_buffer_init(&caps);int rc=-1;
    if(cr_news_thread_posts(&s->server->news,g.id,tid,&posts)||cr_news_thread_capabilities(&s->server->news,g.id,tid,s->account_id,account_perm(s,PERM_MANAGE_NEWSGROUPS),&caps)||posts.len>UINT16_MAX||caps.len>UINT16_MAX){cr_buffer_free(&posts);cr_buffer_free(&caps);return send_error(s,p->transaction_id,1);}
    cr_tlv_out f[]={{1,posts.data,(uint16_t)posts.len},{2,caps.data,(uint16_t)caps.len}};rc=session_send(s,CMD_FORUM_THREAD_ENTRIES,p->transaction_id,f,2);cr_buffer_free(&posts);cr_buffer_free(&caps);return rc;
}

typedef struct cr_reaction_account_ref {
    uint8_t kind;
    const uint8_t *account_id;
    uint16_t account_id_len;
} cr_reaction_account_ref;

static int encode_reaction_user_names(cr_session*s,const char*group_id,uint32_t article_id,cr_buffer*out){
    cr_buffer raw;cr_buffer_init(&raw);
    if(cr_news_reaction_accounts(&s->server->news,group_id,article_id,&raw)){cr_buffer_free(&raw);return-1;}
    if(raw.len<2){cr_buffer_free(&raw);return-1;}
    uint16_t row_count=cr_read_be16(raw.data);size_t pos=2;
    cr_reaction_account_ref*rows=row_count?calloc(row_count,sizeof(*rows)):NULL;
    if(row_count&&!rows){cr_buffer_free(&raw);return-1;}
    uint16_t counts[7]={0};
    for(uint16_t i=0;i<row_count;i++){
        if(pos+3>raw.len){free(rows);cr_buffer_free(&raw);return-1;}
        uint8_t kind=raw.data[pos++];uint16_t n=cr_read_be16(raw.data+pos);pos+=2;
        if(kind<1||kind>6||pos+n>raw.len){free(rows);cr_buffer_free(&raw);return-1;}
        rows[i]=(cr_reaction_account_ref){kind,raw.data+pos,n};counts[kind]++;pos+=n;
    }
    if(pos!=raw.len){free(rows);cr_buffer_free(&raw);return-1;}
    uint8_t group_count=0;for(int kind=1;kind<=6;kind++)if(counts[kind])group_count++;
    out->len=0;if(cr_buffer_append_u8(out,group_count)){free(rows);cr_buffer_free(&raw);return-1;}
    pthread_mutex_lock(&s->server->state.mutex);
    int failed=0;
    for(int kind=1;kind<=6&&!failed;kind++){
        if(!counts[kind])continue;
        if(cr_buffer_append_u8(out,(uint8_t)kind)||cr_buffer_append_u16(out,counts[kind])){failed=1;break;}
        for(uint16_t i=0;i<row_count&&!failed;i++){
            if(rows[i].kind!=(uint8_t)kind)continue;
            const char*display="";
            for(size_t ai=0;ai<s->server->state.account_count;ai++){
                cr_account*a=&s->server->state.accounts[ai];size_t id_len=strlen(a->id);
                if(id_len!=rows[i].account_id_len||strncasecmp(a->id,(const char*)rows[i].account_id,id_len))continue;
                display=a->last_nickname[0]?a->last_nickname:(a->name[0]?a->name:a->login);break;
            }
            size_t n=strlen(display);if(n>UINT16_MAX||cr_buffer_append_string16(out,display,n))failed=1;
        }
    }
    pthread_mutex_unlock(&s->server->state.mutex);
    free(rows);cr_buffer_free(&raw);
    if(failed){out->len=0;return-1;}
    if(out->len>UINT16_MAX){out->len=0;return 1;}
    return 0;
}

static int handle_forum_article_reactions(cr_session*s,const cr_packet*p){
    const cr_tlv*group=cr_packet_field(p,1),*article=cr_packet_field(p,2);if(!group||!group->length||group->length>64||!article||article->length!=4)return send_error(s,p->transaction_id,1);
    cr_newsgroup g;if(lookup_newsgroup(s->server,group->value,group->length,&g)||!group_can_read(&g,s->mode))return send_error(s,p->transaction_id,1);
    uint32_t aid=cr_read_be32(article->value);cr_buffer b,users;cr_buffer_init(&b);cr_buffer_init(&users);
    if(cr_news_reactions(&s->server->news,g.id,aid,s->account_id,&b)||b.len>UINT16_MAX){cr_buffer_free(&b);cr_buffer_free(&users);return send_error(s,p->transaction_id,1);}
    int users_rc=encode_reaction_user_names(s,g.id,aid,&users);if(users_rc<0){cr_buffer_free(&b);cr_buffer_free(&users);return send_error(s,p->transaction_id,1);}
    cr_tlv_out f[]={{1,b.data,(uint16_t)b.len},{2,users.data,(uint16_t)users.len}};int rc=session_send(s,CMD_FORUM_ARTICLE_REACTIONS,p->transaction_id,f,users_rc==0?2:1);cr_buffer_free(&b);cr_buffer_free(&users);return rc;
}
static int handle_forum_article_reaction_set(cr_session*s,const cr_packet*p){
    const cr_tlv*group=cr_packet_field(p,1),*article=cr_packet_field(p,2),*reaction=cr_packet_field(p,3);if(!group||!group->length||group->length>64||!article||article->length!=4||!reaction||reaction->length!=1||reaction->value[0]>6)return send_error(s,p->transaction_id,1);
    cr_newsgroup g;if(lookup_newsgroup(s->server,group->value,group->length,&g)||!group_can_read(&g,s->mode))return send_error(s,p->transaction_id,1);
    uint32_t aid=cr_read_be32(article->value);cr_buffer b,users;cr_buffer_init(&b);cr_buffer_init(&users);
    if(cr_news_set_reaction(&s->server->news,g.id,aid,s->account_id,reaction->value[0],&b)||b.len>UINT16_MAX){cr_buffer_free(&b);cr_buffer_free(&users);return send_error(s,p->transaction_id,1);}
    int users_rc=encode_reaction_user_names(s,g.id,aid,&users);if(users_rc<0){cr_buffer_free(&b);cr_buffer_free(&users);return send_error(s,p->transaction_id,1);}
    cr_tlv_out f[]={{1,b.data,(uint16_t)b.len},{2,users.data,(uint16_t)users.len}};
    int rc=session_send(s,CMD_FORUM_ARTICLE_REACTION_SET,p->transaction_id,f,users_rc==0?2:1);
    if(!rc){
        uint8_t group_wire[256];size_t group_wire_len=0;uint8_t article_wire[4];cr_write_be32(article_wire,aid);
        if(!cr_utf8_to_macroman(g.name,group_wire,sizeof(group_wire),&group_wire_len)&&group_wire_len&&group_wire_len<=64){
            cr_tlv_out changed[]={{1,group_wire,(uint16_t)group_wire_len},{2,article_wire,4}};
            pthread_mutex_lock(&s->server->mutex);
            for(size_t i=0;i<s->server->allocated_session_count;i++){
                cr_session*x=s->server->sessions[i];
                if(x&&x!=s&&x->modern_transport&&session_ready_for_async(x)&&group_can_read(&g,x->mode))
                    session_send(x,CMD_FORUM_ARTICLE_REACTION_CHANGED,0,changed,2);
            }
            pthread_mutex_unlock(&s->server->mutex);
        }
    }
    cr_buffer_free(&b);cr_buffer_free(&users);return rc;
}

static int handle_forum_article_delete(cr_session*s,const cr_packet*p){
    const cr_tlv*group=cr_packet_field(p,1),*article=cr_packet_field(p,2);if(!group||!group->length||group->length>64||!article||article->length!=4)return send_error(s,p->transaction_id,1);
    cr_newsgroup g;if(lookup_newsgroup(s->server,group->value,group->length,&g)||!group_can_read(&g,s->mode))return send_error(s,p->transaction_id,1);
    uint32_t aid=cr_read_be32(article->value);int deleted=0;if(cr_news_soft_delete(&s->server->news,g.id,aid,s->account_id,account_perm(s,PERM_MANAGE_NEWSGROUPS),&deleted)||!deleted)return send_error(s,p->transaction_id,1);
    char message[32];snprintf(message,sizeof(message),"%u",aid);const char*messages[]={message};if(cr_media_store_remove_refs(&s->server->media,CR_MEDIA_KIND_NEWS,g.id,messages,1))return send_error(s,p->transaction_id,1);
    log_msg("News post %u deleted from %s by user %u",aid,g.name,s->user_id);return send_task_complete(s,p->transaction_id);
}

static void event_packet_path(const cr_packet*p,uint32_t field,char*out,size_t cap){
    const cr_tlv*f=cr_packet_field(p,field);if(!cap)return;out[0]=0;if(!f||!f->length){snprintf(out,cap,"/");return;}uint8_t raw[4096];size_t n=f->length<sizeof(raw)?f->length:sizeof(raw);memcpy(raw,f->value,n);for(size_t i=0;i<n;i++)if(raw[i]==1)raw[i]='/';if(cap<2){return;}out[0]='/';if(cr_macroman_to_utf8(raw,n,out+1,cap-1)){snprintf(out,cap,"<invalid-path>");return;}
}
static void event_packet_text(const cr_packet*p,uint32_t field,char*out,size_t cap){const cr_tlv*f=cr_packet_field(p,field);if(!cap)return;out[0]=0;if(f&&f->length&&cr_macroman_to_utf8(f->value,f->length,out,cap))snprintf(out,cap,"<invalid-macroman>");}
static void record_request_event(cr_session*s,const cr_packet*p){
    const char*cat=NULL,*action=NULL;char detail[10000]="",a[4096]="",b[4096]="";
    switch(p->command){
        case CMD_DIRECTORY:event_packet_path(p,1,a,sizeof(a));cat="files";action="list";snprintf(detail,sizeof(detail),"path=%s",a);break;
        case CMD_FILE_INFO:event_packet_path(p,1,a,sizeof(a));cat="files";action="info";snprintf(detail,sizeof(detail),"path=%s",a);break;
        case CMD_CREATE_FOLDER:event_packet_path(p,1,a,sizeof(a));event_packet_text(p,3,b,sizeof(b));cat="files";action="create-folder";snprintf(detail,sizeof(detail),"parent=%s name=%s",a,b);break;
        case CMD_DELETE_FILE:event_packet_path(p,1,a,sizeof(a));cat="files";action="delete";snprintf(detail,sizeof(detail),"path=%s",a);break;
        case CMD_MOVE_FILE:event_packet_path(p,1,a,sizeof(a));event_packet_path(p,2,b,sizeof(b));cat="files";action="move";snprintf(detail,sizeof(detail),"from=%s to=%s",a,b);break;
        case CMD_SET_FILE_INFO:event_packet_path(p,1,a,sizeof(a));cat="files";action="set-info";snprintf(detail,sizeof(detail),"path=%s",a);break;
        case CMD_FILE_LABEL_SET:event_packet_path(p,1,a,sizeof(a));cat="files";action="set-label";snprintf(detail,sizeof(detail),"path=%s",a);break;
        case CMD_ARTICLE_READ:{event_packet_text(p,1,a,sizeof(a));const cr_tlv*f=cr_packet_field(p,2);unsigned id=f&&f->length==4?cr_read_be32(f->value):0;cat="news";action="read-article";snprintf(detail,sizeof(detail),"category=%s article=%u",a,id);break;}
        case CMD_FORUM_THREAD_ENTRIES:{event_packet_text(p,1,a,sizeof(a));const cr_tlv*f=cr_packet_field(p,2);unsigned id=f&&f->length==4?cr_read_be32(f->value):0;cat="news";action="read-thread";snprintf(detail,sizeof(detail),"category=%s thread=%u",a,id);break;}
        case CMD_FORUM_ARTICLE_DELETE:{event_packet_text(p,1,a,sizeof(a));const cr_tlv*f=cr_packet_field(p,2);unsigned id=f&&f->length==4?cr_read_be32(f->value):0;cat="news";action="delete-post";snprintf(detail,sizeof(detail),"category=%s article=%u",a,id);break;}
        case CMD_FLAT_NEWS_LIST:cat="news";action="read-flat-news";break;case CMD_FLAT_NEWS_POST:cat="news";action="post-flat-news";break;
        case CMD_CHANNEL_JOIN:cat="chat";action="join";break;case CMD_CHANNEL_LEAVE:cat="chat";action="leave";break;case CMD_CHANNEL_CHAT:cat="chat";action="message";break;
        case CMD_PRIVATE_MESSAGE:cat="messages";action="private-message";break;case CMD_OFFLINE_MESSAGE_SEND:cat="messages";action="offline-message";break;case CMD_BROADCAST:cat="messages";action="broadcast";break;
        case CMD_ACCOUNT_SAVE:cat="administration";action="save-account";break;case CMD_ACCOUNT_DELETE:cat="administration";action="delete-account";break;case CMD_SET_SERVER_SETTINGS:cat="administration";action="change-server-settings";break;case CMD_BOT_SET_ENABLED:cat="administration";action="control-bot";break;case CMD_BOT_SET_GREETING:cat="administration";action="configure-bot-greeting";break;case CMD_BOT_SET_COMMAND_RULES:cat="administration";action="configure-bot-commands";break;case CMD_BOT_SET_RSS_FEEDS:cat="administration";action="configure-bot-rss";break;case CMD_BOT_TEST_RSS_FEED:cat="administration";action="test-bot-rss";break;case CMD_REBUILD_SEARCH_INDEX:cat="administration";action="rebuild-search-index";break;case CMD_CHANGE_OWN_PASSWORD:cat="account";action="change-password";break;
        default:break;
    }
    if(cat)event_msg(s,cat,action,detail);
}

static int handle_authenticated(cr_session*s,const cr_packet*p){record_request_event(s,p);switch(p->command){
case CMD_SERVER_INFO:return handle_server_info(s,p);case CMD_DIRECTORY:return handle_directory(s,p);
case CMD_DISCONNECT_USER:return handle_disconnect_user(s,p,0);case CMD_BAN_USER:return handle_disconnect_user(s,p,1);
case CMD_PRIVATE_MESSAGE:return handle_private_message(s,p);case CMD_OFFLINE_MESSAGE_SEND:return handle_offline_message_send(s,p);case CMD_OFFLINE_MESSAGE_FETCH:return handle_offline_message_fetch(s,p);case CMD_OFFLINE_MESSAGE_ACK:return handle_offline_message_ack(s,p);case CMD_OFFLINE_MESSAGE_RECIPIENTS:return handle_offline_message_recipients(s,p);case CMD_OFFLINE_MESSAGE_PREFERENCE:return handle_offline_message_preference(s,p);case CMD_EXTENDED_OWN_USER_INFO:return handle_extended_own_user_info(s,p);
case CMD_USER_INFO:return handle_user_info(s,p);case CMD_USER_UPDATE:return handle_user_update(s,p);case CMD_PRESENCE:return handle_presence(s,p);
case CMD_CREATE_FOLDER:return handle_create_folder(s,p);case CMD_DELETE_FILE:return handle_delete_file(s,p);case CMD_FILE_INFO:return handle_file_info(s,p);case CMD_SET_FILE_INFO:return handle_set_file_info(s,p);case CMD_FILE_LABEL_SET:return handle_set_file_label(s,p);case CMD_MOVE_FILE:return handle_move_file(s,p);case CMD_EMPTY_TRASH:return handle_empty_trash(s,p);
case CMD_FLAT_NEWS_POST:return handle_flat_news_post(s,p);case CMD_FLAT_NEWS_LIST:return handle_flat_news_list(s,p);case CMD_FLAT_NEWS_DELETE:return handle_flat_news_delete(s,p);case CMD_FLAT_NEWS_CLEAR:return handle_flat_news_clear(s,p);
case CMD_TRANSFER_INFO:return handle_transfer_info(s,p);
case CMD_REQUEST_SERVER_SETTINGS:return handle_server_settings_request(s,p);case CMD_SET_SERVER_SETTINGS:return handle_server_settings_update(s,p);
case CMD_SERVER_LOG_REQUEST:return handle_server_log_request(s,p);case CMD_SERVER_LOG_CLEAR:return handle_server_log_clear(s,p);case CMD_EVENT_LOG_REQUEST:return handle_event_log_request(s,p);case CMD_EVENT_LOG_CLEAR:return handle_event_log_clear(s,p);case CMD_REBUILD_SEARCH_INDEX:return handle_rebuild_search_index(s,p);
case CMD_ACCOUNT_LIST:return handle_account_list(s,p);case CMD_GET_ACCOUNT:return handle_get_account(s,p);case CMD_ACCOUNT_SAVE:return handle_account_save(s,p);case CMD_ACCOUNT_DELETE:return handle_account_delete(s,p);case CMD_CHANGE_OWN_PASSWORD:return handle_change_own_password(s,p);case CMD_BOT_STATUS_REQUEST:return handle_bot_status(s,p);case CMD_BOT_SET_ENABLED:return handle_bot_set_enabled(s,p);case CMD_BOT_SET_GREETING:return handle_bot_set_greeting(s,p);case CMD_BOT_SET_COMMAND_RULES:return handle_bot_set_command_rules(s,p);case CMD_BOT_SET_RSS_FEEDS:return handle_bot_set_rss_feeds(s,p);case CMD_BOT_TEST_RSS_FEED:return handle_bot_test_rss_feed(s,p);
case CMD_ADMIN_NEWSGROUP_LIST:return handle_admin_newsgroup_list(s,p);case CMD_NEWSGROUP_CREATE:return handle_newsgroup_admin_mutation(s,p,0);case CMD_NEWSGROUP_MODIFY:return handle_newsgroup_admin_mutation(s,p,1);case CMD_NEWSGROUP_DELETE:return handle_newsgroup_admin_mutation(s,p,2);
case CMD_ARTICLE_READ:return handle_article_read(s,p);case CMD_FORUM_THREAD_LIST:return handle_forum_thread_list(s,p);case CMD_FORUM_THREAD_ENTRIES:return handle_forum_thread_entries(s,p);case CMD_FORUM_ARTICLE_REACTIONS:return handle_forum_article_reactions(s,p);case CMD_FORUM_ARTICLE_REACTION_SET:return handle_forum_article_reaction_set(s,p);case CMD_FORUM_ARTICLE_DELETE:return handle_forum_article_delete(s,p);case CMD_ARTICLE_DELETE:return handle_article_delete(s,p);
case CMD_BROADCAST:return handle_broadcast(s,p);case CMD_CHANNEL_LIST:return handle_channel_list(s,p);case CMD_NEWSGROUP_LIST:return handle_newsgroups(s,p);
case CMD_CHANNEL_JOIN:return handle_channel_join(s,p);case CMD_CHANNEL_LEAVE:return handle_channel_leave(s,p);case CMD_CHANNEL_CHAT:return handle_channel_chat(s,p);
case CMD_CHANNEL_SETTINGS:return handle_channel_settings(s,p);case CMD_CHANNEL_USER_MODE:return handle_channel_user_mode(s,p);case CMD_CHANNEL_INVITE:return handle_channel_invite(s,p);case CMD_CHANNEL_DECLINE:return handle_channel_decline(s,p);
default:if(p->transaction_id)return send_error(s,p->transaction_id,1);log_msg("Unhandled legacy command 0x%08x from user %u",p->command,s->user_id);return 0;}}

static void copy_client_metadata_field(const cr_packet*p,uint32_t type,char*out,size_t cap){
    const cr_tlv*f=cr_packet_field(p,type);
    if(!f||!f->length||f->length>CLIENT_METADATA_MAX_BYTES||f->length>=cap||
       !valid_utf8_bytes(f->value,f->length)||memchr(f->value,0,f->length)||memchr(f->value,'\n',f->length)||memchr(f->value,'\r',f->length))return;
    memcpy(out,f->value,f->length);out[f->length]=0;
}
static void capture_client_metadata(cr_session*s,const cr_packet*p){
    if(!s->modern_transport)return;
    copy_client_metadata_field(p,CLIENT_FIELD_OPERATING_SYSTEM,s->client_operating_system,sizeof(s->client_operating_system));
    copy_client_metadata_field(p,CLIENT_FIELD_CPU_ARCHITECTURE,s->client_cpu_architecture,sizeof(s->client_cpu_architecture));
    copy_client_metadata_field(p,CLIENT_FIELD_VERSION,s->client_version,sizeof(s->client_version));
    copy_client_metadata_field(p,CLIENT_FIELD_BUILD,s->client_build,sizeof(s->client_build));
}

static int register_authenticated(cr_session *s, const cr_account *a,
                                  const uint8_t *nickname, size_t nickname_len,
                                  const uint8_t *key, size_t key_len) {
    cr_server *server=s->server;
    uint32_t group_color=a->color_rgb;int has_group_color=a->has_color;char files_root_path[1025]="",files_root_name[257]="Allgemein";state_group_files_root(&server->state,a->group_id,files_root_path,sizeof(files_root_path),files_root_name,sizeof(files_root_name));
    pthread_mutex_lock(&server->mutex);
    s->user_id=server->next_user_id++;
    s->mode=a->mode; s->personal=a->personal; s->permission_bits=a->permission_bits;
    snprintf(s->account_id,sizeof(s->account_id),"%s",a->id);snprintf(s->group_id,sizeof(s->group_id),"%s",a->group_id);snprintf(s->files_root_path,sizeof(s->files_root_path),"%s",files_root_path);snprintf(s->files_root_name,sizeof(s->files_root_name),"%s",files_root_path[0]?files_root_name:"Allgemein");s->has_group_color=has_group_color;s->group_color_rgb=group_color;
    snprintf(s->login,sizeof(s->login),"%s",a->login);
    snprintf(s->profile_name,sizeof(s->profile_name),"%s",a->name);
    snprintf(s->email,sizeof(s->email),"%s",a->email);
    snprintf(s->about,sizeof(s->about),"%s",a->about);
    s->nickname_len=nickname_len?nickname_len:strlen(a->login);
    if(nickname_len) memcpy(s->nickname,nickname,nickname_len);
    else { s->nickname_len=0; cr_utf8_to_macroman(a->login,s->nickname,sizeof(s->nickname),&s->nickname_len); }
    s->key_len=key_len>sizeof(s->key)?sizeof(s->key):key_len; memcpy(s->key,key,s->key_len);
    if(a->picture_len){s->picture=malloc(a->picture_len);if(s->picture){memcpy(s->picture,a->picture,a->picture_len);s->picture_len=a->picture_len;}}
    s->authenticated=1; s->login_at=s->last_activity=time(NULL);
    pthread_mutex_unlock(&server->mutex);
    cr_state_record_login_id(&server->state,a->id,a->mode);
    return 0;
}

static int authenticate(cr_session *s, const cr_packet *p, const uint8_t challenge[12]) {
    const cr_tlv *login=cr_packet_field(p,1), *digest=cr_packet_field(p,2), *nick=cr_packet_field(p,4);
    if(!login||!digest||!nick||login->length>63||digest->length!=32||nick->length>255)return-1;
    char user[512]; if(cr_macroman_to_utf8(login->value,login->length,user,sizeof(user)))return-1;
    char password[512]; int valid=0;
    pthread_mutex_lock(&s->server->state.mutex);
    int idx=s->server->state.legacy_compatible?cr_state_find_account(&s->server->state,user):-1;
    if(idx>=0&&s->server->state.accounts[idx].has_legacy_password&&!s->server->state.accounts[idx].local_login_only){valid=1;snprintf(password,sizeof(password),"%s",s->server->state.accounts[idx].legacy_password);}
    else snprintf(password,sizeof(password),"carracho-invalid-login-placeholder");
    pthread_mutex_unlock(&s->server->state.mutex);
    uint8_t pwmac[512],expected[32],key[128];size_t pwlen=0,keylen=0;
    if(cr_utf8_to_macroman(password,pwmac,sizeof(pwmac),&pwlen)||cr_login_digest_hex(pwmac,pwlen,challenge,expected)||cr_derive_session_key(pwmac,pwlen,challenge,key,sizeof(key),&keylen))return-1;
    uint8_t diff=0;for(int i=0;i<32;i++)diff|=expected[i]^digest->value[i];if(!valid||diff)return 1;
    cr_account copy; memset(&copy,0,sizeof(copy));
    pthread_mutex_lock(&s->server->state.mutex);
    idx=cr_state_find_account(&s->server->state,user);
    if(idx<0||!s->server->state.accounts[idx].has_legacy_password||s->server->state.accounts[idx].local_login_only){pthread_mutex_unlock(&s->server->state.mutex);return 1;}
    copy=s->server->state.accounts[idx]; copy.picture=NULL;
    if(s->server->state.accounts[idx].picture_len){copy.picture=malloc(s->server->state.accounts[idx].picture_len);if(!copy.picture){pthread_mutex_unlock(&s->server->state.mutex);return-1;}memcpy(copy.picture,s->server->state.accounts[idx].picture,s->server->state.accounts[idx].picture_len);copy.picture_len=s->server->state.accounts[idx].picture_len;}
    pthread_mutex_unlock(&s->server->state.mutex);
    int rc=register_authenticated(s,&copy,nick->value,nick->length,key,keylen);free(copy.picture);return rc;
}
static int recv_authenticated_packet(cr_session*s,cr_packet*p,cr_buffer*plain){
    if(!s->modern_transport)return cr_recv_packet(s->fd,s->key,s->key_len,p,plain);
    uint8_t header[CR_AEAD_HEADER_LENGTH];
    if(cr_read_exact(s->fd,header,sizeof(header))){log_msg("Authenticated control read ended before frame header for user %u",s->user_id);return-1;}
    uint32_t n=cr_read_be32(header);uint64_t seq=cr_read_be64(header+4);
    if(n<CR_PACKET_HEADER_SIZE||n>CR_PACKET_HEADER_SIZE+CR_MAX_BODY_LENGTH){log_msg("Rejected authenticated control length %u for user %u",n,s->user_id);return-1;}
    if(seq!=s->control_receive_sequence){log_msg("Rejected authenticated control sequence %llu (expected %llu) for user %u",(unsigned long long)seq,(unsigned long long)s->control_receive_sequence,s->user_id);return-1;}
    size_t frame_len=sizeof(header)+(size_t)n+CR_AEAD_TAG_LENGTH;uint8_t*frame=malloc(frame_len);if(!frame)return-1;memcpy(frame,header,sizeof(header));int rc=-1;
    if(cr_read_exact(s->fd,frame+sizeof(header),(size_t)n+CR_AEAD_TAG_LENGTH)){log_msg("Authenticated control body ended early for user %u",s->user_id);goto done;}
    if(cr_decode_aead(frame,frame_len,s->control_receive_key,s->control_receive_sequence,"carracho/control/v1",CR_PACKET_HEADER_SIZE+CR_MAX_BODY_LENGTH,plain)){log_msg("Rejected authenticated control tag for user %u",s->user_id);goto done;}
    size_t logical=0;if(cr_parse_packet(plain->data,plain->len,p,&logical)||logical!=plain->len){log_msg("Rejected authenticated control packet structure for user %u",s->user_id);goto done;}
    s->control_receive_sequence++;rc=0;
done:free(frame);return rc;
}

static void *session_main(void*opaque){
    cr_session*s=opaque;uint8_t hello[13];
    if(cr_read_exact(s->fd,hello,sizeof(hello))||memcmp(hello,k_client_hello,11))goto done;
    uint16_t client_version=cr_read_be16(hello+11);if(client_version!=1&&client_version!=2)goto done;s->modern_transport=client_version==2;
    if(!s->modern_transport){pthread_mutex_lock(&s->server->state.mutex);int legacy_allowed=s->server->state.legacy_compatible;pthread_mutex_unlock(&s->server->state.mutex);if(!legacy_allowed){log_msg("Rejected legacy connection from %s: modern-only authentication enabled",s->peer_ip);goto done;}}
    if(cr_write_all(s->fd,s->modern_transport?k_server_hello_modern:k_server_hello,sizeof(k_server_hello)))goto done;
    uint8_t challenge[12];if(RAND_bytes(challenge,sizeof(challenge))!=1)goto done;cr_tlv_out ch={1,challenge,12};if(session_send_key(s,k_initial_key,sizeof(k_initial_key),CMD_CHALLENGE,0,&ch,1))goto done;
    cr_packet p;cr_buffer plain;cr_buffer_init(&plain);if(cr_recv_packet(s->fd,k_initial_key,sizeof(k_initial_key),&p,&plain)||p.command!=CMD_LOGIN){cr_buffer_free(&plain);goto done;}
    uint8_t client_public_key[32]={0};if(s->modern_transport){const cr_tlv*client_key=cr_packet_field(&p,5);if(!client_key||client_key->length!=32){cr_buffer_free(&plain);goto done;}memcpy(client_public_key,client_key->value,32);}
    int auth=authenticate(s,&p,challenge);if(auth==0)capture_client_metadata(s,&p);cr_buffer_free(&plain);if(auth!=0){cr_state_stat_add(&s->server->state,"incorrectLogins",1);uint8_t code[2];cr_write_be16(code,100);cr_tlv_out ef={1,code,2};session_send_key(s,k_initial_key,sizeof(k_initial_key),CMD_ERROR,p.transaction_id,&ef,1);goto done;}
    uint8_t modern_master[32]={0};
    if(s->modern_transport){
        uint8_t private_key[32],shared[32];
        if(RAND_bytes(s->modern_salt,sizeof(s->modern_salt))!=1||cr_x25519_generate(private_key,s->modern_server_public_key)||
           cr_x25519_shared(private_key,client_public_key,shared)||
           cr_handshake_authenticator(s->key,s->key_len,challenge,client_public_key,s->modern_server_public_key,s->modern_salt,s->modern_handshake_authenticator)||
           cr_transport_master(shared,s->key,s->key_len,s->modern_salt,modern_master))goto done;
        OPENSSL_cleanse(private_key,sizeof(private_key));OPENSSL_cleanse(shared,sizeof(shared));
    }
    if(send_login_success(s))goto done;
    if(s->modern_transport){memcpy(s->key,modern_master,sizeof(modern_master));s->key_len=sizeof(modern_master);OPENSSL_cleanse(modern_master,sizeof(modern_master));if(cr_derive_control_keys(s->key,s->key_len,s->modern_salt,1,s->control_send_key,s->control_receive_key))goto done;}
    pthread_mutex_lock(&s->server->mutex);s->announced=1;pthread_mutex_unlock(&s->server->mutex);
    if(s->modern_transport&&send_initial_user_updates(s))goto done;
    send_offline_message_notice(s);broadcast_user_arrived(s);log_msg("User %u logged in from %s using %s",s->user_id,s->peer_ip,s->modern_transport?"AES-256-GCM":"legacy Blowfish");event_msg(s,"session","login","connected");
    while(!s->server->stop&&!s->closed){cr_buffer_init(&plain);if(recv_authenticated_packet(s,&p,&plain)){cr_buffer_free(&plain);break;}if(command_is_user_activity(p.command))mark_user_active(s);int rc=handle_authenticated(s,&p);cr_buffer_free(&plain);if(rc<0)break;}
done:session_unregister(s);shutdown(s->fd,SHUT_RDWR);close(s->fd);log_msg("Connection from %s closed",s->peer_ip);pthread_mutex_lock(&s->server->mutex);s->finished=1;pthread_mutex_unlock(&s->server->mutex);return NULL;
}

static void send_async_error_to_user(cr_server*s,uint32_t user_id,uint16_t code){pthread_mutex_lock(&s->mutex);cr_session*x=find_session_locked(s,user_id);if(x&&x->authenticated&&!x->closed)send_error(x,0,code);pthread_mutex_unlock(&s->mutex);}

static void broadcast_banner_changed(cr_server*s){pthread_mutex_lock(&s->mutex);for(size_t i=0;i<s->allocated_session_count;i++){cr_session*x=s->sessions[i];if(session_ready_for_async(x))session_send(x,CMD_BANNER_CHANGED,0,NULL,0);}pthread_mutex_unlock(&s->mutex);}

static int ascii_case_contains(const char *haystack,const char *needle){if(!*needle)return 1;size_t nl=strlen(needle);for(const char*h=haystack;*h;h++){size_t i=0;while(i<nl&&h[i]&&tolower((unsigned char)h[i])==tolower((unsigned char)needle[i]))i++;if(i==nl)return 1;}return 0;}
static int send_search_result(cr_transfer_stream*stream,const uint8_t*name,size_t name_len,uint32_t creator,uint32_t file_type,uint32_t size,uint32_t timestamp,const uint8_t*path,size_t path_len){
    cr_buffer b;cr_buffer_init(&b);int rc=-1;
    if(name_len&&name_len<=255&&path_len<=4096&&cr_buffer_append_u8(&b,1)==0&&cr_buffer_append_u32(&b,1)==0&&cr_buffer_append_u32(&b,0)==0&&cr_buffer_append_u8(&b,(uint8_t)name_len)==0&&cr_buffer_append(&b,name,name_len)==0&&cr_buffer_append_u32(&b,creator)==0&&cr_buffer_append_u32(&b,file_type)==0&&cr_buffer_append_u32(&b,size)==0&&cr_buffer_append_u32(&b,timestamp)==0&&cr_buffer_append_u16(&b,(uint16_t)path_len)==0&&cr_buffer_append(&b,path,path_len)==0&&cr_transfer_send(stream,b.data,b.len)==0)rc=0;
    cr_buffer_free(&b);return rc;
}
typedef struct cr_index_send_context { cr_transfer_stream *stream; } cr_index_send_context;
static int send_indexed_search_result(void *context,const cr_file_search_index_result *r){cr_index_send_context*c=context;return send_search_result(c->stream,r->name,r->name_len,r->is_folder?CREATOR_FOLDER:0,r->is_folder?FILETYPE_FOLDER:0,r->size,r->timestamp,r->path,r->path_len);}
static int search_index_glob_matches(const char*pattern,const char*name){const char*star=NULL,*retry=NULL;while(*name){if(*pattern=='*'){star=pattern++;retry=name;continue;}if(*pattern=='?'||*pattern==*name){pattern++;name++;continue;}if(star){pattern=star+1;name=++retry;continue;}return 0;}while(*pattern=='*')pattern++;return *pattern=='\0';}
static int search_index_excludes_name(const cr_server*s,const char*name){
    for(size_t i=0;i<s->search_index_exclusions.count;i++)if(search_index_glob_matches(s->search_index_exclusions.patterns[i],name))return 1;
    return 0;
}
typedef struct cr_search_directory_identity { dev_t device; ino_t inode; } cr_search_directory_identity;
typedef struct cr_search_visited { cr_search_directory_identity *items; size_t count; size_t capacity; } cr_search_visited;
static void search_visited_free(cr_search_visited*v){if(!v)return;free(v->items);memset(v,0,sizeof(*v));}
static int search_visited_add(cr_search_visited*v,const struct stat*st){if(!v||!st)return-1;for(size_t i=0;i<v->count;i++)if(v->items[i].device==st->st_dev&&v->items[i].inode==st->st_ino)return 0;if(v->count==v->capacity){size_t next=v->capacity?v->capacity*2:128;cr_search_directory_identity*items=realloc(v->items,next*sizeof(*items));if(!items)return-1;v->items=items;v->capacity=next;}v->items[v->count++]=(cr_search_directory_identity){st->st_dev,st->st_ino};return 1;}

static int search_walk(cr_server *s, cr_transfer_stream *stream, cr_file_metadata_store *metadata,
                       const char *directory, const uint8_t *legacy_parent,
                       size_t parent_len, const char *query,
                       size_t *result_count, cr_search_visited *visited) {
  DIR *d = opendir(directory);
  if (!d)
    return -1;
  struct dirent **entries = NULL;
  size_t count = 0, cap = 0;
  struct dirent *de;
  while ((de = readdir(d))) {
    if (de->d_name[0] == '.' || is_transfer_staging_name(de->d_name) ||
        search_index_excludes_name(s, de->d_name))
      continue;
    if (count == cap) {
      size_t nc = cap ? cap * 2 : 32;
      struct dirent **ne = realloc(entries, nc * sizeof(*ne));
      if (!ne) {
        closedir(d);
        for (size_t i = 0; i < count; i++)
          free(entries[i]);
        free(entries);
        return -1;
      }
      entries = ne;
      cap = nc;
    }
    size_t bytes = offsetof(struct dirent, d_name) + strlen(de->d_name) + 1;
    entries[count] = malloc(bytes);
    if (!entries[count]) {
      closedir(d);
      for (size_t i = 0; i < count; i++)
        free(entries[i]);
      free(entries);
      return -1;
    }
    memcpy(entries[count], de, bytes);
    count++;
  }
  closedir(d);
  for (size_t i = 0; i < count; i++) {
    for (size_t j = i + 1; j < count; j++)
      if (strcasecmp(entries[i]->d_name, entries[j]->d_name) > 0) {
        struct dirent *t = entries[i];
        entries[i] = entries[j];
        entries[j] = t;
      }
  }
  int rc = 0;
  for (size_t i = 0; i < count && !rc; i++) {
    de = entries[i];
    char full[PATH_MAX];
    if (join_path_component(full, sizeof(full), directory, de->d_name))
      continue;
    struct stat st;
    if (stat(full, &st) || (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)))
      continue;
    uint8_t name[512];
    size_t nn = 0;
    if (cr_utf8_to_macroman(de->d_name, name, sizeof(name), &nn) || !nn ||
        nn > 255)
      continue;
    uint8_t path[4096];
    size_t pl = 0;
    if (build_legacy_child(legacy_parent, parent_len, name, nn, path, &pl))
      continue;
    int folder = S_ISDIR(st.st_mode);
    if (ascii_case_contains(de->d_name, query)) {
      uint64_t raw = folder ? 0 : (uint64_t)(st.st_size < 0 ? 0 : st.st_size);
      if (send_search_result(stream, name, nn, folder ? CREATOR_FOLDER : 0,
                             folder ? FILETYPE_FOLDER : 0,
                             raw > UINT32_MAX ? UINT32_MAX : (uint32_t)raw,
                             stat_mac_time(st.st_mtime), path, pl)) {
        rc = -1;
        break;
      }
      (*result_count)++;
      if (*result_count > 100000) {
        rc = -1;
        break;
      }
    }
    if (folder) {
      cr_file_metadata m;
      int found = 0, drop = 0;
      if (!cr_file_metadata_get(metadata, path, pl, &m, &found)) {
        drop = found && ((m.flags & 0x2000u) != 0);
        cr_file_metadata_free(&m);
      }
      if (!drop) {
        int added = search_visited_add(visited, &st);
        if (added < 0) {
          rc = -1;
          break;
        }
        if (added)
          rc = search_walk(s, stream, metadata, full, path, pl, query, result_count,
                           visited);
      }
    }
  }
  for (size_t i = 0; i < count; i++)
    free(entries[i]);
  free(entries);
  return rc;
}
static int serve_file_search(cr_server *s, cr_transfer_stream *stream,
                             cr_session *session) {
  if (!account_perm(session, PERM_SEARCH_FILES) ||
      session->personal == CR_PERSONAL_ROOT)
    return -1;
  uint8_t cb[2];
  if (cr_transfer_read(stream, cb, 2))
    return -1;
  uint16_t clauses = cr_read_be16(cb);
  if (!clauses || clauses > 64)
    return -1;
  char query[1024] = "";
  int found_query = 0;
  for (uint16_t i = 0; i < clauses; i++) {
    uint8_t h[7];
    if (cr_transfer_read(stream, h, 7))
      return -1;
    uint32_t n = cr_read_be32(h + 3);
    if (n > 255)
      return -1;
    uint8_t data[255];
    if (n && cr_transfer_read(stream, data, n))
      return -1;
    if (!found_query && h[0] == 1 && h[1] == 1 && n) {
      if (cr_macroman_to_utf8(data, n, query, sizeof(query)))
        return -1;
      found_query = 1;
    }
  }
  if (!found_query)
    return -1;
  uint8_t ack[4] = {0};
  if (cr_transfer_send(stream, ack, 4))
    return -1;
  char search_root[PATH_MAX];
  if (session_files_root(s, session, search_root, sizeof(search_root))) return -1;
  size_t results = 0;
  int search_rc = -1;
  int scoped_root = session->files_root_path[0] || session_uses_legacy_files_root(s,session);
  if (s->file_index_ready && !scoped_root) {
    cr_index_send_context ctx = {stream};
    search_rc = cr_file_search_index_search(
        &s->file_index, query, &s->search_index_exclusions,
        send_indexed_search_result, &ctx, &results);
    if (search_rc)
      log_msg("Indexed file search failed; using filesystem fallback");
  }
  if (!s->file_index_ready || scoped_root || search_rc) {
    results = 0;
    cr_search_visited visited = {0};
    struct stat root_st;
    if (stat(search_root, &root_st) == 0 &&
        S_ISDIR(root_st.st_mode) &&
        search_visited_add(&visited, &root_st) < 0) {
      search_visited_free(&visited);
      return -1;
    }
    int walk_rc = search_walk(s, stream, session_metadata_store(s,session), search_root, NULL, 0, query,
                              &results, &visited);
    search_visited_free(&visited);
    if (walk_rc)
      return -1;
  }
  uint8_t done[5] = {1, 0, 0, 0, 0};
  if (cr_transfer_send(stream, done, sizeof(done)))
    return -1;
  log_msg("File search for user %u: %s — %zu result(s)%s", session->user_id,
          query, results,
          s->file_index_ready && !scoped_root && search_rc == 0 ? " [index]" : " [walk]");
  return 0;
}

static int ensure_directory_tree(const char *path){char tmp[PATH_MAX];if(strlen(path)+1>sizeof(tmp))return-1;strcpy(tmp,path);for(char*p=tmp+1;*p;p++){if(*p=='/'){*p='\0';if(mkdir(tmp,0755)&&errno!=EEXIST)return-1;*p='/';}}return mkdir(tmp,0755)==0||errno==EEXIST?0:-1;}

typedef struct cr_transfer_entry {
    uint8_t relative[4096]; size_t relative_len;
    uint8_t server_path[4096]; size_t server_path_len;
    char fs_path[PATH_MAX]; int is_folder; uint64_t size;
} cr_transfer_entry;
typedef struct cr_transfer_entries { cr_transfer_entry *items; size_t count,cap; } cr_transfer_entries;
static void transfer_entries_free(cr_transfer_entries*v){free(v->items);memset(v,0,sizeof(*v));}
static int transfer_entries_add(cr_transfer_entries*v,const cr_transfer_entry*e){if(v->count==v->cap){size_t nc=v->cap?v->cap*2:32;cr_transfer_entry*n=realloc(v->items,nc*sizeof(*n));if(!n)return-1;v->items=n;v->cap=nc;}v->items[v->count++]=*e;return 0;}
static int make_transfer_entry(cr_transfer_entry*e,const uint8_t*relative,size_t rl,const uint8_t*server_path,size_t sl,const char*fs,int folder,uint64_t size){if(rl>sizeof(e->relative)||sl>sizeof(e->server_path)||strlen(fs)+1>sizeof(e->fs_path))return-1;memset(e,0,sizeof(*e));memcpy(e->relative,relative,rl);e->relative_len=rl;memcpy(e->server_path,server_path,sl);e->server_path_len=sl;strcpy(e->fs_path,fs);e->is_folder=folder;e->size=size;return 0;}
static int download_walk(cr_server*s,cr_session*session,const char*dir,const uint8_t*relative,size_t rl,const uint8_t*server_path,size_t sl,unsigned depth,unsigned max_depth,cr_transfer_entries*v){if(depth>max_depth)return 0;DIR*d=opendir(dir);if(!d)return-1;char**names=NULL;size_t count=0,cap=0;struct dirent*de;while((de=readdir(d))){if(de->d_name[0]=='.'||is_transfer_staging_name(de->d_name))continue;if(count==cap){size_t nc=cap?cap*2:32;char**n=realloc(names,nc*sizeof(*n));if(!n){closedir(d);goto fail;}names=n;cap=nc;}names[count]=strdup(de->d_name);if(!names[count]){closedir(d);goto fail;}count++;}closedir(d);for(size_t i=0;i<count;i++)for(size_t j=i+1;j<count;j++)if(strcasecmp(names[i],names[j])>0){char*t=names[i];names[i]=names[j];names[j]=t;}for(size_t i=0;i<count;i++){uint8_t wn[512];size_t wnl=0;if(cr_utf8_to_macroman(names[i],wn,sizeof(wn),&wnl)||!wnl||wnl>255)continue;cr_transfer_entry e;uint8_t rel[4096],sp[4096];size_t rlen=0,slen=0;if(build_legacy_child(relative,rl,wn,wnl,rel,&rlen)||build_legacy_child(server_path,sl,wn,wnl,sp,&slen))continue;char fs[PATH_MAX];if(resolve_legacy_path_ex(s,session,sp,slen,fs,sizeof(fs),1))continue;struct stat st;if(stat(fs,&st)||(!S_ISDIR(st.st_mode)&&!S_ISREG(st.st_mode)))continue;int folder=S_ISDIR(st.st_mode);uint64_t size=folder?0:(uint64_t)(st.st_size<0?0:st.st_size);if(make_transfer_entry(&e,rel,rlen,sp,slen,fs,folder,size)||transfer_entries_add(v,&e))goto fail;if(folder&&depth<max_depth){int drop=path_is_inside_dropbox(s,session,sp,slen);if(!drop||account_perm(session,PERM_VIEW_DROPBOXES)){if(download_walk(s,session,fs,rel,rlen,sp,slen,depth+1,max_depth,v))goto fail;}}}for(size_t i=0;i<count;i++)free(names[i]);free(names);return 0;fail:if(names){for(size_t i=0;i<count;i++)free(names[i]);free(names);}return-1;}
static int collect_download_entries(cr_server*s,cr_session*session,const uint8_t*remote,size_t remote_len,const char*rootfs,cr_transfer_entries*v,uint64_t*total){const uint8_t*leaf=NULL;size_t ll=0;if(legacy_leaf(remote,remote_len,&leaf,&ll))return-1;struct stat st;int folder=0;if(resource_kind(rootfs,&folder,NULL,&st))return-1;cr_transfer_entry root;if(make_transfer_entry(&root,leaf,ll,remote,remote_len,rootfs,folder,folder?0:(uint64_t)(st.st_size<0?0:st.st_size))||transfer_entries_add(v,&root))return-1;*total=root.size;if(folder){uint16_t configured=0;pthread_mutex_lock(&s->state.mutex);configured=s->state.advanced.max_folder_download_depth;pthread_mutex_unlock(&s->state.mutex);unsigned maxdepth=configured?(unsigned)configured:UINT_MAX;if(download_walk(s,session,rootfs,leaf,ll,remote,remote_len,1,maxdepth,v))return-1;for(size_t i=1;i<v->count;i++)if(!v->items[i].is_folder){uint64_t next=*total+v->items[i].size;if(next<*total)return-1;*total=next;}}return v->count>UINT32_MAX?-1:0;}
static int send_transfer_entry_header(cr_transfer_stream*stream,const cr_transfer_entry*e){
    cr_buffer b;cr_buffer_init(&b);int rc=-1;
    if(cr_buffer_append_string16(&b,e->relative,e->relative_len)==0&&
       cr_buffer_append_u32(&b,e->is_folder?FILETYPE_FOLDER:0)==0&&
       cr_buffer_append_u32(&b,e->is_folder?CREATOR_FOLDER:0)==0&&
       cr_buffer_append_u16(&b,e->is_folder?DIR_FLAG_FOLDER:0)==0){
        uint8_t finder[16]={0};
        if(cr_buffer_append(&b,finder,sizeof(finder))==0){
            if(e->is_folder){if(cr_buffer_append_u32(&b,0)==0&&cr_transfer_send(stream,b.data,b.len)==0)rc=0;}
            else if(cr_buffer_append_u32(&b,8)==0&&cr_buffer_append_u64(&b,e->size)==0&&cr_transfer_send(stream,b.data,b.len)==0)rc=0;
        }
    }
    cr_buffer_free(&b);return rc;
}
static int serve_download(cr_server*s,cr_transfer_stream*stream,cr_session*session,uint32_t transfer_id){cr_buffer remote;cr_buffer_init(&remote);cr_transfer_entries entries={0};int rc=-1;if(cr_transfer_read_string16(stream,&remote,4096)||!remote.len)goto done;configure_transfer(s,transfer_id,remote.data,remote.len,0);if(!account_perm(session,PERM_VIEW_DROPBOXES)&&path_is_inside_dropbox(s,session,remote.data,remote.len))goto done;char rootfs[PATH_MAX];if(resolve_legacy_path_ex(s,session,remote.data,remote.len,rootfs,sizeof(rootfs),1))goto done;uint64_t total=0;if(collect_download_entries(s,session,remote.data,remote.len,rootfs,&entries,&total)||!entries.count)goto done;configure_transfer(s,transfer_id,remote.data,remote.len,total);configure_transfer_directory(s,transfer_id,entries.items[0].is_folder);uint8_t q[4];cr_write_be32(q,0);if(cr_transfer_send(stream,q,4))goto done;uint8_t env[12];cr_write_be64(env,total);cr_write_be32(env+8,(uint32_t)entries.count);if(cr_transfer_send(stream,env,12))goto done;uint8_t io[256*1024];for(size_t i=0;i<entries.count;i++){cr_transfer_entry*e=&entries.items[i];if(transfer_wait_until_resumed(s,transfer_id))goto done;if(send_transfer_entry_header(stream,e))goto done;if(e->is_folder)continue;uint64_t resume=0;if(transfer_wait_until_resumed(s,transfer_id)||cr_transfer_read_u64(stream,&resume)||resume>e->size)goto done;add_transfer_resume_progress(s,transfer_id,resume);uint64_t remaining=e->size-resume;uint8_t lenbuf[8];cr_write_be64(lenbuf,remaining);if(cr_transfer_send(stream,lenbuf,8))goto done;int f=open(e->fs_path,O_RDONLY);if(f<0)goto done;if(lseek(f,(off_t)resume,SEEK_SET)<0){close(f);goto done;}uint64_t left=remaining;while(left){if(transfer_wait_until_resumed(s,transfer_id)){close(f);goto done;}size_t cap=paced_download_chunk_size(s,sizeof(io));size_t want=left>cap?cap:(size_t)left;ssize_t n=read(f,io,want);if(n<0){if(errno==EINTR)continue;close(f);goto done;}if(n==0){close(f);goto done;}throttle_download(s,transfer_id,(size_t)n);if(cr_transfer_send(stream,io,(size_t)n)){close(f);goto done;}left-=(uint64_t)n;add_transfer_progress(s,transfer_id,(uint64_t)n);}close(f);uint8_t comment[2]={0};if(cr_transfer_send(stream,comment,2))goto done;}log_msg("Download completed for user %u",session->user_id);rc=0;done:transfer_entries_free(&entries);cr_buffer_free(&remote);return rc;}
static int upload_relative_inside_stage(const char*stage,const uint8_t*relative,size_t len,const char*expected_root,char*out,size_t cap){
    if(!len||len>4096||strlen(stage)+1>cap)return-1;
    strcpy(out,stage);size_t pos=0,component_index=0;
    while(pos<len){
        size_t st=pos;while(pos<len&&relative[pos]!=1)pos++;size_t n=pos-st;if(!n||n>255)return-1;
        char comp[1024];if(cr_macroman_to_utf8(relative+st,n,comp,sizeof(comp))||!safe_component(comp))return-1;
        if(component_index==0){if(strcmp(comp,expected_root))return-1;}
        else {size_t have=strlen(out),cn=strlen(comp);if(have+1+cn+1>cap)return-1;out[have]='/';memcpy(out+have+1,comp,cn+1);}
        component_index++;if(pos<len)pos++;
    }
    return component_index?0:-1;
}
static int partial_path_for_final(const char*final,char*out,size_t cap){
    int n=snprintf(out,cap,"%s.carracho",final);if(n<0||(size_t)n>=cap)return-1;
    struct stat st;if(lstat(out,&st)&&errno==ENOENT){const char*leaf=strrchr(final,'/');if(!leaf||!leaf[1])return-1;size_t parent=(size_t)(leaf-final);char legacy[PATH_MAX];int m=snprintf(legacy,sizeof(legacy),"%.*s/.carracho.%s",(int)parent,final,leaf+1);if(m<0||(size_t)m>=sizeof(legacy))return-1;if(lstat(legacy,&st)==0&&rename(legacy,out))return-1;}
    return 0;
}
static int regular_file_size(const char*path,uint64_t*out){struct stat st;if(lstat(path,&st)||S_ISLNK(st.st_mode)||!S_ISREG(st.st_mode)||st.st_size<0)return-1;*out=(uint64_t)st.st_size;return 0;}
static int prepare_upload_partial(const char*path,int has_expected,uint64_t expected,uint64_t*resume){
    struct stat st;if(lstat(path,&st)==0){uint64_t size=0;if(S_ISLNK(st.st_mode)||!S_ISREG(st.st_mode)||st.st_size<0){if(recursive_remove_path(path))return-1;}else{size=(uint64_t)st.st_size;if(!has_expected||size<=expected){*resume=size;return 0;}if(unlink(path))return-1;}}
    else if(errno!=ENOENT)return-1;
    int f=open(path,O_CREAT|O_EXCL|O_WRONLY,0644);if(f<0)return-1;if(close(f))return-1;*resume=0;return 0;
}
static int ensure_stage_directory(const char*path){
    struct stat st;if(lstat(path,&st)==0){if(!S_ISLNK(st.st_mode)&&S_ISDIR(st.st_mode))return 0;if(recursive_remove_path(path))return-1;}else if(errno!=ENOENT)return-1;
    return mkdir(path,0755)==0?0:-1;
}
static int read_upload_entry(cr_transfer_stream *stream, cr_buffer *relative,
                             int *folder, uint64_t *declared_size,
                             int *has_declared_size, int modern_extensions) {
  if (cr_transfer_read_string16(stream, relative, 4096) || !relative->len)
    return -1;
  uint8_t fixed[30];
  if (cr_transfer_read(stream, fixed, sizeof(fixed)))
    return -1;
  uint32_t type = cr_read_be32(fixed), creator = cr_read_be32(fixed + 4),
           extra = cr_read_be32(fixed + 26);
  if (extra > 4096)
    return -1;
  *folder = (type == FILETYPE_FOLDER && creator == CREATOR_FOLDER);
  *has_declared_size = 0;
  *declared_size = 0;
  if (extra) {
    uint8_t *x = malloc(extra);
    if (!x)
      return -1;
    int rc = cr_transfer_read(stream, x, extra);
    if (!rc && modern_extensions && !*folder && extra >= 8) {
      *declared_size = cr_read_be64(x);
      *has_declared_size = 1;
    }
    free(x);
    if (rc)
      return -1;
  }
  return 0;
}
static int rename_upload_noreplace(const char *source, const char *destination) {
#if defined(__linux__) && defined(SYS_renameat2)
    /* Linux production path: the no-replace guarantee is atomic, so two simultaneous uploads
       can never race into silently replacing one another. */
    return syscall(SYS_renameat2, AT_FDCWD, source, AT_FDCWD, destination, RENAME_NOREPLACE) == 0 ? 0 : -1;
#else
    /* Native macOS test builds do not have renameat2. Keep the same behavior as closely as the
       host permits; Debian/Linux uses the atomic branch above. */
    struct stat st;
    if (lstat(destination, &st) == 0) { errno = EEXIST; return -1; }
    if (errno != ENOENT) return -1;
    return rename(source, destination);
#endif
}

static int serve_upload(cr_server*s,cr_transfer_stream*stream,cr_session*session,uint32_t transfer_id){
    cr_buffer parent,target,relative;cr_buffer_init(&parent);cr_buffer_init(&target);cr_buffer_init(&relative);int rc=-1,committed=0;char stage[PATH_MAX]="";
    if(cr_transfer_read_string16(stream,&parent,4096)||cr_transfer_read_string16(stream,&target,4096)||!target.len)goto done;
    size_t parent_len=legacy_parent_length(target.data,target.len);
    if(parent_len!=parent.len||(parent_len&&memcmp(target.data,parent.data,parent_len))){
        /* The original Classic client sends the destination directory first and only the
           uploaded leaf name second. Modern Carracho sends the complete target path. Accept
           both forms, but only normalize a single Classic leaf so traversal cannot sneak in. */
        if(session->modern_transport||!parent.len||memchr(target.data,1,target.len))goto done;
        uint8_t full_target[4096];size_t full_target_len=0;
        if(build_legacy_child(parent.data,parent.len,target.data,target.len,full_target,&full_target_len))goto done;
        target.len=0;if(cr_buffer_append(&target,full_target,full_target_len))goto done;
        parent_len=legacy_parent_length(target.data,target.len);
        if(parent_len!=parent.len||(parent_len&&memcmp(target.data,parent.data,parent_len)))goto done;
    }
    configure_transfer(s,transfer_id,target.data,target.len,0);
    if(!account_perm(session,PERM_UPLOAD_ANYWHERE)&&!path_is_upload_folder(s,session,parent.data,parent.len))goto done;
    char parentfs[PATH_MAX],targetfs[PATH_MAX];int parent_folder=0;if(resolve_legacy_path_ex(s,session,parent.data,parent.len,parentfs,sizeof(parentfs),1)||resource_kind(parentfs,&parent_folder,NULL,NULL)||!parent_folder||resolve_legacy_path_ex(s,session,target.data,target.len,targetfs,sizeof(targetfs),0))goto done;
    struct stat target_st;int exists=lstat(targetfs,&target_st)==0;
    if(exists){uint8_t st=1;if(cr_transfer_send(stream,&st,1))goto done;rc=0;goto done;}
    uint8_t status=0;if(cr_transfer_send(stream,&status,1))goto done;uint8_t overwrite=0;if(cr_transfer_read_u8(stream,&overwrite)||overwrite!=0)goto done;
    uint64_t total=0;uint32_t count=0;if(cr_transfer_read_u64(stream,&total)||cr_transfer_read_u32(stream,&count)||!count||count>1000000||total>(1ULL<<50))goto done;configure_transfer(s,transfer_id,target.data,target.len,total);
    const uint8_t*target_leaf=NULL;size_t target_leaf_len=0;if(legacy_leaf(target.data,target.len,&target_leaf,&target_leaf_len))goto done;char expected_root[1024];if(cr_macroman_to_utf8(target_leaf,target_leaf_len,expected_root,sizeof(expected_root))||!safe_component(expected_root))goto done;
    if(snprintf(stage,sizeof(stage),"%s/%s.carracho",parentfs,expected_root)>=(int)sizeof(stage))goto done;
    {struct stat st;if(lstat(stage,&st)&&errno==ENOENT){char legacy_stage[PATH_MAX];if(snprintf(legacy_stage,sizeof(legacy_stage),"%s/.carracho.%s",parentfs,expected_root)>=(int)sizeof(legacy_stage))goto done;if(lstat(legacy_stage,&st)==0&&rename(legacy_stage,stage))goto done;}}
    int root_kind=-1;uint64_t accounted=0;
    for(uint32_t i=0;i<count;i++){
        if(transfer_wait_until_resumed(s,transfer_id))goto done;
        relative.len=0;int folder=0,has_declared=0;uint64_t declared=0;if(read_upload_entry(stream,&relative,&folder,&declared,&has_declared,session->modern_transport))goto done;
        if(i==0){for(size_t k=0;k<relative.len;k++)if(relative.data[k]==1)goto done;root_kind=folder?1:0;configure_transfer_directory(s,transfer_id,folder);}else if(root_kind!=1)goto done;
        char local[PATH_MAX];if(upload_relative_inside_stage(stage,relative.data,relative.len,expected_root,local,sizeof(local)))goto done;
        if(folder){if(ensure_stage_directory(local))goto done;continue;}
        char parentdir[PATH_MAX];if(strlen(local)+1>sizeof(parentdir))goto done;strcpy(parentdir,local);char*slash=strrchr(parentdir,'/');if(!slash)goto done;*slash='\0';if(ensure_directory_tree(parentdir))goto done;
        char write_path[PATH_MAX];uint64_t resume=0;
        if(i==0){if(strlen(stage)+1>sizeof(write_path))goto done;strcpy(write_path,stage);if(prepare_upload_partial(write_path,has_declared,declared,&resume))goto done;}
        else {
            int use_complete=0;if(has_declared){uint64_t complete_size=0;if(regular_file_size(local,&complete_size)==0){if(complete_size==declared){if(strlen(local)+1>sizeof(write_path))goto done;strcpy(write_path,local);resume=declared;use_complete=1;}else if(unlink(local))goto done;}}
            if(!use_complete){if(partial_path_for_final(local,write_path,sizeof(write_path))||prepare_upload_partial(write_path,has_declared,declared,&resume))goto done;}
        }
        int classic_fork_wire=!session->modern_transport;
        uint8_t resumebuf[16]={0};cr_write_be64(resumebuf,resume);if(classic_fork_wire)cr_write_be64(resumebuf+8,0);if(cr_transfer_send(stream,resumebuf,classic_fork_wire?16:8))goto done;add_transfer_resume_progress(s,transfer_id,resume);
        uint64_t length=0,resource_length=0;if(cr_transfer_read_u64(stream,&length)||(classic_fork_wire&&cr_transfer_read_u64(stream,&resource_length)))goto done;uint64_t full=resume+length;if(full<resume||(has_declared&&full!=declared))goto done;uint64_t fork_total=full+resource_length;if(fork_total<full||fork_total>total||accounted>total-fork_total)goto done;accounted+=fork_total;
        int f=open(write_path,O_WRONLY);if(f<0)goto done;if(lseek(f,(off_t)resume,SEEK_SET)<0){close(f);goto done;}uint64_t left=length;uint8_t io[256*1024];
        while(left){if(transfer_wait_until_resumed(s,transfer_id)){close(f);goto done;}size_t want=left>sizeof(io)?sizeof(io):(size_t)left;if(cr_transfer_read(stream,io,want)){close(f);goto done;}size_t off=0;while(off<want){ssize_t n=write(f,io+off,want-off);if(n<0){if(errno==EINTR)continue;close(f);goto done;}off+=(size_t)n;}left-=want;add_transfer_progress(s,transfer_id,want);}if(close(f))goto done;
        /* Classic operation 11 negotiates Macintosh data and resource forks separately. The
           portable server stores the data fork and consumes/discards the resource fork so the
           original client can complete the upload instead of waiting forever at 0 bytes. */
        left=resource_length;while(left){if(transfer_wait_until_resumed(s,transfer_id))goto done;size_t want=left>sizeof(io)?sizeof(io):(size_t)left;if(cr_transfer_read(stream,io,want))goto done;left-=want;add_transfer_progress(s,transfer_id,want);}
        uint16_t comment_len=0;if(cr_transfer_read_u16(stream,&comment_len)||comment_len>4096)goto done;if(comment_len){uint8_t*comment=malloc(comment_len);if(!comment||cr_transfer_read(stream,comment,comment_len)){free(comment);goto done;}free(comment);}
        uint64_t actual=0;if(regular_file_size(write_path,&actual)||actual!=full)goto done;if(i>0&&strcmp(write_path,local)){if(unlink(local)&&errno!=ENOENT)goto done;if(rename(write_path,local))goto done;}
    }
    if(accounted!=total||root_kind<0||lstat(stage,&target_st))goto done;
    if(rename_upload_noreplace(stage,targetfs))goto done;
    committed=1;
    if(file_search_index_incremental_available(s)&&!session_uses_legacy_files_root(s,session)&&!session->files_root_path[0]&&cr_file_search_index_upsert_subtree(&s->file_index,targetfs,target.data,target.len,&s->metadata,&s->search_index_exclusions)){
        log_msg("File-search index upload update failed");
        invalidate_file_search_index(s,"incremental upload failure");
    }
    log_msg("Upload completed for user %u",session->user_id);
    rc=0;
done:cr_buffer_free(&relative);cr_buffer_free(&parent);cr_buffer_free(&target);return committed?0:(rc==0?1:-1);
}

static int transfer_read_string16_alloc(cr_transfer_stream*stream,uint8_t**out,size_t*out_len,size_t max){uint8_t lb[2];if(cr_transfer_read(stream,lb,2))return-1;uint16_t n=cr_read_be16(lb);if(n>max)return-1;uint8_t*p=malloc(n+1);if(!p)return-1;if(n&&cr_transfer_read(stream,p,n)){free(p);return-1;}p[n]=0;*out=p;*out_len=n;return 0;}
static int serve_media_upload(cr_server*s,cr_transfer_stream*stream,cr_session*session){
    uint8_t version=0;if(cr_transfer_read(stream,&version,1)||version!=1)return-1;uint8_t*name=NULL;size_t nn=0;if(transfer_read_string16_alloc(stream,&name,&nn,1024)||!nn)return-1;uint8_t lb[4];if(cr_transfer_read(stream,lb,4)){free(name);return-1;}uint32_t len=cr_read_be32(lb);if(!len||len>CR_MEDIA_MAX_BYTES){free(name);return-1;}uint8_t*data=malloc(len);if(!data){free(name);return-1;}if(cr_transfer_read(stream,data,len)){free(name);free(data);return-1;}char id[37];int rc=cr_media_store_pending(&s->media,session->account_id,(const char*)name,data,len,id);free(name);free(data);if(rc)return-1;uint8_t out[38];cr_write_be16(out,36);memcpy(out+2,id,36);if(cr_transfer_send(stream,out,sizeof(out)))return-1;(void)cr_media_store_cleanup(&s->media,time(NULL));log_msg("Media image uploaded by user %u: %s, %u byte(s)",session->user_id,id,len);return 0;
}
static void broadcast_media_deleted(cr_server*s,const char*id){
    cr_tlv_out f={1,(const uint8_t*)id,36};
    pthread_mutex_lock(&s->mutex);
    for(size_t i=0;i<s->allocated_session_count;i++){
        cr_session*x=s->sessions[i];
        if(x&&x->modern_transport&&session_ready_for_async(x))session_send(x,CMD_MEDIA_DELETED,0,&f,1);
    }
    pthread_mutex_unlock(&s->mutex);
}
static int serve_media_delete(cr_server*s,cr_transfer_stream*stream,cr_session*session){
    uint8_t version=0;
    if(cr_transfer_read(stream,&version,1)||version!=1)return-1;
    uint8_t*idw=NULL;size_t in=0;
    if(transfer_read_string16_alloc(stream,&idw,&in,36))return-1;
    if(in!=36||!media_uuid_text_valid((const char*)idw)){
        free(idw);uint8_t no=0;return cr_transfer_send(stream,&no,1);
    }
    char id[37];memcpy(id,idw,36);id[36]='\0';free(idw);
    int result=cr_media_store_delete_owned(&s->media,id,session->account_id);
    if(result<0)return-1;
    uint8_t status=result==0?1:0;
    if(cr_transfer_send(stream,&status,1))return-1;
    if(result==0){broadcast_media_deleted(s,id);log_msg("Media image deleted by user %u: %s",session->user_id,id);}
    return 0;
}

static int serve_media_download(cr_server*s,cr_transfer_stream*stream,cr_session*session){
    uint8_t h[2];if(cr_transfer_read(stream,h,2)||h[0]!=1)return-1;uint8_t kind=h[1];uint8_t*scope=NULL,*idw=NULL;size_t sn=0,in=0;if(transfer_read_string16_alloc(stream,&scope,&sn,4096)||transfer_read_string16_alloc(stream,&idw,&in,36)){free(scope);free(idw);return-1;}if(in!=36||!media_uuid_text_valid((const char*)idw)){free(scope);free(idw);uint8_t no=0;return cr_transfer_send(stream,&no,1);}char id[37];memcpy(id,idw,36);id[36]='\0';free(idw);int allowed=cr_media_store_is_owned(&s->media,id,session->account_id);
    if(!allowed&&kind==CR_MEDIA_KIND_CHAT&&sn==4){uint32_t cid=cr_read_be32(scope);char key[32];snprintf(key,sizeof(key),"%u",cid);pthread_mutex_lock(&s->mutex);cr_channel*c=channel_by_id_locked(s,cid);int member=c&&channel_member_index(c,session->user_id)>=0;pthread_mutex_unlock(&s->mutex);allowed=member&&cr_media_store_has_ref(&s->media,id,CR_MEDIA_KIND_CHAT,key);}
    else if(!allowed&&kind==CR_MEDIA_KIND_NEWS&&sn){cr_newsgroup g;if(!lookup_newsgroup(s,scope,sn,&g)&&group_can_read(&g,session->mode))allowed=cr_media_store_has_ref(&s->media,id,CR_MEDIA_KIND_NEWS,g.id);}
    free(scope);if(!allowed){uint8_t no=0;return cr_transfer_send(stream,&no,1);}cr_media_object o;if(cr_media_store_load(&s->media,id,&o))return-1;size_t mn=strlen(o.mime_type),fn=strlen(o.filename);if(mn>UINT16_MAX||fn>UINT16_MAX||o.data_len>UINT32_MAX||o.width>UINT16_MAX||o.height>UINT16_MAX){cr_media_object_free(&o);return-1;}cr_buffer b;cr_buffer_init(&b);int fail=cr_buffer_append_u8(&b,1)||cr_buffer_append_string16(&b,o.mime_type,mn)||cr_buffer_append_string16(&b,o.filename,fn)||cr_buffer_append_u16(&b,(uint16_t)o.width)||cr_buffer_append_u16(&b,(uint16_t)o.height)||cr_buffer_append_u32(&b,(uint32_t)o.data_len)||cr_buffer_append(&b,o.data,o.data_len);cr_media_object_free(&o);int rc=fail?-1:cr_transfer_send(stream,b.data,b.len);cr_buffer_free(&b);return rc;
}

static int serve_article_post(cr_server*s,cr_transfer_stream*stream,cr_session*session){
    uint8_t lenbuf[4];if(cr_transfer_read(stream,lenbuf,4))return-1;uint32_t length=cr_read_be32(lenbuf);if(!length||length>0x40000)return-1;
    uint8_t*payload=malloc(length);if(!payload)return-1;if(cr_transfer_read(stream,payload,length)){free(payload);return-1;}
    size_t pos=0;if(pos+2>length){free(payload);return-1;}uint16_t gl=cr_read_be16(payload+pos);pos+=2;if(!gl||gl>64||pos+gl+2>length){free(payload);return-1;}const uint8_t*group=payload+pos;pos+=gl;
    uint16_t sl=cr_read_be16(payload+pos);pos+=2;if(!sl||pos+sl+16>length){free(payload);return-1;}const uint8_t*subject=payload+pos;pos+=sl;
    uint32_t incoming_id=cr_read_be32(payload+pos);pos+=4;uint32_t reserved=cr_read_be32(payload+pos);pos+=4;uint32_t text_len=cr_read_be32(payload+pos);pos+=4;uint32_t style_len=cr_read_be32(payload+pos);pos+=4;
    if((uint64_t)pos+text_len+style_len!=length||text_len>0x40000||style_len>0x40000||reserved==0){free(payload);return-1;}
    cr_newsgroup g;if(lookup_newsgroup(s,group,gl,&g)){free(payload);return-1;}int can_moderate=account_perm(session,PERM_MANAGE_NEWSGROUPS);if(!incoming_id){int may_post=session->modern_transport?(account_perm(session,PERM_POST_NEWS)&&group_can_read(&g,session->mode)):group_can_post(&g,session->mode);if(!may_post){free(payload);return-1;}}
    uint8_t sender[512];size_t sender_len=0;if(session->nickname_len){if(session->nickname_len>sizeof(sender)){free(payload);return-1;}memcpy(sender,session->nickname,session->nickname_len);sender_len=session->nickname_len;}else if(cr_utf8_to_macroman(session->login,sender,sizeof(sender),&sender_len)){free(payload);return-1;}
    if(validate_youtube_tokens(payload+pos,text_len,10)){free(payload);return-1;}
    char media_ids[10][37];size_t media_count=0;if(extract_media_ids(payload+pos,text_len,media_ids,10,&media_count)){free(payload);return-1;}
    if(incoming_id){
        cr_buffer existing_meta,existing_body;cr_buffer_init(&existing_meta);cr_buffer_init(&existing_body);int read_rc=cr_news_reply(&s->news,g.id,group,gl,incoming_id,&existing_meta,&existing_body);cr_buffer_free(&existing_meta);if(read_rc||existing_body.len<16){cr_buffer_free(&existing_body);free(payload);return-1;}uint32_t existing_text_len=cr_read_be32(existing_body.data+8),existing_style_len=cr_read_be32(existing_body.data+12);if((uint64_t)16+existing_text_len+existing_style_len!=existing_body.len){cr_buffer_free(&existing_body);free(payload);return-1;}char old_media_ids[10][37];size_t old_media_count=0;if(extract_media_ids(existing_body.data+16,existing_text_len,old_media_ids,10,&old_media_count)){cr_buffer_free(&existing_body);free(payload);return-1;}for(size_t i=0;i<media_count;i++){int found=0;for(size_t j=0;j<old_media_count;j++)if(!strcasecmp(media_ids[i],old_media_ids[j])){found=1;break;}if(!found){cr_buffer_free(&existing_body);free(payload);return-1;}}cr_buffer_free(&existing_body);
        int rc=cr_news_update_owned(&s->news,g.id,incoming_id,session->account_id,can_moderate,subject,sl,payload+pos,text_len,payload+pos+text_len,style_len);free(payload);if(rc)return-1;
        char message_id[32];snprintf(message_id,sizeof(message_id),"%u",incoming_id);size_t removed_count=0;
        for(size_t i=0;i<old_media_count;i++){int kept=0;for(size_t j=0;j<media_count;j++)if(!strcasecmp(old_media_ids[i],media_ids[j])){kept=1;break;}if(kept)continue;int object_deleted=0;if(cr_media_store_remove_ref(&s->media,old_media_ids[i],CR_MEDIA_KIND_NEWS,g.id,message_id,&object_deleted))return-1;if(object_deleted)broadcast_media_deleted(s,old_media_ids[i]);removed_count++;}
        log_msg("Article %u edited in %s by user %u; removed %zu media attachment(s)",incoming_id,g.name,session->user_id,removed_count);if(session->modern_transport){uint8_t ack=1;if(cr_transfer_send(stream,&ack,1))return-1;}return 0;
    }
    for(size_t mi=0;mi<media_count;mi++)if(!cr_media_store_is_owned(&s->media,media_ids[mi],session->account_id)){free(payload);return-1;}
    time_t now=time(NULL);uint64_t classic=(uint64_t)(now<0?0:now)+MAC_EPOCH_OFFSET;if(classic>UINT32_MAX)classic=UINT32_MAX;uint32_t aid=0;
    int rc=cr_news_post(&s->news,g.id,subject,sl,sender,sender_len,(uint32_t)classic,payload+pos,text_len,payload+pos+text_len,style_len,reserved,session->account_id,&aid);free(payload);if(rc)return-1;
    char message_id[32];snprintf(message_id,sizeof(message_id),"%u",aid);for(size_t mi=0;mi<media_count;mi++)if(cr_media_store_bind(&s->media,media_ids[mi],session->account_id,CR_MEDIA_KIND_NEWS,g.id,message_id,0)){int deleted=0;(void)cr_news_delete(&s->news,g.id,aid,&deleted);return-1;}
    uint32_t count=0;if(cr_news_count(&s->news,g.id,&count)||cr_state_set_newsgroup_article_count(&s->state,g.id,count))return-1;
    log_msg("Article %u posted to %s by user %u",aid,g.name,session->user_id);if(session->modern_transport){uint8_t ack=1;if(cr_transfer_send(stream,&ack,1))return-1;}return 0;
}
static int serve_news_index(cr_server*s,cr_transfer_stream*stream,cr_session*session){
    uint8_t lb[2];if(cr_transfer_read(stream,lb,2))return-1;uint16_t gl=cr_read_be16(lb);if(gl>64)return-1;uint8_t group[64];if(gl&&cr_transfer_read(stream,group,gl))return-1;
    cr_newsgroup g;if(!gl||lookup_newsgroup(s,group,gl,&g)||!group_can_read(&g,session->mode)){uint8_t none[4];cr_write_be32(none,UINT32_MAX);return cr_transfer_send(stream,none,4);}
    cr_buffer index;cr_buffer_init(&index);int rc=-1;if(cr_news_index(&s->news,g.id,group,gl,&index))goto done;if(index.len>UINT32_MAX)goto done;cr_buffer wire;cr_buffer_init(&wire);if(cr_buffer_append_u32(&wire,(uint32_t)index.len)||cr_buffer_append(&wire,index.data,index.len)){cr_buffer_free(&wire);goto done;}if(cr_transfer_send(stream,wire.data,wire.len)){cr_buffer_free(&wire);goto done;}cr_buffer_free(&wire);log_msg("News index served for user %u: %s",session->user_id,g.name);rc=0;done:cr_buffer_free(&index);return rc;
}

static int transfer_fd_register(cr_server *s, int fd) {
    pthread_mutex_lock(&s->mutex);
    size_t slot = CR_SERVER_MAX_TRANSFER_CONNECTIONS;
    for (size_t i=0;i<CR_SERVER_MAX_TRANSFER_CONNECTIONS;i++) if (s->transfer_fds[i] < 0) { slot=i; break; }
    if (slot == CR_SERVER_MAX_TRANSFER_CONNECTIONS) { pthread_mutex_unlock(&s->mutex); return -1; }
    s->transfer_fds[slot]=fd; s->active_transfer_connections++;
    pthread_mutex_unlock(&s->mutex); return 0;
}
static void transfer_fd_unregister(cr_server *s, int fd) {
    pthread_mutex_lock(&s->mutex);
    for (size_t i=0;i<CR_SERVER_MAX_TRANSFER_CONNECTIONS;i++) if (s->transfer_fds[i] == fd) { s->transfer_fds[i]=-1; break; }
    if (s->active_transfer_connections) s->active_transfer_connections--;
    pthread_cond_broadcast(&s->transfer_cond);
    pthread_mutex_unlock(&s->mutex);
}
static int transfer_access_snapshot(cr_server *s,uint32_t uid,const char *peer,cr_transfer_access *out) {
    memset(out,0,sizeof(*out));
    pthread_mutex_lock(&s->mutex);
    cr_session *session=find_session_locked(s,uid);
    /* Synthetic local sessions (notably the Bot) can never authenticate a network transfer. */
    if (!session || session->local_only || strcmp(session->peer_ip,peer)) { pthread_mutex_unlock(&s->mutex); return -1; }
    out->user_id=session->user_id; snprintf(out->account_id,sizeof(out->account_id),"%s",session->account_id); out->permission_bits=session->permission_bits; out->mode=session->mode; out->personal=session->personal;
    snprintf(out->files_root_path,sizeof(out->files_root_path),"%s",session->files_root_path);snprintf(out->files_root_name,sizeof(out->files_root_name),"%s",session->files_root_name);
    snprintf(out->login,sizeof(out->login),"%s",session->login); out->nickname_len=session->nickname_len; memcpy(out->nickname,session->nickname,session->nickname_len); snprintf(out->peer_ip,sizeof(out->peer_ip),"%s",session->peer_ip);
    out->key_len=session->key_len; memcpy(out->key,session->key,session->key_len);out->modern_transport=session->modern_transport;if(session->modern_transport)memcpy(out->modern_salt,session->modern_salt,CR_MODERN_SESSION_SALT);
    pthread_mutex_unlock(&s->mutex);
    mark_user_active(session);
    return 0;
}
static void transfer_access_as_session(cr_server *s,const cr_transfer_access *a,cr_session *fake) {
    memset(fake,0,sizeof(*fake)); fake->server=s; fake->user_id=a->user_id; snprintf(fake->account_id,sizeof(fake->account_id),"%s",a->account_id); fake->permission_bits=a->permission_bits; fake->mode=a->mode; fake->personal=a->personal;
    snprintf(fake->files_root_path,sizeof(fake->files_root_path),"%s",a->files_root_path);snprintf(fake->files_root_name,sizeof(fake->files_root_name),"%s",a->files_root_name);
    snprintf(fake->login,sizeof(fake->login),"%s",a->login); fake->nickname_len=a->nickname_len; memcpy(fake->nickname,a->nickname,a->nickname_len); snprintf(fake->peer_ip,sizeof(fake->peer_ip),"%s",a->peer_ip);
    fake->key_len=a->key_len; memcpy(fake->key,a->key,a->key_len);fake->modern_transport=a->modern_transport;if(a->modern_transport)memcpy(fake->modern_salt,a->modern_salt,CR_MODERN_SESSION_SALT);
}

static void *transfer_connection_main(void *opaque) {
  accepted_ctx *ctx = opaque;
  cr_server *s = ctx->server;
  int fd = ctx->fd;
  char peer[INET_ADDRSTRLEN];
  snprintf(peer, sizeof(peer), "%s", ctx->peer);
  free(ctx);
  cr_transfer_stream stream;
  int stream_initialized = 0;
  uint8_t h[10];
  if (cr_read_exact(fd, h, sizeof(h)))
    goto done;
  uint32_t version = cr_read_be32(h);
  uint16_t op = cr_read_be16(h + 4);
  uint32_t uid = cr_read_be32(h + 6);
  cr_transfer_access access;
  if (transfer_access_snapshot(s, uid, peer, &access))
    goto done;
  if ((op == TRANSFER_MEDIA_UPLOAD || op == TRANSFER_MEDIA_DOWNLOAD || op == TRANSFER_MEDIA_DELETE) && !access.modern_transport)
    goto done;
  if (access.modern_transport) {
    if (version != 0x02000000)
      goto done;
    uint8_t nonce[CR_MODERN_TRANSFER_NONCE];
    if (cr_read_exact(fd, nonce, sizeof(nonce)))
      goto done;
    if (cr_transfer_stream_init_modern(&stream, fd, access.key, access.key_len,
                                       access.modern_salt, nonce, op, 1))
      goto done;
    stream_initialized = 1;
  } else {
    if (version != 0x01000000)
      goto done;
    int encrypted =
        op == TRANSFER_ENCRYPTED_DOWNLOAD || op == TRANSFER_ENCRYPTED_UPLOAD;
    if (encrypted) {
      if (cr_transfer_stream_init(&stream, fd, access.key, access.key_len))
        goto done;
    } else if (cr_transfer_stream_init_plain(&stream, fd))
      goto done;
    stream_initialized = 1;
  }
  cr_session access_session;
  transfer_access_as_session(s, &access, &access_session);
  cr_session *session = &access_session;
  if (op == TRANSFER_ARTICLE_RECEIVER) {
    if (serve_article_post(s, &stream, session))
      goto done;
  } else if (op == TRANSFER_NEWS_INDEX) {
    if (serve_news_index(s, &stream, session))
      goto done;
  } else if (op == TRANSFER_FILE_SEARCH) {
    if (serve_file_search(s, &stream, session))
      goto done;
  } else if (op == TRANSFER_ENCRYPTED_DOWNLOAD) {
    uint32_t tid = begin_file_transfer(s, session, 1, fd);
    if (!tid)
      goto done;
    int success = serve_download(s, &stream, session, tid) == 0;
    end_file_transfer(s, tid, 1, success);
    if (!success)
      goto done;
  } else if (op == TRANSFER_ENCRYPTED_UPLOAD) {
    uint32_t tid = begin_file_transfer(s, session, 2, fd);
    if (!tid)
      goto done;
    int success = serve_upload(s, &stream, session, tid) == 0;
    end_file_transfer(s, tid, 2, success);
    if (!success)
      goto done;
  } else if (op == TRANSFER_MEDIA_UPLOAD) {
    if (serve_media_upload(s, &stream, session)) goto done;
  } else if (op == TRANSFER_MEDIA_DOWNLOAD) {
    if (serve_media_download(s, &stream, session)) goto done;
  } else if (op == TRANSFER_MEDIA_DELETE) {
    if (serve_media_delete(s, &stream, session)) goto done;
  } else if (op == TRANSFER_BANNER_DOWNLOAD) {
    pthread_mutex_lock(&s->state.mutex);
    size_t len = s->state.identity.banner_len;
    uint8_t *copy = malloc(len ? len : 1);
    if (copy && len)
      memcpy(copy, s->state.identity.banner_data, len);
    uint8_t url[256];
    size_t un = 0;
    int url_error = cr_utf8_to_macroman(s->state.identity.banner_url, url,
                                        sizeof(url), &un);
    pthread_mutex_unlock(&s->state.mutex);
    if (!copy || url_error || un > 255) {
      free(copy);
      goto done;
    }
    cr_buffer payload;
    cr_buffer_init(&payload);
    int failed = cr_buffer_append_u32(&payload, (uint32_t)len) ||
                 cr_buffer_append(&payload, copy, len) ||
                 cr_buffer_append_u8(&payload, (uint8_t)un) ||
                 cr_buffer_append(&payload, url, un) ||
                 cr_transfer_send(&stream, payload.data, payload.len);
    cr_buffer_free(&payload);
    free(copy);
    if (failed)
      goto done;
  } else if (op == TRANSFER_BANNER_UPLOAD) {
    if (!account_perm(session, PERM_EDIT_SERVER_INFO)) {
      send_async_error_to_user(s, session->user_id, 2);
      goto done;
    }
    uint8_t l[4];
    if (cr_transfer_read(&stream, l, 4))
      goto done;
    uint32_t len = cr_read_be32(l);
    if (len > 8 * 1024 * 1024)
      goto done;
    uint8_t *data = malloc(len ? len : 1);
    if (!data)
      goto done;
    if (cr_transfer_read(&stream, data, len)) {
      free(data);
      goto done;
    }
    uint8_t un;
    if (cr_transfer_read(&stream, &un, 1)) {
      free(data);
      goto done;
    }
    uint8_t urlmac[255];
    if (cr_transfer_read(&stream, urlmac, un)) {
      free(data);
      goto done;
    }
    char url[2048];
    if (cr_macroman_to_utf8(urlmac, un, url, sizeof(url))) {
      free(data);
      goto done;
    }
    if (cr_state_set_banner(&s->state, data, len, url) == 0)
      broadcast_banner_changed(s);
    free(data);
  } else
    goto done;
done:
  if (stream_initialized)
    cr_transfer_stream_free(&stream);
  transfer_fd_unregister(s, fd);
  shutdown(fd, SHUT_RDWR);
  close(fd);
  return NULL;
}
static void *transfer_accept_main(void *opaque) {
    cr_server *s = opaque;
    while (!s->stop) {
        struct pollfd pfd = { .fd = s->transfer_listener_fd, .events = POLLIN };
        int ready = poll(&pfd, 1, 250);
        if (ready < 0) { if (errno == EINTR) continue; if (s->stop) break; continue; }
        if (ready == 0) continue;
        if (!(pfd.revents & POLLIN)) {
            if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) break;
            continue;
        }
        struct sockaddr_in a;
        socklen_t l = sizeof(a);
        int fd = accept(s->transfer_listener_fd, (struct sockaddr *)&a, &l);
        if (fd < 0) { if (errno == EINTR) continue; if (s->stop) break; continue; }
        configure_accepted_socket(fd);
        if (transfer_fd_register(s, fd) != 0) { close(fd); continue; }
        accepted_ctx *ctx = calloc(1, sizeof(*ctx));
        if (!ctx) { transfer_fd_unregister(s,fd); close(fd); continue; }
        ctx->server = s;
        ctx->fd = fd;
        inet_ntop(AF_INET, &a.sin_addr, ctx->peer, sizeof(ctx->peer));
        pthread_t t;
        if (pthread_create(&t, NULL, transfer_connection_main, ctx) == 0) pthread_detach(t);
        else { transfer_fd_unregister(s,fd); close(fd); free(ctx); }
    }
    return NULL;
}

static void free_joined_session(cr_session *x) {
    if (!x) return;
    free(x->picture);
    pthread_mutex_destroy(&x->send_mutex);
    free(x);
}

static void reap_finished_sessions(cr_server *s) {
    for (;;) {
        cr_session *victim = NULL;
        pthread_t thread;
        pthread_mutex_lock(&s->mutex);
        for (size_t i = 0; i < s->allocated_session_count; ++i) {
            cr_session *x = s->sessions[i];
            if (x && x->thread_started && x->finished) {
                victim = x;
                thread = x->thread;
                s->sessions[i] = NULL;
                break;
            }
        }
        while (s->allocated_session_count && !s->sessions[s->allocated_session_count - 1])
            s->allocated_session_count--;
        pthread_mutex_unlock(&s->mutex);
        if (!victim) break;
        pthread_join(thread, NULL);
        free_joined_session(victim);
    }
}

static void join_all_sessions(cr_server *s) {
    for (;;) {
        cr_session *victim = NULL;
        pthread_t thread;
        pthread_mutex_lock(&s->mutex);
        for (size_t i = 0; i < s->allocated_session_count; ++i) {
            cr_session *x = s->sessions[i];
            if (x && x->thread_started) {
                victim = x;
                thread = x->thread;
                s->sessions[i] = NULL;
                break;
            }
        }
        pthread_mutex_unlock(&s->mutex);
        if (!victim) break;
        pthread_join(thread, NULL);
        free_joined_session(victim);
    }
    pthread_mutex_lock(&s->mutex);
    s->allocated_session_count = 0;
    pthread_mutex_unlock(&s->mutex);
}

static void remove_file_search_index_files(const char *path){
    char sidecar[PATH_MAX];
    unlink(path);
    if(snprintf(sidecar,sizeof(sidecar),"%s-wal",path)>0)unlink(sidecar);
    if(snprintf(sidecar,sizeof(sidecar),"%s-shm",path)>0)unlink(sidecar);
}
static int initialize_file_search_index(cr_server*s){
    char path[PATH_MAX];
    int n=snprintf(path,sizeof(path),"%s/file-index.db",s->state.database_dir);
    int existed=0;
    atomic_store(&s->file_index_ready,0);
    if(n<=0||(size_t)n>=sizeof(path)){log_msg("File-search index path is too long; filesystem fallback enabled");return-1;}
    existed=access(path,F_OK)==0;
    for(int attempt=0;attempt<2;attempt++){
        if(attempt)remove_file_search_index_files(path);
        if(cr_file_search_index_init(&s->file_index,path)==0){
            if(existed&&attempt==0){
                uint64_t count=0;int64_t rebuilt=0;int found=0;
                int valid=cr_file_search_index_entry_count(&s->file_index,&count)==0&&
                          cr_file_search_index_last_full_rebuild(&s->file_index,&rebuilt,&found)==0;
                if(valid&&(count>0||found)){
                    atomic_store(&s->file_index_ready,1);
                    log_msg("Reusing existing file-search index: %llu searchable item(s)",(unsigned long long)count);
                }else{
                    log_msg("No completed file-search index yet; filesystem fallback active until manual or scheduled rebuild");
                }
            }else{
                log_msg("No reusable file-search index; filesystem fallback active until manual or scheduled rebuild");
            }
            return 0;
        }
    }
    log_msg("File-search index unavailable; filesystem fallback enabled");
    return -1;
}

static int file_search_index_incremental_available(cr_server*s){
    if(!s||!s->file_index.ready)return 0;
    pthread_mutex_lock(&s->mutex);
    int available=atomic_load(&s->file_index_ready);
    if(!available)s->file_index_dirty=1;
    pthread_mutex_unlock(&s->mutex);
    return available;
}

/*
 * A full rebuild deliberately keeps the SQLite index mutex for the entire tree
 * walk. File mutations must never wait behind that potentially long operation:
 * while the rebuild is active they update the filesystem/metadata immediately,
 * mark the index dirty, and use filesystem-search fallback. The rebuild repeats
 * until it completes a pass with no concurrent mutations.
 */
static int rebuild_file_search_index_consistently(cr_server*s,int interruptible){
    if(!s||!s->file_index.ready)return-1;
    for(;;){
        cr_search_index_exclusions exclusions;
        pthread_mutex_lock(&s->mutex);
        s->file_index_dirty=0;
        atomic_store(&s->file_index_ready,0);
        exclusions=s->search_index_exclusions;
        pthread_mutex_unlock(&s->mutex);

        int rc=interruptible
            ? cr_file_search_index_rebuild_interruptible(&s->file_index,s->state.storage_root,&s->metadata,&exclusions,&s->stop)
            : cr_file_search_index_rebuild(&s->file_index,s->state.storage_root,&s->metadata,&exclusions);
        if(rc)return rc;

        pthread_mutex_lock(&s->mutex);
        int dirty=s->file_index_dirty;
        if(!dirty)atomic_store(&s->file_index_ready,1);
        pthread_mutex_unlock(&s->mutex);
        if(!dirty)return 0;
        log_msg("File-search index changed during rebuild; repeating without blocking file operations");
    }
}

static void *file_search_index_rebuild_main(void *opaque){
    cr_server*s=opaque;
    log_msg("File-search index rebuild started in background: %s",s->state.storage_root);
    for(;;){
        int rebuild_rc=rebuild_file_search_index_consistently(s,1);
        if(rebuild_rc==0){
            pthread_mutex_lock(&s->mutex);
            int repeat=s->file_index_dirty&&!s->stop;
            if(!repeat)s->file_index_thread_running=0;
            pthread_mutex_unlock(&s->mutex);
            if(repeat){
                log_msg("File-search index changed after rebuild; repeating background pass");
                continue;
            }
            log_msg("File-search index ready: %s",s->file_index.path);
            return NULL;
        }
        atomic_store(&s->file_index_ready,0);
        pthread_mutex_lock(&s->mutex);
        s->file_index_thread_running=0;
        pthread_mutex_unlock(&s->mutex);
        if(rebuild_rc==-2&&s->stop)
            log_msg("File-search index rebuild cancelled during shutdown");
        else
            log_msg("File-search index rebuild failed; filesystem fallback enabled");
        return NULL;
    }
}


static void invalidate_file_search_index(cr_server*s,const char*reason){
    if(!s)return;
    pthread_mutex_lock(&s->mutex);
    atomic_store(&s->file_index_ready,0);
    s->file_index_dirty=1;
    pthread_mutex_unlock(&s->mutex);
    log_msg("File-search index disabled after %s; filesystem fallback active until manual or scheduled rebuild",reason?reason:"incremental update failure");
}

/* Queue a rebuild without holding the requesting control/file operation behind a full
 * filesystem walk. One worker is active at a time. If a rebuild is already running,
 * marking the index dirty makes that worker repeat with the newest exclusions/state. */
static void repair_file_search_index(cr_server*s){
    if(!s||!s->file_index.ready)return;
    pthread_t completed_thread;
    int join_completed=0;

    pthread_mutex_lock(&s->mutex);
    atomic_store(&s->file_index_ready,0);
    s->file_index_dirty=1;
    if(s->file_index_thread_running){
        pthread_mutex_unlock(&s->mutex);
        return;
    }
    if(s->file_index_thread_started){
        completed_thread=s->file_index_thread;
        s->file_index_thread_started=0;
        join_completed=1;
    }
    pthread_mutex_unlock(&s->mutex);

    if(join_completed)pthread_join(completed_thread,NULL);

    pthread_mutex_lock(&s->mutex);
    if(s->stop){pthread_mutex_unlock(&s->mutex);return;}
    if(s->file_index_thread_running){
        s->file_index_dirty=1;
        pthread_mutex_unlock(&s->mutex);
        return;
    }
    s->file_index_dirty=1;
    s->file_index_thread_running=1;
    if(pthread_create(&s->file_index_thread,NULL,file_search_index_rebuild_main,s)==0){
        s->file_index_thread_started=1;
        pthread_mutex_unlock(&s->mutex);
        return;
    }
    s->file_index_thread_running=0;
    atomic_store(&s->file_index_ready,0);
    pthread_mutex_unlock(&s->mutex);
    log_msg("Could not queue file-search index rebuild; filesystem fallback enabled");
}

static void maybe_schedule_file_search_index_rebuild(cr_server*s){
    if(!s||!s->file_index.ready||!s->search_index_rebuild_interval_hours)return;
    time_t now=time(NULL);
    if(s->last_file_index_schedule_check&&now-s->last_file_index_schedule_check<60)return;
    s->last_file_index_schedule_check=now;

    pthread_mutex_lock(&s->mutex);
    int running=s->file_index_thread_running;
    pthread_mutex_unlock(&s->mutex);
    if(running)return;

    int64_t reference=(int64_t)now;
    if(cr_file_search_index_rebuild_schedule_reference(&s->file_index,(int64_t)now,&reference))return;
    uint64_t interval=(uint64_t)s->search_index_rebuild_interval_hours*3600ULL;
    uint64_t due=reference>0?(uint64_t)reference+interval:interval;
    if((uint64_t)now<due)return;

    log_msg("Automatic file-search index rebuild due after %u hour(s)",s->search_index_rebuild_interval_hours);
    repair_file_search_index(s);
}

static int provision_personal_homes(cr_server*s){for(size_t i=0;i<s->state.account_count;i++){cr_account*a=&s->state.accounts[i];if(a->personal==CR_PERSONAL_NONE)continue;if(!safe_component(a->login))return-1;char home[PATH_MAX];if(join_path_component(home,sizeof(home),s->state.personal_home_root,a->login))return-1;if(mkdir(home,0755)&&errno!=EEXIST)return-1;}return 0;}

int cr_server_init(cr_server **out, const cr_server_config *config) {
    if (!out || !config || !config->instance_root[0] || !config->state_path[0] || !config->persistent.files_root[0]) return -1;
    cr_server *s = calloc(1, sizeof(*s));
    if (!s) return -1;
    if (configure_log_path(config->instance_root)) {
        fprintf(stderr, "carracho-server: could not initialize %s/logs/carracho-server.log\n", config->instance_root);
        free(s);
        return -1;
    }
    s->listener_fd = s->transfer_listener_fd = -1;
    s->bot_fd = -1;
    s->next_user_id = 0x1000;
    s->next_channel_id = 2;
    s->next_transfer_id = 1;
    snprintf(s->config_path,sizeof(s->config_path),"%s",config->config_path);
    const char*home=getenv("HOME");struct passwd*pw=NULL;if(!home||!*home){pw=getpwuid(getuid());home=pw&&pw->pw_dir?pw->pw_dir:"";}
    char daemon_dir[PATH_MAX];
    if(!home||!*home||snprintf(s->bot_config_path,sizeof(s->bot_config_path),"%s/etc/carracho-bot.json",config->instance_root)>=(int)sizeof(s->bot_config_path)||
       snprintf(daemon_dir,sizeof(daemon_dir),"%s/daemon",config->instance_root)>=(int)sizeof(daemon_dir)||
       snprintf(s->bot_status_path,sizeof(s->bot_status_path),"%s/bot-status.json",daemon_dir)>=(int)sizeof(s->bot_status_path)||
       snprintf(s->bot_pipe_path,sizeof(s->bot_pipe_path),"%s/Bot",home)>=(int)sizeof(s->bot_pipe_path)||
       snprintf(s->bot_avatar_path,sizeof(s->bot_avatar_path),"%s/etc/carracho-bot-avatar.png",config->instance_root)>=(int)sizeof(s->bot_avatar_path)){free(s);return-1;}
    if(ensure_directory_tree(daemon_dir)){free(s);return-1;}
    s->search_index_exclusions = config->persistent.search_index_exclusions;
    s->search_index_rebuild_interval_hours = config->persistent.search_index_rebuild_interval_hours;
    s->download_bandwidth_limit_bps = config->persistent.upload_bandwidth_limit_bytes_per_second;
    for (size_t i = 0; i < CR_SERVER_MAX_TRANSFER_CONNECTIONS; i++) s->transfer_fds[i] = -1;
    if (pthread_mutex_init(&s->mutex, NULL)) { free(s); return -1; }
    if (pthread_cond_init(&s->transfer_cond, NULL)) { pthread_mutex_destroy(&s->mutex); free(s); return -1; }
    if (cr_state_open_at_root(&s->state, config->state_path, config->instance_root)) {
        pthread_cond_destroy(&s->transfer_cond); pthread_mutex_destroy(&s->mutex); free(s); return -1;
    }
    if(join_path_component(s->bot_rss_db_path,sizeof(s->bot_rss_db_path),s->state.database_dir,"bot-rss.db")){
        cr_state_close(&s->state);pthread_cond_destroy(&s->transfer_cond);pthread_mutex_destroy(&s->mutex);free(s);return-1;
    }

    unsigned reconciled = 0;
    if (cr_state_reconcile_startup_settings(&s->state, &config->persistent, &reconciled)) {
        cr_state_close(&s->state); pthread_cond_destroy(&s->transfer_cond); pthread_mutex_destroy(&s->mutex); free(s); return -1;
    }
    if (reconciled) log_msg("Startup config reconciled %u persisted setting(s) into server.db", reconciled);
    if (cr_state_ensure_local_bot_account(&s->state)) {
        cr_state_close(&s->state); pthread_cond_destroy(&s->transfer_cond); pthread_mutex_destroy(&s->mutex); free(s); return -1;
    }

    if (strlen(config->persistent.files_root) >= sizeof(s->state.storage_root) ||
        snprintf(s->state.storage_root, sizeof(s->state.storage_root), "%s", config->persistent.files_root) >= (int)sizeof(s->state.storage_root) ||
        ensure_directory_tree(s->state.storage_root)) {
        cr_state_close(&s->state); pthread_cond_destroy(&s->transfer_cond); pthread_mutex_destroy(&s->mutex); free(s); return -1;
    }
    log_msg("Published file root: %s", s->state.storage_root);
    if (config->persistent.legacy_files_root[0]) {
        if (strlen(config->persistent.legacy_files_root) >= sizeof(s->state.legacy_storage_root) ||
            snprintf(s->state.legacy_storage_root, sizeof(s->state.legacy_storage_root), "%s", config->persistent.legacy_files_root) >= (int)sizeof(s->state.legacy_storage_root) ||
            ensure_directory_tree(s->state.legacy_storage_root)) {
            cr_state_close(&s->state); pthread_cond_destroy(&s->transfer_cond); pthread_mutex_destroy(&s->mutex); free(s); return -1;
        }
        log_msg("Legacy file root: %s", s->state.legacy_storage_root);
    } else {
        s->state.legacy_storage_root[0] = 0;
    }
    if (config->persistent.upload_bandwidth_limit_bytes_per_second)
        log_msg("Server upload bandwidth limit: %llu byte/s", (unsigned long long)config->persistent.upload_bandwidth_limit_bytes_per_second);
    else
        log_msg("Server upload bandwidth limit: unlimited");

    if (provision_personal_homes(s)) {
        cr_state_close(&s->state); pthread_cond_destroy(&s->transfer_cond); pthread_mutex_destroy(&s->mutex); free(s); return -1;
    }
    if (cr_file_metadata_store_init(&s->metadata, s->state.path, CR_FILE_METADATA_SCOPE_PUBLISHED, s->state.metadata_path)) {
        cr_state_close(&s->state); pthread_cond_destroy(&s->transfer_cond); pthread_mutex_destroy(&s->mutex); free(s); return -1;
    }
    if (cr_file_metadata_store_init(&s->legacy_metadata, s->state.path, CR_FILE_METADATA_SCOPE_LEGACY, s->state.legacy_metadata_path)) {
        cr_file_metadata_store_destroy(&s->metadata); cr_state_close(&s->state); pthread_cond_destroy(&s->transfer_cond); pthread_mutex_destroy(&s->mutex); free(s); return -1;
    }
    (void)initialize_file_search_index(s);
    if (cr_news_store_init(&s->news, s->state.news_db_path, s->state.news_root)) {
        if (s->file_index.ready) cr_file_search_index_destroy(&s->file_index);
        cr_file_metadata_store_destroy(&s->legacy_metadata); cr_file_metadata_store_destroy(&s->metadata); cr_state_close(&s->state); pthread_cond_destroy(&s->transfer_cond); pthread_mutex_destroy(&s->mutex); free(s); return -1;
    }
    char classic_flat_news_path[PATH_MAX];
    if (join_path_component(classic_flat_news_path, sizeof(classic_flat_news_path), s->state.news_root, "Flat News") ||
        cr_flat_news_store_init(&s->flat_news, s->state.news_db_path, s->state.flat_news_path, classic_flat_news_path)) {
        cr_news_store_destroy(&s->news); if (s->file_index.ready) cr_file_search_index_destroy(&s->file_index);
        cr_file_metadata_store_destroy(&s->legacy_metadata); cr_file_metadata_store_destroy(&s->metadata); cr_state_close(&s->state); pthread_cond_destroy(&s->transfer_cond); pthread_mutex_destroy(&s->mutex); free(s); return -1;
    }
    if (join_path_component(s->trash_root, sizeof(s->trash_root), s->state.base_dir, "Trash") ||
        (mkdir(s->trash_root, 0755) && errno != EEXIST)) {
        cr_flat_news_store_destroy(&s->flat_news); cr_news_store_destroy(&s->news); if (s->file_index.ready) cr_file_search_index_destroy(&s->file_index);
        cr_file_metadata_store_destroy(&s->legacy_metadata); cr_file_metadata_store_destroy(&s->metadata); cr_state_close(&s->state); pthread_cond_destroy(&s->transfer_cond); pthread_mutex_destroy(&s->mutex); free(s); return -1;
    }
    char media_db[PATH_MAX],media_root[PATH_MAX];
    if(join_path_component(media_db,sizeof(media_db),s->state.database_dir,"media.db")||join_path_component(media_root,sizeof(media_root),s->state.base_dir,"Media/objects")||cr_media_store_init(&s->media,media_db,media_root)){
        cr_flat_news_store_destroy(&s->flat_news); cr_news_store_destroy(&s->news); if (s->file_index.ready) cr_file_search_index_destroy(&s->file_index);
        cr_file_metadata_store_destroy(&s->legacy_metadata); cr_file_metadata_store_destroy(&s->metadata); cr_state_close(&s->state); pthread_cond_destroy(&s->transfer_cond); pthread_mutex_destroy(&s->mutex); free(s); return -1;
    }
    if (synchronize_news_state(s) < 0 || run_news_expiration(s, time(NULL)) < 0) {
        cr_media_store_destroy(&s->media); cr_flat_news_store_destroy(&s->flat_news); cr_news_store_destroy(&s->news); if (s->file_index.ready) cr_file_search_index_destroy(&s->file_index);
        cr_file_metadata_store_destroy(&s->legacy_metadata); cr_file_metadata_store_destroy(&s->metadata); cr_state_close(&s->state); pthread_cond_destroy(&s->transfer_cond); pthread_mutex_destroy(&s->mutex); free(s); return -1;
    }
    uint16_t requested = s->state.advanced.control_port;
    if (make_listener_pair(requested, &s->listener_fd, &s->transfer_listener_fd, &s->port, &s->transfer_port)) {
        cr_media_store_destroy(&s->media); cr_flat_news_store_destroy(&s->flat_news); cr_news_store_destroy(&s->news); if (s->file_index.ready) cr_file_search_index_destroy(&s->file_index);
        cr_file_metadata_store_destroy(&s->legacy_metadata); cr_file_metadata_store_destroy(&s->metadata); cr_state_close(&s->state); pthread_cond_destroy(&s->transfer_cond); pthread_mutex_destroy(&s->mutex); free(s); return -1;
    }
    log_msg("Listeners bound: control=%u transfer=%u",s->port,s->transfer_port);
    cr_channel *pub = &s->channels[0];
    pub->used = 1; pub->id = 1; memcpy(pub->name, "Public", 6); pub->name_len = 6;
    s->started_at = time(NULL);
    *out = s;
    return 0;
}

uint16_t cr_server_port(cr_server*s){return s?s->port:0;}
uint16_t cr_server_transfer_port(cr_server*s){return s?s->transfer_port:0;}
void cr_server_signal_stop(cr_server *s) { if (s) s->stop = 1; }
void cr_server_request_stop(cr_server*s){if(!s)return;s->stop=1;if(s->listener_fd>=0)shutdown(s->listener_fd,SHUT_RDWR);if(s->transfer_listener_fd>=0)shutdown(s->transfer_listener_fd,SHUT_RDWR);pthread_mutex_lock(&s->mutex);for(size_t i=0;i<s->allocated_session_count;i++){cr_session*x=s->sessions[i];if(x&&!x->closed&&!x->local_only&&x->fd>=0)shutdown(x->fd,SHUT_RDWR);}for(size_t i=0;i<CR_SERVER_MAX_TRANSFER_CONNECTIONS;i++)if(s->transfer_fds[i]>=0)shutdown(s->transfer_fds[i],SHUT_RDWR);pthread_mutex_unlock(&s->mutex);}
int cr_server_run(cr_server *s) {
    if (pthread_create(&s->bot_thread, NULL, bot_thread_main, s) != 0) return -1;
    s->bot_thread_started=1;
    if (pthread_create(&s->bot_rss_thread, NULL, bot_rss_thread_main, s) != 0) {s->stop=1;pthread_join(s->bot_thread,NULL);s->bot_thread_started=0;return -1;}
    s->bot_rss_thread_started=1;
    if (pthread_create(&s->transfer_thread, NULL, transfer_accept_main, s) != 0) {s->stop=1;pthread_join(s->bot_rss_thread,NULL);s->bot_rss_thread_started=0;pthread_join(s->bot_thread,NULL);s->bot_thread_started=0;return -1;}
    log_msg("Carracho C server ready: control=%u transfer=%u state=%s", s->port, s->transfer_port, s->state.path);
    if(s->search_index_rebuild_interval_hours)
        log_msg("Automatic full search-index rebuild interval: %u hour(s)",s->search_index_rebuild_interval_hours);
    else
        log_msg("Automatic full search-index rebuilds disabled");
    while (!s->stop) {
        reap_finished_sessions(s);
        maybe_schedule_file_search_index_rebuild(s);
        maybe_run_news_expiration(s);
        maybe_send_tracker_registration(s);
        maybe_sleep_idle_users(s);
        struct pollfd pfd = { .fd = s->listener_fd, .events = POLLIN };
        int ready = poll(&pfd, 1, 250);
        if (ready < 0) {
            if (errno == EINTR) continue;
            if (s->stop) break;
            log_msg("poll failed: %s", strerror(errno));
            continue;
        }
        if (ready == 0) continue;
        if (!(pfd.revents & POLLIN)) {
            if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) break;
            continue;
        }
        struct sockaddr_in a;
        socklen_t l = sizeof(a);
        int fd = accept(s->listener_fd, (struct sockaddr *)&a, &l);
        if (fd < 0) {
            if (errno == EINTR) continue;
            if (s->stop || errno == EBADF || errno == EINVAL) break;
            log_msg("accept failed: %s", strerror(errno));
            continue;
        }
        configure_accepted_socket(fd);
        char peer[INET_ADDRSTRLEN] = "unknown";
        inet_ntop(AF_INET, &a.sin_addr, peer, sizeof(peer));
        uint8_t address_bytes[4];
        memcpy(address_bytes, &a.sin_addr, 4);
        if (!cr_state_ipv4_allowed(&s->state, address_bytes)) {
            log_msg("Rejected connection from %s: blocked by Allow/Deny IP policy", peer);
            close(fd);
            continue;
        }

        uint16_t max_connections=0,max_per_ip=0;pthread_mutex_lock(&s->state.mutex);max_connections=s->state.advanced.max_connections;max_per_ip=s->state.advanced.max_connections_per_ip;pthread_mutex_unlock(&s->state.mutex);
        pthread_mutex_lock(&s->mutex);
        size_t active = 0, same = 0, slot = CR_SERVER_MAX_SESSIONS;
        for (size_t i = 0; i < s->allocated_session_count; ++i) {
            cr_session *x = s->sessions[i];
            if (!x && slot == CR_SERVER_MAX_SESSIONS) slot = i;
            if (x && !x->closed) { active++; if (!strcmp(x->peer_ip, peer)) same++; }
        }
        if (slot == CR_SERVER_MAX_SESSIONS && s->allocated_session_count < CR_SERVER_MAX_SESSIONS)
            slot = s->allocated_session_count++;
        if (active >= max_connections ||
            same >= max_per_ip ||
            slot == CR_SERVER_MAX_SESSIONS) {
            pthread_mutex_unlock(&s->mutex);
            close(fd);
            continue;
        }
        cr_session *x = calloc(1, sizeof(*x));
        if (!x) { pthread_mutex_unlock(&s->mutex); close(fd); continue; }
        x->server = s;
        x->fd = fd;
        snprintf(x->peer_ip, sizeof(x->peer_ip), "%s", peer);
        if (pthread_mutex_init(&x->send_mutex, NULL) != 0) {
            free(x); pthread_mutex_unlock(&s->mutex); close(fd); continue;
        }
        s->sessions[slot] = x;
        if (pthread_create(&x->thread, NULL, session_main, x) == 0) {
            x->thread_started = 1;
        } else {
            s->sessions[slot] = NULL;
            pthread_mutex_destroy(&x->send_mutex);
            free(x);
            close(fd);
        }
        pthread_mutex_unlock(&s->mutex);
    }

    cr_server_request_stop(s);
    pthread_join(s->transfer_thread, NULL);
    if(s->bot_thread_started){pthread_join(s->bot_thread,NULL);s->bot_thread_started=0;}
    if(s->bot_rss_thread_started){pthread_join(s->bot_rss_thread,NULL);s->bot_rss_thread_started=0;}
    pthread_mutex_lock(&s->mutex);
    while (s->active_transfer_connections) pthread_cond_wait(&s->transfer_cond,&s->mutex);
    pthread_mutex_unlock(&s->mutex);
    join_all_sessions(s);
    log_msg("Carracho C server stopped");
    return 0;
}
void cr_server_destroy(cr_server *s) {
    if (!s) return;
    cr_server_request_stop(s);
    if(s->bot_thread_started){pthread_join(s->bot_thread,NULL);s->bot_thread_started=0;}
    if(s->bot_rss_thread_started){pthread_join(s->bot_rss_thread,NULL);s->bot_rss_thread_started=0;}
    disconnect_local_bot(s);bot_fifo_stop(s);
    join_all_sessions(s);
    if (s->listener_fd >= 0) close(s->listener_fd);
    if (s->transfer_listener_fd >= 0) close(s->transfer_listener_fd);
    if (s->file_index_thread_started) {
        pthread_join(s->file_index_thread,NULL);
        s->file_index_thread_started=0;
    }
    cr_media_store_destroy(&s->media);
    cr_flat_news_store_destroy(&s->flat_news);
    cr_news_store_destroy(&s->news);
    if (s->file_index.ready) cr_file_search_index_destroy(&s->file_index);
    cr_file_metadata_store_destroy(&s->legacy_metadata);
    cr_file_metadata_store_destroy(&s->metadata);
    cr_state_close(&s->state);
    pthread_cond_destroy(&s->transfer_cond);
    pthread_mutex_destroy(&s->mutex);
    free(s);
}
