#if CARRACHO_SERVER
import Foundation
import Darwin

private extension Dictionary where Key == String, Value == Any {
    func writePropertyList(to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: self, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }
}

struct CarrachoLaunchDaemonStatus {
    var installed: Bool
    var loaded: Bool
    var running: Bool
    var snapshot: CarrachoDaemonSnapshot?
    var startsAtBoot: Bool = false
}

enum CarrachoLaunchDaemonError: LocalizedError {
    case noExecutable
    case privilegeCommand(String)
    case invalidSnapshot

    var errorDescription: String? {
        switch self {
        case .noExecutable: return L("The Carracho Server executable could not be located.")
        case let .privilegeCommand(message): return message.isEmpty ? L("The privileged daemon operation failed.") : message
        case .invalidSnapshot: return L("The daemon status file is invalid.")
        }
    }
}

/// Installs root-owned launchd definitions, while the actual jobs run as the current macOS user.
/// That gives the daemons boot/login independence without changing ownership of the user's server DB/files.
final class CarrachoLaunchDaemonManager {
    static let daemonDirectoryURL = URL(fileURLWithPath: "/Library/Application Support/Carracho/Daemon", isDirectory: true)
    static let binaryURL = daemonDirectoryURL.appendingPathComponent("carracho-serverd", isDirectory: false)
    /// Pre-dedicated-daemon installations copied the complete GUI app here.
    /// Remove that legacy copy during the next install/uninstall migration.
    static let legacyInstalledAppURL = daemonDirectoryURL.appendingPathComponent("Carracho Server.app", isDirectory: true)
    static let launchDaemonsURL = URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)

    /// Returns true when at least one system service is installed but its shared daemon binary
    /// does not exactly match the helper embedded in the currently running Server app.
    /// The comparison is intentionally byte-for-byte: a rebuilt hotfix with the same marketing
    /// version still requires the installed daemon to be refreshed.
    func installedDaemonNeedsUpdate() -> Bool {
        guard isInstalled(.server) || isInstalled(.tracker) else { return false }

        let bundled = bundledDaemonURL()
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: bundled.path),
              manager.isExecutableFile(atPath: Self.binaryURL.path) else {
            return true
        }

        do {
            return try !filesMatch(bundled, Self.binaryURL)
        } catch {
            // If the installed helper cannot be read reliably, treating it as stale is safer
            // than silently claiming it matches the app.
            return true
        }
    }

    func serviceIsInstalled(_ kind: CarrachoDaemonKind) -> Bool {
        isInstalled(kind)
    }

    func status(for kind: CarrachoDaemonKind, rootURL: URL) -> CarrachoLaunchDaemonStatus {
        let installed = isInstalled(kind)
        let snapshot = readSnapshot(for: kind, rootURL: rootURL)
        let heartbeatAlive: Bool
        if let snapshot {
            heartbeatAlive = Date().timeIntervalSince(snapshot.updatedAt) < 4.0 && processIsAlive(snapshot.pid)
        } else {
            heartbeatAlive = false
        }
        // A normal user can usually inspect system launchd jobs, but a live heartbeat is an
        // equally strong fallback if launchctl visibility is restricted.
        let loaded = launchctlPrint(kind) == 0 || (installed && heartbeatAlive)
        let running = loaded && heartbeatAlive && snapshot?.isRunning == true
        return CarrachoLaunchDaemonStatus(
            installed: installed,
            loaded: loaded,
            running: running,
            snapshot: snapshot,
            startsAtBoot: installed && startsAtBoot(for: kind)
        )
    }

    /// Cheap display status derived from the installed definition and daemon heartbeat.
    /// This never launches launchctl, so it is safe to use from frequent UI refreshes.
    func heartbeatStatus(for kind: CarrachoDaemonKind, rootURL: URL) -> CarrachoLaunchDaemonStatus {
        let installed = isInstalled(kind)
        let snapshot = readSnapshot(for: kind, rootURL: rootURL)
        let heartbeatAlive: Bool
        if let snapshot {
            heartbeatAlive = Date().timeIntervalSince(snapshot.updatedAt) < 4.0 && processIsAlive(snapshot.pid)
        } else {
            heartbeatAlive = false
        }
        let loaded = installed && heartbeatAlive
        let running = loaded && snapshot?.isRunning == true
        return CarrachoLaunchDaemonStatus(
            installed: installed,
            loaded: loaded,
            running: running,
            snapshot: snapshot,
            startsAtBoot: installed && startsAtBoot(for: kind)
        )
    }

    func install(_ kind: CarrachoDaemonKind,
                 rootURL: URL,
                 startsAtBoot: Bool = true,
                 startNow: Bool = true) throws {
        let sourceAppURL = Bundle.main.bundleURL.standardizedFileURL
        let sourceExecutable = bundledDaemonURL()
        guard sourceAppURL.pathExtension == "app",
              FileManager.default.isExecutableFile(atPath: sourceExecutable.path) else {
            throw CarrachoLaunchDaemonError.noExecutable
        }

        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(
            "carracho-daemon-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }

        let stagedPlist = temporary.appendingPathComponent("\(kind.label).plist")
        try daemonPlist(kind: kind, rootURL: rootURL).writePropertyList(to: stagedPlist)

        let logs = rootURL.standardizedFileURL.appendingPathComponent("logs", isDirectory: true)
        try manager.createDirectory(at: logs, withIntermediateDirectories: true)

        // Server and Tracker share one executable. Reinstalling either service therefore also
        // migrates an older sibling definition while preserving its live and boot-start state.
        let other = kind == .server ? CarrachoDaemonKind.tracker : .server
        let otherInstalled = isInstalled(other)
        let otherStatus = otherInstalled ? status(for: other, rootURL: rootURL) : nil
        let otherWasLoaded = otherStatus?.loaded == true
        let otherStartsAtBoot = otherStatus?.startsAtBoot ?? true
        let stagedOtherPlist = temporary.appendingPathComponent("\(other.label).plist")
        if otherInstalled {
            try daemonPlist(kind: other, rootURL: rootURL).writePropertyList(to: stagedOtherPlist)
        }

        let stopOther = otherWasLoaded
            ? "/bin/launchctl bootout system/\(other.label) >/dev/null 2>&1 || true"
            : ":"

        let installOther: String
        if otherInstalled {
            installOther = """
            /usr/bin/install -o root -g wheel -m 644 \(Self.sh(stagedOtherPlist.path)) \(Self.sh(installedPlistURL(for: other).path))
            \(otherStartsAtBoot
                ? "/usr/bin/install -o root -g wheel -m 644 \(Self.sh(stagedOtherPlist.path)) \(Self.sh(bootPlistURL(for: other).path))"
                : "/bin/rm -f \(Self.sh(bootPlistURL(for: other).path))")
            /bin/rm -f \(Self.sh(legacyAutoStartStateURL(for: other).path))
            """
        } else {
            installOther = ":"
        }

        let restartOther = otherWasLoaded
            ? """
              /bin/launchctl enable system/\(other.label) >/dev/null 2>&1 || true
              /bin/launchctl bootstrap system \(Self.sh(installedPlistURL(for: other).path))
              /bin/launchctl kickstart -k system/\(other.label)
              """
            : ":"

        let configureCurrent = startNow
            ? """
              /bin/launchctl enable system/\(kind.label) >/dev/null 2>&1 || true
              /bin/launchctl bootstrap system \(Self.sh(installedPlistURL(for: kind).path))
              /bin/launchctl kickstart -k system/\(kind.label)
              """
            : ":"

        let script = temporary.appendingPathComponent("install.sh")
        let body = """
        #!/bin/sh
        set -eu
        /bin/launchctl bootout system/\(kind.label) >/dev/null 2>&1 || true
        \(stopOther)
        /bin/mkdir -p \(Self.sh(Self.daemonDirectoryURL.path))
        /usr/sbin/chown root:wheel \(Self.sh(Self.daemonDirectoryURL.path))
        /bin/chmod 755 \(Self.sh(Self.daemonDirectoryURL.path))
        /bin/rm -rf \(Self.sh(Self.legacyInstalledAppURL.path))
        /usr/bin/install -o root -g wheel -m 755 \(Self.sh(sourceExecutable.path)) \(Self.sh(Self.binaryURL.path))
        /usr/bin/install -o root -g wheel -m 644 \(Self.sh(stagedPlist.path)) \(Self.sh(installedPlistURL(for: kind).path))
        \(startsAtBoot
            ? "/usr/bin/install -o root -g wheel -m 644 \(Self.sh(stagedPlist.path)) \(Self.sh(bootPlistURL(for: kind).path))"
            : "/bin/rm -f \(Self.sh(bootPlistURL(for: kind).path))")
        /bin/rm -f \(Self.sh(legacyAutoStartStateURL(for: kind).path))
        \(installOther)
        \(configureCurrent)
        \(restartOther)
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try runPrivileged(scriptURL: script)
    }

    func uninstall(_ kind: CarrachoDaemonKind) throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(
            "carracho-daemon-uninstall-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }

        let other = kind == .server ? CarrachoDaemonKind.tracker : .server
        let script = temporary.appendingPathComponent("uninstall.sh")
        let body = """
        #!/bin/sh
        set -eu
        /bin/launchctl bootout system/\(kind.label) >/dev/null 2>&1 || true
        /bin/launchctl enable system/\(kind.label) >/dev/null 2>&1 || true
        /bin/rm -f \(Self.sh(bootPlistURL(for: kind).path))
        /bin/rm -f \(Self.sh(installedPlistURL(for: kind).path))
        /bin/rm -f \(Self.sh(legacyAutoStartStateURL(for: kind).path))
        if [ ! -f \(Self.sh(bootPlistURL(for: other).path)) ] && [ ! -f \(Self.sh(installedPlistURL(for: other).path)) ]; then
            /bin/rm -f \(Self.sh(Self.binaryURL.path))
            /bin/rm -rf \(Self.sh(Self.legacyInstalledAppURL.path))
            /bin/rmdir \(Self.sh(Self.daemonDirectoryURL.path)) >/dev/null 2>&1 || true
        fi
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try runPrivileged(scriptURL: script)
    }

    func setRunning(_ running: Bool, kind: CarrachoDaemonKind) throws {
        guard isInstalled(kind) else {
            throw CarrachoLaunchDaemonError.privilegeCommand(
                LF("The %@ daemon is not installed.", kind.rawValue)
            )
        }

        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(
            "carracho-daemon-control-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }

        let sourcePlist = preferredInstalledPlistURL(for: kind)
        let script = temporary.appendingPathComponent("control.sh")
        let command: String
        if running {
            command = """
            /bin/launchctl enable system/\(kind.label) >/dev/null 2>&1 || true
            /bin/launchctl bootstrap system \(Self.sh(sourcePlist.path)) >/dev/null 2>&1 || true
            /bin/launchctl kickstart -k system/\(kind.label)
            """
        } else {
            command = "/bin/launchctl bootout system/\(kind.label) >/dev/null 2>&1 || true"
        }

        let body = "#!/bin/sh\nset -eu\n\(command)\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try runPrivileged(scriptURL: script)
    }

    func setStartsAtBoot(_ enabled: Bool, kind: CarrachoDaemonKind) throws {
        guard isInstalled(kind) else {
            throw CarrachoLaunchDaemonError.privilegeCommand(
                LF("The %@ daemon is not installed.", kind.rawValue)
            )
        }

        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(
            "carracho-daemon-autostart-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }

        let internalURL = installedPlistURL(for: kind)
        let bootURL = bootPlistURL(for: kind)
        let script = temporary.appendingPathComponent("autostart.sh")
        let configureBoot = enabled
            ? "/usr/bin/install -o root -g wheel -m 644 \(Self.sh(internalURL.path)) \(Self.sh(bootURL.path))"
            : "/bin/rm -f \(Self.sh(bootURL.path))"
        let body = """
        #!/bin/sh
        set -eu
        /bin/mkdir -p \(Self.sh(Self.daemonDirectoryURL.path))
        if [ ! -f \(Self.sh(internalURL.path)) ]; then
            /usr/bin/install -o root -g wheel -m 644 \(Self.sh(bootURL.path)) \(Self.sh(internalURL.path))
        fi
        /bin/launchctl enable system/\(kind.label) >/dev/null 2>&1 || true
        \(configureBoot)
        /bin/rm -f \(Self.sh(legacyAutoStartStateURL(for: kind).path))
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try runPrivileged(scriptURL: script)
    }

    private func bundledDaemonURL() -> URL {
        Bundle.main.bundleURL.standardizedFileURL.appendingPathComponent(
            "Contents/Helpers/carracho-serverd",
            isDirectory: false
        )
    }

    private func filesMatch(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let manager = FileManager.default
        let leftSize = (try manager.attributesOfItem(atPath: lhs.path)[.size] as? NSNumber)?.uint64Value
        let rightSize = (try manager.attributesOfItem(atPath: rhs.path)[.size] as? NSNumber)?.uint64Value
        guard leftSize == rightSize else { return false }

        let left = try FileHandle(forReadingFrom: lhs)
        let right = try FileHandle(forReadingFrom: rhs)
        defer {
            try? left.close()
            try? right.close()
        }

        let chunkSize = 256 * 1024
        while true {
            let leftChunk = left.readData(ofLength: chunkSize)
            let rightChunk = right.readData(ofLength: chunkSize)
            guard leftChunk == rightChunk else { return false }
            if leftChunk.isEmpty { return true }
        }
    }

    private func isInstalled(_ kind: CarrachoDaemonKind) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: installedPlistURL(for: kind).path)
            || manager.fileExists(atPath: bootPlistURL(for: kind).path)
    }

    private func startsAtBoot(for kind: CarrachoDaemonKind) -> Bool {
        FileManager.default.fileExists(atPath: bootPlistURL(for: kind).path)
    }

    private func preferredInstalledPlistURL(for kind: CarrachoDaemonKind) -> URL {
        let internalURL = installedPlistURL(for: kind)
        return FileManager.default.fileExists(atPath: internalURL.path)
            ? internalURL
            : bootPlistURL(for: kind)
    }

    private func installedPlistURL(for kind: CarrachoDaemonKind) -> URL {
        Self.daemonDirectoryURL.appendingPathComponent("\(kind.rawValue).plist", isDirectory: false)
    }

    private func bootPlistURL(for kind: CarrachoDaemonKind) -> URL {
        Self.launchDaemonsURL.appendingPathComponent("\(kind.label).plist", isDirectory: false)
    }

    /// Cleanup-only compatibility path used by an intermediate development implementation.
    private func legacyAutoStartStateURL(for kind: CarrachoDaemonKind) -> URL {
        Self.daemonDirectoryURL.appendingPathComponent("\(kind.rawValue)-autostart", isDirectory: false)
    }

    private func daemonPlist(kind: CarrachoDaemonKind, rootURL: URL) -> [String: Any] {
        let standardizedRoot = rootURL.standardizedFileURL
        let logs = standardizedRoot.appendingPathComponent("logs", isDirectory: true)
        return [
            "Label": kind.label,
            "ProgramArguments": [Self.binaryURL.path, kind.argument, "--server-root=\(standardizedRoot.path)"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "UserName": NSUserName(),
            "WorkingDirectory": standardizedRoot.path,
            "StandardOutPath": logs.appendingPathComponent("\(kind.rawValue)-daemon.stdout.log").path,
            "StandardErrorPath": logs.appendingPathComponent("\(kind.rawValue)-daemon.stderr.log").path,
        ]
    }

    private func readSnapshot(for kind: CarrachoDaemonKind, rootURL: URL) -> CarrachoDaemonSnapshot? {
        let url = Self.statusURL(kind: kind, rootURL: rootURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(CarrachoDaemonSnapshot.self, from: data),
              value.kind.rawValue == kind.rawValue else { return nil }
        return value
    }

    private func launchctlPrint(_ kind: CarrachoDaemonKind) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(kind.label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
        catch { return -1 }
    }

    private func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    private func runPrivileged(scriptURL: URL) throws {
        let shellCommand = Self.sh(scriptURL.path)
        let appleScript = "do shell script \(Self.appleScriptString(shellCommand)) with administrator privileges"
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CarrachoLaunchDaemonError.privilegeCommand(message)
        }
    }

    static func statusURL(kind: CarrachoDaemonKind, rootURL: URL) -> URL {
        kind.statusURL(rootURL: rootURL)
    }

    fileprivate static func sh(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
#endif
