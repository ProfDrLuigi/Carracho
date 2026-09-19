# Carracho Web Admin – Linux

The Linux WebAdmin is shipped together with the Carracho server as a
PyInstaller ONEFILE helper. The helper contains its own Python runtime, so
Python does not need to be installed on the target system.

The important part: **there is only one systemd service: `carracho.service`.**
The `carracho-server` process starts the WebAdmin itself as a child process
and stops it again when the server shuts down.

## Architecture

```text
systemd
  |
  +-- carracho.service
        |
        +-- /opt/carracho/carracho-server
              |
              +-- HTTP Admin API
              |     127.0.0.1:6780
              |
              +-- Child: carracho-web-admin-helper
                    |
                    +-- Web GUI
                    |     127.0.0.1:6781
                    |
                    +-- Proxy
                          http://127.0.0.1:6780/api/v1
```

A separate `carracho-webadmin.service` is not required.

## Project Structure

```text
ServerLinux/Webinterface/
├── helper/
│   └── web_admin.py
├── web/
│   └── index.html
├── scripts/
│   ├── build-linux-helper.sh
│   ├── linux-build-phase.sh
│   └── verify-linux-helper.sh
├── linux/
│   ├── carracho_web_admin_service.c
│   ├── carracho_web_admin_service.h
│   ├── carracho-server.env.example
│   └── carracho-server.service.d-webadmin.conf
└── docs/
    └── LINUX_INTEGRATION.md
```

The C start/stop layer is integrated directly into `ServerLinux/main.c` and
is compiled into the server through `ServerLinux/build.sh`.

## Build and Deployment

The normal project build remains the single entry point:

```bash
/Users/luigi/Documents/Xcode/Carracho/compile.sh
```

The flow is:

```text
compile.sh
  |
  +-- ServerLinux/build.sh
  |     +-- carracho-server
  |     +-- carracho_web_admin_service.c
  |
  +-- build WebAdmin ONEFILE helper
  |
  +-- copy helper to .build/linux/libexec/carracho
  |
  +-- merge config with the existing live config
  |
  +-- deploy to /opt/carracho
  |
  +-- ensure HTTP Admin token exists
  |
  +-- configure systemd EnvironmentFile
  |
  +-- start carracho.service
        |
        +-- carracho-server starts WebAdmin automatically
```

The installed helper is located at:

```text
/opt/carracho/libexec/carracho/carracho-web-admin-helper
```

## Build Requirements on Debian

Only the build machine needs Python and the PyInstaller prerequisites.
For Debian 13, these packages are particularly relevant:

```bash
sudo apt install python3-venv libpython3.13
```

`build-linux-helper.sh` creates its own virtual environment under
`ServerLinux/Webinterface/.linux-build/` and installs PyInstaller there.
An incomplete or damaged virtual environment is recreated automatically on the
next build.

The `file` package is useful only for an additional diagnostic output and is
not a hard build requirement.

## Ports

Defaults:

```text
Carracho Control         6700
Carracho Transfer        6701
HTTP Admin API           127.0.0.1:6780
Web Admin                127.0.0.1:6781
```

For normal operation, the HTTP Admin API and WebAdmin should only be bound to
`127.0.0.1`.

## carracho-server.json

The HTTP Admin API is enabled in
`/opt/carracho/etc/carracho-server.json`:

```json
"httpAdmin": {
  "enabled": true,
  "bind": "127.0.0.1",
  "port": 6780
}
```

If `httpAdmin.enabled=false`, the WebAdmin child process is not started either.

For Linux/systemd, the bearer token belongs in the environment file and must
be at least 24 characters long.

## Generate the Token

```bash
sudo install -d -m 0755 /opt/carracho/etc

sudo sh -c '
umask 077
printf "CARRACHO_HTTP_ADMIN_TOKEN=%s\n" "$(openssl rand -hex 32)" \
  > /opt/carracho/etc/carracho-server.env
'

sudo chown root:root /opt/carracho/etc/carracho-server.env
sudo chmod 600 /opt/carracho/etc/carracho-server.env
```

This creates a random 64-character hexadecimal token.

Display it with:

```bash
sudo cat /opt/carracho/etc/carracho-server.env
```

Example:

```text
CARRACHO_HTTP_ADMIN_TOKEN=<64-character-token>
```

An existing token should be preserved across deployments. The project
`compile.sh` generates a new token only when no valid token exists yet.

## systemd

Example main unit:

```ini
[Unit]
Description=Carracho Server
After=network.target

[Service]
User=pi
Group=pi
Type=simple
WorkingDirectory=/opt/carracho
ExecStart=/opt/carracho/carracho-server

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

The WebAdmin needs **no second unit**.

A drop-in is enough to provide the token:

```bash
sudo mkdir -p /etc/systemd/system/carracho.service.d

