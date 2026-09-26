#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "bot_file_watch.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <json-c/json.h>
#include <limits.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#if defined(__linux__)
#include <sys/inotify.h>
#endif
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef NAME_MAX
#define NAME_MAX 255
#endif

#define CR_BOT_FILE_WATCH_DEBOUNCE_SECONDS 2.0
#define CR_BOT_FILE_WATCH_COOLDOWN_SECONDS 60.0
#define CR_BOT_FILE_WATCH_EVENT_BUFFER (64u * 1024u)
#define CR_BOT_FILE_WATCH_PENDING_MAX 256u

#if defined(__linux__)
static double monotonic_seconds(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static void watcher_log(cr_bot_file_watch_log_cb cb, void *opaque, const char *fmt, ...) {
    if (!cb) return;
    char line[1536];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    cb(opaque, line);
}

#endif

static int valid_uuid_text(const char *s) {
    if (!s || strlen(s) != 36) return 0;
    for (size_t i = 0; i < 36; ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (s[i] != '-') return 0;
        } else {
            unsigned char c = (unsigned char)s[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return 0;
        }
    }
    return 1;
}

static int path_component_safe(const char *begin, size_t n) {
    if (!n || n > NAME_MAX ||
        (n == 1 && begin[0] == '.') || (n == 2 && begin[0] == '.' && begin[1] == '.')) return 0;
    for (size_t i = 0; i < n; ++i) {
        unsigned char c = (unsigned char)begin[i];
        if (c == '\\' || c == 0) return 0;
    }
    return 1;
}

static int relative_path_safe(const char *path) {
    if (!path || !*path || strlen(path) > CR_BOT_FILE_WATCH_PATH_MAX || path[0] == '/') return 0;
    if (!strcmp(path, ".")) return 1;
    const char *p = path;
    while (*p) {
        const char *slash = strchr(p, '/');
        size_t n = slash ? (size_t)(slash - p) : strlen(p);
        if (!path_component_safe(p, n)) return 0;
        if (!slash) break;
        p = slash + 1;
    }
    return 1;
}

static int template_safe(const char *text) {
    if (!text || !*text || strlen(text) > CR_BOT_FILE_WATCH_TEMPLATE_MAX ||
        strchr(text, '\n') || strchr(text, '\r') ||
        (!strstr(text, "{folder}") && !strstr(text, "{file}"))) return 0;
    return 1;
}

static int path_join(char *out, size_t cap, const char *a, const char *b) {
    if (!out || !cap || !a || !b) return -1;
    size_t an = strlen(a);
    int n = snprintf(out, cap, "%s%s%s", a, (an && a[an - 1] == '/') ? "" : "/", b);
    return n < 0 || (size_t)n >= cap ? -1 : 0;
}

static int path_within_root(const char *root, const char *target) {
    size_t n = strlen(root);
    return !strcmp(root, target) || (!strncmp(root, target, n) && target[n] == '/');
}

static int validate_one(const char *files_root, cr_bot_file_watcher *w, int require_directory) {
    if (!files_root || !w || !valid_uuid_text(w->id) || !relative_path_safe(w->path) ||
        !w->channel_id || !template_safe(w->message_template)) return -1;

    char root_real[PATH_MAX];
    if (!realpath(files_root, root_real)) return -1;
    char target[PATH_MAX];
    if (!strcmp(w->path, ".")) {
        if (snprintf(target, sizeof(target), "%s", root_real) >= (int)sizeof(target)) return -1;
    } else if (path_join(target, sizeof(target), root_real, w->path)) return -1;
    if (require_directory) {
        char target_real[PATH_MAX];
        struct stat st;
        if (!realpath(target, target_real) || stat(target_real, &st) != 0 || !S_ISDIR(st.st_mode) ||
            !path_within_root(root_real, target_real)) return -1;
    }
    return 0;
}

static json_object *read_or_new_root(const char *config_path) {
    json_object *root = NULL;
    if (access(config_path, F_OK) == 0) root = json_object_from_file(config_path);
    else if (errno == ENOENT) root = json_object_new_object();
    if (!root || !json_object_is_type(root, json_type_object)) {
        if (root) json_object_put(root);
        return NULL;
    }
    return root;
}

int cr_bot_file_watch_load(const char *config_path,
                           const char *files_root,
                           cr_bot_file_watcher *out,
                           size_t capacity,
                           size_t *out_count) {
    if (!config_path || !files_root || !out || !out_count) return -1;
    *out_count = 0;
    if (access(config_path, F_OK) != 0) return errno == ENOENT ? 0 : -1;
    json_object *root = json_object_from_file(config_path);
    if (!root || !json_object_is_type(root, json_type_object)) { if (root) json_object_put(root); return -1; }
    json_object *array = NULL;
    if (!json_object_object_get_ex(root, "fileWatchers", &array)) { json_object_put(root); return 0; }
    if (!json_object_is_type(array, json_type_array)) { json_object_put(root); return -1; }
    size_t count = json_object_array_length(array);
    if (count > capacity || count > CR_BOT_FILE_WATCH_MAX) { json_object_put(root); return -1; }
    for (size_t i = 0; i < count; ++i) {
        json_object *item = json_object_array_get_idx(array, i), *id = NULL, *enabled = NULL, *path = NULL,
                    *channel = NULL, *message = NULL;
        if (!item || !json_object_is_type(item, json_type_object) ||
            !json_object_object_get_ex(item, "id", &id) || !json_object_is_type(id, json_type_string) ||
            !json_object_object_get_ex(item, "enabled", &enabled) || !json_object_is_type(enabled, json_type_boolean) ||
            !json_object_object_get_ex(item, "path", &path) || !json_object_is_type(path, json_type_string) ||
            !json_object_object_get_ex(item, "channelID", &channel) || !json_object_is_type(channel, json_type_int) ||
            !json_object_object_get_ex(item, "messageTemplate", &message) || !json_object_is_type(message, json_type_string)) {
            json_object_put(root); return -1;
        }
        const char *ids = json_object_get_string(id), *paths = json_object_get_string(path), *messages = json_object_get_string(message);
        int64_t raw_channel = json_object_get_int64(channel);
        if (!ids || !paths || !messages || raw_channel <= 0 || raw_channel > UINT32_MAX ||
            strlen(ids) >= sizeof(out[i].id) || strlen(paths) >= sizeof(out[i].path) || strlen(messages) >= sizeof(out[i].message_template)) {
            json_object_put(root); return -1;
        }
        memset(&out[i], 0, sizeof(out[i]));
        snprintf(out[i].id, sizeof(out[i].id), "%s", ids);
        out[i].enabled = json_object_get_boolean(enabled) ? 1 : 0;
        snprintf(out[i].path, sizeof(out[i].path), "%s", paths);
        out[i].channel_id = (uint32_t)raw_channel;
        snprintf(out[i].message_template, sizeof(out[i].message_template), "%s", messages);
        if (validate_one(files_root, &out[i], 0)) { json_object_put(root); return -1; }
    }
    json_object_put(root);
    *out_count = count;
    return 0;
}

static int write_config(const char *config_path, json_object *root) {
    char tmp[PATH_MAX];
    int n = snprintf(tmp, sizeof(tmp), "%s.tmp.%ld", config_path, (long)getpid());
    int saved = EIO;
    if (n > 0 && (size_t)n < sizeof(tmp) && json_object_to_file_ext(tmp, root, JSON_C_TO_STRING_PRETTY) == 0) {
        (void)chmod(tmp, 0600);
        if (rename(tmp, config_path) == 0) return 0;
        saved = errno;
        unlink(tmp);
    } else {
        saved = errno ? errno : EIO;
        if (n > 0 && (size_t)n < sizeof(tmp)) unlink(tmp);
    }
    if (access(config_path, F_OK) == 0 && json_object_to_file_ext(config_path, root, JSON_C_TO_STRING_PRETTY) == 0) {
        (void)chmod(config_path, 0600);
        return 0;
    }
    errno = saved;
    return -1;
}

int cr_bot_file_watch_store(const char *config_path,
                            const char *files_root,
                            const cr_bot_file_watcher *watchers,
                            size_t count) {
    if (!config_path || !files_root || (!watchers && count) || count > CR_BOT_FILE_WATCH_MAX) return -1;
    for (size_t i = 0; i < count; ++i) {
        cr_bot_file_watcher copy = watchers[i];
        if (validate_one(files_root, &copy, copy.enabled)) return -1;
        for (size_t j = 0; j < i; ++j) {
            if (!strcasecmp(watchers[j].id, copy.id) || !strcasecmp(watchers[j].path, copy.path)) return -1;
        }
    }
    json_object *root = read_or_new_root(config_path);
    if (!root) return -1;
    json_object *array = json_object_new_array();
    if (!array) { json_object_put(root); return -1; }
    for (size_t i = 0; i < count; ++i) {
        json_object *item = json_object_new_object();
        if (!item) { json_object_put(root); return -1; }
        json_object_object_add(item, "id", json_object_new_string(watchers[i].id));
        json_object_object_add(item, "enabled", json_object_new_boolean(watchers[i].enabled));
        json_object_object_add(item, "path", json_object_new_string(watchers[i].path));
        json_object_object_add(item, "channelID", json_object_new_int64((int64_t)watchers[i].channel_id));
        json_object_object_add(item, "messageTemplate", json_object_new_string(watchers[i].message_template));
        json_object_array_add(array, item);
    }
    json_object_object_add(root, "fileWatchers", array);
    int rc = write_config(config_path, root);
    json_object_put(root);
    return rc;
}

#if defined(__linux__)
typedef struct watched_dir {
    int wd;
    char relative[CR_BOT_FILE_WATCH_PATH_MAX + 1];
} watched_dir;

typedef struct pending_folder {
    char path[CR_BOT_FILE_WATCH_PATH_MAX + 1];
    char name[NAME_MAX + 1];
    char file_name[NAME_MAX + 1];
    double due;
    double last_sent;
    int pending;
} pending_folder;

typedef struct watcher_state {
    cr_bot_file_watcher config;
    int fd;
    char root[PATH_MAX];
    watched_dir *dirs;
    size_t dir_count;
    size_t dir_capacity;
    pending_folder pending[CR_BOT_FILE_WATCH_PENDING_MAX];
    size_t pending_count;
} watcher_state;

static void state_close(watcher_state *state) {
    if (!state) return;
    if (state->fd >= 0) close(state->fd);
    free(state->dirs);
    memset(state, 0, sizeof(*state));
    state->fd = -1;
}

static int state_add_dir(watcher_state *state, const char *full, const char *relative) {
    int wd = inotify_add_watch(state->fd, full,
        IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_DELETE_SELF | IN_MOVE_SELF);
    if (wd < 0) return -1;
    for (size_t i = 0; i < state->dir_count; ++i) {
        if (state->dirs[i].wd == wd) {
            snprintf(state->dirs[i].relative, sizeof(state->dirs[i].relative), "%s", relative ? relative : "");
            return 0;
        }
    }
    if (state->dir_count == state->dir_capacity) {
        size_t cap = state->dir_capacity ? state->dir_capacity * 2 : 32;
        watched_dir *grown = realloc(state->dirs, cap * sizeof(*grown));
        if (!grown) { inotify_rm_watch(state->fd, wd); return -1; }
        state->dirs = grown;
        state->dir_capacity = cap;
    }
    state->dirs[state->dir_count].wd = wd;
    snprintf(state->dirs[state->dir_count].relative, sizeof(state->dirs[state->dir_count].relative), "%s", relative ? relative : "");
    state->dir_count++;
    return 0;
}

static int is_hidden_component(const char *name) { return name && name[0] == '.' && strcmp(name, ".") && strcmp(name, ".."); }

static int copy_name_component(char dst[NAME_MAX + 1], const char *src) {
    if (!dst || !src) return -1;
    size_t n = strlen(src);
    if (!n || n > NAME_MAX) return -1;
    memcpy(dst, src, n + 1);
    return 0;
}

static int state_add_tree(watcher_state *state, const char *full, const char *relative, int queue_existing);

static void state_queue_relative(watcher_state *state, const char *relative_file, int is_directory) {
    if (!state || !relative_file || !*relative_file || is_hidden_component(relative_file)) return;
    const char *slash = strchr(relative_file, '/');
    const char *last_slash = strrchr(relative_file, '/');
    const char *file_name = last_slash ? last_slash + 1 : relative_file;
    if (!*file_name || is_hidden_component(file_name) || strlen(file_name) > NAME_MAX) return;

    char folder_name[NAME_MAX + 1];
    char folder_path[CR_BOT_FILE_WATCH_PATH_MAX + 1];
    if (slash) {
        size_t n = (size_t)(slash - relative_file);
        if (!n || n > NAME_MAX) return;
        memcpy(folder_name, relative_file, n); folder_name[n] = 0;
        if (is_hidden_component(folder_name)) return;
        if (!strcmp(state->config.path, ".")) {
            if (snprintf(folder_path, sizeof(folder_path), "%s", folder_name) >= (int)sizeof(folder_path)) return;
        } else if (snprintf(folder_path, sizeof(folder_path), "%s/%s", state->config.path, folder_name) >= (int)sizeof(folder_path)) return;
    } else if (is_directory) {
        if (copy_name_component(folder_name, relative_file)) return;
        if (!strcmp(state->config.path, ".")) {
            snprintf(folder_path, sizeof(folder_path), "%s", relative_file);
        } else if (snprintf(folder_path, sizeof(folder_path), "%s/%s", state->config.path, relative_file) >= (int)sizeof(folder_path)) return;
    } else {
        if (!strcmp(state->config.path, ".")) {
            const char *leaf = strrchr(state->root, '/');
            if (copy_name_component(folder_name, (leaf && leaf[1]) ? leaf + 1 : "Files")) return;
        } else {
            const char *leaf = strrchr(state->config.path, '/');
            if (copy_name_component(folder_name, leaf ? leaf + 1 : state->config.path)) return;
        }
        snprintf(folder_path, sizeof(folder_path), "%s", state->config.path);
    }

    double now = monotonic_seconds();
    for (size_t i = 0; i < state->pending_count; ++i) {
        if (!strcmp(state->pending[i].path, folder_path)) {
            state->pending[i].pending = 1;
            state->pending[i].due = now + CR_BOT_FILE_WATCH_DEBOUNCE_SECONDS;
            if (copy_name_component(state->pending[i].file_name, file_name)) return;
            return;
        }
    }
    if (state->pending_count >= CR_BOT_FILE_WATCH_PENDING_MAX) return;
    pending_folder *p = &state->pending[state->pending_count++];
    memset(p, 0, sizeof(*p));
    snprintf(p->path, sizeof(p->path), "%s", folder_path);
    if (copy_name_component(p->name, folder_name) ||
        copy_name_component(p->file_name, file_name)) {
        state->pending_count--;
        return;
    }
    p->pending = 1;
    p->due = now + CR_BOT_FILE_WATCH_DEBOUNCE_SECONDS;
}

static int state_add_tree(watcher_state *state, const char *full, const char *relative, int queue_existing) {
    if (state_add_dir(state, full, relative)) return -1;
    DIR *dir = opendir(full);
    if (!dir) return -1;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..") || is_hidden_component(entry->d_name)) continue;
        char child_full[PATH_MAX], child_relative[CR_BOT_FILE_WATCH_PATH_MAX + 1];
        if (path_join(child_full, sizeof(child_full), full, entry->d_name)) continue;
        if (relative && *relative) {
            if (snprintf(child_relative, sizeof(child_relative), "%s/%s", relative, entry->d_name) >= (int)sizeof(child_relative)) continue;
        } else if (snprintf(child_relative, sizeof(child_relative), "%s", entry->d_name) >= (int)sizeof(child_relative)) continue;
        struct stat st;
        if (lstat(child_full, &st) != 0 || S_ISLNK(st.st_mode)) continue;
        if (S_ISDIR(st.st_mode)) (void)state_add_tree(state, child_full, child_relative, queue_existing);
        else if (queue_existing && S_ISREG(st.st_mode)) state_queue_relative(state, child_relative, 0);
    }
    closedir(dir);
    return 0;
}

