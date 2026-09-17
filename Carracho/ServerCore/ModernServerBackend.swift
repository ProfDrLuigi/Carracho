import Foundation
import Dispatch

/// Thread-safe, transactional configuration/authentication backend shared by the
/// macOS GUI and the behavioral/state reference for the native C Linux server.
final class ModernServerBackend {
    private let store: ServerStateStore
    private let queue = DispatchQueue(label: "com.carracho.server-state")
    private let dummyVerifier: ServerPasswordVerifier
    private var state: ServerState

    init(store: ServerStateStore) throws {
        self.store = store
        self.state = try store.loadOrCreate()
        self.dummyVerifier = self.state.accounts.compactMap(\.passwordVerifier).first
            ?? ServerPasswordHasher.makeVerifier(password: UUID().uuidString, iterations: store.passwordIterations)
    }

    func snapshot() -> ServerState { queue.sync { state } }

    func account(login: String) -> ServerAccount? {
        queue.sync { state.accounts.first { Self.sameName($0.login, login) } }
    }

    func localBotAccount() -> ServerAccount? {
        queue.sync { state.accounts.first { $0.id == ServerState.localBotAccountID && $0.isLocalLoginOnly } }
    }

    /// Creates the built-in Bot as a persisted account on first use. Editable profile fields are
    /// preserved on later launches; only the localhost-only security invariant is enforced.
    @discardableResult
    func ensureLocalBotAccount() throws -> ServerAccount {
        try transaction { state in
            if let index = state.accounts.firstIndex(where: { $0.id == ServerState.localBotAccountID }) {
                var account = state.accounts[index]
                account.localLoginOnly = true
                account.legacyPassword = nil
                account.acceptsOfflineMessages = false
                if account.passwordVerifier == nil {
                    account.passwordVerifier = ServerPasswordHasher.makeVerifier(
                        password: UUID().uuidString + UUID().uuidString, iterations: store.passwordIterations)
                }
                state.accounts[index] = account
                return account
            }

            var login = "bot"
            var suffix = 2
            while state.accounts.contains(where: { Self.sameName($0.login, login) }) {
                login = "bot-\(suffix)"
                suffix += 1
            }
            let group = state.accountGroups.first(where: { $0.id == ServerState.builtInMemberGroupID })
            let account = ServerAccount(
                id: ServerState.localBotAccountID, login: login, name: "Bot", legacyPassword: nil,
                passwordVerifier: ServerPasswordHasher.makeVerifier(
                    password: UUID().uuidString + UUID().uuidString, iterations: store.passwordIterations),
                mode: .accountHolder, groupID: ServerState.builtInMemberGroupID, personalDirectory: .none,
                permissions: [.joinChatRooms], colorRGB: group?.colorRGB ?? 0x0A84FF,
                localLoginOnly: true, acceptsOfflineMessages: false, lastNickname: "Bot")
            try ServerStateValidator.validate(account: account)
            state.accounts.append(account)
            state.accounts.sort { $0.login.localizedCaseInsensitiveCompare($1.login) == .orderedAscending }
            return account
        }
    }

    func offlineMessageRecipient(login: String) -> ServerAccount? {
        queue.sync { state.accounts.first(where: { Self.sameName($0.login, login) && !$0.isLocalLoginOnly && $0.offlineMessagesEnabled }) }
    }

    func offlineMessageRecipients() -> [ServerAccount] {
        queue.sync {
            state.accounts.filter { !$0.isLocalLoginOnly && $0.offlineMessagesEnabled }.sorted {
                let left = $0.lastNickname?.isEmpty == false ? $0.lastNickname! : ($0.name.isEmpty ? $0.login : $0.name)
                let right = $1.lastNickname?.isEmpty == false ? $1.lastNickname! : ($1.name.isEmpty ? $1.login : $1.name)
                let comparison = left.localizedCaseInsensitiveCompare(right)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return $0.login.localizedCaseInsensitiveCompare($1.login) == .orderedAscending
            }
        }
    }

    @discardableResult
    func updateOfflineMessagePreference(accountID: UUID, enabled: Bool, nickname: String?) throws -> ServerAccount {
        try transaction { state in
            guard let index = state.accounts.firstIndex(where: { $0.id == accountID }) else {
                throw ServerStateError.accountNotFound(accountID)
            }
            state.accounts[index].acceptsOfflineMessages = enabled
            if let nickname, !nickname.isEmpty { state.accounts[index].lastNickname = nickname }
            state.accounts[index].modifiedAt = Date()
            return state.accounts[index]
        }
    }

