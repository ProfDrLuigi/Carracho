import Foundation
@preconcurrency import Network

enum LegacyFileTransferError: Error, LocalizedError {
    case invalidTransferPort
    case transport(String)
    case connectionClosed
    case timedOut
    case invalidRemotePath
    case invalidTransferRecord(String)
    case uploadConflict
    case uploadSpecialConflict
    case fileTooLarge(maximumBytes: UInt64)
    case localFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidTransferPort:
            return "Für Port 65535 kann kein Carracho-Transfer-Port (+1) gebildet werden."
        case let .transport(message):
            return "Dateitransferfehler: \(message)"
        case .connectionClosed:
            return "Die Dateitransferverbindung wurde vorzeitig geschlossen."
        case .timedOut:
            return "Zeitüberschreitung beim Dateitransfer."
        case .invalidRemotePath:
            return "Der Serverpfad ist für einen Carracho-Dateitransfer ungültig."
        case let .invalidTransferRecord(message):
            return "Ungültiger Dateitransfer-Record: \(message)"
        case .uploadConflict:
            return "Am Ziel existiert bereits eine Datei."
        case .uploadSpecialConflict:
            return "Am Ziel existiert ein Ordner oder ein nicht ersetzbares Objekt."
        case let .fileTooLarge(maximumBytes):
            return "Die Datei überschreitet das erlaubte Limit von \(ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file))."
        case let .localFile(message):
            return "Lokaler Dateifehler: \(message)"
        }
    }
}

struct LegacyFileTransferProgress: Equatable {
    let completedBytes: UInt64
    let totalBytes: UInt64
    var resumedBytes: UInt64 = 0
}

final class LegacyFileTransferTask {
    private var cancellationHandler: (() -> Void)?
    private(set) var isCancelled = false

    fileprivate init() {}

    fileprivate func installCancellationHandler(_ handler: @escaping () -> Void) {
        if isCancelled { handler() } else { cancellationHandler = handler }
    }

    fileprivate func finish() { cancellationHandler = nil }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        let handler = cancellationHandler
        cancellationHandler = nil
        handler?()
    }
}

private final class LegacyTransferURLBox {
    var value: URL?
    init(_ value: URL? = nil) { self.value = value }
}

private final class LegacyTransferStringBox {
    var value: String?
    init(_ value: String? = nil) { self.value = value }
}

private final class LegacyTransferUInt64Box {
    var value: UInt64
    init(_ value: UInt64 = 0) { self.value = value }
}

final class LegacyFileTransferClient {
    private static let timeout: TimeInterval = 30 * 60
    private static let ioChunk = 256 * 1024
    private static let folderType: UInt32 = 0x464c4452 // FLDR
    private static let folderCreator: UInt32 = 0x43617253 // CarS

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let session: LegacyTransferSession

    private struct TransferEntryHeader {
        let path: Data
        let fileType: UInt32
        let creator: UInt32
        let flags: UInt16
        let finderInfo: Data
        let extra: Data
        var isFolder: Bool { fileType == LegacyFileTransferClient.folderType && creator == LegacyFileTransferClient.folderCreator }
        var declaredSize: UInt64? {
            guard !isFolder, extra.count >= 8 else { return nil }
            var cursor = LegacyByteCursor(Data(extra.prefix(8)))
            return try? cursor.readUInt64BE()
        }
    }

    private struct UploadItem {
        let relativePath: Data
        let url: URL
        let isFolder: Bool
        let size: UInt64
    }

    init(host: String, controlPort: UInt16, session: LegacyTransferSession) throws {
        guard controlPort < UInt16.max, let port = NWEndpoint.Port(rawValue: controlPort + 1) else {
            throw LegacyFileTransferError.invalidTransferPort
        }
        self.host = NWEndpoint.Host(host)
        self.port = port
        self.session = session
    }

