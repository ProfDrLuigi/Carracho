#define _XOPEN_SOURCE 700
#define _POSIX_C_SOURCE 200809L
#include "server_runtime.h"
#include "carracho_protocol.h"
#include "carracho_web_admin_service.h"

#include <json-c/json.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

static cr_server *g_server;
static cr_web_admin_service g_web_admin;

static int copy_path(char *out, size_t cap, const char *value) {
    size_t n = value ? strlen(value) : 0;
    if (!n || n >= cap) return -1;
    memcpy(out, value, n + 1);
    return 0;
}

static int join_path(char *out, size_t cap, const char *base, const char *leaf) {
    if (!base || !*base || !leaf || !*leaf) return -1;
    size_t a = strlen(base), b = strlen(leaf);
    int slash = base[a - 1] != '/';
    if (a + (size_t)slash + b + 1 > cap) return -1;
    memcpy(out, base, a);
    if (slash) out[a++] = '/';
    memcpy(out + a, leaf, b + 1);
    return 0;
}

static int parent_directory(char *path) {
    char *slash = strrchr(path, '/');
    if (!slash) return copy_path(path, PATH_MAX, ".");
    if (slash == path) {
        slash[1] = '\0';
        return 0;
    }
    *slash = '\0';
    return 0;
}

static int executable_directory(const char *argv0, char out[PATH_MAX]) {
    char path[PATH_MAX];
    path[0] = '\0';
#if defined(__linux__)
    ssize_t n = readlink("/proc/self/exe", path, sizeof(path) - 1);
    if (n > 0 && (size_t)n < sizeof(path)) path[n] = '\0';
#elif defined(__APPLE__)
    uint32_t size = (uint32_t)sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) path[0] = '\0';
#endif
    if (!path[0]) {
        if (!realpath(argv0, path)) return -1;
    } else {
        char resolved[PATH_MAX];
        if (realpath(path, resolved)) snprintf(path, sizeof(path), "%s", resolved);
    }
    if (copy_path(out, PATH_MAX, path)) return -1;
    return parent_directory(out);
}

static int ensure_directory(const char *path) {
    if (mkdir(path, 0755) == 0 || errno == EEXIST) return 0;
    return -1;
}

static int migrate_file_if_needed(const char *old_path, const char *new_path) {
    if (access(new_path, F_OK) == 0 || access(old_path, F_OK) != 0) return 0;
    return rename(old_path, new_path);
}

static int migrate_legacy_database_layout(const char *instance_root, const char *database_dir) {
    if (ensure_directory(database_dir)) return -1;
    static const char *names[] = {
        "server.db", "server.db-wal", "server.db-shm",
        "news.db", "news.db-wal", "news.db-shm",
        "media.db", "media.db-wal", "media.db-shm",
        "file-index.db", "file-index.db-wal", "file-index.db-shm"
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
        char old_path[PATH_MAX], new_path[PATH_MAX];
        if (join_path(old_path, sizeof(old_path), instance_root, names[i]) ||
            join_path(new_path, sizeof(new_path), database_dir, names[i]) ||
            migrate_file_if_needed(old_path, new_path)) return -1;
    }
    return 0;
}

static int config_string(json_object *root, const char *key, const char *fallback,
                         size_t maximum_bytes, char *out, size_t out_cap, int *configured) {
    json_object *value = NULL;
    if (!json_object_object_get_ex(root, key, &value)) {
        if (configured) *configured = 0;
        if (strlen(fallback) >= out_cap) return -1;
        strcpy(out, fallback);
        return 0;
    }
    if (!json_object_is_type(value, json_type_string)) {
        fprintf(stderr, "carracho-server: config field '%s' must be a string\n", key);
        return -1;
    }
    const char *text = json_object_get_string(value);
    size_t n = text ? strlen(text) : 0;
    if ((maximum_bytes && n > maximum_bytes) || n >= out_cap) {
        fprintf(stderr, "carracho-server: config field '%s' is too long\n", key);
        return -1;
    }
    if (!strcmp(key, "serverName") && n == 0) {
        fprintf(stderr, "carracho-server: config field 'serverName' must not be empty\n");
        return -1;
    }
    memcpy(out, text, n + 1);
    if (configured) *configured = 1;
    return 0;
}

