import Foundation

// Only the picture-size constant is needed from the wire protocol in this standalone
// SQLite/backends regression. The full app builds with the production LegacyUserInfoField.
enum LegacyUserInfoField { static let maximumPictureLength = 65_535 }

@main
struct ServerStateConcurrencyRegression {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("carracho-server-db-regression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var store = ServerStateStore(url: root.appendingPathComponent("db/server.db"))
        store.passwordIterations = 1_000  // isolated test only; production verifier remains unchanged

        // Simulate independently launched Server GUI and background daemon holding stale
        // snapshots, but pointing to the exact same SQLite database.
        let gui = try ModernServerBackend(store: store)
        let daemon = try ModernServerBackend(store: store)
        let admin = try requireAdmin(gui.snapshot())
        let oldAccountIDs = Set(gui.snapshot().accounts.map(\.id))

        let zeb = try daemon.createAccount(
            ServerAccount(login: "zeb", name: "Zeb", mode: .accountHolder), password: "Zeb-test-pw")
        let neverever = try daemon.createAccount(
            ServerAccount(login: "neverever", name: "Neverever", mode: .accountHolder),
            password: "Neverever-test-pw")
        let publicNews = try daemon.createNewsgroup(ServerNewsgroup(name: "Public Discussion"))
        var daemonIdentity = daemon.snapshot().identity
        daemonIdentity.description = "Preserved across GUI password changes"
        try daemon.updateIdentity(daemonIdentity)
        precondition(gui.snapshot().accounts.first(where: { $0.id == zeb.id }) == nil,
                     "Test must start from a stale GUI snapshot")

        // THIS WAS THE REAL BUG: a GUI password change previously rewrote the entire
        // accounts table with the GUI's stale original snapshot, erasing Zeb/Neverever.
        try gui.changePassword(accountID: admin.id, to: "new-admin-password")
        var reopened = try ModernServerBackend(store: store)
        let idsAfterPassword = Set(reopened.snapshot().accounts.map(\.id))
        precondition(idsAfterPassword.isSuperset(of: oldAccountIDs.union([zeb.id, neverever.id])),
                     "Admin password change erased accounts created by the daemon")
        precondition(reopened.authenticateModern(login: admin.login, password: "new-admin-password") != nil,
                     "New administrator password did not persist")
        precondition(reopened.authenticateModern(login: "zeb", password: "Zeb-test-pw") != nil)
        precondition(reopened.authenticateModern(login: "neverever", password: "Neverever-test-pw") != nil)
        precondition(reopened.snapshot().newsgroups.contains(where: { $0.id == publicNews.id }),
                     "Admin password change erased daemon-created newsgroups")
        precondition(reopened.snapshot().identity.description == daemonIdentity.description,
                     "Admin password change rolled back the server identity settings")
        print("PASS: stale GUI password change preserves daemon accounts, newsgroups and server settings")

        // Reverse the order too: the stale daemon must not reset the GUI's new user.
        let luigi = try gui.createAccount(
            ServerAccount(login: "luigi", name: "Luigi", mode: .accountHolder), password: "Luigi-test-pw")
        try daemon.mutateStatistics { $0.totalMessages += 1 }
        reopened = try ModernServerBackend(store: store)
        precondition(reopened.snapshot().accounts.contains(where: { $0.id == luigi.id }),
                     "A daemon state update erased a GUI-created account")
        precondition(reopened.snapshot().statistics.totalMessages == 1)
        print("PASS: stale daemon statistics update preserves GUI-created account")

        // Transaction rollback must preserve all records after an error.
        struct DeliberateFailure: Error {}
        do {
            try gui.updateServerState { state in
                state.accounts.removeAll()
                throw DeliberateFailure()
            }
            preconditionFailure("Expected transaction to throw")
        } catch is DeliberateFailure {}
        reopened = try ModernServerBackend(store: store)
        precondition(reopened.snapshot().accounts.contains(where: { $0.id == luigi.id }))
        precondition(reopened.snapshot().accounts.contains(where: { $0.id == zeb.id }))
        print("PASS: failed SQLite mutation rolls back without removing accounts")

        // Existing but uninitialized/corrupt database must fail closed, never seed admin/Guest.
        let corruptURL = root.appendingPathComponent("already-exists/server.db")
        try FileManager.default.createDirectory(at: corruptURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: corruptURL)
        do {
            var broken = ServerStateStore(url: corruptURL)
            broken.passwordIterations = 1_000
            _ = try broken.loadOrCreate()
            preconditionFailure("Existing incomplete DB must not be reset")
        } catch let error as ServerStateSQLiteError {
            guard case .corrupt = error else { throw error }
        }
        print("PASS: incomplete existing server.db is not silently reset")
    }

    static func requireAdmin(_ state: ServerState) throws -> ServerAccount {
        guard let account = state.accounts.first(where: { $0.mode == .administrator }) else {
            throw ServerStateError.invalidValue("Missing initial administrator")
        }
        return account
    }
}
