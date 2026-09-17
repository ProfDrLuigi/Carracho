import Foundation
@preconcurrency import Network

enum LegacyNewsClientError: Error, LocalizedError {
    case invalidTransferPort
    case transport(String)
    case connectionClosed
    case timedOut
    case indexTooLarge(UInt32)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .invalidTransferPort:
            return "Für Port 65535 kann kein Carracho-Transfer-Port (+1) gebildet werden."
        case let .transport(message):
            return "News-Transferfehler: \(message)"
        case .connectionClosed:
            return "Die News-Transferverbindung wurde vorzeitig geschlossen."
        case .timedOut:
            return "Zeitüberschreitung beim Laden des News-Index."
        case let .indexTooLarge(length):
            return "Der News-Index ist mit \(length) Byte größer als das Sicherheitslimit."
        case .unexpectedResponse:
            return "Der News-Transfer lieferte unerwartete Antwortdaten."
        }
    }
}

/// One-shot client for classic transfer operation 5 (threaded-news index).
/// The classic server listens on controlPort+1 and closes/synchronizes the
/// transfer connection after the index response; each request therefore owns
/// a fresh TCP connection.
final class LegacyNewsClient {
    private static let timeout: TimeInterval = 15
    private static let maximumIndexPayload: UInt32 = 64 * 1024 * 1024

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let session: LegacyTransferSession

    init(host: String, controlPort: UInt16, session: LegacyTransferSession) throws {
        guard controlPort < UInt16.max, let port = NWEndpoint.Port(rawValue: controlPort + 1) else {
            throw LegacyNewsClientError.invalidTransferPort
        }
        self.host = NWEndpoint.Host(host)
        self.port = port
        self.session = session
    }

    convenience init(host: String, controlPort: UInt16, userID: UInt32) throws {
        try self.init(host: host, controlPort: controlPort, session: LegacyTransferSession(userID: userID, key: Data([0])))
    }

