import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum LegacyTrackerNotifierError: LocalizedError {
    case invalidAddress(String)
    case resolve(String)
    case connect(String)
    case send(String)

    var errorDescription: String? {
        switch self {
        case let .invalidAddress(value): return "Invalid tracker address: \(value)"
        case let .resolve(value): return "Could not resolve tracker: \(value)"
        case let .connect(value): return "Could not connect to tracker: \(value)"
        case let .send(value): return "Could not send tracker registration: \(value)"
        }
    }
}

/// Cross-platform outbound half of the Classic Tracker protocol. The server sends CTT\x01
/// registrations to configured trackers; no Network.framework dependency is used so this
/// remains independent of AppKit and mirrors the native tracker wire behavior.
enum LegacyTrackerNotifier {
    static func notify(state: ServerState,
                       controlPort: UInt16,
                       users: Int,
                       log: (String) -> Void) {
        let advanced = state.advanced
        // The Classic CTT v1 registration is intentionally unauthenticated. Server 1.0b13
        // publishes whenever setting 0x32 has the register bit set; it does not inspect the
        // anonymous account first. Matching that behavior is required for legacy Trackers.
        let enabledTrackers = advanced.trackers.filter(\.isRegistrationEnabled)
        guard (advanced.trackerAdvertisementFlags & LegacyTrackerProtocol.registeredFlag) != 0,
              !enabledTrackers.isEmpty else { return }
        guard let serverName = state.identity.name.data(using: .macOSRoman),
              let description = advanced.trackerDescription.data(using: .macOSRoman) else {
            log("Tracker registration skipped: server name/description is not representable in MacRoman")
            return
        }
        let registrationIPv4 = publicAdvertisedIPv4(log: log)
        let registration = LegacyTrackerRegistration(
            ipv4: registrationIPv4,
            port: controlPort,
            serverName: serverName,
            description: description,
            users: UInt16(min(max(users, 0), Int(UInt16.max))),
            flags: advanced.trackerAdvertisementFlags
        )
        let wire: Data
        do { wire = try registration.encoded() }
        catch {
            log("Tracker registration could not be encoded: \(error.localizedDescription)")
            return
        }

        for tracker in enabledTrackers {
            do {
                let endpoint = try parseEndpoint(tracker.address)
                let fd = try connectTCP(host: endpoint.host, port: endpoint.port)
                defer { closeSocket(fd) }
                try writeAll(fd: fd, data: wire)
                log("Tracker registration sent to \(tracker.name.isEmpty ? tracker.address : tracker.name) (\(tracker.address))")
            } catch {
                log("Tracker registration failed for \(tracker.address): \(error.localizedDescription)")
            }
        }
    }

