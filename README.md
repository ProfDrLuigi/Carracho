<p align="center">
  <img src="New%20Logo.png" alt="Carracho" width="320">
</p>

# Carracho

**Carracho is a new native macOS client and server platform for communities built around chat, files, news, messaging and self-hosted servers.**

The project takes the ideas that made Carracho distinctive and rebuilds them as a modern application: a single place for persistent server bookmarks, live chat rooms, threaded discussions, file exchange, private conversations, tracker discovery and full server administration.

The macOS client is written in Swift/AppKit and targets macOS 10.15 or newer. A matching server implementation is included for macOS, together with a native headless C server and tracker for Linux.

### Strong authenticated encryption

Connections between the new Carracho client and a modern Carracho server use a new authenticated transport designed for confidentiality **and** tamper detection. Control traffic and transfer-port operations are protected with **AES-256-GCM**, with fresh session key material negotiated through **ephemeral X25519** key agreement.

The modern transport protects far more than login traffic: chat/control packets, file transfers, News transfers, file search, banners and other modern transfer operations all use authenticated encrypted framing. The client also shows the negotiated cipher in the server information panel, so a modern connection can be identified as `AES-256-GCM` rather than the historical transport.

See the collapsible **Security and modern encryption** section below for the protocol details.


## At a glance


| Component | Implementation | Purpose |
| --- | --- | --- |
| **Carracho** | Swift / AppKit | Native macOS client |
| **Carracho Server** | Swift | Native macOS server |
| **Carracho Server for Linux** | C | Headless server for Linux deployments |
| **Carracho Tracker** | C | Standalone server-directory service |
| **Classic compatibility** | Shared protocol layer | Connects modern Carracho with original/Legacy peers where supported |

The modern client combines chat, files, News, private messages, trackers and server administration in one application. Longer feature and implementation notes are grouped below so the README stays useful as an overview instead of becoming a 500-line wall of text.


<details open>
<summary><strong>The new Carracho client</strong></summary>


The new client is designed around one main window with a persistent sidebar. Servers, trackers and workspaces stay visible while the active content changes, so the application behaves more like a modern communication client than a collection of separate utility windows.

<img width="2032" height="1281" alt="image" src="https://github.com/user-attachments/assets/1e3d2341-d638-48ac-b913-2e05d1698cf8" />


<details>
<summary><strong>Server bookmarks and connections</strong></summary>


Servers are stored as bookmarks in the sidebar. A bookmark contains the server address, port, account, optional nickname/status overrides and connection behaviour.

The client supports:

- multiple saved server bookmarks;
- live bookmark sessions that can remain connected while another server is selected;
- connection-state and notification indicators directly in the sidebar;
- automatic reconnect after a dropped connection;
- connecting a chosen bookmark when Carracho starts;
- per-bookmark control over offline-message reception;
- bookmark import/export;
- passwords stored in the macOS Keychain rather than normal preferences;
- changing a saved account password directly from the bookmark editor.

On a fresh installation a ready-to-use bookmark for `carracho.istation.pw` is created with the `anonymous` account and no password. It is only a first-run default: deleting it does not make it come back later.

<img width="473" height="542" alt="image" src="https://github.com/user-attachments/assets/af177fb6-a6c3-442f-8fcc-989339e69766" />


</details>

<details>
<summary><strong>Overview</strong></summary>


The Overview workspace is the landing page for the selected server. It keeps the important connection and server state close at hand and acts as the starting point for the rest of the client.


</details>

<details>
<summary><strong>Chat rooms</strong></summary>


The **Chat Rooms** workspace provides persistent room navigation and live conversation inside the main window.

Depending on the connected server and account permissions, the client can:

- discover, join, leave and create chat rooms;
- work with room passwords and topics;
- invite users and manage room/member modes;
- show the room participant list alongside the conversation;
- send normal messages, emoji and rich media;
- attach images to modern Carracho conversations;
- attach YouTube links with an inline preview/player and a separate link to the original YouTube page;
- keep joined rooms available while switching to another part of the client.

Features that require a modern server are hidden when the connected server does not advertise the corresponding capability.

<img width="2032" height="1281" alt="image" src="https://github.com/user-attachments/assets/b2fe30a2-ed90-4196-96d8-865fba9ab7dd" />


</details>

<details>
<summary><strong>Files</strong></summary>