    func updateLastNickname(accountID: UUID, nickname: String) throws {
        guard !nickname.isEmpty else { return }
        try transaction { state in
            guard let index = state.accounts.firstIndex(where: { $0.id == accountID }) else { return }
            state.accounts[index].lastNickname = nickname
        }
    }

    @discardableResult
    func enqueueOfflineMessage(recipientAccountID: UUID, plaintext: Data, createdAtUnix: UInt64 = UInt64(Date().timeIntervalSince1970)) throws -> String {
        try queue.sync { try store.enqueueOfflineMessage(recipientAccountID: recipientAccountID, plaintext: plaintext, createdAtUnix: createdAtUnix) }
    }

    func offlineMessageCount(recipientAccountID: UUID) throws -> Int {
        try queue.sync { try store.offlineMessageCount(recipientAccountID: recipientAccountID) }
    }

    func loadOfflineMessages(recipientAccountID: UUID) throws -> [ServerStoredOfflineMessage] {
        try queue.sync { try store.loadOfflineMessages(recipientAccountID: recipientAccountID) }
    }

    func acknowledgeOfflineMessages(recipientAccountID: UUID, ids: [String]) throws {
        try queue.sync { try store.acknowledgeOfflineMessages(recipientAccountID: recipientAccountID, ids: ids) }
    }

    /// Modern authentication always performs a verifier calculation, including for
    /// unknown users, to avoid an obvious fast-path username oracle.
    func authenticateModern(login: String, password: String) -> ServerAccount? {
        let account: ServerAccount? = queue.sync {
            state.accounts.first { Self.sameName($0.login, login) }
        }
        let verifier = account?.passwordVerifier ?? dummyVerifier
        let valid = ServerPasswordHasher.verify(password: password, against: verifier)
        // Local-only accounts still pay the verifier cost, but they can never authenticate remotely.
        return valid && account?.isLocalLoginOnly != true ? account : nil
    }

    /// Returns password-equivalent material only while legacy compatibility is enabled.
    func legacyPasswordForLogin(_ login: String) -> String? {
        queue.sync {
            guard state.authentication.mode == .legacyCompatible,
                  let account = state.accounts.first(where: { Self.sameName($0.login, login) }),
                  !account.isLocalLoginOnly else { return nil }
            return account.legacyPassword
        }
    }

    @discardableResult
    func createAccount(_ account: ServerAccount, password: String? = nil) throws -> ServerAccount {
        try transaction { state in
            guard !state.accounts.contains(where: { Self.sameName($0.login, account.login) }) else {
                throw ServerStateError.duplicateAccount(account.login)
            }
            var value = account
            try Self.applyGroup(to: &value, in: state, existing: nil)
            try Self.applyCredentials(to: &value,
                                      explicitPassword: password,
                                      existing: nil,
                                      authenticationMode: state.authentication.mode,
                                      iterations: store.passwordIterations)
            try ServerStateValidator.validate(account: value)
            let now = Date()
            value.createdAt = now
            value.modifiedAt = now
            state.accounts.append(value)
            state.accounts.sort { $0.login.localizedCaseInsensitiveCompare($1.login) == .orderedAscending }
            try ServerStateValidator.validateTrackerRegistrationEligibility(state)
            return value
        }
    }

    @discardableResult
    func updateAccount(id: UUID, with replacement: ServerAccount, newPassword: String? = nil) throws -> ServerAccount {
        try transaction { state in
            guard let index = state.accounts.firstIndex(where: { $0.id == id }) else {
                throw ServerStateError.accountNotFound(id)
            }
            guard !state.accounts.enumerated().contains(where: {
                $0.offset != index && Self.sameName($0.element.login, replacement.login)
            }) else {
                throw ServerStateError.duplicateAccount(replacement.login)
            }
            var value = replacement
            value.id = state.accounts[index].id
            value.createdAt = state.accounts[index].createdAt
            value.localLoginOnly = state.accounts[index].localLoginOnly
            value.acceptsOfflineMessages = state.accounts[index].acceptsOfflineMessages
            value.lastNickname = state.accounts[index].lastNickname
            value.modifiedAt = Date()
            try Self.applyGroup(to: &value, in: state, existing: state.accounts[index])
            try Self.applyCredentials(to: &value,
                                      explicitPassword: value.isLocalLoginOnly ? nil : newPassword,
                                      existing: state.accounts[index],
                                      authenticationMode: state.authentication.mode,
                                      iterations: store.passwordIterations)
            if value.isLocalLoginOnly { value.legacyPassword = nil }
            try ServerStateValidator.validate(account: value)
            state.accounts[index] = value
            state.accounts.sort { $0.login.localizedCaseInsensitiveCompare($1.login) == .orderedAscending }
            try ServerStateValidator.validateTrackerRegistrationEligibility(state)
            return value
        }
    }

