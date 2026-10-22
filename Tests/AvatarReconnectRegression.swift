import Cocoa
@testable import Carracho

let app = NSApplication.shared
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
precondition(MessageCenterStore.defaultDatabaseURL().path.hasPrefix(root.path + "/"),
             "Test profile storage must be isolated from the real Client")

func settle(until condition: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 15)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    precondition(condition(), "Timed out waiting for the local test session")
}
func awaitResult<T>(_ operation: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
    var result: Result<T, Error>?
    operation { result = $0 }
    settle { result != nil }
    return try result!.get()
}

var store = ServerStateStore(url: root.appendingPathComponent("server/db/server.db"))
store.passwordIterations = 1000
let backend = try ModernServerBackend(store: store)
for login in ["viewer", "peer", "late-peer"] {
    _ = try backend.createAccount(ServerAccount(login: login, name: login, mode: .administrator,
                                                permissions: Set(ServerPermission.allCases)), password: "test-password")
}
let server = LegacyServerRuntime(backend: backend, storageRoot: root.appendingPathComponent("server/Files"),
                                supportRoot: root.appendingPathComponent("server"),
                                databaseRoot: root.appendingPathComponent("server/db"))
let port = try server.start(port: 0)
defer { server.stop() }
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
for x in 0..<16 { for y in 0..<16 { bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), atX: x, y: y) } }
let picture = bitmap.representation(using: .png, properties: [:])!
let peer = LegacyControlClient()
let peerLogin: LegacyLoginResult = try awaitResult {
    peer.connect(host: "127.0.0.1", port: port, login: "peer", password: "test-password", nickname: "Peer", completion: $0)
}
defer { peer.disconnect() }
let peerID = peerLogin.session.userID
let _: Void = try awaitResult { peer.updateUser(nickname: Data("Peer".utf8), picture: picture, completion: $0) }
let target = LegacyControlClient()
let controller = ViewController(nibName: nil, bundle: nil)
controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 1360, height: 820))
controller.didProcessLaunchArguments = true
controller.didRestoreMainWindowFrame = true
controller.buildInterface()
let bookmark = ServerBookmark(name: "Reconnect test", host: "127.0.0.1", port: port,
                              login: "viewer", nickname: "Viewer", autoReconnect: true)
let context = ViewController.BookmarkConnectionContext(bookmarkID: bookmark.id, client: target)
controller.serverBookmarks = [bookmark]
controller.bookmarkConnections[bookmark.id] = context
context.snapshot = controller.captureActiveBookmarkSession()
controller.configureClientCallbacks(for: target, bookmarkID: bookmark.id)
// Re-establish a connection while the bookmark remains in the background.
let login: LegacyLoginResult = try awaitResult { completion in
    target.connect(host: bookmark.host, port: port, login: bookmark.login, password: "test-password",
                   nickname: bookmark.nickname) { result in
        if case let .success(login) = result {
            context.reconnectLoginResult = login
            context.needsForegroundBootstrap = true
            controller.prepareBackgroundReconnectSnapshot(bookmark: bookmark, context: context, login: login)
        }
        completion(result)
    }
}
defer { target.disconnect() }
precondition(login.users.first { $0.userID == peerID }?.picture.isEmpty == true,
             "Modern login intentionally omits avatar data")
settle { context.snapshot?.liveUsers[peerID]?.picture == picture }
let latePeer = LegacyControlClient()
let lateLogin: LegacyLoginResult = try awaitResult {
    latePeer.connect(host: "127.0.0.1", port: port, login: "late-peer", password: "test-password",
                     nickname: "Late Peer", completion: $0)
}
defer { latePeer.disconnect() }
settle { context.snapshot?.liveUsers[lateLogin.session.userID] != nil }
let _: Void = try awaitResult { peer.updateStatusMessage(Data("Reconnected".utf8), completion: $0) }
settle { context.snapshot?.userStatusMessages[peerID] == Data("Reconnected".utf8) }

// Activate the background connection just as the bookmark switch does, then finish bootstrap.
controller.client = target
controller.activeBookmarkConnectionID = bookmark.id
controller.connectedBookmarkID = bookmark.id
controller.restoreBookmarkSession(context.snapshot!)
let queued = context.pendingEvents
context.pendingEvents.removeAll()
for event in queued { controller.handle(event) }
controller.completeForegroundBootstrapAfterBackgroundReconnectIfNeeded(bookmark: bookmark, context: context)
precondition(controller.liveUsers[peerID]?.picture == picture,
             "Foreground bootstrap must preserve avatar updates received after the login list")
precondition(controller.liveUsers[lateLogin.session.userID] != nil,
             "Foreground bootstrap must preserve users who arrived after login")
precondition(controller.userStatusMessages[peerID] == Data("Reconnected".utf8),
             "Foreground bootstrap must preserve current statuses")

// Recover a missing avatar through user info even if no further picture event arrives.
controller.liveUsers[peerID]?.picture = Data()
controller.refreshUserStatus(userID: peerID)
settle { controller.liveUsers[peerID]?.picture == picture }
// An older reply cannot erase a newer avatar event.
controller.refreshUserStatus(userID: peerID)
bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
let newerPicture = bitmap.representation(using: .png, properties: [:])!
controller.liveUsers[peerID]?.picture = newerPicture
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
precondition(controller.liveUsers[peerID]?.picture == newerPicture, "Newer user updates must win")
// Park a request in flight: its reply belongs in the snapshot, not the newly selected server.
controller.liveUsers[peerID]?.picture = Data()
controller.refreshUserStatus(userID: peerID)
context.snapshot = controller.captureActiveBookmarkSession()
controller.client = LegacyControlClient()
controller.activeBookmarkConnectionID = nil
controller.liveUsers = [:]
settle { context.snapshot?.liveUsers[peerID]?.picture == picture }
precondition(controller.liveUsers.isEmpty, "Background replies must not change another server's UI")
controller.stopBackgroundNewsPolling(for: context)
print("PASS: background reconnect avatars, current roster/statuses, user-info recovery, newer updates and bookmark isolation")