The **Files** workspace is a complete browser for the server's published file hierarchy.

It includes:

- directory navigation with history and breadcrumbs;
- server-wide filename search;
- uploads and downloads;
- folder creation and deletion;
- file information and metadata editing where permitted;
- drag-and-drop integration;
- Quick Look preview on macOS;
- Finder integration for completed local downloads;
- support for personal directories, Dropbox-style areas and server-side access rules.

The server keeps incomplete uploads separate from published files. A staged upload is exposed under its final name only after the transfer has completed successfully.

Modern and Classic clients can also be given **separate file roots** when desired. The normal `filesRoot` is the published file tree used by modern Carracho sessions. An optional `legacyFilesRoot` can point Classic/Legacy clients at a completely different directory tree on the same server. If `legacyFilesRoot` is left empty, Classic clients simply use the normal `filesRoot` as well. This makes it possible to keep one shared file area for everybody or deliberately separate the modern and historical client environments without running two servers.

<img width="2032" height="1281" alt="image" src="https://github.com/user-attachments/assets/d739dc00-0d82-4484-b45c-aa0e9c160861" />


</details>

<details>
<summary><strong>Transfer Monitor</strong></summary>


All transfers are collected in a dedicated **Transfers** workspace instead of disappearing into background windows.

The monitor distinguishes between the current Mac's transfers and, when the account is allowed to see them, server-wide transfers. It provides:

- active, waiting, paused and finished filters;
- progress, status and transfer-rate information;
- pause, resume and abort actions;
- removal/cleanup of completed entries;
- deletion of abandoned partial data where appropriate;
- persisted monitor state per bookmark;
- resumed transfers without publishing incomplete server files.

<img width="2032" height="1281" alt="image" src="https://github.com/user-attachments/assets/df8ce88b-bbef-4993-9468-2fb84558304d" />


</details>

<details>
<summary><strong>News</strong></summary>


The modern **News** workspace turns Carracho news into a forum-style discussion system rather than a flat stream.

It supports:

- news categories;
- threads and replies;
- unread/read tracking;
- background polling and sidebar notification badges for connected bookmarks;
- replying to a specific post;
- editing and deleting posts when permitted;
- reactions;
- image attachments;
- YouTube attachments with inline playback;
- per-category read/post policy;
- modern account permission for posting news.

A separate **Classic News** view keeps the traditional flat-news stream available where it is needed, while threaded News is the primary interface in the new client.

<img width="2032" height="1281" alt="image" src="https://github.com/user-attachments/assets/8d22338e-01d3-4641-935e-a3cd708e6381" />


</details>

<details>
<summary><strong>Message Center</strong></summary>


Private communication lives in the **Message Center** rather than transient pop-up windows.

The client keeps conversations locally so they remain useful after switching workspaces or restarting the app. It includes:

- conversation history;
- unread counters;
- search;
- new-message composition;
- per-conversation cleanup/deletion;
- online private messages;
- modern offline messages for users who are currently disconnected.

Offline messages on the modern server are stored in SQLite with authenticated encryption and are removed from the server after successful delivery/acknowledgement.

<img width="2032" height="1281" alt="image" src="https://github.com/user-attachments/assets/4cd4c78e-08d5-46e7-aa8d-bf5fcaecba78" />


</details>

<details>
<summary><strong>Users and presence</strong></summary>


The client presents connected users as people rather than protocol records. Depending on server capabilities it can display and update:

- nickname and account identity;
- presence/sleep state;
- status message;
- e-mail and About Me information;
- avatar/picture;
- account/group colour;
- extended user information.

Accounts with the appropriate rights can also disconnect or ban users and send broadcasts.


</details>

<details>
<summary><strong>Tracker browser</strong></summary>


Trackers provide a decentralized server directory, and the new client gives them a proper browser in the sidebar.

Tracker bookmarks can be added, edited and removed independently from server bookmarks. Results refresh automatically and a server can be opened directly from the tracker listing.

A fresh client starts with `carracho.istation.pw` as its initial tracker. As with the default server bookmark, this is only created once and can be removed permanently.

<img width="1636" height="980" alt="image" src="https://github.com/user-attachments/assets/33c42b60-9306-4258-ac8d-d5ae97373dc1" />


</details>

<details>
<summary><strong>Administration</strong></summary>