static const char *relative_for_wd(watcher_state *state, int wd) {
    for (size_t i = 0; i < state->dir_count; ++i) if (state->dirs[i].wd == wd) return state->dirs[i].relative;
    return NULL;
}

static int state_open(watcher_state *state, const char *files_root, const cr_bot_file_watcher *watcher) {
    memset(state, 0, sizeof(*state));
    state->fd = -1;
    state->config = *watcher;
    char root_real[PATH_MAX], target[PATH_MAX], target_real[PATH_MAX];
    if (!realpath(files_root, root_real)) return -1;
    if (!strcmp(watcher->path, ".")) {
        if (snprintf(target, sizeof(target), "%s", root_real) >= (int)sizeof(target)) return -1;
    } else if (path_join(target, sizeof(target), root_real, watcher->path)) return -1;
    if (!realpath(target, target_real)) return -1;
    state->fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (state->fd < 0) return -1;
    snprintf(state->root, sizeof(state->root), "%s", target_real);
    if (state_add_tree(state, target_real, "", 0)) { state_close(state); return -1; }
    return 0;
}

static void state_process_events(watcher_state *state) {
    uint8_t buffer[CR_BOT_FILE_WATCH_EVENT_BUFFER];
    for (;;) {
        ssize_t n = read(state->fd, buffer, sizeof(buffer));
        if (n < 0) { if (errno == EAGAIN || errno == EINTR) return; return; }
        if (n == 0) return;
        for (size_t off = 0; off + sizeof(struct inotify_event) <= (size_t)n;) {
            struct inotify_event *ev = (struct inotify_event *)(buffer + off);
            const char *dir_relative = relative_for_wd(state, ev->wd);
            if (dir_relative && ev->len && ev->name[0] && !is_hidden_component(ev->name)) {
                char relative[CR_BOT_FILE_WATCH_PATH_MAX + 1], full[PATH_MAX];
                if (*dir_relative) {
                    if (snprintf(relative, sizeof(relative), "%s/%s", dir_relative, ev->name) >= (int)sizeof(relative)) goto next;
                } else if (snprintf(relative, sizeof(relative), "%s", ev->name) >= (int)sizeof(relative)) goto next;
                if (path_join(full, sizeof(full), state->root, relative)) goto next;
                if (ev->mask & IN_ISDIR) {
                    if (ev->mask & (IN_CREATE | IN_MOVED_TO)) {
                        state_queue_relative(state, relative, 1);
                        (void)state_add_tree(state, full, relative, (ev->mask & IN_MOVED_TO) != 0);
                    }
                } else if (ev->mask & (IN_CLOSE_WRITE | IN_MOVED_TO)) {
                    struct stat st;
                    if (stat(full, &st) == 0 && S_ISREG(st.st_mode)) state_queue_relative(state, relative, 0);
                }
            }
next:
            off += sizeof(struct inotify_event) + ev->len;
        }
    }
}

