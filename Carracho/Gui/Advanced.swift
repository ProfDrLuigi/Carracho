import Cocoa
import QuickLookUI

// MARK: - Advanced

extension ViewController {

    func advancedSectionCard(title: String, symbol: String, content: [NSView]) -> NSView {
        let card = cardView()
        if let card = card as? CarrachoCardView { card.cornerRadius = 8 }

        let icon = symbolView(symbol, size: 18, tint: CarrachoTheme.secondaryText)
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        let header = horizontalStack([icon, titleField, NSView()], spacing: 8)
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true

        let divider = CarrachoDividerView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let body = NSStackView(views: content)
        body.orientation = .vertical
        body.alignment = .width
        body.spacing = 9

        let stack = NSStackView(views: [header, divider, body])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 13),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -13),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return card
    }

    func advancedFormRow(_ title: String, control: NSView, note: String? = nil) -> NSView {
        let label = NSTextField(labelWithString: L(title))
        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var views: [NSView] = [label, NSView(), control]
        if let note {
            let help = NSTextField(labelWithString: note)
            help.font = .systemFont(ofSize: 10.5)
            help.textColor = CarrachoTheme.secondaryText
            help.setContentHuggingPriority(.required, for: .horizontal)
            views.append(help)
        }
        let row = horizontalStack(views, spacing: 9)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        return row
    }

    func advancedHelp(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 10.5)
        label.textColor = CarrachoTheme.secondaryText
        label.maximumNumberOfLines = 0
        return label
    }

    func advancedWarning(_ text: String) -> NSView {
        let box = CarrachoCardView()
        box.cornerRadius = 7
        box.fillColor = NSColor.systemOrange.withAlphaComponent(0.10)
        let icon = symbolView("info.circle.fill", size: 15, tint: .systemOrange)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .systemOrange
        label.maximumNumberOfLines = 0
        let row = horizontalStack([icon, label], spacing: 8)
        pin(row, in: box, inset: 9)
        return box
    }

    func configureAdvancedEditorTracking() {
        let fields = [adminMaxConnectionsField, adminMaxConnectionsPerIPField,
                      adminMaxTransfersField, adminMaxTransfersPerUserField,
                      adminMaxFolderDepthField, adminLegacyFilesRootField,
                      transferBandwidthField]
        for field in fields { field.delegate = self }
        adminSearchIndexExclusionsView.delegate = self
        adminIPRulesView.delegate = self

        adminAuthenticationModePopup.target = self
        adminAuthenticationModePopup.action = #selector(advancedPopupChanged(_:))
        transferBandwidthUnitPopup.target = self
        transferBandwidthUnitPopup.action = #selector(advancedBandwidthUnitChanged(_:))
        transferBandwidthField.target = self
        transferBandwidthField.action = #selector(advancedControlCommitted(_:))
    }

    func makeAdvancedAdminPage() -> NSView {
        let page = adminPage(title: L("Advanced"), subtitle: L("Connection limits, transfers, indexing, storage and access restrictions"))
        guard let header = page.subviews.first(where: { $0.identifier?.rawValue == "adminHeader" }) else { return page }

        adminAuthenticationModePopup.removeAllItems()
        adminAuthenticationModePopup.addItems(withTitles: ServerAuthenticationMode.allCases.map(\.displayName))
        adminAuthenticationModePopup.controlSize = .small
        adminAuthenticationModePopup.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let numericFields = [adminMaxConnectionsField, adminMaxConnectionsPerIPField,
                             adminMaxTransfersField, adminMaxTransfersPerUserField,
                             adminMaxFolderDepthField]
        for field in numericFields {
            field.alignment = .right
            field.controlSize = .small
            field.widthAnchor.constraint(equalToConstant: 108).isActive = true
        }
        configureAdvancedEditorTracking()

        let connectionsCard = advancedSectionCard(title: L("Connections & Security"), symbol: "lock.fill", content: [
            advancedFormRow("Authentication", control: adminAuthenticationModePopup),
            advancedFormRow("Total connections", control: adminMaxConnectionsField),
            advancedFormRow("Connections per IP", control: adminMaxConnectionsPerIPField),
            advancedWarning(L("Modern-only permanently removes legacy password-equivalent material. Re-enabling compatibility later may require password resets for Classic clients.")),
        ])

        transferBandwidthField.controlSize = .small
        transferBandwidthField.widthAnchor.constraint(equalToConstant: 100).isActive = true
        transferBandwidthUnitPopup.controlSize = .small
        transferBandwidthUnitPopup.widthAnchor.constraint(equalToConstant: 86).isActive = true
        let bandwidthControls = horizontalStack([transferBandwidthField, transferBandwidthUnitPopup], spacing: 7)
        bandwidthControls.setContentHuggingPriority(.required, for: .horizontal)
        transferBandwidthValueLabel.font = .systemFont(ofSize: 10.5)
        transferBandwidthValueLabel.textColor = CarrachoTheme.secondaryText
        transferBandwidthValueLabel.lineBreakMode = .byTruncatingTail

        let transfersCard = advancedSectionCard(title: L("File Transfers"), symbol: "arrow.up.arrow.down", content: [
            advancedFormRow("Simultaneous transfers", control: adminMaxTransfersField),
            advancedFormRow("Transfers per user", control: adminMaxTransfersPerUserField),
            advancedFormRow("Max. folder depth", control: adminMaxFolderDepthField, note: L("0 = unlimited")),
            advancedFormRow("Upload limit", control: bandwidthControls),
            transferBandwidthValueLabel,
            advancedHelp(L("The upload limit applies server-wide. Enter 0 for unlimited.")),
        ])

        adminLegacyFilesRootField.placeholderString = L("Empty = normal File Root")
        adminLegacyFilesRootField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        adminLegacyFilesRootField.controlSize = .small
        adminLegacyFilesRootStatusLabel.textColor = CarrachoTheme.secondaryText
        adminLegacyFilesRootStatusLabel.font = .systemFont(ofSize: 10.5)
        adminLegacyFilesRootStatusLabel.lineBreakMode = .byTruncatingMiddle
        let legacyCard = advancedSectionCard(title: L("Classic / Legacy File Root"), symbol: "folder.fill", content: [
            advancedHelp(L("Optional absolute server path used only by Classic / legacy clients.")),
            adminLegacyFilesRootField,
            advancedHelp(L("Leave empty to use the normal File Root. Account-group roots stay relative to this base.")),
            adminLegacyFilesRootStatusLabel,
        ])

        advancedRebuildIndexButton.target = self
        advancedRebuildIndexButton.action = #selector(rebuildSearchIndex(_:))
        advancedRebuildIndexButton.image = symbolImage("magnifyingglass", fallback: NSImage.actionTemplateName)
        advancedRebuildIndexButton.imagePosition = .imageLeading
        advancedEmptyTrashButton.target = self
        advancedEmptyTrashButton.action = #selector(emptyLocalServerTrash(_:))
        advancedEmptyTrashButton.image = symbolImage("trash", fallback: NSImage.trashEmptyName)
        advancedEmptyTrashButton.imagePosition = .imageLeading
        advancedEmptyTrashButton.contentTintColor = .systemRed
        let maintenanceIndexRow = horizontalStack([NSTextField(labelWithString: L("Search index")), NSView(), advancedRebuildIndexButton], spacing: 10)
        let maintenanceTrashRow = horizontalStack([NSTextField(labelWithString: L("Server Trash")), NSView(), advancedEmptyTrashButton], spacing: 10)
        maintenanceIndexRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        maintenanceTrashRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        let maintenanceCard = advancedSectionCard(title: L("Maintenance"), symbol: "wrench.and.screwdriver.fill", content: [
            maintenanceIndexRow,
            maintenanceTrashRow,
            advancedHelp(L("Maintenance actions run immediately and are not part of Save Changes.")),
        ])

        adminSearchIndexExclusionsView.isRichText = false
        adminSearchIndexExclusionsView.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        adminSearchIndexExclusionsView.textContainerInset = NSSize(width: 7, height: 7)
        let exclusionsScroll = textScroll(adminSearchIndexExclusionsView)
        exclusionsScroll.heightAnchor.constraint(equalToConstant: 104).isActive = true
        adminSearchIndexExclusionsStatusLabel.textColor = CarrachoTheme.secondaryText
        adminSearchIndexExclusionsStatusLabel.font = .systemFont(ofSize: 10.5)
        adminSearchIndexExclusionsStatusLabel.lineBreakMode = .byTruncatingTail
        let exclusionsCard = advancedSectionCard(title: L("Search Index Exclusions"), symbol: "doc.text.fill", content: [
            advancedHelp(L("One filename or glob pattern per line, for example .DS_Store or *.tmp.")),
            exclusionsScroll,
            advancedHelp(L("Matching entries stay visible in Files but are omitted from File Search.")),
            adminSearchIndexExclusionsStatusLabel,
        ])

        adminIPRulesView.isRichText = false
        adminIPRulesView.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        adminIPRulesView.textContainerInset = NSSize(width: 7, height: 7)
        let bansScroll = textScroll(adminIPRulesView)
        bansScroll.heightAnchor.constraint(equalToConstant: 104).isActive = true
        adminBanStatusLabel.textColor = CarrachoTheme.secondaryText
        adminBanStatusLabel.font = .systemFont(ofSize: 10.5)
        adminBanStatusLabel.lineBreakMode = .byTruncatingTail
        let bansCard = advancedSectionCard(title: L("Banned IP Addresses"), symbol: "nosign", content: [
            advancedHelp(L("One IPv4 address per line. Other legacy allow/deny rules are preserved automatically.")),
            bansScroll,
            advancedHelp(L("Banned addresses are denied access until removed and saved again.")),
            adminBanStatusLabel,
        ])

        let grid = ResponsiveAdvancedGridView(cards: [
            connectionsCard, transfersCard,
            legacyCard, maintenanceCard,
            exclusionsCard, bansCard,
        ])

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = CarrachoFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.addSubview(grid)

        advancedSaveStatusLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        advancedSaveStatusLabel.textColor = CarrachoTheme.secondaryText
        advancedSaveStatusLabel.lineBreakMode = .byTruncatingTail
        advancedSaveStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        advancedResetButton.target = self
        advancedResetButton.action = #selector(resetAdvancedChanges(_:))
        advancedResetButton.bezelStyle = .rounded
        advancedSaveButton.target = self
        advancedSaveButton.action = #selector(saveAllAdvancedChanges(_:))
        CarrachoTheme.applyPrimaryButtonStyle(advancedSaveButton)
        advancedSaveButton.keyEquivalent = "\r"
        advancedSaveButton.toolTip = L("Save all changed Advanced settings")

        let actionBar = CarrachoBackgroundView()
        actionBar.fillColor = CarrachoTheme.elevatedCard
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        let actionDivider = CarrachoDividerView()
        actionDivider.translatesAutoresizingMaskIntoConstraints = false
        actionBar.addSubview(actionDivider)
        let actionRow = horizontalStack([advancedSaveStatusLabel, NSView(), advancedResetButton, advancedSaveButton], spacing: 10)
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        actionBar.addSubview(actionRow)

        page.addSubview(scroll)
        page.addSubview(actionBar)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: actionBar.topAnchor),

            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 2),
            grid.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -2),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),

            actionBar.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: page.bottomAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 54),
            actionDivider.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor),
            actionDivider.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor),
            actionDivider.topAnchor.constraint(equalTo: actionBar.topAnchor),
            actionDivider.heightAnchor.constraint(equalToConstant: 1),
            actionRow.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor, constant: 14),
            actionRow.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor, constant: -14),
            actionRow.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor, constant: 1),
        ])

        updateAdvancedSaveUI()
        return page
    }

    func markAdvancedDirty(bandwidth: Bool = false) {
        guard !advancedSaveInProgress else { return }
        advancedHasUnsavedChanges = true
        if bandwidth { advancedBandwidthDirty = true }
        advancedSaveStatusOverride = nil
        advancedSaveStatusColor = nil
        updateAdvancedSaveUI()
    }

    @objc func advancedPopupChanged(_ sender: NSPopUpButton) {
        markAdvancedDirty()
    }

    @objc func advancedBandwidthUnitChanged(_ sender: NSPopUpButton) {
        if !advancedBandwidthDirty, let value = currentConfiguredTransferBandwidth() {
            transferBandwidthField.stringValue = Self.transferBandwidthInputDisplay(value, unitIndex: sender.indexOfSelectedItem)
        }
        markAdvancedDirty(bandwidth: true)
    }

    @objc func advancedControlCommitted(_ sender: Any?) {
        markAdvancedDirty(bandwidth: sender as AnyObject === transferBandwidthField)
    }

    func updateAdvancedSaveUI() {
        let canEdit = client.isConnected
            ? remotePermissionEnabled(LegacyAccountPermissionBit.editAdvancedSettings)
            : serverBackend != nil
        let remoteReady = !client.isConnected || (
            advancedRemoteCoreLoaded && advancedRemoteLegacyRootLoaded &&
            advancedRemoteExclusionsLoaded && advancedRemoteBansLoaded &&
            remoteTransferUploadLimitBytesPerSecond != nil
        )
        let editorEnabled = canEdit && !advancedSaveInProgress

        for field in [adminMaxConnectionsField, adminMaxConnectionsPerIPField,
                      adminMaxTransfersField, adminMaxTransfersPerUserField,
                      adminMaxFolderDepthField, adminLegacyFilesRootField,
                      transferBandwidthField] {
            field.isEnabled = editorEnabled
        }
        adminAuthenticationModePopup.isEnabled = editorEnabled
        transferBandwidthUnitPopup.isEnabled = editorEnabled
        adminSearchIndexExclusionsView.isEditable = editorEnabled
        adminSearchIndexExclusionsView.isSelectable = true
        adminIPRulesView.isEditable = editorEnabled && client.isConnected
        adminIPRulesView.isSelectable = true

        advancedSaveButton.isEnabled = editorEnabled && remoteReady && advancedHasUnsavedChanges
        advancedResetButton.isEnabled = !advancedSaveInProgress && advancedHasUnsavedChanges
        let canRebuildSearchIndex = client.isConnected
            ? remotePermissionEnabled(LegacyAccountPermissionBit.editAdvancedSettings)
            : localServerRuntime != nil
        advancedRebuildIndexButton.isEnabled = canRebuildSearchIndex && !advancedSaveInProgress && !advancedSearchIndexRebuildInProgress
        let canEmptyTrash = client.isConnected
            ? remotePermissionEnabled(LegacyAccountPermissionBit.emptyServerTrash)
            : localServerRuntime != nil
        advancedEmptyTrashButton.isEnabled = canEmptyTrash && !advancedSaveInProgress && !advancedTrashOperationInProgress
        advancedEmptyTrashButton.toolTip = client.isConnected && !canEmptyTrash
            ? L("This account is not allowed to empty the server Trash.")
            : nil

        if advancedSaveInProgress {
            advancedSaveStatusLabel.stringValue = L("Saving changes…")
            advancedSaveStatusLabel.textColor = CarrachoTheme.secondaryText
        } else if let override = advancedSaveStatusOverride {
            advancedSaveStatusLabel.stringValue = override
            advancedSaveStatusLabel.textColor = advancedSaveStatusColor ?? CarrachoTheme.secondaryText
        } else if advancedHasUnsavedChanges {
            advancedSaveStatusLabel.stringValue = remoteReady ? L("Unsaved changes") : L("Unsaved changes · waiting for server settings")
            advancedSaveStatusLabel.textColor = CarrachoTheme.warning
        } else {
            advancedSaveStatusLabel.stringValue = client.isConnected ? L("Editing connected server") : L("Editing local server")
            advancedSaveStatusLabel.textColor = CarrachoTheme.secondaryText
        }
    }

    @objc func resetAdvancedChanges(_ sender: Any?) {
        guard !advancedSaveInProgress else { return }
        advancedHasUnsavedChanges = false
        advancedBandwidthDirty = false
        advancedSaveStatusOverride = L("Reloading current values…")
        advancedSaveStatusColor = CarrachoTheme.secondaryText
        if client.isConnected {
            advancedRemoteCoreLoaded = false
            advancedRemoteLegacyRootLoaded = false
            advancedRemoteExclusionsLoaded = false
            advancedRemoteBansLoaded = false
        }
        updateAdvancedSaveUI()
        reloadAdvancedSettings()
        reloadTransferBandwidthAdministration()
        reloadLegacyFilesRoot()
        reloadSearchIndexExclusions()
        reloadBanManagement()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.advancedHasUnsavedChanges, !self.advancedSaveInProgress else { return }
            self.advancedSaveStatusOverride = L("Current values restored")
            self.advancedSaveStatusColor = CarrachoTheme.success
            self.updateAdvancedSaveUI()
        }
    }

    @objc func saveAllAdvancedChanges(_ sender: Any?) {
        guard advancedHasUnsavedChanges, !advancedSaveInProgress else { return }
        do {
            let maxConnections = try parseUInt16(adminMaxConnectionsField, name: L("Max. connections"), requirePositive: true)
            let maxConnectionsPerIP = try parseUInt16(adminMaxConnectionsPerIPField, name: L("Max. connections per IP"), requirePositive: true)
            let maxTransfers = try parseUInt16(adminMaxTransfersField, name: L("Max. simultaneous file transfers"), requirePositive: true)
            let maxTransfersPerUser = try parseUInt16(adminMaxTransfersPerUserField, name: L("Max. file transfers per user"), requirePositive: true)
            let maxFolderDepth = try parseUInt16(adminMaxFolderDepthField, name: L("Max. folder download depth"), requirePositive: false)
            let authenticationMode: ServerAuthenticationMode = adminAuthenticationModePopup.indexOfSelectedItem == 1 ? .modernOnly : .legacyCompatible
            let legacyRoot = adminLegacyFilesRootField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard legacyRoot.isEmpty || NSString(string: legacyRoot).isAbsolutePath else {
                throw ServerStateError.invalidValue(L("Classic / Legacy File Root must be empty or an absolute server path."))
            }
            guard legacyRoot.utf8.count < 4096, !legacyRoot.contains("\0") else {
                throw ServerStateError.invalidValue(L("Classic / Legacy File Root is invalid or too long."))
            }
            let exclusions = try parseSearchIndexExclusions(adminSearchIndexExclusionsView.string)
            let bandwidth = try transferBandwidthBytesPerSecond()
            let bans = client.isConnected ? try parseBannedIPv4Addresses(adminIPRulesView.string) : []

            let previousMode: ServerAuthenticationMode
            if client.isConnected {
                guard remotePermissionEnabled(LegacyAccountPermissionBit.editAdvancedSettings) else {
                    throw ServerStateError.invalidValue(L("This account cannot edit advanced server settings."))
                }
                guard advancedRemoteCoreLoaded, advancedRemoteLegacyRootLoaded,
                      advancedRemoteExclusionsLoaded, advancedRemoteBansLoaded,
                      remoteTransferUploadLimitBytesPerSecond != nil,
                      let loadedMode = remoteAdvancedAuthenticationMode else {
                    throw ServerStateError.invalidValue(L("Advanced settings are still loading from the connected server. Please try again in a moment."))
                }
                previousMode = loadedMode
            } else {
                guard serverBackend != nil else {
                    throw ServerStateError.invalidValue(L("Server backend is unavailable."))
                }
                previousMode = localServerState.authentication.mode
            }

            let performSave = { [weak self] in
                guard let self else { return }
                if self.client.isConnected {
                    self.saveRemoteAdvancedChanges(maxConnections: maxConnections,
                                                   maxConnectionsPerIP: maxConnectionsPerIP,
                                                   maxTransfers: maxTransfers,
                                                   maxTransfersPerUser: maxTransfersPerUser,
                                                   maxFolderDepth: maxFolderDepth,
                                                   authenticationMode: authenticationMode,
                                                   legacyRoot: legacyRoot,
                                                   exclusions: exclusions,
                                                   bandwidth: bandwidth,
                                                   bans: bans)
                } else {
                    self.saveLocalAdvancedChanges(maxConnections: maxConnections,
                                                  maxConnectionsPerIP: maxConnectionsPerIP,
                                                  maxTransfers: maxTransfers,
                                                  maxTransfersPerUser: maxTransfersPerUser,
                                                  maxFolderDepth: maxFolderDepth,
                                                  authenticationMode: authenticationMode,
                                                  legacyRoot: legacyRoot,
                                                  exclusions: exclusions,
                                                  bandwidth: bandwidth)
                }
            }

            if previousMode == .legacyCompatible && authenticationMode == .modernOnly {
                guard let window = view.window else { performSave(); return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L("Enable Modern-only Authentication?")
                alert.informativeText = L("This permanently removes legacy password-equivalent material from all persisted accounts. Modern logins continue to work, but Classic Carracho clients are rejected. If Legacy compatibility is enabled again later, affected account passwords must be reset first.")
                alert.addButton(withTitle: L("Enable Modern only"))
                alert.addButton(withTitle: L("Cancel"))
                alert.beginSheetModal(for: window) { [weak self] response in
                    if response == .alertFirstButtonReturn {
                        performSave()
                    } else {
                        self?.advancedSaveStatusOverride = L("Save cancelled · changes remain unsaved")
                        self?.advancedSaveStatusColor = CarrachoTheme.warning
                        self?.updateAdvancedSaveUI()
                    }
                }
            } else {
                performSave()
            }
        } catch {
            advancedSaveStatusOverride = Self.displayMessage(for: error)
            advancedSaveStatusColor = .systemRed
            updateAdvancedSaveUI()
            showAdminError(error)
        }
    }

    func saveLocalAdvancedChanges(maxConnections: UInt16, maxConnectionsPerIP: UInt16,
                                          maxTransfers: UInt16, maxTransfersPerUser: UInt16,
                                          maxFolderDepth: UInt16, authenticationMode: ServerAuthenticationMode,
                                          legacyRoot: String, exclusions: [String], bandwidth: UInt64) {
        guard let backend = serverBackend else { return }
        advancedSaveInProgress = true
        advancedSaveStatusOverride = nil
        advancedSaveStatusColor = nil
        updateAdvancedSaveUI()
        do {
            if !legacyRoot.isEmpty {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: legacyRoot, isDirectory: true),
                                                        withIntermediateDirectories: true)
            }
            var advanced = localServerState.advanced
            advanced.maxConnections = maxConnections
            advanced.maxConnectionsPerIP = maxConnectionsPerIP
            advanced.maxSimultaneousFileTransfers = maxTransfers
            advanced.maxFileTransfersPerUser = maxTransfersPerUser
            advanced.maxFolderDownloadDepth = maxFolderDepth

            var runtime = localServerState.runtime
            let exclusionsChanged = runtime.searchIndexExclusions != exclusions
            runtime.legacyFilesRoot = legacyRoot
            runtime.searchIndexExclusions = exclusions
            runtime.uploadBandwidthLimitBytesPerSecond = bandwidth

            let wasRunning = localServerRuntime?.status.isRunning == true
            try backend.updateAdvanced(advanced, authenticationMode: authenticationMode)
            try backend.updateRuntime(runtime)
            localServerRuntime?.configureDownloadBandwidthLimit(bandwidth)
            try localServerRuntime?.persistStartupConfigurationToJSON(backend.snapshot())
            try persistLocalLegacyFilesRootToConfig(legacyRoot)
            try persistLocalSearchIndexExclusionsToConfig(exclusions)
            if exclusionsChanged {
                localServerRuntime?.rebuildSearchIndexInBackground(reason: "search-index exclusions changed")
            }
            if wasRunning {
                localServerRuntime?.refreshNewsConfiguration()
                localServerRuntime?.refreshTrackerConfiguration()
            }

            advancedSaveInProgress = false
            advancedHasUnsavedChanges = false
            advancedBandwidthDirty = false
            advancedSaveStatusOverride = authenticationMode == .legacyCompatible && backend.snapshot().accounts.contains(where: { $0.legacyPassword == nil })
                ? L("Saved · some accounts need a password reset for Classic clients")
                : L("Changes saved")
            advancedSaveStatusColor = CarrachoTheme.success
            reloadLocalStateFromBackend()
            refreshTransferBandwidthControls()
            updateAdvancedSaveUI()
            showAdminSaved(L("Advanced settings saved."))
        } catch {
            advancedSaveInProgress = false
            advancedHasUnsavedChanges = true
            advancedSaveStatusOverride = LF("Save failed: %@", Self.displayMessage(for: error))
            advancedSaveStatusColor = .systemRed
            updateAdvancedSaveUI()
            showAdminError(error)
        }
    }

    static func displayedRemoteFolderDepth(_ wireValue: UInt16) -> UInt16 {
        // Some older Carracho Server builds could not persist the documented wire value 0
        // and silently restored their default (8). UInt16.max is therefore also accepted as
        // a compatibility sentinel for "unlimited" when reading a remote server.
        wireValue == UInt16.max ? 0 : wireValue
    }

    func ensureRemoteUnlimitedFolderDepth(completion: @escaping (Result<Void, Error>) -> Void) {
        func decode(_ data: Data) throws -> UInt16 {
            var cursor = LegacyByteCursor(data)
            let value = try cursor.readUInt16BE()
            try cursor.requireEnd()
            return value
        }

        client.requestServerSettings(fields: [LegacyServerSettingField.maxFolderDownloadDepth]) { [weak self] result in
            guard let self else { return }
            do {
                let values = try result.get()
                guard let data = values[LegacyServerSettingField.maxFolderDownloadDepth] else {
                    throw LegacyProtocolError.invalidRecord("server did not return max folder download depth")
                }
                let value = try decode(data)
                if value == 0 || value == UInt16.max {
                    completion(.success(()))
                    return
                }

                // Compatibility fallback for servers affected by the historical 0 -> 8
                // persistence bug. 65535 is effectively unlimited for a filesystem tree and,
                // unlike 0, is preserved by those builds. The UI maps it back to 0.
                self.appendLine("\n" + LF("Connected server rewrote folder depth 0 to %@; using compatibility unlimited value.", String(value)))
                self.client.setServerSettings([
                    LegacyTLV(type: LegacyServerSettingField.maxFolderDownloadDepth,
                              value: LegacyWire.uint16BE(UInt16.max)),
                ]) { setResult in
                    switch setResult {
                    case .success:
                        completion(.success(()))
                    case let .failure(error):
                        completion(.failure(error))
                    }
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    func saveRemoteAdvancedChanges(maxConnections: UInt16, maxConnectionsPerIP: UInt16,
                                           maxTransfers: UInt16, maxTransfersPerUser: UInt16,
                                           maxFolderDepth: UInt16, authenticationMode: ServerAuthenticationMode,
                                           legacyRoot: String, exclusions: [String], bandwidth: UInt64,
                                           bans: [ServerIPRestriction]) {
        let exclusionsData: Data
        do {
            exclusionsData = try LegacyServerSettingField.encodeSearchIndexExclusions(exclusions)
        } catch {
            showAdminError(error)
            return
        }

        advancedSaveInProgress = true
        advancedSaveStatusOverride = nil
        advancedSaveStatusColor = nil
        updateAdvancedSaveUI()

        let group = DispatchGroup()
        let lock = NSLock()
        var successes: [String] = []
        var failures: [String] = []
        var coreSaved = false
        var bandwidthSnapshot: LegacyTransferMonitorSnapshot?

        func record(_ name: String, error: Error? = nil) {
            lock.lock()
            if let error {
                failures.append("\(name): \(Self.displayMessage(for: error))")
            } else {
                successes.append(name)
            }
            lock.unlock()
        }

        let settings = [
            LegacyTLV(type: LegacyServerSettingField.authenticationMode,
                      value: LegacyServerSettingField.encodeAuthenticationMode(modernOnly: authenticationMode == .modernOnly)),
            LegacyTLV(type: LegacyServerSettingField.maxConnections, value: LegacyWire.uint16BE(maxConnections)),
            LegacyTLV(type: LegacyServerSettingField.maxConnectionsPerIP, value: LegacyWire.uint16BE(maxConnectionsPerIP)),
            LegacyTLV(type: LegacyServerSettingField.maxSimultaneousFileTransfers, value: LegacyWire.uint16BE(maxTransfers)),
            LegacyTLV(type: LegacyServerSettingField.maxFileTransfersPerUser, value: LegacyWire.uint16BE(maxTransfersPerUser)),
            LegacyTLV(type: LegacyServerSettingField.maxFolderDownloadDepth, value: LegacyWire.uint16BE(maxFolderDepth)),
            LegacyTLV(type: LegacyServerSettingField.legacyFilesRoot, value: Data(legacyRoot.utf8)),
            LegacyTLV(type: LegacyServerSettingField.searchIndexExclusions, value: exclusionsData),
        ]
        group.enter()
        client.setServerSettings(settings) { result in
            switch result {
            case .success:
                lock.lock(); coreSaved = true; lock.unlock()
                record(L("settings"))
            case let .failure(error): record(L("settings"), error: error)
            }
            group.leave()
        }

        group.enter()
        client.setTransferUploadBandwidthLimit(bytesPerSecond: bandwidth) { result in
            switch result {
            case let .success(snapshot):
                lock.lock(); bandwidthSnapshot = snapshot; lock.unlock()
                record(L("upload limit"))
            case let .failure(error): record(L("upload limit"), error: error)
            }
            group.leave()
        }

        group.enter()
        client.requestServerSettings(fields: [LegacyServerSettingField.allowDenyIPList]) { [weak self] result in
            guard let self else { group.leave(); return }
            do {
                let values = try result.get()
                guard let currentData = values[LegacyServerSettingField.allowDenyIPList] else {
                    throw LegacyProtocolError.invalidRecord("server did not return the current ban list")
                }
                let current = try LegacyServerSettingField.decodeIPRestrictions(currentData).map(ServerIPRestriction.init(legacy:))
                let preserved = current.filter { !Self.isSimpleIPv4Ban($0) }
                let data = try LegacyServerSettingField.encodeIPRestrictions((bans + preserved).map(\.legacy))
                self.client.setServerSettings([LegacyTLV(type: LegacyServerSettingField.allowDenyIPList, value: data)]) { result in
                    switch result {
                    case .success: record(L("IP bans"))
                    case let .failure(error): record(L("IP bans"), error: error)
                    }
                    group.leave()
                }
            } catch {
                record(L("IP bans"), error: error)
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            lock.lock()
            let saved = successes
            let errors = failures
            let didSaveCore = coreSaved
            let snapshot = bandwidthSnapshot
            lock.unlock()

            if didSaveCore { self.remoteAdvancedAuthenticationMode = authenticationMode }
            if let snapshot { self.applyRemoteTransferMonitor(snapshot) }

            let finishSuccess = { [weak self] in
                guard let self else { return }
                self.advancedSaveInProgress = false
                self.advancedHasUnsavedChanges = false
                self.advancedBandwidthDirty = false
                self.advancedSaveStatusOverride = L("Changes saved on connected server")
                self.advancedSaveStatusColor = CarrachoTheme.success
                self.updateAdvancedSaveUI()
                self.showAdminSaved(L("Advanced settings saved on the connected server."))
                self.reloadAdvancedSettings()
                self.reloadLegacyFilesRoot()
                self.reloadSearchIndexExclusions()
                self.reloadBanManagement()
                self.reloadTransferBandwidthAdministration()
            }

            if errors.isEmpty {
                if didSaveCore && maxFolderDepth == 0 {
                    self.advancedSaveStatusOverride = L("Verifying unlimited folder depth…")
                    self.advancedSaveStatusColor = CarrachoTheme.secondaryText
                    self.updateAdvancedSaveUI()
                    self.ensureRemoteUnlimitedFolderDepth { [weak self] result in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            switch result {
                            case .success:
                                finishSuccess()
                            case let .failure(error):
                                self.advancedSaveInProgress = false
                                self.advancedHasUnsavedChanges = true
                                self.advancedSaveStatusOverride = LF("Folder depth save failed: %@", Self.displayMessage(for: error))
                                self.advancedSaveStatusColor = .systemRed
                                self.updateAdvancedSaveUI()
                                self.appendLine("\n" + LF("Folder depth compatibility save failed: %@", Self.displayMessage(for: error)))
                            }
                        }
                    }
                } else {
                    finishSuccess()
                }
            } else {
                self.advancedSaveInProgress = false
                self.advancedHasUnsavedChanges = true
                let prefix = saved.isEmpty ? L("Save failed") : L("Partially saved")
                self.advancedSaveStatusOverride = "\(prefix): \(errors.joined(separator: " · "))"
                self.advancedSaveStatusColor = .systemRed
                self.updateAdvancedSaveUI()
                self.appendLine("\n" + LF("Advanced settings %@: %@", prefix.lowercased(), errors.joined(separator: "; ")))
            }
        }
    }

    func reloadAdvancedSettings() {
        guard client.isConnected else {
            advancedRemoteCoreLoaded = false
            refreshAdminControls()
            updateAdvancedSaveUI()
            return
        }
        advancedRemoteCoreLoaded = false
        updateAdvancedSaveUI()
        guard remotePermissionEnabled(LegacyAccountPermissionBit.editAdvancedSettings) else {
            remoteAdvancedAuthenticationMode = nil
            updateAdvancedSaveUI()
            return
        }
        let fields: [UInt32] = [
            LegacyServerSettingField.authenticationMode,
            LegacyServerSettingField.maxConnections,
            LegacyServerSettingField.maxConnectionsPerIP,
            LegacyServerSettingField.maxSimultaneousFileTransfers,
            LegacyServerSettingField.maxFileTransfersPerUser,
            LegacyServerSettingField.maxFolderDownloadDepth,
        ]
        client.requestServerSettings(fields: fields) { [weak self] result in
            guard let self else { return }
            do {
                let values = try result.get()
                guard let auth = values[LegacyServerSettingField.authenticationMode],
                      let maxConnections = values[LegacyServerSettingField.maxConnections],
                      let maxConnectionsPerIP = values[LegacyServerSettingField.maxConnectionsPerIP],
                      let maxTransfers = values[LegacyServerSettingField.maxSimultaneousFileTransfers],
                      let maxTransfersPerUser = values[LegacyServerSettingField.maxFileTransfersPerUser],
                      let maxFolderDepth = values[LegacyServerSettingField.maxFolderDownloadDepth] else {
                    throw LegacyProtocolError.invalidRecord("connected server did not return complete advanced settings")
                }
                let modernOnly = try LegacyServerSettingField.decodeAuthenticationMode(auth)
                func u16(_ data: Data) throws -> UInt16 {
                    var cursor = LegacyByteCursor(data)
                    let value = try cursor.readUInt16BE()
                    try cursor.requireEnd()
                    return value
                }
                self.remoteAdvancedAuthenticationMode = modernOnly ? .modernOnly : .legacyCompatible
                self.adminAuthenticationModePopup.selectItem(at: modernOnly ? 1 : 0)
                self.adminMaxConnectionsField.stringValue = String(try u16(maxConnections))
                self.adminMaxConnectionsPerIPField.stringValue = String(try u16(maxConnectionsPerIP))
                self.adminMaxTransfersField.stringValue = String(try u16(maxTransfers))
                self.adminMaxTransfersPerUserField.stringValue = String(try u16(maxTransfersPerUser))
                let remoteFolderDepth = try u16(maxFolderDepth)
                self.adminMaxFolderDepthField.stringValue = String(Self.displayedRemoteFolderDepth(remoteFolderDepth))
                self.advancedRemoteCoreLoaded = true
                self.updateAdvancedSaveUI()
            } catch {
                self.advancedRemoteCoreLoaded = false
                self.updateAdvancedSaveUI()
                self.showAdminError(error)
            }
        }
    }

    @objc func rebuildSearchIndex(_ sender: Any?) {
        if client.isConnected {
            guard remotePermissionEnabled(LegacyAccountPermissionBit.editAdvancedSettings) else {
                showAdminError(ServerStateError.invalidValue(L("This account cannot edit advanced server settings.")))
                return
            }
            guard !advancedSearchIndexRebuildInProgress else { return }
            advancedSearchIndexRebuildInProgress = true
            updateAdvancedSaveUI()
            let target = client
            target.rebuildServerSearchIndex { [weak self, weak target] result in
                guard let self, let target, self.client === target else { return }
                self.advancedSearchIndexRebuildInProgress = false
                self.updateAdvancedSaveUI()
                switch result {
                case .success:
                    self.showAdminSaved(L("Search-index rebuild queued on the connected server."))
                case let .failure(error):
                    self.showAdminError(error)
                }
            }
            return
        }

        guard let runtime = localServerRuntime else {
            showAdminError(ServerStateError.invalidValue(L("Server runtime is unavailable."))); return
        }
        do {
            let count = try runtime.rebuildSearchIndex()
            showAdminSaved(LF("Search inventory rebuilt: %@ searchable item(s).", String(count)))
        } catch { showAdminError(error) }
    }

    @objc func saveAdvancedSettings(_ sender: Any?) {
        do {
            let maxConnections = try parseUInt16(adminMaxConnectionsField, name: L("Max. connections"), requirePositive: true)
            let maxConnectionsPerIP = try parseUInt16(adminMaxConnectionsPerIPField, name: L("Max. connections per IP"), requirePositive: true)
            let maxTransfers = try parseUInt16(adminMaxTransfersField, name: L("Max. simultaneous file transfers"), requirePositive: true)
            let maxTransfersPerUser = try parseUInt16(adminMaxTransfersPerUserField, name: L("Max. file transfers per user"), requirePositive: true)
            let maxFolderDepth = try parseUInt16(adminMaxFolderDepthField, name: L("Max. folder download depth"), requirePositive: false)
            let requestedMode: ServerAuthenticationMode = adminAuthenticationModePopup.indexOfSelectedItem == 1 ? .modernOnly : .legacyCompatible

            let commit: () -> Void
            let previousMode: ServerAuthenticationMode
            if client.isConnected {
                guard remotePermissionEnabled(LegacyAccountPermissionBit.editAdvancedSettings) else {
                    throw ServerStateError.invalidValue(L("This account cannot edit advanced server settings."))
                }
                guard let loadedMode = remoteAdvancedAuthenticationMode else {
                    throw ServerStateError.invalidValue(L("Advanced settings are still loading from the connected server. Please try again in a moment."))
                }
                previousMode = loadedMode
                commit = { [weak self] in
                    self?.commitRemoteAdvancedSettings(maxConnections: maxConnections,
                                                       maxConnectionsPerIP: maxConnectionsPerIP,
                                                       maxTransfers: maxTransfers,
                                                       maxTransfersPerUser: maxTransfersPerUser,
                                                       maxFolderDepth: maxFolderDepth,
                                                       authenticationMode: requestedMode)
                }
            } else {
                guard serverBackend != nil else {
                    throw ServerStateError.invalidValue(L("Server backend is unavailable."))
                }
                previousMode = localServerState.authentication.mode
                var advanced = localServerState.advanced
                advanced.maxConnections = maxConnections
                advanced.maxConnectionsPerIP = maxConnectionsPerIP
                advanced.maxSimultaneousFileTransfers = maxTransfers
                advanced.maxFileTransfersPerUser = maxTransfersPerUser
                advanced.maxFolderDownloadDepth = maxFolderDepth
                commit = { [weak self] in self?.commitAdvancedSettings(advanced, authenticationMode: requestedMode) }
            }

            if previousMode == .legacyCompatible && requestedMode == .modernOnly {
                guard let window = view.window else { commit(); return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L("Enable Modern-only Authentication?")
                alert.informativeText = L("This permanently removes legacy password-equivalent material from all persisted accounts. Modern logins continue to work, but Classic Carracho clients are rejected. If Legacy compatibility is enabled again later, affected account passwords must be reset first.")
                alert.addButton(withTitle: L("Enable Modern only"))
                alert.addButton(withTitle: L("Cancel"))
                alert.beginSheetModal(for: window) { [weak self] response in
                    guard response == .alertFirstButtonReturn else {
                        self?.adminAuthenticationModePopup.selectItem(at: 0)
                        return
                    }
                    commit()
                }
            } else {
                commit()
            }
        } catch { showAdminError(error) }
    }

    func commitRemoteAdvancedSettings(maxConnections: UInt16, maxConnectionsPerIP: UInt16,
                                              maxTransfers: UInt16, maxTransfersPerUser: UInt16,
                                              maxFolderDepth: UInt16, authenticationMode: ServerAuthenticationMode) {
        let fields = [
            LegacyTLV(type: LegacyServerSettingField.authenticationMode,
                      value: LegacyServerSettingField.encodeAuthenticationMode(modernOnly: authenticationMode == .modernOnly)),
            LegacyTLV(type: LegacyServerSettingField.maxConnections, value: LegacyWire.uint16BE(maxConnections)),
            LegacyTLV(type: LegacyServerSettingField.maxConnectionsPerIP, value: LegacyWire.uint16BE(maxConnectionsPerIP)),
            LegacyTLV(type: LegacyServerSettingField.maxSimultaneousFileTransfers, value: LegacyWire.uint16BE(maxTransfers)),
            LegacyTLV(type: LegacyServerSettingField.maxFileTransfersPerUser, value: LegacyWire.uint16BE(maxTransfersPerUser)),
            LegacyTLV(type: LegacyServerSettingField.maxFolderDownloadDepth, value: LegacyWire.uint16BE(maxFolderDepth)),
        ]
        client.setServerSettings(fields) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.remoteAdvancedAuthenticationMode = authenticationMode
                self.showAdminSaved(authenticationMode == .legacyCompatible
                    ? L("Advanced settings saved on the connected server. Accounts whose legacy password was previously removed may need a password reset for Classic clients.")
                    : L("Advanced settings saved on the connected server. Classic connections are now disabled."))
                self.reloadAdvancedSettings()
            case let .failure(error):
                self.showAdminError(error)
                self.reloadAdvancedSettings()
            }
        }
    }

    func commitAdvancedSettings(_ advanced: ServerAdvancedSettings, authenticationMode: ServerAuthenticationMode) {
        guard let backend = serverBackend else { return }
        do {
            let wasRunning = localServerRuntime?.status.isRunning == true
            try backend.updateAdvanced(advanced, authenticationMode: authenticationMode)
            try localServerRuntime?.persistStartupConfigurationToJSON(backend.snapshot())
            reloadLocalStateFromBackend()
            if wasRunning {
                localServerRuntime?.refreshNewsConfiguration()
                localServerRuntime?.refreshTrackerConfiguration()
            }
            if authenticationMode == .legacyCompatible && localServerState.accounts.contains(where: { $0.legacyPassword == nil }) {
                showAdminSaved(L("Advanced settings saved. Some accounts need a password reset before Classic clients can use them again."))
            } else {
                showAdminSaved(L("Advanced settings saved."))
            }
        } catch { showAdminError(error) }
    }

    @objc func emptyLocalServerTrash(_ sender: Any?) {
        let remote = client.isConnected
        if remote {
            guard remotePermissionEnabled(LegacyAccountPermissionBit.emptyServerTrash) else {
                showAdminError(ServerStateError.invalidValue(L("This account is not allowed to empty the server Trash.")))
                return
            }
        } else if localServerRuntime == nil {
            showAdminError(ServerStateError.invalidValue(L("Server runtime is unavailable.")))
            return
        }

        let perform = { [weak self] in
            guard let self else { return }
            if remote {
                self.advancedTrashOperationInProgress = true
                self.updateAdvancedSaveUI()
                let target = self.client
                target.emptyServerTrash { [weak self, weak target] result in
                    guard let self, let target, self.client === target else { return }
                    self.advancedTrashOperationInProgress = false
                    self.updateAdvancedSaveUI()
                    switch result {
                    case .success:
                        self.showAdminSaved(L("Server Trash emptied."))
                    case let .failure(error):
                        self.showAdminError(error)
                    }
                }
            } else if let runtime = self.localServerRuntime {
                do {
                    try runtime.emptyTrash()
                    self.showAdminSaved(L("Server Trash emptied."))
                } catch {
                    self.showAdminError(error)
                }
            }
        }

        guard let window = view.window else { perform(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Empty Server Trash")
        alert.informativeText = L("Permanently remove all items previously deleted from the server storage?")
        alert.addButton(withTitle: L("Empty Trash"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { perform() }
        }
    }

    @objc func reloadLegacyFilesRootPressed(_ sender: Any?) {
        reloadLegacyFilesRoot()
    }

    func reloadLegacyFilesRoot() {
        if client.isConnected {
            advancedRemoteLegacyRootLoaded = false
            updateAdvancedSaveUI()
            guard remotePermissionEnabled(LegacyAccountPermissionBit.editAdvancedSettings) else {
                adminLegacyFilesRootField.stringValue = ""
                adminLegacyFilesRootStatusLabel.stringValue = L("This account cannot edit the Classic / Legacy File Root.")
                updateAdvancedSaveUI()
                return
            }
            adminLegacyFilesRootStatusLabel.stringValue = L("Loading Classic / Legacy File Root…")
            client.requestServerSettings(fields: [LegacyServerSettingField.legacyFilesRoot]) { [weak self] result in
                guard let self else { return }
                do {
                    let values = try result.get()
                    guard let data = values[LegacyServerSettingField.legacyFilesRoot],
                          let path = String(data: data, encoding: .utf8) else {
                        throw LegacyProtocolError.invalidRecord("server does not support a Classic / Legacy File Root")
                    }
                    self.adminLegacyFilesRootField.stringValue = path
                    self.adminLegacyFilesRootStatusLabel.stringValue = path.isEmpty
                        ? L("Classic connections use the normal File Root on the connected server.")
                        : L("Separate Classic / Legacy root on connected server.")
                    self.advancedRemoteLegacyRootLoaded = true
                    self.updateAdvancedSaveUI()
                } catch {
                    self.advancedRemoteLegacyRootLoaded = false
                    self.updateAdvancedSaveUI()
                    self.adminLegacyFilesRootStatusLabel.stringValue = LF("Could not load Legacy root: %@", Self.displayMessage(for: error))
                }
            }
            return
        }
        advancedRemoteLegacyRootLoaded = false
        let path = localServerState.runtime.legacyFilesRoot
        adminLegacyFilesRootField.stringValue = path
        adminLegacyFilesRootStatusLabel.stringValue = path.isEmpty
            ? L("Classic connections use the normal local File Root.")
            : L("Separate Classic / Legacy root is active locally.")
    }

    func persistLocalLegacyFilesRootToConfig(_ path: String) throws {
        let url = Self.modernServerDirectoryURL().appendingPathComponent("etc", isDirectory: true)
            .appendingPathComponent("carracho-server.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerStateError.invalidValue(L("carracho-server.json is not a JSON object."))
        }
        object["legacyFilesRoot"] = path
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: url, options: .atomic)
    }

    @objc func saveLegacyFilesRoot(_ sender: Any?) {
        do {
            let path = adminLegacyFilesRootField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.isEmpty || NSString(string: path).isAbsolutePath else {
                throw ServerStateError.invalidValue(L("Classic / Legacy File Root must be empty or an absolute server path."))
            }
            guard path.utf8.count < 4096, !path.contains("\0") else {
                throw ServerStateError.invalidValue(L("Classic / Legacy File Root is invalid or too long."))
            }
            if client.isConnected {
                guard remotePermissionEnabled(LegacyAccountPermissionBit.editAdvancedSettings) else {
                    throw ServerStateError.invalidValue(L("This account cannot edit advanced server settings."))
                }
                adminLegacyFilesRootStatusLabel.stringValue = L("Saving Classic / Legacy File Root…")
                client.setServerSettings([LegacyTLV(type: LegacyServerSettingField.legacyFilesRoot, value: Data(path.utf8))]) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.showAdminSaved(path.isEmpty
                            ? L("Classic connections now use the normal File Root.")
                            : L("Separate Classic / Legacy File Root saved on the connected server."))
                        self.reloadLegacyFilesRoot()
                    case let .failure(error):
                        self.adminLegacyFilesRootStatusLabel.stringValue = LF("Save failed: %@", Self.displayMessage(for: error))
                        self.showAdminError(error)
                    }
                }
                return
            }
            guard let backend = serverBackend else {
                throw ServerStateError.invalidValue(L("Server backend is unavailable."))
            }
            if !path.isEmpty {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: path, isDirectory: true), withIntermediateDirectories: true)
            }
            var runtime = localServerState.runtime
            runtime.legacyFilesRoot = path
            try backend.updateRuntime(runtime)
            try persistLocalLegacyFilesRootToConfig(path)
            reloadLocalStateFromBackend()
            showAdminSaved(path.isEmpty
                ? L("Classic connections now use the normal local File Root.")
                : L("Separate Classic / Legacy File Root saved locally."))
        } catch { showAdminError(error) }
    }

    func parseSearchIndexExclusions(_ text: String) throws -> [String] {
        var patterns: [String] = []
        var seen = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { continue }
            guard seen.insert(pattern).inserted else { continue }
            patterns.append(pattern)
        }
        _ = try LegacyServerSettingField.encodeSearchIndexExclusions(patterns)
        return patterns
    }

    @objc func reloadSearchIndexExclusionsPressed(_ sender: Any?) {
        reloadSearchIndexExclusions()
    }

    func reloadSearchIndexExclusions() {
        if client.isConnected {
            advancedRemoteExclusionsLoaded = false
            updateAdvancedSaveUI()
            guard remotePermissionEnabled(LegacyAccountPermissionBit.editAdvancedSettings) else {
                adminSearchIndexExclusionsView.string = ""
                adminSearchIndexExclusionsStatusLabel.stringValue = L("This account cannot edit search-index exclusions.")
                updateAdvancedSaveUI()
                return
            }
            adminSearchIndexExclusionsStatusLabel.stringValue = L("Loading exclusions…")
            client.requestServerSettings(fields: [LegacyServerSettingField.searchIndexExclusions]) { [weak self] result in
                guard let self else { return }
                do {
                    let values = try result.get()
                    guard let data = values[LegacyServerSettingField.searchIndexExclusions] else {
                        throw LegacyProtocolError.invalidRecord("server does not support search-index exclusions")
                    }
                    let patterns = try LegacyServerSettingField.decodeSearchIndexExclusions(data)
                    self.adminSearchIndexExclusionsView.string = patterns.joined(separator: "\n")
                    self.adminSearchIndexExclusionsStatusLabel.stringValue = patterns.count == 1 ? LF("%@ exclusion pattern on connected server", String(patterns.count)) : LF("%@ exclusion patterns on connected server", String(patterns.count))
                    self.advancedRemoteExclusionsLoaded = true
                    self.updateAdvancedSaveUI()
                } catch {
                    self.advancedRemoteExclusionsLoaded = false
                    self.updateAdvancedSaveUI()
                    self.adminSearchIndexExclusionsStatusLabel.stringValue = LF("Could not load exclusions: %@", Self.displayMessage(for: error))
                }
            }
            return
        }
        advancedRemoteExclusionsLoaded = false
        let patterns = localServerState.runtime.searchIndexExclusions
        adminSearchIndexExclusionsView.string = patterns.joined(separator: "\n")
        adminSearchIndexExclusionsStatusLabel.stringValue = patterns.count == 1 ? LF("%@ local exclusion pattern", String(patterns.count)) : LF("%@ local exclusion patterns", String(patterns.count))
    }

    func persistLocalSearchIndexExclusionsToConfig(_ patterns: [String]) throws {
        let url = Self.modernServerDirectoryURL().appendingPathComponent("etc", isDirectory: true)
            .appendingPathComponent("carracho-server.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerStateError.invalidValue(L("carracho-server.json is not a JSON object."))
        }
        object["searchIndexExclusions"] = patterns
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: url, options: .atomic)
    }

    @objc func saveSearchIndexExclusions(_ sender: Any?) {
        do {
            let patterns = try parseSearchIndexExclusions(adminSearchIndexExclusionsView.string)
            if client.isConnected {
                guard remotePermissionEnabled(LegacyAccountPermissionBit.editAdvancedSettings) else {
                    throw ServerStateError.invalidValue(L("This account cannot edit search-index exclusions."))
                }
                let value = try LegacyServerSettingField.encodeSearchIndexExclusions(patterns)
                adminSearchIndexExclusionsStatusLabel.stringValue = L("Saving exclusions…")
                client.setServerSettings([LegacyTLV(type: LegacyServerSettingField.searchIndexExclusions, value: value)]) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.showAdminSaved(L("Search-index exclusions saved on the connected server."))
                        self.reloadSearchIndexExclusions()
                    case let .failure(error):
                        self.adminSearchIndexExclusionsStatusLabel.stringValue = LF("Save failed: %@", Self.displayMessage(for: error))
                        self.showAdminError(error)
                    }
                }
                return
            }
            guard let backend = serverBackend else {
                throw ServerStateError.invalidValue(L("Server backend is unavailable."))
            }
            var runtime = localServerState.runtime
            runtime.searchIndexExclusions = patterns
            try backend.updateRuntime(runtime)
            try persistLocalSearchIndexExclusionsToConfig(patterns)
            localServerRuntime?.rebuildSearchIndexInBackground(reason: "search-index exclusions changed")
            reloadLocalStateFromBackend()
            showAdminSaved(L("Search-index exclusions saved locally."))
        } catch { showAdminError(error) }
    }

    @objc func reloadBanManagementPressed(_ sender: Any?) {
        reloadBanManagement()
    }

    func reloadBanManagement() {
        advancedRemoteBansLoaded = false
        updateAdvancedSaveUI()
        guard client.isConnected else {
            adminIPRulesView.string = ""
            adminBanStatusLabel.stringValue = L("Connect to a server to manage bans.")
            updateAdvancedSaveUI()
            return
        }
        guard remotePermissionEnabled(LegacyAccountPermissionBit.editAdvancedSettings) else {
            adminIPRulesView.string = ""
            adminBanStatusLabel.stringValue = L("This account cannot edit server IP restrictions.")
            updateAdvancedSaveUI()
            return
        }
        adminBanStatusLabel.stringValue = L("Loading ban rules…")
        client.requestServerSettings(fields: [LegacyServerSettingField.allowDenyIPList]) { [weak self] result in
            guard let self else { return }
            do {
                let values = try result.get()
                guard let data = values[LegacyServerSettingField.allowDenyIPList] else {
                    throw LegacyProtocolError.invalidRecord("server did not return the allow/deny IP list")
                }
                let rules = try LegacyServerSettingField.decodeIPRestrictions(data).map(ServerIPRestriction.init(legacy:))
                let bans = rules.filter(Self.isSimpleIPv4Ban)
                let preserved = rules.count - bans.count
                self.adminIPRulesView.string = self.renderBannedIPv4Addresses(bans)
                let base = "\(bans.count) banned IP\(bans.count == 1 ? "" : "s") on connected server"
                self.adminBanStatusLabel.stringValue = preserved > 0
                    ? base + " · \(preserved) legacy advanced rule\(preserved == 1 ? "" : "s") preserved"
                    : base
                self.advancedRemoteBansLoaded = true
                self.updateAdvancedSaveUI()
            } catch {
                self.advancedRemoteBansLoaded = false
                self.updateAdvancedSaveUI()
                self.adminBanStatusLabel.stringValue = LF("Could not load ban rules: %@", Self.displayMessage(for: error))
            }
        }
    }

    @objc func saveBanManagement(_ sender: Any?) {
        guard client.isConnected else {
            showAdminError(ServerStateError.invalidValue(L("Connect to a server before editing bans.")))
            return
        }
        guard remotePermissionEnabled(LegacyAccountPermissionBit.editAdvancedSettings) else {
            showAdminError(ServerStateError.invalidValue(L("This account cannot edit server bans.")))
            return
        }
        do {
            let bans = try parseBannedIPv4Addresses(adminIPRulesView.string)
            adminBanStatusLabel.stringValue = L("Saving bans…")
            client.requestServerSettings(fields: [LegacyServerSettingField.allowDenyIPList]) { [weak self] result in
                guard let self else { return }
                do {
                    let values = try result.get()
                    guard let currentData = values[LegacyServerSettingField.allowDenyIPList] else {
                        throw LegacyProtocolError.invalidRecord("server did not return the current ban list")
                    }
                    let current = try LegacyServerSettingField.decodeIPRestrictions(currentData).map(ServerIPRestriction.init(legacy:))
                    let preserved = current.filter { !Self.isSimpleIPv4Ban($0) }
                    let merged = bans + preserved
                    let data = try LegacyServerSettingField.encodeIPRestrictions(merged.map(\.legacy))
                    self.client.setServerSettings([LegacyTLV(type: LegacyServerSettingField.allowDenyIPList, value: data)]) { [weak self] saveResult in
                        guard let self else { return }
                        switch saveResult {
                        case .success:
                            self.adminBanStatusLabel.stringValue = bans.count == 1 ? LF("Saved %@ banned IP", String(bans.count)) : LF("Saved %@ banned IPs", String(bans.count))
                            self.showAdminSaved(L("Banned IP addresses saved on the connected server."))
                            self.reloadBanManagement()
                        case let .failure(error):
                            self.adminBanStatusLabel.stringValue = LF("Save failed: %@", Self.displayMessage(for: error))
                            self.showAdminError(error)
                        }
                    }
                } catch {
                    self.adminBanStatusLabel.stringValue = LF("Save failed: %@", Self.displayMessage(for: error))
                    self.showAdminError(error)
                }
            }
        } catch {
            showAdminError(error)
        }
    }

    func renderBannedIPv4Addresses(_ rules: [ServerIPRestriction]) -> String {
        rules.map { Self.ipv4Text($0.network) }.joined(separator: "\n")
    }

    static func ipv4Text(_ data: Data) -> String {
        guard data.count == 4 else { return "?.?.?.?" }
        return data.map(String.init).joined(separator: ".")
    }

    func parseIPv4(_ text: String, line: Int) throws -> Data {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            throw ServerStateError.invalidValue(LF("Ban line %@: enter a valid IPv4 address such as 203.0.113.7.", String(line)))
        }
        var bytes: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = UInt8(part) else {
                throw ServerStateError.invalidValue(LF("Ban line %@: enter a valid IPv4 address such as 203.0.113.7.", String(line)))
            }
            bytes.append(value)
        }
        return Data(bytes)
    }

    func parseBannedIPv4Addresses(_ text: String) throws -> [ServerIPRestriction] {
        var result: [ServerIPRestriction] = []
        var seen = Set<Data>()
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !trimmed.contains(where: \.isWhitespace) else {
                throw ServerStateError.invalidValue(LF("Ban line %@: enter only the IPv4 address, without masks or extra options.", String(offset + 1)))
            }
            let address = try parseIPv4(trimmed, line: offset + 1)
            guard seen.insert(address).inserted else { continue }
            result.append(ServerIPRestriction(network: address, mask: Data([255, 255, 255, 255]), deny: true, reserved: 0))
        }
        guard result.count <= 4096 else {
            throw ServerStateError.invalidValue(L("The ban list exceeds 4096 IP addresses."))
        }
        return result
    }

    func parseUInt16(_ field: NSTextField, name: String, requirePositive: Bool) throws -> UInt16 {
        guard let value = UInt16(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              !requirePositive || value > 0 else {
            throw ServerStateError.invalidValue(requirePositive ? LF("%@ must be a valid positive 16-bit number.", name) : LF("%@ must be a valid 16-bit number.", name))
        }
        return value
    }

    @objc func showPreferences(_ sender: Any?) { selectWorkspace(.advanced) }

}
