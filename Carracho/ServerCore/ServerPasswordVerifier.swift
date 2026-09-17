import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

enum ServerPasswordAlgorithm: String, Codable {
    case pbkdf2SHA256 = "pbkdf2-sha256"
}

struct ServerPasswordVerifier: Codable, Equatable {
    var algorithm: ServerPasswordAlgorithm
    var iterations: UInt32
    var salt: Data
    var derivedKey: Data
}

enum ServerPasswordHasher {
    /// PBKDF2 is intentionally parameterized and versioned in the stored verifier so
    /// work factors can be raised later without changing the account schema.
    static let defaultIterations: UInt32 = 210_000
    static let saltLength = 16
    static let derivedKeyLength = 32

    static func makeVerifier(password: String,
                             iterations: UInt32 = defaultIterations,
                             salt: Data? = nil) -> ServerPasswordVerifier {
        let actualSalt = salt ?? randomBytes(count: saltLength)
        let key = PBKDF2SHA256.derive(password: Data(password.utf8),
                                     salt: actualSalt,
                                     iterations: iterations,
                                     outputByteCount: derivedKeyLength)
        return ServerPasswordVerifier(algorithm: .pbkdf2SHA256,
                                      iterations: iterations,
                                      salt: actualSalt,
                                      derivedKey: key)
    }

    static func verify(password: String, against verifier: ServerPasswordVerifier) -> Bool {
        guard verifier.algorithm == .pbkdf2SHA256,
              verifier.iterations > 0,
              verifier.salt.count >= 16,
              verifier.derivedKey.count >= 16 else { return false }
        let candidate = PBKDF2SHA256.derive(password: Data(password.utf8),
                                            salt: verifier.salt,
                                            iterations: verifier.iterations,
                                            outputByteCount: verifier.derivedKey.count)
        return constantTimeEqual(candidate, verifier.derivedKey)
    }

    private static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        let a = [UInt8](lhs)
        let b = [UInt8](rhs)
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

private enum PBKDF2SHA256 {
    static func derive(password: Data, salt: Data, iterations: UInt32, outputByteCount: Int) -> Data {
        precondition(iterations > 0 && outputByteCount > 0)
#if canImport(CommonCrypto)
        let passwordBytes = [UInt8](password)
        let saltBytes = [UInt8](salt)
        var derivedKey = [UInt8](repeating: 0, count: outputByteCount)
        let status: Int32 = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
            saltBytes.withUnsafeBufferPointer { saltBuffer in
                derivedKey.withUnsafeMutableBufferPointer { outputBuffer in
                    let passwordPointer = passwordBuffer.baseAddress.map {
                        UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self)
                    }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPointer,
                        passwordBuffer.count,
                        saltBuffer.baseAddress,
                        saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        outputBuffer.baseAddress,
                        outputBuffer.count
                    )
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2-SHA256 derivation failed with status \(status)")
        return Data(derivedKey)
#else
        let hashLength = 32
        let blockCount = (outputByteCount + hashLength - 1) / hashLength
        var output = Data()
        output.reserveCapacity(blockCount * hashLength)

        for blockIndex in 1 ... blockCount {
            var firstInput = salt
            let counter = UInt32(blockIndex).bigEndian
            withUnsafeBytes(of: counter) { firstInput.append(contentsOf: $0) }
            var u = HMACSHA256.authenticate(key: password, message: firstInput)
            var block = [UInt8](u)
            if iterations > 1 {
                for _ in 2 ... iterations {
                    u = HMACSHA256.authenticate(key: password, message: u)
                    let bytes = [UInt8](u)
                    for index in block.indices { block[index] ^= bytes[index] }
                }
            }
            output.append(contentsOf: block)
        }
        return output.prefix(outputByteCount)
#endif
    }
}

private enum HMACSHA256 {
    static func authenticate(key: Data, message: Data) -> Data {
        let blockSize = 64
        var keyBytes = [UInt8](key)
        if keyBytes.count > blockSize { keyBytes = [UInt8](SHA256.hash(Data(keyBytes))) }
        if keyBytes.count < blockSize { keyBytes += [UInt8](repeating: 0, count: blockSize - keyBytes.count) }

        var inner = [UInt8](repeating: 0, count: blockSize)
        var outer = [UInt8](repeating: 0, count: blockSize)
        for index in 0 ..< blockSize {
            inner[index] = keyBytes[index] ^ 0x36
            outer[index] = keyBytes[index] ^ 0x5c
        }
        var innerData = Data(inner)
        innerData.append(message)
        let innerHash = SHA256.hash(innerData)
        var outerData = Data(outer)
        outerData.append(innerHash)
        return SHA256.hash(outerData)
    }
}

private enum SHA256 {
    private static let initial: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    private static let constants: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
    ]

    static func hash(_ data: Data) -> Data {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        var beLength = bitLength.bigEndian
        withUnsafeBytes(of: &beLength) { message.append(contentsOf: $0) }

        var state = initial
        var schedule = [UInt32](repeating: 0, count: 64)
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            for index in 0 ..< 16 {
                let offset = chunkStart + index * 4
                schedule[index] = (UInt32(message[offset]) << 24) |
                    (UInt32(message[offset + 1]) << 16) |
                    (UInt32(message[offset + 2]) << 8) |
                    UInt32(message[offset + 3])
            }
            for index in 16 ..< 64 {
                let s0 = rotateRight(schedule[index - 15], by: 7) ^ rotateRight(schedule[index - 15], by: 18) ^ (schedule[index - 15] >> 3)
                let s1 = rotateRight(schedule[index - 2], by: 17) ^ rotateRight(schedule[index - 2], by: 19) ^ (schedule[index - 2] >> 10)
                schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
            }

            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for index in 0 ..< 64 {
                let s1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let choose = (e & f) ^ ((~e) & g)
                let temp1 = h &+ s1 &+ choose &+ constants[index] &+ schedule[index]
                let s0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
            state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
        }

        var result = Data()
        result.reserveCapacity(32)
        for word in state {
            result.append(UInt8(truncatingIfNeeded: word >> 24))
            result.append(UInt8(truncatingIfNeeded: word >> 16))
            result.append(UInt8(truncatingIfNeeded: word >> 8))
            result.append(UInt8(truncatingIfNeeded: word))
        }
        return result
    }

    private static func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
