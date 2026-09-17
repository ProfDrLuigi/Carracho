import Cocoa
@preconcurrency import UserNotifications

enum ClientSoundEvent: String, CaseIterable {
    case message
    case chat
    case userSignedIn
    case userSignedOut
    case transferCompleted
    case invitation
    case newsPost
    case error

    var title: String {
        switch self {
        case .message: return L("Message")
        case .chat: return L("Chat")
        case .userSignedIn: return L("User signed in")
        case .userSignedOut: return L("User signed out")
        case .transferCompleted: return L("File transfer completed")
        case .invitation: return L("Invitation")
        case .newsPost: return L("New News Post")
        case .error: return L("Error")
        }
    }

    var defaultSoundIdentifier: String {
        switch self {
        case .message: return ClientSoundPreferences.builtInIdentifier("Glass")
        case .chat: return ClientSoundPreferences.builtInIdentifier("Pop")
        case .userSignedIn: return ClientSoundPreferences.builtInIdentifier("Tink")
        case .userSignedOut: return ClientSoundPreferences.noSoundIdentifier
        case .transferCompleted: return ClientSoundPreferences.builtInIdentifier("Hero")
        case .invitation: return ClientSoundPreferences.builtInIdentifier("Ping")
        case .newsPost: return ClientSoundPreferences.builtInIdentifier("Submarine")
        case .error: return ClientSoundPreferences.builtInIdentifier("Basso")
        }
    }
}

@MainActor
final class ClientSoundPreferences {
    static let enabledDefaultsKey = "Carracho.Sounds.Enabled.v1"
    static let volumeDefaultsKey = "Carracho.Sounds.Volume.v1"
    static let eventDefaultsKeyPrefix = "Carracho.Sounds.Event.v1."
    static let notificationDefaultsKeyPrefix = "Carracho.Notifications.Event.v1."
    static let noSoundIdentifier = "none"
    static let builtInPrefix = "builtin:"
    static let customPrefix = "custom:"
    static let defaultVolume = 0.70

    static let builtInSoundNames = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    private let defaults: UserDefaults
    private var activeSound: NSSound?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func builtInIdentifier(_ name: String) -> String { builtInPrefix + name }
    static func customIdentifier(_ filename: String) -> String { customPrefix + filename }

    var enabled: Bool {
        guard defaults.object(forKey: Self.enabledDefaultsKey) != nil else { return true }
        return defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    var volume: Double {
        guard defaults.object(forKey: Self.volumeDefaultsKey) != nil else { return Self.defaultVolume }
        return min(1, max(0, defaults.double(forKey: Self.volumeDefaultsKey)))
    }

    func selection(for event: ClientSoundEvent) -> String {
        defaults.string(forKey: Self.eventDefaultsKeyPrefix + event.rawValue) ?? event.defaultSoundIdentifier
    }

    func notificationEnabled(for event: ClientSoundEvent) -> Bool {
        defaults.bool(forKey: Self.notificationDefaultsKeyPrefix + event.rawValue)
    }

    func save(enabled: Bool, volume: Double, selections: [ClientSoundEvent: String],
              notifications: [ClientSoundEvent: Bool]) {
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        defaults.set(min(1, max(0, volume)), forKey: Self.volumeDefaultsKey)
        for event in ClientSoundEvent.allCases {
            defaults.set(selections[event] ?? event.defaultSoundIdentifier,
                         forKey: Self.eventDefaultsKeyPrefix + event.rawValue)
            defaults.set(notifications[event] ?? false,
                         forKey: Self.notificationDefaultsKeyPrefix + event.rawValue)
        }
    }

    func restoreDefaults() {
        defaults.set(true, forKey: Self.enabledDefaultsKey)
        defaults.set(Self.defaultVolume, forKey: Self.volumeDefaultsKey)
        for event in ClientSoundEvent.allCases {
            defaults.set(event.defaultSoundIdentifier,
                         forKey: Self.eventDefaultsKeyPrefix + event.rawValue)
            defaults.set(false, forKey: Self.notificationDefaultsKeyPrefix + event.rawValue)
        }
    }

    func play(_ event: ClientSoundEvent) {
        guard enabled else { return }
        play(identifier: selection(for: event), volume: volume)
    }

    func play(identifier: String, volume: Double) {
        guard identifier != Self.noSoundIdentifier,
              let sound = sound(for: identifier) else { return }
        activeSound?.stop()
        sound.volume = Float(min(1, max(0, volume)))
        activeSound = sound
        sound.play()
    }

    func stopPreview() {
        activeSound?.stop()
        activeSound = nil
    }

    func availableSounds() -> [(title: String, identifier: String)] {
        var result = [(L("No Sound"), Self.noSoundIdentifier)]
        result.append(contentsOf: Self.builtInSoundNames.map { ($0, Self.builtInIdentifier($0)) })
        result.append(contentsOf: customSoundFiles().map { url in
            (url.deletingPathExtension().lastPathComponent, Self.customIdentifier(url.lastPathComponent))
        })
        return result
    }

    func customSoundFiles() -> [URL] {
        let supported = Set(["aif", "aiff", "wav", "mp3", "m4a", "caf"])
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: soundsDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { supported.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    var soundsDirectoryURL: URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        return base
            .appendingPathComponent("Carracho", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    @discardableResult
    func ensureSoundsDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: soundsDirectoryURL,
                                                withIntermediateDirectories: true)
        return soundsDirectoryURL
    }

    func importSound(from sourceURL: URL) throws -> URL {
        let directory = try ensureSoundsDirectory()
        let manager = FileManager.default
        let originalName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var destination = directory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
        var suffix = 2
        while manager.fileExists(atPath: destination.path) {
            let candidate = ext.isEmpty ? "\(originalName) \(suffix)" : "\(originalName) \(suffix).\(ext)"
            destination = directory.appendingPathComponent(candidate, isDirectory: false)
            suffix += 1
        }
        try manager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func sound(for identifier: String) -> NSSound? {
        if identifier.hasPrefix(Self.builtInPrefix) {
            let name = String(identifier.dropFirst(Self.builtInPrefix.count))
            if let sound = NSSound(named: NSSound.Name(name)) { return sound }
            let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
            return NSSound(contentsOf: url, byReference: true)
        }
        if identifier.hasPrefix(Self.customPrefix) {
            let filename = String(identifier.dropFirst(Self.customPrefix.count))
            guard !filename.isEmpty,
                  filename == URL(fileURLWithPath: filename).lastPathComponent else { return nil }
            let url = soundsDirectoryURL.appendingPathComponent(filename, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return NSSound(contentsOf: url, byReference: true)
        }
        return nil
    }
}


@MainActor
final class ClientNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func prepareAuthorization() {
        let notificationCenter = center
        notificationCenter.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            notificationCenter.requestAuthorization(options: [.alert, .badge]) { _, _ in }
        }
    }

    func post(title: String, body: String) {
        let notificationCenter = center
        let deliver: () -> Void = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = nil
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content,
                                                trigger: nil)
            notificationCenter.add(request)
        }

        notificationCenter.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                deliver()
            case .notDetermined:
                notificationCenter.requestAuthorization(options: [.alert, .badge]) { granted, _ in
                    if granted { deliver() }
                }
            default:
                break
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .list])
        } else {
            completionHandler([.alert])
        }
    }
}
