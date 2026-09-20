import Cocoa
import QuickLookUI

// MARK: - Transfers

extension ViewController {

    func updateWorkspaceTransferBarVisibility() {
        let hidden = currentWorkspace == .transfers
        workspaceTransferBar?.isHidden = hidden
        workspaceTransferBarHeightConstraint?.constant = hidden ? 0 : 42
    }

    func makeTransferBar() -> NSView {
        let container = CarrachoBackgroundView()
        container.fillColor = CarrachoTheme.elevatedCard
        let divider = CarrachoDividerView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)

        transferSummaryLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        transferSummaryLabel.textColor = CarrachoTheme.secondaryText
        transferSummaryLabel.maximumNumberOfLines = 1
        transferSummaryLabel.lineBreakMode = .byTruncatingMiddle
        transferSummaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        transferSummaryLabel.toolTip = L("Transfer summary for the active server/session")

        transferBarSpeedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        transferBarSpeedLabel.textColor = CarrachoTheme.secondaryText
        transferBarSpeedLabel.setContentHuggingPriority(.required, for: .horizontal)

        transferProgress.style = .bar
        transferProgress.isIndeterminate = false
        transferProgress.minValue = 0
        transferProgress.maxValue = 100
        transferProgress.isHidden = true
        transferProgress.widthAnchor.constraint(equalToConstant: 144).isActive = true