    @discardableResult
    func changePassword(accountID: UUID, to newPassword: String) throws -> ServerAccount {
        try transaction { state in
            guard let index = state.accounts.firstIndex(where: { $0.id == accountID }) else {
                throw ServerStateError.accountNotFound(accountID)
            }
            let existing = state.accounts[index]
            guard !existing.isLocalLoginOnly else {
                throw ServerStateError.invalidValue("Local-only accounts do not use network passwords.")
            }
            var value = existing
            value.modifiedAt = Date()
            try Self.applyCredentials(to: &value,
                                      explicitPassword: newPassword,
                                      existing: existing,
                                      authenticationMode: state.authentication.mode,
                                      iterations: store.passwordIterations)
            try ServerStateValidator.validate(account: value)
            state.accounts[index] = value
            try ServerStateValidator.validateTrackerRegistrationEligibility(state)
            return value
        }
    }

    func deleteAccount(id: UUID) throws {
        try transaction { state in
            guard let index = state.accounts.firstIndex(where: { $0.id == id }) else { throw ServerStateError.accountNotFound(id) }
            guard !state.accounts[index].isLocalLoginOnly else {
                throw ServerStateError.invalidValue("The built-in Bot account cannot be deleted. Disconnect it from the Bot tab instead.")
            }
            state.accounts.remove(at: index)
            try ServerStateValidator.validateTrackerRegistrationEligibility(state)
        }
    }

    @discardableResult
    func createAccountGroup(_ group: ServerAccountGroup) throws -> ServerAccountGroup {
        throw ServerStateError.invalidValue("Custom account groups are no longer supported. Edit Administrator, Account Holder or Guest instead.")
    }

    @discardableResult
    func updateAccountGroup(id: UUID, with replacement: ServerAccountGroup) throws -> ServerAccountGroup {
        try transaction { state in
            guard let index = state.accountGroups.firstIndex(where: { $0.id == id }) else {
                throw ServerStateError.accountGroupNotFound(id)
            }
            let existing = state.accountGroups[index]
            guard id == ServerState.builtInAccountGroupID(for: existing.legacyMode) else {
                throw ServerStateError.invalidValue("Only the three fixed Classic account groups may be edited.")
            }
            var value = replacement
            value.id = id
            value.legacyMode = existing.legacyMode
            value.name = ServerState.builtInAccountGroupName(for: existing.legacyMode)
            try ServerStateValidator.validate(accountGroup: value)
            state.accountGroups[index] = value
            // Existing accounts keep their copied permissions and nickname color. Changing a
            // class only changes the defaults applied to subsequent assignments.
            return value
        }
    }

    func deleteAccountGroup(id: UUID) throws {
        guard ServerState.builtInAccountGroupOrder.contains(id) else {
            throw ServerStateError.accountGroupNotFound(id)
        }
        throw ServerStateError.invalidValue("Administrator, Account Holder and Guest are fixed and cannot be deleted.")
    }

    @discardableResult
    func createNewsgroup(_ group: ServerNewsgroup) throws -> ServerNewsgroup {
        try transaction { state in
            try ServerStateValidator.validate(newsgroup: group)
            guard !state.newsgroups.contains(where: { Self.sameName($0.name, group.name) }) else {
                throw ServerStateError.duplicateNewsgroup(group.name)
            }
            state.newsgroups.append(group)
            state.newsgroups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return group
        }
    }

