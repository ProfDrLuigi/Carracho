#if !CARRACHO_SERVER
import Cocoa

extension ViewController {
    func makeBotFileWatcherAdministrationSection() -> [NSView] {
        let title = sectionCaption(L("File Watchers"))
        adminBotFileWatcherTable.delegate = self
        adminBotFileWatcherTable.dataSource = self
        adminBotFileWatcherTable.target = self
        adminBotFileWatcherTable.action = #selector(botFileWatcherTableClicked(_:))
        adminBotFileWatcherTable.usesAlternatingRowBackgroundColors = false
        adminBotFileWatcherTable.backgroundColor = CarrachoTheme.conferenceTranscriptBackground
        adminBotFileWatcherTable.gridStyleMask = [.solidVerticalGridLineMask]
        adminBotFileWatcherTable.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
        adminBotFileWatcherTable.rowHeight = 30
        adminBotFileWatcherTable.intercellSpacing = NSSize(width: 5, height: 1)
        adminBotFileWatcherTable.allowsMultipleSelection = false
        adminBotFileWatcherTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        if #available(macOS 11.0, *) { adminBotFileWatcherTable.style = .plain }

        if adminBotFileWatcherTable.tableColumns.isEmpty {
            func column(_ id: String, _ label: String, _ width: CGFloat, min: CGFloat? = nil, max: CGFloat? = nil) {
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                c.title = L(label)
                c.width = width
                c.minWidth = min ?? width
                if let max { c.maxWidth = max }
                adminBotFileWatcherTable.addTableColumn(c)
            }
            column("botFileWatcherEnabled", "On", 44, min: 44, max: 44)
            column("botFileWatcherPath", "Folder", 230, min: 140)
            column("botFileWatcherTarget", "Target", 120, min: 95)
            column("botFileWatcherMessage", "Message", 360, min: 220)
        }

        let scroll = tableScroll(adminBotFileWatcherTable, tracksViewportWidth: true)
        scroll.drawsBackground = true
        scroll.backgroundColor = CarrachoTheme.conferenceTranscriptBackground
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 190).isActive = true

        adminBotFileWatcherAddButton.target = self
        adminBotFileWatcherAddButton.action = #selector(addBotFileWatcher(_:))
        adminBotFileWatcherAddButton.bezelStyle = .rounded
        adminBotFileWatcherDeleteButton.target = self
        adminBotFileWatcherDeleteButton.action = #selector(removeBotFileWatcher(_:))
        adminBotFileWatcherDeleteButton.bezelStyle = .rounded
        adminBotFileWatcherSaveButton.target = self
        adminBotFileWatcherSaveButton.action = #selector(saveBotFileWatchers(_:))
        CarrachoTheme.applyPrimaryButtonStyle(adminBotFileWatcherSaveButton)