Administration is integrated into the same client. Pages appear according to the permissions of the connected account, instead of forcing administrators into a separate tool.

The current administration workspaces include:

- **Accounts** — users, groups, per-account overrides, colours and permissions;
- **News Categories** — categories, retention and access policy;
- **Server Info** — server identity, description and banner;
- **Trackers** — publication, tracker targets, privacy and advertised bandwidth class;
- **Server Log** — protocol and runtime activity;
- **Events** — user activity audit trail;
- **Bot** — local Bot runtime, automatic greeting, command rules and RSS/Atom feeds;
- **Advanced** — limits, file/search settings, IP rules, authentication mode and storage-related options;
- **Agreement** — login agreement text;
- **Statistics** — server and transfer counters.

The permission model also includes new account-level rights such as **Post News**, allowing modern server features to be controlled independently and extended over time.

<img width="1636" height="980" alt="image" src="https://github.com/user-attachments/assets/4df5ed2f-72f2-41ca-91ab-c70f3a2b1ff3" />


</details>

<details>
<summary><strong>Server Bot</strong></summary>


Modern Carracho servers include a **local server Bot** that runs as a server-owned session rather than as a normal network login. Administrators can control it from the **Bot** page in the client without editing configuration files by hand.

The Bot administration page provides:

- enable/disable control for the local Bot;
- an optional automatic greeting for newly connected users;
- configurable greeting text with **`{name}`** and **`{login}`** placeholders;
- persistent command/response rules, each with its own enable/disable switch;
- RSS/Atom feed management with per-feed target room, polling interval, summary length and image setting;
- a feed test action that publishes the fetched article into **Public** using the same rendering path as a normal RSS post.

<img width="1961" height="1378" alt="image" src="https://github.com/user-attachments/assets/946d4e62-f032-45df-84e3-c9a0a8e85a84" />

#### Bot commands

Command rules are simple server-side responses rather than a scripting language. A rule can map a command such as `Hello` to a response such as `Hello {name}, how are you?`.

In a Conference the Bot is addressed with `#` at the beginning of the message:

```text
#Hello
```

A direct Private Message to the Bot does not need the prefix:

```text
Hello
```

The Bot replies in the **same Conference** in which it was addressed, or directly to the sender for a Private Message. If necessary it joins the target Conference first and follows the normal speaking permissions of that room. Sending a Bot message also wakes the Bot from its sleeping presence state.

#### RSS and Atom feeds

The Bot can monitor multiple **RSS 2.0** and **Atom** feeds and publish newly discovered articles into configured Conferences. Each feed can independently define:

- enabled/disabled state;
- display name;
- RSS/Atom URL;
- target Conference;
- polling interval;
- maximum summary length;
- whether an article image should be included when the feed provides one.

MacRumors and Tarnkappe are available as convenient presets in the administration UI, but feeds are not provider-specific and arbitrary compatible RSS/Atom URLs can be added.

For each new article the Bot publishes the headline, a cleaned and shortened description, the original article link and, when enabled and available, an image stored through the normal Carracho media system. Common feed boilerplate such as WordPress “appeared first on” footers is removed from the summary.

Feed state is persistent. On the first successful poll of a newly configured feed, existing items are recorded as already seen instead of being dumped into a room as an old backlog. Later polls publish only unseen items, and servers use `ETag` / `Last-Modified` conditional requests when the feed origin supports them.

RSS fetching is deliberately restricted to HTTP/HTTPS and rejects local or reserved network destinations, unsafe redirects, oversized responses and stalled requests. This allows administrators to add external feeds without turning the Bot into an accidental internal-network fetch proxy.


</details>

<details>
<summary><strong>Settings, appearance and notifications</strong></summary>


The client has its own settings window with **General** and **Sounds** sections.

General settings cover the global client identity, avatar, About Me information and the default download destination. Sounds can be configured per event, including custom imported sound files, volume and macOS notifications.

The application also provides system/light/dark appearance choices, English and German localization, and Sparkle-based update support.

<img width="758" height="760" alt="image" src="https://github.com/user-attachments/assets/2edbb6ee-d60a-4870-9c9e-548c44ba99ed" />
<img width="776" height="765" alt="image" src="https://github.com/user-attachments/assets/7db9d6f1-fb7d-435d-ba51-1a8cecb1eada" />


