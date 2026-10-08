import Foundation

/// Run with Tests/run-message-center-identity-regression.sh.
/// Exercises the actual SQLite store, not a mock of the private-message model.
@main
struct MessageCenterIdentityRegression {
    static func main() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("carracho-pm-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = MessageCenterStore(databaseURL: base.appendingPathComponent("messages.sqlite3"))
        let scope = MessageCenterStoreScope(host: "example.invalid", port: 6700, login: "admin")
        let otherScope = MessageCenterStoreScope(host: "other.invalid", port: 6700, login: "admin")
        let numericID: UInt32 = 42
        let nevereverEpoch = UUID()
        let zebEpoch = UUID()

        func conversation(_ nickname: String, body: String) -> MessageCenterStoredBootConversation {
            MessageCenterStoredBootConversation(
                userID: numericID, nickname: nickname, picture: Data(),
                isLegacyTransport: true, unreadCount: 1, draftText: "", lastActivity: Date(),
                messages: [MessageCenterStoredPrivateMessage(
                    id: UUID(), timestamp: Date(), outgoing: false,
                    message: Data(body.utf8)
                )]
            )
        }

        // Two different people received the exact same routing ID, without the server rebooting.
        try store.saveBootConversationHistory(conversation("Neverever", body: "old history"),
                                              scope: scope, bootID: nevereverEpoch)
        try store.saveBootConversationHistory(conversation("Zeb", body: "new history"),
                                              scope: scope, bootID: zebEpoch)

        let histories = try store.loadArchivedLegacyConversations(scope: scope)
        precondition(histories.count == 2, "Two routing leases must remain separate")
        let byEpoch = Dictionary(uniqueKeysWithValues: histories.map { ($0.bootID, $0.conversation) })
        precondition(byEpoch[nevereverEpoch]?.nickname == "Neverever")
        precondition(byEpoch[zebEpoch]?.nickname == "Zeb")
        precondition(byEpoch[nevereverEpoch]?.messages.map(\.message) == [Data("old history".utf8)])
        precondition(byEpoch[zebEpoch]?.messages.map(\.message) == [Data("new history".utf8)])
        let otherHistories = try store.loadArchivedLegacyConversations(scope: otherScope)
        precondition(otherHistories.isEmpty, "History must never cross bookmark endpoints")

        // Clearing one person's history may not touch the other person with the same ID.
        try store.deleteBootConversation(userID: numericID, scope: scope, bootID: zebEpoch)
        let remaining = try store.loadArchivedLegacyConversations(scope: scope)
        precondition(remaining.count == 1 && remaining[0].bootID == nevereverEpoch)
        precondition(remaining[0].conversation.messages[0].message == Data("old history".utf8))
        print("PASS: recycled userID isolated by conversation UUID, correct sender history retained")
        print("PASS: different server endpoints isolated, archive deletion cannot affect another peer")
    }
}