        let actions = horizontalStack([
            adminBotFileWatcherAddButton, adminBotFileWatcherDeleteButton,
            NSView(), adminBotFileWatcherSaveButton,
        ], spacing: 8)
        let note = infoLabel(L("Watch a folder below the server Files root, or use . to watch the Files root itself. When new files arrive, the Bot posts one coalesced message to the selected conference. Use {folder} for a clickable folder link and {file} for the detected file or folder name."))
        note.maximumNumberOfLines = 4
        return [title, scroll, actions, note]
    }

    var canEditBotFileWatchers: Bool {
        client.isConnected && !isConnectedToClassicServer && canManageRemoteAccounts
            && remoteBotStatus?.fileWatchersSupported == true
            && !remoteBotLoading && !remoteBotMutationInProgress
            && !remoteBotGreetingMutationInProgress && !remoteBotCommandMutationInProgress
            && !remoteBotRSSMutationInProgress && !remoteBotRSSTestInProgress
            && !remoteBotFileWatcherMutationInProgress
    }

    func botFileWatcherCell(identifier: String, row: Int) -> NSView? {
        guard row >= 0, row < remoteBotFileWatcherDraft.count else { return nil }
        let watcher = remoteBotFileWatcherDraft[row]

        if identifier == "botFileWatcherEnabled" {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(botFileWatcherEnabledChanged(_:)))
            checkbox.tag = row
            checkbox.state = watcher.enabled ? .on : .off
            checkbox.isEnabled = canEditBotFileWatchers
            return verticallyCenteredTableContent(checkbox)
        }

        if identifier == "botFileWatcherTarget" {
            let popup = NSPopUpButton()
            popup.tag = row
            popup.target = self
            popup.action = #selector(botFileWatcherTargetChanged(_:))
            popup.isEnabled = canEditBotFileWatchers
            var channels = lastChannels
            if !channels.contains(where: { $0.channelID == LegacyServerRuntime.publicChannelID }) {
                channels.append(LegacyChannelSummary(channelID: LegacyServerRuntime.publicChannelID,
                                                     memberCount: 0, flags: 0, name: Data("Public".utf8)))
            }
            channels.sort { $0.channelID < $1.channelID }
            for channel in channels {
                let name = Self.macRomanString(channel.name).trimmingCharacters(in: .whitespacesAndNewlines)
                let title = channel.channelID == LegacyServerRuntime.publicChannelID
                    ? "Public" : (name.isEmpty ? "#\(channel.channelID)" : "#\(name)")
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.tag = Int(channel.channelID)
                popup.menu?.addItem(item)
            }
            if popup.itemArray.first(where: { $0.tag == Int(watcher.channelID) }) == nil {
                let item = NSMenuItem(title: "#\(watcher.channelID)", action: nil, keyEquivalent: "")
                item.tag = Int(watcher.channelID)
                popup.menu?.addItem(item)
            }
            if let item = popup.itemArray.first(where: { $0.tag == Int(watcher.channelID) }) { popup.select(item) }
            return verticallyCenteredTableContent(popup, fillWidth: true, leadingInset: 1, trailingInset: 1)
        }

        let value: String
        switch identifier {
        case "botFileWatcherPath": value = watcher.path
        case "botFileWatcherMessage": value = watcher.messageTemplate
        default: return nil
        }
        let field = NSTextField(string: value)
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.tag = row
        field.font = .systemFont(ofSize: 12)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingMiddle
        field.isEditable = canEditBotFileWatchers
        field.isSelectable = canEditBotFileWatchers
        field.isEnabled = canEditBotFileWatchers
        field.target = self
        field.action = #selector(botFileWatcherTextEdited(_:))
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        if identifier == "botFileWatcherPath" { field.placeholderString = L("Folder relative to Files root, or . for root") }
        if identifier == "botFileWatcherMessage" { field.placeholderString = L("New {file} in {folder}") }
        return verticallyCenteredTableContent(field, fillWidth: true, leadingInset: 2, trailingInset: 2)
    }

    @objc func botFileWatcherTableClicked(_ sender: NSTableView) {
        guard sender === adminBotFileWatcherTable, canEditBotFileWatchers else { return }
        let row = sender.clickedRow
        let column = sender.clickedColumn
        guard row >= 0, row < remoteBotFileWatcherDraft.count,
              column >= 0, column < sender.tableColumns.count else { return }
        let identifier = sender.tableColumns[column].identifier.rawValue
        guard ["botFileWatcherPath", "botFileWatcherMessage"].contains(identifier),
              let cell = sender.view(atColumn: column, row: row, makeIfNecessary: true),
              let field = botFileWatcherTextField(in: cell, identifier: identifier) else { return }
        view.window?.makeFirstResponder(field)
    }

    private func botFileWatcherTextField(in view: NSView, identifier: String) -> NSTextField? {
        if let field = view as? NSTextField, field.identifier?.rawValue == identifier { return field }
        for subview in view.subviews {
            if let field = botFileWatcherTextField(in: subview, identifier: identifier) { return field }
        }
        return nil
    }

    func updateBotFileWatcherButtons() {
        let editable = canEditBotFileWatchers
        let row = adminBotFileWatcherTable.selectedRow
        let hasSelection = row >= 0 && row < remoteBotFileWatcherDraft.count
        adminBotFileWatcherAddButton.isEnabled = editable && remoteBotFileWatcherDraft.count < LegacyBotFileWatcher.maximumCount
        adminBotFileWatcherDeleteButton.isEnabled = editable && hasSelection
        adminBotFileWatcherSaveButton.isEnabled = editable && remoteBotFileWatchersDirty
        adminBotFileWatcherTable.isEnabled = editable
    }

    func markBotFileWatchersDirty() {
        remoteBotFileWatchersDirty = true
        updateBotFileWatcherButtons()
    }

    @objc func addBotFileWatcher(_ sender: Any?) {
        guard canEditBotFileWatchers, remoteBotFileWatcherDraft.count < LegacyBotFileWatcher.maximumCount else { return }
        view.window?.makeFirstResponder(nil)
        remoteBotFileWatcherDraft.append(LegacyBotFileWatcher(
            id: UUID(),
            enabled: false,
            path: "Incoming",
            channelID: LegacyServerRuntime.publicChannelID,
            messageTemplate: "New {file} in {folder}"
        ))
        markBotFileWatchersDirty()
        adminBotFileWatcherTable.reloadData()
        let row = remoteBotFileWatcherDraft.count - 1
        adminBotFileWatcherTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        adminBotFileWatcherTable.scrollRowToVisible(row)
    }

    @objc func removeBotFileWatcher(_ sender: Any?) {
        guard canEditBotFileWatchers else { return }
        view.window?.makeFirstResponder(nil)
        let row = adminBotFileWatcherTable.selectedRow
        guard row >= 0, row < remoteBotFileWatcherDraft.count else { return }
        remoteBotFileWatcherDraft.remove(at: row)
        markBotFileWatchersDirty()
        adminBotFileWatcherTable.reloadData()
        if !remoteBotFileWatcherDraft.isEmpty {
            adminBotFileWatcherTable.selectRowIndexes(IndexSet(integer: min(row, remoteBotFileWatcherDraft.count - 1)),
                                                       byExtendingSelection: false)
        }
        updateBotFileWatcherButtons()
    }

    @objc func botFileWatcherEnabledChanged(_ sender: NSButton) {
        guard canEditBotFileWatchers, sender.tag >= 0, sender.tag < remoteBotFileWatcherDraft.count else { return }
        remoteBotFileWatcherDraft[sender.tag].enabled = sender.state == .on
        markBotFileWatchersDirty()
    }

    @objc func botFileWatcherTargetChanged(_ sender: NSPopUpButton) {
        guard canEditBotFileWatchers, sender.tag >= 0, sender.tag < remoteBotFileWatcherDraft.count,
              let item = sender.selectedItem, item.tag > 0 else { return }
        remoteBotFileWatcherDraft[sender.tag].channelID = UInt32(item.tag)
        markBotFileWatchersDirty()
    }

    @objc func botFileWatcherTextEdited(_ sender: NSTextField) {
        guard canEditBotFileWatchers, sender.tag >= 0, sender.tag < remoteBotFileWatcherDraft.count else { return }
        switch sender.identifier?.rawValue {
        case "botFileWatcherPath": remoteBotFileWatcherDraft[sender.tag].path = sender.stringValue
        case "botFileWatcherMessage": remoteBotFileWatcherDraft[sender.tag].messageTemplate = sender.stringValue
        default: return
        }
        markBotFileWatchersDirty()
    }

    func validatedBotFileWatcherDraft() throws -> [LegacyBotFileWatcher] {
        guard remoteBotFileWatcherDraft.count <= LegacyBotFileWatcher.maximumCount else {
            throw ServerStateError.invalidValue(L("Too many Bot File Watchers."))
        }
        var ids = Set<UUID>()
        var paths = Set<String>()
        var output: [LegacyBotFileWatcher] = []
        for (index, watcher) in remoteBotFileWatcherDraft.enumerated() {
            let validated: LegacyBotFileWatcher
            do { validated = try watcher.validated() }
            catch {
                throw ServerStateError.invalidValue(LF("File Watcher %@ has invalid settings. Paths are relative to Files and the message must contain {folder} or {file}.", String(index + 1)))
            }
            guard ids.insert(validated.id).inserted else {
                throw ServerStateError.invalidValue(L("Each File Watcher needs a unique identifier."))
            }
            let key = validated.path.lowercased()
            guard paths.insert(key).inserted else {
                throw ServerStateError.invalidValue(LF("The folder “%@” is watched more than once.", validated.path))
            }
            output.append(validated)
        }
        return output
    }

    @objc func saveBotFileWatchers(_ sender: Any?) {
        guard canEditBotFileWatchers else { return }
        view.window?.makeFirstResponder(nil)
        let watchers: [LegacyBotFileWatcher]
        do { watchers = try validatedBotFileWatcherDraft() }
        catch { showAdminError(error); return }
        let source = client
        remoteBotFileWatcherMutationInProgress = true
        updateBotAdministrationUI()
        source.setBotAdministrationFileWatchers(watchers) { [weak self, weak source] result in
            DispatchQueue.main.async {
                guard let self, let source, self.client === source else { return }
                self.remoteBotFileWatcherMutationInProgress = false
                switch result {
                case .success:
                    self.remoteBotFileWatcherDraft = watchers
                    self.remoteBotStatus?.fileWatchers = watchers
                    self.remoteBotFileWatchersDirty = false
                    self.adminBotFileWatcherTable.reloadData()
                    self.showAdminSaved(L("Bot File Watchers saved."))
                case let .failure(error):
                    self.showAdminError(error)
                }
                self.updateBotAdministrationUI()
            }
        }
    }
}
#endif