</details>

</details>


<details>
<summary><strong>Security and modern encryption</strong></summary>


Security is a first-class part of the new Carracho client/server protocol. When two modern Carracho peers connect, the client negotiates the modern authenticated transport automatically. It does not merely replace one cipher with another: the handshake, key separation, frame authentication and password storage model are all different from the historical transport.

### Authenticated session handshake

Each modern connection creates fresh **ephemeral X25519** key pairs on the client and server. The shared secret is combined with the authenticated login session material and a fresh 32-byte server session salt to derive a transport master key.

The server also authenticates the handshake transcript with **HMAC-SHA256**. The authenticator covers the login challenge, both X25519 public keys and the session salt. The client verifies this before accepting the modern transport. A connection that cannot complete that authenticated negotiation is not silently accepted as a modern encrypted session.

Because the X25519 keys are ephemeral and newly generated for a connection, transport keys are not static server keys reused from session to session.

### HKDF-SHA256 key derivation and key separation

Carracho derives 256-bit transport keys using **HKDF-SHA256**. Separate keys are produced for the two directions of the control channel:

- client → server;
- server → client.

Transfer connections receive their own derived keys as well. Their derivation is bound to the session salt, a fresh per-transfer 16-byte nonce, the transfer operation and the traffic direction. A file download therefore does not reuse the same AES key material as a control packet, a News upload or traffic flowing in the opposite direction.

### AES-256-GCM authenticated framing

Modern control and transfer traffic is protected with **AES-256-GCM**. Every frame carries a 128-bit authentication tag. The frame length, protocol domain and monotonic sequence number are authenticated as additional data, so modifying ciphertext or authenticated frame metadata causes verification to fail rather than producing unauthenticated plaintext.

Each direction keeps its own sequence counter. The receiver requires exactly the expected sequence number, providing protection against replay, duplication and attempts to splice authenticated frames into a different position in the stream. Control and transfer traffic also use separate protocol domains when authenticated.

The authenticated transport is used for modern:

- control/session traffic and chat commands;
- file uploads and downloads;
- News article transfers;
- media transfer operations;
- file search;
- banner transfer;
- other operations carried over the transfer connection.

In other words, encryption is not a decorative lock icon applied only to the login form. The actual application traffic is encrypted and authenticated on the wire.

### Password protection on the server

Modern server accounts use versioned **PBKDF2-HMAC-SHA256** password verifiers with a random 16-byte salt, a 256-bit derived value and currently **210,000 iterations**. Verification is performed with a constant-time comparison. The stored verifier format is parameterized so the work factor can be raised in the future without changing the account schema.

The server can run in `modernOnly` authentication mode. In that mode password-equivalent material needed only for old clients is removed from persisted accounts, leaving the modern password verifier as the authentication representation.

### Encrypted offline-message storage

Offline messages stored by the modern server are also protected at rest. Their payloads are sealed with **AES-GCM** using a server-side 256-bit key, and message/account identity is included as authenticated additional data. A modified stored message therefore fails authentication instead of being delivered as valid plaintext.

### What this security model means

For a modern client talking to a modern server, Carracho provides authenticated encryption between the client and server: passive network observers cannot read protected application traffic, and modified authenticated frames are rejected.

This is **transport encryption between client and server**, not end-to-end encryption between individual users. The server necessarily processes chat, News, files and messages in order to provide the Carracho service.


</details>


<details>
<summary><strong>Server options</strong></summary>


The repository contains two implementations of the current Carracho server:

### Carracho Server for macOS

<img width="1032" height="804" alt="image" src="https://github.com/user-attachments/assets/9f8ad5ed-4767-4309-a63e-1f454399317d" />

The Xcode project includes the **Carracho Server** target. It uses the same Swift server core/runtime as the client-side development environment and stores its instance under:

```text
~/Library/Application Support/Carracho/Server/
```

The normal layout is:

```text
Server/
├── etc/
│   ├── carracho-server.json
│   └── carracho-bot.json
├── db/
│   ├── server.db
│   ├── file-index.db
│   └── bot-rss.db
├── logs/
│   └── carracho-server.log
└── ...
```

### Native Linux server

`ServerLinux/` contains a native C implementation intended for headless deployment. It does not require a Swift runtime and uses OpenSSL, json-c, SQLite, libcurl and libxml2.

