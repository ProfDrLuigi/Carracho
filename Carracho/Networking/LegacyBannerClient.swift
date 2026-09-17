import Foundation
@preconcurrency import Network

struct LegacyBannerContent: Equatable {
    var imageData: Data
    var url: Data

    var urlString: String { String(data: url, encoding: .macOSRoman) ?? "" }
}

enum LegacyBannerClientError: Error, LocalizedError {
    case invalidTransferPort
    case invalidBanner
    case invalidURL
    case transport(String)
    case connectionClosed
    case timedOut
    case invalidResponse(String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .invalidTransferPort: return "Für Port 65535 kann kein Carracho-Banner-Transfer-Port (+1) gebildet werden."
        case .invalidBanner: return "Das Banner überschreitet das Sicherheitslimit von 8 MiB."
        case .invalidURL: return "Die Banner-URL muss in MacRoman darstellbar und höchstens 255 Byte lang sein."
        case let .transport(message): return "Banner-Transferfehler: \(message)"
        case .connectionClosed: return "Die Banner-Transferverbindung wurde vorzeitig geschlossen."
        case .timedOut: return "Zeitüberschreitung beim Banner-Transfer."
        case let .invalidResponse(message): return "Ungültige Banner-Antwort: \(message)"
        case .unexpectedResponse: return "Der Banner-Upload lieferte unerwartete Antwortdaten."
        }
    }
}

/// One-shot client for banner transfer operations 8/15. Modern sessions use authenticated
/// AES-256-GCM framing; explicit Classic sessions preserve the historical plain stream.
final class LegacyBannerClient {
    private static let timeout: TimeInterval = 15
    private static let maximumBannerBytes = 8 * 1024 * 1024

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let session: LegacyTransferSession

    init(host: String, controlPort: UInt16, session: LegacyTransferSession) throws {
        guard controlPort < UInt16.max, let port = NWEndpoint.Port(rawValue: controlPort + 1) else {
            throw LegacyBannerClientError.invalidTransferPort
        }
        self.host = NWEndpoint.Host(host)
        self.port = port
        self.session = session
    }

    convenience init(host: String, controlPort: UInt16, userID: UInt32) throws {
        try self.init(host: host, controlPort: controlPort, session: LegacyTransferSession(userID: userID, key: Data([0])))
    }

    func download(completion: @escaping (Result<LegacyBannerContent, Error>) -> Void) {
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let stream: AuthenticatedTransferStream
        do { stream = try AuthenticatedTransferStream(connection: connection, session: session, operation: LegacyTransferOperation.bannerDownload, legacyMode: .plain) }
        catch { completion(.failure(error)); return }
        var finished = false
        var timeoutWorkItem: DispatchWorkItem?
        func finish(_ result: Result<LegacyBannerContent, Error>) {
            guard !finished else { return }
            finished = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            connection.cancel()
            completion(result)
        }
        let timeout = DispatchWorkItem { finish(.failure(LegacyBannerClientError.timedOut)) }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: timeout)

