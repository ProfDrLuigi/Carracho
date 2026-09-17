import Foundation
import CryptoKit

enum CarrachoModernCrypto {
    static let clientHelloVersion: UInt16 = 2
    static let serverHelloVersion: UInt16 = 3
    static let transferProtocolVersion: UInt16 = 3
    static let transferHelloVersion: UInt32 = 0x02000000
    static let sessionSaltLength = 32
    static let transferNonceLength = 16
    static let tagLength = 16
    static let frameHeaderLength = 12
    static let ephemeralPublicKeyLength = 32
    static let handshakeAuthenticatorLength = 32

    enum Role { case client, server }

    struct EphemeralKeyPair {
        fileprivate let privateKey: Curve25519.KeyAgreement.PrivateKey
        var publicKey: Data { privateKey.publicKey.rawRepresentation }
    }

    enum Error: Swift.Error, LocalizedError {
        case invalidKey
        case invalidSalt
        case invalidNonce
        case invalidFrame(String)
        case authenticationFailed
        case sequenceExhausted
        case keyAgreementFailed
        case handshakeAuthenticationFailed

        var errorDescription: String? {
            switch self {
            case .invalidKey: return "Modern transport key is invalid."
            case .invalidSalt: return "Modern transport salt is invalid."
            case .invalidNonce: return "Modern transport nonce is invalid."
            case let .invalidFrame(message): return "Invalid authenticated transport frame: \(message)"
            case .authenticationFailed: return "Authenticated transport frame could not be verified."
            case .sequenceExhausted: return "Authenticated transport sequence is exhausted."
            case .keyAgreementFailed: return "X25519 transport key agreement failed."
            case .handshakeAuthenticationFailed: return "Modern transport handshake authentication failed."
            }
        }
    }

    struct DirectionalKeys: Equatable {
        let send: Data
        let receive: Data
    }

    static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func makeEphemeralKeyPair() -> EphemeralKeyPair {
        EphemeralKeyPair(privateKey: Curve25519.KeyAgreement.PrivateKey())
    }

    static func transportMaster(keyPair: EphemeralKeyPair, peerPublicKey: Data,
                                sessionKey: Data, sessionSalt: Data) throws -> Data {
        guard peerPublicKey.count == ephemeralPublicKeyLength else { throw Error.keyAgreementFailed }
        guard !sessionKey.isEmpty else { throw Error.invalidKey }
        guard sessionSalt.count == sessionSaltLength else { throw Error.invalidSalt }
        do {
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
            let shared = try keyPair.privateKey.sharedSecretFromKeyAgreement(with: peer)
            let sharedData = shared.withUnsafeBytes { Data($0) }
            var binding = Data("carracho/x25519/salt/v1".utf8)
            binding.append(sessionKey)
            binding.append(sessionSalt)
            let bindingSalt = Data(SHA256.hash(data: binding))
            return deriveKey(input: sharedData, salt: bindingSalt, info: "carracho/x25519/master/v1")
        } catch {
            throw Error.keyAgreementFailed
        }
    }

    static func handshakeAuthenticator(sessionKey: Data, challenge: Data, clientPublicKey: Data,
                                       serverPublicKey: Data, sessionSalt: Data) throws -> Data {
        guard !sessionKey.isEmpty else { throw Error.invalidKey }
        guard challenge.count == 12,
              clientPublicKey.count == ephemeralPublicKeyLength,
              serverPublicKey.count == ephemeralPublicKeyLength,
              sessionSalt.count == sessionSaltLength else { throw Error.handshakeAuthenticationFailed }
        let transcript = handshakeTranscript(challenge: challenge, clientPublicKey: clientPublicKey,
                                             serverPublicKey: serverPublicKey, sessionSalt: sessionSalt)
        let code = HMAC<SHA256>.authenticationCode(for: transcript, using: SymmetricKey(data: sessionKey))
        return Data(code)
    }

    static func verifyHandshakeAuthenticator(_ authenticator: Data, sessionKey: Data, challenge: Data,
                                             clientPublicKey: Data, serverPublicKey: Data,
                                             sessionSalt: Data) throws {
        guard authenticator.count == handshakeAuthenticatorLength else { throw Error.handshakeAuthenticationFailed }
        let transcript = handshakeTranscript(challenge: challenge, clientPublicKey: clientPublicKey,
                                             serverPublicKey: serverPublicKey, sessionSalt: sessionSalt)
        let valid = HMAC<SHA256>.isValidAuthenticationCode(authenticator, authenticating: transcript,
                                                           using: SymmetricKey(data: sessionKey))
        guard valid else { throw Error.handshakeAuthenticationFailed }
    }

    private static func handshakeTranscript(challenge: Data, clientPublicKey: Data,
                                            serverPublicKey: Data, sessionSalt: Data) -> Data {
        var transcript = Data("carracho/x25519-auth/v1".utf8)
        transcript.append(challenge)
        transcript.append(clientPublicKey)
        transcript.append(serverPublicKey)
        transcript.append(sessionSalt)
        return transcript
    }

    static func controlKeys(sessionKey: Data, salt: Data, role: Role) throws -> DirectionalKeys {
        guard !sessionKey.isEmpty else { throw Error.invalidKey }
        guard salt.count == sessionSaltLength else { throw Error.invalidSalt }
        let c2s = deriveKey(input: sessionKey, salt: salt, info: "carracho/aes-256-gcm/control/c2s/v1")
        let s2c = deriveKey(input: sessionKey, salt: salt, info: "carracho/aes-256-gcm/control/s2c/v1")
        return role == .client ? DirectionalKeys(send: c2s, receive: s2c)
                               : DirectionalKeys(send: s2c, receive: c2s)
    }

