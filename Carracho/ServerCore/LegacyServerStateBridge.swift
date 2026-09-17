import Foundation

nonisolated private func makeLegacyPermissionBytes(mode: ServerAccountMode, permissions: Set<ServerPermission>,
                                                    includeCarrachoExtensions: Bool = false) -> Data {
    var bytes = Data(repeating: 0, count: 8)
    func setBit(_ bit: Int) {
        guard bit >= 0, bit < 64 else { return }
        bytes[bit / 8] |= UInt8(0x80 >> (bit % 8))
    }
    switch mode {
    case .administrator: setBit(LegacyAccountPermissionBit.administrator)
    case .accountHolder: setBit(LegacyAccountPermissionBit.accountHolder)
    case .guest: break
    }
    for permission in permissions where includeCarrachoExtensions || permission.isClassicPermission {
        setBit(permission.rawValue)
    }
    return bytes
}

nonisolated private func modeAndPermissions(from bytes: Data) throws -> (ServerAccountMode, Set<ServerPermission>) {
    let raw = [UInt8](bytes)
    guard raw.count == 8 else { throw ServerStateError.invalidValue("Classic permission record is invalid.") }
    func bit(_ index: Int) -> Bool { (raw[index / 8] & UInt8(0x80 >> (index % 8))) != 0 }
    let mode: ServerAccountMode = bit(LegacyAccountPermissionBit.administrator) ? .administrator
        : bit(LegacyAccountPermissionBit.accountHolder) ? .accountHolder : .guest
    return (mode, Set(ServerPermission.allCases.filter { bit($0.rawValue) }))
}

extension ServerAccountGroup {
    func legacyGroupRecord() -> LegacyAccountGroupRecord {
        let modeValue: UInt8
        switch legacyMode {
        case .guest: modeValue = 0
        case .accountHolder: modeValue = 1
        case .administrator: modeValue = 2
        }
        return LegacyAccountGroupRecord(id: id, name: name, colorRGB: colorRGB, legacyMode: modeValue,
                                        permissionBytes: makeLegacyPermissionBytes(mode: legacyMode, permissions: permissions,
                                                                                  includeCarrachoExtensions: true),
                                        filesRootPath: filesRootPath, filesRootName: effectiveFilesRootName)
    }

    nonisolated init(legacy record: LegacyAccountGroupRecord) throws {
        let decoded = try modeAndPermissions(from: record.permissionBytes)
        let mode: ServerAccountMode
        switch record.legacyMode {
        case 2: mode = .administrator
        case 1: mode = .accountHolder
        default: mode = .guest
        }
        // The explicit mode byte is authoritative; permission bytes still carry Classic compatibility bits.
        self.init(id: record.id, name: record.name, colorRGB: record.colorRGB,
                  legacyMode: mode, permissions: decoded.1, filesRootPath: record.filesRootPath,
                  filesRootName: record.filesRootPath.isEmpty ? ServerAccountGroup.defaultFilesRootName : record.filesRootName)
    }
}

extension ServerAccount {
    func permissionBytes(includeCarrachoExtensions: Bool) -> Data {
        var bytes = makeLegacyPermissionBytes(mode: mode, permissions: permissions,
                                              includeCarrachoExtensions: includeCarrachoExtensions)
        func setBit(_ bit: Int) { bytes[bit / 8] |= UInt8(0x80 >> (bit % 8)) }
        switch personalDirectory {
        case .none: break
        case .nestedInRoot: setBit(LegacyAccountPermissionBit.personalDirectoryNestedInRoot)
        case .rootDirectory: setBit(LegacyAccountPermissionBit.personalDirectoryIsRoot)
        }
        return bytes
    }

    /// Bytes safe to expose to an original Classic client. Carracho-only permissions are omitted.
    var legacyPermissionBytes: Data { permissionBytes(includeCarrachoExtensions: false) }
}

extension ServerNewsgroupAccess {
    var legacyFlags: UInt16 {
        let values = [administratorsRead, administratorsPost, accountHoldersRead, accountHoldersPost, guestsRead, guestsPost]
        var flags: UInt16 = 0
        for (index, enabled) in values.enumerated() where enabled {
            flags |= UInt16(0x8000 >> index)
        }
        return flags
    }
}

private let legacyMacEpochOffset: TimeInterval = 2_082_844_800

extension Date {
    var legacyMacTimestamp: UInt32 {
        let value = max(0, timeIntervalSince1970 + legacyMacEpochOffset)
        return UInt32(min(value, TimeInterval(UInt32.max)))
    }

    static func fromLegacyMacTimestamp(_ value: UInt32) -> Date? {
        guard value != 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value) - legacyMacEpochOffset)
    }
}

extension ServerAccount {
    func legacyRecord(includePassword: Bool = true, includeCarrachoExtensions: Bool = false) throws -> LegacyAccountRecord {
        let loginData = try Self.legacyMacRoman(login, field: "account login")
        let nameData = try Self.legacyMacRoman(name, field: "account name")
        let passwordData: Data
        if includePassword, let legacyPassword {
            passwordData = try Self.legacyMacRoman(legacyPassword, field: "account password")
        } else {
            passwordData = Data()
        }
        return LegacyAccountRecord(login: loginData,
                                   name: nameData,
                                   password: passwordData,
                                   created: createdAt.legacyMacTimestamp,
                                   modified: modifiedAt.legacyMacTimestamp,
                                   lastLogin: lastLoginAt?.legacyMacTimestamp ?? 0,
                                   permissionBytes: permissionBytes(includeCarrachoExtensions: includeCarrachoExtensions))
    }