    @discardableResult
    func updateNewsgroup(id: UUID, with replacement: ServerNewsgroup) throws -> ServerNewsgroup {
        try transaction { state in
            guard let index = state.newsgroups.firstIndex(where: { $0.id == id }) else { throw ServerStateError.newsgroupNotFound(id) }
            guard !state.newsgroups.enumerated().contains(where: {
                $0.offset != index && Self.sameName($0.element.name, replacement.name)
            }) else { throw ServerStateError.duplicateNewsgroup(replacement.name) }
            try ServerStateValidator.validate(newsgroup: replacement)
            var value = replacement
            value.id = state.newsgroups[index].id
            value.articleCount = state.newsgroups[index].articleCount
            state.newsgroups[index] = value
            state.newsgroups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return value
        }
    }

    func deleteNewsgroup(id: UUID) throws {
        try transaction { state in
            guard let index = state.newsgroups.firstIndex(where: { $0.id == id }) else { throw ServerStateError.newsgroupNotFound(id) }
            state.newsgroups.remove(at: index)
        }
    }

    func updateIdentity(_ identity: ServerIdentity) throws {
        try transaction { state in
            try ServerStateValidator.validate(identity: identity)
            state.identity = identity
        }
    }

    func updateAgreement(_ agreement: ServerAgreement) throws {
        try transaction { state in
            guard agreement.text.utf8.count <= 64 * 1024 else { throw ServerStateError.invalidValue("Agreement exceeds 64 KiB.") }
            state.agreement = agreement
        }
    }

    func updateAdvanced(_ advanced: ServerAdvancedSettings) throws {
        try transaction { state in
            try ServerStateValidator.validate(advanced: advanced)
            state.advanced = advanced
            try ServerStateValidator.validateTrackerRegistrationEligibility(state)
        }
    }

    func updateAdvanced(_ advanced: ServerAdvancedSettings, authenticationMode: ServerAuthenticationMode) throws {
        try transaction { state in
            try ServerStateValidator.validate(advanced: advanced)
            state.advanced = advanced
            try Self.applyAuthenticationMode(authenticationMode, to: &state, iterations: store.passwordIterations)
            try ServerStateValidator.validateTrackerRegistrationEligibility(state)
        }
    }

    func updateAuthenticationMode(_ mode: ServerAuthenticationMode) throws {
        try transaction { state in
            try Self.applyAuthenticationMode(mode, to: &state, iterations: store.passwordIterations)
            try ServerStateValidator.validateTrackerRegistrationEligibility(state)
        }
    }

    func updateRuntime(_ runtime: ServerRuntimeSettings) throws {
        try transaction { state in state.runtime = runtime }
    }

    /// Applies the startup-controlled configuration in one persisted transaction.
    /// Accounts, bans, trackers and the non-configured identity fields remain database-managed.
    func reconcileStartupConfiguration(identity: ServerIdentity,
                                       advanced: ServerAdvancedSettings,
                                       authenticationMode: ServerAuthenticationMode,
                                       runtime: ServerRuntimeSettings) throws {
        try transaction { state in
            try ServerStateValidator.validate(identity: identity)
            try ServerStateValidator.validate(advanced: advanced)
            state.identity = identity
            state.advanced = advanced
            state.runtime = runtime
            try Self.applyAuthenticationMode(authenticationMode, to: &state, iterations: store.passwordIterations)
        }
    }

    func mutateStatistics(_ body: (inout ServerStatistics) -> Void) throws {
        try transaction { state in body(&state.statistics) }
    }

    func recordCompletedTransfer(accountID: UUID, login: String, direction: ServerTransferStatisticDirection, bytes: UInt64) throws {
        try queue.sync { try store.recordCompletedTransfer(accountID: accountID, login: login, direction: direction, bytes: bytes) }
    }

    func accountTransferStatistics() throws -> [ServerAccountTransferStatistics] {
        try queue.sync { try store.loadAccountTransferStatistics() }
    }

    /// Transactional mutation used by protocol adapters that update several related
    /// configuration fields in one legacy command. Persistence remains atomic.
    func updateServerState(_ body: (inout ServerState) throws -> Void) throws {
        try transaction { state in try body(&state) }
    }

    func recordSuccessfulLogin(accountID: UUID, at date: Date = Date()) throws {
        try transaction { state in
            guard let index = state.accounts.firstIndex(where: { $0.id == accountID }) else { return }
            state.accounts[index].lastLoginAt = date
        }
    }