static void state_publish_due(watcher_state *state,
                              cr_bot_file_watch_can_publish_cb can_publish,
                              cr_bot_file_watch_publish_cb publish,
                              cr_bot_file_watch_log_cb log_cb,
                              void *opaque) {
    double now = monotonic_seconds();
    for (size_t i = 0; i < state->pending_count; ++i) {
        pending_folder *p = &state->pending[i];
        if (!p->pending || now < p->due) continue;
        p->pending = 0;
        if (p->last_sent > 0 && now - p->last_sent < CR_BOT_FILE_WATCH_COOLDOWN_SECONDS) continue;
        if (can_publish && !can_publish(opaque)) continue;
        if (publish && publish(opaque, &state->config, p->path, p->name, p->file_name) == 0) {
            p->last_sent = now;
            watcher_log(log_cb, opaque, "Bot File Watcher %s announced %s", state->config.path, p->path);
        }
    }
}

static int config_stamp(const char *path, struct timespec *stamp) {
    struct stat st;
    if (stat(path, &st) != 0) { stamp->tv_sec = 0; stamp->tv_nsec = 0; return errno == ENOENT ? 0 : -1; }
#if defined(__APPLE__)
    *stamp = st.st_mtimespec;
#else
    *stamp = st.st_mtim;
#endif
    return 0;
}