        connection.stateUpdateHandler = { state in
            guard !finished else { return }
            switch state {
            case .ready:
                stream.sendHello { helloResult in
                    guard case .success = helloResult else { finish(helloResult.map { LegacyBannerContent(imageData: Data(), url: Data()) }); return }
                    stream.readPayload(4) { prefixResult in
                        do {
                            var cursor = LegacyByteCursor(try prefixResult.get())
                            let imageLength = Int(try cursor.readUInt32BE())
                            guard imageLength <= Self.maximumBannerBytes else { throw LegacyBannerClientError.invalidBanner }
                            stream.readPayload(imageLength) { imageResult in
                                do {
                                    let imageData = try imageResult.get()
                                    stream.readPayload(1) { urlLengthResult in
                                        do {
                                            let urlLength = Int(try urlLengthResult.get().first ?? 0)
                                            stream.readPayload(urlLength) { urlResult in
                                                do {
                                                    finish(.success(LegacyBannerContent(imageData: imageData, url: try urlResult.get())))
                                                } catch { finish(.failure(error)) }
                                            }
                                        } catch { finish(.failure(error)) }
                                    }
                                } catch { finish(.failure(error)) }
                            }
                        } catch { finish(.failure(error)) }
                    }
                }
            case let .failed(error): finish(.failure(LegacyBannerClientError.transport(error.localizedDescription)))
            case .cancelled: if !finished { finish(.failure(LegacyBannerClientError.connectionClosed)) }
            default: break
            }
        }
        connection.start(queue: .main)
    }

    func upload(imageData: Data, url: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        guard imageData.count <= Self.maximumBannerBytes, imageData.count <= Int(UInt32.max) else {
            completion(.failure(LegacyBannerClientError.invalidBanner)); return
        }
        guard url.count <= 255 else { completion(.failure(LegacyBannerClientError.invalidURL)); return }
        var payload = LegacyWire.uint32BE(UInt32(imageData.count))
        payload.append(imageData)
        payload.append(UInt8(url.count))
        payload.append(url)

        let connection = NWConnection(host: host, port: port, using: .tcp)
        let stream: AuthenticatedTransferStream
        do { stream = try AuthenticatedTransferStream(connection: connection, session: session, operation: LegacyTransferOperation.bannerUpload, legacyMode: .plain) }
        catch { completion(.failure(error)); return }
        var finished = false
        var timeoutWorkItem: DispatchWorkItem?
        func finish(_ result: Result<Void, Error>) {
            guard !finished else { return }
            finished = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            connection.cancel()
            completion(result)
        }
        let timeout = DispatchWorkItem { finish(.failure(LegacyBannerClientError.timedOut)) }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: timeout)

        func waitForOrderlyClose() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, isComplete, error in
                if let error { finish(.failure(LegacyBannerClientError.transport(error.localizedDescription))) }
                else if let data, !data.isEmpty { finish(.failure(LegacyBannerClientError.unexpectedResponse)) }
                else if isComplete { finish(.success(())) }
                else { waitForOrderlyClose() }
            }
        }
        connection.stateUpdateHandler = { state in
            guard !finished else { return }
            switch state {
            case .ready:
                stream.sendHello { helloResult in
                    guard case .success = helloResult else { finish(helloResult); return }
                    stream.sendPayload(payload) { sendResult in
                        if case let .failure(error) = sendResult { finish(.failure(error)) }
                        else { waitForOrderlyClose() }
                    }
                }
            case let .failed(error): finish(.failure(LegacyBannerClientError.transport(error.localizedDescription)))
            case .cancelled: if !finished { finish(.failure(LegacyBannerClientError.connectionClosed)) }
            default: break
            }
        }
        connection.start(queue: .main)
    }

    func upload(imageData: Data, urlString: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = urlString.data(using: .macOSRoman), url.count <= 255 else {
            completion(.failure(LegacyBannerClientError.invalidURL)); return
        }
        upload(imageData: imageData, url: url, completion: completion)
    }

    private static func receiveExactly(connection: NWConnection, count: Int,
                                       completion: @escaping (Result<Data, Error>) -> Void) {
        guard count >= 0 else { completion(.failure(LegacyBannerClientError.invalidResponse("negative read length"))); return }
        if count == 0 { completion(.success(Data())); return }
        var buffer = Data()
        func pump() {
            let remaining = count - buffer.count
            guard remaining > 0 else { completion(.success(buffer)); return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                if let data { buffer.append(data) }
                if let error { completion(.failure(LegacyBannerClientError.transport(error.localizedDescription))) }
                else if buffer.count == count { completion(.success(buffer)) }
                else if isComplete { completion(.failure(LegacyBannerClientError.connectionClosed)) }
                else { pump() }
            }
        }
        pump()
    }
}
