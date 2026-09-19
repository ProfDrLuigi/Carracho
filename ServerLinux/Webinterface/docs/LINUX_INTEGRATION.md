# Linux-Integration

## Zielarchitektur

Der Linux-Server verwaltet den WebAdmin direkt als Child-Prozess:

```text
carracho.service
  |
  +-- carracho-server
        |
        +-- HTTP Admin API :6780
        |
        +-- carracho-web-admin-helper :6781
```

Eine zweite systemd-Unit für den WebAdmin ist nicht notwendig.

## Build

`ServerLinux/build.sh` kompiliert neben dem normalen Servercode auch:

```text
ServerLinux/Webinterface/linux/carracho_web_admin_service.c
```

Der Include-Pfad ist:

```text
ServerLinux/Webinterface/linux
```

Der ONEFILE-Helper wird separat durch:

```bash
ServerLinux/Webinterface/scripts/linux-build-phase.sh
```

gebaut und beim normalen `compile.sh` unter:

```text
.build/linux/libexec/carracho/carracho-web-admin-helper
```

gestaged.

Nach dem Deployment liegt er unter:

```text
/opt/carracho/libexec/carracho/carracho-web-admin-helper
```

## Server-Integration

`ServerLinux/main.c` enthält einen globalen WebAdmin-State:

```c
static cr_web_admin_service g_web_admin;
```

Wenn `httpAdmin.enabled` aktiv ist, wird nach erfolgreichem
`cr_server_init()` der Helper gestartet.

Die Upstream-URL wird aus der HTTP-Admin-Konfiguration erzeugt, zum Beispiel:

```text
http://127.0.0.1:6780/api/v1
```

Der Aufruf erfolgt sinngemäß über:

```c
cr_web_admin_start(
    &g_web_admin,
    NULL,
    config.http_admin_token,
    upstream_url,
    NULL,
    0
);
```

`NULL` als Helper-Pfad aktiviert die automatische Helper-Suche.

`NULL` bzw. `0` für Web-Bind und Web-Port verwenden:

```text
CARRACHO_WEB_ADMIN_BIND
CARRACHO_WEB_ADMIN_PORT
```

oder die Defaults `127.0.0.1:6781`.

Nach Rückkehr aus `cr_server_run()` wird der Child beendet:

```c
cr_web_admin_stop(&g_web_admin);
```

## Token

Der Server lädt `CARRACHO_HTTP_ADMIN_TOKEN` beim Config-Startup. Dieser Token
wird an den Child ausschließlich über dessen Environment weitergereicht.

Empfohlene Datei:

```text
/opt/carracho/etc/carracho-server.env
```

Erzeugen:

```bash
sudo sh -c '
umask 077
printf "CARRACHO_HTTP_ADMIN_TOKEN=%s\n" "$(openssl rand -hex 32)" \
  > /opt/carracho/etc/carracho-server.env
'
sudo chown root:root /opt/carracho/etc/carracho-server.env
sudo chmod 600 /opt/carracho/etc/carracho-server.env
```

systemd-Drop-in:

```ini
[Service]
EnvironmentFile=/opt/carracho/etc/carracho-server.env
```

Danach:

```bash
sudo systemctl daemon-reload
sudo systemctl restart carracho.service
```

## Helper-Suche

Reihenfolge:

1. `CARRACHO_WEB_ADMIN_HELPER`
2. relativ zum laufenden Server
3. `/usr/local/libexec/carracho/carracho-web-admin-helper`
4. `/usr/libexec/carracho/carracho-web-admin-helper`

Beim `/opt/carracho`-Deployment wird automatisch gefunden:

```text
/opt/carracho/libexec/carracho/carracho-web-admin-helper
```

## Shutdown

`cr_web_admin_stop()` sendet zuerst `SIGTERM`, wartet kurz und verwendet nur
bei Bedarf anschließend `SIGKILL`. Der Child bleibt dadurch nicht als
verwaister WebAdmin-Prozess zurück.

## Fehlerverhalten

Kann der Helper nicht gestartet werden, schreibt `carracho-server` eine
Warnung und läuft als Kernserver weiter. Dadurch legt ein fehlender oder
defekter Admin-Helper nicht den eigentlichen Carracho-Dienst lahm.

## Tests

Server:

```bash
systemctl status carracho.service --no-pager
```

Listener:

```bash
ss -lntp | grep -E ':(6780|6781)\b'
```

API:

```bash
TOKEN="$(sudo sed -n 's/^CARRACHO_HTTP_ADMIN_TOKEN=//p' /opt/carracho/etc/carracho-server.env)"
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:6780/api/v1/status
```

WebAdmin:

```bash
curl http://127.0.0.1:6781/healthz
```

Logs:

```bash
journalctl -u carracho.service -f
```

## glibc / Distribution-Kompatibilität

PyInstaller bringt Python mit, aber nicht die libc des Zielsystems. Der
ONEFILE-Helper sollte deshalb auf der ältesten Distribution gebaut werden, die
unterstützt werden soll.

Für den aktuellen Entwicklungsstand wird der Helper unter Debian 13 gebaut und
getestet. Für ältere Zielsysteme sollte ein entsprechend älterer Build-Host
oder Container verwendet werden.