sudo tee /etc/systemd/system/carracho.service.d/webadmin.conf >/dev/null <<'EOF'
[Service]
EnvironmentFile=/opt/carracho/etc/carracho-server.env
EOF
```

Then run:

```bash
sudo systemctl daemon-reload
sudo systemctl enable carracho.service
sudo systemctl restart carracho.service
```

systemd starts only `carracho-server`. That process then starts the WebAdmin
helper itself.

## WebAdmin Child Lifecycle

When HTTP Admin is enabled, the server does the following:

1. Load the startup config including the token.
2. Initialize the Carracho server.
3. Locate the WebAdmin helper under `libexec/carracho`.
4. Start the WebAdmin as a child process.
5. Pass the token exclusively through the child environment.
6. Start the HTTP Admin API and normal server operation.
7. On server shutdown, terminate the WebAdmin with `SIGTERM` first.
8. If the helper does not stop in time, terminate it with `SIGKILL`.

The token is not passed to the helper as a command-line argument and therefore
does not appear in its argv.

## Helper Lookup

`carracho-server` searches for the WebAdmin helper in this order:

1. `CARRACHO_WEB_ADMIN_HELPER`
2. relative to the server binary
3. `/usr/local/libexec/carracho/carracho-web-admin-helper`
4. `/usr/libexec/carracho/carracho-web-admin-helper`

The normal deployment finds this path:

```text
/opt/carracho/libexec/carracho/carracho-web-admin-helper
```

The path can optionally be set explicitly:

```text
CARRACHO_WEB_ADMIN_HELPER=/opt/carracho/libexec/carracho/carracho-web-admin-helper
```

## Optional Environment Variables

In addition to the token, the child launcher understands:

```text
CARRACHO_WEB_ADMIN_BIND
CARRACHO_WEB_ADMIN_PORT
CARRACHO_WEB_ADMIN_HELPER
CARRACHO_HTTP_ADMIN_URL
```

Defaults:

```text
CARRACHO_WEB_ADMIN_BIND=127.0.0.1
CARRACHO_WEB_ADMIN_PORT=6781
```

The server normally builds the upstream URL automatically from
`httpAdmin.bind` and `httpAdmin.port`.

## Check Status

Check only the main unit:

```bash
systemctl status carracho.service --no-pager
```

The journal should contain messages similar to:

```text
carracho-server: WebAdmin helper started (pid=...)
HTTP administration API listening on http://127.0.0.1:6780/api/v1/
```

Check listeners:

```bash
ss -lntp | grep -E ':(6780|6781)\b'
```

Expected:

```text
127.0.0.1:6780
127.0.0.1:6781
```

## Test the HTTP Admin API

```bash
TOKEN="$(sudo sed -n 's/^CARRACHO_HTTP_ADMIN_TOKEN=//p' \
  /opt/carracho/etc/carracho-server.env)"

curl \
  -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:6780/api/v1/status
```

## Test WebAdmin

Health check:

```bash
curl http://127.0.0.1:6781/healthz
```

Browser:

```text
http://127.0.0.1:6781/
```

## nginx Reverse Proxy for External Access

The WebAdmin intentionally listens only on:

```text
127.0.0.1:6781
```

If the interface needs to be reachable externally, nginx should sit in front
of it and terminate TLS.

The GUI uses absolute paths such as:

```text
/proxy/...
/proxy/events
```

For that reason, a dedicated host or subdomain is the cleanest setup, for
example:

```text
https://carracho-admin.example.com/
```

Example for an existing HTTPS vhost:

```nginx
server {
    listen 443 ssl http2;
    server_name carracho-admin.example.com;

    ssl_certificate     /etc/letsencrypt/live/carracho-admin.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/carracho-admin.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:6781;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP $remote_addr;

        # Important for Server-Sent Events under /proxy/events.
        proxy_buffering off;
        proxy_cache off;

        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }
}
```

The WebAdmin currently uses **Server-Sent Events (SSE)** rather than
WebSockets. These WebSocket headers are therefore not required:

```nginx
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
```

If actual WebSockets are added later, those headers can be added as well.

After changing the nginx configuration:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

The interface is then available, for example, at:

```text
https://carracho-admin.example.com/
```

The internal WebAdmin port `6781` does **not** need to be opened in the
firewall. nginx talks to `127.0.0.1:6781` locally.

### Optional: Allow Only Specific IPs

Because this is an administration interface, nginx can additionally restrict
access to specific networks or IP addresses:

```nginx
location / {
    allow 203.0.113.10;
    allow 2001:db8:1234::/64;
    deny all;

    proxy_pass http://127.0.0.1:6781;
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Real-IP $remote_addr;

    proxy_buffering off;
    proxy_cache off;

    proxy_read_timeout 86400;
    proxy_send_timeout 86400;
}
```

### Optional: Additional HTTP Basic Auth

In addition to the Carracho admin authentication, nginx can add a second layer
of protection:

```bash
sudo apt install apache2-utils
sudo htpasswd -c /etc/nginx/carracho-admin.htpasswd admin
```

Then add this to the `location` block:

```nginx
auth_basic "Carracho Administration";
auth_basic_user_file /etc/nginx/carracho-admin.htpasswd;
```

Complete example:

```nginx
location / {
    auth_basic "Carracho Administration";
    auth_basic_user_file /etc/nginx/carracho-admin.htpasswd;

    proxy_pass http://127.0.0.1:6781;
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Real-IP $remote_addr;

    proxy_buffering off;
    proxy_cache off;

    proxy_read_timeout 86400;
    proxy_send_timeout 86400;
}
```

### Running Under a Subpath

A setup such as:

```text
https://example.com/carracho-admin/
```

is not the preferred option with the current GUI because the frontend sends
absolute requests to `/proxy/...`. Without additional nginx rules, those
requests would be routed at the root of the vhost.

If a subpath is required, the interface can be proxied under
`/carracho-admin/` while the API proxy paths are forwarded separately:

```nginx
location = /carracho-admin {
    return 301 /carracho-admin/;
}