Compilation of the native Linux components is documented in the **Building on Linux** section below.

The server listens on the configured control port, normally `6700`; the adjacent port is used for transfer connections. The standalone tracker defaults to port `6702`.

### First server start

A fresh server database contains two initial accounts:

- `admin` — administrator account, initially with an empty password;
- `anonymous` — restricted guest account, initially with an empty password.

Change the administrator password before exposing a new server to an untrusted network.

### Bot configuration and persistence

The Bot has its own persistent configuration in `etc/carracho-bot.json`. The macOS and native Linux server implementations use the same conceptual settings so Bot administration behaves consistently on both platforms.

A minimal configuration looks like this:

```json
{
  "enabled": false,
  "avatarPath": "etc/carracho-bot-avatar.png",
  "greetNewUsers": false,
  "greetingTemplate": "Welcome, {name}! Nice to have you here.",
  "commandRules": [],
  "rssFeeds": []
}
```

Normal administration should be done through the Carracho client's **Administration → Bot** page. The JSON file remains useful for deployment, backups and headless server provisioning.

Command rules and RSS feed definitions are stored in this Bot configuration. RSS polling state and seen-item tracking are stored separately in `db/bot-rss.db`, so restarting the server does not cause previously seen articles to be published again.

The main runtime configuration lives in `etc/carracho-server.json`. A typical configuration contains the server name, description, port, published file roots, authentication mode, connection/transfer limits, search exclusions, news expiration settings and tracker publication settings.

Two file-root settings are available:

- `filesRoot` — the primary published file tree used by modern Carracho clients;
- `legacyFilesRoot` — an optional second tree used only by Classic/Legacy client sessions.

When `legacyFilesRoot` is empty, Classic/Legacy sessions fall back to `filesRoot`. When it is configured, the server selects the appropriate root automatically from the negotiated client transport. Both roots may point at separate disks or mounted filesystems.

For example:

```json
{
  "filesRoot": "../Files",
  "legacyFilesRoot": "../Files-Legacy"
}
```

The SQLite databases remain in the fixed `db/` directory beside the server installation. The published file trees are independent of the database location.


</details>


<details>
<summary><strong>Tracker</strong></summary>


<img width="1032" height="804" alt="image" src="https://github.com/user-attachments/assets/a5ca73e7-2b46-4077-8bd1-22d96825d375" />

`TrackerLinux/` contains the native tracker service. It is built together with the native server by the Linux build described below, or separately with `make tracker`.

Start the compiled tracker directly with:

```sh
.build/linux/carracho-tracker --port 6702
```

Server registrations expire when they are no longer refreshed.


</details>


<details>
<summary><strong>A note about Classic Carracho compatibility</strong></summary>


Compatibility with original Carracho software is intentionally treated as a bridge, not as the definition of the new project.

The practical side effect of keeping the protocol lineage intact is useful:

- the new macOS client can connect to many original/Classic Carracho servers;
- the modern server can accept original Carracho clients when `authenticationMode` is `legacyCompatible`;
- Classic trackers, files, chat, user administration and other reconstructed protocol areas remain available;
- when a Classic peer is detected, modern-only capabilities are hidden or mapped to the older behaviour automatically;
- a server can optionally expose a separate `legacyFilesRoot` to Classic clients while modern clients continue to use the primary `filesRoot`.

Classic connections use the historical transport and the limits of the historical protocol. Features invented for the new platform, such as modern authenticated transport, threaded-News extensions, reactions, rich-media capability negotiation, offline-message extensions and new account permissions, require a modern Carracho peer.

Servers can also be configured as `modernOnly`. In that mode the compatibility password material required by original clients is not retained, so Classic authentication is deliberately unavailable.


</details>


<details>
<summary><strong>Building on Linux</strong></summary>


The native Linux build produces the headless **Carracho Server** and **Carracho Tracker**. The macOS GUI client is not part of the Linux build.

### Build requirements

A normal build needs:

- a C11 compiler such as GCC or Clang;
- `make` and a POSIX shell;
- `pkg-config`;
- OpenSSL development headers and libraries;
- json-c;
- SQLite 3;
- libcurl;
- libxml2;
- pthread support supplied by the system C library.

On **Debian 12 or newer** and **Ubuntu 22.04 or newer**, install the required development packages with:

