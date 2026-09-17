import Foundation

enum LegacyAuthentication {
    static let initialControlKey = Data("YOYO".utf8)

    static func deriveSessionKey(password: Data, challenge: Data) throws -> Data {
        guard challenge.count >= 12 else {
            throw LegacyProtocolError.invalidLength("login challenge must contain at least 12 bytes")
        }
        let passwordBytes = Array(password)
        let challengeBytes = Array(challenge.prefix(12))
        var result = Data()

        if passwordBytes.count < 13 {
            var filler: UInt8 = 1
            for index in 0..<12 {
                let value: UInt8
                if index < passwordBytes.count {
                    value = passwordBytes[index]
                } else {
                    value = filler
                    filler &+= 1
                }
                result.append(value ^ 0x21)
                result.append(challengeBytes[index])
            }
        } else {
            var filler: UInt8 = 1
            for (index, value) in passwordBytes.enumerated() {
                result.append(value ^ 0x21)
                if index < 12 {
                    result.append(challengeBytes[index])
                } else {
                    result.append(filler)
                    filler &+= 1
                }
            }
        }
        return result
    }

    static func deriveSessionKey(password: String, challenge: Data) throws -> Data {
        guard let passwordData = password.data(using: .macOSRoman) else {
            throw LegacyProtocolError.invalidRecord("password is not representable as MacRoman")
        }
        return try deriveSessionKey(password: passwordData, challenge: challenge)
    }

    static func loginDigestHexASCII(password: Data, challenge: Data) throws -> Data {
        LegacyMD5.hexDigestASCII(try deriveSessionKey(password: password, challenge: challenge))
    }
}
