#ifndef CARRACHO_WEB_ADMIN_SERVICE_H
#define CARRACHO_WEB_ADMIN_SERVICE_H

#include <sys/types.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    pid_t pid;
} cr_web_admin_service;

/*
 * Sucht den Helper in dieser Reihenfolge:
 *   1. CARRACHO_WEB_ADMIN_HELPER
 *   2. relativ zum laufenden Server: ../libexec/carracho/...
 *   3. /usr/local/libexec/carracho/...
 *   4. /usr/libexec/carracho/...
 *
 * Rückgabe: 0 bei Erfolg, -1 bei Fehler.
 */
int cr_web_admin_find_helper(char *out, size_t out_size);

/*
 * Startet den WebAdmin als Child-Prozess.
 * Der Token wird ausschließlich über die Child-Environment weitergegeben.
 *
 * helper_path darf NULL sein; dann wird cr_web_admin_find_helper verwendet.
 * upstream_url darf NULL sein -> CARRACHO_HTTP_ADMIN_URL oder
 *                                http://127.0.0.1:6780/api/v1
 * bind_address darf NULL sein -> CARRACHO_WEB_ADMIN_BIND oder 127.0.0.1
 * port <= 0 -> CARRACHO_WEB_ADMIN_PORT oder 6781
 */
int cr_web_admin_start(
    cr_web_admin_service *service,
    const char *helper_path,
    const char *token,
    const char *upstream_url,
    const char *bind_address,
    int port
);

/* SIGTERM, kurze Wartezeit, danach bei Bedarf SIGKILL. */
void cr_web_admin_stop(cr_web_admin_service *service);

/* 1 wenn der Child-Prozess noch lebt, sonst 0. */
int cr_web_admin_is_running(cr_web_admin_service *service);

#ifdef __cplusplus
}
#endif

#endif