    func requestIndex(group: Data,
                      completion: @escaping (Result<LegacyArticleIndex?, Error>) -> Void) {
        let request: Data
        do {
            request = try LegacyNewsTransfer.encodeIndexRequest(group: group)
        } catch {
            completion(.failure(error))
            return
        }

        let connection = NWConnection(host: host, port: port, using: .tcp)
        let stream: AuthenticatedTransferStream
        do { stream = try AuthenticatedTransferStream(connection: connection, session: session, operation: LegacyTransferOperation.newsIndex, legacyMode: .plain) }
        catch { completion(.failure(error)); return }
        var finished = false
        var timeoutWorkItem: DispatchWorkItem?

        func finish(_ result: Result<LegacyArticleIndex?, Error>) {
            guard !finished else { return }
            finished = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            connection.cancel()
            completion(result)
        }

        let timeout = DispatchWorkItem {
            finish(.failure(LegacyNewsClientError.timedOut))
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: timeout)

        connection.stateUpdateHandler = { state in
            guard !finished else { return }
            switch state {
            case .ready:
                stream.sendHello { helloResult in
                    guard case .success = helloResult else { finish(helloResult.map { nil }); return }
                    stream.sendPayload(request) { sendResult in
                        guard case .success = sendResult else { finish(sendResult.map { nil }); return }
                    stream.readPayload(4) { prefixResult in
                        do {
                            let prefix = try prefixResult.get()
                            var cursor = LegacyByteCursor(prefix)
                            let length = try cursor.readUInt32BE()
                            if length == LegacyArticle.noArticle {
                                finish(.success(nil))
                                return
                            }
                            guard length <= Self.maximumIndexPayload else {
                                throw LegacyNewsClientError.indexTooLarge(length)
                            }
                            stream.readPayload(Int(length)) { payloadResult in
                                do {
                                    let payload = try payloadResult.get()
                                    finish(.success(try LegacyArticleIndex.decode(payload)))
                                } catch {
                                    finish(.failure(error))
                                }
                            }
                        } catch {
                            finish(.failure(error))
                        }
                    }
                    }
                }
            case let .failed(error):
                finish(.failure(LegacyNewsClientError.transport(error.localizedDescription)))
            case .cancelled:
                if !finished { finish(.failure(LegacyNewsClientError.connectionClosed)) }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    /// Modern operation 4 is carried inside authenticated AES-256-GCM transfer frames and
    /// requires a one-byte success ACK after persistence. Explicit Classic compatibility keeps
    /// its historical plain stream and close-as-success behavior because Classic has no ACK.
    func postArticle(group: Data,
                     subject: Data,
                     text: Data,
                     styleData: Data = Data(),
                     parentArticleID: UInt32? = nil,
                     editingArticleID: UInt32? = nil,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        guard !group.isEmpty, group.count <= LegacyNewsTransfer.maximumGroupNameLength,
              !subject.isEmpty, subject.count <= Int(UInt16.max) else {
            completion(.failure(LegacyProtocolError.invalidLength("invalid article group/subject length")))
            return
        }
        let upload = LegacyArticleUploadPayload(
            group: group,
            subject: subject,
            body: LegacyArticleBodyPayload(articleID: editingArticleID ?? 0,
                                           reservedWord: parentArticleID ?? LegacyArticle.noArticle,
                                           text: text, styleData: styleData)
        )
        let payload: Data
        do { payload = try LegacyNewsTransfer.encodeArticleReceiverStream(upload) }
        catch { completion(.failure(error)); return }

        let connection = NWConnection(host: host, port: port, using: .tcp)
        let stream: AuthenticatedTransferStream
        do { stream = try AuthenticatedTransferStream(connection: connection, session: session, operation: LegacyTransferOperation.articleReceiver, legacyMode: .plain) }
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
        let timeout = DispatchWorkItem { finish(.failure(LegacyNewsClientError.timedOut)) }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: timeout)

        func waitForOrderlyClose() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, isComplete, error in
                if let error {
                    finish(.failure(LegacyNewsClientError.transport(error.localizedDescription)))
                } else if let data, !data.isEmpty {
                    finish(.failure(LegacyNewsClientError.unexpectedResponse))
                } else if isComplete {
                    finish(.success(()))
                } else {
                    waitForOrderlyClose()
                }
            }
        }

        connection.stateUpdateHandler = { state in
            guard !finished else { return }
            switch state {
            case .ready:
                stream.sendHello { helloResult in
                    guard case .success = helloResult else { finish(helloResult); return }
                    stream.sendPayload(payload) { sendResult in
                        if case let .failure(error) = sendResult {
                            finish(.failure(error))
                        } else if self.session.modernSalt != nil {
                            stream.readPayload(1) { ackResult in
                                do {
                                    let ack = try ackResult.get()
                                    guard ack == Data([1]) else { throw LegacyNewsClientError.unexpectedResponse }
                                    finish(.success(()))
                                } catch {
                                    finish(.failure(error))
                                }
                            }
                        } else {
                            waitForOrderlyClose()
                        }
                    }
                }
            case let .failed(error): finish(.failure(LegacyNewsClientError.transport(error.localizedDescription)))
            case .cancelled: if !finished { finish(.failure(LegacyNewsClientError.connectionClosed)) }
            default: break
            }
        }
        connection.start(queue: .main)
    }

    func editArticle(group: Data,
                     articleID: UInt32,
                     subject: Data,
                     text: Data,
                     styleData: Data = Data(),
                     completion: @escaping (Result<Void, Error>) -> Void) {
        guard articleID != 0, articleID != LegacyArticle.noArticle else {
            completion(.failure(LegacyProtocolError.invalidLength("invalid article ID for edit")))
            return
        }
        postArticle(group: group, subject: subject, text: text, styleData: styleData,
                    editingArticleID: articleID, completion: completion)
    }

    private static func receiveExactly(connection: NWConnection,
                                       count: Int,
                                       completion: @escaping (Result<Data, Error>) -> Void) {
        guard count >= 0 else {
            completion(.failure(LegacyProtocolError.invalidLength("negative news receive length")))
            return
        }
        if count == 0 {
            completion(.success(Data()))
            return
        }
        var buffer = Data()
        func pump() {
            let remaining = count - buffer.count
            guard remaining > 0 else {
                completion(.success(buffer))
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                if let data { buffer.append(data) }
                if let error {
                    completion(.failure(LegacyNewsClientError.transport(error.localizedDescription)))
                    return
                }
                if buffer.count == count {
                    completion(.success(buffer))
                    return
                }
                if isComplete {
                    completion(.failure(LegacyNewsClientError.connectionClosed))
                    return
                }
                pump()
            }
        }
        pump()
    }
}
