#if CARRACHO_SERVER
import Foundation
import Darwin

struct CarrachoDaemonSnapshot: Codable, Equatable {
    enum Kind: String, Codable { case server, tracker }

    var kind: Kind
    var pid: Int32
    var updatedAt: Date
    var isRunning: Bool
    var port: UInt16?
    var transferPort: UInt16?
    var connectedClients: Int
    var activeFileTransfers: Int
    var registeredServers: Int
}

enum CarrachoDaemonKind: String, CaseIterable {
    case server
    case tracker

    var label: String {
        switch self {
        case .server: return "com.carracho.server"
        case .tracker: return "com.carracho.tracker"
        }
    }

    var argument: String {
        switch self {
        case .server: return "--daemon-server"
        case .tracker: return "--daemon-tracker"
        }
    }

    var statusFileName: String {
        switch self {
        case .server: return "server-status.json"
        case .tracker: return "tracker-status.json"
        }
    }
}

struct CarrachoLaunchDaemonStatus {
    var installed: Bool
    var loaded: Bool
    var running: Bool
    var snapshot: CarrachoDaemonSnapshot?
}

enum CarrachoLaunchDaemonError: LocalizedError {
    case noExecutable
    case privilegeCommand(String)
    case invalidSnapshot

    var errorDescription: String? {
        switch self {
        case .noExecutable: return L("The Carracho Server executable could not be located.")
        case let .privilegeCommand(message): return message.isEmpty ? L("The privileged daemon operation failed.") : message
        case .invalidSnapshot: return L("The daemon status file is invalid.")
        }
    }
}