```sh
sudo apt update
sudo apt install \
  build-essential \
  pkg-config \
  libssl-dev \
  libjson-c-dev \
  libsqlite3-dev \
  libcurl4-openssl-dev \
  libxml2-dev
```

These package names are shared by current Debian and Ubuntu releases. Other Linux distributions need the equivalent development packages. The build scripts use `pkg-config` to obtain the compiler and linker flags.

### Build server and tracker

From the repository root:

```sh
make native
```

For the stricter development build used by this project:

```sh
make native-werror
```

`native-werror` builds both components with the normal warning set plus `-Werror`.

The two components can also be built separately:

```sh
make server
make tracker
```

The scripts can be called directly as well:

```sh
./ServerLinux/build.sh
./TrackerLinux/build.sh
```

To use a different C compiler:

```sh
CC=clang make native
```

### Optional WebAdmin helper

The native server itself builds without Python. The bundled WebAdmin frontend uses a separate PyInstaller ONEFILE helper. Only the **build machine** needs Python for this step; the generated helper contains its own Python runtime.

On Debian 12+ and Ubuntu 22.04+:

```sh
sudo apt install python3 python3-venv python3-dev
```

Using `python3-dev` instead of a version-specific `libpython3.x` package keeps the build instructions portable across distributions with different default Python versions.

Build and stage the helper with:

```sh
./ServerLinux/Webinterface/scripts/linux-build-phase.sh \
  .build/linux/libexec/carracho
```

On the first build the script creates a private virtual environment below `ServerLinux/Webinterface/.linux-build/` and installs the required PyInstaller version there.

### Build output

After building the native components, the relevant output is under:

```text
.build/linux/
├── carracho-server
├── carracho-tracker
├── etc/
│   ├── carracho-server.json
│   └── carracho-bot.json
├── db/
└── libexec/
    └── carracho/
        └── carracho-web-admin-helper   # only when the optional helper was built
```

The databases inside `db/` are created as the server runs; they are not prebuilt artifacts.

The server resolves its default configuration relative to its executable, so the development build can be started directly:

```sh
.build/linux/carracho-server
```

An explicit configuration file can also be supplied:

```sh
.build/linux/carracho-server \
  --config .build/linux/etc/carracho-server.json
```

Start the tracker with:

```sh
.build/linux/carracho-tracker --port 6702
```

Remove generated native build output with:

```sh
make clean
```


</details>

<details>
<summary><strong>Building the macOS client</strong></summary>


Requirements: macOS with Xcode.

```sh
xcodebuild -project Carracho.xcodeproj \
  -scheme Carracho \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

For normal development, open `Carracho.xcodeproj` and run the shared **Carracho** scheme.

The project currently targets macOS 10.15 or newer.


</details>


<details>
<summary><strong>Repository layout</strong></summary>


```text
Carracho/
├── Client/          Client-side storage, media, sounds, bookmarks and UI support
├── Gui/             Main macOS workspaces and administration UI
├── LegacyProtocol/  Protocol codecs and compatibility primitives
├── Networking/      Client networking for control, files, news, media and trackers
├── ServerCore/      Server state, persistence, authentication and shared backend
└── ServerRuntime/   Swift server runtime

ServerLinux/          Native C headless server
TrackerLinux/         Native C tracker
Analysis/spec/        Protocol and server documentation
Analysis/tests/       Swift and native integration/regression tests
```


</details>


<details>
<summary><strong>Tests</strong></summary>


Run the Swift/reference protocol suite:

```sh
make swift-tests
```

Run the native C integration suite:

```sh
make c-tests
```

Run the complete local release gate:

```sh
make release-check
```

The native C server and tracker are expected to compile cleanly with `-Wall -Wextra -Wpedantic -Werror`.


</details>


<details>
<summary><strong>Protocol and implementation documentation</strong></summary>


Detailed implementation notes live under `Analysis/spec/`.

Useful starting points are:

- `Analysis/spec/PROTOCOL.md`
- `Analysis/spec/SERVER_RUNTIME.md`
- `Analysis/spec/FILE_BACKEND.md`
- `Analysis/spec/NEWS_BACKEND.md`
- `Analysis/spec/MODERN_SERVER_STATE.md`

These documents describe the wire protocol, persistence model and compatibility work in much more detail than the user-facing overview above.

</details>
