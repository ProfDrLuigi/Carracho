import Foundation
@preconcurrency import Network

struct TrackerBookmark: Codable, Equatable, Identifiable {
    var id: UUID
    var address: String

    init(id: UUID = UUID(), address: String) {
        self.id = id
        self.address = address
    }
}

final class TrackerBookmarkStore {
    static let storageKey = "Carracho.TrackerBookmarks.v1"
    static let defaultsInitializedKey = "Carracho.TrackerBookmarks.DefaultsInitialized.v1"
    static let defaultTrackerAddress = "carracho.istation.pw"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [TrackerBookmark] {
        if let data = defaults.data(forKey: Self.storageKey),
           let value = try? JSONDecoder().decode([TrackerBookmark].self, from: data) {
            defaults.set(true, forKey: Self.defaultsInitializedKey)
            return value
        }

        guard !defaults.bool(forKey: Self.defaultsInitializedKey) else { return [] }
        let initial = [TrackerBookmark(address: Self.defaultTrackerAddress)]
        save(initial)
        return initial
    }

    func save(_ trackers: [TrackerBookmark]) {
        guard let data = try? JSONEncoder().encode(trackers) else { return }
        defaults.set(data, forKey: Self.storageKey)
        defaults.set(true, forKey: Self.defaultsInitializedKey)
    }
}

struct LegacyTrackerEndpoint: Equatable {
    var host: String
    var port: UInt16

    static func parse(_ rawValue: String) throws -> LegacyTrackerEndpoint {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LegacyTrackerClientError.invalidAddress(rawValue) }
        let source = trimmed.contains("://") ? trimmed : "tracker://\(trimmed)"
        guard let components = URLComponents(string: source),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw LegacyTrackerClientError.invalidAddress(rawValue)
        }
        if let scheme = components.scheme?.lowercased(),
           !["tracker", "carracho-tracker", "tcp"].contains(scheme) {
            throw LegacyTrackerClientError.invalidScheme(scheme)
        }
        let rawPort = components.port ?? Int(LegacyTrackerProtocol.port)
        guard rawPort > 0, rawPort <= Int(UInt16.max) else {
            throw LegacyTrackerClientError.invalidAddress(rawValue)
        }
        return LegacyTrackerEndpoint(host: host, port: UInt16(rawPort))
    }
}

enum LegacyTrackerClientError: LocalizedError {
    case invalidAddress(String)
    case invalidScheme(String)
    case transport(String)
    case timedOut
    case connectionClosed
    case responseTooLarge
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case let .invalidAddress(value): return "Invalid Tracker address: \(value)"
        case let .invalidScheme(value): return "Unsupported Tracker URL scheme ‘\(value)’. Use tracker://, carracho-tracker:// or tcp://."
        case let .transport(message): return "Tracker connection failed: \(message)"
        case .timedOut: return "Tracker request timed out."
        case .connectionClosed: return "Tracker closed the connection before sending a complete server list."
        case .responseTooLarge: return "Tracker response exceeds the safety limit."
        case let .invalidResponse(message): return "Invalid Tracker response: \(message)"
        }
    }
}

/// One-shot Classic CTQ/QLI client used by the sidebar Tracker browser.
final class LegacyTrackerClient {
    private static let timeout: TimeInterval = 8
    private static let maximumResponseBytes = 4 * 1024 * 1024
    private static let maximumEntries = 10_000

    func query(address: String, completion: @escaping (Result<[LegacyTrackerServerEntry], Error>) -> Void) {
        let endpoint: LegacyTrackerEndpoint
        do { endpoint = try LegacyTrackerEndpoint.parse(address) }
        catch { completion(.failure(error)); return }
        query(host: endpoint.host, port: endpoint.port, completion: completion)
    }

    func query(host: String, port: UInt16,
               completion: @escaping (Result<[LegacyTrackerServerEntry], Error>) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(.failure(LegacyTrackerClientError.invalidAddress("\(host):\(port)")))
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        var received = Data()
        var finished = false
        var timeoutWorkItem: DispatchWorkItem?

        func finish(_ result: Result<[LegacyTrackerServerEntry], Error>) {
            guard !finished else { return }
            finished = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            connection.cancel()
            completion(result)
        }

        func inspectAndContinue() {
            do {
                if try Self.isCompleteResponse(received) {
                    finish(.success(try LegacyTrackerProtocol.decodeListResponse(received)))
                    return
                }
            } catch {
                finish(.failure(error))
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                guard !finished else { return }
                if let error {
                    finish(.failure(LegacyTrackerClientError.transport(error.localizedDescription)))
                    return
                }
                if let data, !data.isEmpty {
                    received.append(data)
                    guard received.count <= Self.maximumResponseBytes else {
                        finish(.failure(LegacyTrackerClientError.responseTooLarge))
                        return
                    }
                    inspectAndContinue()
                    return
                }
                if isComplete { finish(.failure(LegacyTrackerClientError.connectionClosed)) }
                else { inspectAndContinue() }
            }
        }

        let timeout = DispatchWorkItem { finish(.failure(LegacyTrackerClientError.timedOut)) }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: timeout)

        connection.stateUpdateHandler = { state in
            guard !finished else { return }
            switch state {
            case .ready:
                connection.send(content: LegacyTrackerProtocol.listRequest(), completion: .contentProcessed { error in
                    if let error { finish(.failure(LegacyTrackerClientError.transport(error.localizedDescription))) }
                    else { inspectAndContinue() }
                })
            case let .failed(error):
                finish(.failure(LegacyTrackerClientError.transport(error.localizedDescription)))
            case .cancelled:
                if !finished { finish(.failure(LegacyTrackerClientError.connectionClosed)) }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private static func isCompleteResponse(_ data: Data) throws -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = [UInt8](data.prefix(4))
        let count = Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        guard count <= maximumEntries else {
            throw LegacyTrackerClientError.invalidResponse("server count \(count) exceeds the safety limit")
        }
        var offset = 4
        for _ in 0..<count {
            guard data.count > offset else { return false }
            let recordLength = Int(data[data.index(data.startIndex, offsetBy: offset)])
            offset += 1
            guard recordLength >= 14 else {
                throw LegacyTrackerClientError.invalidResponse("record is shorter than the fixed Tracker fields")
            }
            guard data.count >= offset + recordLength else { return false }
            offset += recordLength
        }
        if data.count > offset {
            throw LegacyTrackerClientError.invalidResponse("response has \(data.count - offset) trailing byte(s)")
        }
        return data.count == offset
    }
}
