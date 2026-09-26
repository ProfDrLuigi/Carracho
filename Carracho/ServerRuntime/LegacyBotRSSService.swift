import Foundation
import Dispatch
import SQLite3
#if canImport(Darwin)
import Darwin
#endif

struct LegacyBotRSSArticle {
    var key: String
    var title: String
    var summary: String
    var link: String
    var imageURL: URL?
    var imageData: Data?
    var imageFilename: String?
}

private struct LegacyBotRSSFetchState {
    var initialized = false
    var lastChecked: TimeInterval = 0
    var etag: String?
    var lastModified: String?
}

private enum LegacyBotRSSError: LocalizedError {
    case invalidURL, blockedAddress, invalidFeed
    case network(String), database(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "RSS URL is invalid."
        case .blockedAddress: return "RSS URL resolves to a local or reserved network address."
        case .invalidFeed: return "RSS/Atom feed contains no usable articles."
        case let .network(message): return "RSS network error: \(message)"
        case let .database(message): return "RSS state database error: \(message)"
        }
    }
}

final class LegacyBotRSSService {
    typealias ArticleHandler = (LegacyBotRSSFeed, LegacyBotRSSArticle) -> Bool
    private let configURL: URL
    private let databaseURL: URL
    private let queue = DispatchQueue(label: "com.carracho.bot-rss", qos: .utility)
    private let configLock = NSLock()
    private let canPublish: () -> Bool
    private let articleHandler: ArticleHandler
    private let logHandler: (String) -> Void
    private var timer: DispatchSourceTimer?
    private var database: OpaquePointer?

    init(configURL: URL, databaseURL: URL, canPublish: @escaping () -> Bool,
         articleHandler: @escaping ArticleHandler, logHandler: @escaping (String) -> Void) {
        self.configURL = configURL
        self.databaseURL = databaseURL
        self.canPublish = canPublish
        self.articleHandler = articleHandler
        self.logHandler = logHandler
    }