static int config_int(json_object *root, const char *key, int64_t fallback,
                      int64_t minimum, int64_t maximum, int64_t *out) {
    json_object *value = NULL;
    if (!json_object_object_get_ex(root, key, &value)) {
        *out = fallback;
        return 0;
    }
    if (!json_object_is_type(value, json_type_int)) {
        fprintf(stderr, "carracho-server: config field '%s' must be an integer\n", key);
        return -1;
    }
    int64_t number = json_object_get_int64(value);
    if (number < minimum || number > maximum) {
        fprintf(stderr, "carracho-server: config field '%s' must be between %lld and %lld\n",
                key, (long long)minimum, (long long)maximum);
        return -1;
    }
    *out = number;
    return 0;
}

static int config_tracker_registration(json_object *root, cr_startup_persistent_settings *out) {
    json_object *registration = NULL;
    if (!json_object_object_get_ex(root, "trackerRegistration", &registration)) return 0;
    if (!json_object_is_type(registration, json_type_object)) {
        fprintf(stderr, "carracho-server: config field 'trackerRegistration' must be an object\n");
        return -1;
    }
    out->tracker_registration_configured = 1;

    uint32_t flags = 0;
    json_object *value = NULL;
    if (json_object_object_get_ex(registration, "flags", &value)) {
        if (!json_object_is_type(value, json_type_int)) {
            fprintf(stderr, "carracho-server: trackerRegistration.flags must be an integer\n");
            return -1;
        }
        int64_t raw = json_object_get_int64(value);
        if (raw < 0 || (uint64_t)raw > UINT32_MAX) {
            fprintf(stderr, "carracho-server: trackerRegistration.flags must fit UInt32\n");
            return -1;
        }
        flags = (uint32_t)raw;
    }
    if (json_object_object_get_ex(registration, "bandwidthCode", &value)) {
        if (!json_object_is_type(value, json_type_int)) {
            fprintf(stderr, "carracho-server: trackerRegistration.bandwidthCode must be an integer\n");
            return -1;
        }
        int64_t code = json_object_get_int64(value);
        if (code < 0 || code > 255) {
            fprintf(stderr, "carracho-server: trackerRegistration.bandwidthCode must be between 0 and 255\n");
            return -1;
        }
        flags = (flags & 0x00ffffffu) | ((uint32_t)code << 24);
    }
    if (json_object_object_get_ex(registration, "enabled", &value)) {
        if (!json_object_is_type(value, json_type_boolean)) {
            fprintf(stderr, "carracho-server: trackerRegistration.enabled must be a boolean\n");
            return -1;
        }
        if (json_object_get_boolean(value)) flags |= 0x00800000u;
        else flags &= ~0x00800000u;
    }
    if (json_object_object_get_ex(registration, "private", &value)) {
        if (!json_object_is_type(value, json_type_boolean)) {
            fprintf(stderr, "carracho-server: trackerRegistration.private must be a boolean\n");
            return -1;
        }
        if (json_object_get_boolean(value)) flags |= 0x00400000u;
        else flags &= ~0x00400000u;
    }
    out->tracker_advertisement_flags = flags;

    const char *description = "";
    if (json_object_object_get_ex(registration, "description", &value)) {
        if (!json_object_is_type(value, json_type_string)) {
            fprintf(stderr, "carracho-server: trackerRegistration.description must be a string\n");
            return -1;
        }
        description = json_object_get_string(value);
    }
    if (!description || strlen(description) >= sizeof(out->tracker_description)) {
        fprintf(stderr, "carracho-server: trackerRegistration.description is too long\n");
        return -1;
    }
    uint8_t mac[512]; size_t mac_len = 0;
    if (cr_utf8_to_macroman(description, mac, sizeof(mac), &mac_len) ||
        mac_len > CR_CLASSIC_TRACKER_DESCRIPTION_MAX) {
        fprintf(stderr, "carracho-server: trackerRegistration.description must be MacRoman and at most %d bytes for Classic Tracker\n",
                CR_CLASSIC_TRACKER_DESCRIPTION_MAX);
        return -1;
    }
    snprintf(out->tracker_description, sizeof(out->tracker_description), "%s", description);

    json_object *trackers = NULL;
    if (!json_object_object_get_ex(registration, "trackers", &trackers)) return 0;
    if (!json_object_is_type(trackers, json_type_array)) {
        fprintf(stderr, "carracho-server: trackerRegistration.trackers must be an array\n");
        return -1;
    }
    size_t count = json_object_array_length(trackers);
    if (count > CR_MAX_TRACKERS) {
        fprintf(stderr, "carracho-server: trackerRegistration.trackers exceeds %d entries\n", CR_MAX_TRACKERS);
        return -1;
    }
    for (size_t i = 0; i < count; ++i) {
        json_object *item = json_object_array_get_idx(trackers, i);
        if (!item || !json_object_is_type(item, json_type_object)) {
            fprintf(stderr, "carracho-server: trackerRegistration.trackers[%zu] must be an object\n", i);
            return -1;
        }
        cr_startup_tracker_setting *dst = &out->trackers[out->tracker_count];
        json_object *field = NULL;
        const char *name = "", *address = "", *reserved = "";

        if (json_object_object_get_ex(item, "name", &field)) {
            if (!json_object_is_type(field, json_type_string)) return -1;
            name = json_object_get_string(field);
        }
        if (!json_object_object_get_ex(item, "address", &field) || !json_object_is_type(field, json_type_string)) {
            fprintf(stderr, "carracho-server: trackerRegistration.trackers[%zu].address must be a string\n", i);
            return -1;
        }
        address = json_object_get_string(field);
        if (!address || !*address) {
            fprintf(stderr, "carracho-server: trackerRegistration.trackers[%zu].address must not be empty\n", i);
            return -1;
        }
        if (json_object_object_get_ex(item, "reservedString", &field)) {
            if (!json_object_is_type(field, json_type_string)) return -1;
            reserved = json_object_get_string(field);
        }

        uint8_t encoded[512]; size_t encoded_len = 0;
        if (cr_utf8_to_macroman(name, encoded, sizeof(encoded), &encoded_len) || encoded_len > 32 ||
            strlen(name) >= sizeof(dst->name)) {
            fprintf(stderr, "carracho-server: trackerRegistration.trackers[%zu].name exceeds Classic limits\n", i);
            return -1;
        }
        if (cr_utf8_to_macroman(address, encoded, sizeof(encoded), &encoded_len) || encoded_len > 64 ||
            strlen(address) >= sizeof(dst->address)) {
            fprintf(stderr, "carracho-server: trackerRegistration.trackers[%zu].address exceeds Classic limits\n", i);
            return -1;
        }
        if (cr_utf8_to_macroman(reserved, encoded, sizeof(encoded), &encoded_len) || encoded_len > 16 ||
            strlen(reserved) >= sizeof(dst->reserved_string)) {
            fprintf(stderr, "carracho-server: trackerRegistration.trackers[%zu].reservedString exceeds Classic limits\n", i);
            return -1;
        }

        snprintf(dst->name, sizeof(dst->name), "%s", name);
        snprintf(dst->address, sizeof(dst->address), "%s", address);
        snprintf(dst->reserved_string, sizeof(dst->reserved_string), "%s", reserved);

        int64_t reserved_value = 0;
        if (json_object_object_get_ex(item, "reservedValue", &field)) {
            if (!json_object_is_type(field, json_type_int)) return -1;
            reserved_value = json_object_get_int64(field);
            if (reserved_value < 0 || (uint64_t)reserved_value > UINT32_MAX) return -1;
        }
        dst->reserved_value = (uint32_t)reserved_value;
        if (json_object_object_get_ex(item, "enabled", &field)) {
            if (!json_object_is_type(field, json_type_boolean)) return -1;
            if (json_object_get_boolean(field)) dst->reserved_value &= ~0x80000000u;
            else dst->reserved_value |= 0x80000000u;
        }
        out->tracker_count++;
    }
    return 0;
}

