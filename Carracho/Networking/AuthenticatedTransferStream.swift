import Foundation
@preconcurrency import Network

/// Framing shared by all transfer-port operations. Modern sessions encrypt and
/// authenticate every transfer operation (including news/search/banner traffic).
/// Legacy sessions preserve the historical plain or Blowfish wire mode.
final class AuthenticatedTransferStream {
    enum LegacyMode { case plain, blowfish }

    private static let maximumFramePayload = 4 * 1024 * 1024
    let connection: NWConnection
    let session: LegacyTransferSession
    let operation: UInt16
    private let legacyMode: LegacyMode
    private let modernChannel: CarrachoAEADChannel?
    private let transferNonce: Data?
    private var plaintextBuffer = Data()

    init(connection: NWConnection, session: LegacyTransferSession, operation: UInt16, legacyMode: LegacyMode) throws {
        self.connection = connection
        self.session = session
        self.operation = operation
        self.legacyMode = legacyMode
        if let salt = session.modernSalt {
            let nonce = CarrachoModernCrypto.randomBytes(count: CarrachoModernCrypto.transferNonceLength)
            let keys = try CarrachoModernCrypto.transferKeys(sessionKey: session.key, sessionSalt: salt,
                                                              transferNonce: nonce, operation: operation, role: .client)
            self.transferNonce = nonce
            self.modernChannel = try CarrachoAEADChannel(keys: keys, domain: "carracho/transfer/v1")
        } else {
            self.transferNonce = nil
            self.modernChannel = nil
        }
    }

    var hello: Data {
        var value = LegacyWire.transferHello(operation: operation, userID: session.userID,
                                             versionWord: modernChannel == nil ? 0x01000000 : CarrachoModernCrypto.transferHelloVersion)
        if let transferNonce { value.append(transferNonce) }
        return value
    }

    func sendHello(completion: @escaping (Result<Void, Error>) -> Void) {
        sendRaw(hello, completion: completion)
    }

    func sendPayload(_ payload: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        if let modernChannel {
            if payload.isEmpty { completion(.success(())); return }
            var offset = 0
            func sendNext() {
                guard offset < payload.count else { completion(.success(())); return }
                do {
                    let count = min(Self.maximumFramePayload, payload.count - offset)
                    let chunk = Data(payload[offset ..< offset + count])
                    let wire = try modernChannel.seal(chunk)
                    sendRaw(wire) { result in
                        guard case .success = result else { completion(result); return }
                        offset += count
                        sendNext()
                    }
                } catch { completion(.failure(error)) }
            }
            sendNext()
            return
        }
        do {
            let wire = legacyMode == .blowfish
                ? try LegacyCryptoFraming.encodeTransferBlock(payload: payload, key: session.key)
                : payload
            sendRaw(wire, completion: completion)
        } catch { completion(.failure(error)) }
    }

    func readPayload(_ count: Int, completion: @escaping (Result<Data, Error>) -> Void) {
        guard count >= 0 else {
            completion(.failure(LegacyProtocolError.invalidLength("negative transfer read length"))); return
        }
        if count == 0 { completion(.success(Data())); return }
        if modernChannel == nil && legacyMode == .plain {
            Self.receiveExactly(connection: connection, count: count, completion: completion)
            return
        }
        if plaintextBuffer.count >= count {
            let result = Data(plaintextBuffer.prefix(count)); plaintextBuffer.removeFirst(count)
            completion(.success(result)); return
        }
        readFrame { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(payload):
                self.plaintextBuffer.append(payload)
                self.readPayload(count, completion: completion)
            case let .failure(error): completion(.failure(error))
            }
        }
    }

    private func readFrame(completion: @escaping (Result<Data, Error>) -> Void) {
        if let modernChannel {
            Self.receiveExactly(connection: connection, count: CarrachoModernCrypto.frameHeaderLength) { headerResult in
                do {
                    let header = try headerResult.get()
                    var cursor = LegacyByteCursor(header)
                    let length = Int(try cursor.readUInt32BE())
                    _ = try cursor.readUInt64BE()
                    guard length >= 0, length <= Self.maximumFramePayload else {
                        throw LegacyProtocolError.invalidLength("authenticated transfer frame exceeds 4 MiB")
                    }
                    Self.receiveExactly(connection: self.connection, count: length + CarrachoModernCrypto.tagLength) { bodyResult in
                        do {
                            var frame = header; frame.append(try bodyResult.get())
                            completion(.success(try modernChannel.open(frame, maximumCiphertextLength: Self.maximumFramePayload)))
                        } catch { completion(.failure(error)) }
                    }
                } catch { completion(.failure(error)) }
            }
            return
        }

        Self.receiveExactly(connection: connection, count: 9) { headerResult in
            do {
                let header = try headerResult.get()
                var cursor = LegacyByteCursor(header)
                let encryptedLength = Int(try cursor.readUInt32BE())
                let reserved = try cursor.readUInt32BE()
                let padding = Int(try cursor.readUInt8())
                guard reserved == 0, padding <= 7, encryptedLength >= 0,
                      encryptedLength.isMultiple(of: 8), encryptedLength <= Self.maximumFramePayload else {
                    throw LegacyProtocolError.invalidLength("invalid legacy encrypted transfer frame")
                }
                Self.receiveExactly(connection: self.connection, count: encryptedLength) { bodyResult in
                    do {
                        var frame = header; frame.append(try bodyResult.get())
                        completion(.success(try LegacyCryptoFraming.decodeTransferBlock(frame, key: self.session.key)))
                    } catch { completion(.failure(error)) }
                }
            } catch { completion(.failure(error)) }
        }
    }

    private func sendRaw(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { completion(.failure(error)) } else { completion(.success(())) }
        })
    }

    static func receiveExactly(connection: NWConnection, count: Int,
                               completion: @escaping (Result<Data, Error>) -> Void) {
        if count == 0 { completion(.success(Data())); return }
        var buffer = Data()
        func pump() {
            let remaining = count - buffer.count
            guard remaining > 0 else { completion(.success(buffer)); return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                if let data { buffer.append(data) }
                if let error { completion(.failure(error)) }
                else if buffer.count == count { completion(.success(buffer)) }
                else if complete { completion(.failure(LegacyProtocolError.truncated(expected: count, remaining: buffer.count))) }
                else { pump() }
            }
        }
        pump()
    }
}