    deinit {
        stop()
        if let database { sqlite3_close(database) }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            do { _ = try self.openDatabase() }
            catch { self.logHandler("Bot RSS database could not be opened: \(error.localizedDescription)") }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 5, repeating: 30)
            timer.setEventHandler { [weak self] in self?.pollDueFeeds() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    func loadFeeds() -> [LegacyBotRSSFeed] {
        configLock.lock()
        defer { configLock.unlock() }
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["rssFeeds"] as? [[String: Any]] else { return [] }
        return rows.prefix(LegacyBotRSSFeed.maximumCount).compactMap { row in
            guard let idString = row["id"] as? String, let id = UUID(uuidString: idString),
                  let enabled = row["enabled"] as? Bool, let name = row["name"] as? String,
                  let url = row["url"] as? String, let channel = row["channelID"] as? NSNumber,
                  let interval = row["pollIntervalMinutes"] as? NSNumber,
                  let image = row["includeImage"] as? Bool,
                  let summary = row["summaryCharacters"] as? NSNumber else { return nil }
            return try? LegacyBotRSSFeed(id: id, enabled: enabled, name: name, url: url,
                                         channelID: channel.uint32Value,
                                         pollIntervalMinutes: interval.intValue,
                                         includeImage: image,
                                         summaryCharacters: summary.intValue).validated()
        }
    }

    func saveFeeds(_ feeds: [LegacyBotRSSFeed]) throws {
        guard feeds.count <= LegacyBotRSSFeed.maximumCount else { throw LegacyBotRSSError.invalidFeed }
        let validated = try feeds.map { try $0.validated() }
        var ids = Set<UUID>()
        guard validated.allSatisfy({ ids.insert($0.id).inserted }) else { throw LegacyBotRSSError.invalidFeed }
        configLock.lock()
        defer { configLock.unlock() }
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let current = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { root = current }
        root["rssFeeds"] = validated.map { feed in
            ["id": feed.id.uuidString.lowercased(), "enabled": feed.enabled,
             "name": feed.name, "url": feed.url, "channelID": feed.channelID,
             "pollIntervalMinutes": feed.pollIntervalMinutes,
             "includeImage": feed.includeImage,
             "summaryCharacters": feed.summaryCharacters] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    func testArticle(_ feed: LegacyBotRSSFeed) throws -> LegacyBotRSSArticle {
        try queue.sync {
            let feed = try feed.validated()
            let result = try fetch(urlString: feed.url, maximumBytes: 2 * 1024 * 1024,
                                   etag: nil, lastModified: nil)
            guard result.status == 200,
                  var first = LegacyBotRSSParser.parse(result.data,
                                                       summaryCharacters: feed.summaryCharacters).first else {
                throw LegacyBotRSSError.invalidFeed
            }
            if feed.includeImage, let url = first.imageURL,
               let image = try? fetch(urlString: url.absoluteString,
                                      maximumBytes: LegacyMediaTransfer.maximumImageBytes,
                                      etag: nil, lastModified: nil),
               image.status == 200 {
                first.imageData = image.data
                first.imageFilename = url.lastPathComponent.isEmpty ? "rss-image" : url.lastPathComponent
            }
            return first
        }
    }

    private func pollDueFeeds() {
        guard canPublish() else { return }
        let now = Date().timeIntervalSince1970
        for feed in loadFeeds() where feed.enabled {
            let key = feedStateKey(feed)
            do {
                var state = try loadState(key: key)
                guard now - state.lastChecked >= Double(feed.pollIntervalMinutes * 60) else { continue }
                let result = try fetch(urlString: feed.url, maximumBytes: 2 * 1024 * 1024,
                                       etag: state.etag, lastModified: state.lastModified)
                state.lastChecked = now
                if let value = result.etag { state.etag = value }
                if let value = result.lastModified { state.lastModified = value }
                if result.status == 304 {
                    try saveState(key: key, state: state)
                    continue
                }
                guard result.status == 200 else {
                    try saveState(key: key, state: state)
                    logHandler("Bot RSS \(feed.name) returned HTTP \(result.status)")
                    continue
                }
                let items = LegacyBotRSSParser.parse(result.data,
                                                     summaryCharacters: feed.summaryCharacters)
                guard !items.isEmpty else {
                    try saveState(key: key, state: state)
                    logHandler("Bot RSS \(feed.name) contained no usable articles")
                    continue
                }
                if !state.initialized {
                    for item in items { try markSeen(feedKey: key, itemKey: item.key) }
                    state.initialized = true
                    try saveState(key: key, state: state)
                    logHandler("Bot RSS \(feed.name) initialized with \(items.count) existing item(s)")
                    continue
                }
                let unseen = try items.filter { try !isSeen(feedKey: key, itemKey: $0.key) }
                for var item in unseen.prefix(5).reversed() {
                    if feed.includeImage, let url = item.imageURL,
                       let image = try? fetch(urlString: url.absoluteString,
                                              maximumBytes: LegacyMediaTransfer.maximumImageBytes,
                                              etag: nil, lastModified: nil),
                       image.status == 200 {
                        item.imageData = image.data
                        item.imageFilename = url.lastPathComponent.isEmpty ? "rss-image" : url.lastPathComponent
                    }
                    if articleHandler(feed, item) {
                        try markSeen(feedKey: key, itemKey: item.key)
                    }
                }
                // Prevent a backlog storm if a feed suddenly exposes a large archive.
                for item in unseen.dropFirst(5) { try markSeen(feedKey: key, itemKey: item.key) }
                try saveState(key: key, state: state)
            } catch {
                do {
                    var state = try loadState(key: key)
                    state.lastChecked = now
                    try saveState(key: key, state: state)
                } catch {}
                logHandler("Bot RSS \(feed.name) failed: \(error.localizedDescription)")
            }
        }
    }

    private func feedStateKey(_ feed: LegacyBotRSSFeed) -> String {
        feed.id.uuidString.lowercased() + "|" + feed.url
    }

    private func openDatabase() throws -> OpaquePointer {
        if let database { return database }
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else { throw LegacyBotRSSError.database("open failed") }
        database = db
        let schema = "PRAGMA journal_mode=WAL;PRAGMA synchronous=NORMAL;" +
            "CREATE TABLE IF NOT EXISTS rss_feed_state(feed_key TEXT PRIMARY KEY,initialized INTEGER NOT NULL,last_checked REAL NOT NULL,etag TEXT,last_modified TEXT);" +
            "CREATE TABLE IF NOT EXISTS rss_seen(feed_key TEXT NOT NULL,item_key TEXT NOT NULL,seen_at REAL NOT NULL,PRIMARY KEY(feed_key,item_key));" +
            "CREATE INDEX IF NOT EXISTS rss_seen_time_idx ON rss_seen(seen_at);"
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw LegacyBotRSSError.database(String(cString: sqlite3_errmsg(db)))
        }
        return db
    }

    private func loadState(key: String) throws -> LegacyBotRSSFetchState {
        let db = try openDatabase()
        var state = LegacyBotRSSFetchState()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db,
            "SELECT initialized,last_checked,etag,last_modified FROM rss_feed_state WHERE feed_key=?",
            -1, &stmt, nil) == SQLITE_OK else {
            throw LegacyBotRSSError.database(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(stmt, 1, key, -1, carrachoSQLiteTransient)
        if sqlite3_step(stmt) == SQLITE_ROW {
            state.initialized = sqlite3_column_int(stmt, 0) != 0
            state.lastChecked = sqlite3_column_double(stmt, 1)
            if let p = sqlite3_column_text(stmt, 2) { state.etag = String(cString: p) }
            if let p = sqlite3_column_text(stmt, 3) { state.lastModified = String(cString: p) }
        }
        return state
    }

    private func saveState(key: String, state: LegacyBotRSSFetchState) throws {
        let db = try openDatabase()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "INSERT INTO rss_feed_state(feed_key,initialized,last_checked,etag,last_modified) VALUES(?,?,?,?,?) " +
            "ON CONFLICT(feed_key) DO UPDATE SET initialized=excluded.initialized,last_checked=excluded.last_checked,etag=excluded.etag,last_modified=excluded.last_modified"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LegacyBotRSSError.database(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(stmt, 1, key, -1, carrachoSQLiteTransient)
        sqlite3_bind_int(stmt, 2, state.initialized ? 1 : 0)
        sqlite3_bind_double(stmt, 3, state.lastChecked)
        if let value = state.etag { sqlite3_bind_text(stmt, 4, value, -1, carrachoSQLiteTransient) } else { sqlite3_bind_null(stmt, 4) }
        if let value = state.lastModified { sqlite3_bind_text(stmt, 5, value, -1, carrachoSQLiteTransient) } else { sqlite3_bind_null(stmt, 5) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LegacyBotRSSError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func isSeen(feedKey: String, itemKey: String) throws -> Bool {
        let db = try openDatabase()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM rss_seen WHERE feed_key=? AND item_key=?", -1, &stmt, nil) == SQLITE_OK else {
            throw LegacyBotRSSError.database(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(stmt, 1, feedKey, -1, carrachoSQLiteTransient)
        sqlite3_bind_text(stmt, 2, itemKey, -1, carrachoSQLiteTransient)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func markSeen(feedKey: String, itemKey: String) throws {
        let db = try openDatabase()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO rss_seen(feed_key,item_key,seen_at) VALUES(?,?,?)", -1, &stmt, nil) == SQLITE_OK else {
            throw LegacyBotRSSError.database(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(stmt, 1, feedKey, -1, carrachoSQLiteTransient)
        sqlite3_bind_text(stmt, 2, itemKey, -1, carrachoSQLiteTransient)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LegacyBotRSSError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    private struct HTTPResult {
        var status: Int
        var data: Data
        var etag: String?
        var lastModified: String?
    }

    private func fetch(urlString: String, maximumBytes: Int,
                       etag: String?, lastModified: String?) throws -> HTTPResult {
        guard let url = URL(string: urlString), try LegacyBotRSSNetworkPolicy.isAllowed(url) else {
            throw LegacyBotRSSError.blockedAddress
        }
        let delegate = LegacyBotRSSHTTPDelegate(maximumBytes: maximumBytes)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        cfg.httpMaximumConnectionsPerHost = 2
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue("Carracho-Bot-RSS/1.0.7", forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml, image/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let semaphore = DispatchSemaphore(value: 0)
        var value: Result<HTTPResult, Error>!
        delegate.completion = { response, data, error in
            defer { semaphore.signal() }
            if let error { value = .failure(error); return }
            guard let response else { value = .failure(LegacyBotRSSError.network("missing HTTP response")); return }
            value = .success(HTTPResult(status: response.statusCode, data: data,
                                       etag: response.value(forHTTPHeaderField: "ETag"),
                                       lastModified: response.value(forHTTPHeaderField: "Last-Modified")))
        }
        session.dataTask(with: request).resume()
        guard semaphore.wait(timeout: .now() + 25) == .success else {
            session.invalidateAndCancel()
            throw LegacyBotRSSError.network("timeout")
        }
        session.finishTasksAndInvalidate()
        return try value.get()
    }
}

private final class LegacyBotRSSHTTPDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    let maximumBytes: Int
    var data = Data()
    var response: HTTPURLResponse?
    var error: Error?
    var completion: ((HTTPURLResponse?, Data, Error?) -> Void)?
    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            error = LegacyBotRSSError.network("non-HTTP response")
            completionHandler(.cancel)
            return
        }
        self.response = http
        if let expected = http.value(forHTTPHeaderField: "Content-Length"),
           let count = Int(expected), count > maximumBytes {
            error = LegacyBotRSSError.network("response too large")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        if data.count + chunk.count > maximumBytes {
            error = LegacyBotRSSError.network("response too large")
            dataTask.cancel()
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? LegacyBotRSSNetworkPolicy.isAllowed(url)) == true else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError taskError: Error?) {
        completion?(response, data, error ?? taskError)
    }
}

private enum LegacyBotRSSNetworkPolicy {
    static func isAllowed(_ url: URL) throws -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil, let host = url.host, !host.isEmpty else {
            throw LegacyBotRSSError.invalidURL
        }
        if host.lowercased() == "localhost" || host.lowercased().hasSuffix(".local") { return false }
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC,
                             ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw LegacyBotRSSError.network("DNS lookup failed")
        }
        defer { freeaddrinfo(first) }
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let current = pointer {
            if blocked(current.pointee.ai_addr, current.pointee.ai_family) { return false }
            pointer = current.pointee.ai_next
        }
        return true
    }

    private static func blocked(_ raw: UnsafeMutablePointer<sockaddr>?, _ family: Int32) -> Bool {
        guard let raw else { return true }
        if family == AF_INET {
            let address = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let first = address >> 24
            let second = (address >> 16) & 255
            return first == 0 || first == 10 || first == 127 || first >= 224 ||
                (first == 100 && second >= 64 && second <= 127) ||
                (first == 169 && second == 254) ||
                (first == 172 && second >= 16 && second <= 31) ||
                (first == 192 && second == 168) ||
                (first == 198 && (second == 18 || second == 19))
        }
        if family == AF_INET6 {
            let address = raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            let bytes = withUnsafeBytes(of: address) { Array($0) }
            return bytes.allSatisfy { $0 == 0 } ||
                (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1) ||
                (bytes[0] & 0xfe) == 0xfc ||
                (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) || bytes[0] == 0xff
        }
        return true
    }
}

private final class LegacyBotRSSParser: NSObject, XMLParserDelegate {
    private struct Item { var title = ""; var link = ""; var guid = ""; var body = ""; var image = "" }
    private var items: [Item] = []
    private var current: Item?
    private var text = ""
    private var atom = false

    static func parse(_ data: Data, summaryCharacters: Int) -> [LegacyBotRSSArticle] {
        let delegate = LegacyBotRSSParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.items.compactMap { delegate.article($0, limit: summaryCharacters) }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = (qName ?? elementName).lowercased()
        text = ""
        if name == "feed" { atom = true }
        if name == "item" || name == "entry" { current = Item() }
        guard current != nil else { return }
        if name == "link", let href = attributeDict["href"], current!.link.isEmpty { current!.link = href }
        if (name == "enclosure" || name.hasSuffix(":content") || name.hasSuffix(":thumbnail")),
           let url = attributeDict["url"], current!.image.isEmpty { current!.image = url }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = (qName ?? elementName).lowercased()
        guard var item = current else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "title" && item.title.isEmpty { item.title = value }
        else if name == "link" && !atom && item.link.isEmpty { item.link = value }
        else if (name == "guid" || name == "id") && item.guid.isEmpty { item.guid = value }
        else if (name == "description" || name == "summary" || name.hasSuffix(":encoded") || name == "content") && value.count > item.body.count { item.body = value }
        if name == "item" || name == "entry" { items.append(item); current = nil }
        else { current = item }
        text = ""
    }

    private func article(_ item: Item, limit: Int) -> LegacyBotRSSArticle? {
        let title = Self.clean(item.title, max: 512)
        let link = item.link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !link.isEmpty, URL(string: link) != nil else { return nil }
        let summary = Self.clean(item.body, max: limit)
        let image = item.image.isEmpty ? Self.image(in: item.body) : item.image
        let key = item.guid.isEmpty ? link : item.guid
        return LegacyBotRSSArticle(key: key, title: title, summary: summary,
                                   link: link, imageURL: image.flatMap(URL.init(string:)))
    }

    private static func image(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<img\b[^>]*\bsrc\s*=\s*[\"']([^\"']+)[\"']"#),
              let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)),
              match.numberOfRanges > 1 else { return nil }
        return (html as NSString).substring(with: match.range(at: 1))
    }

    private static func clean(_ html: String, max: Int) -> String {
        var value = html
            .replacingOccurrences(of: #"(?is)<(script|style|iframe)\b[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>|</li>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&amp;":"&", "&lt;":"<", "&gt;":">", "&quot;":"\"", "&#39;":"'", "&apos;":"'", "&nbsp;":" ", "&zwnj;":""]
        for (key, replacement) in entities { value = value.replacingOccurrences(of: key, with: replacement, options: .caseInsensitive) }
        value = value
            .replacingOccurrences(of: #"&#(?:x[0-9a-fA-F]+|\d+);"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"&[A-Za-z][A-Za-z0-9]+;"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .replacingOccurrences(of: #"(?i)\s+Der Artikel\s+.+?\s+erschien zuerst auf\s+.+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+The post\s+.+?\s+appeared first on\s+.+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count > max {
            let end = value.index(value.startIndex, offsetBy: max)
            value = String(value[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return value
    }
}


#if canImport(Darwin)
extension LegacyBotFileWatcher {
    func validated(filesRootURL: URL, requireDirectory: Bool = true) throws -> LegacyBotFileWatcher {
        let watcher = try validated()
        var target = filesRootURL.standardizedFileURL
        if watcher.path != "." {
            for component in watcher.path.split(separator: "/") {
                target.appendPathComponent(String(component), isDirectory: true)
            }
        }
        let resolvedRoot = filesRootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedTarget == resolvedRoot || resolvedTarget.hasPrefix(resolvedRoot + "/") else {
            throw LegacyProtocolError.invalidRecord("Bot File Watcher path escapes Files root")
        }
        if requireDirectory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw LegacyProtocolError.invalidRecord("Bot File Watcher folder does not exist: \(watcher.path)")
            }
        }
        return watcher
    }

    func directoryURL(filesRootURL: URL) -> URL {
        if path == "." { return filesRootURL.standardizedFileURL }
        return path.split(separator: "/").reduce(filesRootURL.standardizedFileURL) {
            $0.appendingPathComponent(String($1), isDirectory: true)
        }
    }
}

struct LegacyBotFileWatcherAnnouncement: Equatable {
    var watcher: LegacyBotFileWatcher
    var folderPath: String
    var folderName: String
    var fileName: String
}

final class LegacyBotFileWatcherService {
    private struct SourceEntry {
        var source: DispatchSourceFileSystemObject
        var fd: Int32
    }

    private let configURL: URL
    private let filesRootURL: URL
    private let canPublish: () -> Bool
    private let announcementHandler: (LegacyBotFileWatcherAnnouncement) -> Bool
    private let logHandler: (String) -> Void
    private let queue = DispatchQueue(label: "com.carracho.server.bot-file-watcher", qos: .utility)
    private var configTimer: DispatchSourceTimer?
    private var sources: [String: SourceEntry] = [:]
    private var watchers: [UUID: LegacyBotFileWatcher] = [:]
    private var fileSnapshots: [UUID: Set<String>] = [:]
    private var rescanItems: [UUID: DispatchWorkItem] = [:]
    private var lastPublished: [String: Date] = [:]
    private var configStamp: Date?
    private var running = false

    init(configURL: URL, filesRootURL: URL,
         canPublish: @escaping () -> Bool,
         announcementHandler: @escaping (LegacyBotFileWatcherAnnouncement) -> Bool,
         logHandler: @escaping (String) -> Void) {
        self.configURL = configURL
        self.filesRootURL = filesRootURL.standardizedFileURL
        self.canPublish = canPublish
        self.announcementHandler = announcementHandler
        self.logHandler = logHandler
    }

    deinit { stop() }

    func start() {
        queue.async { [weak self] in
            guard let self, !running else { return }
            running = true
            reloadConfiguration(force: true)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(150))
            timer.setEventHandler { [weak self] in self?.reloadConfiguration(force: false) }
            configTimer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            guard running || configTimer != nil || !sources.isEmpty else { return }
            running = false
            configTimer?.cancel()
            configTimer = nil
            rescanItems.values.forEach { $0.cancel() }
            rescanItems.removeAll()
            cancelSources()
            watchers.removeAll()
            fileSnapshots.removeAll()
            lastPublished.removeAll()
        }
    }

    func configurationDidChange() {
        queue.async { [weak self] in self?.reloadConfiguration(force: true) }
    }

    private func configurationModificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate]) as? Date
    }

    private func loadWatchers() throws -> [LegacyBotFileWatcher] {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return [] }
        let data = try Data(contentsOf: configURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LegacyProtocolError.invalidRecord("invalid Bot configuration")
        }
        guard let raw = root["fileWatchers"] else { return [] }
        guard let rows = raw as? [[String: Any]], rows.count <= LegacyBotFileWatcher.maximumCount else {
            throw LegacyProtocolError.invalidRecord("invalid Bot File Watcher list")
        }
        var result: [LegacyBotFileWatcher] = []
        var ids = Set<UUID>()
        for row in rows {
            guard let idText = row["id"] as? String, let id = UUID(uuidString: idText),
                  let enabled = row["enabled"] as? Bool,
                  let path = row["path"] as? String,
                  let channel = row["channelID"] as? NSNumber,
                  let message = row["messageTemplate"] as? String,
                  channel.uint64Value > 0, channel.uint64Value <= UInt64(UInt32.max) else {
                throw LegacyProtocolError.invalidRecord("invalid Bot File Watcher configuration")
            }
            let watcher = try LegacyBotFileWatcher(id: id, enabled: enabled, path: path,
                                                   channelID: channel.uint32Value,
                                                   messageTemplate: message)
                .validated(filesRootURL: filesRootURL, requireDirectory: enabled)
            guard ids.insert(watcher.id).inserted else {
                throw LegacyProtocolError.invalidRecord("duplicate Bot File Watcher id")
            }
            result.append(watcher)
        }
        return result
    }

    private func reloadConfiguration(force: Bool) {
        guard running else { return }
        let stamp = configurationModificationDate()
        if !force, stamp == configStamp { return }
        configStamp = stamp
        do {
            let loaded = try loadWatchers()
            watchers = Dictionary(uniqueKeysWithValues: loaded.filter(\.enabled).map { ($0.id, $0) })
            fileSnapshots.removeAll()
            for watcher in watchers.values { fileSnapshots[watcher.id] = scanFiles(for: watcher) }
            installSources()
        } catch {
            logHandler("Bot File Watcher configuration is invalid: \(error.localizedDescription)")
        }
    }

    private func scanFiles(for watcher: LegacyBotFileWatcher) -> Set<String> {
        let root = watcher.directoryURL(filesRootURL: filesRootURL)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
        ) else { return [] }
        var result = Set<String>()
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]),
                  values.isRegularFile == true || values.isDirectory == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(prefix) else { continue }
            result.insert(String(full.dropFirst(prefix.count)))
        }
        return result
    }

    private func directories(for watcher: LegacyBotFileWatcher) -> [URL] {
        let root = watcher.directoryURL(filesRootURL: filesRootURL)
        var result = [root]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
        ) else { return result }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { result.append(url) }
        }
        return result
    }

    private func cancelSources() {
        let existing = sources
        sources.removeAll()
        for entry in existing.values { entry.source.cancel() }
    }

    private func installSources() {
        cancelSources()
        guard running else { return }
        for watcher in watchers.values {
            for directory in directories(for: watcher) {
                let fd = directory.path.withCString { open($0, O_EVTONLY) }
                guard fd >= 0 else { continue }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .extend, .attrib, .rename, .delete, .link],
                    queue: queue
                )
                let key = watcher.id.uuidString + ":" + directory.path
                source.setEventHandler { [weak self] in self?.scheduleRescan(watcherID: watcher.id) }
                source.setCancelHandler { Darwin.close(fd) }
                sources[key] = SourceEntry(source: source, fd: fd)
                source.resume()
            }
        }
    }

    private func scheduleRescan(watcherID: UUID) {
        rescanItems[watcherID]?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.rescan(watcherID: watcherID) }
        rescanItems[watcherID] = item
        queue.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func rescan(watcherID: UUID) {
        rescanItems[watcherID] = nil
        guard running, let watcher = watchers[watcherID] else { return }
        let prior = fileSnapshots[watcherID] ?? []
        let current = scanFiles(for: watcher)
        fileSnapshots[watcherID] = current
        let added = current.subtracting(prior)
        installSources()
        guard !added.isEmpty, canPublish() else { return }

        var folders: [String: (folderName: String, fileName: String)] = [:]
        let watchesRoot = watcher.path == "."
        for relativeFile in added.sorted() {
            let components = relativeFile.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.isEmpty else { continue }
            let fileName = components.last ?? relativeFile
            if components.count >= 2 {
                let folderName = components[0]
                let folderPath = watchesRoot ? folderName : watcher.path + "/" + folderName
                folders[folderPath] = (folderName, fileName)
            } else {
                let entryURL = watcher.directoryURL(filesRootURL: filesRootURL)
                    .appendingPathComponent(relativeFile)
                let isDirectory = (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let folderPath: String
                let folderName: String
                if isDirectory {
                    folderPath = watchesRoot ? relativeFile : watcher.path + "/" + relativeFile
                    folderName = relativeFile
                } else {
                    folderPath = watcher.path
                    folderName = watchesRoot
                        ? filesRootURL.lastPathComponent
                        : URL(fileURLWithPath: watcher.path).lastPathComponent
                }
                if !folderName.isEmpty { folders[folderPath] = (folderName, fileName) }
            }
        }

        let now = Date()
        for folderPath in folders.keys.sorted() {
            guard let values = folders[folderPath] else { continue }
            let folderName = values.folderName
            let cooldownKey = watcher.id.uuidString + ":" + folderPath
            if let last = lastPublished[cooldownKey], now.timeIntervalSince(last) < 60 { continue }
            let announcement = LegacyBotFileWatcherAnnouncement(
                watcher: watcher, folderPath: folderPath, folderName: folderName,
                fileName: values.fileName
            )
            if announcementHandler(announcement) {
                lastPublished[cooldownKey] = now
                logHandler("Bot File Watcher \(watcher.path) announced \(folderPath)")
            }
        }
    }
}
#endif