static int same_stamp(struct timespec a, struct timespec b) { return a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec; }

static int rebuild_states(const char *config_path, const char *files_root, watcher_state *states, size_t *state_count,
                          cr_bot_file_watch_log_cb log_cb, void *opaque) {
    for (size_t i = 0; i < *state_count; ++i) state_close(&states[i]);
    *state_count = 0;
    cr_bot_file_watcher watchers[CR_BOT_FILE_WATCH_MAX];
    size_t count = 0;
    if (cr_bot_file_watch_load(config_path, files_root, watchers, CR_BOT_FILE_WATCH_MAX, &count)) return -1;
    for (size_t i = 0; i < count; ++i) {
        if (!watchers[i].enabled) continue;
        if (state_open(&states[*state_count], files_root, &watchers[i]) == 0) (*state_count)++;
        else watcher_log(log_cb, opaque, "Bot File Watcher could not watch %s: %s", watchers[i].path, strerror(errno));
    }
    return 0;
}

int cr_bot_file_watch_run(const char *config_path,
                          const char *files_root,
                          cr_bot_file_watch_should_stop_cb should_stop,
                          cr_bot_file_watch_can_publish_cb can_publish,
                          cr_bot_file_watch_publish_cb publish,
                          cr_bot_file_watch_log_cb log_cb,
                          void *opaque) {
    if (!config_path || !files_root || !should_stop || !publish) return -1;
    watcher_state *states = calloc(CR_BOT_FILE_WATCH_MAX, sizeof(*states));
    if (!states) {
        watcher_log(log_cb, opaque, "Bot File Watcher could not allocate watcher state");
        return -1;
    }
    for (size_t i = 0; i < CR_BOT_FILE_WATCH_MAX; ++i) states[i].fd = -1;
    size_t state_count = 0;
    struct timespec last_stamp = {0, 0};
    (void)config_stamp(config_path, &last_stamp);
    if (rebuild_states(config_path, files_root, states, &state_count, log_cb, opaque)) {
        watcher_log(log_cb, opaque, "Bot File Watcher configuration is invalid");
    }
    double next_config_check = monotonic_seconds() + 1.0;
    while (!should_stop(opaque)) {
        struct pollfd fds[CR_BOT_FILE_WATCH_MAX];
        nfds_t nfds = 0;
        for (size_t i = 0; i < state_count; ++i) {
            if (states[i].fd >= 0) { fds[nfds].fd = states[i].fd; fds[nfds].events = POLLIN; fds[nfds].revents = 0; nfds++; }
        }
        (void)poll(fds, nfds, 250);
        for (size_t i = 0; i < state_count; ++i) state_process_events(&states[i]);
        for (size_t i = 0; i < state_count; ++i) state_publish_due(&states[i], can_publish, publish, log_cb, opaque);
        double now = monotonic_seconds();
        if (now >= next_config_check) {
            struct timespec stamp;
            if (config_stamp(config_path, &stamp) == 0 && !same_stamp(stamp, last_stamp)) {
                last_stamp = stamp;
                if (rebuild_states(config_path, files_root, states, &state_count, log_cb, opaque))
                    watcher_log(log_cb, opaque, "Bot File Watcher configuration reload failed");
            }
            next_config_check = now + 1.0;
        }
    }
    for (size_t i = 0; i < state_count; ++i) state_close(&states[i]);
    free(states);
    return 0;
}

#else
int cr_bot_file_watch_run(const char *config_path, const char *files_root,
                          cr_bot_file_watch_should_stop_cb should_stop,
                          cr_bot_file_watch_can_publish_cb can_publish,
                          cr_bot_file_watch_publish_cb publish,
                          cr_bot_file_watch_log_cb log_cb, void *opaque) {
    (void)config_path; (void)files_root; (void)should_stop; (void)can_publish; (void)publish; (void)log_cb; (void)opaque;
    errno = ENOTSUP;
    return -1;
}
#endif
