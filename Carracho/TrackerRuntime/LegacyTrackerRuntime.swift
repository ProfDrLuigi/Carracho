import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct LegacyTrackerRuntimeStatus: Equatable {
    var isRunning: Bool
    var port: UInt16?
    var registeredServers: Int
}

enum LegacyTrackerRuntimeError: LocalizedError {
    case alreadyRunning
    case socket(String)
    case protocolFailure(String)
    case stopped

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "The tracker is already running."
        case let .socket(message): return "Tracker socket error: \(message)"
        case let .protocolFailure(message): return "Tracker protocol error: \(message)"
        case .stopped: return "The tracker stopped."
        }
    }
}

final class LegacyTrackerRuntime {
    private struct Key: Hashable {
        var ipv4: Data
        var port: UInt16
    }
    private struct Registration {
        var entry: LegacyTrackerServerEntry
        var lastSeen: Date
    }

    var onLog: ((String) -> Void)?
    var onStatus: ((LegacyTrackerRuntimeStatus) -> Void)?

    private let expirationInterval: TimeInterval
    private let cleanupInterval: TimeInterval
    private let stateLock = NSLock()
    private var listenerFD: Int32 = -1
    private var registrationFD: Int32 = -1
    private var boundPort: UInt16?
    private var running = false
    private var registrations: [Key: Registration] = [:]
    private let acceptQueue = DispatchQueue(label: "com.carracho.tracker.accept", qos: .userInitiated)
    private let registrationQueue = DispatchQueue(label: "com.carracho.tracker.registration", qos: .utility)
    private let cleanupQueue = DispatchQueue(label: "com.carracho.tracker.cleanup", qos: .utility)
    private let timerLock = NSLock()
    private var cleanupTimer: DispatchSourceTimer?

    /// Classic servers refresh tracker registration every five minutes. The modern tracker
    /// expires a server after two missed refresh cycles; tests may inject shorter intervals.
    init(expirationInterval: TimeInterval = 600, cleanupInterval: TimeInterval = 60) {
        self.expirationInterval = max(0.05, expirationInterval)
        self.cleanupInterval = max(0.05, cleanupInterval)
    }

    deinit { stop() }

    var status: LegacyTrackerRuntimeStatus {
        stateLock.lock(); defer { stateLock.unlock() }
        return LegacyTrackerRuntimeStatus(isRunning: running, port: boundPort,
                                          registeredServers: registrations.count)
    }

    @discardableResult
    func start(port: UInt16 = LegacyTrackerProtocol.port) throws -> UInt16 {
        stateLock.lock()
        if running { stateLock.unlock(); throw LegacyTrackerRuntimeError.alreadyRunning }
        stateLock.unlock()

        let listener = try TrackerSocket.makeListener(port: port)
        let actualPort = try TrackerSocket.localPort(fd: listener)
        let registrationSocket: Int32
        do {
            registrationSocket = try TrackerSocket.makeDatagramListener(port: actualPort)
        } catch {
            TrackerSocket.shutdownAndClose(listener)
            throw error
        }
        stateLock.lock()
        listenerFD = listener
        registrationFD = registrationSocket
        boundPort = actualPort
        running = true
        stateLock.unlock()
        emitStatus()
        log("Tracker listening on TCP/UDP \(actualPort)")
        acceptQueue.async { [weak self] in self?.acceptLoop(fd: listener) }
        registrationQueue.async { [weak self] in self?.registrationLoop(fd: registrationSocket) }
        scheduleCleanup()
        return actualPort
    }

    func stop() {
        stateLock.lock()
        guard running || listenerFD >= 0 || registrationFD >= 0 else { stateLock.unlock(); return }
        running = false
        let fd = listenerFD
        let udpFD = registrationFD
        listenerFD = -1
        registrationFD = -1
        boundPort = nil
        stateLock.unlock()
        cancelCleanup()
        if fd >= 0 { TrackerSocket.shutdownAndClose(fd) }
        if udpFD >= 0 { TrackerSocket.closeDatagram(udpFD) }
        emitStatus()
        log("Tracker stopped")
    }

    func entries(now: Date = Date()) -> [LegacyTrackerServerEntry] {
        pruneExpired(now: now)
        stateLock.lock(); defer { stateLock.unlock() }
        return registrations.values.map(\.entry).sorted { lhs, rhs in
            let left = String(data: lhs.serverName, encoding: .macOSRoman) ?? ""
            let right = String(data: rhs.serverName, encoding: .macOSRoman) ?? ""
            let comparison = left.localizedCaseInsensitiveCompare(right)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            if lhs.ipv4 != rhs.ipv4 { return lhs.ipv4.lexicographicallyPrecedes(rhs.ipv4) }
            return lhs.port < rhs.port
        }
    }

