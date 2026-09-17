import Foundation
@preconcurrency import Network

enum LegacyControlClientError: Error, LocalizedError {
    case alreadyConnected
    case invalidInput(String)
    case transport(String)
    case timedOut(String)
    case connectionClosed
    case invalidServerHello
    case unexpectedCommand(expected: UInt32, actual: UInt32)
    case missingField(UInt32)
    case serverError(UInt16)
    case protocolFailure(String)

    var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            return "Es besteht bereits eine Verbindung."
        case let .invalidInput(message):
            return message
        case let .transport(message):
            return "Netzwerkfehler: \(message)"
        case let .timedOut(operation):
            return "Zeitüberschreitung bei \(operation)."
        case .connectionClosed:
            return "Die Verbindung wurde geschlossen."
        case .invalidServerHello:
            return "Der Server hat kein gültiges Carracho-1.x-Hello gesendet."
        case let .unexpectedCommand(expected, actual):
            return String(format: "Unerwarteter Protokollbefehl 0x%08x (erwartet 0x%08x).", actual, expected)
        case let .missingField(type):
            return String(format: "Im Serverpaket fehlt TLV 0x%08x.", type)
        case let .serverError(code):
            if code == 100 { return "Login fehlgeschlagen (Serverfehler 100)." }
            if code == 105 { return "Zu viele Verbindungen (Serverfehler 105)." }
            return "Der Server meldet Fehler \(code)."
        case let .protocolFailure(message):
            return "Protokollfehler: \(message)"
        }
    }
}

struct LegacyLoginResult {
    var session: LegacyLoginSessionInfo
    var serverName: String
    var users: [LegacyUserListEntry]
    var agreement: LegacyAgreementContent?
    var maxFileTransfersPerUser: UInt16?
    var transferProtocolVersion: UInt16?
    var mediaCapabilities: UInt32 = 0
    var filesRootName: String = LegacyFilesRootCapability.defaultDisplayName

    var supportsMediaAttachments: Bool {
        mediaCapabilities & LegacyMediaCapability.attachmentsV1 != 0
    }

    var supportsYouTubeLinks: Bool {
        mediaCapabilities & LegacyMediaCapability.youtubeLinksV1 != 0
    }

    var supportsMediaOwnerDelete: Bool {
        mediaCapabilities & LegacyMediaCapability.ownerDeleteV1 != 0
    }
}

struct LegacyClientTransferQueueCapacity {
    static func startCount(queuedCount: Int,
                           localActive: Int,
                           maxPerUser: UInt16,
                           reportedOwnActive: UInt16?,
                           maxServer: UInt16?,
                           reportedServerActive: UInt16?) -> Int {
        guard queuedCount > 0 else { return 0 }
        let reportedOwn = Int(reportedOwnActive ?? 0)
        let ownActive = max(localActive, reportedOwn)
        let ownSlots = max(0, Int(maxPerUser) - ownActive)
        let serverSlots: Int
        if let maxServer, let reportedServerActive {
            // A transfer can be locally marked active a few milliseconds before the next
            // server-info snapshot sees it. Reserve those not-yet-reported local slots here so
            // the queue cannot transiently oversubscribe the server-wide limit.
            let unreportedLocal = max(0, localActive - reportedOwn)
            serverSlots = max(0, Int(maxServer) - Int(reportedServerActive) - unreportedLocal)
        } else {
            serverSlots = Int.max
        }
        return min(queuedCount, ownSlots, serverSlots)
    }
}

struct LegacyServerInfo {
    var serverName: String?
    var location: String?
    var systemOperator: String?
    var description: String?
    var softwareVersion: String?
    var uptimeTicks: UInt32?
    var maxSimultaneousFileTransfers: UInt16? = nil
    var activeFileTransfers: UInt16? = nil
    var maxFileTransfersPerUser: UInt16? = nil
    var activeFileTransfersForUser: UInt16? = nil
}

struct LegacyChannelState: Equatable {
    var channelID: UInt32
    var name: Data
    var topic: Data
    var members: [LegacyChannelMember]
    var flags: UInt16
}

struct LegacyChannelMessage: Equatable {
    var channelID: UInt32
    var senderUserID: UInt32
    var message: Data
    var attribute: UInt8
}

struct LegacyChannelInvitation: Equatable {
    var channelID: UInt32
    var inviterUserID: UInt32
    var name: Data
}

struct LegacyBroadcastMessage: Equatable {
    var senderUserID: UInt32
    var message: Data
}

struct LegacyPrivateMessage: Equatable {
    var senderUserID: UInt32
    var message: Data
    var secondaryPayload: Data
}

struct LegacyUserInfoReply: Equatable {
    var userID: UInt32
    var nickname: Data
    var name: Data
    var email: Data
    var aboutMe: Data
    var picture: Data
    var ipAddress: UInt32?
    var loginTime: UInt32?
    var idleTime: UInt32?
    var statusMessage: Data
    var groupColorRGB: UInt32?
    var loginName: Data?
    var taskList: Data?
    var operatingSystem: String?
    var cpuArchitecture: String?
    var clientVersion: String?
    var clientBuild: String?
}

struct LegacyTransferSession: Equatable {
    let userID: UInt32
    let key: Data
    let modernSalt: Data?

    init(userID: UInt32, key: Data, modernSalt: Data? = nil) {
        self.userID = userID
        self.key = key
        self.modernSalt = modernSalt
    }

    var usesModernCrypto: Bool { modernSalt?.count == CarrachoModernCrypto.sessionSaltLength }
}

enum LegacyControlEvent {
    case userArrived(LegacyUserListEntry)
    case userDisconnected(UInt32)
    case presence(userID: UInt32, sleeping: Bool)
    case privateMessage(LegacyPrivateMessage)
    case offlineMessagesAvailable(Int)
    case broadcastMessage(LegacyBroadcastMessage)
    case userUpdated(userID: UInt32, nickname: Data, picture: Data, statusMessage: Data?)
    case userStatus(userID: UInt32, statusMessage: Data)
    case userGroupColor(userID: UInt32, colorRGB: UInt32?)
    case ownPermissionsChanged(permissionWord0: UInt32, permissionWord1: UInt32)
    case channelUserJoined(channelID: UInt32, userID: UInt32, mode: UInt8)
    case channelUserLeft(channelID: UInt32, userID: UInt32)
    case channelUserMode(channelID: UInt32, userID: UInt32, mode: UInt8)
    case channelInvitation(LegacyChannelInvitation)
    case channelInvitationDeclined(channelID: UInt32, userID: UInt32)
    case channelMessage(LegacyChannelMessage)
    case channelSettings(channelID: UInt32, topic: Data, flags: UInt16)
    case flatNewsPosted(Data)
    case flatNewsDeleted(UInt32)
    case flatNewsCleared
    case bannerChanged
    case mediaDeleted(UUID)
    case fileLabelChanged(path: Data, label: LegacyFileLabel)
    case forcedDisconnect
    case unhandled(LegacyPacket)
}

struct LegacyNewsThreadEntriesResult: Equatable {
    var posts: [LegacyNewsThreadPostSummary]
    var capabilities: [LegacyNewsPostCapability]
}

final class LegacyControlClient {
    enum State: Equatable {
        case idle
        case connecting
        case handshaking
        case authenticating
        case connected
        case disconnecting
        case failed(String)
    }

    var onStateChange: ((State) -> Void)?
    var onEvent: ((LegacyControlEvent) -> Void)?
    /// Raw packet callback retained for diagnostics and future command implementations.
    var onAsyncPacket: ((LegacyPacket) -> Void)?
    /// Explicit compatibility switch for tests and peers that must start with the Classic v1 hello.
    /// Normal app connections advertise the modern hello first, but accept a Classic v2 server hello
    /// and continue with the original Blowfish transport when talking to Server 1.0b13-era peers.
    var allowLegacyCrypto = false
    private var negotiatedLegacyCrypto = false

    private struct PendingRequest {
        let completion: (Result<LegacyPacket, Error>) -> Void
        let timeoutWorkItem: DispatchWorkItem
    }

    private static let connectTimeout: TimeInterval = 12
    private static let handshakeTimeout: TimeInterval = 12
    private static let requestTimeout: TimeInterval = 15

    private static func clientMetadataFields() -> [LegacyTLV] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let operatingSystem = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #else
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        #endif

        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #elseif arch(i386)
        let architecture = "i386"
        #else
        let architecture = "unknown"
        #endif

