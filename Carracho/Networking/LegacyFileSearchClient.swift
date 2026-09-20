import Foundation
@preconcurrency import Network

enum LegacyFileSearchClientError: Error, LocalizedError {
    case invalidTransferPort
    case invalidQuery
    case transport(String)
    case connectionClosed
    case timedOut
    case invalidResponse(String)
    case tooManyResults

    var errorDescription: String? {
        switch self {
        case .invalidTransferPort: return "Für Port 65535 kann kein Carracho-Such-Port (+1) gebildet werden."
        case .invalidQuery: return "Der Suchtext muss in MacRoman darstellbar und 1 bis 255 Byte lang sein."
        case let .transport(message): return "Dateisuche fehlgeschlagen: \(message)"
        case .connectionClosed: return "Die Suchverbindung wurde vorzeitig geschlossen."
        case .timedOut: return "Zeitüberschreitung bei der Dateisuche."
        case let .invalidResponse(message): return "Ungültige Suchantwort: \(message)"
        case .tooManyResults: return "Der Server lieferte zu viele Suchtreffer."
        }
    }
}

/// One-shot client for transfer operation 9. Modern sessions use authenticated
/// AES-256-GCM framing; explicit Classic sessions preserve the historical plain stream.
final class LegacyFileSearchClient {
    private static let inactivityTimeout: TimeInterval = 30
    private static let maximumResults = 100_000
    private static let maximumPathLength = LegacyPath.maximumWireLength

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let session: LegacyTransferSession

    init(host: String, controlPort: UInt16, session: LegacyTransferSession) throws {
        guard controlPort < UInt16.max, let port = NWEndpoint.Port(rawValue: controlPort + 1) else {
            throw LegacyFileSearchClientError.invalidTransferPort
        }
        self.host = NWEndpoint.Host(host)
        self.port = port
        self.session = session
    }

    convenience init(host: String, controlPort: UInt16, userID: UInt32) throws {
        try self.init(host: host, controlPort: controlPort, session: LegacyTransferSession(userID: userID, key: Data([0])))
    }

