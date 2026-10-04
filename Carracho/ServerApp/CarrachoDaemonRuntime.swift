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

    func statusURL(rootURL: URL) -> URL {
        rootURL.standardizedFileURL
            .appendingPathComponent("daemon", isDirectory: true)
            .appendingPathComponent(statusFileName, isDirectory: false)
    }
}


#if CARRACHO_SERVER_DAEMON
/// Headless entry point used by the dedicated carracho-serverd executable.
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
            let service = try CarrachoServerService(
                rootURL: root,
                defaultBannerPNG: CarrachoDefaultServerBanner.pngData()
            )
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
                _ = try service.trackerRuntime.start(port: service.trackerConfiguration.port)
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
                let url = kind.statusURL(rootURL: rootURL)
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
#endif