    @discardableResult
    func pruneExpired(now: Date = Date()) -> Int {
        stateLock.lock()
        let before = registrations.count
        registrations = registrations.filter { now.timeIntervalSince($0.value.lastSeen) <= expirationInterval }
        let removed = before - registrations.count
        stateLock.unlock()
        if removed > 0 {
            log("Expired \(removed) tracker registration\(removed == 1 ? "" : "s")")
            emitStatus()
        }
        return removed
    }

    private func acceptLoop(fd: Int32) {
        while true {
            stateLock.lock(); let shouldRun = running && listenerFD == fd; stateLock.unlock()
            guard shouldRun else { return }
            do {
                let accepted = try TrackerSocket.accept(fd: fd)
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    defer { TrackerSocket.shutdownAndClose(accepted.fd) }
                    do { try self?.handleConnection(fd: accepted.fd, peerIP: accepted.peerIP) }
                    catch { self?.log("Tracker connection from \(accepted.peerIP) failed: \(error.localizedDescription)") }
                }
            } catch {
                stateLock.lock(); let stillRunning = running; stateLock.unlock()
                if stillRunning { log("Tracker accept failed: \(error.localizedDescription)") }
                return
            }
        }
    }

    private func registrationLoop(fd: Int32) {
        while true {
            stateLock.lock()
            let shouldRun = running && registrationFD == fd
            stateLock.unlock()
            guard shouldRun else { return }
            do {
                let datagram = try TrackerSocket.receiveDatagram(fd: fd, maximumBytes: 256)
                let registration = try LegacyTrackerRegistration.decode(datagram.data)
                guard registration.serverName.count <= LegacyTrackerProtocol.maxRegistrationServerNameBytes,
                      registration.description.count <= LegacyTrackerProtocol.maxRegistrationDescriptionBytes else {
                    throw LegacyTrackerRuntimeError.protocolFailure("Classic Tracker registration exceeds 40/100-byte text limits")
                }
                guard let observedIPv4 = TrackerSocket.ipv4Data(datagram.peerIP) else {
                    throw LegacyTrackerRuntimeError.protocolFailure("registration peer has no usable IPv4 address")
                }
                // Tracker X 1.1.1 treats the UDP source address as authoritative and
                // overwrites the four IPv4 bytes carried in the CTT payload.
                let entry = LegacyTrackerServerEntry(ipv4: observedIPv4, port: registration.port,
                                                     serverName: registration.serverName,
                                                     description: registration.description,
                                                     users: registration.users, flags: registration.flags)
                stateLock.lock()
                registrations[Key(ipv4: entry.ipv4, port: entry.port)] =
                    Registration(entry: entry, lastSeen: Date())
                stateLock.unlock()
                emitStatus()
                let name = String(data: entry.serverName, encoding: .macOSRoman) ?? "?"
                log("Tracker UDP registration updated from \(datagram.peerIP): \(name) (\(entry.users) users)")
            } catch {
                stateLock.lock()
                let stillRunning = running && registrationFD == fd
                stateLock.unlock()
                if stillRunning {
                    log("Tracker UDP registration failed: \(error.localizedDescription)")
                    continue
                }
                return
            }
        }
    }

    private func handleConnection(fd: Int32, peerIP: String) throws {
        let magic = try TrackerSocket.readExactly(fd: fd, count: 4)
        if magic == LegacyTrackerProtocol.queryMagic {
            let operation = try TrackerSocket.readExactly(fd: fd, count: LegacyTrackerProtocol.listQuery.count)
            guard operation == LegacyTrackerProtocol.listQuery else {
                throw LegacyTrackerRuntimeError.protocolFailure("unknown tracker query operation")
            }
            let list = entries()
            try TrackerSocket.writeAll(fd: fd, data: try LegacyTrackerProtocol.encodeListResponse(list))
            log("Tracker list served to \(peerIP): \(list.count) server\(list.count == 1 ? "" : "s")")
            return
        }
        if magic == LegacyTrackerProtocol.registrationMagic {
            var wire = magic
            wire.append(try TrackerSocket.readExactly(fd: fd, count: 6)) // IPv4 + port
            let nameLengthData = try TrackerSocket.readExactly(fd: fd, count: 1)
            guard let nameLength = nameLengthData.first else { throw LegacyTrackerRuntimeError.protocolFailure("missing tracker server-name length") }
            wire.append(nameLengthData)
            wire.append(try TrackerSocket.readExactly(fd: fd, count: Int(nameLength)))
            let descriptionLengthData = try TrackerSocket.readExactly(fd: fd, count: 1)
            guard let descriptionLength = descriptionLengthData.first else { throw LegacyTrackerRuntimeError.protocolFailure("missing tracker description length") }
            wire.append(descriptionLengthData)
            wire.append(try TrackerSocket.readExactly(fd: fd, count: Int(descriptionLength)))
            wire.append(try TrackerSocket.readExactly(fd: fd, count: 6)) // users + flags
            let registration = try LegacyTrackerRegistration.decode(wire)
            guard registration.serverName.count <= LegacyTrackerProtocol.maxRegistrationServerNameBytes,
                  registration.description.count <= LegacyTrackerProtocol.maxRegistrationDescriptionBytes else {
                throw LegacyTrackerRuntimeError.protocolFailure("Classic Tracker registration exceeds 40/100-byte text limits")
            }
            guard let observedIPv4 = TrackerSocket.ipv4Data(peerIP) else {
                throw LegacyTrackerRuntimeError.protocolFailure("registration peer has no usable IPv4 address")
            }
            // Across the public Internet, the TCP source is authoritative and prevents a server
            // from spoofing another public host. With split DNS / NAT hairpinning the tracker may
            // instead see a private LAN source; in that case the server's discovered public IPv4
            // is exactly the address clients need and must win over 192.168/10/172.16.
            let publishedIPv4: Data
            if !TrackerSocket.isPrivateOrLocalIPv4(observedIPv4) {
                publishedIPv4 = observedIPv4
            } else if !TrackerSocket.isPrivateOrLocalIPv4(registration.ipv4) {
                publishedIPv4 = registration.ipv4
            } else {
                publishedIPv4 = registration.ipv4
            }
            let entry = LegacyTrackerServerEntry(ipv4: publishedIPv4, port: registration.port,
                                                 serverName: registration.serverName,
                                                 description: registration.description,
                                                 users: registration.users, flags: registration.flags)
            stateLock.lock()
            registrations[Key(ipv4: entry.ipv4, port: entry.port)] = Registration(entry: entry, lastSeen: Date())
            stateLock.unlock()
            emitStatus()
            let name = String(data: entry.serverName, encoding: .macOSRoman) ?? "?"
            log("Tracker registration updated from \(peerIP): \(name) (\(entry.users) users)")
            return
        }
        throw LegacyTrackerRuntimeError.protocolFailure("unknown tracker magic/version")
    }

    private func scheduleCleanup() {
        cancelCleanup()
        guard status.isRunning else { return }
        let timer = DispatchSource.makeTimerSource(queue: cleanupQueue)
        timer.schedule(deadline: .now() + cleanupInterval, repeating: cleanupInterval,
                       leeway: .milliseconds(Int(min(cleanupInterval * 100, 1000))))
        timer.setEventHandler { [weak self] in _ = self?.pruneExpired() }
        timerLock.lock(); cleanupTimer = timer; timerLock.unlock()
        timer.resume()
    }

    private func cancelCleanup() {
        timerLock.lock(); let timer = cleanupTimer; cleanupTimer = nil; timerLock.unlock()
        timer?.cancel()
    }

    private func emitStatus() { onStatus?(status) }
    private func log(_ message: String) { onLog?(message) }
}

