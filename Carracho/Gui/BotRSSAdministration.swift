#if !CARRACHO_SERVER
import Cocoa

extension ViewController {
    func makeBotRSSAdministrationSection() -> [NSView] {
        let title = sectionCaption(L("RSS feeds"))
        adminBotRSSTable.delegate = self
        adminBotRSSTable.dataSource = self
        adminBotRSSTable.target = self
        adminBotRSSTable.action = #selector(botRSSTableClicked(_:))
        adminBotRSSTable.usesAlternatingRowBackgroundColors = true
        adminBotRSSTable.backgroundColor = CarrachoTheme.tableBackground
        adminBotRSSTable.gridStyleMask = [.solidVerticalGridLineMask]
        adminBotRSSTable.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
        adminBotRSSTable.rowHeight = 30
        adminBotRSSTable.intercellSpacing = NSSize(width: 5, height: 1)
        adminBotRSSTable.allowsMultipleSelection = false
        adminBotRSSTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        if #available(macOS 11.0, *) { adminBotRSSTable.style = .plain }

        if adminBotRSSTable.tableColumns.isEmpty {
            func column(_ id: String, _ label: String, _ width: CGFloat, min: CGFloat? = nil, max: CGFloat? = nil) {
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                c.title = L(label)
                c.width = width
                c.minWidth = min ?? width
                if let max { c.maxWidth = max }
                adminBotRSSTable.addTableColumn(c)
            }
            column("botRSSEnabled", "On", 44, min: 44, max: 44)
            column("botRSSName", "Name", 130, min: 90)
            column("botRSSTarget", "Target", 120, min: 95)
            column("botRSSInterval", "Minutes", 72, min: 65, max: 90)
            column("botRSSImage", "Image", 55, min: 55, max: 55)
            column("botRSSSummary", "Summary", 78, min: 70, max: 95)
            column("botRSSURL", "RSS URL", 340, min: 220)
        }

        let scroll = tableScroll(adminBotRSSTable, tracksViewportWidth: true)
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        adminBotRSSAddButton.target = self
        adminBotRSSAddButton.action = #selector(addBotRSSFeed(_:))
        adminBotRSSAddButton.bezelStyle = .rounded
        adminBotRSSDeleteButton.target = self
        adminBotRSSDeleteButton.action = #selector(removeBotRSSFeed(_:))
        adminBotRSSDeleteButton.bezelStyle = .rounded
        adminBotRSSTestButton.target = self
        adminBotRSSTestButton.action = #selector(testBotRSSFeed(_:))
        adminBotRSSTestButton.bezelStyle = .rounded
        adminBotRSSSaveButton.target = self
        adminBotRSSSaveButton.action = #selector(saveBotRSSFeeds(_:))
        CarrachoTheme.applyPrimaryButtonStyle(adminBotRSSSaveButton)

        let actions = horizontalStack([
            adminBotRSSAddButton, adminBotRSSDeleteButton, adminBotRSSTestButton,
            NSView(), adminBotRSSSaveButton,
        ], spacing: 8)
        let note = infoLabel(L("Only articles that appear after a feed is initialized are posted. Existing articles are marked as seen. RSS 2.0 and Atom are supported; images are optional and are stored through Carracho media."))
        note.maximumNumberOfLines = 4
        return [title, scroll, actions, note]
    }

    var canEditBotRSSFeeds: Bool {
        client.isConnected && !isConnectedToClassicServer && canManageRemoteAccounts
            && remoteBotStatus?.rssFeedsSupported == true
            && !remoteBotLoading && !remoteBotMutationInProgress
            && !remoteBotGreetingMutationInProgress && !remoteBotCommandMutationInProgress
            && !remoteBotRSSMutationInProgress && !remoteBotRSSTestInProgress
    }