        let openMonitor = NSButton(title: L("Open"), target: self, action: #selector(showTransfers(_:)))
        openMonitor.controlSize = .small
        openMonitor.bezelStyle = .rounded
        openMonitor.toolTip = L("Open the detailed transfer monitor")
        openMonitor.setAccessibilityLabel(L("Open transfer monitor"))

        let stack = horizontalStack([
            transferSummaryLabel, NSView(), transferBarSpeedLabel, transferProgress, openMonitor,
        ], spacing: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 1),
        ])
        return container
    }

    func makeTransferMonitorPage() -> NSView {
        let page = CarrachoBackgroundView()
        page.fillColor = CarrachoTheme.conferenceTranscriptBackground

        let title = NSTextField(labelWithString: L("Transfers"))
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Match News: the section title/actions live on one quiet elevated strip while the
        // actual content uses the normal workspace surface below it.
        let topBar = CarrachoBackgroundView()
        topBar.fillColor = CarrachoTheme.elevatedCard
        let header = horizontalStack([title, NSView(), transferRefreshButton], spacing: 8)
        header.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(header)
        let topDivider = CarrachoDividerView()
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(topDivider)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -14),
            header.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            topDivider.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            topDivider.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),
        ])

        transferScopeControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let scopeRow = horizontalStack([transferScopeControl, NSView(), transferViewRateLabel], spacing: 12)

        let divider1 = CarrachoDividerView()
        divider1.heightAnchor.constraint(equalToConstant: 1).isActive = true
        transferSearchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        transferSearchField.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        transferFilterControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let transferActions = horizontalStack([
            transferPauseButton, transferResumeButton, transferAbortButton,
            transferRemoveButton, transferDeletePartialButton,
        ], spacing: 5)
        transferActions.setContentHuggingPriority(.required, for: .horizontal)
        transferActions.setContentCompressionResistancePriority(.required, for: .horizontal)
        let filterRow = horizontalStack([transferFilterControl, transferActions, NSView(), transferSearchField], spacing: 10)

        // Keep the table document locked to the live viewport. Otherwise the table can retain
        // its construction width and the right-hand row actions get clipped until a resize.
        let scroll = tableScroll(transferTable, tracksViewportWidth: true)
        scroll.drawsBackground = true
        scroll.backgroundColor = CarrachoTheme.conferenceTranscriptBackground
        transferTable.backgroundColor = CarrachoTheme.conferenceTranscriptBackground
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let tableHost = NSView()
        tableHost.translatesAutoresizingMaskIntoConstraints = false
        transferEmptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        tableHost.addSubview(scroll)
        tableHost.addSubview(transferEmptyStateLabel)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: tableHost.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: tableHost.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: tableHost.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: tableHost.bottomAnchor),
            transferEmptyStateLabel.centerXAnchor.constraint(equalTo: tableHost.centerXAnchor),
            transferEmptyStateLabel.centerYAnchor.constraint(equalTo: tableHost.centerYAnchor),
            transferEmptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tableHost.leadingAnchor, constant: 24),
            transferEmptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: tableHost.trailingAnchor, constant: -24),
            tableHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        func detailRow(_ title: String, _ value: NSTextField) -> NSView {
            let label = NSTextField(labelWithString: L(title))
            label.font = .systemFont(ofSize: 10.5, weight: .medium)
            label.textColor = CarrachoTheme.secondaryText
            label.widthAnchor.constraint(equalToConstant: 72).isActive = true
            label.setContentHuggingPriority(.required, for: .horizontal)
            return horizontalStack([label, value], spacing: 8)
        }
        transferShowInFinderButton.title = L("Show in Finder")
        transferShowInFinderButton.image = symbolImage("folder", fallback: NSImage.folderName)
        transferShowInFinderButton.imagePosition = .imageLeading
        let detailTop = horizontalStack([transferDetailsDisclosureButton, NSView(), transferShowInFinderButton], spacing: 8)
        let detailBody = verticalStack([
            detailRow("File", transferDetailNameLabel),
            detailRow("User", transferDetailUserLabel),
            detailRow("Server", transferDetailServerLabel),
            detailRow("Started", transferDetailStartedLabel),
            detailRow("Issue", transferDetailErrorLabel),
        ], spacing: 4)
        transferDetailsBody = detailBody
        let detailDivider = CarrachoDividerView()
        detailDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let detailsStack = verticalStack([detailDivider, detailTop, detailBody], spacing: 6)

        let cleanupDivider = CarrachoDividerView()
        cleanupDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        transferClearButton.bezelStyle = .rounded
        let cleanupRow = horizontalStack([
            transferAutoRemoveFinishedCheckbox, NSView(), transferClearButton,
        ], spacing: 10)
        let footer = horizontalStack([transferMonitorStatusLabel, NSView()], spacing: 8)

        let content = CarrachoBackgroundView()
        content.fillColor = CarrachoTheme.conferenceTranscriptBackground
        let stack = verticalStack([
            scopeRow, divider1, filterRow, tableHost,
            detailsStack, cleanupDivider, cleanupRow, footer,
        ], spacing: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])

        topBar.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(topBar)
        page.addSubview(content)
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: page.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: CarrachoTheme.workspaceHeaderHeight),
            content.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            content.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        updateTransferDetailsUI()
        return page
    }

    @objc func showTransfers(_ sender: Any?) { selectWorkspace(.transfers) }

    @objc func uploadFile(_ sender: Any?) {
        guard client.isConnected, fileTransferClient != nil, let directory = lastDirectory else { return }
        let panel = NSOpenPanel()
        panel.title = L("Upload File or Folder")
        panel.prompt = L("Upload")
        panel.message = L("Choose a file or folder to upload to the current server folder.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.enqueueUpload(localFile: url, parentPath: directory.currentPath)
        }
    }

    func enqueueUpload(localFile: URL, parentPath: Data) {
        guard client.isConnected, fileTransferClient != nil else { return }
        let operation = ClientTransferOperation.upload(localFile: localFile, parentPath: parentPath, overwrite: false)
        guard beginClientTransfer(kind: LegacyTransferKind.upload,
                                  name: localFile.lastPathComponent,
                                  detail: "\(localFile.path) → \(LegacyPath.displayString(parentPath))",
                                  operation: operation) != nil else { return }
        fileTransferLabel.stringValue = LF("Upload queued: %@", localFile.lastPathComponent)
        scheduleClientTransferQueue(refreshCapacity: true)
    }

    func scheduleClientTransferQueue(refreshCapacity: Bool) {
        guard client.isConnected, fileTransferClient != nil else { return }
        guard !queuedClientTransferIDs.isEmpty else {
            transferQueueRetryWorkItem?.cancel()
            transferQueueRetryWorkItem = nil
            refreshTransferMonitorUI()
            return
        }
        if refreshCapacity {
            refreshTransferCapacityForQueue()
        } else {
            startQueuedTransfersUsingKnownCapacity()
        }
    }

    func refreshTransferCapacityForQueue() {
        guard client.isConnected, !queuedClientTransferIDs.isEmpty else { return }
        refreshTransferCapacitySnapshot(startQueuedTransfers: true)
    }

    func refreshTransferCapacitySnapshot(startQueuedTransfers: Bool) {
        guard client.isConnected, !transferCapacityRequestInFlight else { return }
        transferCapacityRequestInFlight = true
        let target = client
        target.requestServerInfo { [weak self, weak target] result in
            guard let self, let target, self.client === target else { return }
            self.transferCapacityRequestInFlight = false
            if case let .success(info) = result {
                self.lastServerInfo = info
                if let ticks = info.uptimeTicks { self.applyRemoteServerUptimeTicks(ticks) }
            }
            if startQueuedTransfers && !self.queuedClientTransferIDs.isEmpty {
                self.startQueuedTransfersUsingKnownCapacity()
            } else {
                self.refreshTransferMonitorUI()
            }
        }
    }

    func startQueuedTransfersUsingKnownCapacity() {
        guard client.isConnected, fileTransferClient != nil else { return }
        let queued = queuedClientTransferIDs
        guard !queued.isEmpty else {
            transferQueueRetryWorkItem?.cancel()
            transferQueueRetryWorkItem = nil
            refreshTransferMonitorUI()
            return
        }

        let localActive = orderedTransferMonitorItems.filter(\.active).count
        let perUserLimit = lastServerInfo?.maxFileTransfersPerUser
            ?? lastLoginResult?.maxFileTransfersPerUser ?? 1
        let startCount = LegacyClientTransferQueueCapacity.startCount(
            queuedCount: queued.count,
            localActive: localActive,
            maxPerUser: max(1, perUserLimit),
            reportedOwnActive: lastServerInfo?.activeFileTransfersForUser,
            maxServer: lastServerInfo?.maxSimultaneousFileTransfers,
            reportedServerActive: lastServerInfo?.activeFileTransfers
        )
        if startCount > 0 {
            for id in queued.prefix(startCount) { startClientTransfer(id: id) }
        }
        refreshTransferMonitorUI()

        if !queuedClientTransferIDs.isEmpty {
            scheduleTransferQueueRetry(after: startCount > 0 ? 0.8 : 0.6)
        }
    }

    func scheduleTransferQueueRetry(after delay: TimeInterval) {
        transferQueueRetryWorkItem?.cancel()
        guard !queuedClientTransferIDs.isEmpty else { transferQueueRetryWorkItem = nil; return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.transferQueueRetryWorkItem = nil
            self.scheduleClientTransferQueue(refreshCapacity: true)
        }
        transferQueueRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func startClientTransfer(id: UUID) {
        guard client.isConnected, let transfer = fileTransferClient,
              var item = transferMonitorItems[id], item.queued,
              let operation = clientTransferOperations[id] else { return }

        let resumeAttempt = item.resumeOnStart
        item.attemptGeneration &+= 1
        if item.attemptGeneration == 0 { item.attemptGeneration = 1 }
        let generation = item.attemptGeneration
        item.active = true
        item.queued = false
        item.paused = false
        item.resumable = false
        item.resumeOnStart = false
        item.rateBytesPerSecond = nil
        item.lastProgressSampleDate = nil
        item.lastProgressBytes = item.completedBytes
        item.errorMessage = nil
        if resumeAttempt { item.resumed = true }
        item.state = resumeAttempt ? "Resuming" : "Starting"
        transferMonitorItems[id] = item
        refreshTransferMonitorUI()

        switch operation {
        case let .download(remotePath, destination):
            let task = transfer.download(remotePath: remotePath, to: destination, progress: { [weak self] progress in
                self?.updateClientTransfer(id: id, generation: generation, progress: progress)
            }) { [weak self] result in
                self?.handleDownloadCompletion(id: id, generation: generation,
                                               resumeAttempt: resumeAttempt, result: result)
            }
            if transferMonitorItems[id]?.active == true,
               transferMonitorItems[id]?.attemptGeneration == generation {
                clientTransferTasks[id] = task
                updateTransferActionButtons()
            }

        case let .downloadDirectory(remotePath, parentDirectory):
            let task = transfer.downloadDirectory(remotePath: remotePath, toParentDirectory: parentDirectory, progress: { [weak self] progress in
                self?.updateClientTransfer(id: id, generation: generation, progress: progress)
            }) { [weak self] result in
                self?.handleDownloadCompletion(id: id, generation: generation,
                                               resumeAttempt: resumeAttempt, result: result)
            }
            if transferMonitorItems[id]?.active == true,
               transferMonitorItems[id]?.attemptGeneration == generation {
                clientTransferTasks[id] = task
                updateTransferActionButtons()
            }

        case let .upload(localFile, parentPath, _):
            // Resuming uses the server-side .carracho staging file. It must never imply permission
            // to replace an already published item with the same name.
            startUploadTransfer(id: id, generation: generation, resumeAttempt: resumeAttempt,
                                transfer: transfer, localFile: localFile,
                                parentPath: parentPath, overwrite: false)
        }
    }

    func refreshDirectoryAfterUpload(parentPath: Data, localFile: URL, attempt: Int = 0) {
        guard client.isConnected else { return }
        let expectedName = localFile.lastPathComponent.data(using: .macOSRoman)
        let target = client
        let sourceKey = currentFilesSourceKey()
        target.requestDirectory(pathData: parentPath) { [weak self, weak target] result in
            guard let self, let target, self.client === target,
                  sourceKey == self.currentFilesSourceKey() else { return }
            switch result {
            case let .success(listing):
                // Only repaint the Files view when the user is still looking at the upload target.
                // An upload that finishes after navigation must not drag the UI back to its old folder.
                if self.lastDirectory?.currentPath == parentPath {
                    self.lastDirectory = listing
                    self.renderSession()
                }

                let committed = expectedName.map { name in
                    listing.entries.contains(where: { $0.name == name })
                } ?? true
                // Always take one delayed snapshot even if the name already exists. This also
                // refreshes size/timestamp correctly when an upload overwrites an existing item.
                guard (attempt == 0 || !committed), attempt < 5, self.client.isConnected else { return }

                // The classic upload stream has no final "commit complete" acknowledgement. The
                // sender can finish a few milliseconds before the server renames the .carracho
                // staging file into place. Retry the directory snapshot until that commit becomes
                // visible instead of leaving the Files view stale until the user navigates away.
                let retryDelays: [TimeInterval] = [0.08, 0.16, 0.30, 0.55, 0.90]
                let delay = retryDelays[min(attempt, retryDelays.count - 1)]
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.refreshDirectoryAfterUpload(parentPath: parentPath, localFile: localFile, attempt: attempt + 1)
                }

            case .failure:
                guard attempt < 5, self.client.isConnected else { return }
                let retryDelays: [TimeInterval] = [0.08, 0.16, 0.30, 0.55, 0.90]
                let delay = retryDelays[min(attempt, retryDelays.count - 1)]
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.refreshDirectoryAfterUpload(parentPath: parentPath, localFile: localFile, attempt: attempt + 1)
                }
            }
        }
    }

    func handleDownloadCompletion(id: UUID, generation: UInt64, resumeAttempt: Bool,
                                          result: Result<URL, Error>) {
        guard let item = transferMonitorItems[id], item.attemptGeneration == generation else { return }
        clientTransferTasks[id] = nil
        guard item.active else { return }
        switch result {
        case let .success(savedURL):
            if var current = transferMonitorItems[id] {
                current.finderURL = savedURL
                transferMonitorItems[id] = current
            }
            finishClientTransfer(id: id, state: "Completed", resumable: false)
            clientTransferOperations[id] = nil
            fileTransferLabel.stringValue = LF("Saved: %@", savedURL.lastPathComponent)
        case let .failure(error):
            handleClientTransferFailure(id: id, generation: generation, resumeAttempt: resumeAttempt,
                                        error: error, logPrefix: "Download failed")
        }
    }

    func handleClientTransferFailure(id: UUID, generation: UInt64, resumeAttempt: Bool,
                                             error: Error, logPrefix: String) {
        guard var item = transferMonitorItems[id], item.attemptGeneration == generation else { return }
        clientTransferTasks[id] = nil
        guard item.active else { return }

        // A full server historically rejects the transfer connection before a byte is sent.
        // Ask for the public capacity snapshot before declaring a zero-byte transfer broken.
        // If the limits really are full, put the same logical transfer back in our queue instead
        // of manufacturing a bogus resumable/partial entry.
        guard item.completedBytes == 0, client.isConnected else {
            if var current = transferMonitorItems[id] {
                current.errorMessage = Self.displayMessage(for: error)
                transferMonitorItems[id] = current
            }
            finishClientTransfer(id: id, state: "Interrupted · Resume available", resumable: true)
            appendLine("\n\(logPrefix): \(Self.displayMessage(for: error))")
            return
        }

        item.state = "Checking transfer queue…"
        transferMonitorItems[id] = item
        refreshTransferMonitorUI()
        let target = client
        target.requestServerInfo { [weak self, weak target] result in
            guard let self, let target, self.client === target,
                  var current = self.transferMonitorItems[id],
                  current.attemptGeneration == generation else { return }

            if case let .success(info) = result {
                self.lastServerInfo = info
                let totalFull: Bool
                if let active = info.activeFileTransfers, let maximum = info.maxSimultaneousFileTransfers {
                    totalFull = active >= maximum
                } else { totalFull = false }
                let userFull: Bool
                if let active = info.activeFileTransfersForUser, let maximum = info.maxFileTransfersPerUser {
                    userFull = active >= maximum
                } else { userFull = false }
                if totalFull || userFull {
                    current.active = false
                    current.queued = true
                    current.paused = false
                    current.resumable = false
                    current.resumeOnStart = resumeAttempt
                    current.state = "Queued"
                    self.transferMonitorItems[id] = current
                    self.refreshTransferMonitorUI()
                    self.scheduleClientTransferQueue(refreshCapacity: false)
                    return
                }
            }

            if var failed = self.transferMonitorItems[id] {
                failed.errorMessage = Self.displayMessage(for: error)
                self.transferMonitorItems[id] = failed
            }
            self.finishClientTransfer(id: id, state: "Interrupted · Resume available", resumable: true)
            self.appendLine("\n\(logPrefix): \(Self.displayMessage(for: error))")
        }
    }

    func startUploadTransfer(id: UUID, generation: UInt64, resumeAttempt: Bool,
                                     transfer: LegacyFileTransferClient, localFile: URL,
                                     parentPath: Data, overwrite: Bool) {
        let securityScoped = localFile.startAccessingSecurityScopedResource()
        let task = transfer.upload(localFile: localFile, toParentPath: parentPath, overwrite: overwrite, progress: { [weak self] progress in
            self?.updateClientTransfer(id: id, generation: generation, progress: progress)
        }) { [weak self] result in
            if securityScoped { localFile.stopAccessingSecurityScopedResource() }
            guard let self,
                  let item = self.transferMonitorItems[id],
                  item.attemptGeneration == generation else { return }
            self.clientTransferTasks[id] = nil
            guard item.active else { return }
            switch result {
            case .success:
                self.finishClientTransfer(id: id, state: "Completed", resumable: false)
                self.clientTransferOperations[id] = nil
                self.fileTransferLabel.stringValue = LF("Upload completed: %@", localFile.lastPathComponent)
                self.refreshDirectoryAfterUpload(parentPath: parentPath, localFile: localFile)
            case let .failure(error as LegacyFileTransferError):
                if case .uploadConflict = error {
                    let message = LF("%@ already exists on the server. Upload it again with a different name.", localFile.lastPathComponent)
                    if var failed = self.transferMonitorItems[id] {
                        failed.errorMessage = message
                        self.transferMonitorItems[id] = failed
                    }
                    self.finishClientTransfer(id: id, state: "Failed", resumable: false)
                    self.clientTransferOperations[id] = nil
                    self.fileTransferLabel.stringValue = message
                    self.appendLine("\n" + LF("Upload failed: %@", message))
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = L("Upload failed")
                    alert.informativeText = message
                    alert.addButton(withTitle: L("OK"))
                    if let window = self.view.window { alert.beginSheetModal(for: window) }
                    else { alert.runModal() }
                } else {
                    self.handleClientTransferFailure(id: id, generation: generation, resumeAttempt: resumeAttempt,
                                                     error: error, logPrefix: "Upload failed")
                }
            case let .failure(error):
                self.handleClientTransferFailure(id: id, generation: generation, resumeAttempt: resumeAttempt,
                                                 error: error, logPrefix: "Upload failed")
            }
        }
        if transferMonitorItems[id]?.active == true,
           transferMonitorItems[id]?.attemptGeneration == generation {
            clientTransferTasks[id] = task
            updateTransferActionButtons()
        }
    }

    func serverPath(for operation: ClientTransferOperation) -> Data? {
        switch operation {
        case let .download(remotePath, _), let .downloadDirectory(remotePath, _):
            return remotePath
        case let .upload(localFile, parentPath, _):
            guard let name = localFile.lastPathComponent.data(using: .macOSRoman) else { return nil }
            return try? LegacyPath.child(parent: parentPath, name: name)
        }
    }

    func localTransferUserMatchesRemote(_ item: ClientTransferMonitorItem, remoteUserID: UInt32) -> Bool {
        if item.userID == remoteUserID { return true }
        return lastLoginResult?.session.userID == remoteUserID
    }

    func managedTransferRepresentingLocal(_ item: ClientTransferMonitorItem) -> LegacyManagedTransferRecord? {
        guard item.active, let operation = clientTransferOperations[item.id],
              let path = serverPath(for: operation) else { return nil }
        return remoteManagedTransferSnapshot.first { managed in
            localTransferUserMatchesRemote(item, remoteUserID: managed.userID) &&
                managed.kind == item.kind && managed.path == path
        }
    }

    func localTransferRepresentingManaged(_ managed: LegacyManagedTransferRecord) -> UUID? {
        transferMonitorOrder.first { id in
            guard let item = transferMonitorItems[id],
                  item.active || item.queued || item.paused || item.resumable,
                  localTransferUserMatchesRemote(item, remoteUserID: managed.userID),
                  item.kind == managed.kind,
                  let operation = clientTransferOperations[id],
                  let path = serverPath(for: operation) else { return false }
            return path == managed.path
        }
    }

    func transferRowKey(_ row: TransferMonitorRow) -> TransferMonitorRowKey {
        switch row {
        case let .local(item): return .local(item.id)
        case let .managed(item): return .managed(item.transferID)
        case let .legacyServer(item): return .legacy(kind: item.kind, userID: item.userID, path: item.path)
        }
    }

    func currentTransferRow(for key: TransferMonitorRowKey) -> TransferMonitorRow? {
        switch key {
        case let .local(id):
            return transferMonitorItems[id].map(TransferMonitorRow.local)
        case let .managed(id):
            return remoteManagedTransferSnapshot.first(where: { $0.transferID == id }).map(TransferMonitorRow.managed)
        case let .legacy(kind, userID, path):
            return remoteTransferSnapshot.first(where: { $0.kind == kind && $0.userID == userID && $0.path == path }).map(TransferMonitorRow.legacyServer)
        }
    }

    func transferStatusCategory(_ row: TransferMonitorRow) -> TransferMonitorStatusCategory {
        switch row {
        case let .local(item):
            if item.active { return .active }
            if item.queued || item.state.hasPrefix("Checking transfer queue") || item.state.hasPrefix("Waiting for overwrite") {
                return .waiting
            }
            if item.paused { return .paused }
            if item.state == "Completed" { return .completed }
            if item.state == "Cancelled" || item.state.hasPrefix("Stopped") { return .cancelled }
            if item.state.hasPrefix("Interrupted") || item.resumable { return .interrupted }
            if item.state.localizedCaseInsensitiveContains("fail") || item.errorMessage != nil { return .failed }
            return .failed
        case let .managed(item):
            if item.isAborting { return .cancelled }
            if item.isPaused { return .paused }
            return .active
        case .legacyServer:
            return .active
        }
    }

    func transferRowMatchesFilter(_ row: TransferMonitorRow) -> Bool {
        switch transferMonitorFilter {
        case .all: return true
        case .active: return transferStatusCategory(row) == .active
        case .waiting: return transferStatusCategory(row) == .waiting
        case .paused: return transferStatusCategory(row) == .paused
        case .finished: return transferStatusCategory(row) == .completed
        }
    }

    func transferRowMatchesSearch(_ row: TransferMonitorRow) -> Bool {
        let query = transferMonitorSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let haystack = [
            transferRowName(row), transferRowUserName(row), transferRowServerName(row),
            transferRowStatus(row), transferRowServerPath(row),
        ].joined(separator: " ")
        return haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    func transferRowUserName(_ row: TransferMonitorRow) -> String {
        switch row {
        case let .local(item):
            if !item.userNickname.isEmpty { return item.userNickname }
            if let userID = item.userID, let user = liveUsers[userID] { return Self.macRomanString(user.nickname) }
            return item.userID == nil ? L("You") : L("Unknown User")
        case let .managed(item):
            return liveUsers[item.userID].map { Self.macRomanString($0.nickname) } ?? L("Unknown User")
        case let .legacyServer(item):
            return liveUsers[item.userID].map { Self.macRomanString($0.nickname) } ?? L("Unknown User")
        }
    }

    func transferRowKind(_ row: TransferMonitorRow) -> UInt8 {
        switch row {
        case let .local(item): return item.kind
        case let .managed(item): return item.kind
        case let .legacyServer(item): return item.kind
        }
    }

    func transferRowName(_ row: TransferMonitorRow) -> String {
        switch row {
        case let .local(item):
            let leaf = NSString(string: item.name).lastPathComponent
            return leaf.isEmpty ? item.name : leaf
        case let .managed(item): return LegacyPath.displayName(item.path)
        case let .legacyServer(item): return LegacyPath.displayName(item.path)
        }
    }

    func transferRowServerPath(_ row: TransferMonitorRow) -> String {
        switch row {
        case let .local(item):
            guard let operation = clientTransferOperations[item.id], let path = serverPath(for: operation) else { return "" }
            return LegacyPath.displayString(path)
        case let .managed(item): return LegacyPath.displayString(item.path)
        case let .legacyServer(item): return LegacyPath.displayString(item.path)
        }
    }

    func transferRowServerName(_ row: TransferMonitorRow) -> String {
        switch row {
        case let .local(item): return item.serverName
        case .managed, .legacyServer: return currentTransferServerName
        }
    }

    func transferRowCompletedAndTotal(_ row: TransferMonitorRow) -> (completed: UInt64, total: UInt64) {
        switch row {
        case let .local(item): return (item.completedBytes, item.totalBytes)
        case let .managed(item): return (item.bytesTransferred, item.totalBytes)
        case let .legacyServer(item): return (item.bytesTransferred, item.totalBytes)
        }
    }

    func transferRowProgress(_ row: TransferMonitorRow) -> Double {
        let values = transferRowCompletedAndTotal(row)
        guard values.total > 0 else { return Double(values.completed) }
        return Double(values.completed) / Double(values.total)
    }

    func transferRowRate(_ row: TransferMonitorRow) -> UInt64? {
        switch row {
        case let .local(item): return item.rateBytesPerSecond
        case .managed, .legacyServer: return transferRemoteRatesByKey[transferRowKey(row)]
        }
    }

    func transferRowStartedValue(_ row: TransferMonitorRow) -> Double {
        switch row {
        case let .local(item): return item.startedAt.timeIntervalSinceReferenceDate
        case let .managed(item): return Double(item.transferID)
        case .legacyServer: return 0
        }
    }

    func clientTransferQueuePosition(id: UUID) -> (position: Int, total: Int)? {
        let queued = queuedClientTransferIDs
        guard let index = queued.firstIndex(of: id) else { return nil }
        return (index + 1, queued.count)
    }

    func localizedTransferState(_ state: String) -> String {
        switch state {
        case "Starting": return L("Starting")
        case "Resuming": return L("Resuming")
        case "Queued": return L("Queued")
        case "Waiting for overwrite confirmation": return L("Waiting for overwrite confirmation")
        case "Transferring": return L("Transferring")
        case "Transferring · Resumed": return L("Transferring · Resumed")
        case "Paused · Resume available": return L("Paused · Resume available")
        case "Interrupted": return L("Interrupted")
        case "Interrupted · Resume available": return L("Interrupted · Resume available")
        case "Interrupted · reconnect to resume": return L("Interrupted · reconnect to resume")
        case "Completed": return L("Completed")
        case "Cancelled": return L("Cancelled")
        case "Failed": return L("Failed")
        case "Checking transfer queue…": return L("Checking transfer queue…")
        case "Stopped · Resume available": return L("Stopped · Resume available")
        default: return state
        }
    }

    func transferRowStatus(_ row: TransferMonitorRow) -> String {
        switch row {
        case let .local(item):
            if item.queued, let queue = clientTransferQueuePosition(id: item.id) {
                return LF("Waiting · %@/%@", String(queue.position), String(queue.total))
            }
            return localizedTransferState(item.state)
        case let .managed(item): return item.isAborting ? L("Aborting") : (item.isPaused ? L("Paused") : L("Transferring"))
        case .legacyServer: return L("Transferring")
        }
    }

    func selectedTransferRows() -> [TransferMonitorRow] {
        selectedTransferKeys.compactMap(currentTransferRow(for:))
    }

    func primarySelectedTransferRow() -> TransferMonitorRow? {
        let rows = transferMonitorRows
        let row = transferTable.selectedRow
        if row >= 0, row < rows.count { return rows[row] }
        if let key = selectedTransferKeys.first { return currentTransferRow(for: key) }
        return nil
    }

    func selectTransferRow(_ key: TransferMonitorRowKey, extending: Bool = false) {
        guard let row = transferMonitorRows.firstIndex(where: { transferRowKey($0) == key }) else { return }
        isReloadingTransferTable = true
        transferTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: extending)
        isReloadingTransferTable = false
        if extending { selectedTransferKeys.insert(key) }
        else { selectedTransferKeys = [key] }
        updatePrimaryTransferSelectionFromTable()
        updateTransferActionButtons()
        updateTransferDetailsUI()
    }

    func updatePrimaryTransferSelectionFromTable() {
        let rows = transferMonitorRows
        selectedTransferID = nil
        selectedRemoteTransferID = nil
        guard transferTable.selectedRow >= 0, transferTable.selectedRow < rows.count else { return }
        switch rows[transferTable.selectedRow] {
        case let .local(item): selectedTransferID = item.id
        case let .managed(item): selectedRemoteTransferID = item.transferID
        case .legacyServer: break
        }
    }

    @objc func transferScopeChanged(_ sender: NSSegmentedControl) {
        guard let scope = TransferMonitorScope(rawValue: sender.selectedSegment) else { return }
        if scope == .serverWide, !canManageRemoteTransfers {
            NSSound.beep()
            transferScopeControl.selectedSegment = TransferMonitorScope.mine.rawValue
            transferMonitorScope = .mine
        } else {
            transferMonitorScope = scope
        }
        selectedTransferKeys.removeAll()
        selectedTransferID = nil
        selectedRemoteTransferID = nil
        transferTable.deselectAll(nil)
        if transferMonitorScope == .serverWide { refreshRemoteTransferInfo(nil) }
        refreshTransferMonitorUI()
    }

    @objc func transferFilterChanged(_ sender: NSSegmentedControl) {
        guard let filter = TransferMonitorFilter(rawValue: sender.selectedSegment) else { return }
        transferMonitorFilter = filter
        refreshTransferMonitorUI()
    }

    @objc func transferSearchChanged(_ sender: NSSearchField) {
        transferMonitorSearchQuery = sender.stringValue
        refreshTransferMonitorUI()
    }

    @objc func refreshTransferMonitorPressed(_ sender: Any?) {
        guard client.isConnected else {
            refreshTransferMonitorUI()
            return
        }
        refreshTransferCapacitySnapshot(startQueuedTransfers: !queuedClientTransferIDs.isEmpty)
        if transferMonitorScope == .serverWide, canManageRemoteTransfers { refreshRemoteTransferInfo(nil) }
        else { refreshTransferMonitorUI() }
    }

    @objc func toggleTransferDetails(_ sender: Any?) {
        transferDetailsCollapsed.toggle()
        updateTransferDetailsUI()
    }

    @objc func transferRowDoubleClicked(_ sender: Any?) {
        let rowIndex = transferTable.clickedRow >= 0 ? transferTable.clickedRow : transferTable.selectedRow
        guard rowIndex >= 0, rowIndex < transferMonitorRows.count else { return }
        let row = transferMonitorRows[rowIndex]
        let key = transferRowKey(row)
        selectTransferRow(key)
        if transferCanRevealLocal(row) {
            showSelectedTransferInFinder(sender)
        } else {
            transferDetailsCollapsed = false
            updateTransferDetailsUI()
        }
    }

    func transferCanRevealLocal(_ row: TransferMonitorRow) -> Bool {
        guard case let .local(item) = row, let url = item.finderURL else { return false }
        return FileManager.default.fileExists(atPath: url.standardizedFileURL.path)
    }

    func transferLocationDescription(_ row: TransferMonitorRow) -> String {
        switch row {
        case let .local(item):
            if !item.detail.isEmpty { return item.detail }
            if let url = item.finderURL { return url.standardizedFileURL.path }
            return transferRowServerPath(row)
        case .managed, .legacyServer:
            let path = transferRowServerPath(row)
            return path.isEmpty ? L("Not reported by server") : path
        }
    }

    func transferIssueDescription(_ row: TransferMonitorRow) -> String {
        switch row {
        case let .local(item):
            if let error = item.errorMessage, !error.isEmpty { return error }
            switch transferStatusCategory(row) {
            case .interrupted, .failed, .cancelled: return localizedTransferState(item.state)
            default: return "—"
            }
        case let .managed(item):
            return item.isAborting ? L("Server is aborting this transfer.") : "—"
        case .legacyServer:
            return "—"
        }
    }

    func updateTransferDetailsUI() {
        transferDetailsDisclosureButton.image = symbolImage(transferDetailsCollapsed ? "chevron.right" : "chevron.down",
                                                            fallback: NSImage.touchBarGoDownTemplateName)
        guard let row = primarySelectedTransferRow() else {
            transferDetailsDisclosureButton.title = L("Transfer Details")
            transferDetailsDisclosureButton.isEnabled = false
            transferDetailsBody?.isHidden = true
            transferShowInFinderButton.isHidden = true
            transferDetailNameLabel.stringValue = "—"
            transferDetailUserLabel.stringValue = "—"
            transferDetailServerLabel.stringValue = "—"
            transferDetailLocationLabel.stringValue = "—"
            transferDetailStartedLabel.stringValue = "—"
            transferDetailErrorLabel.stringValue = "—"
            return
        }
        transferDetailsDisclosureButton.title = L("Transfer Details")
        transferDetailsDisclosureButton.isEnabled = true
        transferDetailsBody?.isHidden = transferDetailsCollapsed
        transferDetailNameLabel.stringValue = transferRowName(row)
        transferDetailNameLabel.toolTip = transferRowName(row)
        transferDetailUserLabel.stringValue = transferRowUserName(row)
        transferDetailServerLabel.stringValue = transferRowServerName(row)
        let location = transferLocationDescription(row)
        transferDetailLocationLabel.stringValue = location
        transferDetailLocationLabel.toolTip = location
        switch row {
        case let .local(item):
            transferDetailStartedLabel.stringValue = Self.dateString(item.startedAt)
        case .managed, .legacyServer:
            transferDetailStartedLabel.stringValue = L("Not reported by server")
        }
        let issue = transferIssueDescription(row)
        transferDetailErrorLabel.stringValue = issue
        transferDetailErrorLabel.textColor = issue == "—" ? CarrachoTheme.secondaryText : .systemRed
        transferShowInFinderButton.isHidden = !transferCanRevealLocal(row)
        transferShowInFinderButton.isEnabled = transferCanRevealLocal(row)
    }

    func updateTransferFilterLabels() {
        let rows = transferRowsMatchingSearch
        let active = rows.filter { transferStatusCategory($0) == .active }.count
        let waiting = rows.filter { transferStatusCategory($0) == .waiting }.count
        let paused = rows.filter { transferStatusCategory($0) == .paused }.count
        let finished = rows.filter { transferStatusCategory($0) == .completed }.count
        let labels = [
            "\(L("All")) \(rows.count)", "\(L("Active")) \(active)",
            "\(L("Waiting")) \(waiting)", "\(L("Paused")) \(paused)",
            "\(L("Finished")) \(finished)",
        ]
        for (index, title) in labels.enumerated() where index < transferFilterControl.segmentCount {
            transferFilterControl.setLabel(title, forSegment: index)
        }
    }

    func updateTransferScopeAvailability() {
        let serverWideAvailable = canManageRemoteTransfers
        transferScopeControl.setEnabled(serverWideAvailable, forSegment: TransferMonitorScope.serverWide.rawValue)
        if !serverWideAvailable, transferMonitorScope == .serverWide {
            transferMonitorScope = .mine
            transferScopeControl.selectedSegment = TransferMonitorScope.mine.rawValue
        }
        transferRefreshButton.isEnabled = client.isConnected
    }

    func updateTransferEmptyState() {
        let visible = transferMonitorRows
        let base = transferScopeRows
        transferEmptyStateLabel.isHidden = !visible.isEmpty
        guard visible.isEmpty else { return }
        if !client.isConnected {
            transferEmptyStateLabel.stringValue = L("Not connected\nConnect to a server to start or inspect transfers.")
        } else if transferMonitorScope == .serverWide, !canManageRemoteTransfers {
            transferEmptyStateLabel.stringValue = L("Server-wide transfer monitoring is not available for this account.")
        } else if !transferMonitorSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    (transferMonitorFilter != .all && !base.isEmpty) {
            transferEmptyStateLabel.stringValue = L("No matching transfers")
        } else if transferMonitorScope == .serverWide {
            transferEmptyStateLabel.stringValue = L("No active server-wide transfers\nThis view is a live active-transfer snapshot, not a transfer history.")
        } else {
            transferEmptyStateLabel.stringValue = L("No transfers yet")
        }
    }

    func updateTransferRateSummary() {
        let rows = transferScopeRows
        var download: UInt64 = 0
        var upload: UInt64 = 0
        for row in rows where transferStatusCategory(row) == .active {
            let rate = transferRowRate(row) ?? 0
            if transferRowKind(row) == LegacyTransferKind.download { download &+= rate }
            else if transferRowKind(row) == LegacyTransferKind.upload { upload &+= rate }
        }
        if transferMonitorScope == .serverWide, let reported = remoteDownloadTrafficBytesPerSecond {
            download = reported
        }
        let prefix = transferMonitorScope == .mine ? L("This Mac") : L("Server-wide")
        transferViewRateLabel.stringValue = "\(prefix)  ↓ \(Self.transferRateDisplay(download))   ↑ \(Self.transferRateDisplay(upload))"
        transferViewRateLabel.toolTip = transferMonitorScope == .serverWide
            ? L("Download is server outbound traffic; upload is traffic received by the server.")
            : L("Download is traffic to this Mac; upload is traffic sent from this Mac.")
    }

    func transferCanPause(_ row: TransferMonitorRow) -> Bool {
        switch row {
        case let .local(item): return item.queued || (item.active && clientTransferTasks[item.id] != nil)
        case let .managed(item): return canManageRemoteTransfers && !item.isPaused && !item.isAborting
        case .legacyServer: return false
        }
    }

    func transferCanResume(_ row: TransferMonitorRow) -> Bool {
        switch row {
        case let .local(item):
            return client.isConnected && fileTransferClient != nil && clientTransferOperations[item.id] != nil &&
                !item.active && !item.queued && (item.paused || item.resumable) &&
                !item.state.hasPrefix("Waiting for overwrite")
        case let .managed(item): return canManageRemoteTransfers && item.isPaused && !item.isAborting
        case .legacyServer: return false
        }
    }

    func transferCanAbort(_ row: TransferMonitorRow) -> Bool {
        switch row {
        case let .local(item):
            return clientTransferOperations[item.id] != nil && (item.active || item.queued || item.paused || item.resumable)
        case let .managed(item): return canManageRemoteTransfers && !item.isAborting
        case .legacyServer: return false
        }
    }

    func duplicateClientTransferID(kind: UInt8, operation: ClientTransferOperation) -> UUID? {
        guard let path = serverPath(for: operation) else { return nil }
        return transferMonitorOrder.first { id in
            guard let item = transferMonitorItems[id], item.kind == kind,
                  item.active || item.queued || item.paused || item.resumable,
                  let existing = clientTransferOperations[id],
                  let existingPath = serverPath(for: existing) else { return false }
            return existingPath == path
        }
    }

    @discardableResult
    func beginClientTransfer(kind: UInt8, name: String, detail: String,
                                     operation: ClientTransferOperation) -> UUID? {
        if let duplicateID = duplicateClientTransferID(kind: kind, operation: operation) {
            selectedTransferID = duplicateID
            selectedRemoteTransferID = nil
            let duplicateName = transferMonitorItems[duplicateID]?.name ?? name
            fileTransferLabel.stringValue = LF("Already queued or active: %@", duplicateName)
            refreshTransferMonitorUI()
            return nil
        }

        let id = UUID()
        let ownUserID = lastLoginResult?.session.userID
        let ownUser = ownUserID.flatMap { liveUsers[$0] }
        let ownNickname = ownUser.map { Self.macRomanString($0.nickname) }
            ?? nicknameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let finderURL: URL?
        switch operation {
        case let .download(_, destination): finderURL = destination
        case .downloadDirectory: finderURL = nil
        case let .upload(localFile, _, _): finderURL = localFile
        }
        transferMonitorItems[id] = ClientTransferMonitorItem(id: id, kind: kind, userID: ownUserID,
                                                             userNickname: ownNickname.isEmpty ? L("You") : ownNickname,
                                                             userPicture: ownUser?.picture ?? Data(),
                                                             serverName: currentTransferServerName,
                                                             name: name, detail: detail, finderURL: finderURL,
                                                             completedBytes: 0, totalBytes: 0,
                                                             state: "Queued", active: false, queued: true,
                                                             paused: false, resumable: false,
                                                             resumed: false, resumeOnStart: false,
                                                             attemptGeneration: 0, startedAt: Date())
        clientTransferOperations[id] = operation
        transferMonitorOrder.insert(id, at: 0)
        selectedTransferID = id
        selectedRemoteTransferID = nil
        trimTransferHistory()
        refreshTransferMonitorUI()
        updateFileTransferButtons()
        return id
    }

    /// Transfer callbacks can arrive many times per second. Keep the model current, but redraw
    /// rate/ETA/progress at most once per second so the transfer UI remains visually stable.
    func scheduleTransferProgressUIRefresh(now: Date = Date()) {
        let interval: TimeInterval = 1.0
        let elapsed = now.timeIntervalSince(transferProgressUIRefreshDate)
        if elapsed >= interval {
            transferProgressUIRefreshWorkItem?.cancel()
            transferProgressUIRefreshWorkItem = nil
            transferProgressUIRefreshDate = now
            refreshTransferMonitorUI()
            return
        }
        guard transferProgressUIRefreshWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.transferProgressUIRefreshWorkItem = nil
            self.transferProgressUIRefreshDate = Date()
            self.refreshTransferMonitorUI()
        }
        transferProgressUIRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, interval - elapsed), execute: work)
    }

    func updateClientTransfer(id: UUID, generation: UInt64, progress: LegacyFileTransferProgress) {
        guard var item = transferMonitorItems[id], item.active,
              item.attemptGeneration == generation else { return }
        let now = Date()
        if let previousDate = item.lastProgressSampleDate {
            let elapsed = now.timeIntervalSince(previousDate)
            if elapsed >= 1.0, progress.completedBytes >= item.lastProgressBytes {
                item.rateBytesPerSecond = UInt64(Double(progress.completedBytes - item.lastProgressBytes) / elapsed)
                item.lastProgressSampleDate = now
                item.lastProgressBytes = progress.completedBytes
            }
        } else {
            item.lastProgressSampleDate = now
            item.lastProgressBytes = progress.completedBytes
        }
        item.completedBytes = progress.completedBytes
        item.totalBytes = progress.totalBytes
        item.errorMessage = nil
        if progress.resumedBytes > 0 { item.resumed = true }
        item.state = item.resumed ? "Transferring · Resumed" : "Transferring"
        transferMonitorItems[id] = item
        scheduleTransferProgressUIRefresh(now: now)
    }

    func setClientTransferWaiting(id: UUID, state: String) {
        guard var item = transferMonitorItems[id] else { return }
        item.state = state
        item.active = false
        item.queued = false
        item.paused = false
        item.resumable = true
        item.resumeOnStart = true
        transferMonitorItems[id] = item
        refreshTransferMonitorUI()
        scheduleClientTransferQueue(refreshCapacity: true)
    }

    func finishClientTransfer(id: UUID, state: String, resumable: Bool = false) {
        guard var item = transferMonitorItems[id] else { return }
        item.state = state
        item.active = false
        item.queued = false
        item.paused = false
        item.resumable = resumable
        item.resumeOnStart = resumable
        item.rateBytesPerSecond = nil
        item.lastProgressSampleDate = nil
        if state == "Completed" {
            item.errorMessage = nil
            if item.totalBytes > 0 { item.completedBytes = item.totalBytes }
            emitClientEvent(.transferCompleted,
                            notificationTitle: L("File transfer completed"),
                            notificationBody: LF("%@ was transferred successfully.", item.name))
        }
        transferMonitorItems[id] = item

        if state == "Completed" && transferAutoRemoveFinishedCheckbox.state == .on {
            removeFinishedTransferIDs([id])
        } else {
            trimTransferHistory()
        }
        refreshTransferMonitorUI()
        updateFileTransferButtons()
        if !queuedClientTransferIDs.isEmpty { scheduleTransferQueueRetry(after: 0.15) }
    }

    func queueClientTransfer(id: UUID, resume: Bool) {
        guard client.isConnected, fileTransferClient != nil,
              var item = transferMonitorItems[id], clientTransferOperations[id] != nil else { return }
        item.active = false
        item.queued = true
        item.paused = false
        item.resumable = false
        item.resumeOnStart = resume
        item.rateBytesPerSecond = nil
        item.errorMessage = nil
        item.state = "Queued"
        transferMonitorItems[id] = item
        refreshTransferMonitorUI()
        scheduleClientTransferQueue(refreshCapacity: true)
    }

    @objc func pauseSelectedTransfer(_ sender: Any?) {
        let rows = selectedTransferRows().filter(transferCanPause)
        guard !rows.isEmpty else { return }
        for row in rows {
            switch row {
            case let .managed(managed):
                controlRemoteTransfer(managed, action: .pause, failureTitle: L("Transfer could not be paused"))
            case let .local(selected):
                guard var item = transferMonitorItems[selected.id], clientTransferOperations[item.id] != nil else { continue }
                if item.queued {
                    item.queued = false
                    item.paused = true
                    item.resumable = true
                    item.rateBytesPerSecond = nil
                    item.state = "Paused · Resume available"
                    transferMonitorItems[item.id] = item
                    continue
                }
                guard item.active, let task = clientTransferTasks.removeValue(forKey: item.id) else { continue }
                item.attemptGeneration &+= 1
                if item.attemptGeneration == 0 { item.attemptGeneration = 1 }
                item.active = false
                item.queued = false
                item.paused = true
                item.resumable = true
                item.resumeOnStart = true
                item.rateBytesPerSecond = nil
                item.state = "Paused · Resume available"
                transferMonitorItems[item.id] = item
                task.cancel()
            case .legacyServer:
                break
            }
        }
        refreshTransferMonitorUI()
        scheduleClientTransferQueue(refreshCapacity: true)
        scheduleTransferQueueRetry(after: 0.15)
    }

    @objc func resumeSelectedTransfer(_ sender: Any?) {
        let rows = selectedTransferRows().filter(transferCanResume)
        guard !rows.isEmpty else { return }
        for row in rows {
            switch row {
            case let .managed(managed):
                controlRemoteTransfer(managed, action: .resume, failureTitle: L("Transfer could not be resumed"))
            case let .local(item):
                queueClientTransfer(id: item.id, resume: item.resumeOnStart)
            case .legacyServer:
                break
            }
        }
    }

    @objc func abortSelectedRemoteTransfer(_ sender: Any?) {
        let rows = selectedTransferRows().filter(transferCanAbort)
        guard !rows.isEmpty else { return }
        let action = { [weak self] in
            guard let self else { return }
            for row in rows { self.abortTransferWithoutConfirmation(row) }
            self.refreshTransferMonitorUI()
            self.scheduleTransferQueueRetry(after: 0.15)
        }
        guard let window = view.window else { action(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = rows.count == 1 ? L("Abort Transfer?") : LF("Abort %@ Transfers?", String(rows.count))
        alert.informativeText = L("This stops the selected transfer operation. Partial data is not deleted and remains resumable where the transfer protocol supports it.")
        alert.addButton(withTitle: rows.count == 1 ? L("Abort Transfer") : L("Abort Transfers"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { action() }
        }
    }

    func abortTransferWithoutConfirmation(_ row: TransferMonitorRow) {
        switch row {
        case let .managed(managed):
            guard !managed.isAborting else { return }
            controlRemoteTransfer(managed, action: .abort, failureTitle: L("Transfer could not be aborted"))
        case let .local(selected):
            guard var item = transferMonitorItems[selected.id], clientTransferOperations[item.id] != nil else { return }
            item.attemptGeneration &+= 1
            if item.attemptGeneration == 0 { item.attemptGeneration = 1 }
            let task = clientTransferTasks.removeValue(forKey: item.id)
            let wasQueuedOnly = item.queued && item.completedBytes == 0 && !item.resumeOnStart
            item.active = false
            item.queued = false
            item.paused = false
            item.rateBytesPerSecond = nil
            if wasQueuedOnly {
                item.resumable = false
                item.resumeOnStart = false
                item.state = "Cancelled"
                clientTransferOperations[item.id] = nil
            } else {
                item.resumable = true
                item.resumeOnStart = true
                item.state = "Stopped · Resume available"
            }
            transferMonitorItems[item.id] = item
            task?.cancel()
        case .legacyServer:
            break
        }
    }

    func controlRemoteTransfer(_ transfer: LegacyManagedTransferRecord, action: LegacyTransferControlAction,
                                       failureTitle: String) {
        guard client.isConnected, canManageRemoteTransfers else { return }
        transferPauseButton.isEnabled = false
        transferResumeButton.isEnabled = false
        transferAbortButton.isEnabled = false
        client.controlTransfer(transferID: transfer.transferID, action: action) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(snapshot):
                self.applyRemoteTransferMonitor(snapshot)
                if action == .abort {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.refreshRemoteTransferInfo(nil) }
                }
            case let .failure(error):
                self.updateTransferActionButtons()
                self.showError(LF("%@: %@", failureTitle, Self.displayMessage(for: error)))
            }
        }
    }

    func primarySelectedLocalTransfer() -> ClientTransferMonitorItem? {
        guard let row = primarySelectedTransferRow(), case let .local(item) = row else { return nil }
        return transferMonitorItems[item.id]
    }

    @objc func showSelectedTransferInFinder(_ sender: Any?) {
        guard let item = primarySelectedLocalTransfer(), let finderURL = item.finderURL else { return }
        let url = finderURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            showError(LF("The local file or folder is no longer available at %@.", url.path))
            updateTransferActionButtons()
            updateTransferDetailsUI()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func removeSelectedTransfer(_ sender: Any?) {
        let items = selectedTransferRows().compactMap { row -> ClientTransferMonitorItem? in
            guard case let .local(item) = row else { return nil }
            return transferMonitorItems[item.id]
        }
        guard !items.isEmpty else { return }
        guard items.allSatisfy({ !$0.active && !$0.queued }) else {
            showError(L("Active or waiting transfers must be paused or aborted before their list entry can be removed."))
            return
        }
        let resumable = items.filter { $0.paused || $0.resumable || clientTransferOperations[$0.id] != nil }
        let remove = { [weak self] in
            guard let self else { return }
            let ids = Set(items.map(\.id))
            for id in ids {
                self.clientTransferTasks.removeValue(forKey: id)?.cancel()
                self.clientTransferOperations[id] = nil
                self.transferMonitorItems[id] = nil
            }
            self.transferMonitorOrder.removeAll { ids.contains($0) }
            self.selectedTransferKeys.subtract(ids.map { TransferMonitorRowKey.local($0) })
            if let selectedTransferID = self.selectedTransferID, ids.contains(selectedTransferID) { self.selectedTransferID = nil }
            self.refreshTransferMonitorUI()
        }
        guard !resumable.isEmpty, let window = view.window else { remove(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = items.count == 1 ? L("Remove Transfer from List?") : L("Remove Transfers from List?")
        alert.informativeText = L("This removes only the monitor entries and their resume metadata. Existing partial files are not deleted. Use “Delete Partial Data…” when you explicitly want to remove partial data.")
        alert.addButton(withTitle: L("Remove from List"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { remove() }
        }
    }

    @objc func deleteSelectedTransferPartialData(_ sender: Any?) {
        let items = selectedTransferRows().compactMap { row -> ClientTransferMonitorItem? in
            guard case let .local(item) = row,
                  item.state != "Completed",
                  clientTransferOperations[item.id] != nil else { return nil }
            return item
        }
        guard !items.isEmpty else { return }
        guard items.allSatisfy({ !$0.active && !$0.queued }) else {
            showError(L("Abort or pause active transfers before deleting partial data."))
            return
        }
        let needsServerConnection = items.contains { item in
            guard let operation = clientTransferOperations[item.id] else { return false }
            if case .upload = operation { return true }
            return false
        }
        guard !needsServerConnection || client.isConnected else {
            showError(L("Reconnect before deleting server-side partial upload data. The list entry has been kept."))
            return
        }
        let destroy = { [weak self] in
            guard let self else { return }
            let ids = Set(items.map(\.id))
            for item in items {
                if let operation = self.clientTransferOperations[item.id] { self.discardPartialData(for: operation) }
                self.clientTransferOperations[item.id] = nil
                self.transferMonitorItems[item.id] = nil
            }
            self.transferMonitorOrder.removeAll { ids.contains($0) }
            self.selectedTransferKeys.subtract(ids.map { TransferMonitorRowKey.local($0) })
            self.refreshTransferMonitorUI()
        }
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = items.count == 1 ? L("Delete Partial Data?") : LF("Delete Partial Data for %@ Transfers?", String(items.count))
        alert.informativeText = L("This destructive action deletes incomplete local download staging data or the corresponding server-side upload staging data. The original completed source file is not deleted.")
        alert.addButton(withTitle: L("Delete Partial Data"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { destroy() }
        }
    }

    func discardPartialData(for operation: ClientTransferOperation) {
        switch operation {
        case let .download(_, destination):
            let parent = destination.deletingLastPathComponent()
            let partial = parent.appendingPathComponent("\(destination.lastPathComponent).carracho")
            let legacyPartial = parent.appendingPathComponent(".carracho.\(destination.lastPathComponent)")
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.removeItem(at: legacyPartial)

        case let .downloadDirectory(remotePath, parentDirectory):
            let nameData: Data
            if let separator = remotePath.lastIndex(of: LegacyPath.separator) {
                nameData = Data(remotePath[remotePath.index(after: separator)...])
            } else {
                nameData = remotePath
            }
            if let name = String(data: nameData, encoding: .macOSRoman), !name.isEmpty {
                let staging = parentDirectory.appendingPathComponent("\(name).carracho", isDirectory: true)
                let legacyStaging = parentDirectory.appendingPathComponent(".carracho.\(name)", isDirectory: true)
                try? FileManager.default.removeItem(at: staging)
                try? FileManager.default.removeItem(at: legacyStaging)
            }

        case let .upload(localFile, parentPath, _):
            guard client.isConnected,
                  let partialName = "\(localFile.lastPathComponent).carracho".data(using: .macOSRoman),
                  let partialPath = try? LegacyPath.child(parent: parentPath, name: partialName) else { return }
            client.deleteFile(path: partialPath) { [weak self] result in
                if case let .failure(error) = result {
                    self?.appendLine("\n" + LF("Partial upload data could not be removed from the server: %@", Self.displayMessage(for: error)))
                }
            }
        }
    }

    func trimTransferHistory() {
        guard transferMonitorOrder.count > 100 else { return }
        let removable = transferMonitorOrder.dropFirst(100).filter { id in
            guard let item = transferMonitorItems[id] else { return true }
            return item.state == "Completed"
        }
        for id in removable {
            transferMonitorItems[id] = nil
            clientTransferOperations[id] = nil
            clientTransferTasks[id] = nil
        }
        transferMonitorOrder.removeAll { transferMonitorItems[$0] == nil }
    }

    func removeFinishedTransferIDs(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        for id in idSet {
            transferMonitorItems[id] = nil
            clientTransferOperations[id] = nil
            clientTransferTasks[id] = nil
        }
        transferMonitorOrder.removeAll { idSet.contains($0) || transferMonitorItems[$0] == nil }
        selectedTransferKeys.subtract(idSet.map { TransferMonitorRowKey.local($0) })
        if let selectedTransferID, idSet.contains(selectedTransferID) { self.selectedTransferID = nil }
    }

    @objc func clearFinishedTransfers(_ sender: Any?) {
        let finished = transferMonitorOrder.filter { id in
            guard let item = transferMonitorItems[id] else { return false }
            return item.state == "Completed"
        }
        removeFinishedTransferIDs(finished)
        refreshTransferMonitorUI()
    }

    @objc func transferAutoRemoveFinishedChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: Self.transferAutoRemoveFinishedDefaultsKey)
        if enabled { clearFinishedTransfers(nil) }
    }

    func refreshTransferMonitorUI() {
        updateTransferScopeAvailability()
        if selectedTransferKeys.isEmpty {
            if let selectedTransferID { selectedTransferKeys.insert(.local(selectedTransferID)) }
            if let selectedRemoteTransferID { selectedTransferKeys.insert(.managed(selectedRemoteTransferID)) }
        }

        // Preserve AppKit's actual clip-view origin. With a table header the legal top origin
        // can be negative; clamping it to zero makes the first row slide underneath the header.
        let previousScrollOrigin = transferTable.enclosingScrollView?.contentView.bounds.origin ?? .zero
        let rows = transferMonitorRows
        let rowKeys = rows.map(transferRowKey)
        let visibleKeys = Set(rowKeys)
        let keysToRestore = selectedTransferKeys.intersection(visibleKeys)
        let rowIdentityUnchanged = transferTableRowKeysSnapshot == rowKeys
            && transferTable.numberOfRows == rows.count

        var indexes = IndexSet()
        for (index, key) in rowKeys.enumerated() where keysToRestore.contains(key) {
            indexes.insert(index)
        }

        transferTableReloadGeneration &+= 1
        let reloadGeneration = transferTableReloadGeneration
        isReloadingTransferTable = true

        if rowIdentityUnchanged {
            // Progress/rate/ETA updates do not change row identity. Reload the visible model rows
            // in place so NSTableView never tears down its selection merely because a byte counter
            // changed.
            if !rows.isEmpty, transferTable.numberOfColumns > 0 {
                transferTable.reloadData(
                    forRowIndexes: IndexSet(integersIn: 0 ..< rows.count),
                    columnIndexes: IndexSet(integersIn: 0 ..< transferTable.numberOfColumns)
                )
            }
        } else {
            transferTable.reloadData()
        }

        // A full reload may clear AppKit's numeric selection even though the logical transfer keys
        // are unchanged. Reassert the key-based selection after either reload path.
        if transferTable.selectedRowIndexes != indexes {
            if indexes.isEmpty { transferTable.deselectAll(nil) }
            else { transferTable.selectRowIndexes(indexes, byExtendingSelection: false) }
        }
        transferTableRowKeysSnapshot = rowKeys
        selectedTransferKeys = keysToRestore
        updatePrimaryTransferSelectionFromTable()

        if !rowIdentityUnchanged, let scroll = transferTable.enclosingScrollView {
            // NSClipView constrains this to its real legal range, including the negative top
            // offset used while an NSTableHeaderView is present. Do not hand-clamp to 0.
            scroll.contentView.scroll(to: previousScrollOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        // Selection notifications caused by reloadData/selectRowIndexes can arrive one run-loop
        // turn late. Keep the reload guard up long enough to ignore those synthetic notifications,
        // then verify the logical selection once more before returning control to normal user input.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.transferTableReloadGeneration == reloadGeneration else { return }
            let currentRows = self.transferMonitorRows
            let currentKeys = currentRows.map(self.transferRowKey)
            guard currentKeys == self.transferTableRowKeysSnapshot else { return }

            var expectedIndexes = IndexSet()
            for (index, key) in currentKeys.enumerated() where self.selectedTransferKeys.contains(key) {
                expectedIndexes.insert(index)
            }
            if self.transferTable.selectedRowIndexes != expectedIndexes {
                if expectedIndexes.isEmpty { self.transferTable.deselectAll(nil) }
                else { self.transferTable.selectRowIndexes(expectedIndexes, byExtendingSelection: false) }
            }
            for index in expectedIndexes {
                self.transferTable.rowView(atRow: index, makeIfNecessary: false)?.needsDisplay = true
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.transferTableReloadGeneration == reloadGeneration else { return }
                self.isReloadingTransferTable = false
                self.updateTransferActionButtons()
                self.updateTransferDetailsUI()
            }
        }

        let items = orderedTransferMonitorItems
        let active = items.filter(\.active)
        let queued = items.filter(\.queued)
        let paused = items.filter { $0.paused }
        let completedItems = items.filter { $0.state == "Completed" }
        let problems = items.filter { item in
            let row = TransferMonitorRow.local(item)
            let category = transferStatusCategory(row)
            return category == .interrupted || category == .failed || category == .cancelled
        }
        transferClearButton.isEnabled = !completedItems.isEmpty
        transferClearButton.isHidden = transferMonitorScope == .serverWide
        transferAutoRemoveFinishedCheckbox.isHidden = transferMonitorScope == .serverWide

        let ownLimit = lastServerInfo?.maxFileTransfersPerUser ?? lastLoginResult?.maxFileTransfersPerUser
        let reportedOwnActive = lastServerInfo?.activeFileTransfersForUser.map(Int.init) ?? 0
        let ownActive = max(active.count, reportedOwnActive)
        var statusParts: [String] = []
        if transferMonitorScope == .serverWide {
            statusParts.append(L("Live server-wide active-transfer snapshot"))
            statusParts.append(transferScopeRows.count == 1 ? LF("%@ transfer", String(transferScopeRows.count)) : LF("%@ transfers", String(transferScopeRows.count)))
            if let serverActive = lastServerInfo?.activeFileTransfers,
               let serverLimit = lastServerInfo?.maxSimultaneousFileTransfers {
                statusParts.append(LF("capacity %@/%@", String(serverActive), String(serverLimit)))
            }
            if let limit = remoteTransferUploadLimitBytesPerSecond {
                statusParts.append(LF("server outbound limit %@", Self.transferBandwidthDisplay(limit)))
            }
        } else {
            if let ownLimit { statusParts.append(LF("own capacity %@/%@", String(ownActive), String(ownLimit))) }
            else { statusParts.append(LF("%@ active", String(active.count))) }
            if let serverActive = lastServerInfo?.activeFileTransfers,
               let serverLimit = lastServerInfo?.maxSimultaneousFileTransfers {
                statusParts.append(LF("server %@/%@ active", String(serverActive), String(serverLimit)))
            }
            statusParts.append(LF("%@ waiting", String(queued.count)))
            statusParts.append(LF("%@ paused", String(paused.count)))
            if !problems.isEmpty { statusParts.append(LF("%@ interrupted/cancelled", String(problems.count))) }
            statusParts.append(LF("%@ completed", String(completedItems.count)))
        }
        transferMonitorStatusLabel.stringValue = statusParts.joined(separator: " · ")
        transferMonitorStatusLabel.toolTip = transferMonitorStatusLabel.stringValue
        updateTransferFilterLabels()
        updateTransferRateSummary()
        updateTransferEmptyState()
        updateTransferActionButtons()
        updateTransferDetailsUI()
        scheduleTransferMonitorPersistenceIfChanged()

        let remoteBarManaged = remoteManagedTransferSnapshot.filter { !$0.isPaused && !$0.isAborting }
        let useRemoteBarTransfers = active.isEmpty && !remoteBarManaged.isEmpty
        let useLegacyRemoteBarTransfers = active.isEmpty && remoteBarManaged.isEmpty && !remoteTransferSnapshot.isEmpty
        let total: UInt64
        let completed: UInt64
        if useRemoteBarTransfers {
            total = remoteBarManaged.reduce(UInt64(0)) { partial, item in
                let (sum, overflow) = partial.addingReportingOverflow(item.totalBytes)
                return overflow ? UInt64.max : sum
            }
            completed = remoteBarManaged.reduce(UInt64(0)) { partial, item in
                let (sum, overflow) = partial.addingReportingOverflow(item.bytesTransferred)
                return overflow ? UInt64.max : sum
            }
        } else if useLegacyRemoteBarTransfers {
            total = remoteTransferSnapshot.reduce(UInt64(0)) { partial, item in
                let (sum, overflow) = partial.addingReportingOverflow(item.totalBytes)
                return overflow ? UInt64.max : sum
            }
            completed = remoteTransferSnapshot.reduce(UInt64(0)) { partial, item in
                let (sum, overflow) = partial.addingReportingOverflow(item.bytesTransferred)
                return overflow ? UInt64.max : sum
            }
        } else {
            total = active.reduce(UInt64(0)) { partial, item in
                let (sum, overflow) = partial.addingReportingOverflow(item.totalBytes)
                return overflow ? UInt64.max : sum
            }
            completed = active.reduce(UInt64(0)) { partial, item in
                let (sum, overflow) = partial.addingReportingOverflow(item.completedBytes)
                return overflow ? UInt64.max : sum
            }
        }
        let hasBarTransfers = !active.isEmpty || useRemoteBarTransfers || useLegacyRemoteBarTransfers
        transferProgress.isHidden = !hasBarTransfers
        transferProgress.doubleValue = total > 0 ? min(100, Double(completed) / Double(total) * 100) : 0

        let now = Date()
        if !hasBarTransfers {
            transferBarPreviousCompletedBytes = nil
            transferBarPreviousSampleDate = nil
            transferBarRateBytesPerSecond = 0
        } else if let previousBytes = transferBarPreviousCompletedBytes,
                  let previousDate = transferBarPreviousSampleDate {
            let elapsed = now.timeIntervalSince(previousDate)
            if elapsed >= 1.0 {
                if completed >= previousBytes {
                    transferBarRateBytesPerSecond = UInt64(Double(completed - previousBytes) / elapsed)
                } else {
                    // The active set changed; establish a fresh baseline rather than reporting
                    // a nonsense negative aggregate rate.
                    transferBarRateBytesPerSecond = 0
                }
                transferBarPreviousCompletedBytes = completed
                transferBarPreviousSampleDate = now
            }
        } else {
            transferBarPreviousCompletedBytes = completed
            transferBarPreviousSampleDate = now
            transferBarRateBytesPerSecond = 0
        }

        if !active.isEmpty {
            let first = active[0]
            let percent = first.totalBytes > 0 ? Int(min(100, (first.completedBytes * 100) / first.totalBytes)) : 0
            let direction = first.kind == LegacyTransferKind.download ? "↓" : "↑"
            let suffix = active.count > 1 ? LF(" · +%@ more", String(active.count - 1)) : ""
            transferSummaryLabel.stringValue = LF("%@ active · %@ %@ %@%%%@", String(active.count), direction, first.name, String(percent), suffix)
            let rate = transferBarRateBytesPerSecond > 0 ? transferBarRateBytesPerSecond : (remoteDownloadTrafficBytesPerSecond ?? 0)
            transferBarSpeedLabel.stringValue = rate > 0 ? Self.transferRateDisplay(rate) : ""
        } else if useRemoteBarTransfers, let first = remoteBarManaged.first {
            let percent = first.totalBytes > 0 ? Int(min(100, (first.bytesTransferred * 100) / first.totalBytes)) : 0
            let direction = first.kind == LegacyTransferKind.download ? "↓" : "↑"
            let name = LegacyPath.displayName(first.path)
            let suffix = remoteBarManaged.count > 1 ? LF(" · +%@ more", String(remoteBarManaged.count - 1)) : ""
            transferSummaryLabel.stringValue = LF("%@ active on server · %@ %@ %@%%%@", String(remoteBarManaged.count), direction, name, String(percent), suffix)
            let rate = remoteDownloadTrafficBytesPerSecond ?? transferBarRateBytesPerSecond
            transferBarSpeedLabel.stringValue = rate > 0 ? Self.transferRateDisplay(rate) : ""
        } else if useLegacyRemoteBarTransfers, let first = remoteTransferSnapshot.first {
            let percent = first.totalBytes > 0 ? Int(min(100, (first.bytesTransferred * 100) / first.totalBytes)) : 0
            let direction = first.kind == LegacyTransferKind.download ? "↓" : "↑"
            let name = LegacyPath.displayName(first.path)
            let suffix = remoteTransferSnapshot.count > 1 ? LF(" · +%@ more", String(remoteTransferSnapshot.count - 1)) : ""
            transferSummaryLabel.stringValue = LF("%@ active on server · %@ %@ %@%%%@", String(remoteTransferSnapshot.count), direction, name, String(percent), suffix)
            let rate = remoteDownloadTrafficBytesPerSecond ?? transferBarRateBytesPerSecond
            transferBarSpeedLabel.stringValue = rate > 0 ? Self.transferRateDisplay(rate) : ""
        } else {
            transferSummaryLabel.stringValue = queued.isEmpty
                ? L("No active transfers")
                : LF("No active transfers · %@ queued", String(queued.count))
            transferBarSpeedLabel.stringValue = ""
        }
    }

    static func transferMonitorPersistenceURL() -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        return base.appendingPathComponent("Carracho", isDirectory: true)
            .appendingPathComponent("Client", isDirectory: true)
            .appendingPathComponent(transferMonitorPersistenceFilename, isDirectory: false)
    }

    func loadPersistedTransferMonitorDocument() -> PersistedTransferMonitorDocument {
        let url = Self.transferMonitorPersistenceURL()
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(PersistedTransferMonitorDocument.self, from: data),
              document.version == 1 else { return PersistedTransferMonitorDocument() }
        return document
    }

    func writePersistedTransferMonitorDocument(_ document: PersistedTransferMonitorDocument) {
        let url = Self.transferMonitorPersistenceURL()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            if (try? Data(contentsOf: url)) == data { return }
            try data.write(to: url, options: .atomic)
        } catch {
            appendLine("\n" + LF("Transfer monitor state could not be saved: %@", Self.displayMessage(for: error)))
        }
    }

    func persistedTransferOperation(_ operation: ClientTransferOperation) -> PersistedTransferOperation {
        switch operation {
        case let .download(remotePath, destination):
            return PersistedTransferOperation(kind: .download, remotePath: remotePath, localURL: destination,
                                              parentPath: nil, overwrite: nil)
        case let .downloadDirectory(remotePath, parentDirectory):
            return PersistedTransferOperation(kind: .downloadDirectory, remotePath: remotePath, localURL: parentDirectory,
                                              parentPath: nil, overwrite: nil)
        case let .upload(localFile, parentPath, overwrite):
            return PersistedTransferOperation(kind: .upload, remotePath: nil, localURL: localFile,
                                              parentPath: parentPath, overwrite: overwrite)
        }
    }

    func restoredTransferOperation(_ operation: PersistedTransferOperation) -> ClientTransferOperation? {
        switch operation.kind {
        case .download:
            guard let remotePath = operation.remotePath, let destination = operation.localURL else { return nil }
            return .download(remotePath: remotePath, destination: destination)
        case .downloadDirectory:
            guard let remotePath = operation.remotePath, let parentDirectory = operation.localURL else { return nil }
            return .downloadDirectory(remotePath: remotePath, parentDirectory: parentDirectory)
        case .upload:
            guard let localFile = operation.localURL, let parentPath = operation.parentPath else { return nil }
            return .upload(localFile: localFile, parentPath: parentPath, overwrite: operation.overwrite ?? false)
        }
    }

    func persistedTransferItem(_ item: ClientTransferMonitorItem,
                                       operation: ClientTransferOperation?) -> PersistedTransferMonitorItem {
        var persisted = PersistedTransferMonitorItem(
            id: item.id, kind: item.kind, userID: item.userID, userNickname: item.userNickname,
            userPicture: item.userPicture, serverName: item.serverName, name: item.name, detail: item.detail,
            finderURL: item.finderURL, completedBytes: item.completedBytes, totalBytes: item.totalBytes,
            state: item.state, active: item.active, queued: item.queued, paused: item.paused,
            resumable: item.resumable, resumed: item.resumed, resumeOnStart: item.resumeOnStart,
            attemptGeneration: item.attemptGeneration, startedAt: item.startedAt,
            errorMessage: item.errorMessage,
            operation: operation.map(persistedTransferOperation)
        )
        // A process cannot restore a live socket/task. Persist an in-flight transfer as a
        // resumable local operation instead. The .carracho staging file is the source of truth
        // for the actual byte offset when Resume is pressed after relaunch.
        if persisted.active {
            persisted.active = false
            persisted.queued = false
            persisted.paused = false
            persisted.resumable = persisted.operation != nil
            persisted.resumeOnStart = persisted.operation != nil
            persisted.state = persisted.operation == nil ? "Interrupted" : "Interrupted · reconnect to resume"
        }
        return persisted
    }

    func restoredTransferItem(_ persisted: PersistedTransferMonitorItem) -> ClientTransferMonitorItem {
        var item = ClientTransferMonitorItem(
            id: persisted.id, kind: persisted.kind, userID: persisted.userID,
            userNickname: persisted.userNickname, userPicture: persisted.userPicture,
            serverName: persisted.serverName, name: persisted.name, detail: persisted.detail,
            finderURL: persisted.finderURL, completedBytes: persisted.completedBytes,
            totalBytes: persisted.totalBytes, state: persisted.state, active: false,
            queued: persisted.queued, paused: persisted.paused, resumable: persisted.resumable,
            resumed: persisted.resumed, resumeOnStart: persisted.resumeOnStart,
            attemptGeneration: persisted.attemptGeneration, startedAt: persisted.startedAt,
            errorMessage: persisted.errorMessage
        )
        if persisted.active {
            item.queued = false
            item.paused = false
            item.resumable = persisted.operation != nil
            item.resumeOnStart = persisted.operation != nil
            item.state = persisted.operation == nil ? "Interrupted" : "Interrupted · reconnect to resume"
        }
        return item
    }

    func persistTransferMonitorSession(bookmarkID: UUID,
                                               items: [UUID: ClientTransferMonitorItem],
                                               order: [UUID],
                                               operations: [UUID: ClientTransferOperation],
                                               selectedTransferID: UUID?) {
        guard !temporaryServerBookmarkIDs.contains(bookmarkID),
              let bookmark = serverBookmarks.first(where: { $0.id == bookmarkID }) else { return }
        var document = loadPersistedTransferMonitorDocument()
        let key = bookmarkID.uuidString.lowercased()
        let persistedItems = order.compactMap { id -> PersistedTransferMonitorItem? in
            guard let item = items[id] else { return nil }
            return persistedTransferItem(item, operation: operations[id])
        }
        if persistedItems.isEmpty {
            document.sessions.removeValue(forKey: key)
        } else {
            let selected = selectedTransferID.flatMap { id in persistedItems.contains(where: { $0.id == id }) ? id : nil }
            document.sessions[key] = PersistedTransferMonitorSession(host: bookmark.host, port: bookmark.port,
                                                                      login: bookmark.login, items: persistedItems,
                                                                      selectedTransferID: selected)
        }
        writePersistedTransferMonitorDocument(document)
    }

    func currentTransferMonitorPersistenceFingerprint() -> Int {
        var hasher = Hasher()
        hasher.combine(transferPersistenceBookmarkID)
        hasher.combine(selectedTransferID)
        for id in transferMonitorOrder {
            hasher.combine(id)
            guard let item = transferMonitorItems[id] else { continue }
            hasher.combine(item.kind)
            hasher.combine(item.userID)
            hasher.combine(item.userNickname)
            hasher.combine(item.userPicture)
            hasher.combine(item.serverName)
            hasher.combine(item.name)
            hasher.combine(item.detail)
            hasher.combine(item.finderURL)
            hasher.combine(item.completedBytes)
            hasher.combine(item.totalBytes)
            hasher.combine(item.state)
            hasher.combine(item.active)
            hasher.combine(item.queued)
            hasher.combine(item.paused)
            hasher.combine(item.resumable)
            hasher.combine(item.resumed)
            hasher.combine(item.resumeOnStart)
            hasher.combine(item.attemptGeneration)
            hasher.combine(item.startedAt)
            hasher.combine(item.errorMessage)
            if let operation = clientTransferOperations[id] {
                switch operation {
                case let .download(remotePath, destination):
                    hasher.combine(1); hasher.combine(remotePath); hasher.combine(destination)
                case let .downloadDirectory(remotePath, parentDirectory):
                    hasher.combine(2); hasher.combine(remotePath); hasher.combine(parentDirectory)
                case let .upload(localFile, parentPath, overwrite):
                    hasher.combine(3); hasher.combine(localFile); hasher.combine(parentPath); hasher.combine(overwrite)
                }
            } else {
                hasher.combine(0)
            }
        }
        return hasher.finalize()
    }

    func scheduleTransferMonitorPersistenceIfChanged() {
        let fingerprint = currentTransferMonitorPersistenceFingerprint()
        guard fingerprint != transferMonitorPersistenceFingerprint else { return }
        transferMonitorPersistenceFingerprint = fingerprint
        scheduleTransferMonitorPersistence()
    }

    func scheduleTransferMonitorPersistence() {
        guard !suppressTransferMonitorPersistence, let bookmarkID = transferPersistenceBookmarkID,
              !temporaryServerBookmarkIDs.contains(bookmarkID) else { return }
        transferMonitorPersistenceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.suppressTransferMonitorPersistence,
                  self.transferPersistenceBookmarkID == bookmarkID else { return }
            self.persistTransferMonitorSession(bookmarkID: bookmarkID,
                                               items: self.transferMonitorItems,
                                               order: self.transferMonitorOrder,
                                               operations: self.clientTransferOperations,
                                               selectedTransferID: self.selectedTransferID)
        }
        transferMonitorPersistenceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func restorePersistedTransferMonitorSession(for bookmarkID: UUID) {
        guard !temporaryServerBookmarkIDs.contains(bookmarkID) else { return }
        let document = loadPersistedTransferMonitorDocument()
        guard let bookmark = serverBookmarks.first(where: { $0.id == bookmarkID }),
              let session = document.sessions[bookmarkID.uuidString.lowercased()],
              session.host.caseInsensitiveCompare(bookmark.host) == .orderedSame,
              session.port == bookmark.port,
              session.login.caseInsensitiveCompare(bookmark.login) == .orderedSame else { return }

        var restoredItems: [UUID: ClientTransferMonitorItem] = [:]
        var restoredOperations: [UUID: ClientTransferOperation] = [:]
        var restoredOrder: [UUID] = []
        let autoRemoveFinished = transferAutoRemoveFinishedCheckbox.state == .on
        for persisted in session.items {
            if autoRemoveFinished && persisted.state == "Completed" { continue }
            let item = restoredTransferItem(persisted)
            restoredItems[item.id] = item
            restoredOrder.append(item.id)
            if let operation = persisted.operation.flatMap(restoredTransferOperation) {
                restoredOperations[item.id] = operation
            }
        }
        transferMonitorItems = restoredItems
        transferMonitorOrder = restoredOrder
        clientTransferTasks = [:]
        clientTransferOperations = restoredOperations
        selectedTransferID = session.selectedTransferID.flatMap { restoredItems[$0] != nil ? $0 : nil }
        selectedRemoteTransferID = nil
        refreshTransferMonitorUI()
    }

    @objc func applicationWillTerminate(_ notification: Notification) {
        transferMonitorPersistenceWorkItem?.cancel()
        transferMonitorPersistenceWorkItem = nil
        if let bookmarkID = transferPersistenceBookmarkID, !temporaryServerBookmarkIDs.contains(bookmarkID) {
            persistTransferMonitorSession(bookmarkID: bookmarkID, items: transferMonitorItems,
                                          order: transferMonitorOrder, operations: clientTransferOperations,
                                          selectedTransferID: selectedTransferID)
        }
        for (bookmarkID, context) in bookmarkConnections where bookmarkID != transferPersistenceBookmarkID {
            guard let snapshot = context.snapshot, !temporaryServerBookmarkIDs.contains(bookmarkID) else { continue }
            persistTransferMonitorSession(bookmarkID: bookmarkID, items: snapshot.transferMonitorItems,
                                          order: snapshot.transferMonitorOrder,
                                          operations: snapshot.clientTransferOperations,
                                          selectedTransferID: snapshot.selectedTransferID)
        }

        // Do not rely on process teardown to eventually make TCP disappear. A single client can
        // keep several bookmark sessions alive at once, so explicitly close every distinct
        // control connection while AppKit is still giving us deterministic shutdown time.
        var terminatingClients: [ObjectIdentifier: LegacyControlClient] = [ObjectIdentifier(client): client]
        for context in bookmarkConnections.values {
            context.backgroundNewsTimer?.invalidate()
            context.backgroundNewsTimer = nil
            terminatingClients[ObjectIdentifier(context.client)] = context.client
        }
        if let probe = trackerCredentialValidationClient {
            terminatingClients[ObjectIdentifier(probe)] = probe
            trackerCredentialValidationClient = nil
        }
        for connection in terminatingClients.values { connection.disconnect() }
    }

    func updateTransferActionButtons() {
        let rows = selectedTransferRows()
        transferPauseButton.isEnabled = rows.contains(where: transferCanPause)
        transferResumeButton.isEnabled = rows.contains(where: transferCanResume)
        transferAbortButton.isEnabled = rows.contains(where: transferCanAbort)
        let localItems = rows.compactMap { row -> ClientTransferMonitorItem? in
            guard case let .local(item) = row else { return nil }
            return transferMonitorItems[item.id]
        }
        transferRemoveButton.isEnabled = !localItems.isEmpty && localItems.allSatisfy { !$0.active && !$0.queued }
        transferDeletePartialButton.isEnabled = !localItems.isEmpty &&
            localItems.allSatisfy { !$0.active && !$0.queued } &&
            localItems.contains { item in
                clientTransferOperations[item.id] != nil && item.state != "Completed"
            }
        transferShowInFinderButton.isEnabled = rows.count == 1 && rows.first.map(transferCanRevealLocal) == true
    }

    @objc func refreshRemoteTransferInfo(_ sender: Any?) {
        guard client.isConnected, canManageRemoteTransfers else {
            clearRemoteTransferMonitorState()
            return
        }
        guard !transferMonitorRequestInFlight else { return }
        transferMonitorRequestInFlight = true
        client.requestTransferMonitor { [weak self] result in
            guard let self else { return }
            self.transferMonitorRequestInFlight = false
            switch result {
            case let .success(snapshot):
                self.applyRemoteTransferMonitor(snapshot)
            case .failure:
                // Server-wide transfer information is an administrative view. The
                // local monitor remains available to every user even when 0xe0 is denied.
                self.clearRemoteTransferMonitorState()
            }
        }
    }

    func reloadTransferBandwidthAdministration() {
        if client.isConnected {
            guard isRemoteAdministrator else {
                setTransferBandwidthControlsEnabled(false)
                transferBandwidthValueLabel.stringValue = L("Administrator access required")
                return
            }
            setTransferBandwidthControlsEnabled(false)
            transferBandwidthValueLabel.stringValue = L("Loading…")
            refreshRemoteTransferInfo(nil)
        } else {
            refreshTransferBandwidthControls()
        }
    }

    func setTransferBandwidthControlsEnabled(_ enabled: Bool) {
        transferBandwidthField.isEnabled = enabled
        transferBandwidthUnitPopup.isEnabled = enabled
        transferBandwidthApplyButton.isEnabled = enabled
    }

    func currentConfiguredTransferBandwidth() -> UInt64? {
        if client.isConnected { return remoteTransferUploadLimitBytesPerSecond }
        return serverBackend == nil ? nil : localServerState.runtime.uploadBandwidthLimitBytesPerSecond
    }

    func transferBandwidthBytesPerSecond() throws -> UInt64 {
        let raw = transferBandwidthField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(normalized), amount.isFinite, amount >= 0 else {
            throw ServerStateError.invalidValue(L("Enter a non-negative upload bandwidth value."))
        }
        let unitIndex = transferBandwidthUnitPopup.indexOfSelectedItem
        guard Self.transferBandwidthUnitBytesPerSecond.indices.contains(unitIndex) else {
            throw ServerStateError.invalidValue(L("Select a valid upload bandwidth unit."))
        }
        let bytes = amount * Self.transferBandwidthUnitBytesPerSecond[unitIndex]
        guard bytes.isFinite, bytes <= Double(UInt64.max) else {
            throw ServerStateError.invalidValue(L("The upload bandwidth value is too large."))
        }
        return UInt64(bytes.rounded())
    }

    @objc func transferBandwidthChanged(_ sender: Any?) {
        let value: UInt64
        do {
            value = try transferBandwidthBytesPerSecond()
        } catch {
            refreshTransferBandwidthControls()
            showAdminError(error)
            return
        }

        if client.isConnected {
            guard isRemoteAdministrator, remoteTransferUploadLimitBytesPerSecond != nil else {
                refreshTransferBandwidthControls()
                return
            }
            setTransferBandwidthControlsEnabled(false)
            transferBandwidthValueLabel.stringValue = L("Applying…")
            client.setTransferUploadBandwidthLimit(bytesPerSecond: value) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(snapshot):
                    self.applyRemoteTransferMonitor(snapshot)
                case let .failure(error):
                    self.refreshTransferBandwidthControls()
                    self.showError(LF("Upload bandwidth could not be changed: %@", Self.displayMessage(for: error)))
                }
            }
            return
        }

        guard let backend = serverBackend else {
            refreshTransferBandwidthControls()
            return
        }
        do {
            setTransferBandwidthControlsEnabled(false)
            transferBandwidthValueLabel.stringValue = L("Applying…")
            var runtime = localServerState.runtime
            runtime.uploadBandwidthLimitBytesPerSecond = value
            try backend.updateRuntime(runtime)
            localServerRuntime?.configureDownloadBandwidthLimit(value)
            try localServerRuntime?.persistStartupConfigurationToJSON(backend.snapshot())
            reloadLocalStateFromBackend()
            refreshTransferBandwidthControls()
        } catch {
            refreshTransferBandwidthControls()
            showAdminError(error)
        }
    }

    @objc func transferBandwidthUnitChanged(_ sender: NSPopUpButton) {
        guard let value = currentConfiguredTransferBandwidth() else { return }
        transferBandwidthField.stringValue = Self.transferBandwidthInputDisplay(value, unitIndex: sender.indexOfSelectedItem)
    }

    func cachedRemoteTransferIsDirectory(_ path: Data) -> Bool? {
        transferRemoteDirectoryKindsBySource[currentFilesSourceKey()]?[path]
    }

    func resolveRemoteTransferDirectoryKindsIfNeeded(_ snapshot: LegacyTransferMonitorSnapshot) {
        guard client.isConnected else { return }
        let sourceKey = currentFilesSourceKey()
        let target = client

        let managedDownloads = snapshot.managedTransfers.filter { $0.kind == LegacyTransferKind.download }
        let paths: Set<Data>
        if !managedDownloads.isEmpty {
            paths = Set(managedDownloads.map(\.path))
            for item in managedDownloads where item.isDirectory {
                transferRemoteDirectoryKindsBySource[sourceKey, default: [:]][item.path] = true
            }
        } else {
            paths = Set(snapshot.transfers.filter { $0.kind == LegacyTransferKind.download }.map(\.path))
        }

        transferRemoteDirectoryKindsBySource[sourceKey] = transferRemoteDirectoryKindsBySource[sourceKey, default: [:]]
            .filter { paths.contains($0.key) }
        transferRemoteDirectoryLookupsBySource[sourceKey] = transferRemoteDirectoryLookupsBySource[sourceKey, default: []]
            .intersection(paths)

        for path in paths where !path.isEmpty {
            if transferRemoteDirectoryKindsBySource[sourceKey]?[path] != nil { continue }
            if transferRemoteDirectoryLookupsBySource[sourceKey, default: []].contains(path) { continue }
            transferRemoteDirectoryLookupsBySource[sourceKey, default: []].insert(path)
            target.requestFileInfo(path: path) { [weak self, weak target] result in
                guard let self, let target, self.client === target, sourceKey == self.currentFilesSourceKey() else { return }
                guard case let .success(info) = result else { return }
                let isDirectory = (info.metadata.flags & LegacyDirectoryFlags.folder) != 0
                self.transferRemoteDirectoryKindsBySource[sourceKey, default: [:]][path] = isDirectory
                self.refreshTransferMonitorUI()
            }
        }
    }

    func applyRemoteTransferMonitor(_ snapshot: LegacyTransferMonitorSnapshot) {
        let fallbackLocalID: UUID? = selectedManagedTransfer.flatMap(localTransferRepresentingManaged)
        let selectedRemoteStillExists = selectedRemoteTransferID.map { selectedID in
            snapshot.managedTransfers.contains { $0.transferID == selectedID }
        } ?? false

        let now = Date()
        var currentBytes: [TransferMonitorRowKey: UInt64] = [:]
        if !snapshot.managedTransfers.isEmpty {
            for item in snapshot.managedTransfers { currentBytes[.managed(item.transferID)] = item.bytesTransferred }
        } else {
            for item in snapshot.transfers {
                currentBytes[.legacy(kind: item.kind, userID: item.userID, path: item.path)] = item.bytesTransferred
            }
        }
        if let previousDate = transferRemotePreviousSampleDate {
            let elapsed = now.timeIntervalSince(previousDate)
            if elapsed >= 1.0 {
                var rates: [TransferMonitorRowKey: UInt64] = [:]
                for (key, bytes) in currentBytes {
                    if let previous = transferRemotePreviousBytesByKey[key], bytes >= previous {
                        rates[key] = UInt64(Double(bytes - previous) / elapsed)
                    }
                }
                transferRemoteRatesByKey = rates
                transferRemotePreviousBytesByKey = currentBytes
                transferRemotePreviousSampleDate = now
            }
        } else {
            transferRemoteRatesByKey = [:]
            transferRemotePreviousBytesByKey = currentBytes
            transferRemotePreviousSampleDate = now
        }

        remoteTransferSnapshot = snapshot.transfers
        remoteManagedTransferSnapshot = snapshot.managedTransfers
        if selectedRemoteTransferID != nil, !selectedRemoteStillExists {
            selectedRemoteTransferID = nil
            if let fallbackLocalID { selectedTransferID = fallbackLocalID }
        }
        remoteTransferUploadLimitBytesPerSecond = snapshot.uploadBandwidthLimitBytesPerSecond
        remoteDownloadTrafficBytesPerSecond = snapshot.downloadTrafficBytesPerSecond
        resolveRemoteTransferDirectoryKindsIfNeeded(snapshot)
        refreshTransferBandwidthControls()
        refreshTransferMonitorUI()
    }

    func clearRemoteTransferMonitorState() {
        let fallbackLocalID = selectedManagedTransfer.flatMap(localTransferRepresentingManaged)
        remoteTransferSnapshot = []
        remoteManagedTransferSnapshot = []
        transferRemoteRatesByKey = [:]
        transferRemotePreviousBytesByKey = [:]
        transferRemotePreviousSampleDate = nil
        let sourceKey = currentFilesSourceKey()
        transferRemoteDirectoryKindsBySource[sourceKey] = nil
        transferRemoteDirectoryLookupsBySource[sourceKey] = nil
        selectedRemoteTransferID = nil
        if let fallbackLocalID { selectedTransferID = fallbackLocalID }
        remoteTransferUploadLimitBytesPerSecond = nil
        remoteDownloadTrafficBytesPerSecond = nil
        transferMonitorRequestInFlight = false
        refreshTransferBandwidthControls()
        refreshTransferMonitorUI()
    }

    func refreshTransferBandwidthControls() {
        let unitIndex = max(0, transferBandwidthUnitPopup.indexOfSelectedItem)
        if client.isConnected {
            if isRemoteAdministrator {
                if let limit = remoteTransferUploadLimitBytesPerSecond {
                    if !advancedBandwidthDirty {
                        transferBandwidthField.stringValue = Self.transferBandwidthInputDisplay(limit, unitIndex: unitIndex)
                    }
                    setTransferBandwidthControlsEnabled(true)
                    transferBandwidthValueLabel.stringValue = Self.transferBandwidthDisplay(limit)
                } else {
                    setTransferBandwidthControlsEnabled(false)
                    transferBandwidthValueLabel.stringValue = L("Unavailable")
                }
            } else {
                setTransferBandwidthControlsEnabled(false)
                transferBandwidthValueLabel.stringValue = L("Administrator access required")
            }

            if canManageRemoteTransfers {
                let rate = remoteDownloadTrafficBytesPerSecond ?? 0
                transferDownloadSpeedLabel.stringValue = LF("Downloader traffic: %@", Self.transferRateDisplay(rate))
            } else {
                transferDownloadSpeedLabel.stringValue = ""
            }
            updateAdvancedSaveUI()
            return
        }

        if serverBackend != nil {
            let limit = localServerState.runtime.uploadBandwidthLimitBytesPerSecond
            if !advancedBandwidthDirty {
                transferBandwidthField.stringValue = Self.transferBandwidthInputDisplay(limit, unitIndex: unitIndex)
            }
            setTransferBandwidthControlsEnabled(true)
            transferBandwidthValueLabel.stringValue = Self.transferBandwidthDisplay(limit)
        } else {
            setTransferBandwidthControlsEnabled(false)
            transferBandwidthValueLabel.stringValue = L("Unavailable")
        }
        transferDownloadSpeedLabel.stringValue = ""
        updateAdvancedSaveUI()
    }

    static func transferBandwidthInputDisplay(_ value: UInt64, unitIndex: Int) -> String {
        guard transferBandwidthUnitBytesPerSecond.indices.contains(unitIndex) else { return String(value) }
        let amount = Double(value) / transferBandwidthUnitBytesPerSecond[unitIndex]
        if amount == 0 { return "0" }
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 3
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.3f", amount)
    }

    static func transferBandwidthDisplay(_ value: UInt64) -> String {
        value == 0 ? L("Unlimited") : transferRateDisplay(value)
    }

    static func transferRateDisplay(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) + "/s"
    }

    func updateTransferMonitorPolling() {
        transferMonitorRefreshTimer?.invalidate()
        transferMonitorRefreshTimer = nil
        guard currentWorkspace == .transfers, client.isConnected else {
            if !client.isConnected { clearRemoteTransferMonitorState() }
            return
        }
        if canManageRemoteTransfers { refreshRemoteTransferInfo(nil) }
        else { clearRemoteTransferMonitorState() }
        refreshTransferCapacitySnapshot(startQueuedTransfers: !queuedClientTransferIDs.isEmpty)
        transferMonitorRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.canManageRemoteTransfers { self.refreshRemoteTransferInfo(nil) }
            self.refreshTransferCapacitySnapshot(startQueuedTransfers: !self.queuedClientTransferIDs.isEmpty)
        }
    }
    func transferUserName(userID: UInt32) -> String {
        liveUsers[userID].map { Self.macRomanString($0.nickname) } ?? L("Unknown User")
    }

    func transferProgressText(completed: UInt64, total: UInt64) -> String {
        let done = ByteCountFormatter.string(fromByteCount: Int64(clamping: completed), countStyle: .file)
        guard total > 0 else { return done }
        let totalText = ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file)
        let percent = Int(min(100.0, (Double(completed) / Double(total)) * 100.0))
        return "\(done) / \(totalText) · \(percent)%"
    }

    func transferUserCell(userID: UInt32?, nickname: String? = nil, picture: Data? = nil) -> NSView {
        let liveUser = userID.flatMap { liveUsers[$0] }
        let resolvedName = nickname ?? liveUser.map { Self.macRomanString($0.nickname) }
            ?? (userID == nil ? L("Local User") : L("Unknown User"))
        let resolvedPicture = picture.flatMap { $0.isEmpty ? nil : $0 }
            ?? liveUser.flatMap { $0.picture.isEmpty ? nil : $0.picture }

        let avatar = NSImageView()
        if let resolvedPicture, let image = NSImage(data: resolvedPicture) {
            avatar.image = image
        } else {
            avatar.image = AvatarArtwork.defaultImage()
            avatar.contentTintColor = nil
        }
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 16
        avatar.layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 32),
            avatar.heightAnchor.constraint(equalToConstant: 32),
        ])

        let name = NSTextField(labelWithString: resolvedName)
        name.font = .systemFont(ofSize: 12.5, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        return horizontalStack([avatar, name], spacing: 7)
    }

    func transferFileIcon(for row: TransferMonitorRow) -> NSImage? {
        if case let .local(item) = row {
            if let url = item.finderURL, FileManager.default.fileExists(atPath: url.path) {
                let image = NSWorkspace.shared.icon(forFile: url.path)
                image.size = NSSize(width: 34, height: 34)
                return image
            }
            if let url = item.finderURL {
                let parent = url.deletingLastPathComponent()
                let partial = parent.appendingPathComponent("\(url.lastPathComponent).carracho", isDirectory: false)
                let legacyPartial = parent.appendingPathComponent(".carracho.\(url.lastPathComponent)", isDirectory: false)
                if FileManager.default.fileExists(atPath: partial.path) ||
                    FileManager.default.fileExists(atPath: legacyPartial.path) {
                    let source = Bundle.main.image(forResource: NSImage.Name("Incomplete"))
                        ?? NSImage(named: NSImage.Name("Incomplete"))
                    if let source, let image = source.copy() as? NSImage {
                        image.isTemplate = false
                        image.size = NSSize(width: 34, height: 34)
                        return image
                    }
                }
            }
            if let operation = clientTransferOperations[item.id], case .downloadDirectory = operation {
                return symbolImage("folder.fill", fallback: NSImage.folderName)
            }
        }
        switch row {
        case let .managed(item):
            if item.isDirectory || cachedRemoteTransferIsDirectory(item.path) == true {
                return symbolImage("folder.fill", fallback: NSImage.folderName)
            }
        case let .legacyServer(item):
            if cachedRemoteTransferIsDirectory(item.path) == true {
                return symbolImage("folder.fill", fallback: NSImage.folderName)
            }
        case .local:
            break
        }
        let name = transferRowName(row)
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty {
            let image = NSWorkspace.shared.icon(forFile: "/tmp/carracho-transfer-placeholder.\(ext)")
            image.size = NSSize(width: 34, height: 34)
            return image
        }
        return symbolImage("doc.fill", fallback: NSImage.multipleDocumentsName)
    }

    func transferAvatarIsLegacy(_ row: TransferMonitorRow) -> Bool {
        let userID: UInt32?
        switch row {
        case let .local(item): userID = item.userID
        case let .managed(item): userID = item.userID
        case let .legacyServer(item): userID = item.userID
        }
        return userID.flatMap { liveUsers[$0]?.isLegacyTransport } ?? false
    }

    func transferAvatarImage(for row: TransferMonitorRow) -> NSImage? {
        let userID: UInt32?
        let storedPicture: Data?
        switch row {
        case let .local(item): userID = item.userID; storedPicture = item.userPicture
        case let .managed(item): userID = item.userID; storedPicture = nil
        case let .legacyServer(item): userID = item.userID; storedPicture = nil
        }
        if let storedPicture, let image = AvatarArtwork.decodedImage(from: storedPicture) { return image }
        if let userID, let user = liveUsers[userID] {
            return AvatarArtwork.userImage(picture: user.picture,
                                           isLegacyTransport: user.isLegacyTransport)
        }
        return AvatarArtwork.defaultImage()
    }

    func transferDirectionText(_ row: TransferMonitorRow) -> String {
        let download = transferRowKind(row) == LegacyTransferKind.download
        switch transferMonitorScope {
        case .mine:
            return download ? L("Download to this Mac") : L("Upload to server")
        case .serverWide:
            let user = transferRowUserName(row)
            return download ? LF("Download from server · %@", user) : LF("Upload to server · %@", user)
        }
    }

    func transferNameCell(for row: TransferMonitorRow) -> NSView {
        let icon = NSImageView()
        icon.image = transferFileIcon(for: row)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34),
        ])

        let name = NSTextField(labelWithString: transferRowName(row))
        name.font = .systemFont(ofSize: 12.5, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = transferRowName(row)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let direction = NSTextField(labelWithString: transferDirectionText(row))
        direction.font = .systemFont(ofSize: 10.5)
        direction.textColor = CarrachoTheme.secondaryText
        direction.lineBreakMode = .byTruncatingTail
        direction.setContentHuggingPriority(.defaultLow, for: .horizontal)
        direction.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = verticalStack([name, direction], spacing: 3)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Do not let NSStackView keep the text block at its intrinsic filename width. The file
        // column can be much wider, and that unused width should belong to the filename before
        // we start truncating it.
        let content = NSView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        labels.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(icon)
        content.addSubview(labels)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            labels.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            labels.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        if transferMonitorScope == .serverWide {
            let avatar = NSImageView()
            avatar.image = transferAvatarImage(for: row)
            avatar.imageScaling = .scaleProportionallyUpOrDown
            avatar.translatesAutoresizingMaskIntoConstraints = false
            avatar.wantsLayer = true
            let legacyAvatar = transferAvatarIsLegacy(row)
            avatar.layer?.cornerRadius = legacyAvatar ? 0 : 12
            avatar.layer?.masksToBounds = !legacyAvatar
            avatar.toolTip = transferRowUserName(row)
            content.addSubview(avatar)
            NSLayoutConstraint.activate([
                avatar.widthAnchor.constraint(equalToConstant: 24),
                avatar.heightAnchor.constraint(equalToConstant: 24),
                avatar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                avatar.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                labels.trailingAnchor.constraint(equalTo: avatar.leadingAnchor, constant: -8),
            ])
        } else {
            labels.trailingAnchor.constraint(equalTo: content.trailingAnchor).isActive = true
        }

        content.setAccessibilityLabel(LF("%@, %@", transferRowName(row), transferDirectionText(row)))
        return verticallyCenteredTableContent(content, fillWidth: true, leadingInset: 4, trailingInset: 8)
    }

    func transferProgressCell(for row: TransferMonitorRow) -> NSView {
        let values = transferRowCompletedAndTotal(row)
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 100
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        progress.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let category = transferStatusCategory(row)
        let percentLabel = NSTextField(labelWithString: "")
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        percentLabel.alignment = .right
        percentLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        if values.total > 0 {
            progress.isIndeterminate = false
            progress.doubleValue = min(100, Double(values.completed) / Double(values.total) * 100)
            percentLabel.stringValue = "\(Int(progress.doubleValue))%"
        } else if category == .active {
            progress.isIndeterminate = true
            progress.startAnimation(nil)
            percentLabel.stringValue = "—"
        } else {
            progress.isIndeterminate = false
            progress.doubleValue = 0
            progress.isHidden = true
            percentLabel.stringValue = "—"
        }
        let progressRow = horizontalStack([progress, percentLabel], spacing: 8)

        let detail = NSTextField(labelWithString: transferProgressText(completed: values.completed, total: values.total))
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = CarrachoTheme.secondaryText
        detail.lineBreakMode = .byTruncatingTail
        detail.toolTip = detail.stringValue
        return verticallyCenteredTableContent(verticalStack([progressRow, detail], spacing: 4), fillWidth: true)
    }

    func transferStatusPresentation(_ row: TransferMonitorRow) -> (symbol: String, color: NSColor, title: String, detail: String) {
        let category = transferStatusCategory(row)
        let title = transferRowStatus(row)
        let values = transferRowCompletedAndTotal(row)
        let rate = transferRowRate(row) ?? 0
        let detail: String
        if category == .active, rate > 0 {
            if values.total > values.completed {
                let remaining = Double(values.total - values.completed) / Double(rate)
                detail = LF("%@ · about %@ left", Self.transferRateDisplay(rate), Self.durationString(remaining))
            } else {
                detail = Self.transferRateDisplay(rate)
            }
        } else {
            switch category {
            case .waiting: detail = L("Waiting for an available transfer slot")
            case .paused: detail = L("Can be resumed")
            case .interrupted: detail = L("Interrupted · resume available when supported")
            case .failed: detail = transferIssueDescription(row)
            case .cancelled: detail = transferIssueDescription(row)
            case .completed: detail = L("Completed successfully")
            case .active: detail = L("Transfer in progress")
            }
        }
        switch category {
        case .active:
            return (transferRowKind(row) == LegacyTransferKind.download ? "arrow.down.circle.fill" : "arrow.up.circle.fill",
                    CarrachoTheme.selection, title, detail)
        case .waiting: return ("clock.fill", CarrachoTheme.secondaryText, title, detail)
        case .paused: return ("pause.circle.fill", CarrachoTheme.warning, title, detail)
        case .interrupted: return ("exclamationmark.triangle.fill", CarrachoTheme.warning, title, detail)
        case .failed: return ("xmark.octagon.fill", .systemRed, title, detail)
        case .cancelled: return ("xmark.circle.fill", CarrachoTheme.secondaryText, title, detail)
        case .completed: return ("checkmark.circle.fill", CarrachoTheme.success, title, detail)
        }
    }

    func transferPrimaryAction(for row: TransferMonitorRow) -> (title: String, symbol: String)? {
        if transferCanPause(row) { return (L("Pause"), "pause.fill") }
        if transferCanResume(row) { return (L("Resume"), "play.fill") }
        if transferCanRevealLocal(row) { return (L("Reveal"), "folder") }
        return nil
    }

    func performTransferPrimaryAction(for key: TransferMonitorRowKey) {
        guard let row = currentTransferRow(for: key) else { return }
        selectTransferRow(key)
        if transferCanPause(row) { pauseSelectedTransfer(nil) }
        else if transferCanResume(row) { resumeSelectedTransfer(nil) }
        else if transferCanRevealLocal(row) { showSelectedTransferInFinder(nil) }
    }

    func transferStatusCell(for row: TransferMonitorRow) -> NSView {
        let presentation = transferStatusPresentation(row)
        let icon = NSImageView()
        icon.image = symbolImage(presentation.symbol, fallback: NSImage.statusAvailableName)
        icon.contentTintColor = presentation.color
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
        ])

        let title = NSTextField(labelWithString: presentation.title)
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: presentation.detail)
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = CarrachoTheme.secondaryText
        detail.lineBreakMode = .byTruncatingTail
        detail.toolTip = presentation.detail
        let labels = verticalStack([title, detail], spacing: 2)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var views: [NSView] = [icon, labels, NSView()]
        let key = transferRowKey(row)
        if let action = transferPrimaryAction(for: row) {
            let button = CarrachoClosureButton(title: action.title)
            button.controlSize = .small
            button.image = symbolImage(action.symbol, fallback: NSImage.actionTemplateName)
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = action.title
            button.setAccessibilityLabel(action.title)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            // Progress updates reload this table several times per second. A normal NSButton
            // sends its action on mouse-up, so the cell could be replaced between mouse-down and
            // mouse-up and the pause click simply vanished. Fire on mouse-down for these compact
            // row actions so Pause/Resume remains reliable during a live transfer.
            button.sendAction(on: .leftMouseDown)
            button.handler = { [weak self] in self?.performTransferPrimaryAction(for: key) }
            views.append(button)
        }
        let stack = horizontalStack(views, spacing: 7)
        stack.setAccessibilityLabel(LF("%@, %@", presentation.title, presentation.detail))
        // Keep a real trailing gutter so the pause/resume and overflow buttons never sit under
        // the scroll-view edge or vertical scroller.
        return verticallyCenteredTableContent(stack, fillWidth: true, leadingInset: 4, trailingInset: 8)
    }

}