    static func parseEndpoint(_ raw: String) throws -> (host: String, port: UInt16) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw LegacyTrackerNotifierError.invalidAddress(raw) }
        if let colon = value.lastIndex(of: ":"), !value[..<colon].contains(":"),
           let port = UInt16(value[value.index(after: colon)...]), port > 0 {
            let host = String(value[..<colon])
            guard !host.isEmpty else { throw LegacyTrackerNotifierError.invalidAddress(raw) }
            return (host, port)
        }
        return (value, LegacyTrackerProtocol.port)
    }

    /// Tracker entries must be reachable from the public Internet. A local interface address
    /// (192.168/10/172.16) is useful only inside the server's LAN, so prefer the WAN address.
    /// The environment override is intentionally supported for deterministic integration tests
    /// and for installations where outbound HTTP is filtered but the public address is known.
    static func publicAdvertisedIPv4(log: (String) -> Void = { _ in }) -> Data {
        if let override = ProcessInfo.processInfo.environment["CARRACHO_PUBLIC_IPV4"],
           let value = ipv4Data(override), !isPrivateOrLocalIPv4(value) {
            return value
        }
        for endpoint in ["https://checkip.amazonaws.com", "https://api.ipify.org"] {
            if let value = fetchPublicIPv4(endpoint), !isPrivateOrLocalIPv4(value) {
                return value
            }
        }
        let fallback = advertisedIPv4()
        log("Public IPv4 discovery failed; tracker registration falls back to local IPv4 \(ipv4String(fallback))")
        return fallback
    }

    static func ipv4Data(_ string: String) -> Data? {
        var address = in_addr()
        guard string.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        var copy = address.s_addr
        return withUnsafeBytes(of: &copy) { Data($0.prefix(4)) }
    }

    static func isPrivateOrLocalIPv4(_ value: Data) -> Bool {
        guard value.count == 4 else { return true }
        let b = [UInt8](value)
        if b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 { return true }
        if b[0] == 100 && (64...127).contains(b[1]) { return true } // carrier-grade NAT
        if b[0] == 169 && b[1] == 254 { return true }
        if b[0] == 172 && (16...31).contains(b[1]) { return true }
        if b[0] == 192 && b[1] == 168 { return true }
        return false
    }

    private static func fetchPublicIPv4(_ rawURL: String) -> Data? {
        guard let url = URL(string: rawURL) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2.5
        configuration.timeoutIntervalForResource = 2.5
        let session = URLSession(configuration: configuration)
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var resolved: Data?
        let task = session.dataTask(with: url) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data, data.count <= 64,
                  let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let address = ipv4Data(text) else { return }
            lock.lock(); resolved = address; lock.unlock()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 3) == .timedOut { task.cancel(); session.invalidateAndCancel(); return nil }
        session.finishTasksAndInvalidate()
        lock.lock(); defer { lock.unlock() }
        return resolved
    }

    private static func ipv4String(_ value: Data) -> String {
        value.map(String.init).joined(separator: ".")
    }

    static func advertisedIPv4() -> Data {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return Data([127, 0, 0, 1]) }
        defer { freeifaddrs(head) }
        var fallback: Data?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_INET else { continue }
            let sin = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
            var raw = sin.sin_addr
            let bytes = withUnsafeBytes(of: &raw) { Data($0.prefix(4)) }
            guard bytes.count == 4 else { continue }
            if bytes.first == 127 { fallback = fallback ?? bytes; continue }
            if bytes != Data([0, 0, 0, 0]) { return bytes }
        }
        return fallback ?? Data([127, 0, 0, 1])
    }

    private static func connectTCP(host: String, port: UInt16) throws -> Int32 {
        var result: UnsafeMutablePointer<addrinfo>?
        let service = String(port)
        let code = getaddrinfo(host, service, nil, &result)
        guard code == 0, let first = result else {
            throw LegacyTrackerNotifierError.resolve(host)
        }
        defer { freeaddrinfo(result) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            let value = info.pointee
            if value.ai_socktype == streamSocketType || value.ai_socktype == 0 {
                let fd = socket(value.ai_family, streamSocketType, value.ai_protocol)
                if fd >= 0 {
                    if systemConnect(fd, value.ai_addr, value.ai_addrlen) == 0 { return fd }
                    closeSocket(fd)
                }
            }
            cursor = value.ai_next
        }
        throw LegacyTrackerNotifierError.connect("\(host):\(port)")
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let n = systemSend(fd, base.advanced(by: offset), data.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw LegacyTrackerNotifierError.send(String(cString: strerror(errno)))
                }
                guard n > 0 else { throw LegacyTrackerNotifierError.send("connection closed") }
                offset += n
            }
        }
    }

    #if canImport(Darwin)
    private static let streamSocketType = SOCK_STREAM
    private static func systemConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
        Darwin.connect(fd, address, length)
    }
    private static func systemSend(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        Darwin.send(fd, buffer, count, 0)
    }
    private static func closeSocket(_ fd: Int32) { _ = Darwin.close(fd) }
    #else
    private static let streamSocketType = Int32(SOCK_STREAM.rawValue)
    private static func systemConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
        Glibc.connect(fd, address, length)
    }
    private static func systemSend(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        Glibc.send(fd, buffer, count, Int32(MSG_NOSIGNAL))
    }
    private static func closeSocket(_ fd: Int32) { _ = Glibc.close(fd) }
    #endif
}