    /// `articleCount` is a persisted cache of the separate News store. The News
    /// store remains authoritative and the runtime reconciles these values at startup.
    func updateNewsgroupArticleCounts(_ counts: [UUID: UInt32]) throws {
        guard !counts.isEmpty else { return }
        try transaction { state in
            for index in state.newsgroups.indices {
                if let count = counts[state.newsgroups[index].id] {
                    state.newsgroups[index].articleCount = count
                }
            }
        }
    }

    /// Used by protocol adapters while they already own a backend transaction. This deliberately
    /// performs no nested queue/transaction work; it only applies the same credential migration
    /// rules as updateAdvanced/updateAuthenticationMode to the supplied transactional state.
    func applyAuthenticationModeInTransaction(_ mode: ServerAuthenticationMode, to state: inout ServerState) throws {
        try Self.applyAuthenticationMode(mode, to: &state, iterations: store.passwordIterations)
    }

    private static func applyAuthenticationMode(_ mode: ServerAuthenticationMode,
                                                to state: inout ServerState,
                                                iterations: UInt32) throws {
        if mode == .modernOnly {
            for index in state.accounts.indices {
                if state.accounts[index].passwordVerifier == nil {
                    guard let password = state.accounts[index].legacyPassword else {
                        throw ServerStateError.invalidValue("Account “\(state.accounts[index].login)” cannot be converted to modern-only authentication without resetting its password.")
                    }
                    state.accounts[index].passwordVerifier = ServerPasswordHasher.makeVerifier(password: password, iterations: iterations)
                }
                state.accounts[index].legacyPassword = nil
            }
        }
        state.authentication.mode = mode
    }

    private static func applyGroup(to account: inout ServerAccount, in state: ServerState,
                                   existing: ServerAccount?) throws {
        let groupID = account.groupID ?? ServerState.builtInAccountGroupID(for: account.mode)
        guard let group = state.accountGroups.first(where: { $0.id == groupID }),
              group.id == ServerState.builtInAccountGroupID(for: group.legacyMode) else {
            throw ServerStateError.accountGroupNotFound(groupID)
        }
        account.groupID = group.id
        account.mode = group.legacyMode
        if account.colorRGB == nil {
            // Keeping an account in the same class preserves an individual color override.
            // Moving it to another class is an assignment and therefore starts with that
            // class's default color, exactly like selecting another group in the admin UI.
            if let existing, existing.groupID == group.id {
                account.colorRGB = existing.colorRGB ?? group.colorRGB
            } else {
                account.colorRGB = group.colorRGB
            }
        }
    }

    private static func applyCredentials(to account: inout ServerAccount,
                                         explicitPassword: String?,
                                         existing: ServerAccount?,
                                         authenticationMode: ServerAuthenticationMode,
                                         iterations: UInt32) throws {
        if let explicitPassword {
            if authenticationMode == .legacyCompatible {
                guard let classic = explicitPassword.data(using: .macOSRoman), classic.count <= 64 else {
                    throw ServerStateError.invalidValue("Legacy-compatible passwords must be representable in MacRoman and may not exceed 64 bytes.")
                }
            } else if explicitPassword.utf8.count > 1024 {
                throw ServerStateError.invalidValue("Password exceeds 1024 UTF-8 bytes.")
            }
            account.passwordVerifier = ServerPasswordHasher.makeVerifier(password: explicitPassword, iterations: iterations)
            account.legacyPassword = authenticationMode == .legacyCompatible ? explicitPassword : nil
        } else if let existing {
            account.passwordVerifier = existing.passwordVerifier
            account.legacyPassword = authenticationMode == .legacyCompatible ? existing.legacyPassword : nil
        } else if let legacyPassword = account.legacyPassword {
            account.passwordVerifier = ServerPasswordHasher.makeVerifier(password: legacyPassword, iterations: iterations)
            if authenticationMode == .modernOnly { account.legacyPassword = nil }
        } else if account.passwordVerifier == nil {
            throw ServerStateError.invalidValue("A password is required for a new account.")
        }
    }

    /// Applies to a copy, persists the copy atomically, and only then publishes it.
    private func transaction<T>(_ body: (inout ServerState) throws -> T) throws -> T {
        try queue.sync {
            var candidate = state
            let result = try body(&candidate)
            let persisted = try store.save(candidate)
            state = persisted
            return result
        }
    }

    private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