static int config_search_index_exclusions(json_object *root, cr_search_index_exclusions *out) {
    memset(out, 0, sizeof(*out));
    json_object *value = NULL;
    if (!json_object_object_get_ex(root, "searchIndexExclusions", &value)) return 0;
    if (!json_object_is_type(value, json_type_array)) {
        fprintf(stderr, "carracho-server: config field 'searchIndexExclusions' must be an array of filename/glob strings\n");
        return -1;
    }
    size_t count = json_object_array_length(value);
    if (count > CR_MAX_SEARCH_INDEX_EXCLUSIONS) {
        fprintf(stderr, "carracho-server: searchIndexExclusions exceeds %d patterns\n", CR_MAX_SEARCH_INDEX_EXCLUSIONS);
        return -1;
    }
    for (size_t i = 0; i < count; ++i) {
        json_object *item = json_object_array_get_idx(value, i);
        if (!item || !json_object_is_type(item, json_type_string)) {
            fprintf(stderr, "carracho-server: searchIndexExclusions[%zu] must be a string\n", i);
            return -1;
        }
        const char *pattern = json_object_get_string(item);
        size_t n = strlen(pattern); uint8_t mac[512]; size_t mac_len = 0;
        if (!n || n >= CR_MAX_SEARCH_INDEX_PATTERN || strchr(pattern, '/') || strchr(pattern, '\\') ||
            cr_utf8_to_macroman(pattern, mac, sizeof(mac), &mac_len) || !mac_len || mac_len > 255) {
            fprintf(stderr, "carracho-server: searchIndexExclusions[%zu] must be a non-empty filename/glob below %d bytes without path separators\n", i, CR_MAX_SEARCH_INDEX_PATTERN);
            return -1;
        }
        memcpy(out->patterns[i], pattern, n + 1);
    }
    out->count = count;
    return 0;
}

