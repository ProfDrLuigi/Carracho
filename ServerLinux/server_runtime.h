#ifndef CARRACHO_SERVER_RUNTIME_H
#define CARRACHO_SERVER_RUNTIME_H

#include "server_state.h"
#include <pthread.h>
#include <stdint.h>

#define CR_SERVER_MAX_SESSIONS 2048
#define CR_SERVER_MAX_CHANNELS 256
#define CR_CHANNEL_MAX_MEMBERS 512

typedef struct cr_server cr_server;

typedef struct cr_server_config {
    char instance_root[PATH_MAX];
    char state_path[PATH_MAX];
    char config_path[PATH_MAX];
    cr_startup_persistent_settings persistent;

    /* Optional localhost-first HTTP administration API. */
    int http_admin_enabled;
    char http_admin_bind[64];
    uint16_t http_admin_port;
    char http_admin_token[256];
} cr_server_config;

int cr_server_init(cr_server **out, const cr_server_config *config);
int cr_server_run(cr_server *server);
void cr_server_request_stop(cr_server *server);
void cr_server_signal_stop(cr_server *server);
void cr_server_destroy(cr_server *server);
uint16_t cr_server_port(cr_server *server);
uint16_t cr_server_transfer_port(cr_server *server);

#endif
