#define _POSIX_C_SOURCE 200809L

#include "carracho_web_admin_service.h"

#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

static int cr_is_executable(const char *path)
{
    return path != NULL && path[0] != '\0' && access(path, X_OK) == 0;
}

static int cr_copy_path(char *out, size_t out_size, const char *path)
{
    size_t n;
    if (out == NULL || out_size == 0 || path == NULL) {
        errno = EINVAL;
        return -1;
    }
    n = strlen(path);
    if (n + 1 > out_size) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(out, path, n + 1);
    return 0;
}

static int cr_executable_dir(char *out, size_t out_size)
{
    char exe[PATH_MAX];
    ssize_t n;
    char *slash;

    n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n <= 0 || (size_t)n >= sizeof(exe)) {
        return -1;
    }
    exe[n] = '\0';

    slash = strrchr(exe, '/');
    if (slash == NULL) {
        errno = EINVAL;
        return -1;
    }
    *slash = '\0';
    return cr_copy_path(out, out_size, exe);
}

int cr_web_admin_find_helper(char *out, size_t out_size)
{
    const char *env = getenv("CARRACHO_WEB_ADMIN_HELPER");
    char dir[PATH_MAX];
    char candidate[PATH_MAX];
    int rc;

    if (cr_is_executable(env)) {
        return cr_copy_path(out, out_size, env);
    }

    if (cr_executable_dir(dir, sizeof(dir)) == 0) {
        rc = snprintf(
            candidate,
            sizeof(candidate),
            "%s/../libexec/carracho/carracho-web-admin-helper",
            dir
        );
        if (rc > 0 && (size_t)rc < sizeof(candidate) && cr_is_executable(candidate)) {
            return cr_copy_path(out, out_size, candidate);
        }

        rc = snprintf(
            candidate,
            sizeof(candidate),
            "%s/libexec/carracho/carracho-web-admin-helper",
            dir
        );
        if (rc > 0 && (size_t)rc < sizeof(candidate) && cr_is_executable(candidate)) {
            return cr_copy_path(out, out_size, candidate);
        }
    }

    if (cr_is_executable("/usr/local/libexec/carracho/carracho-web-admin-helper")) {
        return cr_copy_path(
            out, out_size,
            "/usr/local/libexec/carracho/carracho-web-admin-helper"
        );
    }

    if (cr_is_executable("/usr/libexec/carracho/carracho-web-admin-helper")) {
        return cr_copy_path(
            out, out_size,
            "/usr/libexec/carracho/carracho-web-admin-helper"
        );
    }

    errno = ENOENT;
    return -1;
}

int cr_web_admin_is_running(cr_web_admin_service *service)
{
    int status;
    pid_t rc;

    if (service == NULL || service->pid <= 0) {
        return 0;
    }

    rc = waitpid(service->pid, &status, WNOHANG);
    if (rc == 0) {
        return 1;
    }

    service->pid = 0;
    return 0;
}

int cr_web_admin_start(
    cr_web_admin_service *service,
    const char *helper_path,
    const char *token,
    const char *upstream_url,
    const char *bind_address,
    int port
)
{
    const char *env_value;
    char resolved[PATH_MAX];
    char port_buf[32];
    pid_t pid;

    if (service == NULL || token == NULL || strlen(token) < 24) {
        errno = EINVAL;
        return -1;
    }

    if (cr_web_admin_is_running(service)) {
        return 0;
    }

    if (helper_path == NULL || helper_path[0] == '\0') {
        if (cr_web_admin_find_helper(resolved, sizeof(resolved)) != 0) {
            return -1;
        }
        helper_path = resolved;
    } else if (!cr_is_executable(helper_path)) {
        errno = ENOENT;
        return -1;
    }

    if (upstream_url == NULL || upstream_url[0] == '\0') {
        env_value = getenv("CARRACHO_HTTP_ADMIN_URL");
        upstream_url = (env_value != NULL && env_value[0] != '\0')
            ? env_value
            : "http://127.0.0.1:6780/api/v1";
    }
    if (bind_address == NULL || bind_address[0] == '\0') {
        env_value = getenv("CARRACHO_WEB_ADMIN_BIND");
        bind_address = (env_value != NULL && env_value[0] != '\0')
            ? env_value
            : "127.0.0.1";
    }
    if (port <= 0 || port > 65535) {
        env_value = getenv("CARRACHO_WEB_ADMIN_PORT");
        if (env_value != NULL && env_value[0] != '\0') {
            char *end = NULL;
            long env_port;

            errno = 0;
            env_port = strtol(env_value, &end, 10);
            if (errno == 0 && end != env_value && *end == '\0' &&
                env_port > 0 && env_port <= 65535) {
                port = (int)env_port;
            } else {
                errno = EINVAL;
                return -1;
            }
        } else {
            port = 6781;
        }
    }

    if (snprintf(port_buf, sizeof(port_buf), "%d", port) <= 0) {
        errno = EINVAL;
        return -1;
    }

    pid = fork();
    if (pid < 0) {
        return -1;
    }

    if (pid == 0) {
        /*
         * Nur im Child setzen. Damit landet der Token nicht in argv und
         * der Parent muss seine eigene Environment nicht verändern.
         */
        if (setenv("CARRACHO_HTTP_ADMIN_TOKEN", token, 1) != 0 ||
            setenv("CARRACHO_HTTP_ADMIN_URL", upstream_url, 1) != 0 ||
            setenv("CARRACHO_WEB_ADMIN_BIND", bind_address, 1) != 0 ||
            setenv("CARRACHO_WEB_ADMIN_PORT", port_buf, 1) != 0) {
            _exit(126);
        }

        execl(helper_path, helper_path, (char *)NULL);
        _exit(127);
    }

    service->pid = pid;
    return 0;
}

void cr_web_admin_stop(cr_web_admin_service *service)
{
    struct timespec delay = {0, 100000000L}; /* 100 ms */
    int status;
    int i;

    if (service == NULL || service->pid <= 0) {
        return;
    }

    if (kill(service->pid, SIGTERM) != 0 && errno != ESRCH) {
        return;
    }

    for (i = 0; i < 30; ++i) {
        pid_t rc = waitpid(service->pid, &status, WNOHANG);
        if (rc == service->pid || (rc < 0 && errno == ECHILD)) {
            service->pid = 0;
            return;
        }
        nanosleep(&delay, NULL);
    }

    (void)kill(service->pid, SIGKILL);
    (void)waitpid(service->pid, &status, 0);
    service->pid = 0;
}
