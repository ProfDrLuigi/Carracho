import Cocoa
@testable import Carracho

let app = NSApplication.shared

func awaitResult<T>(_ operation: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
    var result: Result<T, Error>?
    operation { result = $0 }
    let deadline = Date(timeIntervalSinceNow: 20)
    while result == nil && Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    guard let result else { fatalError("Timed out waiting for local server") }
    return try result.get()
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("carracho-size-integration-\(UUID().uuidString)")
let files = root.appendingPathComponent("Files")
try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let largeSize: UInt64 = 10 * 1024 * 1024 * 1024 + 123
let largeName = "large.iso"
let largeURL = files.appendingPathComponent(largeName)
precondition(FileManager.default.createFile(atPath: largeURL.path, contents: Data()))
let handle = try FileHandle(forWritingTo: largeURL)
try handle.truncate(atOffset: largeSize)
try handle.close()
// Enough records to exercise modern directory pagination through the actual client.
for index in 0..<2200 {
    let name = String(format: "small-file-with-a-long-name-for-pagination-%04d.txt", index)
    precondition(FileManager.default.createFile(atPath: files.appendingPathComponent(name).path,
                                                contents: Data([1, 2, 3])))
}
let folder = files.appendingPathComponent("folder")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
precondition(FileManager.default.createFile(atPath: folder.appendingPathComponent("child").path, contents: Data()))
var store = ServerStateStore(url: root.appendingPathComponent("db/server.db"))
store.passwordIterations = 1000
let backend = try ModernServerBackend(store: store)
try backend.updateAuthenticationMode(.legacyCompatible)
var settings = backend.snapshot().runtime
settings.legacyFilesRoot = files.path
try backend.updateRuntime(settings)
_ = try backend.createAccount(ServerAccount(login: "size-test", name: "Size Test", mode: .administrator,
                                            permissions: Set(ServerPermission.allCases)), password: "test-password")
let server = LegacyServerRuntime(backend: backend, storageRoot: files, supportRoot: root,
                                databaseRoot: root.appendingPathComponent("db"))
var port = try server.start(port: 0)
defer { server.stop() }
var nativeProcess: Process?
defer {
    if let nativeProcess, nativeProcess.isRunning {
        nativeProcess.terminate()
        nativeProcess.waitUntilExit()
    }
}
if CommandLine.arguments.count > 1 {
    // Run the same client checks against the native C server using an isolated copy
    // of its executable and the interoperable test database created above.
    server.stop()
    // Choose a fresh port pair; the stopped Swift runtime may still have sockets
    // winding down asynchronously on its former port.
    func bindTestSocket(_ port: UInt16) -> (fd: Int32, port: UInt16)? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { Darwin.close(fd); return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }
    var pairFound = false
    for _ in 0..<20 {
        guard let control = bindTestSocket(0) else { continue }
        defer { Darwin.close(control.fd) }
        guard control.port < UInt16.max, let transfer = bindTestSocket(control.port + 1) else { continue }
        Darwin.close(transfer.fd)
        port = control.port
        pairFound = true
        break
    }
    precondition(pairFound, "An unused native server port pair must be available")
    let binary = root.appendingPathComponent("carracho-server")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: binary)
    let configURL = root.appendingPathComponent("etc/carracho-server.json")
    try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let config: [String: Any] = ["serverName": "Size Regression", "description": "Isolated test",
                               "serverPort": Int(port), "filesRoot": files.path, "legacyFilesRoot": files.path,
                               "authenticationMode": "legacyCompatible", "httpAdmin": ["enabled": false],
                               "trackerRegistration": ["enabled": false]]
    try JSONSerialization.data(withJSONObject: config).write(to: configURL)
    let logURL = root.appendingPathComponent("native-test.log")
    precondition(FileManager.default.createFile(atPath: logURL.path, contents: Data()))
    let log = try FileHandle(forWritingTo: logURL)
    let process = Process()
    process.executableURL = binary
    process.arguments = ["--config", configURL.path]
    process.standardOutput = log
    process.standardError = log
    try process.run()
    nativeProcess = process
    let deadline = Date(timeIntervalSinceNow: 20)
    var ready = false
    while process.isRunning && Date() < deadline {
        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        if output.contains("Carracho C server ready:") { ready = true; break }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    guard ready else {
        fatalError("Native server did not start: \((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")")
    }
}

for legacy in [false, true] {
    if legacy {
        // Classic directory replies cannot be paginated, so keep that fixture within one TLV.
        for url in try FileManager.default.contentsOfDirectory(at: files, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("small-file-") {
            try FileManager.default.removeItem(at: url)
        }
    }
    let client = LegacyControlClient()
    client.allowLegacyCrypto = legacy
    defer { client.disconnect() }
    let _: LegacyLoginResult = try awaitResult {
        client.connect(host: "127.0.0.1", port: port, login: "size-test", password: "test-password",
                       nickname: "Size Test", completion: $0)
    }
    let listing: LegacyDirectoryListing = try awaitResult { client.requestDirectory(pathData: Data(), completion: $0) }
    precondition(listing.entries.count == (legacy ? 2 : 2202), "Every page must be merged")
    let large = listing.entries.first { $0.name == Data(largeName.utf8) }!
    let expected = legacy ? UInt64(UInt32.max) : largeSize
    precondition(large.size == expected, "Directory size must match negotiated transport")
    let folderEntry = listing.entries.first { $0.name == Data("folder".utf8) }!
    precondition(folderEntry.isFolder && folderEntry.size == 1, "Folder item counts must remain intact")
    let info: LegacyFileInfoReply = try awaitResult {
        client.requestFileInfo(path: Data(largeName.utf8), completion: $0)
    }
    precondition(info.metadata.size == expected, "File info must match negotiated transport")
    let search = try LegacyFileSearchClient(host: "127.0.0.1", controlPort: port, session: client.transferSession!)
    let results: [LegacyFileSearchResult] = try awaitResult { search.search(text: Data(largeName.utf8), completion: $0) }
    precondition(results.count == 1 && results[0].size == expected && results[0].directoryEntry.size == expected,
                 "Search results must preserve sizes in the same file-list model")
    if !legacy {
        let _: Void = try awaitResult { client.rebuildServerSearchIndex(completion: $0) }
        let deadline = Date(timeIntervalSinceNow: 20)
        var indexReady = false
        repeat {
            let status: LegacySearchIndexStatus = try awaitResult { client.requestSearchIndexStatus(completion: $0) }
            if status.ready && !status.rebuilding { indexReady = true; break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        } while Date() < deadline
        precondition(indexReady, "Search index must finish rebuilding")
        let indexedSearch = try LegacyFileSearchClient(host: "127.0.0.1", controlPort: port, session: client.transferSession!)
        let indexed: [LegacyFileSearchResult] = try awaitResult {
            indexedSearch.search(text: Data(largeName.utf8), completion: $0)
        }
        precondition(indexed.count == 1 && indexed[0].size == largeSize,
                     "Clamped cached index sizes must resolve to exact file sizes")
        let controller = ViewController(nibName: nil, bundle: nil)
        let smallText = controller.cachedFileSizeString(UInt64(UInt32.max))
        let largeText = controller.cachedFileSizeString(large.size)
        precondition(largeText != smallText, "UI size cache must preserve full 64-bit keys")
        print("PASS: modern listing, search, and file info display \(largeText) for \(largeSize) bytes")
    } else {
        print("PASS: Classic listing, search, and file info preserve 32-bit compatibility")
    }
}