    func botRSSFeedCell(identifier: String, row: Int) -> NSView? {
        guard row >= 0, row < remoteBotRSSFeedDraft.count else { return nil }
        let feed = remoteBotRSSFeedDraft[row]
        if identifier == "botRSSEnabled" || identifier == "botRSSImage" {
            let selector = identifier == "botRSSEnabled" ? #selector(botRSSEnabledChanged(_:)) : #selector(botRSSImageChanged(_:))
            let button = NSButton(checkboxWithTitle: "", target: self, action: selector)
            button.tag = row
            button.state = (identifier == "botRSSEnabled" ? feed.enabled : feed.includeImage) ? .on : .off
            button.isEnabled = canEditBotRSSFeeds
            return verticallyCenteredTableContent(button)
        }
        if identifier == "botRSSTarget" {
            let popup = NSPopUpButton()
            popup.tag = row
            popup.target = self
            popup.action = #selector(botRSSTargetChanged(_:))
            popup.isEnabled = canEditBotRSSFeeds
            var channels = lastChannels
            if !channels.contains(where: { $0.channelID == LegacyServerRuntime.publicChannelID }) {
                channels.append(LegacyChannelSummary(channelID: LegacyServerRuntime.publicChannelID,
                                                     memberCount: 0, flags: 0, name: Data("Public".utf8)))
            }
            channels.sort { $0.channelID < $1.channelID }
            for channel in channels {
                let name = Self.macRomanString(channel.name).trimmingCharacters(in: .whitespacesAndNewlines)
                let title = channel.channelID == LegacyServerRuntime.publicChannelID ? "Public" : (name.isEmpty ? "#\(channel.channelID)" : "#\(name)")
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.tag = Int(channel.channelID)
                popup.menu?.addItem(item)
            }
            if popup.itemArray.first(where: { $0.tag == Int(feed.channelID) }) == nil {
                let item = NSMenuItem(title: "#\(feed.channelID)", action: nil, keyEquivalent: "")
                item.tag = Int(feed.channelID)
                popup.menu?.addItem(item)
            }
            if let item = popup.itemArray.first(where: { $0.tag == Int(feed.channelID) }) { popup.select(item) }
            return verticallyCenteredTableContent(popup, fillWidth: true, leadingInset: 1, trailingInset: 1)
        }

        let value: String
        switch identifier {
        case "botRSSName": value = feed.name
        case "botRSSURL": value = feed.url
        case "botRSSInterval": value = String(feed.pollIntervalMinutes)
        case "botRSSSummary": value = String(feed.summaryCharacters)
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
        field.isEditable = canEditBotRSSFeeds
        field.isSelectable = canEditBotRSSFeeds
        field.isEnabled = canEditBotRSSFeeds
        field.delegate = self
        field.target = self
        field.action = #selector(botRSSFeedTextEdited(_:))
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        if identifier == "botRSSURL" { field.placeholderString = "https://feeds.example.com/news" }
        if identifier == "botRSSName" { field.placeholderString = L("Feed name") }
        if identifier == "botRSSInterval" || identifier == "botRSSSummary" {
            let formatter = NumberFormatter()
            formatter.numberStyle = .none
            formatter.allowsFloats = false
            formatter.minimum = NSNumber(value: identifier == "botRSSInterval" ? LegacyBotRSSFeed.minimumPollMinutes : LegacyBotRSSFeed.minimumSummaryCharacters)
            formatter.maximum = NSNumber(value: identifier == "botRSSInterval" ? LegacyBotRSSFeed.maximumPollMinutes : LegacyBotRSSFeed.maximumSummaryCharacters)
            field.formatter = formatter
            field.alignment = .right
        }
        return verticallyCenteredTableContent(field, fillWidth: true, leadingInset: 2, trailingInset: 2)
    }

    @objc func botRSSTableClicked(_ sender: NSTableView) {
        guard sender === adminBotRSSTable, canEditBotRSSFeeds else { return }
        let row = sender.clickedRow
        let column = sender.clickedColumn
        guard row >= 0, row < remoteBotRSSFeedDraft.count,
              column >= 0, column < sender.tableColumns.count else { return }
        let identifier = sender.tableColumns[column].identifier.rawValue
        guard ["botRSSName", "botRSSURL", "botRSSInterval", "botRSSSummary"].contains(identifier),
              let cellView = sender.view(atColumn: column, row: row, makeIfNecessary: true),
              let field = botRSSTextField(in: cellView, identifier: identifier) else { return }
        view.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: editor.selectedRange.location, length: 0)
        }
    }

    private func botRSSTextField(in view: NSView, identifier: String) -> NSTextField? {
        if let field = view as? NSTextField, field.identifier?.rawValue == identifier { return field }
        for subview in view.subviews {
            if let field = botRSSTextField(in: subview, identifier: identifier) { return field }
        }
        return nil
    }

    func updateBotRSSButtons() {
        let editable = canEditBotRSSFeeds
        let row = adminBotRSSTable.selectedRow
        let hasSelection = row >= 0 && row < remoteBotRSSFeedDraft.count
        adminBotRSSAddButton.isEnabled = editable && remoteBotRSSFeedDraft.count < LegacyBotRSSFeed.maximumCount
        adminBotRSSDeleteButton.isEnabled = editable && hasSelection
        adminBotRSSTestButton.isEnabled = editable && hasSelection
        adminBotRSSSaveButton.isEnabled = editable && remoteBotRSSFeedsDirty
        adminBotRSSTable.isEnabled = editable
    }

    func markBotRSSFeedsDirty() {
        remoteBotRSSFeedsDirty = true
        updateBotRSSButtons()
    }

    @objc func addBotRSSFeed(_ sender: Any?) {
        guard canEditBotRSSFeeds, remoteBotRSSFeedDraft.count < LegacyBotRSSFeed.maximumCount else { return }
        view.window?.makeFirstResponder(nil)
        let presets = [
            (name: "MacRumors", url: "https://feeds.macrumors.com/MacRumors-All"),
            (name: "Tarnkappe", url: "https://tarnkappe.info/feed"),
        ]
        let configuredURLs = Set(remoteBotRSSFeedDraft.map {
            $0.url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let preset = presets.first { !configuredURLs.contains($0.url.lowercased()) }
        remoteBotRSSFeedDraft.append(LegacyBotRSSFeed(
            id: UUID(), enabled: true,
            name: preset?.name ?? LF("Feed %@", String(remoteBotRSSFeedDraft.count + 1)),
            url: preset?.url ?? "",
            channelID: LegacyServerRuntime.publicChannelID,
            pollIntervalMinutes: 15, includeImage: true, summaryCharacters: 280))
        markBotRSSFeedsDirty()
        adminBotRSSTable.reloadData()
        let row = remoteBotRSSFeedDraft.count - 1
        adminBotRSSTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        adminBotRSSTable.scrollRowToVisible(row)
    }

    @objc func removeBotRSSFeed(_ sender: Any?) {
        guard canEditBotRSSFeeds else { return }
        view.window?.makeFirstResponder(nil)
        let row = adminBotRSSTable.selectedRow
        guard row >= 0, row < remoteBotRSSFeedDraft.count else { return }
        remoteBotRSSFeedDraft.remove(at: row)
        markBotRSSFeedsDirty()
        adminBotRSSTable.reloadData()
        if !remoteBotRSSFeedDraft.isEmpty {
            adminBotRSSTable.selectRowIndexes(IndexSet(integer: min(row, remoteBotRSSFeedDraft.count - 1)), byExtendingSelection: false)
        }
        updateBotRSSButtons()
    }

    @objc func botRSSEnabledChanged(_ sender: NSButton) {
        guard canEditBotRSSFeeds, sender.tag >= 0, sender.tag < remoteBotRSSFeedDraft.count else { return }
        remoteBotRSSFeedDraft[sender.tag].enabled = sender.state == .on
        markBotRSSFeedsDirty()
    }

    @objc func botRSSImageChanged(_ sender: NSButton) {
        guard canEditBotRSSFeeds, sender.tag >= 0, sender.tag < remoteBotRSSFeedDraft.count else { return }
        remoteBotRSSFeedDraft[sender.tag].includeImage = sender.state == .on
        markBotRSSFeedsDirty()
    }

    @objc func botRSSTargetChanged(_ sender: NSPopUpButton) {
        guard canEditBotRSSFeeds, sender.tag >= 0, sender.tag < remoteBotRSSFeedDraft.count,
              let item = sender.selectedItem, item.tag > 0 else { return }
        remoteBotRSSFeedDraft[sender.tag].channelID = UInt32(item.tag)
        markBotRSSFeedsDirty()
    }

    @objc func botRSSFeedTextEdited(_ sender: NSTextField) {
        guard canEditBotRSSFeeds, sender.tag >= 0, sender.tag < remoteBotRSSFeedDraft.count else { return }
        switch sender.identifier?.rawValue {
        case "botRSSName": remoteBotRSSFeedDraft[sender.tag].name = sender.stringValue
        case "botRSSURL": remoteBotRSSFeedDraft[sender.tag].url = sender.stringValue
        case "botRSSInterval":
            guard let value = Int(sender.stringValue) else { adminBotRSSTable.reloadData(); return }
            remoteBotRSSFeedDraft[sender.tag].pollIntervalMinutes = value
        case "botRSSSummary":
            guard let value = Int(sender.stringValue) else { adminBotRSSTable.reloadData(); return }
            remoteBotRSSFeedDraft[sender.tag].summaryCharacters = value
        default: return
        }
        markBotRSSFeedsDirty()
    }

    func validatedBotRSSFeedDraft() throws -> [LegacyBotRSSFeed] {
        guard remoteBotRSSFeedDraft.count <= LegacyBotRSSFeed.maximumCount else {
            throw ServerStateError.invalidValue(L("Too many Bot RSS feeds."))
        }
        var ids = Set<UUID>()
        var urls = Set<String>()
        var output: [LegacyBotRSSFeed] = []
        for (index, feed) in remoteBotRSSFeedDraft.enumerated() {
            let validated: LegacyBotRSSFeed
            do { validated = try feed.validated() }
            catch { throw ServerStateError.invalidValue(LF("RSS feed %@ has invalid settings.", String(index + 1))) }
            guard ids.insert(validated.id).inserted else {
                throw ServerStateError.invalidValue(L("Each RSS feed needs a unique identifier."))
            }
            let key = validated.url.lowercased()
            guard urls.insert(key).inserted else {
                throw ServerStateError.invalidValue(LF("The RSS feed URL “%@” is configured more than once.", validated.url))
            }
            output.append(validated)
        }
        return output
    }

    @objc func saveBotRSSFeeds(_ sender: Any?) {
        guard canEditBotRSSFeeds else { return }
        view.window?.makeFirstResponder(nil)
        let feeds: [LegacyBotRSSFeed]
        do { feeds = try validatedBotRSSFeedDraft() }
        catch { showAdminError(error); return }
        let source = client
        remoteBotRSSMutationInProgress = true
        updateBotAdministrationUI()
        source.setBotAdministrationRSSFeeds(feeds) { [weak self, weak source] result in
            DispatchQueue.main.async {
                guard let self, let source, self.client === source else { return }
                self.remoteBotRSSMutationInProgress = false
                switch result {
                case .success:
                    self.remoteBotRSSFeedDraft = feeds
                    self.remoteBotStatus?.rssFeeds = feeds
                    self.remoteBotRSSFeedsDirty = false
                    self.adminBotRSSTable.reloadData()
                    self.showAdminSaved(L("Bot RSS feeds saved."))
                case let .failure(error): self.showAdminError(error)
                }
                self.updateBotAdministrationUI()
            }
        }
    }

    @objc func testBotRSSFeed(_ sender: Any?) {
        guard canEditBotRSSFeeds else { return }
        view.window?.makeFirstResponder(nil)
        let row = adminBotRSSTable.selectedRow
        guard row >= 0, row < remoteBotRSSFeedDraft.count else { return }
        let feed: LegacyBotRSSFeed
        do { feed = try remoteBotRSSFeedDraft[row].validated() }
        catch { showAdminError(ServerStateError.invalidValue(L("The selected RSS feed has invalid settings."))); return }
        let source = client
        remoteBotRSSTestInProgress = true
        updateBotAdministrationUI()
        source.testBotAdministrationRSSFeed(feed) { [weak self, weak source] result in
            DispatchQueue.main.async {
                guard let self, let source, self.client === source else { return }
                self.remoteBotRSSTestInProgress = false
                self.updateBotAdministrationUI()
                switch result {
                case .success:
                    self.showAdminSaved(L("RSS test article posted to Public."))
                case let .failure(error): self.showAdminError(error)
                }
            }
        }
    }
}
#endif