    static func transferKeys(sessionKey: Data, sessionSalt: Data, transferNonce: Data,
                             operation: UInt16, role: Role) throws -> DirectionalKeys {
        guard !sessionKey.isEmpty else { throw Error.invalidKey }
        guard sessionSalt.count == sessionSaltLength else { throw Error.invalidSalt }
        guard transferNonce.count == transferNonceLength else { throw Error.invalidNonce }
        var salt = sessionSalt
        salt.append(transferNonce)
        let op = String(format: "%04x", operation)
        let c2s = deriveKey(input: sessionKey, salt: salt,
                            info: "carracho/aes-256-gcm/transfer/\(op)/c2s/v1")
        let s2c = deriveKey(input: sessionKey, salt: salt,
                            info: "carracho/aes-256-gcm/transfer/\(op)/s2c/v1")
        return role == .client ? DirectionalKeys(send: c2s, receive: s2c)
                               : DirectionalKeys(send: s2c, receive: c2s)
    }

    /// RFC 5869 HKDF-SHA-256 implemented from HMAC so the modern transport
    /// remains available on the project's macOS 10.15 deployment target.
    /// Every current derivation requests exactly one SHA-256 output block.
    private static func deriveKey(input: Data, salt: Data, info: String) -> Data {
        let extractKey = SymmetricKey(data: salt)
        let prk = Data(HMAC<SHA256>.authenticationCode(for: input, using: extractKey))
        var expandInput = Data(info.utf8)
        expandInput.append(0x01)
        return Data(HMAC<SHA256>.authenticationCode(for: expandInput, using: SymmetricKey(data: prk)))
    }

    static func makeNonce(sequence: UInt64) throws -> AES.GCM.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        bytes.append(LegacyWire.uint64BE(sequence))
        do { return try AES.GCM.Nonce(data: bytes) }
        catch { throw Error.invalidNonce }
    }

    static func aad(domain: String, ciphertextLength: UInt32, sequence: UInt64) -> Data {
        var value = Data(domain.utf8)
        value.append(LegacyWire.uint32BE(ciphertextLength))
        value.append(LegacyWire.uint64BE(sequence))
        return value
    }
}

/// Stateful authenticated framing for an established control or transfer direction.
/// TCP preserves ordering; the explicit sequence additionally rejects replay and any
/// attempt to splice frames from another position in the stream.
final class CarrachoAEADChannel {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let domain: String
    private(set) var sendSequence: UInt64 = 0
    private(set) var receiveSequence: UInt64 = 0

    init(keys: CarrachoModernCrypto.DirectionalKeys, domain: String) throws {
        guard keys.send.count == 32, keys.receive.count == 32 else { throw CarrachoModernCrypto.Error.invalidKey }
        self.sendKey = SymmetricKey(data: keys.send)
        self.receiveKey = SymmetricKey(data: keys.receive)
        self.domain = domain
    }

    func seal(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= Int(UInt32.max) else {
            throw CarrachoModernCrypto.Error.invalidFrame("payload exceeds UInt32 length")
        }
        let sequence = sendSequence
        guard sequence != UInt64.max else { throw CarrachoModernCrypto.Error.sequenceExhausted }
        let length = UInt32(plaintext.count)
        let nonce = try CarrachoModernCrypto.makeNonce(sequence: sequence)
        let aad = CarrachoModernCrypto.aad(domain: domain, ciphertextLength: length, sequence: sequence)
        let box = try AES.GCM.seal(plaintext, using: sendKey, nonce: nonce, authenticating: aad)
        var frame = LegacyWire.uint32BE(length)
        frame.append(LegacyWire.uint64BE(sequence))
        frame.append(box.ciphertext)
        frame.append(box.tag)
        sendSequence &+= 1
        return frame
    }

    func open(_ frame: Data, maximumCiphertextLength: Int) throws -> Data {
        guard frame.count >= CarrachoModernCrypto.frameHeaderLength + CarrachoModernCrypto.tagLength else {
            throw CarrachoModernCrypto.Error.invalidFrame("frame is truncated")
        }
        var cursor = LegacyByteCursor(frame)
        let length = Int(try cursor.readUInt32BE())
        let sequence = try cursor.readUInt64BE()
        guard length >= 0, length <= maximumCiphertextLength else {
            throw CarrachoModernCrypto.Error.invalidFrame("ciphertext length \(length) exceeds limit")
        }
        guard sequence == receiveSequence else {
            throw CarrachoModernCrypto.Error.invalidFrame("unexpected sequence \(sequence), expected \(receiveSequence)")
        }
        guard cursor.remaining == length + CarrachoModernCrypto.tagLength else {
            throw CarrachoModernCrypto.Error.invalidFrame("declared length does not match frame")
        }
        let ciphertext = try cursor.readBytes(count: length)
        let tag = try cursor.readBytes(count: CarrachoModernCrypto.tagLength)
        let nonce = try CarrachoModernCrypto.makeNonce(sequence: sequence)
        let aad = CarrachoModernCrypto.aad(domain: domain, ciphertextLength: UInt32(length), sequence: sequence)
        do {
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let plaintext = try AES.GCM.open(box, using: receiveKey, authenticating: aad)
            guard receiveSequence != UInt64.max else { throw CarrachoModernCrypto.Error.sequenceExhausted }
            receiveSequence &+= 1
            return plaintext
        } catch let error as CarrachoModernCrypto.Error {
            throw error
        } catch {
            throw CarrachoModernCrypto.Error.authenticationFailed
        }
    }
}