    func legacyCompactSummary() throws -> LegacyCompactAccountSummary {
        let modeValue: UInt8
        switch mode {
        case .guest: modeValue = LegacyCompactAccountSummary.UserMode.guest.rawValue
        case .accountHolder: modeValue = LegacyCompactAccountSummary.UserMode.accountHolder.rawValue
        case .administrator: modeValue = LegacyCompactAccountSummary.UserMode.administrator.rawValue
        }
        return LegacyCompactAccountSummary(login: try Self.legacyMacRoman(login, field: "account login"),
                                           name: try Self.legacyMacRoman(name, field: "account name"),
                                           lastLogin: lastLoginAt?.legacyMacTimestamp ?? 0,
                                           userMode: modeValue,
                                           legacyPadding: 0)
    }

    static func fromLegacyRecord(_ record: LegacyAccountRecord, id: UUID = UUID(),
                                 allowCarrachoExtensions: Bool = false) throws -> (account: ServerAccount, password: String) {
        guard let login = String(data: record.login, encoding: .macOSRoman), !login.isEmpty,
              let name = String(data: record.name, encoding: .macOSRoman),
              let password = String(data: record.password, encoding: .macOSRoman) else {
            throw ServerStateError.invalidValue("Classic account contains invalid MacRoman text.")
        }
        let bytes = [UInt8](record.permissionBytes)
        guard bytes.count == 8 else { throw ServerStateError.invalidValue("Classic account permission record is invalid.") }
        func bit(_ index: Int) -> Bool {
            (bytes[index / 8] & UInt8(0x80 >> (index % 8))) != 0
        }
        let mode: ServerAccountMode
        if bit(LegacyAccountPermissionBit.administrator) { mode = .administrator }
        else if bit(LegacyAccountPermissionBit.accountHolder) { mode = .accountHolder }
        else { mode = .guest }
        let personal: ServerPersonalDirectoryMode
        if bit(LegacyAccountPermissionBit.personalDirectoryIsRoot) { personal = .rootDirectory }
        else if bit(LegacyAccountPermissionBit.personalDirectoryNestedInRoot) { personal = .nestedInRoot }
        else { personal = .none }
        let permissions = Set(ServerPermission.allCases.filter { permission in
            (allowCarrachoExtensions || permission.isClassicPermission) && bit(permission.rawValue)
        })
        let created = Date.fromLegacyMacTimestamp(record.created) ?? Date()
        let modified = Date.fromLegacyMacTimestamp(record.modified) ?? created
        return (ServerAccount(id: id, login: login, name: name, legacyPassword: password,
                              mode: mode, personalDirectory: personal, permissions: permissions,
                              createdAt: created, modifiedAt: modified,
                              lastLoginAt: Date.fromLegacyMacTimestamp(record.lastLogin)), password)
    }

    private static func legacyMacRoman(_ value: String, field: String) throws -> Data {
        guard let data = value.data(using: .macOSRoman) else {
            throw ServerStateError.invalidValue("\(field) is not representable in MacRoman.")
        }
        return data
    }
}

extension ServerNewsgroupAccess {
    init(legacyFlags: UInt16) {
        administratorsRead = legacyFlags & 0x8000 != 0
        administratorsPost = legacyFlags & 0x4000 != 0
        accountHoldersRead = legacyFlags & 0x2000 != 0
        accountHoldersPost = legacyFlags & 0x1000 != 0
        guestsRead = legacyFlags & 0x0800 != 0
        guestsPost = legacyFlags & 0x0400 != 0
    }
}

extension ServerIPRestriction {
    nonisolated init(legacy: LegacyIPRestriction) {
        network = legacy.network
        mask = legacy.mask
        deny = legacy.deny
        reserved = legacy.reserved
    }

    var legacy: LegacyIPRestriction {
        LegacyIPRestriction(network: network, mask: mask, deny: deny, reserved: reserved)
    }
}

extension ServerTrackerSetting {
    nonisolated init(legacy: LegacyTrackerSettingRecord) throws {
        guard let name = String(data: legacy.name, encoding: .macOSRoman),
              let address = String(data: legacy.address, encoding: .macOSRoman),
              let reserved = String(data: legacy.reservedString, encoding: .macOSRoman) else {
            throw ServerStateError.invalidValue("Classic tracker record contains invalid MacRoman text.")
        }
        self.init(name: name, address: address, reservedString: reserved, reservedValue: legacy.reservedValue)
    }

    func legacyRecord() throws -> LegacyTrackerSettingRecord {
        guard let name = name.data(using: .macOSRoman),
              let address = address.data(using: .macOSRoman),
              let reserved = reservedString.data(using: .macOSRoman) else {
            throw ServerStateError.invalidValue("Tracker record is not representable in MacRoman.")
        }
        return LegacyTrackerSettingRecord(name: name, address: address, reservedString: reserved, reservedValue: reservedValue)
    }
}
