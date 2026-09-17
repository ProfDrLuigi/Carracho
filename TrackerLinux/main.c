#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define CARRACHO_TRACKER_DEFAULT_PORT 6702u
#define CARRACHO_TRACKER_EXPIRATION_SECONDS 600
#define CARRACHO_TRACKER_MAX_REGISTRATIONS 4096u
#define CARRACHO_TRACKER_BACKLOG 64

static const uint8_t k_query_magic[4] = {'C','T','Q',1};
static const uint8_t k_registration_magic[4] = {'C','T','T',1};
static const uint8_t k_list_query[3] = {'Q','L','I'};

typedef struct tracker_registration {
    uint8_t ipv4[4];
    uint16_t port;
    uint8_t name_len;
    uint8_t name[255];
    uint8_t description_len;
    uint8_t description[255];
    uint16_t users;
    uint32_t flags;
    time_t last_seen;
} tracker_registration;

typedef struct tracker_state {
    pthread_mutex_t mutex;
    tracker_registration registrations[CARRACHO_TRACKER_MAX_REGISTRATIONS];
    size_t count;
    unsigned expiration_seconds;
} tracker_state;

typedef struct connection_ctx {
    int fd;
    char peer[INET_ADDRSTRLEN];
    tracker_state *state;
} connection_ctx;

static volatile sig_atomic_t g_stop = 0;
static volatile sig_atomic_t g_listener = -1;

static uint16_t read_be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void write_be16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
}

static void write_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