static int load_startup_config(const char *config_path, const char *instance_root, cr_server_config *config) {
    char resolved_config[PATH_MAX];
    if (!realpath(config_path, resolved_config)) {
        fprintf(stderr, "carracho-server: config file not found: %s\n", config_path);
        return -1;
    }
    json_object *root = json_object_from_file(resolved_config);
    if (!root || !json_object_is_type(root, json_type_object)) {
        fprintf(stderr, "carracho-server: invalid JSON config: %s\n", resolved_config);
        if (root) json_object_put(root);
        return -1;
    }

    char config_dir[PATH_MAX], database_dir[PATH_MAX];
    if (copy_path(config_dir, sizeof(config_dir), resolved_config) || parent_directory(config_dir) ||
        copy_path(config->instance_root, sizeof(config->instance_root), instance_root) ||
        copy_path(config->config_path, sizeof(config->config_path), resolved_config) ||
        join_path(database_dir, sizeof(database_dir), instance_root, "db") ||
        join_path(config->state_path, sizeof(config->state_path), database_dir, "server.db")) {
        fprintf(stderr, "carracho-server: config/instance path is too long\n");
        json_object_put(root);
        return -1;
    }
    if (migrate_legacy_database_layout(instance_root, database_dir)) {
        fprintf(stderr, "carracho-server: could not migrate/create fixed database directory: %s\n", database_dir);
        json_object_put(root);
        return -1;
    }

    json_object *obsolete = NULL;
    if (json_object_object_get_ex(root, "state", &obsolete))
        fprintf(stderr, "carracho-server: config field 'state' is obsolete and ignored; database name/path is fixed to %s\n", config->state_path);

    if (config_string(root, "serverName", "Carracho Server", 255,
                      config->persistent.server_name, sizeof(config->persistent.server_name),
                      &config->persistent.server_name_configured) ||
        config_string(root, "description", "", CR_MAX_IDENTITY_TEXT,
                      config->persistent.description, sizeof(config->persistent.description),
                      &config->persistent.description_configured)) {
        json_object_put(root);
        return -1;
    }

    const char *files_value = "../Files";
    json_object *value = NULL;
    if (json_object_object_get_ex(root, "filesRoot", &value)) {
        if (!json_object_is_type(value, json_type_string) || !*json_object_get_string(value)) {
            fprintf(stderr, "carracho-server: config field 'filesRoot' must be a non-empty string\n");
            json_object_put(root);
            return -1;
        }
        files_value = json_object_get_string(value);
    }
    if (files_value[0] == '/') {
        if (copy_path(config->persistent.files_root, sizeof(config->persistent.files_root), files_value)) {
            fprintf(stderr, "carracho-server: filesRoot path is too long\n");
            json_object_put(root);
            return -1;
        }
    } else if (join_path(config->persistent.files_root, sizeof(config->persistent.files_root), config_dir, files_value)) {
        fprintf(stderr, "carracho-server: filesRoot path is too long\n");
        json_object_put(root);
        return -1;
    }

    config->persistent.legacy_files_root[0] = '\0';
    value = NULL;
    if (json_object_object_get_ex(root, "legacyFilesRoot", &value)) {
        if (!json_object_is_type(value, json_type_string)) {
            fprintf(stderr, "carracho-server: config field 'legacyFilesRoot' must be a string\n");
            json_object_put(root);
            return -1;
        }
        const char *legacy_value = json_object_get_string(value);
        if (legacy_value && *legacy_value) {
            if (legacy_value[0] == '/') {
                if (copy_path(config->persistent.legacy_files_root, sizeof(config->persistent.legacy_files_root), legacy_value)) {
                    fprintf(stderr, "carracho-server: legacyFilesRoot path is too long\n");
                    json_object_put(root);
                    return -1;
                }
            } else if (join_path(config->persistent.legacy_files_root, sizeof(config->persistent.legacy_files_root), config_dir, legacy_value)) {
                fprintf(stderr, "carracho-server: legacyFilesRoot path is too long\n");
                json_object_put(root);
                return -1;
            }
        }
    }

    config->persistent.legacy_compatible = 1;
    value = NULL;
    if (json_object_object_get_ex(root, "authenticationMode", &value)) {
        if (!json_object_is_type(value, json_type_string)) {
            fprintf(stderr, "carracho-server: config field 'authenticationMode' must be a string\n");
            json_object_put(root);
            return -1;
        }
        const char *mode = json_object_get_string(value);
        if (!strcmp(mode, "legacyCompatible")) config->persistent.legacy_compatible = 1;
        else if (!strcmp(mode, "modernOnly")) config->persistent.legacy_compatible = 0;
        else {
            fprintf(stderr, "carracho-server: authenticationMode must be 'legacyCompatible' or 'modernOnly'\n");
            json_object_put(root);
            return -1;
        }
    }

    int64_t number = 0;
    /* Accept the first generated config's old 'port' key as a one-time compatibility alias. */
    if (!json_object_object_get_ex(root, "serverPort", NULL) && json_object_object_get_ex(root, "port", &value) &&
        json_object_is_type(value, json_type_int) && json_object_get_int64(value) > 0) {
        number = json_object_get_int64(value);
        if (number >= 65535) { fprintf(stderr, "carracho-server: config field 'port' must be between 1 and 65534\n"); json_object_put(root); return -1; }
    } else if (config_int(root, "serverPort", 6700, 1, 65534, &number)) { json_object_put(root); return -1; }
    config->persistent.control_port = (uint16_t)number;

    if (config_int(root, "maxConnections", 100, 1, 65535, &number)) { json_object_put(root); return -1; }
    config->persistent.max_connections = (uint16_t)number;
    if (config_int(root, "maxConnectionsPerIP", 5, 1, 65535, &number)) { json_object_put(root); return -1; }
    config->persistent.max_connections_per_ip = (uint16_t)number;
    if (config_int(root, "maxSimultaneousFileTransfers", 20, 1, 65535, &number)) { json_object_put(root); return -1; }
    config->persistent.max_simultaneous_file_transfers = (uint16_t)number;
    if (config_int(root, "maxFileTransfersPerUser", 1, 1, 65535, &number)) { json_object_put(root); return -1; }
    config->persistent.max_file_transfers_per_user = (uint16_t)number;
    if (config_int(root, "maxFolderDownloadDepth", 8, 0, 65535, &number)) { json_object_put(root); return -1; }
    config->persistent.max_folder_download_depth = (uint16_t)number;
    if (config_int(root, "newsExpirationHour", 0, 0, 23, &number)) { json_object_put(root); return -1; }
    config->persistent.news_expiration_hour = (uint8_t)number;
    if (config_int(root, "newsExpirationMinute", 0, 0, 59, &number)) { json_object_put(root); return -1; }
    config->persistent.news_expiration_minute = (uint8_t)number;
    if (config_int(root, "uploadBandwidthLimitBytesPerSecond", 0, 0, INT64_MAX, &number)) { json_object_put(root); return -1; }
    config->persistent.upload_bandwidth_limit_bytes_per_second = (uint64_t)number;
    if (config_int(root, "searchIndexRebuildIntervalHours", 0, 0, UINT32_MAX, &number)) { json_object_put(root); return -1; }
    config->persistent.search_index_rebuild_interval_hours = (uint32_t)number;
    if (config_search_index_exclusions(root, &config->persistent.search_index_exclusions)) { json_object_put(root); return -1; }
    if (config_tracker_registration(root, &config->persistent)) { json_object_put(root); return -1; }

    config->http_admin_enabled = 0;
    snprintf(config->http_admin_bind, sizeof(config->http_admin_bind), "%s", "127.0.0.1");
    config->http_admin_port = 6780;
    config->http_admin_token[0] = '\0';
    json_object *http_admin = NULL;
    if (json_object_object_get_ex(root, "httpAdmin", &http_admin)) {
        if (!json_object_is_type(http_admin, json_type_object)) {
            fprintf(stderr, "carracho-server: config field 'httpAdmin' must be an object\n");
            json_object_put(root);
            return -1;
        }
        json_object *hv = NULL;
        if (json_object_object_get_ex(http_admin, "enabled", &hv)) {
            if (!json_object_is_type(hv, json_type_boolean)) {
                fprintf(stderr, "carracho-server: httpAdmin.enabled must be a boolean\n");
                json_object_put(root);
                return -1;
            }
            config->http_admin_enabled = json_object_get_boolean(hv) ? 1 : 0;
        }
        if (json_object_object_get_ex(http_admin, "bind", &hv)) {
            if (!json_object_is_type(hv, json_type_string) ||
                strlen(json_object_get_string(hv)) >= sizeof(config->http_admin_bind)) {
                fprintf(stderr, "carracho-server: httpAdmin.bind must be a short IPv4 address string\n");
                json_object_put(root);
                return -1;
            }
            snprintf(config->http_admin_bind, sizeof(config->http_admin_bind), "%s",
                     json_object_get_string(hv));
        }
        if (json_object_object_get_ex(http_admin, "port", &hv)) {
            int64_t port = json_object_get_int64(hv);
            if (!json_object_is_type(hv, json_type_int) || port < 1 || port > 65535) {
                fprintf(stderr, "carracho-server: httpAdmin.port must be between 1 and 65535\n");
                json_object_put(root);
                return -1;
            }
            config->http_admin_port = (uint16_t)port;
        }
        if (json_object_object_get_ex(http_admin, "token", &hv)) {
            if (!json_object_is_type(hv, json_type_string) ||
                strlen(json_object_get_string(hv)) >= sizeof(config->http_admin_token)) {
                fprintf(stderr, "carracho-server: httpAdmin.token is invalid or too long\n");
                json_object_put(root);
                return -1;
            }
            snprintf(config->http_admin_token, sizeof(config->http_admin_token), "%s",
                     json_object_get_string(hv));
        }
    }
    const char *http_admin_env_token = getenv("CARRACHO_HTTP_ADMIN_TOKEN");
    if (http_admin_env_token && *http_admin_env_token) {
        if (strlen(http_admin_env_token) >= sizeof(config->http_admin_token)) {
            fprintf(stderr, "carracho-server: CARRACHO_HTTP_ADMIN_TOKEN is too long\n");
            json_object_put(root);
            return -1;
        }
        snprintf(config->http_admin_token, sizeof(config->http_admin_token), "%s", http_admin_env_token);
    }
    if (config->http_admin_enabled && strlen(config->http_admin_token) < 24) {
        fprintf(stderr, "carracho-server: enabled httpAdmin requires a token of at least 24 characters (or CARRACHO_HTTP_ADMIN_TOKEN)\n");
        json_object_put(root);
        return -1;
    }

    if (!config->persistent.server_name_configured || !config->persistent.description_configured) {
        cr_server_state state;
        if (cr_state_open_at_root(&state, config->state_path, instance_root)) {
            fprintf(stderr, "carracho-server: could not open server.db while migrating identity config\n");
            json_object_put(root);
            return -1;
        }
        if (!config->persistent.server_name_configured) {
            size_t server_name_length = strnlen(state.identity.name, sizeof(state.identity.name));
            if (server_name_length >= sizeof(config->persistent.server_name))
                server_name_length = sizeof(config->persistent.server_name) - 1;
            memcpy(config->persistent.server_name, state.identity.name, server_name_length);
            config->persistent.server_name[server_name_length] = '\0';
            json_object_object_add(root, "serverName", json_object_new_string(config->persistent.server_name));
            config->persistent.server_name_configured = 1;
        }
        if (!config->persistent.description_configured) {
            snprintf(config->persistent.description, sizeof(config->persistent.description), "%s", state.identity.description);
            json_object_object_add(root, "description", json_object_new_string(config->persistent.description));
            config->persistent.description_configured = 1;
        }
        cr_state_close(&state);
        if (json_object_to_file_ext(resolved_config, root, JSON_C_TO_STRING_PRETTY) != 0)
            fprintf(stderr, "carracho-server: warning: could not persist migrated serverName/description into %s\n", resolved_config);
    }

    json_object_put(root);
    return 0;
}

