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
        let guestID = UUID()
        let shared: [(userID: UInt32, accountID: UUID?)] =
            [(12, guestID), (34, guestID)]
        let conflict = PrivateMessageRecipientPolicy.trustedAccountID(
            userID: 34, accountID: guestID, nickname: "Zeb",
            otherUsers: shared, saved: (12, "Neverever"))
        precondition(conflict == nil, "Shared Guest UUID must not select Neverever")
        let stale = PrivateMessageRecipientPolicy.trustedAccountID(
            userID: 34, accountID: guestID, nickname: "Zeb",
            otherUsers: [(34, guestID)], saved: (nil, "Neverever"))
        precondition(stale == nil, "Neverever archive must not open for Zeb")
        print("PASS: shared Guest account and wrong saved nickname cannot cross-route PMs")
        // Three Guest reconnects should produce ONE visible row, with every session preserved.
        let t = Date()
        let oldGuestSessions = (0..<3).map { offset in
            GuestConversationPresentation.Session(
                id: UUID(), nickname: "Luigi", hasAccountIdentity: false,
                isLive: false, activity: t.addingTimeInterval(Double(offset)))
        }
        let collapsed = GuestConversationPresentation.visibleIDs(oldGuestSessions)
        precondition(collapsed.count == 1, "Three archived Guest sessions must not clutter the inbox")
        // A returning Guest must be detected from the current user list, before the
        // first new PM. A shared nickname with two live sessions remains ambiguous.
        let soleGuest = GuestConversationPresentation.uniqueLiveRecipient(
            for: "Luigi", users: [(userID: 76, nickname: "Luigi")])
        precondition(soleGuest == 76, "Returning Guest must become online automatically")
        let mixedNames = GuestConversationPresentation.uniqueLiveRecipient(
            for: "luigi", users: [(userID: 76, nickname: "Luigi"), (userID: 77, nickname: "Zeb")])
        precondition(mixedNames == 76)
        let twoSameNames = GuestConversationPresentation.uniqueLiveRecipient(
            for: "Luigi", users: [(userID: 76, nickname: "Luigi"),
                                 (userID: 88, nickname: "LUIGI")])
        precondition(twoSameNames == nil, "Duplicate Guest names must not select a random recipient")
        let absent = GuestConversationPresentation.uniqueLiveRecipient(
            for: "Luigi", users: [(userID: 77, nickname: "Zeb")])
        precondition(absent == nil, "Disconnected Guest must be offline")
        let fourth = GuestConversationPresentation.Session(
            id: UUID(), nickname: "Luigi", hasAccountIdentity: false,
            isLive: true, activity: t.addingTimeInterval(10))
        let reopened = GuestConversationPresentation.visibleIDs(oldGuestSessions + [fourth])
        precondition(reopened == Set([fourth.id]), "Fourth Guest session needs one live row")
        let twoLive = GuestConversationPresentation.Session(
            id: UUID(), nickname: "Luigi", hasAccountIdentity: false,
            isLive: true, activity: t.addingTimeInterval(11))
        let simultaneous = GuestConversationPresentation.visibleIDs(oldGuestSessions + [fourth, twoLive])
        precondition(simultaneous.contains(fourth.id) && simultaneous.contains(twoLive.id))
        precondition(simultaneous.count == 3,
                     "Identical nicknames in simultaneous sessions must remain separate")
        let verified = GuestConversationPresentation.Session(
            id: UUID(), nickname: "Luigi", hasAccountIdentity: true,
            isLive: false, activity: t)
        let withAccount = GuestConversationPresentation.visibleIDs(oldGuestSessions + [fourth, verified])
        precondition(withAccount.count == 2 && withAccount.contains(verified.id),
                     "Verified-account history must remain distinct from Guest group")
        print("PASS: returning Guest is recognized on arrival without a new message; ambiguous names stay unbound")
        print("PASS: 3 archived Guest chats appear as one, 4th session reuses row; concurrent users remain distinct")

        print("PASS: recycled userID isolated by conversation UUID, correct sender history retained")
        print("PASS: different server endpoints isolated, archive deletion cannot affect another peer")
    }
}
