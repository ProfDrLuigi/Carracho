import Foundation
@preconcurrency import Network

enum LegacyMediaClientError: Error, LocalizedError {
    case invalidTransferPort
    case unsupported
    case invalidImage
    case invalidResponse
    case accessDenied
    case timedOut
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidTransferPort: return "The media transfer port is invalid."
        case .unsupported: return "This server does not support media attachments."
        case .invalidImage: return "The image is invalid or exceeds the media limits."
        case .invalidResponse: return "The server returned an invalid media response."
        case .accessDenied: return "The media attachment is unavailable or access was denied."
        case .timedOut: return "The media transfer timed out."
        case let .transport(message): return "Media transfer failed: \(message)"
        }
    }
}

struct LegacyMediaContent: Equatable {
    var id: UUID
    var mimeType: String
    var filename: String
    var width: Int
    var height: Int
    var data: Data
}

final class LegacyMediaClient {
    private static let timeout: TimeInterval = 25
    let cacheNamespace: String
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let session: LegacyTransferSession

    init(host: String, controlPort: UInt16, session: LegacyTransferSession) throws {
        guard session.usesModernCrypto else { throw LegacyMediaClientError.unsupported }
        guard controlPort < UInt16.max, let port = NWEndpoint.Port(rawValue: controlPort + 1) else { throw LegacyMediaClientError.invalidTransferPort }
        self.host = NWEndpoint.Host(host)
        self.port = port
        self.session = session
        self.cacheNamespace = "\(host.lowercased()):\(controlPort)"
    }

    func upload(filename: String, data: Data, completion: @escaping (Result<UUID, Error>) -> Void) {
        guard !data.isEmpty, data.count <= LegacyMediaTransfer.maximumImageBytes,
              let name = filename.data(using: .utf8), !name.isEmpty, name.count <= 1024 else {
            completion(.failure(LegacyMediaClientError.invalidImage)); return
        }
        var payload = Data([1])
        do { payload.append(try LegacyWire.string16(name)) }
        catch { completion(.failure(error)); return }
        payload.append(LegacyWire.uint32BE(UInt32(data.count)))
        payload.append(data)
        perform(operation: LegacyTransferOperation.mediaUpload, send: payload) { stream, finish in
            stream.readPayload(2) { lengthResult in
                do {
                    var cursor = LegacyByteCursor(try lengthResult.get())
                    let length = Int(try cursor.readUInt16BE())
                    guard length == 36 else { throw LegacyMediaClientError.invalidResponse }
                    stream.readPayload(length) { idResult in
                        do {
                            guard let text = String(data: try idResult.get(), encoding: .ascii), let id = UUID(uuidString: text) else {
                                throw LegacyMediaClientError.invalidResponse
                            }
                            finish(.success(id))
                        } catch { finish(.failure(error)) }
                    }
                } catch { finish(.failure(error)) }
            }
        } completion: { (result: Result<UUID, Error>) in completion(result) }
    }

    func delete(id: UUID, completion: @escaping (Result<Void, Error>) -> Void) {
        let idData = Data(id.uuidString.lowercased().utf8)
        var payload = Data([1])
        do { payload.append(try LegacyWire.string16(idData)) }
        catch { completion(.failure(error)); return }
        perform(operation: LegacyTransferOperation.mediaDelete, send: payload) { stream, finish in
            stream.readPayload(1) { statusResult in
                do {
                    guard let status = try statusResult.get().first else { throw LegacyMediaClientError.invalidResponse }
                    switch status {
                    case 1: finish(.success(()))
                    case 0: finish(.failure(LegacyMediaClientError.accessDenied))
                    default: finish(.failure(LegacyMediaClientError.invalidResponse))
                    }
                } catch { finish(.failure(error)) }
            }
        } completion: { (result: Result<Void, Error>) in completion(result) }
    }