    @discardableResult
    func download(remotePath: Data,
                  to destination: URL,
                  maximumFileSize: UInt64? = nil,
                  progress: ((LegacyFileTransferProgress) -> Void)? = nil,
                  completion: @escaping (Result<URL, Error>) -> Void) -> LegacyFileTransferTask {
        let task = LegacyFileTransferTask()
        guard isValidRemotePath(remotePath) else {
            completion(.failure(LegacyFileTransferError.invalidRemotePath)); return task
        }
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let stream: AuthenticatedTransferStream
        do {
            stream = try AuthenticatedTransferStream(connection: connection, session: session,
                                                     operation: LegacyTransferOperation.encryptedDownload,
                                                     legacyMode: .blowfish)
        } catch { completion(.failure(error)); return task }
        task.installCancellationHandler { connection.cancel() }
        let tempURL = LegacyTransferURLBox()
        var finished = false
        var timeout: DispatchWorkItem!

        func finish(_ result: Result<URL, Error>) {
            guard !finished else { return }
            finished = true
            timeout?.cancel()
            task.finish()
            connection.cancel()
            completion(result)
        }
        timeout = DispatchWorkItem { finish(.failure(LegacyFileTransferError.timedOut)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: timeout)

        connection.stateUpdateHandler = { state in
            guard !finished else { return }
            switch state {
            case .ready:
                self.beginDownload(stream: stream, remotePath: remotePath) { result in
                    switch result {
                    case .success:
                        self.receiveSingleFileDownload(stream: stream, destination: destination,
                                                       tempURL: tempURL, maximumFileSize: maximumFileSize,
                                                       progress: progress, completion: finish)
                    case let .failure(error): finish(.failure(error))
                    }
                }
            case let .failed(error): finish(.failure(LegacyFileTransferError.transport(error.localizedDescription)))
            case .cancelled: if !finished { finish(.failure(LegacyFileTransferError.connectionClosed)) }
            default: break
            }
        }
        connection.start(queue: .main)
        return task
    }

    @discardableResult
    func downloadDirectory(remotePath: Data,
                           toParentDirectory parentDirectory: URL,
                           progress: ((LegacyFileTransferProgress) -> Void)? = nil,
                           completion: @escaping (Result<URL, Error>) -> Void) -> LegacyFileTransferTask {
        let task = LegacyFileTransferTask()
        guard isValidRemotePath(remotePath) else {
            completion(.failure(LegacyFileTransferError.invalidRemotePath)); return task
        }
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let stream: AuthenticatedTransferStream
        do {
            stream = try AuthenticatedTransferStream(connection: connection, session: session,
                                                     operation: LegacyTransferOperation.encryptedDownload,
                                                     legacyMode: .blowfish)
        } catch { completion(.failure(error)); return task }
        task.installCancellationHandler { connection.cancel() }
        let stagingURL = LegacyTransferURLBox()
        var finished = false
        var timeout: DispatchWorkItem!

        func finish(_ result: Result<URL, Error>) {
            guard !finished else { return }
            finished = true
            timeout?.cancel()
            task.finish()
            connection.cancel()
            if case let .failure(error) = result,
               let transferError = error as? LegacyFileTransferError {
                switch transferError {
                case .invalidTransferRecord, .invalidRemotePath:
                    if let url = stagingURL.value { try? FileManager.default.removeItem(at: url) }
                    stagingURL.value = nil
                default: break
                }
            }
            completion(result)
        }
        timeout = DispatchWorkItem { finish(.failure(LegacyFileTransferError.timedOut)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: timeout)

        connection.stateUpdateHandler = { state in
            guard !finished else { return }
            switch state {
            case .ready:
                self.beginDownload(stream: stream, remotePath: remotePath) { result in
                    switch result {
                    case .success:
                        self.receiveDirectoryDownload(stream: stream, parentDirectory: parentDirectory,
                                                      stagingURL: stagingURL, progress: progress, completion: finish)
                    case let .failure(error): finish(.failure(error))
                    }
                }
            case let .failed(error): finish(.failure(LegacyFileTransferError.transport(error.localizedDescription)))
            case .cancelled: if !finished { finish(.failure(LegacyFileTransferError.connectionClosed)) }
            default: break
            }
        }
        connection.start(queue: .main)
        return task
    }

    @discardableResult
    func upload(localFile: URL,
                toParentPath parentPath: Data,
                overwrite: Bool,
                progress: ((LegacyFileTransferProgress) -> Void)? = nil,
                completion: @escaping (Result<Void, Error>) -> Void) -> LegacyFileTransferTask {
        let task = LegacyFileTransferTask()
        guard parentPath.count <= LegacyPath.maximumWireLength else {
            completion(.failure(LegacyFileTransferError.invalidRemotePath)); return task
        }
        let items: [UploadItem]
        let totalBytes: UInt64
        do {
            (items, totalBytes) = try buildUploadItems(root: localFile)
        } catch {
            completion(.failure(error)); return task
        }
        guard let rootItem = items.first else {
            completion(.failure(LegacyFileTransferError.localFile("Leerer Upload-Baum."))); return task
        }
        let rootName: Data
        do {
            let components = try safeLocalComponents(for: rootItem.relativePath)
            guard components.count == 1,
                  let encoded = components[0].data(using: .macOSRoman) else {
                throw LegacyFileTransferError.localFile("Ungültiger Wurzelname.")
            }
            rootName = encoded
        } catch {
            completion(.failure(error)); return task
        }
        let remotePath: Data
        do { remotePath = try LegacyPath.child(parent: parentPath, name: rootName) }
        catch { completion(.failure(error)); return task }

        let connection = NWConnection(host: host, port: port, using: .tcp)
        let stream: AuthenticatedTransferStream
        do {
            stream = try AuthenticatedTransferStream(connection: connection, session: session,
                                                     operation: LegacyTransferOperation.encryptedUpload,
                                                     legacyMode: .blowfish)
        } catch { completion(.failure(error)); return task }
        task.installCancellationHandler { connection.cancel() }
        var finished = false
        var timeout: DispatchWorkItem!
        func finish(_ result: Result<Void, Error>) {
            guard !finished else { return }
            finished = true
            timeout?.cancel()
            task.finish()
            connection.cancel()
            completion(result)
        }
        timeout = DispatchWorkItem { finish(.failure(LegacyFileTransferError.timedOut)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: timeout)

        connection.stateUpdateHandler = { state in
            guard !finished else { return }
            switch state {
            case .ready:
                stream.sendHello { result in
                    guard case .success = result else { finish(result); return }
                    self.sendUploadNegotiation(stream: stream, parentPath: parentPath, remotePath: remotePath,
                                               overwrite: overwrite) { negotiation in
                        switch negotiation {
                        case .success:
                            self.sendUploadItems(stream: stream, items: items, totalBytes: totalBytes,
                                                 progress: progress, completion: finish)
                        case let .failure(error): finish(.failure(error))
                        }
                    }
                }
            case let .failed(error): finish(.failure(LegacyFileTransferError.transport(error.localizedDescription)))
            case .cancelled: if !finished { finish(.failure(LegacyFileTransferError.connectionClosed)) }
            default: break
            }
        }
        connection.start(queue: .main)
        return task
    }

    private func isValidRemotePath(_ path: Data) -> Bool {
        !path.isEmpty && path.count <= LegacyPath.maximumWireLength
    }

    private func beginDownload(stream: AuthenticatedTransferStream,
                               remotePath: Data,
                               completion: @escaping (Result<Void, Error>) -> Void) {
        stream.sendHello { result in
            guard case .success = result else { completion(result); return }
            do {
                let pathWire = try LegacyWire.string16(remotePath)
                stream.sendPayload(pathWire) { result in
                    guard case .success = result else { completion(result); return }
                    self.readDownloadQueue(stream: stream, completion: completion)
                }
            } catch { completion(.failure(error)) }
        }
    }

    private func readDownloadQueue(stream: AuthenticatedTransferStream,
                                   completion: @escaping (Result<Void, Error>) -> Void) {
        stream.readPayload(4) { result in
            do {
                var cursor = LegacyByteCursor(try result.get())
                var remaining = try cursor.readUInt32BE()
                if remaining == 0 { completion(.success(())); return }
                func next() {
                    stream.readPayload(1) { statusResult in
                        do {
                            let status = try statusResult.get()
                            guard let byte = status.first, byte == 0 || byte == 1 else {
                                throw LegacyFileTransferError.invalidTransferRecord("ungültiger Queue-Status")
                            }
                            if byte == 1, remaining > 0 { remaining -= 1 }
                            if remaining == 0 { completion(.success(())) } else { next() }
                        } catch { completion(.failure(error)) }
                    }
                }
                next()
            } catch { completion(.failure(error)) }
        }
    }

    private func receiveSingleFileDownload(stream: AuthenticatedTransferStream,
                                           destination: URL,
                                           tempURL: LegacyTransferURLBox,
                                           maximumFileSize: UInt64?,
                                           progress: ((LegacyFileTransferProgress) -> Void)?,
                                           completion: @escaping (Result<URL, Error>) -> Void) {
        readTransferEnvelope(stream: stream) { envelopeResult in
            do {
                let (declaredTotal, count) = try envelopeResult.get()
                guard count == 1 else {
                    throw LegacyFileTransferError.invalidTransferRecord("Dateidownload enthält \(count) Einträge statt genau einem")
                }
                if let maximumFileSize, declaredTotal > maximumFileSize {
                    throw LegacyFileTransferError.fileTooLarge(maximumBytes: maximumFileSize)
                }
                self.readTransferEntryHeader(stream: stream) { headerResult in
                    do {
                        let header = try headerResult.get()
                        guard !header.isFolder else {
                            throw LegacyFileTransferError.invalidTransferRecord("Dateidownload lieferte einen Ordner")
                        }
                        if let maximumFileSize, let expected = header.declaredSize, expected > maximumFileSize {
                            throw LegacyFileTransferError.fileTooLarge(maximumBytes: maximumFileSize)
                        }
                        let partial = try self.partialURL(for: destination)
                        tempURL.value = partial
                        try self.preparePartialFile(partial, expectedSize: header.declaredSize)
                        let resume = try self.currentRegularFileSizeIfPresent(partial)
                        let handle = try FileHandle(forWritingTo: partial)
                        try handle.seek(toOffset: resume)
                        progress?(LegacyFileTransferProgress(completedBytes: resume,
                                                           totalBytes: max(declaredTotal, header.declaredSize ?? 0),
                                                           resumedBytes: resume))
                        self.receiveFilePayload(stream: stream, writeTo: handle, resumeOffset: resume,
                                                completedBase: resume, totalBytes: declaredTotal,
                                                maximumFileSize: maximumFileSize, progress: progress) { payloadResult in
                            try? handle.close()
                            do {
                                _ = try payloadResult.get()
                                if let expected = header.declaredSize {
                                    let actual = try self.currentRegularFileSizeIfPresent(partial)
                                    guard actual == expected else {
                                        throw LegacyFileTransferError.invalidTransferRecord("partielle Zieldatei hat nach Abschluss Größe \(actual), erwartet \(expected)")
                                    }
                                }
                                if FileManager.default.fileExists(atPath: destination.path) {
                                    try FileManager.default.removeItem(at: destination)
                                }
                                try FileManager.default.moveItem(at: partial, to: destination)
                                tempURL.value = nil
                                completion(.success(destination))
                            } catch {
                                completion(.failure(error))
                            }
                        }
                    } catch { completion(.failure(error)) }
                }
            } catch { completion(.failure(error)) }
        }
    }

    private func receiveDirectoryDownload(stream: AuthenticatedTransferStream,
                                          parentDirectory: URL,
                                          stagingURL: LegacyTransferURLBox,
                                          progress: ((LegacyFileTransferProgress) -> Void)?,
                                          completion: @escaping (Result<URL, Error>) -> Void) {
        readTransferEnvelope(stream: stream) { envelopeResult in
            do {
                let (declaredTotal, count) = try envelopeResult.get()
                guard count > 0 else {
                    throw LegacyFileTransferError.invalidTransferRecord("Ordnerdownload enthält keine Einträge")
                }
                let stage = LegacyTransferURLBox()
                let rootName = LegacyTransferStringBox()
                let completed = LegacyTransferUInt64Box()

                func process(_ index: UInt32) {
                    if index == count {
                        do {
                            guard let root = rootName.value, let stagedRoot = stage.value else {
                                throw LegacyFileTransferError.invalidTransferRecord("Ordnerdownload hat keine Wurzel")
                            }
                            let finalRoot = parentDirectory.appendingPathComponent(root, isDirectory: true)
                            guard FileManager.default.fileExists(atPath: stagedRoot.path) else {
                                throw LegacyFileTransferError.invalidTransferRecord("Ordnerwurzel wurde nicht erzeugt")
                            }
                            guard !FileManager.default.fileExists(atPath: finalRoot.path) else {
                                throw LegacyFileTransferError.localFile("Zielordner \(root) existiert bereits.")
                            }
                            try FileManager.default.moveItem(at: stagedRoot, to: finalRoot)
                            stagingURL.value = nil
                            progress?(LegacyFileTransferProgress(completedBytes: completed.value,
                                                               totalBytes: max(declaredTotal, completed.value)))
                            completion(.success(finalRoot))
                        } catch { completion(.failure(error)) }
                        return
                    }

                    self.readTransferEntryHeader(stream: stream) { headerResult in
                        do {
                            let header = try headerResult.get()
                            let components = try self.safeLocalComponents(for: header.path)
                            guard !components.isEmpty else {
                                throw LegacyFileTransferError.invalidTransferRecord("leerer relativer Pfad")
                            }
                            if index == 0 {
                                guard header.isFolder, components.count == 1 else {
                                    throw LegacyFileTransferError.invalidTransferRecord("erster Ordnerdownload-Eintrag ist keine Wurzel")
                                }
                                let root = components[0]
                                rootName.value = root
                                let stagedRoot = parentDirectory.appendingPathComponent("\(root).carracho", isDirectory: true)
                                let legacyStagedRoot = parentDirectory.appendingPathComponent(".carracho.\(root)", isDirectory: true)
                                if !FileManager.default.fileExists(atPath: stagedRoot.path),
                                   FileManager.default.fileExists(atPath: legacyStagedRoot.path) {
                                    try FileManager.default.moveItem(at: legacyStagedRoot, to: stagedRoot)
                                }
                                let finalRoot = parentDirectory.appendingPathComponent(root, isDirectory: true)
                                guard !FileManager.default.fileExists(atPath: finalRoot.path) else {
                                    throw LegacyFileTransferError.localFile("Zielordner \(root) existiert bereits.")
                                }
                                if FileManager.default.fileExists(atPath: stagedRoot.path) {
                                    let values = try stagedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                                    if values.isDirectory != true || values.isSymbolicLink == true {
                                        try FileManager.default.removeItem(at: stagedRoot)
                                        try FileManager.default.createDirectory(at: stagedRoot, withIntermediateDirectories: false)
                                    }
                                } else {
                                    try FileManager.default.createDirectory(at: stagedRoot, withIntermediateDirectories: false)
                                }
                                stage.value = stagedRoot
                                stagingURL.value = stagedRoot
                                process(index + 1)
                                return
                            }
                            guard components[0] == rootName.value, let stagedRoot = stage.value else {
                                throw LegacyFileTransferError.invalidTransferRecord("Eintrag liegt außerhalb der Download-Wurzel")
                            }

                            var target = stagedRoot
                            for component in components.dropFirst() { target.appendPathComponent(component) }
                            if header.isFolder {
                                if FileManager.default.fileExists(atPath: target.path) {
                                    let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                                    guard values.isDirectory == true, values.isSymbolicLink != true else {
                                        throw LegacyFileTransferError.invalidTransferRecord("Ordner kollidiert mit einer vorhandenen Teildatei")
                                    }
                                } else {
                                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                                }
                                process(index + 1)
                                return
                            }

                            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                                    withIntermediateDirectories: true)
                            let expected = header.declaredSize
                            var resume: UInt64 = 0
                            var writeURL = try self.partialURL(for: target)
                            if FileManager.default.fileExists(atPath: target.path), let expected {
                                let finalSize = try self.currentRegularFileSizeIfPresent(target)
                                if finalSize == expected {
                                    resume = expected
                                    writeURL = target
                                } else {
                                    try FileManager.default.removeItem(at: target)
                                }
                            }
                            if resume == 0 {
                                try self.preparePartialFile(writeURL, expectedSize: expected)
                                resume = try self.currentRegularFileSizeIfPresent(writeURL)
                            }
                            let handle = try FileHandle(forWritingTo: writeURL)
                            try handle.seek(toOffset: resume)
                            let base = completed.value + resume
                            progress?(LegacyFileTransferProgress(completedBytes: base, totalBytes: declaredTotal, resumedBytes: resume))
                            self.receiveFilePayload(stream: stream, writeTo: handle, resumeOffset: resume,
                                                    completedBase: base, totalBytes: declaredTotal,
                                                    maximumFileSize: nil, progress: progress) { payloadResult in
                                try? handle.close()
                                do {
                                    _ = try payloadResult.get()
                                    if let expected {
                                        let actual = try self.currentRegularFileSizeIfPresent(writeURL)
                                        guard actual == expected else {
                                            throw LegacyFileTransferError.invalidTransferRecord("partielle Datei hat nach Abschluss Größe \(actual), erwartet \(expected)")
                                        }
                                    }
                                    if writeURL != target {
                                        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                                        try FileManager.default.moveItem(at: writeURL, to: target)
                                    }
                                    let fullSize: UInt64
                                    if let expected { fullSize = expected }
                                    else { fullSize = try self.currentRegularFileSizeIfPresent(target) }
                                    let (newValue, overflow) = completed.value.addingReportingOverflow(fullSize)
                                    guard !overflow else {
                                        throw LegacyFileTransferError.invalidTransferRecord("Download-Größenzähler überläuft")
                                    }
                                    completed.value = newValue
                                    process(index + 1)
                                } catch { completion(.failure(error)) }
                            }
                        } catch { completion(.failure(error)) }
                    }
                }
                process(0)
            } catch { completion(.failure(error)) }
        }
    }

    private func readTransferEnvelope(stream: AuthenticatedTransferStream,
                                      completion: @escaping (Result<(UInt64, UInt32), Error>) -> Void) {
        stream.readPayload(12) { result in
            do {
                var cursor = LegacyByteCursor(try result.get())
                let total = (UInt64(try cursor.readUInt32BE()) << 32) | UInt64(try cursor.readUInt32BE())
                let count = try cursor.readUInt32BE()
                guard count <= 1_000_000 else {
                    throw LegacyFileTransferError.invalidTransferRecord("unplausible Eintragsanzahl \(count)")
                }
                completion(.success((total, count)))
            } catch { completion(.failure(error)) }
        }
    }

    private func readTransferEntryHeader(stream: AuthenticatedTransferStream,
                                         completion: @escaping (Result<TransferEntryHeader, Error>) -> Void) {
        stream.readPayload(2) { lengthResult in
            do {
                var cursor = LegacyByteCursor(try lengthResult.get())
                let length = Int(try cursor.readUInt16BE())
                guard length > 0, length <= LegacyPath.maximumWireLength else {
                    throw LegacyFileTransferError.invalidRemotePath
                }
                stream.readPayload(length + 30) { fixedResult in
                    do {
                        var fixed = LegacyByteCursor(try fixedResult.get())
                        let path = try fixed.readBytes(count: length)
                        let type = try fixed.readUInt32BE()
                        let creator = try fixed.readUInt32BE()
                        let flags = try fixed.readUInt16BE()
                        let finder = try fixed.readBytes(count: 16)
                        let extraCount = Int(try fixed.readUInt32BE())
                        guard extraCount <= 4096 else {
                            throw LegacyFileTransferError.invalidTransferRecord("zu viele Zusatzbytes")
                        }
                        stream.readPayload(extraCount) { extraResult in
                            do {
                                completion(.success(TransferEntryHeader(path: path, fileType: type, creator: creator,
                                                                        flags: flags, finderInfo: finder,
                                                                        extra: try extraResult.get())))
                            } catch { completion(.failure(error)) }
                        }
                    } catch { completion(.failure(error)) }
                }
            } catch { completion(.failure(error)) }
        }
    }

    private func receiveFilePayload(stream: AuthenticatedTransferStream,
                                    writeTo handle: FileHandle,
                                    resumeOffset: UInt64,
                                    completedBase: UInt64,
                                    totalBytes: UInt64,
                                    maximumFileSize: UInt64?,
                                    progress: ((LegacyFileTransferProgress) -> Void)?,
                                    completion: @escaping (Result<UInt64, Error>) -> Void) {
        var resumePayload = LegacyWire.uint64BE(resumeOffset)
        if !session.usesModernCrypto {
            // Classic encrypted downloads negotiate both forks. Carracho Server 1.0b13
            // reads a 64-bit data-fork resume offset followed by a 64-bit resource-fork
            // resume offset before sending either fork length.
            resumePayload.append(LegacyWire.uint64BE(0))
        }

        stream.sendPayload(resumePayload) { sent in
            guard case .success = sent else { completion(sent.map { 0 }); return }
            let lengthBytes = self.session.usesModernCrypto ? 8 : 16
            stream.readPayload(lengthBytes) { lengthResult in
                do {
                    var cursor = LegacyByteCursor(try lengthResult.get())
                    let dataLength = try cursor.readUInt64BE()
                    let resourceLength = self.session.usesModernCrypto ? 0 : try cursor.readUInt64BE()
                    let (logicalEnd, overflow) = completedBase.addingReportingOverflow(dataLength)
                    guard !overflow else {
                        throw LegacyFileTransferError.invalidTransferRecord("Download-Größenzähler überläuft")
                    }
                    if let maximumFileSize, logicalEnd > maximumFileSize {
                        throw LegacyFileTransferError.fileTooLarge(maximumBytes: maximumFileSize)
                    }
                    self.receiveBytes(stream: stream, count: dataLength, writeTo: handle,
                                      completedBase: completedBase, total: max(totalBytes, logicalEnd),
                                      progress: progress) { bytesResult in
                        guard case .success = bytesResult else { completion(bytesResult.map { dataLength }); return }
                        self.discardBytes(stream: stream, count: resourceLength) { resourceResult in
                            guard case .success = resourceResult else {
                                completion(resourceResult.map { dataLength }); return
                            }
                            stream.readPayload(2) { commentLenResult in
                                do {
                                    var cc = LegacyByteCursor(try commentLenResult.get())
                                    let commentLength = Int(try cc.readUInt16BE())
                                    guard commentLength <= 4096 else {
                                        throw LegacyFileTransferError.invalidTransferRecord("Kommentar ist zu lang")
                                    }
                                    stream.readPayload(commentLength) { commentResult in
                                        do {
                                            _ = try commentResult.get()
                                            completion(.success(dataLength))
                                        } catch { completion(.failure(error)) }
                                    }
                                } catch { completion(.failure(error)) }
                            }
                        }
                    }
                } catch { completion(.failure(error)) }
            }
        }
    }

    private func discardBytes(stream: AuthenticatedTransferStream,
                              count: UInt64,
                              completion: @escaping (Result<Void, Error>) -> Void) {
        var remaining = count
        func next() {
            guard remaining > 0 else { completion(.success(())); return }
            let chunk = Int(min(UInt64(Self.ioChunk), remaining))
            stream.readPayload(chunk) { result in
                do {
                    let data = try result.get()
                    guard !data.isEmpty else {
                        throw LegacyFileTransferError.connectionClosed
                    }
                    remaining -= UInt64(data.count)
                    next()
                } catch {
                    completion(.failure(error))
                }
            }
        }
        next()
    }

    private func receiveBytes(stream: AuthenticatedTransferStream,
                              count: UInt64,
                              writeTo handle: FileHandle,
                              completedBase: UInt64,
                              total: UInt64,
                              progress: ((LegacyFileTransferProgress) -> Void)?,
                              completion: @escaping (Result<Void, Error>) -> Void) {
        var remaining = count
        var completed: UInt64 = 0
        func next() {
            guard remaining > 0 else { completion(.success(())); return }
            let chunk = Int(min(UInt64(Self.ioChunk), remaining))
            stream.readPayload(chunk) { result in
                do {
                    let data = try result.get()
                    handle.write(data)
                    remaining -= UInt64(data.count)
                    completed += UInt64(data.count)
                    progress?(LegacyFileTransferProgress(completedBytes: completedBase + completed, totalBytes: total))
                    next()
                } catch { completion(.failure(LegacyFileTransferError.localFile(error.localizedDescription))) }
            }
        }
        next()
    }

    private func safeLocalComponents(for legacyPath: Data) throws -> [String] {
        guard !legacyPath.isEmpty, legacyPath.count <= LegacyPath.maximumWireLength else {
            throw LegacyFileTransferError.invalidRemotePath
        }
        let rawComponents = legacyPath.split(separator: LegacyPath.separator, omittingEmptySubsequences: false)
        var result: [String] = []
        result.reserveCapacity(rawComponents.count)
        for raw in rawComponents {
            let data = Data(raw)
            guard !data.isEmpty, let name = String(data: data, encoding: .macOSRoman),
                  !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\0") else {
                throw LegacyFileTransferError.invalidTransferRecord("unsicherer relativer Pfad")
            }
            result.append(name)
        }
        return result
    }

    private func partialURL(for finalURL: URL) throws -> URL {
        let parent = finalURL.deletingLastPathComponent()
        let partial = parent.appendingPathComponent("\(finalURL.lastPathComponent).carracho")
        let legacyPartial = parent.appendingPathComponent(".carracho.\(finalURL.lastPathComponent)")
        if !FileManager.default.fileExists(atPath: partial.path),
           FileManager.default.fileExists(atPath: legacyPartial.path) {
            try FileManager.default.moveItem(at: legacyPartial, to: partial)
        }
        return partial
    }

    private func currentRegularFileSizeIfPresent(_ url: URL) throws -> UInt64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw LegacyFileTransferError.localFile("Resume-Datei ist keine reguläre Datei: \(url.lastPathComponent)")
        }
        return size.uint64Value
    }

    private func preparePartialFile(_ url: URL, expectedSize: UInt64?) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let size = try currentRegularFileSizeIfPresent(url)
                if let expectedSize, size > expectedSize {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                try FileManager.default.removeItem(at: url)
            }
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw LegacyFileTransferError.localFile("Temporäre .carracho-Datei konnte nicht angelegt werden.")
            }
        }
    }

    private func sendUploadNegotiation(stream: AuthenticatedTransferStream,
                                       parentPath: Data,
                                       remotePath: Data,
                                       overwrite: Bool,
                                       completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let parentWire = try LegacyWire.string16(parentPath)
            let targetWire = try LegacyWire.string16(remotePath)
            stream.sendPayload(parentWire) { first in
                guard case .success = first else { completion(first); return }
                stream.sendPayload(targetWire) { second in
                    guard case .success = second else { completion(second); return }
                    stream.readPayload(1) { statusResult in
                        do {
                            guard let status = try statusResult.get().first else {
                                throw LegacyFileTransferError.invalidTransferRecord("fehlender Upload-Konfliktstatus")
                            }
                            if status == 2 { throw LegacyFileTransferError.uploadSpecialConflict }
                            if status == 1 { throw LegacyFileTransferError.uploadConflict }
                            guard status == 0 else {
                                throw LegacyFileTransferError.invalidTransferRecord("unbekannter Upload-Konfliktstatus \(status)")
                            }
                            // The legacy byte is retained on the wire for compatibility, but a
                            // Carracho client never authorizes replacement of a published item.
                            // Resume data lives in a separate .carracho staging path and needs no
                            // overwrite permission.
                            stream.sendPayload(Data([0]), completion: completion)
                        } catch { completion(.failure(error)) }
                    }
                }
            }
        } catch { completion(.failure(error)) }
    }

    private func currentRegularFileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw LegacyFileTransferError.localFile("Dateigröße konnte nicht ermittelt werden: \(url.lastPathComponent)")
        }
        return size.uint64Value
    }

    private func buildUploadItems(root: URL) throws -> ([UploadItem], UInt64) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let rootValues = try root.resourceValues(forKeys: keys)
        guard rootValues.isSymbolicLink != true else {
            throw LegacyFileTransferError.localFile("Symbolische Links werden nicht hochgeladen.")
        }
        guard rootValues.isDirectory == true || rootValues.isRegularFile == true else {
            throw LegacyFileTransferError.localFile("Nur reguläre Dateien und Ordner können hochgeladen werden.")
        }
        guard let rootName = root.lastPathComponent.data(using: .macOSRoman), !rootName.isEmpty else {
            throw LegacyFileTransferError.localFile("Datei- oder Ordnername ist nicht in MacRoman darstellbar.")
        }
        let rootSize = rootValues.isRegularFile == true ? try currentRegularFileSize(root) : 0
        var items = [UploadItem(relativePath: rootName, url: root, isFolder: rootValues.isDirectory == true, size: rootSize)]

        if rootValues.isDirectory == true {
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, error in enumerationError = error; return false }
            ) else {
                throw LegacyFileTransferError.localFile("Ordnerinhalt konnte nicht gelesen werden.")
            }
            let rootComponentsCount = root.standardizedFileURL.pathComponents.count
            while let child = enumerator.nextObject() as? URL {
                if let error = enumerationError { throw LegacyFileTransferError.localFile(error.localizedDescription) }
                let values = try child.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    throw LegacyFileTransferError.localFile("Symbolische Links werden nicht hochgeladen: \(child.lastPathComponent)")
                }
                guard values.isDirectory == true || values.isRegularFile == true else {
                    throw LegacyFileTransferError.localFile("Nicht unterstütztes Dateisystemobjekt: \(child.lastPathComponent)")
                }
                let childComponents = child.standardizedFileURL.pathComponents
                guard childComponents.count > rootComponentsCount else { continue }
                var legacy = rootName
                for component in childComponents.dropFirst(rootComponentsCount) {
                    guard let encoded = component.data(using: .macOSRoman), !encoded.isEmpty else {
                        throw LegacyFileTransferError.localFile("Pfad ist nicht in MacRoman darstellbar: \(component)")
                    }
                    legacy = try LegacyPath.child(parent: legacy, name: encoded)
                }
                let size = values.isRegularFile == true ? try currentRegularFileSize(child) : 0
                items.append(UploadItem(relativePath: legacy, url: child,
                                        isFolder: values.isDirectory == true, size: size))
            }
            if let error = enumerationError { throw LegacyFileTransferError.localFile(error.localizedDescription) }
            items = [items[0]] + items.dropFirst().sorted { $0.relativePath.lexicographicallyPrecedes($1.relativePath) }
        }

        guard items.count <= Int(UInt32.max) else {
            throw LegacyFileTransferError.localFile("Zu viele Einträge für einen Transfer.")
        }
        var total: UInt64 = 0
        for item in items where !item.isFolder {
            let (sum, overflow) = total.addingReportingOverflow(item.size)
            guard !overflow else { throw LegacyFileTransferError.localFile("Gesamtgröße des Uploads ist zu groß.") }
            total = sum
        }
        return (items, total)
    }

    private func sendUploadItems(stream: AuthenticatedTransferStream,
                                 items: [UploadItem],
                                 totalBytes: UInt64,
                                 progress: ((LegacyFileTransferProgress) -> Void)?,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        var envelope = Data()
        envelope.append(LegacyWire.uint32BE(UInt32(totalBytes >> 32)))
        envelope.append(LegacyWire.uint32BE(UInt32(totalBytes & 0xffffffff)))
        envelope.append(LegacyWire.uint32BE(UInt32(items.count)))
        let completed = LegacyTransferUInt64Box()

        stream.sendPayload(envelope) { envelopeResult in
            guard case .success = envelopeResult else { completion(envelopeResult); return }

            func sendItem(_ index: Int) {
                guard index < items.count else {
                    progress?(LegacyFileTransferProgress(completedBytes: completed.value, totalBytes: totalBytes))
                    completion(.success(()))
                    return
                }
                let item = items[index]
                let header: Data
                do { header = try self.encodeTransferEntry(item, includeDeclaredSize: self.session.usesModernCrypto) }
                catch { completion(.failure(error)); return }
                stream.sendPayload(header) { headerResult in
                    guard case .success = headerResult else { completion(headerResult); return }
                    if item.isFolder {
                        sendItem(index + 1)
                        return
                    }
                    let resumeBytes = self.session.usesModernCrypto ? 8 : 16
                    stream.readPayload(resumeBytes) { resumeResult in
                        do {
                            var cursor = LegacyByteCursor(try resumeResult.get())
                            let offset = try cursor.readUInt64BE()
                            let resourceOffset = self.session.usesModernCrypto ? 0 : try cursor.readUInt64BE()
                            guard offset <= item.size else {
                                throw LegacyFileTransferError.invalidTransferRecord("Resume-Position liegt hinter lokalem Dateiende")
                            }
                            guard resourceOffset == 0 else {
                                throw LegacyFileTransferError.invalidTransferRecord("Resource-Fork-Resume wird von diesem Client nicht unterstützt")
                            }
                            let remaining = item.size - offset
                            let logicalBase = completed.value + offset
                            progress?(LegacyFileTransferProgress(completedBytes: logicalBase, totalBytes: totalBytes, resumedBytes: offset))
                            var length = LegacyWire.uint64BE(remaining)
                            if !self.session.usesModernCrypto {
                                // Original operation 11 sends data-fork and resource-fork lengths.
                                length.append(LegacyWire.uint64BE(0))
                            }
                            stream.sendPayload(length) { lengthResult in
                                guard case .success = lengthResult else { completion(lengthResult); return }
                                do {
                                    let handle = try FileHandle(forReadingFrom: item.url)
                                    try handle.seek(toOffset: offset)
                                    let (checkedBase, baseOverflow) = completed.value.addingReportingOverflow(offset)
                                    guard !baseOverflow else {
                                        throw LegacyFileTransferError.invalidTransferRecord("Upload-Größenzähler überläuft")
                                    }
                                    self.sendFileBytes(stream: stream, handle: handle, remaining: remaining,
                                                       completedBase: checkedBase, total: totalBytes,
                                                       progress: progress) { bytesResult in
                                        try? handle.close()
                                        guard case .success = bytesResult else { completion(bytesResult); return }
                                        stream.sendPayload(LegacyWire.uint16BE(0)) { commentResult in
                                            guard case .success = commentResult else { completion(commentResult); return }
                                            let (sum, overflow) = completed.value.addingReportingOverflow(item.size)
                                            guard !overflow else {
                                                completion(.failure(LegacyFileTransferError.invalidTransferRecord("Upload-Größenzähler überläuft")))
                                                return
                                            }
                                            completed.value = sum
                                            sendItem(index + 1)
                                        }
                                    }
                                } catch { completion(.failure(LegacyFileTransferError.localFile(error.localizedDescription))) }
                            }
                        } catch { completion(.failure(error)) }
                    }
                }
            }
            sendItem(0)
        }
    }

    private func encodeTransferEntry(_ item: UploadItem, includeDeclaredSize: Bool) throws -> Data {
        var descriptor = Data()
        descriptor.append(try LegacyWire.string16(item.relativePath))
        descriptor.append(LegacyWire.uint32BE(item.isFolder ? Self.folderType : 0))
        descriptor.append(LegacyWire.uint32BE(item.isFolder ? Self.folderCreator : 0))
        descriptor.append(LegacyWire.uint16BE(0))
        descriptor.append(Data(repeating: 0, count: 16))
        if item.isFolder || !includeDeclaredSize {
            descriptor.append(LegacyWire.uint32BE(0))
        } else {
            descriptor.append(LegacyWire.uint32BE(8))
            descriptor.append(LegacyWire.uint64BE(item.size))
        }
        return descriptor
    }

    private func sendFileBytes(stream: AuthenticatedTransferStream,
                               handle: FileHandle,
                               remaining initialRemaining: UInt64,
                               completedBase: UInt64,
                               total: UInt64,
                               progress: ((LegacyFileTransferProgress) -> Void)?,
                               completion: @escaping (Result<Void, Error>) -> Void) {
        var remaining = initialRemaining
        var completed: UInt64 = 0
        func next() {
            guard remaining > 0 else { completion(.success(())); return }
            let requested = Int(min(UInt64(Self.ioChunk), remaining))
            let data = handle.readData(ofLength: requested)
            guard !data.isEmpty else {
                completion(.failure(LegacyFileTransferError.localFile("Datei endete vor der gemeldeten Größe.")))
                return
            }
            stream.sendPayload(data) { result in
                guard case .success = result else { completion(result); return }
                remaining -= UInt64(data.count)
                completed += UInt64(data.count)
                progress?(LegacyFileTransferProgress(completedBytes: completedBase + completed, totalBytes: total))
                next()
            }
        }
        next()
    }
}