static void on_signal(int sig) {
    (void)sig;
    if (g_server) cr_server_signal_stop(g_server);
}

static void usage(FILE *out) {
    fprintf(out, "Usage: carracho-server [--config FILE]\n");
    fprintf(out, "       carracho-server [--config FILE] --init-admin LOGIN --password-stdin\n");
    fprintf(out, "Default config: <binary-dir>/etc/carracho-server.json\n");
    fprintf(out, "Databases are fixed at <binary-dir>/db/server.db, <binary-dir>/db/news.db, <binary-dir>/db/media.db and <binary-dir>/db/file-index.db; startup settings come from the config on every start.\n");
    fprintf(out, "Persistent server log: <binary-dir>/logs/carracho-server.log\n");
}

static uint64_t administrator_permission_bits(void) {
    static const unsigned permissions[] = {
        0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,
        0x18,0x19,0x1c,0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x28,0x2a,0x2c,0x2d,0x2e,0x2f,0x30,0x31
    };
    uint64_t bits = 1ULL;
    for (size_t i = 0; i < sizeof(permissions) / sizeof(permissions[0]); ++i)
        bits |= 1ULL << permissions[i];
    return bits;
}

static int read_password_stdin(char *out, size_t cap) {
    if (!fgets(out, (int)cap, stdin)) return -1;
    size_t n = strlen(out);
    if (n && out[n - 1] == '\n') out[--n] = '\0';
    if (n && out[n - 1] == '\r') out[--n] = '\0';
    if (!n || n > 64) return -1;
    if (!feof(stdin)) {
        int c = fgetc(stdin);
        if (c != EOF) return -1;
    }
    return 0;
}