static int read_exact(int fd, void *buffer, size_t length) {
    uint8_t *out = buffer;
    size_t offset = 0;
    while (offset < length) {
        ssize_t n = recv(fd, out + offset, length - offset, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        offset += (size_t)n;
    }
    return 0;
}

static int write_all(int fd, const void *buffer, size_t length) {
    const uint8_t *in = buffer;
    size_t offset = 0;
    while (offset < length) {
#ifdef MSG_NOSIGNAL
        ssize_t n = send(fd, in + offset, length - offset, MSG_NOSIGNAL);
#else
        ssize_t n = send(fd, in + offset, length - offset, 0);
#endif
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        offset += (size_t)n;
    }
    return 0;
}

static void log_line(const char *message, const char *detail) {
    time_t now = time(NULL);
    struct tm tmv;
    char stamp[32];
    localtime_r(&now, &tmv);
    strftime(stamp, sizeof(stamp), "%Y-%m-%dT%H:%M:%S%z", &tmv);
    if (detail && *detail) fprintf(stdout, "%s %s %s\n", stamp, message, detail);
    else fprintf(stdout, "%s %s\n", stamp, message);
    fflush(stdout);
}

static void prune_locked(tracker_state *state, time_t now) {
    size_t dst = 0;
    for (size_t i = 0; i < state->count; ++i) {
        tracker_registration *r = &state->registrations[i];
        if ((unsigned long)(now - r->last_seen) <= state->expiration_seconds) {
            if (dst != i) state->registrations[dst] = *r;
            ++dst;
        }
    }
    state->count = dst;
}

static int compare_registration(const void *a, const void *b) {
    const tracker_registration *left = a;
    const tracker_registration *right = b;
    char ln[256], rn[256];
    memcpy(ln, left->name, left->name_len); ln[left->name_len] = '\0';
    memcpy(rn, right->name, right->name_len); rn[right->name_len] = '\0';
    int c = strcasecmp(ln, rn);
    if (c != 0) return c;
    c = memcmp(left->ipv4, right->ipv4, 4);
    if (c != 0) return c;
    return left->port < right->port ? -1 : left->port > right->port ? 1 : 0;
}

static int handle_query(connection_ctx *ctx) {
    uint8_t operation[3];
    if (read_exact(ctx->fd, operation, sizeof(operation)) != 0 ||
        memcmp(operation, k_list_query, sizeof(operation)) != 0) return -1;

    tracker_registration *snapshot = NULL;
    size_t count = 0;
    pthread_mutex_lock(&ctx->state->mutex);
    prune_locked(ctx->state, time(NULL));
    count = ctx->state->count;
    if (count) {
        snapshot = malloc(count * sizeof(*snapshot));
        if (snapshot) memcpy(snapshot, ctx->state->registrations, count * sizeof(*snapshot));
    }
    pthread_mutex_unlock(&ctx->state->mutex);
    if (count && !snapshot) return -1;
    if (count > 1) qsort(snapshot, count, sizeof(*snapshot), compare_registration);

    uint8_t count_wire[4];
    write_be32(count_wire, (uint32_t)count);
    if (write_all(ctx->fd, count_wire, sizeof(count_wire)) != 0) {
        free(snapshot);
        return -1;
    }

    for (size_t i = 0; i < count; ++i) {
        const tracker_registration *r = &snapshot[i];
        size_t payload_length = 14u + r->name_len + r->description_len;
        if (payload_length > 255u) {
            free(snapshot);
            return -1;
        }
        uint8_t record[256];
        size_t p = 0;
        record[p++] = (uint8_t)payload_length;
        memcpy(record + p, r->ipv4, 4); p += 4;
        write_be16(record + p, r->port); p += 2;
        record[p++] = r->name_len;
        memcpy(record + p, r->name, r->name_len); p += r->name_len;
        record[p++] = r->description_len;
        memcpy(record + p, r->description, r->description_len); p += r->description_len;
        write_be16(record + p, r->users); p += 2;
        write_be32(record + p, r->flags); p += 4;
        if (write_all(ctx->fd, record, p) != 0) {
            free(snapshot);
            return -1;
        }
    }
    free(snapshot);

    char detail[128];
    snprintf(detail, sizeof(detail), "to %s: %zu server%s", ctx->peer, count, count == 1 ? "" : "s");
    log_line("Tracker list served", detail);
    return 0;
}

static int handle_registration(connection_ctx *ctx) {
    tracker_registration incoming;
    memset(&incoming, 0, sizeof(incoming));
    uint8_t fixed[6];
    if (read_exact(ctx->fd, fixed, sizeof(fixed)) != 0) return -1;
    memcpy(incoming.ipv4, fixed, 4);
    incoming.port = read_be16(fixed + 4);

    if (read_exact(ctx->fd, &incoming.name_len, 1) != 0) return -1;
    if (incoming.name_len && read_exact(ctx->fd, incoming.name, incoming.name_len) != 0) return -1;
    if (read_exact(ctx->fd, &incoming.description_len, 1) != 0) return -1;
    if (incoming.description_len && read_exact(ctx->fd, incoming.description, incoming.description_len) != 0) return -1;
    uint8_t tail[6];
    if (read_exact(ctx->fd, tail, sizeof(tail)) != 0) return -1;
    incoming.users = read_be16(tail);
    incoming.flags = read_be32(tail + 2);
    incoming.last_seen = time(NULL);

    if ((size_t)incoming.name_len + incoming.description_len > 241u) return -1;

    pthread_mutex_lock(&ctx->state->mutex);
    prune_locked(ctx->state, incoming.last_seen);
    size_t index = ctx->state->count;
    for (size_t i = 0; i < ctx->state->count; ++i) {
        tracker_registration *r = &ctx->state->registrations[i];
        if (r->port == incoming.port && memcmp(r->ipv4, incoming.ipv4, 4) == 0) {
            index = i;
            break;
        }
    }
    if (index == ctx->state->count) {
        if (ctx->state->count >= CARRACHO_TRACKER_MAX_REGISTRATIONS) {
            pthread_mutex_unlock(&ctx->state->mutex);
            return -1;
        }
        ++ctx->state->count;
    }
    ctx->state->registrations[index] = incoming;
    size_t live_count = ctx->state->count;
    pthread_mutex_unlock(&ctx->state->mutex);

    char name[256];
    memcpy(name, incoming.name, incoming.name_len); name[incoming.name_len] = '\0';
    char detail[640];
    snprintf(detail, sizeof(detail), "from %s: %s (%u users, %zu live)", ctx->peer, name,
             (unsigned)incoming.users, live_count);
    log_line("Tracker registration updated", detail);
    return 0;
}

static void *connection_main(void *opaque) {
    connection_ctx *ctx = opaque;
    uint8_t magic[4];
    int result = -1;
    if (read_exact(ctx->fd, magic, sizeof(magic)) == 0) {
        if (memcmp(magic, k_query_magic, 4) == 0) result = handle_query(ctx);
        else if (memcmp(magic, k_registration_magic, 4) == 0) result = handle_registration(ctx);
    }
    if (result != 0) {
        char detail[128];
        snprintf(detail, sizeof(detail), "from %s", ctx->peer);
        log_line("Tracker connection rejected", detail);
    }
    shutdown(ctx->fd, SHUT_RDWR);
    close(ctx->fd);
    free(ctx);
    return NULL;
}

static void *cleanup_main(void *opaque) {
    tracker_state *state = opaque;
    while (!g_stop) {
        struct timespec wait = {.tv_sec = 1, .tv_nsec = 0};
        nanosleep(&wait, NULL);
        time_t now = time(NULL);
        pthread_mutex_lock(&state->mutex);
        size_t before = state->count;
        prune_locked(state, now);
        size_t after = state->count;
        pthread_mutex_unlock(&state->mutex);
        if (after < before) {
            char detail[96];
            snprintf(detail, sizeof(detail), "%zu registration%s", before - after,
                     before - after == 1 ? "" : "s");
            log_line("Expired", detail);
        }
    }
    return NULL;
}

static void on_signal(int signo) {
    (void)signo;
    g_stop = 1;
    int fd = (int)g_listener;
    if (fd >= 0) shutdown(fd, SHUT_RDWR);
}

static int make_listener(uint16_t port, uint16_t *actual_port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes)) != 0) {
        close(fd); return -1;
    }