        let bundle = Bundle.main
        let clientVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        let clientBuild = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
        let values: [(UInt32, String)] = [
            (LegacyClientMetadataField.operatingSystem, operatingSystem),
            (LegacyClientMetadataField.cpuArchitecture, architecture),
            (LegacyClientMetadataField.clientVersion, clientVersion),
            (LegacyClientMetadataField.clientBuild, clientBuild),
        ]
        return values.compactMap { pair in
            let (type, value) = pair
            let data = Data(value.utf8)
            guard !data.isEmpty, data.count <= LegacyClientMetadataField.maximumLength else { return nil }
            return LegacyTLV(type: type, value: data)
        }
    }

    private var connection: NWConnection?
    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    private var sessionKey: Data?
    private var modernControlChannel: CarrachoAEADChannel?
    private(set) var transferSession: LegacyTransferSession?
    private var loginCompletion: ((Result<LegacyLoginResult, Error>) -> Void)?
    private var currentNickname: Data?
    private var nextTransactionID: UInt32 = 1
    private var pendingRequests: [UInt32: PendingRequest] = [:]
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var expectedDisconnect = false

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    func connect(host: String,
                 port: UInt16 = LegacyWire.defaultControlPort,
                 login: String,
                 password: String,
                 nickname: String,
                 completion: @escaping (Result<LegacyLoginResult, Error>) -> Void) {
        guard connection == nil else {
            completion(.failure(LegacyControlClientError.alreadyConnected))
            return
        }

        do {
            let credentials = try validateCredentials(login: login, password: password, nickname: nickname)
            currentNickname = credentials.nickname
            let endpointPort = NWEndpoint.Port(rawValue: port)!
            let newConnection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            connection = newConnection
            sessionKey = nil
            modernControlChannel = nil
            negotiatedLegacyCrypto = false
            transferSession = nil
            expectedDisconnect = false
            loginCompletion = completion
            state = .connecting
            let timeout = DispatchWorkItem { [weak self, weak newConnection] in
                guard let self, self.connection === newConnection else { return }
                self.fail(LegacyControlClientError.timedOut("TCP-Verbindungsaufbau"))
            }
            connectTimeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout, execute: timeout)

            newConnection.stateUpdateHandler = { [weak self, weak newConnection] newState in
                guard let self, let newConnection, self.connection === newConnection else { return }
                switch newState {
                case .ready:
                    self.connectTimeoutWorkItem?.cancel()
                    self.connectTimeoutWorkItem = nil
                    self.beginHandshake(credentials: credentials)
                case let .failed(error):
                    self.fail(LegacyControlClientError.transport(error.localizedDescription))
                case .cancelled:
                    self.handleTransportClosed()
                default:
                    break
                }
            }
            newConnection.start(queue: .main)
        } catch {
            completion(.failure(error))
        }
    }

    func disconnect() {
        guard let connection else { return }
        expectedDisconnect = true
        state = .disconnecting
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        self.connection = nil
        sessionKey = nil
        modernControlChannel = nil
        negotiatedLegacyCrypto = false
        transferSession = nil
        currentNickname = nil
        failPending(with: LegacyControlClientError.connectionClosed)
        connection.cancel()
        state = .idle
    }

    func requestServerInfo(completion: @escaping (Result<LegacyServerInfo, Error>) -> Void) {
        sendRequest(command: LegacyCommand.serverInfo, fields: []) { result in
            completion(result.flatMap { packet in
                do {
                    guard packet.command == LegacyCommand.serverInfo else {
                        throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.serverInfo,
                                                                         actual: packet.command)
                    }
                    let uptimeTicks = try packet.firstField(type: LegacyServerInfoField.uptimeTicks)?.uint32BE()
                    let maxTransfers = try packet.firstField(type: LegacyServerInfoField.maxSimultaneousFileTransfers)?.uint16BE()
                    let activeTransfers = try packet.firstField(type: LegacyServerInfoField.activeFileTransfers)?.uint16BE()
                    let maxUserTransfers = try packet.firstField(type: LegacyServerInfoField.maxFileTransfersPerUser)?.uint16BE()
                    let activeUserTransfers = try packet.firstField(type: LegacyServerInfoField.activeFileTransfersForUser)?.uint16BE()
                    return .success(LegacyServerInfo(
                        serverName: Self.macRomanString(packet.firstField(type: LegacyServerInfoField.serverName)?.value),
                        location: Self.macRomanString(packet.firstField(type: LegacyServerInfoField.serverLocation)?.value),
                        systemOperator: Self.macRomanString(packet.firstField(type: LegacyServerInfoField.systemOperator)?.value),
                        description: Self.macRomanString(packet.firstField(type: LegacyServerInfoField.description)?.value),
                        softwareVersion: Self.macRomanString(packet.firstField(type: LegacyServerInfoField.softwareVersion)?.value),
                        uptimeTicks: uptimeTicks,
                        maxSimultaneousFileTransfers: maxTransfers,
                        activeFileTransfers: activeTransfers,
                        maxFileTransfersPerUser: maxUserTransfers,
                        activeFileTransfersForUser: activeUserTransfers
                    ))
                } catch {
                    return .failure(error)
                }
            })
        }
    }

    func requestDirectory(path: String = "",
                          completion: @escaping (Result<LegacyDirectoryListing, Error>) -> Void) {
        guard let pathData = path.data(using: .macOSRoman) else {
            completion(.failure(LegacyControlClientError.invalidInput(
                "Der Dateipfad muss in MacRoman darstellbar sein."
            )))
            return
        }
        requestDirectory(pathData: pathData, completion: completion)
    }

    func requestDirectory(pathData: Data,
                          completion: @escaping (Result<LegacyDirectoryListing, Error>) -> Void) {
        guard pathData.count <= LegacyPath.maximumWireLength else {
            completion(.failure(LegacyControlClientError.invalidInput(
                "Der Dateipfad darf höchstens 4096 Byte lang sein."
            )))
            return
        }
        let fields = pathData.isEmpty ? [] : [LegacyTLV(type: 1, value: pathData)]
        sendRequest(command: LegacyCommand.directory, fields: fields) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.directory else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.directory,
                                                                     actual: packet.command)
                }
                guard let payload = packet.firstField(type: 2)?.value else {
                    throw LegacyControlClientError.missingField(2)
                }
                var listing = try LegacyDirectoryListing.decode(payload)
                if let labels = packet.firstField(type: LegacyFileLabelField.directoryLabels)?.value {
                    guard labels.count == listing.entries.count else {
                        throw LegacyControlClientError.protocolFailure("invalid modern directory-label payload")
                    }
                    for index in listing.entries.indices {
                        listing.entries[index].label = LegacyFileLabel(rawValue: labels[index]) ?? .none
                    }
                }
                completion(.success(listing))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func requestChannels(completion: @escaping (Result<[LegacyChannelSummary], Error>) -> Void) {
        sendRequest(command: LegacyCommand.channelList, fields: []) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.channelList else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.channelList,
                                                                     actual: packet.command)
                }
                guard let payload = packet.firstField(type: 0x0a)?.value else {
                    throw LegacyControlClientError.missingField(0x0a)
                }
                completion(.success(try LegacyPackedRecords.decodeChannelList(payload)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func joinChannel(channelID: UInt32,
                     name: Data,
                     password: Data = Data(),
                     completion: @escaping (Result<LegacyChannelState, Error>) -> Void) {
        guard name.count <= 64, channelID != 0 || !name.isEmpty else {
            completion(.failure(LegacyControlClientError.invalidInput(
                "Der Channel braucht eine ID oder einen Namen mit höchstens 64 Byte."
            )))
            return
        }
        guard password.count <= 32 else {
            completion(.failure(LegacyControlClientError.invalidInput(
                "Das Channel-Passwort darf höchstens 32 Byte lang sein."
            )))
            return
        }
        let fields = [
            LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(channelID)),
            LegacyTLV(type: LegacyChannelField.name, value: name),
            LegacyTLV(type: LegacyChannelField.password, value: password),
        ]
        sendRequest(command: LegacyCommand.channelJoin, fields: fields) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.channelJoin else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.channelJoin, actual: packet.command)
                }
                guard let idField = packet.firstField(type: LegacyChannelField.channelID),
                      let nameField = packet.firstField(type: LegacyChannelField.name),
                      let membersField = packet.firstField(type: LegacyChannelField.members),
                      let flagsField = packet.firstField(type: LegacyChannelField.settings) else {
                    throw LegacyControlClientError.protocolFailure("unvollständige Channel-State-Antwort")
                }
                let state = LegacyChannelState(
                    channelID: try idField.uint32BE(),
                    name: nameField.value,
                    topic: packet.firstField(type: LegacyChannelField.topic)?.value ?? Data(),
                    members: try LegacyPackedRecords.decodeChannelMembers(membersField.value),
                    flags: try flagsField.uint16BE()
                )
                completion(.success(state))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func leaveChannel(channelID: UInt32,
                      completion: @escaping (Result<Void, Error>) -> Void) {
        sendRequest(command: LegacyCommand.channelLeave,
                    fields: [LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(channelID))]) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.channelLeave else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.channelLeave, actual: packet.command)
                }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func sendChannelMessage(channelID: UInt32,
                            message: Data,
                            attribute: UInt8 = 0,
                            completion: @escaping (Result<Void, Error>) -> Void) {
        guard !message.isEmpty, message.count <= 0x800 else {
            completion(.failure(LegacyControlClientError.invalidInput(
                "Eine Channel-Nachricht muss 1 bis 2048 Byte lang sein."
            )))
            return
        }
        sendOneWay(command: LegacyCommand.channelChat, fields: [
            LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(channelID)),
            LegacyTLV(type: LegacyChannelField.message, value: message),
            LegacyTLV(type: LegacyChannelField.chatAttribute, value: Data([attribute])),
        ], completion: completion)
    }

    func setChannelSettings(channelID: UInt32, topic: Data, flags: UInt16,
                            completion: @escaping (Result<Void, Error>) -> Void) {
        guard topic.count <= 0x100 else {
            completion(.failure(LegacyControlClientError.invalidInput("Das Channel-Topic darf höchstens 256 Byte lang sein.")))
            return
        }
        sendOneWay(command: LegacyCommand.channelSettings, fields: [
            LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(channelID)),
            LegacyTLV(type: LegacyChannelField.topic, value: topic),
            LegacyTLV(type: LegacyChannelField.settings, value: LegacyWire.uint16BE(flags)),
        ], completion: completion)
    }

    func setChannelUserMode(channelID: UInt32, userID: UInt32, mode: UInt8,
                            completion: @escaping (Result<Void, Error>) -> Void) {
        sendOneWay(command: LegacyCommand.channelUserMode, fields: [
            LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(channelID)),
            LegacyTLV(type: LegacyChannelField.userID, value: LegacyWire.uint32BE(userID)),
            LegacyTLV(type: LegacyChannelField.userMode, value: Data([mode])),
        ], completion: completion)
    }

    func inviteUser(_ userID: UInt32, toChannel channelID: UInt32,
                    completion: @escaping (Result<Void, Error>) -> Void) {
        sendTaskCompleteRequest(command: LegacyCommand.channelInvite, fields: [
            LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(channelID)),
            LegacyTLV(type: LegacyChannelField.userID, value: LegacyWire.uint32BE(userID)),
        ], completion: completion)
    }

    func declineChannelInvitation(channelID: UInt32, inviterUserID: UInt32,
                                  completion: @escaping (Result<Void, Error>) -> Void) {
        sendOneWay(command: LegacyCommand.channelDeclineInvitation, fields: [
            LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(channelID)),
            LegacyTLV(type: 0x0b, value: LegacyWire.uint32BE(inviterUserID)),
        ], completion: completion)
    }

    func requestArticle(group: Data,
                        articleID: UInt32,
                        completion: @escaping (Result<LegacyArticleReply, Error>) -> Void) {
        guard !group.isEmpty, group.count <= LegacyNewsTransfer.maximumGroupNameLength else {
            completion(.failure(LegacyControlClientError.invalidInput(
                "Der Newsgroup-Name muss 1 bis 64 Byte lang sein."
            )))
            return
        }
        sendRequest(command: LegacyCommand.articleRead, fields: [
            LegacyTLV(type: 1, value: group),
            LegacyTLV(type: 2, value: LegacyWire.uint32BE(articleID)),
        ]) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.newsgroupListReply else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.newsgroupListReply,
                                                                     actual: packet.command)
                }
                guard let metadataField = packet.firstField(type: 1),
                      let bodyField = packet.firstField(type: 2) else {
                    throw LegacyControlClientError.protocolFailure("unvollständige Artikel-Antwort")
                }
                let metadata = try LegacyArticleReplyMetadata.decode(metadataField.value)
                let body = try LegacyArticleBodyPayload.decode(bodyField.value)
                guard metadata.articleID == body.articleID else {
                    throw LegacyControlClientError.protocolFailure("Artikel-ID von Metadaten und Body stimmt nicht überein")
                }
                completion(.success(LegacyArticleReply(metadata: metadata, body: body)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func deleteArticle(group: Data,
                       articleID: UInt32,
                       completion: @escaping (Result<Void, Error>) -> Void) {
        guard !group.isEmpty, group.count <= LegacyNewsTransfer.maximumGroupNameLength else {
            completion(.failure(LegacyControlClientError.invalidInput("Der Newsgroup-Name muss 1 bis 64 Byte lang sein.")))
            return
        }
        sendRequest(command: LegacyCommand.articleDelete, fields: [
            LegacyTLV(type: 1, value: group),
            LegacyTLV(type: 2, value: LegacyWire.uint32BE(articleID)),
        ]) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.taskComplete else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.taskComplete, actual: packet.command)
                }
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }

    func requestNewsThreads(group: Data,
                            completion: @escaping (Result<[LegacyNewsThreadSummary], Error>) -> Void) {
        guard !group.isEmpty, group.count <= LegacyNewsTransfer.maximumGroupNameLength else {
            completion(.failure(LegacyControlClientError.invalidInput("The news category name must be 1 to 64 bytes.")))
            return
        }
        sendRequest(command: LegacyCommand.forumThreadList,
                    fields: [LegacyTLV(type: 1, value: group)]) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.forumThreadList else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.forumThreadList, actual: packet.command)
                }
                guard let field = packet.firstField(type: 1) else { throw LegacyControlClientError.missingField(1) }
                completion(.success(try LegacyPackedRecords.decodeNewsThreadList(field.value)))
            } catch { completion(.failure(error)) }
        }
    }

    func requestNewsThreadEntries(group: Data, threadID: UInt32,
                                  completion: @escaping (Result<[LegacyNewsThreadPostSummary], Error>) -> Void) {
        requestNewsThreadEntriesWithCapabilities(group: group, threadID: threadID) { result in
            completion(result.map(\.posts))
        }
    }

    func requestNewsThreadEntriesWithCapabilities(group: Data, threadID: UInt32,
                                                   completion: @escaping (Result<LegacyNewsThreadEntriesResult, Error>) -> Void) {
        guard !group.isEmpty, group.count <= LegacyNewsTransfer.maximumGroupNameLength,
              threadID != 0, threadID != LegacyArticle.noArticle else {
            completion(.failure(LegacyControlClientError.invalidInput("Invalid news thread.")))
            return
        }
        sendRequest(command: LegacyCommand.forumThreadEntries, fields: [
            LegacyTLV(type: 1, value: group),
            LegacyTLV(type: 2, value: LegacyWire.uint32BE(threadID)),
        ]) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.forumThreadEntries else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.forumThreadEntries, actual: packet.command)
                }
                guard let field = packet.firstField(type: 1) else { throw LegacyControlClientError.missingField(1) }
                let posts = try LegacyPackedRecords.decodeNewsThreadPosts(field.value)
                let capabilities = try packet.firstField(type: 2).map { try LegacyPackedRecords.decodeNewsPostCapabilities($0.value) } ?? []
                completion(.success(LegacyNewsThreadEntriesResult(posts: posts, capabilities: capabilities)))
            } catch { completion(.failure(error)) }
        }
    }

    func deleteNewsPost(group: Data, articleID: UInt32,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        guard !group.isEmpty, group.count <= LegacyNewsTransfer.maximumGroupNameLength,
              articleID != 0, articleID != LegacyArticle.noArticle else {
            completion(.failure(LegacyControlClientError.invalidInput("Invalid news article.")))
            return
        }
        sendRequest(command: LegacyCommand.forumArticleDelete, fields: [
            LegacyTLV(type: 1, value: group),
            LegacyTLV(type: 2, value: LegacyWire.uint32BE(articleID)),
        ]) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.taskComplete else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.taskComplete, actual: packet.command)
                }
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }

    func requestNewsReactions(group: Data, articleID: UInt32,
                              completion: @escaping (Result<[LegacyNewsReactionSummary], Error>) -> Void) {
        guard !group.isEmpty, group.count <= LegacyNewsTransfer.maximumGroupNameLength,
              articleID != 0, articleID != LegacyArticle.noArticle else {
            completion(.failure(LegacyControlClientError.invalidInput("Invalid news article.")))
            return
        }
        sendRequest(command: LegacyCommand.forumArticleReactions, fields: [
            LegacyTLV(type: 1, value: group),
            LegacyTLV(type: 2, value: LegacyWire.uint32BE(articleID)),
        ]) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.forumArticleReactions else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.forumArticleReactions, actual: packet.command)
                }
                guard let field = packet.firstField(type: 1) else { throw LegacyControlClientError.missingField(1) }
                var summaries = try LegacyPackedRecords.decodeNewsReactions(field.value)
                if let usersField = packet.firstField(type: 2) {
                    let users = try LegacyPackedRecords.decodeNewsReactionUsers(usersField.value)
                    for index in summaries.indices { summaries[index].userNames = users[summaries[index].kind] ?? [] }
                }
                completion(.success(summaries))
            } catch { completion(.failure(error)) }
        }
    }

    /// `reaction == 0` removes the caller's reaction. Values 1...6 select one of
    /// `LegacyNewsReactionKind`. The server returns the updated aggregate.
    func setNewsReaction(group: Data, articleID: UInt32, reaction: UInt8,
                         completion: @escaping (Result<[LegacyNewsReactionSummary], Error>) -> Void) {
        guard !group.isEmpty, group.count <= LegacyNewsTransfer.maximumGroupNameLength,
              articleID != 0, articleID != LegacyArticle.noArticle,
              reaction == 0 || LegacyNewsReactionKind(rawValue: reaction) != nil else {
            completion(.failure(LegacyControlClientError.invalidInput("Invalid news reaction.")))
            return
        }
        sendRequest(command: LegacyCommand.forumArticleReactionSet, fields: [
            LegacyTLV(type: 1, value: group),
            LegacyTLV(type: 2, value: LegacyWire.uint32BE(articleID)),
            LegacyTLV(type: 3, value: Data([reaction])),
        ]) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.forumArticleReactionSet else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.forumArticleReactionSet, actual: packet.command)
                }
                guard let field = packet.firstField(type: 1) else { throw LegacyControlClientError.missingField(1) }
                var summaries = try LegacyPackedRecords.decodeNewsReactions(field.value)
                if let usersField = packet.firstField(type: 2) {
                    let users = try LegacyPackedRecords.decodeNewsReactionUsers(usersField.value)
                    for index in summaries.indices { summaries[index].userNames = users[summaries[index].kind] ?? [] }
                }
                completion(.success(summaries))
            } catch { completion(.failure(error)) }
        }
    }

    func requestNewsgroups(completion: @escaping (Result<[Data], Error>) -> Void) {
        sendRequest(command: LegacyCommand.newsgroupList, fields: []) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.newsgroupListReply else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.newsgroupListReply,
                                                                     actual: packet.command)
                }
                guard let payload = packet.firstField(type: 1)?.value else {
                    throw LegacyControlClientError.missingField(1)
                }
                completion(.success(try LegacyPackedRecords.decodeNewsgroupList(payload)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func requestTransferInfo(completion: @escaping (Result<[LegacyTransferInfoRecord], Error>) -> Void) {
        requestTransferMonitor { result in
            completion(result.map(\.transfers))
        }
    }

    func requestTransferMonitor(completion: @escaping (Result<LegacyTransferMonitorSnapshot, Error>) -> Void) {
        sendRequest(command: LegacyCommand.transferInfo, fields: []) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.transferInfo else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.transferInfo, actual: packet.command)
                }
                completion(.success(try LegacyTransferMonitorSnapshot.decode(fields: packet.fields)))
            } catch { completion(.failure(error)) }
        }
    }

    func controlTransfer(transferID: UInt32, action: LegacyTransferControlAction,
                         completion: @escaping (Result<LegacyTransferMonitorSnapshot, Error>) -> Void) {
        let request = LegacyTransferControlRequest(transferID: transferID, action: action)
        let field = LegacyTLV(type: LegacyTransferMonitorField.transferControl, value: request.encoded())
        sendRequest(command: LegacyCommand.transferInfo, fields: [field]) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.transferInfo else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.transferInfo, actual: packet.command)
                }
                completion(.success(try LegacyTransferMonitorSnapshot.decode(fields: packet.fields)))
            } catch { completion(.failure(error)) }
        }
    }

    /// Sets the server's aggregate outbound file bandwidth. Zero means unlimited.
    /// All user downloads share this cap on servers that implement the extended 0xe0 monitor.
    func setTransferUploadBandwidthLimit(bytesPerSecond: UInt64,
                                         completion: @escaping (Result<LegacyTransferMonitorSnapshot, Error>) -> Void) {
        let field = LegacyTLV(type: LegacyTransferMonitorField.uploadBandwidthLimit,
                              value: LegacyWire.uint64BE(bytesPerSecond))
        sendRequest(command: LegacyCommand.transferInfo, fields: [field]) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.transferInfo else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.transferInfo, actual: packet.command)
                }
                completion(.success(try LegacyTransferMonitorSnapshot.decode(fields: packet.fields)))
            } catch { completion(.failure(error)) }
        }
    }

    func requestFlatNews(completion: @escaping (Result<[Data], Error>) -> Void) {
        sendRequest(command: LegacyCommand.flatNewsList, fields: []) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.flatNewsList else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.flatNewsList, actual: packet.command)
                }
                completion(.success(packet.fields.filter { $0.type == LegacyCommand.flatNewsPost }.map(\.value)))
            } catch { completion(.failure(error)) }
        }
    }

    func postFlatNews(_ content: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let decoded = CarrachoTextWire.validatedString(from: content) else {
            completion(.failure(LegacyControlClientError.invalidInput("Flat News enthält ungültige Textdaten.")))
            return
        }
        let visibleText = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visibleText.isEmpty else {
            completion(.failure(LegacyControlClientError.invalidInput("Flat News darf nicht leer sein.")))
            return
        }
        guard content.count <= Int(UInt16.max) else {
            completion(.failure(LegacyControlClientError.invalidInput("Flat News darf höchstens 65535 Byte lang sein.")))
            return
        }
        if CarrachoTextWire.isTaggedUTF8(content), transferSession?.usesModernCrypto != true {
            completion(.failure(LegacyControlClientError.invalidInput("Emoji und Unicode in Flat News benötigen einen modernen Carracho-Server.")))
            return
        }
        sendTaskCompleteRequest(command: LegacyCommand.flatNewsPost,
                                fields: [LegacyTLV(type: LegacyCommand.flatNewsPost, value: content)],
                                completion: completion)
    }

    func deleteFlatNews(wireIndex: UInt32, completion: @escaping (Result<Void, Error>) -> Void) {
        guard wireIndex > 0 else {
            completion(.failure(LegacyControlClientError.invalidInput("Flat-News-Indizes beginnen bei 1.")))
            return
        }
        sendTaskCompleteRequest(command: LegacyCommand.flatNewsDelete,
                                fields: [LegacyTLV(type: LegacyCommand.flatNewsDelete, value: LegacyWire.uint32BE(wireIndex))],
                                completion: completion)
    }

    func clearFlatNews(completion: @escaping (Result<Void, Error>) -> Void) {
        sendTaskCompleteRequest(command: LegacyCommand.flatNewsClear, fields: [], completion: completion)
    }

    func broadcastMessage(_ message: Data,
                          completion: @escaping (Result<Void, Error>) -> Void) {
        guard let decoded = CarrachoTextWire.validatedString(from: message),
              !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.count <= 0x200 else {
            completion(.failure(LegacyControlClientError.invalidInput("Broadcast muss gültigen Text mit höchstens 512 Byte enthalten.")))
            return
        }
        var wireMessage = message
        if CarrachoTextWire.isTaggedUTF8(message), transferSession?.usesModernCrypto != true {
            guard let classic = CarrachoTextWire.macRomanFilteringEmoji(from: message),
                  !classic.isEmpty, classic.count <= 0x200 else {
                completion(.failure(LegacyControlClientError.invalidInput("Für Classic-Broadcasts werden Emoji entfernt; der übrige Text muss MacRoman-kompatibel und höchstens 512 Byte lang sein.")))
                return
            }
            wireMessage = classic
        }
        sendTaskCompleteRequest(command: LegacyCommand.broadcastMessage,
                                fields: [LegacyTLV(type: 1, value: wireMessage)], completion: completion)
    }

    // MARK: - Users / presence

    func sendPrivateMessage(to userID: UInt32, message: Data, secondaryPayload: Data = Data(),
                            completion: @escaping (Result<Void, Error>) -> Void) {
        guard !message.isEmpty, message.count <= 0x8000, secondaryPayload.count <= 0x8000 else {
            completion(.failure(LegacyControlClientError.invalidInput("Private Nachricht überschreitet das Protokoll-Limit."))); return
        }
        var fields = [LegacyTLV(type: 1, value: LegacyWire.uint32BE(userID)), LegacyTLV(type: 2, value: message)]
        if !secondaryPayload.isEmpty { fields.append(LegacyTLV(type: 3, value: secondaryPayload)) }
        sendOneWay(command: LegacyCommand.privateMessage, fields: fields, completion: completion)
    }

    func sendOfflineCapableMessage(toLogin login: Data, message: Data,
                                   completion: @escaping (Result<Void, Error>) -> Void) {
        guard !login.isEmpty, login.count <= 63, !message.isEmpty, message.count <= LegacyOfflineMessage.maximumMessageLength else {
            completion(.failure(LegacyControlClientError.invalidInput("Offline messages are limited to 4096 bytes.")))
            return
        }
        sendTaskCompleteRequest(command: LegacyCommand.offlineMessageSend,
                                fields: [LegacyTLV(type: 1, value: login), LegacyTLV(type: 2, value: message)],
                                completion: completion)
    }

    func requestOfflineMessageRecipients(completion: @escaping (Result<[LegacyOfflineMessageRecipient], Error>) -> Void) {
        sendRequest(command: LegacyCommand.offlineMessageRecipients, fields: []) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.offlineMessageRecipients else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.offlineMessageRecipients, actual: packet.command)
                }
                completion(.success(try packet.fields.filter { $0.type == 1 }.map { try LegacyOfflineMessageRecipient.decode($0.value) }))
            } catch { completion(.failure(error)) }
        }
    }

    func setOfflineMessagePreference(enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        sendTaskCompleteRequest(command: LegacyCommand.offlineMessagePreference,
                                fields: [LegacyTLV(type: 1, value: Data([enabled ? 1 : 0]))],
                                completion: completion)
    }

    func requestOfflineMessages(completion: @escaping (Result<[LegacyOfflineMessage], Error>) -> Void) {
        sendRequest(command: LegacyCommand.offlineMessageFetch, fields: []) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.offlineMessageFetch else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.offlineMessageFetch, actual: packet.command)
                }
                let messages = try packet.fields.filter { $0.type == 1 }.map { try LegacyOfflineMessage.decode($0.value) }
                completion(.success(messages))
            } catch { completion(.failure(error)) }
        }
    }

    func acknowledgeOfflineMessages(ids: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        let fields = ids.compactMap { id -> LegacyTLV? in
            guard let data = id.data(using: .utf8), !data.isEmpty, data.count <= 64 else { return nil }
            return LegacyTLV(type: 1, value: data)
        }
        guard fields.count == ids.count, !fields.isEmpty else {
            completion(.failure(LegacyControlClientError.invalidInput("Invalid offline-message id.")))
            return
        }
        sendTaskCompleteRequest(command: LegacyCommand.offlineMessageAcknowledge, fields: fields, completion: completion)
    }

    func setPresence(sleeping: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let userID = transferSession?.userID else {
            completion(.failure(LegacyControlClientError.connectionClosed)); return
        }
        sendOneWay(command: LegacyCommand.userPresenceState, fields: [
            LegacyTLV(type: LegacyPresenceStateField.userID, value: LegacyWire.uint32BE(userID)),
            LegacyTLV(type: LegacyPresenceStateField.state,
                      value: Data([sleeping ? LegacyPresenceState.sleeping : LegacyPresenceState.awake])),
        ], completion: completion)
    }

    func updateUser(nickname: Data, picture: Data = Data(), statusMessage: Data? = nil,
                    completion: @escaping (Result<Void, Error>) -> Void) {
        guard !nickname.isEmpty, nickname.count <= 64, picture.count <= LegacyUserInfoField.maximumPictureLength,
              statusMessage.map({ $0.count <= 255 }) ?? true else {
            completion(.failure(LegacyControlClientError.invalidInput("Nickname/Picture/Status überschreitet das User-Update-Limit."))); return
        }
        currentNickname = nickname
        var fields = [LegacyTLV(type: 2, value: nickname), LegacyTLV(type: 5, value: picture)]
        if let statusMessage { fields.append(LegacyTLV(type: LegacyUserInfoField.statusMessage, value: statusMessage)) }
        sendOneWay(command: LegacyCommand.userUpdate, fields: fields, completion: completion)
    }

    func updateNickname(_ nickname: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !nickname.isEmpty, nickname.count <= 64 else {
            completion(.failure(LegacyControlClientError.invalidInput("Nickname überschreitet das User-Update-Limit."))); return
        }
        currentNickname = nickname
        sendOneWay(command: LegacyCommand.userUpdate, fields: [
            LegacyTLV(type: 2, value: nickname),
        ], completion: completion)
    }

    func updateStatusMessage(_ statusMessage: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        guard statusMessage.count <= 255 else {
            completion(.failure(LegacyControlClientError.invalidInput("Status überschreitet das User-Update-Limit."))); return
        }
        guard let nickname = currentNickname, !nickname.isEmpty else {
            completion(.failure(LegacyControlClientError.connectionClosed)); return
        }
        sendOneWay(command: LegacyCommand.userUpdate, fields: [
            LegacyTLV(type: 2, value: nickname),
            LegacyTLV(type: LegacyUserInfoField.statusMessage, value: statusMessage),
        ], completion: completion)
    }

    func updateOwnUserInfo(name: Data, email: Data, aboutMe: Data,
                           completion: @escaping (Result<Void, Error>) -> Void) {
        guard name.count <= 64, email.count <= 64, aboutMe.count <= 128 else {
            completion(.failure(LegacyControlClientError.invalidInput("Profilfelder überschreiten das Classic-Limit."))); return
        }
        sendTaskCompleteRequest(command: LegacyCommand.extendedOwnUserInfo, fields: [
            LegacyTLV(type: LegacyUserInfoField.name, value: name),
            LegacyTLV(type: LegacyUserInfoField.email, value: email),
            LegacyTLV(type: LegacyUserInfoField.aboutMe, value: aboutMe),
        ], completion: completion)
    }

    func requestUserInfo(userID: UInt32,
                         completion: @escaping (Result<LegacyUserInfoReply, Error>) -> Void) {
        sendRequest(command: LegacyCommand.userInfo,
                    fields: [LegacyTLV(type: 1, value: LegacyWire.uint32BE(userID))]) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.userInfo else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.userInfo, actual: packet.command)
                }
                func clientMetadataString(_ type: UInt32) -> String? {
                    guard let value = packet.firstField(type: type)?.value,
                          !value.isEmpty, value.count <= LegacyClientMetadataField.maximumLength,
                          let string = String(data: value, encoding: .utf8), !string.isEmpty else { return nil }
                    return string
                }
                let reply = LegacyUserInfoReply(
                    userID: userID,
                    nickname: packet.firstField(type: LegacyUserInfoField.nickname)?.value ?? Data(),
                    name: packet.firstField(type: LegacyUserInfoField.name)?.value ?? Data(),
                    email: packet.firstField(type: LegacyUserInfoField.email)?.value ?? Data(),
                    aboutMe: packet.firstField(type: LegacyUserInfoField.aboutMe)?.value ?? Data(),
                    picture: packet.firstField(type: LegacyUserInfoField.picture)?.value ?? Data(),
                    ipAddress: try packet.firstField(type: LegacyUserInfoField.ipAddress)?.uint32BE(),
                    loginTime: try packet.firstField(type: LegacyUserInfoField.loginTime)?.uint32BE(),
                    idleTime: try packet.firstField(type: LegacyUserInfoField.idleTime)?.uint32BE(),
                    statusMessage: packet.firstField(type: LegacyUserInfoField.statusMessage)?.value ?? Data(),
                    groupColorRGB: try packet.firstField(type: LegacyUserInfoField.groupColorRGB)?.uint32BE(),
                    loginName: packet.firstField(type: LegacyUserInfoField.loginName)?.value,
                    taskList: packet.firstField(type: LegacyUserInfoField.taskList)?.value,
                    operatingSystem: clientMetadataString(LegacyClientMetadataField.operatingSystem),
                    cpuArchitecture: clientMetadataString(LegacyClientMetadataField.cpuArchitecture),
                    clientVersion: clientMetadataString(LegacyClientMetadataField.clientVersion),
                    clientBuild: clientMetadataString(LegacyClientMetadataField.clientBuild)
                )
                completion(.success(reply))
            } catch { completion(.failure(error)) }
        }
    }

    /// Classic command 0x04: disconnect the selected user's current session without
    /// changing the server's admission policy. This is the traditional Carracho "Kick".
    func kickUser(userID: UInt32, completion: @escaping (Result<Void, Error>) -> Void) {
        sendTaskCompleteRequest(command: LegacyCommand.disconnectUser,
                                fields: [LegacyTLV(type: 1, value: LegacyWire.uint32BE(userID))], completion: completion)
    }

    /// Compatibility alias for older call sites/tests that used the protocol command name.
    func disconnectUser(userID: UInt32, completion: @escaping (Result<Void, Error>) -> Void) {
        kickUser(userID: userID, completion: completion)
    }

    /// Classic command 0x05: persistently deny the target's IPv4 host and disconnect
    /// the current session. Reconnection remains blocked until the deny rule is removed.
    func banUser(userID: UInt32, completion: @escaping (Result<Void, Error>) -> Void) {
        sendTaskCompleteRequest(command: LegacyCommand.banUser,
                                fields: [LegacyTLV(type: 1, value: LegacyWire.uint32BE(userID))], completion: completion)
    }

    // MARK: - File control

    func createFolder(parentPath: Data, name: Data, flags: UInt16 = 0,
                      completion: @escaping (Result<Void, Error>) -> Void) {
        guard parentPath.count <= LegacyPath.maximumWireLength,
              !name.isEmpty, name.count <= 0xfa, !name.contains(LegacyPath.separator) else {
            completion(.failure(LegacyControlClientError.invalidInput("Ungültiger Ordnername oder Pfad."))); return
        }
        var fields: [LegacyTLV] = []
        if !parentPath.isEmpty { fields.append(LegacyTLV(type: 1, value: parentPath)) }
        fields.append(LegacyTLV(type: 2, value: LegacyWire.uint16BE(flags)))
        fields.append(LegacyTLV(type: 3, value: name))
        sendTaskCompleteRequest(command: LegacyCommand.createFolder, fields: fields, completion: completion)
    }

    func deleteFile(path: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !path.isEmpty, path.count <= LegacyPath.maximumWireLength else {
            completion(.failure(LegacyControlClientError.invalidInput("Ungültiger Dateipfad."))); return
        }
        sendTaskCompleteRequest(command: LegacyCommand.deleteFile,
                                fields: [LegacyTLV(type: 1, value: path)], completion: completion)
    }

    func requestFileInfo(path: Data, completion: @escaping (Result<LegacyFileInfoReply, Error>) -> Void) {
        guard !path.isEmpty, path.count <= LegacyPath.maximumWireLength else {
            completion(.failure(LegacyControlClientError.invalidInput("Ungültiger Dateipfad."))); return
        }
        sendRequest(command: LegacyCommand.fileInfo, fields: [LegacyTLV(type: 1, value: path)]) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.moveFile else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.moveFile, actual: packet.command)
                }
                guard let pathField = packet.firstField(type: 1),
                      let nameField = packet.firstField(type: 2),
                      let metadataField = packet.firstField(type: 3) else {
                    throw LegacyControlClientError.protocolFailure("unvollständige File-Info-Antwort")
                }
                let label: LegacyFileLabel
                if let labelData = packet.firstField(type: LegacyFileLabelField.fileInfo)?.value {
                    label = try LegacyFileLabel.decode(labelData)
                } else {
                    label = .none
                }
                completion(.success(LegacyFileInfoReply(path: pathField.value,
                                                        name: nameField.value,
                                                        metadata: try LegacyFileInfoMetadata.decode(metadataField.value),
                                                        comment: packet.firstField(type: 4)?.value ?? Data(),
                                                        label: label)))
            } catch { completion(.failure(error)) }
        }
    }

    func setFileInfo(path: Data, name: Data, flags: UInt16, comment: Data,
                     label: LegacyFileLabel? = nil,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        guard !path.isEmpty, path.count <= LegacyPath.maximumWireLength,
              !name.isEmpty, name.count <= 0x200, !name.contains(LegacyPath.separator),
              comment.count <= 0xff else {
            completion(.failure(LegacyControlClientError.invalidInput("Ungültige Datei-Metadaten."))); return
        }
        if label != nil, transferSession?.usesModernCrypto != true {
            completion(.failure(LegacyControlClientError.invalidInput("Datei-Labels werden nur von modernen Carracho-Servern unterstützt.")))
            return
        }
        var fields = [
            LegacyTLV(type: 1, value: path), LegacyTLV(type: 2, value: name),
            LegacyTLV(type: 3, value: LegacyWire.uint16BE(flags)), LegacyTLV(type: 4, value: comment),
        ]
        if let label { fields.append(LegacyTLV(type: LegacyFileLabelField.fileInfo, value: label.encoded)) }
        sendTaskCompleteRequest(command: LegacyCommand.setFileInfo, fields: fields, completion: completion)
    }

    func setFileLabel(path: Data, label: LegacyFileLabel,
                      completion: @escaping (Result<Void, Error>) -> Void) {
        guard transferSession?.usesModernCrypto == true else {
            completion(.failure(LegacyControlClientError.invalidInput("Datei-Labels werden nur von modernen Carracho-Servern unterstützt.")))
            return
        }
        guard !path.isEmpty, path.count <= LegacyPath.maximumWireLength else {
            completion(.failure(LegacyControlClientError.invalidInput("Ungültiger Dateipfad."))); return
        }
        sendTaskCompleteRequest(command: LegacyCommand.fileLabelSet, fields: [
            LegacyTLV(type: 1, value: path),
            LegacyTLV(type: LegacyFileLabelField.fileInfo, value: label.encoded),
        ], completion: completion)
    }

    func moveFile(sourcePath: Data, destinationPath: Data,
                  completion: @escaping (Result<Void, Error>) -> Void) {
        guard !sourcePath.isEmpty, sourcePath.count <= LegacyPath.maximumWireLength,
              !destinationPath.isEmpty, destinationPath.count <= LegacyPath.maximumWireLength else {
            completion(.failure(LegacyControlClientError.invalidInput("Ungültiger Quell- oder Zielpfad."))); return
        }
        sendTaskCompleteRequest(command: LegacyCommand.moveFile, fields: [
            LegacyTLV(type: 1, value: sourcePath), LegacyTLV(type: 2, value: destinationPath),
        ], completion: completion)
    }

    func emptyServerTrash(completion: @escaping (Result<Void, Error>) -> Void) {
        sendTaskCompleteRequest(command: LegacyCommand.emptyTrash, fields: [], completion: completion)
    }

    /// Classic Carracho uses control command 0x40 for Advanced → Rebuild Index.
    /// Normal searches do not need a control preflight; they go straight to transfer operation 9.
    func rebuildServerSearchIndex(completion: @escaping (Result<Void, Error>) -> Void) {
        sendTaskCompleteRequest(command: LegacyCommand.rebuildSearchIndex, fields: [], completion: completion)
    }

    /// Changes the password of the account authenticated on this control session.
    /// The command never names an account on the wire; the server derives it from
    /// the authenticated session so it cannot be used to modify somebody else.
    func changeOwnPassword(to password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let passwordData = password.data(using: .macOSRoman), passwordData.count <= 64 else {
            completion(.failure(LegacyControlClientError.invalidInput("Das Passwort muss in MacRoman darstellbar und höchstens 64 Byte lang sein.")))
            return
        }
        sendTaskCompleteRequest(command: LegacyCommand.changeOwnPassword,
                                fields: [LegacyTLV(type: 1, value: passwordData)],
                                completion: completion)
    }

    // MARK: - Classic remote administration

    func requestAccountList(completion: @escaping (Result<[LegacyCompactAccountSummary], Error>) -> Void) {
        sendRequest(command: LegacyCommand.accountList, fields: []) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.accountList else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.accountList, actual: packet.command)
                }
                guard let field = packet.firstField(type: 0x10) else { throw LegacyControlClientError.missingField(0x10) }
                completion(.success(try LegacyPackedRecords.decodeCompactAccountList(field.value)))
            } catch { completion(.failure(error)) }
        }
    }

    func requestAccountDetails(login: Data,
                               completion: @escaping (Result<LegacyAccountDetails, Error>) -> Void) {
        guard !login.isEmpty, login.count <= 31 else {
            completion(.failure(LegacyControlClientError.invalidInput("Der Accountname muss 1 bis 31 Byte lang sein."))); return
        }
        sendRequest(command: LegacyCommand.getAccount, fields: [LegacyTLV(type: 2, value: login)]) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.accountReply else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.accountReply, actual: packet.command)
                }
                guard let field = packet.firstField(type: 1) else { throw LegacyControlClientError.missingField(1) }
                let groupID: UUID?
                if let raw = packet.firstField(type: LegacyAccountField.groupID)?.value {
                    guard let text = String(data: raw, encoding: .utf8), let id = UUID(uuidString: text) else {
                        throw LegacyControlClientError.protocolFailure("ungültige Account-Gruppen-ID")
                    }
                    groupID = id
                } else { groupID = nil }
                let colorRGB: UInt32?
                if let colorField = packet.firstField(type: LegacyAccountField.colorRGB) {
                    let color = try colorField.uint32BE()
                    guard color <= 0x00ff_ffff else {
                        throw LegacyControlClientError.protocolFailure("ungültige Account-Farbe")
                    }
                    colorRGB = color
                } else { colorRGB = nil }
                let picture = packet.firstField(type: LegacyAccountField.picture)?.value
                if let picture, picture.count > LegacyUserInfoField.maximumPictureLength {
                    throw LegacyControlClientError.protocolFailure("Account-Avatar ist zu groß")
                }
                let localLoginOnly: Bool
                if let localField = packet.firstField(type: LegacyAccountField.localLoginOnly) {
                    guard localField.value.count == 1, let flag = localField.value.first, flag <= 1 else {
                        throw LegacyControlClientError.protocolFailure("ungültiger Local-only-Account-Status")
                    }
                    localLoginOnly = flag == 1
                } else { localLoginOnly = false }
                completion(.success(LegacyAccountDetails(record: try LegacyAccountRecord.decode(field.value),
                                                         groupID: groupID, colorRGB: colorRGB,
                                                         picture: picture, localLoginOnly: localLoginOnly)))
            } catch { completion(.failure(error)) }
        }
    }

    func requestAccount(login: Data, completion: @escaping (Result<LegacyAccountRecord, Error>) -> Void) {
        requestAccountDetails(login: login) { result in completion(result.map(\.record)) }
    }

    func saveAccount(_ record: LegacyAccountRecord,
                     oldLogin: Data? = nil, groupID: UUID? = nil, colorRGB: UInt32? = nil,
                     picture: Data? = nil,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            var fields = [LegacyTLV(type: 1, value: try record.encoded())]
            if let oldLogin, !oldLogin.isEmpty {
                guard oldLogin.count <= 63 else { throw LegacyControlClientError.invalidInput("Der alte Accountname ist zu lang.") }
                fields.append(LegacyTLV(type: 3, value: oldLogin))
            }
            if let groupID { fields.append(LegacyTLV(type: LegacyAccountField.groupID, value: Data(groupID.uuidString.utf8))) }
            if let colorRGB {
                guard colorRGB <= 0x00ff_ffff else {
                    throw LegacyControlClientError.invalidInput("Account-Farbe muss ein 24-Bit-RGB-Wert sein.")
                }
                fields.append(LegacyTLV(type: LegacyAccountField.colorRGB, value: LegacyWire.uint32BE(colorRGB)))
            }
            if let picture {
                guard picture.count <= LegacyUserInfoField.maximumPictureLength else {
                    throw LegacyControlClientError.invalidInput("Account-Avatar überschreitet das Protokolllimit.")
                }
                fields.append(LegacyTLV(type: LegacyAccountField.picture, value: picture))
            }
            sendTaskCompleteRequest(command: LegacyCommand.accountCreateOrModify, fields: fields, completion: completion)
        } catch { completion(.failure(error)) }
    }

    func requestAccountGroups(completion: @escaping (Result<[LegacyAccountGroupRecord], Error>) -> Void) {
        requestServerSettings(fields: [LegacyServerSettingField.accountGroups]) { result in
            do {
                let fields = try result.get()
                guard let value = fields[LegacyServerSettingField.accountGroups] else {
                    throw LegacyControlClientError.missingField(LegacyServerSettingField.accountGroups)
                }
                completion(.success(try LegacyServerSettingField.decodeAccountGroups(value)))
            } catch { completion(.failure(error)) }
        }
    }

    func setAccountGroups(_ groups: [LegacyAccountGroupRecord], completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let value = try LegacyServerSettingField.encodeAccountGroups(groups)
            setServerSettings([LegacyTLV(type: LegacyServerSettingField.accountGroups, value: value)], completion: completion)
        } catch { completion(.failure(error)) }
    }

    func deleteAccount(login: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !login.isEmpty, login.count <= 31 else {
            completion(.failure(LegacyControlClientError.invalidInput("Der Accountname muss 1 bis 31 Byte lang sein."))); return
        }
        sendTaskCompleteRequest(command: LegacyCommand.accountDelete,
                                fields: [LegacyTLV(type: 2, value: login)], completion: completion)
    }

    func requestAdminNewsgroups(completion: @escaping (Result<[LegacyAdminNewsgroup], Error>) -> Void) {
        sendRequest(command: LegacyCommand.adminNewsgroupList, fields: []) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.adminNewsgroupListReply else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.adminNewsgroupListReply, actual: packet.command)
                }
                guard let field = packet.firstField(type: 2) else { throw LegacyControlClientError.missingField(2) }
                completion(.success(try LegacyPackedRecords.decodeAdminNewsgroupList(field.value)))
            } catch { completion(.failure(error)) }
        }
    }

    func createNewsgroup(name: Data, expireAfterSeconds: UInt32, flags: UInt16,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        guard !name.isEmpty, name.count <= LegacyNewsTransfer.maximumGroupNameLength else {
            completion(.failure(LegacyControlClientError.invalidInput("Der Newsgroup-Name muss 1 bis 64 Byte lang sein."))); return
        }
        sendTaskCompleteRequest(command: LegacyCommand.newsgroupCreate, fields: [
            LegacyTLV(type: 1, value: name), LegacyTLV(type: 2, value: LegacyWire.uint32BE(expireAfterSeconds)),
            LegacyTLV(type: 3, value: LegacyWire.uint16BE(flags)),
        ], completion: completion)
    }

    func modifyNewsgroup(oldName: Data, newName: Data, expireAfterSeconds: UInt32, flags: UInt16,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        guard !oldName.isEmpty, oldName.count <= LegacyNewsTransfer.maximumGroupNameLength,
              !newName.isEmpty, newName.count <= LegacyNewsTransfer.maximumGroupNameLength else {
            completion(.failure(LegacyControlClientError.invalidInput("Der Newsgroup-Name muss 1 bis 64 Byte lang sein."))); return
        }
        sendTaskCompleteRequest(command: LegacyCommand.newsgroupModify, fields: [
            LegacyTLV(type: 1, value: newName), LegacyTLV(type: 2, value: LegacyWire.uint32BE(expireAfterSeconds)),
            LegacyTLV(type: 3, value: LegacyWire.uint16BE(flags)), LegacyTLV(type: 4, value: oldName),
        ], completion: completion)
    }

    func deleteNewsgroup(name: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !name.isEmpty, name.count <= LegacyNewsTransfer.maximumGroupNameLength else {
            completion(.failure(LegacyControlClientError.invalidInput("Der Newsgroup-Name muss 1 bis 64 Byte lang sein."))); return
        }
        sendTaskCompleteRequest(command: LegacyCommand.newsgroupDelete,
                                fields: [LegacyTLV(type: 1, value: name)], completion: completion)
    }

    func requestServerLog(completion: @escaping (Result<String, Error>) -> Void) {
        let chunkSize: UInt32 = 60 * 1024
        let maximumSnapshotBytes: UInt64 = 8 * 1024 * 1024
        var targetEnd: UInt64?
        var nextOffset: UInt64 = 0
        var firstDisplayedOffset: UInt64 = 0
        var payload = Data()

        func fetch() {
            let fields = [
                LegacyTLV(type: 1, value: LegacyWire.uint64BE(nextOffset)),
                LegacyTLV(type: 2, value: LegacyWire.uint32BE(chunkSize)),
            ]
            sendRequest(command: LegacyCommand.serverLogRequest, fields: fields) { result in
                do {
                    let packet = try result.get()
                    guard packet.command == LegacyCommand.serverLogReply else {
                        throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.serverLogReply,
                                                                         actual: packet.command)
                    }
                    guard let totalField = packet.firstField(type: 1), totalField.value.count == 8,
                          let offsetField = packet.firstField(type: 2), offsetField.value.count == 8,
                          let dataField = packet.firstField(type: 3) else {
                        throw LegacyControlClientError.protocolFailure("unvollständige Server-Log-Antwort")
                    }
                    var totalCursor = LegacyByteCursor(totalField.value)
                    let total = try totalCursor.readUInt64BE()
                    try totalCursor.requireEnd()
                    var offsetCursor = LegacyByteCursor(offsetField.value)
                    let returnedOffset = try offsetCursor.readUInt64BE()
                    try offsetCursor.requireEnd()

                    if targetEnd == nil {
                        targetEnd = total
                        if total > maximumSnapshotBytes && nextOffset == 0 {
                            firstDisplayedOffset = total - maximumSnapshotBytes
                            nextOffset = firstDisplayedOffset
                            payload.removeAll(keepingCapacity: true)
                            fetch()
                            return
                        }
                    }
                    guard returnedOffset == nextOffset, let targetEnd else {
                        throw LegacyControlClientError.protocolFailure("Server-Log-Antwort hat einen unerwarteten Offset")
                    }
                    if nextOffset > targetEnd {
                        throw LegacyControlClientError.protocolFailure("Server-Log wurde während des Lesens verkürzt")
                    }
                    let remaining = targetEnd - nextOffset
                    let acceptedCount = min(dataField.value.count, Int(min(remaining, UInt64(Int.max))))
                    if acceptedCount > 0 { payload.append(dataField.value.prefix(acceptedCount)) }
                    nextOffset += UInt64(acceptedCount)

                    if nextOffset < targetEnd {
                        guard acceptedCount > 0 else {
                            throw LegacyControlClientError.protocolFailure("Server-Log-Antwort endete vorzeitig")
                        }
                        fetch()
                        return
                    }

                    var text = String(decoding: payload, as: UTF8.self)
                    if firstDisplayedOffset > 0 {
                        let notice = "[Showing the last 8 MiB of the server log; earlier bytes were omitted.]\n"
                        text = notice + text
                    }
                    completion(.success(text))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        fetch()
    }

    func clearServerLog(completion: @escaping (Result<Void, Error>) -> Void) {
        sendTaskCompleteRequest(command: LegacyCommand.serverLogClear, fields: [], completion: completion)
    }

    func requestEventLog(completion: @escaping (Result<String, Error>) -> Void) {
        let chunkSize: UInt32 = 60 * 1024
        let maximumSnapshotBytes: UInt64 = 8 * 1024 * 1024
        var targetEnd: UInt64?
        var nextOffset: UInt64 = 0
        var firstDisplayedOffset: UInt64 = 0
        var payload = Data()

        func fetch() {
            let fields = [
                LegacyTLV(type: 1, value: LegacyWire.uint64BE(nextOffset)),
                LegacyTLV(type: 2, value: LegacyWire.uint32BE(chunkSize)),
            ]
            sendRequest(command: LegacyCommand.eventLogRequest, fields: fields) { result in
                do {
                    let packet = try result.get()
                    guard packet.command == LegacyCommand.eventLogReply else {
                        throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.eventLogReply,
                                                                         actual: packet.command)
                    }
                    guard let totalField = packet.firstField(type: 1), totalField.value.count == 8,
                          let offsetField = packet.firstField(type: 2), offsetField.value.count == 8,
                          let dataField = packet.firstField(type: 3) else {
                        throw LegacyControlClientError.protocolFailure("unvollständige Event-Log-Antwort")
                    }
                    var totalCursor = LegacyByteCursor(totalField.value)
                    let total = try totalCursor.readUInt64BE()
                    try totalCursor.requireEnd()
                    var offsetCursor = LegacyByteCursor(offsetField.value)
                    let returnedOffset = try offsetCursor.readUInt64BE()
                    try offsetCursor.requireEnd()
                    if targetEnd == nil {
                        targetEnd = total
                        if total > maximumSnapshotBytes && nextOffset == 0 {
                            firstDisplayedOffset = total - maximumSnapshotBytes
                            nextOffset = firstDisplayedOffset
                            payload.removeAll(keepingCapacity: true)
                            fetch()
                            return
                        }
                    }
                    guard returnedOffset == nextOffset, let targetEnd else {
                        throw LegacyControlClientError.protocolFailure("Event-Log-Antwort hat einen unerwarteten Offset")
                    }
                    if nextOffset > targetEnd {
                        throw LegacyControlClientError.protocolFailure("Event-Log wurde während des Lesens verkürzt")
                    }
                    let remaining = targetEnd - nextOffset
                    let acceptedCount = min(dataField.value.count, Int(min(remaining, UInt64(Int.max))))
                    if acceptedCount > 0 { payload.append(dataField.value.prefix(acceptedCount)) }
                    nextOffset += UInt64(acceptedCount)
                    if nextOffset < targetEnd {
                        guard acceptedCount > 0 else {
                            throw LegacyControlClientError.protocolFailure("Event-Log-Antwort endete vorzeitig")
                        }
                        fetch()
                        return
                    }
                    var text = String(decoding: payload, as: UTF8.self)
                    if firstDisplayedOffset > 0 {
                        text = "[Showing the last 8 MiB of the event log; earlier bytes were omitted.]\n" + text
                    }
                    completion(.success(text))
                } catch { completion(.failure(error)) }
            }
        }
        fetch()
    }

    func clearEventLog(completion: @escaping (Result<Void, Error>) -> Void) {
        sendTaskCompleteRequest(command: LegacyCommand.eventLogClear, fields: [], completion: completion)
    }

    func requestBotAdministrationStatus(completion: @escaping (Result<LegacyBotAdminStatus, Error>) -> Void) {
        sendRequest(command: LegacyCommand.botStatusRequest, fields: []) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.botStatusReply else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.botStatusReply, actual: packet.command)
                }
                func flag(_ type: UInt32) throws -> Bool {
                    guard let field = packet.firstField(type: type), field.value.count == 1,
                          let value = field.value.first, value <= 1 else {
                        throw LegacyControlClientError.protocolFailure("ungültiger Bot-Status")
                    }
                    return value == 1
                }
                func text(_ type: UInt32) throws -> String {
                    guard let field = packet.firstField(type: type),
                          let value = String(data: field.value, encoding: .utf8) else {
                        throw LegacyControlClientError.protocolFailure("ungültiger Bot-Text")
                    }
                    return value
                }
                let error: String?
                if let field = packet.firstField(type: LegacyBotAdminField.lastError) {
                    guard let value = String(data: field.value, encoding: .utf8) else {
                        throw LegacyControlClientError.protocolFailure("ungültiger Bot-Fehlertext")
                    }
                    error = value.isEmpty ? nil : value
                } else { error = nil }
                let greetingEnabledField = packet.firstField(type: LegacyBotAdminField.greetNewUsers)
                let greetingTemplateField = packet.firstField(type: LegacyBotAdminField.greetingTemplate)
                let greetingSupported = greetingEnabledField != nil && greetingTemplateField != nil
                var greetNewUsers = false
                var greetingTemplate = LegacyBotAdminStatus.defaultGreetingTemplate
                if greetingSupported {
                    guard let greetingEnabledField, greetingEnabledField.value.count == 1,
                          let raw = greetingEnabledField.value.first, raw <= 1,
                          let greetingTemplateField,
                          let decoded = String(data: greetingTemplateField.value, encoding: .utf8),
                          !decoded.isEmpty else {
                        throw LegacyControlClientError.protocolFailure("ungültige Bot-Begrüßung")
                    }
                    greetNewUsers = raw == 1
                    greetingTemplate = decoded
                }
                completion(.success(LegacyBotAdminStatus(
                    desiredEnabled: try flag(LegacyBotAdminField.desiredEnabled),
                    connected: try flag(LegacyBotAdminField.connected),
                    login: try text(LegacyBotAdminField.login),
                    name: try text(LegacyBotAdminField.name),
                    lastError: error,
                    greetingSupported: greetingSupported,
                    greetNewUsers: greetNewUsers,
                    greetingTemplate: greetingTemplate)))
            } catch { completion(.failure(error)) }
        }
    }

    func setBotAdministrationEnabled(_ enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        sendTaskCompleteRequest(command: LegacyCommand.botSetEnabled,
                                fields: [LegacyTLV(type: LegacyBotAdminField.desiredEnabled,
                                                   value: Data([enabled ? 1 : 0]))],
                                completion: completion)
    }

    func setBotAdministrationGreeting(enabled: Bool, template: String,
                                      completion: @escaping (Result<Void, Error>) -> Void) {
        let normalized = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.contains("\n"), !normalized.contains("\r"),
              normalized.utf8.count <= 512 else {
            completion(.failure(LegacyControlClientError.protocolFailure("ungültige Bot-Begrüßung")))
            return
        }
        sendTaskCompleteRequest(command: LegacyCommand.botSetGreeting, fields: [
            LegacyTLV(type: LegacyBotAdminField.greetNewUsers, value: Data([enabled ? 1 : 0])),
            LegacyTLV(type: LegacyBotAdminField.greetingTemplate, value: Data(normalized.utf8)),
        ], completion: completion)
    }

    func requestServerSettings(fields: [UInt32],
                               completion: @escaping (Result<[UInt32: Data], Error>) -> Void) {
        let requestFields = fields.map { LegacyTLV(type: $0, value: Data()) }
        sendRequest(command: LegacyCommand.requestServerSettings, fields: requestFields) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.serverSettingsReply else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.serverSettingsReply, actual: packet.command)
                }
                var values: [UInt32: Data] = [:]
                for field in packet.fields { values[field.type] = field.value }
                completion(.success(values))
            } catch { completion(.failure(error)) }
        }
    }

    func setServerSettings(_ fields: [LegacyTLV], completion: @escaping (Result<Void, Error>) -> Void) {
        sendTaskCompleteRequest(command: LegacyCommand.setServerSettings, fields: fields, completion: completion)
    }

    private func sendTaskCompleteRequest(command: UInt32, fields: [LegacyTLV],
                                         completion: @escaping (Result<Void, Error>) -> Void) {
        sendRequest(command: command, fields: fields) { result in
            do {
                let packet = try result.get()
                guard packet.command == LegacyCommand.taskComplete else {
                    throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.taskComplete, actual: packet.command)
                }
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }

    private func sendOneWay(command: UInt32,
                            fields: [LegacyTLV],
                            completion: @escaping (Result<Void, Error>) -> Void) {
        guard let key = sessionKey, connection != nil, isConnected else {
            completion(.failure(LegacyControlClientError.connectionClosed))
            return
        }
        do {
            let packet = LegacyPacket(command: command, transactionID: 0, fields: fields)
            let frame: Data
            if let modernControlChannel { frame = try modernControlChannel.seal(packet.plaintext()) }
            else { frame = try LegacyControlCodec.encode(packet, key: key) }
            sendRaw(frame) { error in
                if let error { completion(.failure(error)) }
                else { completion(.success(())) }
            }
        } catch {
            completion(.failure(error))
        }
    }

    func sendRequest(command: UInt32,
                     fields: [LegacyTLV],
                     completion: @escaping (Result<LegacyPacket, Error>) -> Void) {
        guard let key = sessionKey, connection != nil, isConnected else {
            completion(.failure(LegacyControlClientError.connectionClosed))
            return
        }
        let transactionID = allocateTransactionID()
        let packet = LegacyPacket(command: command, transactionID: transactionID, fields: fields)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingRequests.removeValue(forKey: transactionID) else { return }
            pending.completion(.failure(LegacyControlClientError.timedOut(
                String(format: "Request 0x%08x", command)
            )))
        }
        pendingRequests[transactionID] = PendingRequest(completion: completion, timeoutWorkItem: timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestTimeout, execute: timeout)
        do {
            let frame: Data
            if let modernControlChannel {
                frame = try modernControlChannel.seal(packet.plaintext())
            } else {
                frame = try LegacyControlCodec.encode(packet, key: key)
            }
            sendRaw(frame) { [weak self] error in
                guard let self, let error else { return }
                guard let pending = self.pendingRequests.removeValue(forKey: transactionID) else { return }
                pending.timeoutWorkItem.cancel()
                pending.completion(.failure(error))
            }
        } catch {
            if let pending = pendingRequests.removeValue(forKey: transactionID) {
                pending.timeoutWorkItem.cancel()
                pending.completion(.failure(error))
            }
        }
    }

    private struct Credentials {
        let login: Data
        let password: Data
        let nickname: Data
    }

    private func validateCredentials(login: String, password: String, nickname: String) throws -> Credentials {
        guard !login.isEmpty else {
            throw LegacyControlClientError.invalidInput("Bitte einen Login-Namen eingeben.")
        }
        guard let loginData = login.data(using: .macOSRoman), loginData.count <= 30 else {
            throw LegacyControlClientError.invalidInput("Der Login muss in MacRoman darstellbar und höchstens 30 Byte lang sein.")
        }
        guard let passwordData = password.data(using: .macOSRoman), passwordData.count <= 64 else {
            throw LegacyControlClientError.invalidInput("Das Passwort muss in MacRoman darstellbar und höchstens 64 Byte lang sein.")
        }
        let effectiveNickname = nickname.isEmpty ? login : nickname
        guard let nicknameData = effectiveNickname.data(using: .macOSRoman), nicknameData.count <= 64 else {
            throw LegacyControlClientError.invalidInput("Der Nickname muss in MacRoman darstellbar und höchstens 64 Byte lang sein.")
        }
        return Credentials(login: loginData, password: passwordData, nickname: nicknameData)
    }

    private func beginHandshake(credentials: Credentials) {
        guard case .connecting = state else { return }
        state = .handshaking
        let forceLegacyHello = allowLegacyCrypto
        let clientVersion: UInt16 = forceLegacyHello ? 1 : CarrachoModernCrypto.clientHelloVersion
        sendRaw(LegacyWire.clientHello(version: clientVersion)) { [weak self] error in
            guard let self else { return }
            if let error { self.fail(error); return }
            self.receiveExactly(LegacyWire.serverHello().count, timeout: Self.handshakeTimeout,
                                operation: "Server-Hello") { result in
                switch result {
                case let .failure(error):
                    self.fail(error)
                case let .success(hello):
                    if !forceLegacyHello,
                       hello == LegacyWire.serverHello(version: CarrachoModernCrypto.serverHelloVersion) {
                        self.negotiatedLegacyCrypto = false
                    } else if hello == LegacyWire.serverHello(version: 2) {
                        // Original Server 1.0b13 accepts the newer client hello value but always
                        // answers with its Classic server version 2. Treat that explicit reply as
                        // transport negotiation rather than rejecting the connection immediately.
                        self.negotiatedLegacyCrypto = true
                    } else {
                        self.fail(LegacyControlClientError.invalidServerHello)
                        return
                    }
                    self.receiveControlPacket(key: LegacyAuthentication.initialControlKey,
                                              timeout: Self.handshakeTimeout,
                                              operation: "Login-Challenge") { packetResult in
                        self.handleChallenge(packetResult, credentials: credentials)
                    }
                }
            }
        }
    }

    private func handleChallenge(_ result: Result<LegacyPacket, Error>, credentials: Credentials) {
        do {
            let challengePacket = try result.get()
            if challengePacket.command == LegacyCommand.error {
                throw try serverError(from: challengePacket)
            }
            guard challengePacket.command == LegacyCommand.challenge else {
                throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.challenge,
                                                                 actual: challengePacket.command)
            }
            guard let challengeField = challengePacket.firstField(type: 1), challengeField.value.count == 12 else {
                throw LegacyControlClientError.missingField(1)
            }

            let derivedKey = try LegacyAuthentication.deriveSessionKey(password: credentials.password,
                                                                       challenge: challengeField.value)
            let digest = LegacyMD5.hexDigestASCII(derivedKey)
            let ephemeral = negotiatedLegacyCrypto ? nil : CarrachoModernCrypto.makeEphemeralKeyPair()
            var loginFields = [
                LegacyTLV(type: 1, value: credentials.login),
                LegacyTLV(type: 2, value: digest),
                LegacyTLV(type: 4, value: credentials.nickname),
            ]
            if let ephemeral {
                loginFields.append(LegacyTLV(type: 5, value: ephemeral.publicKey))
                loginFields.append(contentsOf: Self.clientMetadataFields())
            }
            let loginPacket = LegacyPacket(command: LegacyCommand.login, transactionID: 0, fields: loginFields)
            state = .authenticating
            let frame = try LegacyControlCodec.encode(loginPacket, key: LegacyAuthentication.initialControlKey)
            sendRaw(frame) { [weak self] error in
                guard let self else { return }
                if let error { self.fail(error); return }
                self.receiveControlPacket(key: LegacyAuthentication.initialControlKey,
                                          timeout: Self.handshakeTimeout,
                                          operation: "Login-Antwort") { reply in
                    self.handleLoginReply(reply, derivedKey: derivedKey, challenge: challengeField.value, ephemeral: ephemeral)
                }
            }
        } catch {
            fail(error)
        }
    }

    private func handleLoginReply(_ result: Result<LegacyPacket, Error>, derivedKey: Data, challenge: Data,
                                  ephemeral: CarrachoModernCrypto.EphemeralKeyPair?) {
        do {
            let packet = try result.get()
            if packet.command == LegacyCommand.error {
                throw try serverError(from: packet)
            }
            guard packet.command == LegacyCommand.loginSuccess else {
                throw LegacyControlClientError.unexpectedCommand(expected: LegacyCommand.loginSuccess,
                                                                 actual: packet.command)
            }
            let loginResult = try parseLoginSuccess(packet)
            let modernSalt = packet.firstField(type: 6)?.value
            let transportKey: Data
            if negotiatedLegacyCrypto {
                transportKey = derivedKey
                sessionKey = derivedKey
                modernControlChannel = nil
            } else {
                guard loginResult.transferProtocolVersion == CarrachoModernCrypto.transferProtocolVersion,
                      let modernSalt, modernSalt.count == CarrachoModernCrypto.sessionSaltLength,
                      let serverPublicKey = packet.firstField(type: 7)?.value,
                      let authenticator = packet.firstField(type: 8)?.value,
                      let ephemeral else {
                    throw LegacyControlClientError.protocolFailure("server did not negotiate authenticated X25519 + AES-256-GCM transport")
                }
                try CarrachoModernCrypto.verifyHandshakeAuthenticator(authenticator, sessionKey: derivedKey,
                    challenge: challenge, clientPublicKey: ephemeral.publicKey,
                    serverPublicKey: serverPublicKey, sessionSalt: modernSalt)
                transportKey = try CarrachoModernCrypto.transportMaster(keyPair: ephemeral,
                    peerPublicKey: serverPublicKey, sessionKey: derivedKey, sessionSalt: modernSalt)
                sessionKey = transportKey
                let keys = try CarrachoModernCrypto.controlKeys(sessionKey: transportKey, salt: modernSalt, role: .client)
                modernControlChannel = try CarrachoAEADChannel(keys: keys, domain: "carracho/control/v1")
            }
            transferSession = LegacyTransferSession(userID: loginResult.session.userID, key: transportKey, modernSalt: modernSalt)
            state = .connected
            let completion = loginCompletion
            loginCompletion = nil
            completion?(.success(loginResult))
            receiveLoop()
        } catch {
            fail(error)
        }
    }

    private func parseLoginSuccess(_ packet: LegacyPacket) throws -> LegacyLoginResult {
        guard let sessionField = packet.firstField(type: 1) else {
            throw LegacyControlClientError.missingField(1)
        }
        let session = try LegacyLoginSessionInfo.decode(sessionField.value)
        let serverName = Self.macRomanString(packet.firstField(type: 2)?.value) ?? "Carracho Server"

        var users: [LegacyUserListEntry] = []
        if let usersField = packet.firstField(type: 3) {
            users = try LegacyPackedRecords.decodeUserList(usersField.value)
        }
        if let transportField = packet.firstField(type: LegacyUserTransportCapability.loginFieldType) {
            let legacyIDs = try LegacyUserTransportCapability.decodeLegacyUserIDs(transportField.value)
            for index in users.indices where legacyIDs.contains(users[index].userID) {
                users[index].isLegacyTransport = true
            }
        }

        var agreement: LegacyAgreementContent?
        if let agreementField = packet.firstField(type: 4) {
            agreement = try LegacyAgreementContent.decode(agreementField.value)
        }

        let maxTransfers = try packet.firstField(type: 0x21)?.uint16BE()
        let transferVersion = try packet.firstField(type: 5)?.uint16BE()
        let mediaCapabilities = try packet.firstField(type: LegacyMediaCapability.loginFieldType)?.uint32BE() ?? 0
        let filesRootName: String
        if let rootField = packet.firstField(type: LegacyFilesRootCapability.loginFieldType) {
            guard !rootField.value.isEmpty, rootField.value.count <= 64,
                  let decoded = String(data: rootField.value, encoding: .utf8) else {
                throw LegacyControlClientError.protocolFailure("server sent an invalid Files root name")
            }
            filesRootName = decoded
        } else {
            filesRootName = LegacyFilesRootCapability.defaultDisplayName
        }

        return LegacyLoginResult(session: session,
                                 serverName: serverName,
                                 users: users,
                                 agreement: agreement,
                                 maxFileTransfersPerUser: maxTransfers,
                                 transferProtocolVersion: transferVersion,
                                 mediaCapabilities: mediaCapabilities,
                                 filesRootName: filesRootName)
    }

    private func receiveLoop() {
        guard let key = sessionKey, connection != nil, isConnected else { return }
        receiveControlPacket(key: key, timeout: nil, operation: "Serverdaten") { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                self.fail(error)
            case let .success(packet):
                self.route(packet)
                if self.connection != nil, self.isConnected { self.receiveLoop() }
            }
        }
    }

    private func route(_ packet: LegacyPacket) {
        if packet.command == LegacyCommand.forceDisconnect {
            onAsyncPacket?(packet)
            onEvent?(.forcedDisconnect)
            expectedDisconnect = true
            disconnect()
            return
        }

        if packet.transactionID != 0,
           let pending = pendingRequests.removeValue(forKey: packet.transactionID) {
            pending.timeoutWorkItem.cancel()
            if packet.command == LegacyCommand.error {
                do { pending.completion(.failure(try serverError(from: packet))) }
                catch { pending.completion(.failure(error)) }
            } else {
                pending.completion(.success(packet))
            }
            return
        }

        onAsyncPacket?(packet)
        do {
            switch packet.command {
            case LegacyCommand.offlineMessageNotice:
                guard let count = packet.firstField(type: 1), count.value.count == 4 else {
                    throw LegacyControlClientError.protocolFailure("invalid offline-message notice")
                }
                onEvent?(.offlineMessagesAvailable(Int(try count.uint32BE())))
            case LegacyCommand.privateMessage:
                guard let sender = packet.firstField(type: 1), let message = packet.firstField(type: 2) else {
                    throw LegacyControlClientError.protocolFailure("unvollständige private Nachricht")
                }
                onEvent?(.privateMessage(LegacyPrivateMessage(senderUserID: try sender.uint32BE(),
                                                              message: message.value,
                                                              secondaryPayload: packet.firstField(type: 3)?.value ?? Data())))
            case LegacyCommand.broadcastMessage:
                guard let message = packet.firstField(type: 1), let sender = packet.firstField(type: 2) else {
                    throw LegacyControlClientError.protocolFailure("unvollständiger Broadcast")
                }
                onEvent?(.broadcastMessage(LegacyBroadcastMessage(senderUserID: try sender.uint32BE(), message: message.value)))
            case LegacyCommand.userUpdate:
                guard let idField = packet.firstField(type: 1), let nicknameField = packet.firstField(type: 2) else {
                    throw LegacyControlClientError.protocolFailure("unvollständiges User-Update-Event")
                }
                let userID = try idField.uint32BE()
                let status = packet.firstField(type: LegacyUserInfoField.statusMessage)?.value
                onEvent?(.userUpdated(userID: userID, nickname: nicknameField.value,
                                      picture: packet.firstField(type: LegacyUserInfoField.picture)?.value ?? Data(),
                                      statusMessage: status))
                if let colorField = packet.firstField(type: LegacyUserInfoField.groupColorRGB) {
                    onEvent?(.userGroupColor(userID: userID, colorRGB: try colorField.uint32BE()))
                }
                if userID == transferSession?.userID,
                   let permissionField = packet.firstField(type: LegacyUserInfoField.permissionWords) {
                    guard permissionField.value.count == 8 else {
                        throw LegacyControlClientError.protocolFailure("invalid own-permission update")
                    }
                    var cursor = LegacyByteCursor(permissionField.value)
                    let word0 = try cursor.readUInt32BE()
                    let word1 = try cursor.readUInt32BE()
                    try cursor.requireEnd()
                    onEvent?(.ownPermissionsChanged(permissionWord0: word0, permissionWord1: word1))
                }
            case LegacyCommand.userArrived:
                guard let idField = packet.firstField(type: 1),
                      let nickField = packet.firstField(type: 2),
                      let flagsField = packet.firstField(type: 3) else {
                    throw LegacyControlClientError.protocolFailure("unvollständiges User-Arrived-Event")
                }
                let transportMarker = packet.firstField(type: LegacyUserInfoField.legacyTransport)?.value
                if let transportMarker, transportMarker.count != 1 {
                    throw LegacyControlClientError.protocolFailure("invalid user transport marker")
                }
                let user = LegacyUserListEntry(nickname: nickField.value,
                                               flags: try flagsField.uint16BE(),
                                               userID: try idField.uint32BE(),
                                               picture: packet.firstField(type: LegacyUserInfoField.picture)?.value ?? Data(),
                                               isLegacyTransport: transportMarker?.first == 1)
                onEvent?(.userArrived(user))
                if let status = packet.firstField(type: LegacyUserInfoField.statusMessage)?.value {
                    onEvent?(.userStatus(userID: user.userID, statusMessage: status))
                }
                if let colorField = packet.firstField(type: LegacyUserInfoField.groupColorRGB) {
                    onEvent?(.userGroupColor(userID: user.userID, colorRGB: try colorField.uint32BE()))
                }
            case LegacyCommand.userDisconnected:
                guard let idField = packet.firstField(type: 1) else {
                    throw LegacyControlClientError.protocolFailure("unvollständiges User-Disconnected-Event")
                }
                onEvent?(.userDisconnected(try idField.uint32BE()))
            case LegacyCommand.channelUserJoined:
                guard let channelField = packet.firstField(type: LegacyChannelField.channelID),
                      let userField = packet.firstField(type: LegacyChannelField.userID),
                      let modeField = packet.firstField(type: LegacyChannelField.userMode),
                      modeField.value.count == 1, let mode = modeField.value.first else {
                    throw LegacyControlClientError.protocolFailure("unvollständiges Channel-Join-Event")
                }
                onEvent?(.channelUserJoined(channelID: try channelField.uint32BE(),
                                            userID: try userField.uint32BE(),
                                            mode: mode))
            case LegacyCommand.channelUserLeft:
                guard let channelField = packet.firstField(type: LegacyChannelField.channelID),
                      let userField = packet.firstField(type: LegacyChannelField.userID) else {
                    throw LegacyControlClientError.protocolFailure("unvollständiges Channel-Leave-Event")
                }
                onEvent?(.channelUserLeft(channelID: try channelField.uint32BE(),
                                          userID: try userField.uint32BE()))
            case LegacyCommand.channelUserMode:
                guard let channelField = packet.firstField(type: LegacyChannelField.channelID),
                      let userField = packet.firstField(type: LegacyChannelField.userID),
                      let modeField = packet.firstField(type: LegacyChannelField.userMode),
                      modeField.value.count == 1, let mode = modeField.value.first else {
                    throw LegacyControlClientError.protocolFailure("unvollständiges Channel-Mode-Event")
                }
                onEvent?(.channelUserMode(channelID: try channelField.uint32BE(),
                                          userID: try userField.uint32BE(), mode: mode))
            case LegacyCommand.channelInvite:
                guard let channelField = packet.firstField(type: LegacyChannelField.channelID),
                      let inviterField = packet.firstField(type: 0x0b),
                      let nameField = packet.firstField(type: LegacyChannelField.name) else {
                    throw LegacyControlClientError.protocolFailure("unvollständige Channel-Einladung")
                }
                onEvent?(.channelInvitation(LegacyChannelInvitation(channelID: try channelField.uint32BE(),
                                                                     inviterUserID: try inviterField.uint32BE(),
                                                                     name: nameField.value)))
            case LegacyCommand.channelDeclineInvitation:
                guard let channelField = packet.firstField(type: LegacyChannelField.channelID),
                      let userField = packet.firstField(type: LegacyChannelField.userID) else {
                    throw LegacyControlClientError.protocolFailure("unvollständige abgelehnte Channel-Einladung")
                }
                onEvent?(.channelInvitationDeclined(channelID: try channelField.uint32BE(),
                                                     userID: try userField.uint32BE()))
            case LegacyCommand.channelChat:
                guard let channelField = packet.firstField(type: LegacyChannelField.channelID),
                      let senderField = packet.firstField(type: LegacyChannelField.userID),
                      let messageField = packet.firstField(type: LegacyChannelField.message),
                      let attributeField = packet.firstField(type: LegacyChannelField.chatAttribute),
                      attributeField.value.count == 1, let attribute = attributeField.value.first else {
                    throw LegacyControlClientError.protocolFailure("unvollständiges Channel-Chat-Event")
                }
                onEvent?(.channelMessage(LegacyChannelMessage(
                    channelID: try channelField.uint32BE(),
                    senderUserID: try senderField.uint32BE(),
                    message: messageField.value,
                    attribute: attribute
                )))
            case LegacyCommand.channelSettings:
                guard let channelField = packet.firstField(type: LegacyChannelField.channelID),
                      let flagsField = packet.firstField(type: LegacyChannelField.settings) else {
                    throw LegacyControlClientError.protocolFailure("unvollständiges Channel-Settings-Event")
                }
                onEvent?(.channelSettings(channelID: try channelField.uint32BE(),
                                          topic: packet.firstField(type: LegacyChannelField.topic)?.value ?? Data(),
                                          flags: try flagsField.uint16BE()))
            case LegacyCommand.flatNewsPost:
                guard let field = packet.firstField(type: LegacyCommand.flatNewsPost) else {
                    throw LegacyControlClientError.protocolFailure("unvollständiges Flat-News-Post-Event")
                }
                onEvent?(.flatNewsPosted(field.value))
            case LegacyCommand.flatNewsDelete:
                guard let field = packet.firstField(type: LegacyCommand.flatNewsDelete) else {
                    throw LegacyControlClientError.protocolFailure("unvollständiges Flat-News-Delete-Event")
                }
                onEvent?(.flatNewsDeleted(try field.uint32BE()))
            case LegacyCommand.flatNewsClear:
                onEvent?(.flatNewsCleared)
            case LegacyCommand.bannerChanged:
                guard packet.fields.isEmpty else {
                    throw LegacyControlClientError.protocolFailure("Banner-Changed-Event enthält unerwartete Felder")
                }
                onEvent?(.bannerChanged)
            case LegacyCommand.mediaDeleted:
                guard let field = packet.firstField(type: 1), field.value.count == 36,
                      let text = String(data: field.value, encoding: .ascii),
                      let id = UUID(uuidString: text) else {
                    throw LegacyControlClientError.protocolFailure("invalid media-deleted event")
                }
                onEvent?(.mediaDeleted(id))
            case LegacyCommand.fileLabelChanged:
                guard let path = packet.firstField(type: 1)?.value,
                      !path.isEmpty, path.count <= LegacyPath.maximumWireLength,
                      let labelData = packet.firstField(type: LegacyFileLabelField.fileInfo)?.value else {
                    throw LegacyControlClientError.protocolFailure("invalid file-label-changed event")
                }
                onEvent?(.fileLabelChanged(path: path, label: try LegacyFileLabel.decode(labelData)))
            case LegacyCommand.userPresenceState:
                guard let idField = packet.firstField(type: LegacyPresenceStateField.userID),
                      let stateField = packet.firstField(type: LegacyPresenceStateField.state),
                      stateField.value.count == 1, let stateByte = stateField.value.first else {
                    throw LegacyControlClientError.protocolFailure("unvollständiges Presence-Event")
                }
                guard stateByte == LegacyPresenceState.awake || stateByte == LegacyPresenceState.sleeping else {
                    throw LegacyControlClientError.protocolFailure("unbekannter Presence-State \(stateByte)")
                }
                onEvent?(.presence(userID: try idField.uint32BE(),
                                   sleeping: stateByte == LegacyPresenceState.sleeping))
            default:
                onEvent?(.unhandled(packet))
            }
        } catch {
            // Keep the session alive for malformed/unknown asynchronous extensions;
            // the raw callback above still exposes the packet for diagnostics.
            onEvent?(.unhandled(packet))
        }
    }

    private func serverError(from packet: LegacyPacket) throws -> LegacyControlClientError {
        guard let field = packet.firstField(type: 1) else {
            return .serverError(0)
        }
        return .serverError(try field.uint16BE())
    }

    private func receiveControlPacket(key: Data,
                                      timeout: TimeInterval?,
                                      operation: String,
                                      completion: @escaping (Result<LegacyPacket, Error>) -> Void) {
        if let modernControlChannel {
            receiveExactly(CarrachoModernCrypto.frameHeaderLength, timeout: timeout,
                           operation: "\(operation) (AEAD-Header)") { [weak self] headerResult in
                guard let self else { return }
                do {
                    let header = try headerResult.get()
                    var cursor = LegacyByteCursor(header)
                    let length = Int(try cursor.readUInt32BE())
                    _ = try cursor.readUInt64BE()
                    guard length >= LegacyPacket.headerSize,
                          length <= LegacyPacket.headerSize + LegacyPacket.maximumClassicBodyLength else {
                        throw LegacyProtocolError.invalidLength("invalid authenticated control ciphertext length \(length)")
                    }
                    self.receiveExactly(length + CarrachoModernCrypto.tagLength, timeout: timeout,
                                        operation: "\(operation) (AEAD-Daten)") { bodyResult in
                        do {
                            var frame = header
                            frame.append(try bodyResult.get())
                            let plaintext = try modernControlChannel.open(frame,
                                maximumCiphertextLength: LegacyPacket.headerSize + LegacyPacket.maximumClassicBodyLength)
                            let decoded = try LegacyPacket.parsePlaintext(plaintext)
                            guard decoded.trailing.isEmpty else {
                                throw LegacyProtocolError.trailingBytes(decoded.trailing.count)
                            }
                            completion(.success(decoded.packet))
                        } catch { completion(.failure(error)) }
                    }
                } catch { completion(.failure(error)) }
            }
            return
        }

        receiveExactly(4, timeout: timeout, operation: "\(operation) (Frame-Länge)") { [weak self] prefixResult in
            guard let self else { return }
            do {
                let prefix = try prefixResult.get()
                var prefixCursor = LegacyByteCursor(prefix)
                let length = Int(try prefixCursor.readUInt32BE())
                guard length > 0,
                      length.isMultiple(of: 8),
                      length <= LegacyControlCodec.maximumCiphertextLength else {
                    throw LegacyProtocolError.invalidLength("invalid control ciphertext length \(length)")
                }
                self.receiveExactly(length, timeout: timeout, operation: "\(operation) (Frame-Daten)") { bodyResult in
                    do {
                        var frame = prefix
                        frame.append(try bodyResult.get())
                        completion(.success(try LegacyControlCodec.decode(frame, key: key)))
                    } catch { completion(.failure(error)) }
                }
            } catch { completion(.failure(error)) }
        }
    }

    private func receiveExactly(_ byteCount: Int,
                                timeout: TimeInterval? = nil,
                                operation: String = "Netzwerkempfang",
                                completion: @escaping (Result<Data, Error>) -> Void) {
        guard byteCount >= 0 else {
            completion(.failure(LegacyProtocolError.invalidLength("negative receive length")))
            return
        }
        guard let connection else {
            completion(.failure(LegacyControlClientError.connectionClosed))
            return
        }
        if byteCount == 0 {
            completion(.success(Data()))
            return
        }

        var buffer = Data()
        var finished = false
        var timeoutWorkItem: DispatchWorkItem?

        func finish(_ result: Result<Data, Error>) {
            guard !finished else { return }
            finished = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            completion(result)
        }

        if let timeout {
            let item = DispatchWorkItem { [weak self, weak connection] in
                guard let self, let connection, self.connection === connection else { return }
                finish(.failure(LegacyControlClientError.timedOut(operation)))
            }
            timeoutWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
        }

        func pump() {
            guard !finished else { return }
            let remaining = byteCount - buffer.count
            guard remaining > 0 else {
                finish(.success(buffer))
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self, weak connection] data, _, isComplete, error in
                guard let self, let connection, self.connection === connection, !finished else { return }
                if let data { buffer.append(data) }
                if let error {
                    finish(.failure(LegacyControlClientError.transport(error.localizedDescription)))
                    return
                }
                if buffer.count == byteCount {
                    finish(.success(buffer))
                    return
                }
                if isComplete {
                    finish(.failure(LegacyControlClientError.connectionClosed))
                    return
                }
                pump()
            }
        }
        pump()
    }

    private func sendRaw(_ data: Data, completion: @escaping (Error?) -> Void) {
        guard let connection else {
            completion(LegacyControlClientError.connectionClosed)
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.connection === connection else { return }
            if let error {
                completion(LegacyControlClientError.transport(error.localizedDescription))
            } else {
                completion(nil)
            }
        })
    }

    private func allocateTransactionID() -> UInt32 {
        while nextTransactionID == 0 || pendingRequests[nextTransactionID] != nil {
            nextTransactionID &+= 1
        }
        let result = nextTransactionID
        nextTransactionID &+= 1
        if nextTransactionID == 0 { nextTransactionID = 1 }
        return result
    }

    private func fail(_ error: Error) {
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        state = .failed(message)
        let completion = loginCompletion
        loginCompletion = nil
        completion?(.failure(error))
        failPending(with: error)
        let oldConnection = connection
        connection = nil
        sessionKey = nil
        modernControlChannel = nil
        negotiatedLegacyCrypto = false
        transferSession = nil
        currentNickname = nil
        oldConnection?.cancel()
    }

    private func failPending(with error: Error) {
        let requests = Array(pendingRequests.values)
        pendingRequests.removeAll()
        for request in requests {
            request.timeoutWorkItem.cancel()
            request.completion(.failure(error))
        }
    }

    private func handleTransportClosed() {
        guard connection != nil else { return }
        if expectedDisconnect {
            connection = nil
            sessionKey = nil
            modernControlChannel = nil
            negotiatedLegacyCrypto = false
            transferSession = nil
            currentNickname = nil
            state = .idle
        } else {
            fail(LegacyControlClientError.connectionClosed)
        }
    }

    private static func macRomanString(_ data: Data?) -> String? {
        guard let data else { return nil }
        return String(data: data, encoding: .macOSRoman)
    }
}