private enum TrackerSocket {
    #if canImport(Darwin)
    static let streamType = SOCK_STREAM
    static let datagramType = SOCK_DGRAM
    #else
    static let streamType = Int32(SOCK_STREAM.rawValue)
    static let datagramType = Int32(SOCK_DGRAM.rawValue)
    #endif

    static func makeListener(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw socketError("socket") }
        do {
            var yes: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else {
                throw socketError("setsockopt(SO_REUSEADDR)")
            }
            #if canImport(Darwin)
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            #endif
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw socketError("bind") }
            guard listen(fd, 64) == 0 else { throw socketError("listen") }
            return fd
        } catch {
            closeFD(fd)
            throw error
        }
    }

    static func makeDatagramListener(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, datagramType, 0)
        guard fd >= 0 else { throw socketError("socket(SOCK_DGRAM)") }
        do {
            var yes: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                             socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else {
                throw socketError("setsockopt(SO_REUSEADDR)")
            }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw socketError("bind(SOCK_DGRAM)") }
            return fd
        } catch {
            closeFD(fd)
            throw error
        }
    }

    static func localPort(fd: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result == 0 else { throw socketError("getsockname") }
        return UInt16(bigEndian: address.sin_port)
    }

    static func accept(fd: Int32) throws -> (fd: Int32, peerIP: String) {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let clientFD = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { platformAccept(fd, $0, &length) }
        }
        guard clientFD >= 0 else { throw socketError("accept") }
        #if canImport(Darwin)
        var yes: Int32 = 1
        _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        #endif
        return (clientFD, peerAddress(storage))
    }

    static func receiveDatagram(fd: Int32, maximumBytes: Int) throws -> (data: Data, peerIP: String) {
        guard maximumBytes > 0 else {
            throw LegacyTrackerRuntimeError.protocolFailure("invalid tracker datagram limit")
        }
        // One byte beyond the Classic 256-byte limit lets us reject oversized datagrams
        // instead of accepting a silently truncated CTT packet.
        var buffer = [UInt8](repeating: 0, count: maximumBytes + 1)
        let bufferCapacity = buffer.count
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let received = buffer.withUnsafeMutableBytes { raw -> Int in
            withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    platformRecvFrom(fd, raw.baseAddress, bufferCapacity, $0, &length)
                }
            }
        }
        if received < 0 {
            if errno == EINTR { return try receiveDatagram(fd: fd, maximumBytes: maximumBytes) }
            throw socketError("recvfrom")
        }
        guard received <= maximumBytes else {
            throw LegacyTrackerRuntimeError.protocolFailure("tracker registration exceeds 256 bytes")
        }
        return (Data(buffer.prefix(received)), peerAddress(storage))
    }

    static func readExactly(fd: Int32, count: Int) throws -> Data {
        guard count >= 0 else { throw LegacyTrackerRuntimeError.protocolFailure("negative read length") }
        var result = Data(count: count)
        var offset = 0
        try result.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < count {
                let n = platformRecv(fd, base.advanced(by: offset), count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw socketError("recv")
                }
                if n == 0 { throw LegacyTrackerRuntimeError.stopped }
                offset += n
            }
        }
        return result
    }

    static func writeAll(fd: Int32, data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let n = platformSend(fd, base.advanced(by: offset), data.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw socketError("send")
                }
                guard n > 0 else { throw LegacyTrackerRuntimeError.stopped }
                offset += n
            }
        }
    }

    static func isPrivateOrLocalIPv4(_ value: Data) -> Bool {
        guard value.count == 4 else { return true }
        let b = [UInt8](value)
        if b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 { return true }
        if b[0] == 100 && (64...127).contains(b[1]) { return true }
        if b[0] == 169 && b[1] == 254 { return true }
        if b[0] == 172 && (16...31).contains(b[1]) { return true }
        if b[0] == 192 && b[1] == 168 { return true }
        return false
    }

    static func ipv4Data(_ value: String) -> Data? {
        var address = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Data($0.prefix(4)) }
    }

    static func shutdownAndClose(_ fd: Int32) {
        guard fd >= 0 else { return }
        _ = shutdown(fd, Int32(SHUT_RDWR))
        closeFD(fd)
    }

    static func closeDatagram(_ fd: Int32) {
        guard fd >= 0 else { return }
        closeFD(fd)
    }

    private static func peerAddress(_ storage: sockaddr_storage) -> String {
        var copy = storage
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return withUnsafePointer(to: &copy) { pointer -> String in
            if Int32(storage.ss_family) == AF_INET {
                return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                    var addr = p.pointee.sin_addr
                    guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count)) != nil else { return "unknown" }
                    return String(cString: buffer)
                }
            }
            return "unknown"
        }
    }

    private static func socketError(_ operation: String) -> LegacyTrackerRuntimeError {
        LegacyTrackerRuntimeError.socket("\(operation): \(String(cString: strerror(errno)))")
    }

    #if canImport(Darwin)
    private static func platformAccept(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ length: UnsafeMutablePointer<socklen_t>?) -> Int32 {
        Darwin.accept(fd, address, length)
    }
    private static func platformRecv(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        Darwin.recv(fd, buffer, count, 0)
    }
    private static func platformRecvFrom(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int,
                                         _ address: UnsafeMutablePointer<sockaddr>?,
                                         _ length: UnsafeMutablePointer<socklen_t>?) -> Int {
        Darwin.recvfrom(fd, buffer, count, 0, address, length)
    }
    private static func platformSend(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        Darwin.send(fd, buffer, count, 0)
    }
    private static func closeFD(_ fd: Int32) { _ = Darwin.close(fd) }
    #else
    private static func platformAccept(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ length: UnsafeMutablePointer<socklen_t>?) -> Int32 {
        Glibc.accept(fd, address, length)
    }
    private static func platformRecv(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        Glibc.recv(fd, buffer, count, 0)
    }
    private static func platformRecvFrom(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int,
                                         _ address: UnsafeMutablePointer<sockaddr>?,
                                         _ length: UnsafeMutablePointer<socklen_t>?) -> Int {
        Glibc.recvfrom(fd, buffer, count, 0, address, length)
    }
    private static func platformSend(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        Glibc.send(fd, buffer, count, Int32(MSG_NOSIGNAL))
    }
    private static func closeFD(_ fd: Int32) { _ = Glibc.close(fd) }
    #endif
}