    func search(text: Data, completion: @escaping (Result<[LegacyFileSearchResult], Error>) -> Void) {
        let query: Data
        do { query = try LegacyFileSearchQuery(text: text).encoded() }
        catch { completion(.failure(error)); return }

        // Search responses can legitimately contain tens of thousands of records. Parsing all
        // transfer frames on the main queue makes scrolling/UI input hitch for the entire search.
        // Keep every socket read and record decode on one serial worker queue; only publish the
        // final immutable result array back to AppKit on the main queue.
        let queue = DispatchQueue(label: "com.carracho.file-search", qos: .userInitiated)
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let stream: AuthenticatedTransferStream
        do { stream = try AuthenticatedTransferStream(connection: connection, session: session, operation: LegacyTransferOperation.fileSearch, legacyMode: .plain) }
        catch { completion(.failure(error)); return }
        var finished = false
        var timeoutWorkItem: DispatchWorkItem?
        var results: [LegacyFileSearchResult] = []
        results.reserveCapacity(512)

        func finish(_ result: Result<[LegacyFileSearchResult], Error>) {
            guard !finished else { return }
            finished = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            connection.cancel()
            DispatchQueue.main.async { completion(result) }
        }

        func armInactivityTimeout() {
            timeoutWorkItem?.cancel()
            let timeout = DispatchWorkItem { finish(.failure(LegacyFileSearchClientError.timedOut)) }
            timeoutWorkItem = timeout
            queue.asyncAfter(deadline: .now() + Self.inactivityTimeout, execute: timeout)
        }

        func readRecord(_ remaining: UInt32, then: @escaping () -> Void) {
            guard remaining > 0 else { then(); return }
            stream.readPayload(5) { prefixResult in
                do {
                    var prefix = LegacyByteCursor(try prefixResult.get())
                    let reserved = try prefix.readUInt32BE()
                    guard reserved == 0 else { throw LegacyFileSearchClientError.invalidResponse("reserved word is nonzero") }
                    let nameLength = Int(try prefix.readUInt8())
                    guard nameLength > 0 else { throw LegacyFileSearchClientError.invalidResponse("empty result name") }
                    stream.readPayload(nameLength + 18) { fixedResult in
                        do {
                            let fixed = try fixedResult.get()
                            var cursor = LegacyByteCursor(fixed)
                            let name = try cursor.readBytes(count: nameLength)
                            let creator = try cursor.readUInt32BE()
                            let fileType = try cursor.readUInt32BE()
                            let size = try cursor.readUInt32BE()
                            let timestamp = try cursor.readUInt32BE()
                            let pathLength = Int(try cursor.readUInt16BE())
                            guard pathLength <= Self.maximumPathLength else {
                                throw LegacyFileSearchClientError.invalidResponse("result path exceeds classic limit")
                            }
                            stream.readPayload(pathLength) { pathResult in
                                do {
                                    let path = try pathResult.get()
                                    results.append(LegacyFileSearchResult(name: name, creator: creator, fileType: fileType,
                                                                         size: size, timestamp: timestamp, path: path))
                                    guard results.count <= Self.maximumResults else { throw LegacyFileSearchClientError.tooManyResults }
                                    armInactivityTimeout()
                                    readRecord(remaining - 1, then: then)
                                } catch { finish(.failure(error)) }
                            }
                        } catch { finish(.failure(error)) }
                    }
                } catch { finish(.failure(error)) }
            }
        }

        func readFrame() {
            stream.readPayload(1) { signalResult in
                do {
                    guard let signal = try signalResult.get().first else {
                        throw LegacyFileSearchClientError.invalidResponse("missing signal byte")
                    }
                    armInactivityTimeout()
                    if signal == 0 { readFrame(); return } // classic keepalive
                    guard signal == 1 else { throw LegacyFileSearchClientError.invalidResponse("unknown signal \(signal)") }
                    stream.readPayload(4) { countResult in
                        do {
                            var cursor = LegacyByteCursor(try countResult.get())
                            let count = try cursor.readUInt32BE()
                            if count == 0 { finish(.success(results)); return }
                            guard Int(count) <= Self.maximumResults - results.count else {
                                throw LegacyFileSearchClientError.tooManyResults
                            }
                            readRecord(count) { readFrame() }
                        } catch { finish(.failure(error)) }
                    }
                } catch { finish(.failure(error)) }
            }
        }

        connection.stateUpdateHandler = { state in
            guard !finished else { return }
            switch state {
            case .ready:
                armInactivityTimeout()
                stream.sendHello { helloResult in
                    guard case .success = helloResult else {
                        if case let .failure(error) = helloResult { finish(.failure(error)) }
                        return
                    }
                    stream.sendPayload(query) { sendResult in
                        guard case .success = sendResult else {
                            if case let .failure(error) = sendResult { finish(.failure(error)) }
                            return
                        }
                        stream.readPayload(4) { ackResult in
                            do {
                                var cursor = LegacyByteCursor(try ackResult.get())
                                guard try cursor.readUInt32BE() == 0 else {
                                    throw LegacyFileSearchClientError.invalidResponse("query acknowledgement is nonzero")
                                }
                                armInactivityTimeout()
                                readFrame()
                            } catch { finish(.failure(error)) }
                        }
                    }
                }
            case let .failed(error): finish(.failure(LegacyFileSearchClientError.transport(error.localizedDescription)))
            case .cancelled: if !finished { finish(.failure(LegacyFileSearchClientError.connectionClosed)) }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private static func receiveExactly(connection: NWConnection, count: Int,
                                       completion: @escaping (Result<Data, Error>) -> Void) {
        guard count >= 0 else { completion(.failure(LegacyFileSearchClientError.invalidResponse("negative read length"))); return }
        if count == 0 { completion(.success(Data())); return }
        var buffer = Data()
        func pump() {
            let remaining = count - buffer.count
            guard remaining > 0 else { completion(.success(buffer)); return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                if let data { buffer.append(data) }
                if let error { completion(.failure(LegacyFileSearchClientError.transport(error.localizedDescription))) }
                else if buffer.count == count { completion(.success(buffer)) }
                else if complete { completion(.failure(LegacyFileSearchClientError.connectionClosed)) }
                else { pump() }
            }
        }
        pump()
    }
}
