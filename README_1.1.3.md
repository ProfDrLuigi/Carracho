# Carracho 1.1.3

Carracho 1.1.3 focuses on **safer first-run server setup, more capable Files operations, and configurable macOS window-close behaviour**. The macOS client and server are version **1.1.3 (build 14)**, with matching first-run support in the native Linux server and installers.

## Highlights

- Files can now delete multiple selected server items in one operation.
- The Upload dialog can select multiple local files and folders at once and queue them together.
- Added a client setting controlling whether closing the last window quits Carracho or leaves it running in the Dock.
- Fresh server databases now protect the built-in `admin` account with a random initial password before the server can accept connections.
- First-run setup clearly explains that `anonymous` has no password by default and can be given one in Administration → Accounts.
- Linux installation documentation now explicitly requires the server runtime user to have full access to `/opt/carracho` and its contents.
- Updated Carracho and Carracho Server version reporting to **1.1.3 / build 14**.

## Carracho Client 1.1.3

### Multi-select Files operations

The Files browser now applies **Delete** to all selected server items when the account has the required delete permissions for every selected file or folder. A single confirmation covers the batch, delete requests are sent safely one after another, and selecting both a folder and one of its children does not generate a redundant second delete for that child.

Successful deletions are removed from the visible file tree immediately. Individual failures are reported without discarding successful operations from the same batch.

The Upload dialog now allows selecting **multiple local files and/or folders at once**. Every selected item is added to the existing transfer queue, and transfer capacity is refreshed once for the complete batch. Multi-item Finder drag-and-drop uses the same batched enqueue path.

### Configurable red close-button behaviour

The General client settings now include an **App Behavior** option controlling what happens when the last Carracho window is closed with the red macOS close button.

The option defaults to enabled, preserving the historical behaviour: closing the final window quits Carracho. When disabled, the window closes but Carracho remains running in the Dock and existing server sessions remain active. Clicking the Carracho Dock icon brings the main window back. **Quit Carracho** from the application menu still terminates the app normally.

## Carracho Server 1.1.3

### Secure first-run administrator credentials

A genuinely new server database no longer leaves the built-in `admin` account with an empty password until an administrator changes it manually. Before the server runtime can accept connections, Carracho generates a random 128-bit initial password and applies it to the built-in `admin` account.

On macOS, the Server app displays the generated password once in an **Initial Server Credentials** warning and provides a **Copy Password** action. On Linux source installs and fresh Debian package installs, the installer prints the initial administrator login and password before the service is started. In both cases the administrator is explicitly told to change the password immediately after the first login.

The generated plaintext password is not written to a separate credentials file. Existing databases and migrated legacy state are not assigned a new password by this bootstrap logic.

### Anonymous first-run notice

The built-in `anonymous` Guest account intentionally remains passwordless by default. The first-run notice now states this explicitly and explains that an administrator can set a password for `anonymous` under **Administration → Accounts** when passwordless Guest access is not desired.

### Linux runtime permissions

The Linux installation instructions now explicitly state that the user configured to run `carracho-server` must have full read, write, create/remove, and directory-traversal access to the complete `/opt/carracho` tree.

With the standard service this user is `carracho`, so `/opt/carracho` should remain owned appropriately by `carracho:carracho`. Installations using a different systemd `User=` or `Group=` must adjust ownership and permissions accordingly. The documentation explicitly discourages making `/opt/carracho` world-writable.

## Compatibility notes

- Multi-delete and multi-upload are client-side improvements and do not require a new file protocol.
- Existing server databases are not modified by the new first-run password bootstrap.
- `anonymous` remains passwordless unless an administrator explicitly assigns a password.
