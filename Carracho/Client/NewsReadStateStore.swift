import Foundation

struct NewsReadState: Codable, Equatable {
    private(set) var initializedCategories: Set<String> = []
    private(set) var seenPostCounts: [String: [String: UInt32]] = [:]

    private static func categoryKey(_ category: Data) -> String { category.base64EncodedString() }
    private static func threadKey(_ threadID: UInt32) -> String { String(threadID) }

    /// Establishes the first snapshot as a read baseline. Later snapshots only
    /// prune deleted threads, so increases and newly appearing thread IDs become unread.
    @discardableResult
    mutating func reconcile(category: Data, totals: [UInt32: UInt32]) -> Bool {
        let categoryKey = Self.categoryKey(category)
        let validKeys = Set(totals.keys.map { String($0) })
        if !initializedCategories.contains(categoryKey) {
            initializedCategories.insert(categoryKey)
            seenPostCounts[categoryKey] = Dictionary(uniqueKeysWithValues: totals.map {
                (Self.threadKey($0.key), $0.value)
            })
            return true
        }
        var seen = seenPostCounts[categoryKey] ?? [:]
        let before = seen
        seen = seen.filter { validKeys.contains($0.key) }
        seenPostCounts[categoryKey] = seen
        return before != seen
    }

    mutating func markRead(category: Data, threadID: UInt32, totalPosts: UInt32) {
        let categoryKey = Self.categoryKey(category)
        initializedCategories.insert(categoryKey)
        var seen = seenPostCounts[categoryKey] ?? [:]
        seen[Self.threadKey(threadID)] = totalPosts
        seenPostCounts[categoryKey] = seen
    }

    func unreadCount(category: Data, threadID: UInt32, totalPosts: UInt32) -> Int {
        let categoryKey = Self.categoryKey(category)
        guard initializedCategories.contains(categoryKey) else { return 0 }
        let seen = seenPostCounts[categoryKey]?[Self.threadKey(threadID)] ?? 0
        return Int(totalPosts > seen ? totalPosts - seen : 0)
    }

    func unreadCount(category: Data, totals: [UInt32: UInt32]) -> Int {
        totals.reduce(0) { partial, pair in
            partial + unreadCount(category: category, threadID: pair.key, totalPosts: pair.value)
        }
    }
}

final class NewsReadStateStore {
    private static let keyPrefix = "Carracho.NewsReadState.v1."
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(scope: String) -> NewsReadState {
        guard let data = defaults.data(forKey: key(for: scope)),
              let state = try? JSONDecoder().decode(NewsReadState.self, from: data) else { return NewsReadState() }
        return state
    }

    func save(_ state: NewsReadState, scope: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key(for: scope))
    }

    private func key(for scope: String) -> String {
        Self.keyPrefix + Data(scope.utf8).base64EncodedString()
    }
}