location /carracho-admin/ {
    proxy_pass http://127.0.0.1:6781/;
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Real-IP $remote_addr;

    proxy_buffering off;
    proxy_cache off;

    proxy_read_timeout 86400;
    proxy_send_timeout 86400;
}

location /proxy/ {
    proxy_pass http://127.0.0.1:6781/proxy/;
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Real-IP $remote_addr;

    proxy_buffering off;
    proxy_cache off;

    proxy_read_timeout 86400;
    proxy_send_timeout 86400;
}
```

If the same vhost already uses `/proxy/` itself, a dedicated subdomain vhost
is clearly preferable. Otherwise nginx eventually becomes the URI traffic cop
for five different applications, and nobody wins.

## Remote Access

Because the WebAdmin listens only on loopback by default, remote access can
also be provided through an SSH tunnel:

```bash
ssh -L 6781:127.0.0.1:6781 user@server
```

Then open locally:

```text
http://127.0.0.1:6781/
```

The admin interface should not be exposed directly and unencrypted to the
Internet unless there is a very specific reason to do so.

## Logs

Because WebAdmin inherits stdout/stderr from its parent, server and WebAdmin
output end up in the same systemd journal:

```bash
journalctl -u carracho.service -f
```

Last 100 lines:

```bash
journalctl -u carracho.service -n 100 --no-pager
```

There is intentionally no separate `carracho-webadmin.service` journal.

## Common Problems

### carracho.service does not start with httpAdmin enabled

Check the token:

```bash
sudo cat /opt/carracho/etc/carracho-server.env
```

Then run:

```bash
sudo systemctl daemon-reload
sudo systemctl restart carracho.service
journalctl -u carracho.service -n 100 --no-pager
```

### WebAdmin helper is not found

```bash
ls -l /opt/carracho/libexec/carracho/carracho-web-admin-helper
```

The file must exist and be executable.

Otherwise the journal contains:

```text
carracho-server: warning: could not start bundled WebAdmin helper: ...
```

The core server keeps running in this case. A missing WebAdmin helper therefore
does not take down the entire Carracho server.

### Port 6780 is missing

```bash
ss -lntp | grep ':6780'
```

Then check `httpAdmin` in `carracho-server.json` and verify the token.

### Port 6781 is missing

```bash
ss -lntp | grep ':6781'
journalctl -u carracho.service -n 100 --no-pager
```

In particular, look for the `WebAdmin helper started` message or a
`could not start bundled WebAdmin helper` warning.

## Manual Helper Test

The helper can still be built separately for diagnostics:

```bash
./scripts/build-linux-helper.sh
```

and started manually:

```bash
export CARRACHO_HTTP_ADMIN_TOKEN="$(openssl rand -hex 32)"
export CARRACHO_HTTP_ADMIN_URL="http://127.0.0.1:6780/api/v1"

./dist/linux/carracho-web-admin-helper
```

Normally this is not necessary. During regular operation, the WebAdmin process
belongs to the `carracho-server` lifecycle.

## Further Details

See:

```text
docs/LINUX_INTEGRATION.md
```