/// Installs root-owned launchd definitions, while the actual jobs run as the current macOS user.
/// That gives the daemons boot/login independence without changing ownership of the user's server DB/files.
final class CarrachoLaunchDaemonManager {
    static let daemonDirectoryURL = URL(fileURLWithPath: "/Library/Application Support/Carracho/Daemon", isDirectory: true)
    static let installedAppURL = daemonDirectoryURL.appendingPathComponent("Carracho Server.app", isDirectory: true)
    static let binaryURL = installedAppURL.appendingPathComponent("Contents/MacOS/Carracho Server", isDirectory: false)
    static let launchDaemonsURL = URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)

    func status(for kind: CarrachoDaemonKind, rootURL: URL) -> CarrachoLaunchDaemonStatus {
        let installed = FileManager.default.fileExists(atPath: plistURL(for: kind).path)
        let snapshot = readSnapshot(for: kind, rootURL: rootURL)
        let heartbeatAlive: Bool
        if let snapshot {
            heartbeatAlive = Date().timeIntervalSince(snapshot.updatedAt) < 4.0 && processIsAlive(snapshot.pid)
        } else {
            heartbeatAlive = false
        }
        // A normal user can usually inspect system launchd jobs, but a live heartbeat is an
        // equally strong fallback and also covers the intentionally idle tracker daemon.
        let loaded = launchctlPrint(kind) == 0 || (installed && heartbeatAlive)
        let running = loaded && heartbeatAlive && snapshot?.isRunning == true
        return CarrachoLaunchDaemonStatus(installed: installed, loaded: loaded, running: running, snapshot: snapshot)
    }

    /// Cheap display status derived from the installed plist and the daemon heartbeat.
    /// Unlike `status(for:rootURL:)` this never launches `launchctl`, so it is safe to use
    /// from frequent UI refreshes and menu-opening paths on the main thread.
    func heartbeatStatus(for kind: CarrachoDaemonKind, rootURL: URL) -> CarrachoLaunchDaemonStatus {
        let installed = FileManager.default.fileExists(atPath: plistURL(for: kind).path)
        let snapshot = readSnapshot(for: kind, rootURL: rootURL)
        let heartbeatAlive: Bool
        if let snapshot {
            heartbeatAlive = Date().timeIntervalSince(snapshot.updatedAt) < 4.0 && processIsAlive(snapshot.pid)
        } else {
            heartbeatAlive = false
        }
        let loaded = installed && heartbeatAlive
        let running = loaded && snapshot?.isRunning == true
        return CarrachoLaunchDaemonStatus(installed: installed, loaded: loaded, running: running, snapshot: snapshot)
    }

    func install(_ kind: CarrachoDaemonKind, rootURL: URL) throws {
        let sourceAppURL = Bundle.main.bundleURL.standardizedFileURL
        let sourceExecutable = sourceAppURL.appendingPathComponent("Contents/MacOS/Carracho Server", isDirectory: false)
        guard sourceAppURL.pathExtension == "app", FileManager.default.isExecutableFile(atPath: sourceExecutable.path) else {
            throw CarrachoLaunchDaemonError.noExecutable
        }

        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("carracho-daemon-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }

        let stagedPlist = temporary.appendingPathComponent("\(kind.label).plist")
        let logs = rootURL.appendingPathComponent("logs", isDirectory: true)
        try manager.createDirectory(at: logs, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": kind.label,
            "ProgramArguments": [Self.binaryURL.path, kind.argument, "--server-root=\(rootURL.standardizedFileURL.path)"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "UserName": NSUserName(),
            "WorkingDirectory": rootURL.standardizedFileURL.path,
            "StandardOutPath": logs.appendingPathComponent("\(kind.rawValue)-daemon.stdout.log").path,
            "StandardErrorPath": logs.appendingPathComponent("\(kind.rawValue)-daemon.stderr.log").path,
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: stagedPlist, options: .atomic)

        let script = temporary.appendingPathComponent("install.sh")
        let body = """
        #!/bin/sh
        set -eu
        /bin/mkdir -p \(Self.sh(Self.daemonDirectoryURL.path))
        /bin/rm -rf \(Self.sh(Self.installedAppURL.path))
        /usr/bin/ditto \(Self.sh(sourceAppURL.path)) \(Self.sh(Self.installedAppURL.path))
        /usr/sbin/chown -R root:wheel \(Self.sh(Self.installedAppURL.path))
        /bin/chmod 755 \(Self.sh(Self.binaryURL.path))
        /bin/launchctl bootout system/\(kind.label) >/dev/null 2>&1 || true
        /usr/bin/install -o root -g wheel -m 644 \(Self.sh(stagedPlist.path)) \(Self.sh(plistURL(for: kind).path))
        /bin/launchctl bootstrap system \(Self.sh(plistURL(for: kind).path))
        /bin/launchctl enable system/\(kind.label)
        /bin/launchctl kickstart -k system/\(kind.label)
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try runPrivileged(scriptURL: script)
    }

    func uninstall(_ kind: CarrachoDaemonKind) throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("carracho-daemon-uninstall-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let script = temporary.appendingPathComponent("uninstall.sh")
        let other = kind == .server ? CarrachoDaemonKind.tracker : .server
        let body = """
        #!/bin/sh
        set -eu
        /bin/launchctl bootout system/\(kind.label) >/dev/null 2>&1 || true
        /bin/rm -f \(Self.sh(plistURL(for: kind).path))
        if [ ! -f \(Self.sh(plistURL(for: other).path)) ]; then
            /bin/rm -rf \(Self.sh(Self.installedAppURL.path))
            /bin/rmdir \(Self.sh(Self.daemonDirectoryURL.path)) >/dev/null 2>&1 || true
        fi
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try runPrivileged(scriptURL: script)
    }

    func setRunning(_ running: Bool, kind: CarrachoDaemonKind) throws {
        guard FileManager.default.fileExists(atPath: plistURL(for: kind).path) else {
            throw CarrachoLaunchDaemonError.privilegeCommand(LF("The %@ daemon is not installed.", kind.rawValue))
        }
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("carracho-daemon-control-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let script = temporary.appendingPathComponent("control.sh")
        let command: String
        if running {
            command = """
            /bin/launchctl bootstrap system \(Self.sh(plistURL(for: kind).path)) >/dev/null 2>&1 || true
            /bin/launchctl enable system/\(kind.label)
            /bin/launchctl kickstart -k system/\(kind.label)
            """
        } else {
            command = "/bin/launchctl bootout system/\(kind.label) >/dev/null 2>&1 || true"
        }
        let body = "#!/bin/sh\nset -eu\n\(command)\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try runPrivileged(scriptURL: script)
    }

    private func plistURL(for kind: CarrachoDaemonKind) -> URL {
        Self.launchDaemonsURL.appendingPathComponent("\(kind.label).plist")
    }

    private func readSnapshot(for kind: CarrachoDaemonKind, rootURL: URL) -> CarrachoDaemonSnapshot? {
        let url = Self.statusURL(kind: kind, rootURL: rootURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(CarrachoDaemonSnapshot.self, from: data),
              value.kind.rawValue == kind.rawValue else { return nil }
        return value
    }

    private func launchctlPrint(_ kind: CarrachoDaemonKind) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(kind.label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
        catch { return -1 }
    }

    private func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    private func runPrivileged(scriptURL: URL) throws {
        let shellCommand = Self.sh(scriptURL.path)
        let appleScript = "do shell script \(Self.appleScriptString(shellCommand)) with administrator privileges"
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CarrachoLaunchDaemonError.privilegeCommand(message)
        }
    }

    static func statusURL(kind: CarrachoDaemonKind, rootURL: URL) -> URL {
        rootURL.standardizedFileURL
            .appendingPathComponent("daemon", isDirectory: true)
            .appendingPathComponent(kind.statusFileName, isDirectory: false)
    }

    fileprivate static func sh(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Headless entry point executed by launchd from the same server binary as the GUI.
enum CarrachoDaemonEntryPoint {
    static func requestedKind(arguments: [String] = CommandLine.arguments) -> CarrachoDaemonKind? {
        if arguments.contains(CarrachoDaemonKind.server.argument) { return .server }
        if arguments.contains(CarrachoDaemonKind.tracker.argument) { return .tracker }
        return nil
    }

    static func run(kind: CarrachoDaemonKind, arguments: [String] = CommandLine.arguments) -> Int32 {
        let root = rootURL(arguments: arguments)
        let writer = SnapshotWriter(kind: kind, rootURL: root)
        do {
            let service = try CarrachoServerService(rootURL: root,
                                                    defaultBannerPNG: CarrachoDefaultServerBanner.pngData())
            switch kind {
            case .server:
                service.runtime.onStatus = { writer.write(server: $0) }
                _ = try service.start()
                writer.write(server: service.status)
            case .tracker:
                let logLock = NSLock()
                let formatter = ISO8601DateFormatter()
                service.trackerRuntime.onLog = { line in
                    logLock.lock(); defer { logLock.unlock() }
                    let entry = "\(formatter.string(from: Date())) \(line)\n"
                    FileHandle.standardError.write(Data(entry.utf8))
                }
                service.trackerRuntime.onStatus = { writer.write(tracker: $0) }
                if service.trackerConfiguration.enabled { _ = try service.startConfiguredTracker() }
                writer.write(tracker: service.trackerStatus)
            }

            let heartbeat = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            heartbeat.schedule(deadline: .now(), repeating: 1.0)
            heartbeat.setEventHandler {
                switch kind {
                case .server: writer.write(server: service.status)
                case .tracker: writer.write(tracker: service.trackerStatus)
                }
            }
            heartbeat.resume()

            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)
            let shutdownQueue = DispatchQueue(label: "com.carracho.daemon.shutdown")
            let shutdownComplete = DispatchSemaphore(value: 0)
            let shutdownLock = NSLock()
            var didStop = false
            let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: shutdownQueue)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: shutdownQueue)
            let stop: () -> Void = {
                shutdownLock.lock()
                guard !didStop else { shutdownLock.unlock(); return }
                didStop = true
                shutdownLock.unlock()

                heartbeat.cancel()
                switch kind {
                case .server:
                    service.stop()
                    writer.write(server: service.status)
                case .tracker:
                    service.trackerRuntime.stop()
                    writer.write(tracker: service.trackerStatus)
                }
                shutdownComplete.signal()
            }
            term.setEventHandler(handler: stop)
            interrupt.setEventHandler(handler: stop)
            term.resume(); interrupt.resume()

            // Do not depend on an NSApplication/CFRunLoop in daemon mode. launchd delivers
            // SIGTERM during bootout/uninstall, the signal source stops the runtime, then this
            // wait releases and the process exits normally with status 0.
            shutdownComplete.wait()
            term.cancel(); interrupt.cancel()
            _ = service // keep the runtime alive until shutdown has completed
            return 0
        } catch {
            writer.writeFailure()
            fputs("Carracho \(kind.rawValue) daemon failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func rootURL(arguments: [String]) -> URL {
        if let raw = arguments.first(where: { $0.hasPrefix("--server-root=") })?.dropFirst("--server-root=".count), !raw.isEmpty {
            return URL(fileURLWithPath: String(raw), isDirectory: true).standardizedFileURL
        }
        return CarrachoServerService.defaultRootURL()
    }

    private final class SnapshotWriter {
        private let kind: CarrachoDaemonKind
        private let rootURL: URL
        private let lock = NSLock()

        init(kind: CarrachoDaemonKind, rootURL: URL) {
            self.kind = kind
            self.rootURL = rootURL
        }

        func write(server status: LegacyServerRuntimeStatus) {
            write(CarrachoDaemonSnapshot(kind: .server, pid: getpid(), updatedAt: Date(),
                                         isRunning: status.isRunning, port: status.port,
                                         transferPort: status.transferPort,
                                         connectedClients: status.connectedClients,
                                         activeFileTransfers: status.activeFileTransfers,
                                         registeredServers: 0))
        }

        func write(tracker status: LegacyTrackerRuntimeStatus) {
            write(CarrachoDaemonSnapshot(kind: .tracker, pid: getpid(), updatedAt: Date(),
                                         isRunning: status.isRunning, port: status.port,
                                         transferPort: nil, connectedClients: 0,
                                         activeFileTransfers: 0,
                                         registeredServers: status.registeredServers))
        }

        func writeFailure() {
            write(CarrachoDaemonSnapshot(kind: kind == .server ? .server : .tracker,
                                         pid: getpid(), updatedAt: Date(), isRunning: false,
                                         port: nil, transferPort: nil, connectedClients: 0,
                                         activeFileTransfers: 0, registeredServers: 0))
        }

        private func write(_ snapshot: CarrachoDaemonSnapshot) {
            lock.lock(); defer { lock.unlock() }
            do {
                let url = CarrachoLaunchDaemonManager.statusURL(kind: kind, rootURL: rootURL)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                // Status reporting must never take down a daemon.
            }
        }
    }
}
#endif