#ifdef SO_NOSIGPIPE
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(fd, CARRACHO_TRACKER_BACKLOG) != 0) {
        close(fd); return -1;
    }
    socklen_t len = sizeof(address);
    if (getsockname(fd, (struct sockaddr *)&address, &len) != 0) {
        close(fd); return -1;
    }
    *actual_port = ntohs(address.sin_port);
    return fd;
}

static int parse_port(const char *text, uint16_t *out) {
    char *end = NULL;
    errno = 0;
    unsigned long value = strtoul(text, &end, 10);
    if (errno || !end || *end || value == 0 || value > 65535) return -1;
    *out = (uint16_t)value;
    return 0;
}

static void usage(FILE *stream) {
    fprintf(stream, "Usage: carracho-tracker [--port PORT]\n");
    fprintf(stream, "Default: TCP 6702. Registrations expire after 600 seconds without refresh.\n");
}

int main(int argc, char **argv) {
    uint16_t port = CARRACHO_TRACKER_DEFAULT_PORT;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            usage(stdout); return 0;
        }
        if (!strcmp(argv[i], "--port")) {
            if (++i >= argc || parse_port(argv[i], &port) != 0) {
                fprintf(stderr, "carracho-tracker: invalid or missing --port value\n");
                return 2;
            }
            continue;
        }
        fprintf(stderr, "carracho-tracker: unknown argument: %s\n", argv[i]);
        return 2;
    }

    tracker_state state;
    memset(&state, 0, sizeof(state));
    state.expiration_seconds = CARRACHO_TRACKER_EXPIRATION_SECONDS;
    if (pthread_mutex_init(&state.mutex, NULL) != 0) {
        fprintf(stderr, "carracho-tracker: pthread_mutex_init failed\n");
        return 1;
    }

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = on_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGTERM, &action, NULL);
    signal(SIGPIPE, SIG_IGN);

    uint16_t actual_port = 0;
    int listener = make_listener(port, &actual_port);
    if (listener < 0) {
        fprintf(stderr, "carracho-tracker: listen failed: %s\n", strerror(errno));
        pthread_mutex_destroy(&state.mutex);
        return 1;
    }
    g_listener = listener;

    pthread_t cleanup_thread;
    if (pthread_create(&cleanup_thread, NULL, cleanup_main, &state) != 0) {
        fprintf(stderr, "carracho-tracker: cleanup thread failed\n");
        close(listener);
        pthread_mutex_destroy(&state.mutex);
        return 1;
    }

    char ready[96];
    snprintf(ready, sizeof(ready), "port=%u", (unsigned)actual_port);
    log_line("Carracho tracker ready", ready);

    while (!g_stop) {
        struct sockaddr_in peer_address;
        socklen_t peer_len = sizeof(peer_address);
        int client = accept(listener, (struct sockaddr *)&peer_address, &peer_len);
        if (client < 0) {
            if (errno == EINTR) continue;
            if (g_stop || errno == EBADF || errno == EINVAL) break;
            fprintf(stderr, "carracho-tracker: accept failed: %s\n", strerror(errno));
            break;
        }
#ifdef SO_NOSIGPIPE
        int yes = 1;
        (void)setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
        connection_ctx *ctx = calloc(1, sizeof(*ctx));
        if (!ctx) { close(client); continue; }
        ctx->fd = client;
        ctx->state = &state;
        if (!inet_ntop(AF_INET, &peer_address.sin_addr, ctx->peer, sizeof(ctx->peer)))
            strcpy(ctx->peer, "unknown");
        pthread_t thread;
        if (pthread_create(&thread, NULL, connection_main, ctx) != 0) {
            close(client); free(ctx); continue;
        }
        pthread_detach(thread);
    }

    g_stop = 1;
    g_listener = -1;
    shutdown(listener, SHUT_RDWR);
    close(listener);
    pthread_join(cleanup_thread, NULL);
    pthread_mutex_destroy(&state.mutex);
    log_line("Tracker stopped", NULL);
    return 0;
}