    func download(id: UUID, context: LegacyMediaContext,
                  completion: @escaping (Result<LegacyMediaContent, Error>) -> Void) {
        var payload = Data([1, context.kind])
        do {
            payload.append(try LegacyWire.string16(context.scopeWire))
            payload.append(try LegacyWire.string16(Data(id.uuidString.lowercased().utf8)))
        } catch { completion(.failure(error)); return }
        perform(operation: LegacyTransferOperation.mediaDownload, send: payload) { stream, finish in
            stream.readPayload(1) { statusResult in
                do {
                    guard try statusResult.get().first == 1 else { throw LegacyMediaClientError.accessDenied }
                    self.readString16(stream: stream, maximum: 128) { mimeResult in
                        do {
                            let mimeData = try mimeResult.get()
                            guard let mime = String(data: mimeData, encoding: .utf8), mime == "image/png" || mime == "image/jpeg" else { throw LegacyMediaClientError.invalidResponse }
                            self.readString16(stream: stream, maximum: 1024) { filenameResult in
                                do {
                                    guard let filename = String(data: try filenameResult.get(), encoding: .utf8) else { throw LegacyMediaClientError.invalidResponse }
                                    stream.readPayload(8) { metaResult in
                                        do {
                                            var cursor = LegacyByteCursor(try metaResult.get())
                                            let width = Int(try cursor.readUInt16BE()), height = Int(try cursor.readUInt16BE())
                                            let byteCount = Int(try cursor.readUInt32BE())
                                            guard width > 0, height > 0,
                                                  width <= LegacyMediaTransfer.maximumDimension,
                                                  height <= LegacyMediaTransfer.maximumDimension,
                                                  byteCount > 0, byteCount <= LegacyMediaTransfer.maximumImageBytes else { throw LegacyMediaClientError.invalidResponse }
                                            stream.readPayload(byteCount) { dataResult in
                                                do {
                                                    finish(.success(LegacyMediaContent(id: id, mimeType: mime, filename: filename,
                                                                                       width: width, height: height, data: try dataResult.get())))
                                                } catch { finish(.failure(error)) }
                                            }
                                        } catch { finish(.failure(error)) }
                                    }
                                } catch { finish(.failure(error)) }
                            }
                        } catch { finish(.failure(error)) }
                    }
                } catch { finish(.failure(error)) }
            }
        } completion: { (result: Result<LegacyMediaContent, Error>) in completion(result) }
    }

    private func readString16(stream: AuthenticatedTransferStream, maximum: Int,
                              completion: @escaping (Result<Data, Error>) -> Void) {
        stream.readPayload(2) { prefixResult in
            do {
                var cursor = LegacyByteCursor(try prefixResult.get())
                let length = Int(try cursor.readUInt16BE())
                guard length <= maximum else { throw LegacyMediaClientError.invalidResponse }
                stream.readPayload(length, completion: completion)
            } catch { completion(.failure(error)) }
        }
    }

    private func perform<T>(operation: UInt16, send payload: Data,
                            receive: @escaping (AuthenticatedTransferStream, @escaping (Result<T, Error>) -> Void) -> Void,
                            completion: @escaping (Result<T, Error>) -> Void) {
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let stream: AuthenticatedTransferStream
        do { stream = try AuthenticatedTransferStream(connection: connection, session: session, operation: operation, legacyMode: .plain) }
        catch { completion(.failure(error)); return }
        var finished = false
        var timeoutWorkItem: DispatchWorkItem?
        func finish(_ result: Result<T, Error>) {
            guard !finished else { return }
            finished = true; timeoutWorkItem?.cancel(); timeoutWorkItem = nil
            connection.cancel(); completion(result)
        }
        let timeout = DispatchWorkItem { finish(.failure(LegacyMediaClientError.timedOut)) }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: timeout)
        connection.stateUpdateHandler = { state in
            guard !finished else { return }
            switch state {
            case .ready:
                stream.sendHello { hello in
                    switch hello {
                    case .success:
                        stream.sendPayload(payload) { sent in
                            switch sent {
                            case .success: receive(stream, finish)
                            case let .failure(error): finish(.failure(error))
                            }
                        }
                    case let .failure(error):
                        finish(.failure(error))
                    }
                }
            case let .failed(error): finish(.failure(LegacyMediaClientError.transport(error.localizedDescription)))
            case .cancelled: break
            default: break
            }
        }
        connection.start(queue: .main)
    }
}