static int validate_classic_credential(const char *text, size_t maximum) {
    uint8_t mac[512];
    size_t n = 0;
    if (!text || !*text || cr_utf8_to_macroman(text, mac, sizeof(mac), &n)) return -1;
    return n <= maximum ? 0 : -1;
}

static int initialize_admin(const cr_server_config *config, const char *login) {
    char password[128];
    if (validate_classic_credential(login, 63)) {
        fprintf(stderr, "carracho-server: admin login must be 1..63 Classic-compatible bytes\n");
        return 2;
    }
    if (read_password_stdin(password, sizeof(password)) || validate_classic_credential(password, 64)) {
        fprintf(stderr, "carracho-server: password stdin must contain one non-empty Classic-compatible password of at most 64 bytes\n");
        return 2;
    }

    /* cr_server_state is intentionally large (account/newsgroup snapshots live inline).
       Keep it off the process stack so --init-admin does not depend on the host's stack limit. */
    cr_server_state *state = calloc(1, sizeof(*state));
    if (!state) {
        fprintf(stderr, "carracho-server: could not allocate server state\n");
        memset(password, 0, sizeof(password));
        return 1;
    }
    if (cr_state_open_at_root(state, config->state_path, config->instance_root)) {
        fprintf(stderr, "carracho-server: could not open server state\n");
        free(state);
        memset(password, 0, sizeof(password));
        return 1;
    }
    unsigned changed = 0;
    if (cr_state_reconcile_startup_settings(state, &config->persistent, &changed)) {
        fprintf(stderr, "carracho-server: could not reconcile config with server.db\n");
        cr_state_close(state);
        free(state);
        memset(password, 0, sizeof(password));
        return 1;
    }
    if (!state->legacy_compatible) {
        fprintf(stderr, "carracho-server: --init-admin requires legacyCompatible authentication\n");
        cr_state_close(state);
        free(state);
        memset(password, 0, sizeof(password));
        return 1;
    }
    int action = 0;
    const char *group_id = "";
    for (size_t i = 0; i < state->account_group_count; ++i)
        if (state->account_groups[i].mode == CR_MODE_ADMIN) { group_id = state->account_groups[i].id; break; }
    int rc = cr_state_account_upsert(state, "", login, login, password,
                                     administrator_permission_bits(), group_id, 0, 0, &action);
    cr_state_close(state);
    free(state);
    memset(password, 0, sizeof(password));
    if (rc || action != 0) {
        fprintf(stderr, "carracho-server: administrator could not be created (login may already exist)\n");
        return 1;
    }
    fprintf(stdout, "Initialized administrator '%s' in %s\n", login, config->state_path);
    return 0;
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            usage(stdout);
            return 0;
        }
    }

    const char *config_argument = NULL;
    const char *init_admin = NULL;
    int password_stdin = 0;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--config")) {
            if (++i >= argc || !*argv[i]) { usage(stderr); return 2; }
            config_argument = argv[i];
        } else if (!strcmp(argv[i], "--init-admin")) {
            if (++i >= argc || !*argv[i]) { usage(stderr); return 2; }
            init_admin = argv[i];
        } else if (!strcmp(argv[i], "--password-stdin")) {
            password_stdin = 1;
        } else {
            fprintf(stderr, "carracho-server: unknown argument: %s\n", argv[i]);
            usage(stderr);
            return 2;
        }
    }

    char binary_dir[PATH_MAX], default_config_path[PATH_MAX];
    if (executable_directory(argv[0], binary_dir) ||
        join_path(default_config_path, sizeof(default_config_path), binary_dir, "etc/carracho-server.json")) {
        fprintf(stderr, "carracho-server: could not resolve executable/config path\n");
        return 1;
    }
    const char *config_path = config_argument ? config_argument : default_config_path;
    cr_server_config config;
    memset(&config, 0, sizeof(config));
    if (load_startup_config(config_path, binary_dir, &config)) return 1;

    if (init_admin || password_stdin) {
        if (!init_admin || !password_stdin) { usage(stderr); return 2; }
        return initialize_admin(&config, init_admin);
    }

    signal(SIGPIPE, SIG_IGN);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = on_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGTERM, &action, NULL);

    if (cr_server_init(&g_server, &config)) {
        fprintf(stderr, "carracho-server: initialization failed\n");
        return 1;
    }

    if (config.http_admin_enabled) {
        char upstream_url[384];
        const char *upstream_override = getenv("CARRACHO_HTTP_ADMIN_URL");
        const char *upstream_host = config.http_admin_bind;

        if (upstream_override != NULL && upstream_override[0] != '\0') {
            if (snprintf(upstream_url, sizeof(upstream_url), "%s", upstream_override)
                >= (int)sizeof(upstream_url)) {
                fprintf(stderr, "carracho-server: CARRACHO_HTTP_ADMIN_URL is too long\n");
                cr_server_destroy(g_server);
                g_server = NULL;
                return 1;
            }
        } else {
            /*
             * 0.0.0.0 is a valid listen address but not a useful upstream
             * target. The helper runs on the same host, so loop back in that
             * case.
             */
            if (!upstream_host[0] || !strcmp(upstream_host, "0.0.0.0"))
                upstream_host = "127.0.0.1";

            if (snprintf(upstream_url, sizeof(upstream_url),
                         "http://%s:%u/api/v1",
                         upstream_host,
                         config.http_admin_port ? config.http_admin_port : 6780)
                >= (int)sizeof(upstream_url)) {
                fprintf(stderr, "carracho-server: HTTP admin upstream URL is too long\n");
                cr_server_destroy(g_server);
                g_server = NULL;
                return 1;
            }
        }

        if (cr_web_admin_start(
                &g_web_admin,
                NULL,
                config.http_admin_token,
                upstream_url,
                NULL,
                0) != 0) {
            fprintf(stderr,
                    "carracho-server: warning: could not start bundled WebAdmin helper: %s\n",
                    strerror(errno));
        } else {
            fprintf(stdout,
                    "carracho-server: WebAdmin helper started (pid=%ld)\n",
                    (long)g_web_admin.pid);
        }
    }

    int rc = cr_server_run(g_server);
    cr_web_admin_stop(&g_web_admin);
    cr_server_destroy(g_server);
    g_server = NULL;
    return rc ? 1 : 0;
}
