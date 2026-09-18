import Cocoa
import QuickLookUI

// MARK: - NewsAdmin

extension ViewController {

    func makeNewsAdminPage() -> NSView {
        let page = adminPage(title: L("News Categories"), subtitle: L("Create categories and manage retention and user access"))
        configure(table: adminNewsgroupTable, columns: [
            ("name", "Groupname", 330), ("articles", "Articles", 85), ("expire", "Expire articles", 150),
        ])
        adminNewsgroupTable.target = self
        adminNewsgroupTable.doubleAction = #selector(modifySelectedNewsgroup(_:))
        let groupScroll = tableScroll(adminNewsgroupTable)
        let add = NSButton(title: L("Add"), target: self, action: #selector(showNewsgroupEditor(_:)))
        adminNewsgroupModifyButton.target = self
        adminNewsgroupModifyButton.action = #selector(modifySelectedNewsgroup(_:))
        adminNewsgroupDeleteButton.target = self
        adminNewsgroupDeleteButton.action = #selector(deleteSelectedNewsgroup(_:))
        let refresh = NSButton(title: L("Reload"), target: self, action: #selector(reloadNewsgroupAdministrationPressed(_:)))
        let controls = NSStackView(views: [add, adminNewsgroupModifyButton, adminNewsgroupDeleteButton, refresh])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        adminNewsExpireTimeField.alignment = .center
        adminNewsExpireTimeField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let setTime = NSButton(title: L("Set Time"), target: self, action: #selector(saveNewsExpirationTime(_:)))
        let schedule = NSStackView(views: [NSTextField(labelWithString: L("Expire articles every day at")), adminNewsExpireTimeField, NSTextField(labelWithString: L("(local time)")), setTime])
        schedule.orientation = .horizontal
        schedule.alignment = .centerY
        schedule.spacing = 8
        appendAdminContent([groupScroll, schedule, controls], to: page, minimumBodyHeight: 470)
        return page
    }

    @objc func reloadNewsgroupAdministrationPressed(_ sender: Any?) {
        if client.isConnected { reloadNewsgroupAdministration() }
        else { loadModernServerState() }
    }

    func reloadNewsgroupAdministration() {
        guard client.isConnected else {
            remoteNewsgroupAdministrationGeneration &+= 1
            remoteNewsgroupAdministrationLoading = false
            remoteAdminNewsgroups = []
            let advanced = localServerState.advanced
            adminNewsExpireTimeField.stringValue = String(format: "%02d:%02d", advanced.newsExpirationHour, advanced.newsExpirationMinute)
            adminNewsgroupTable.reloadData()
            updateAdminSelectionButtons()
            return
        }
        guard canManageRemoteNewsgroups else {
            remoteNewsgroupAdministrationGeneration &+= 1
            remoteNewsgroupAdministrationLoading = false
            remoteAdminNewsgroups = []
            adminNewsgroupTable.reloadData()
            updateAdminSelectionButtons()
            return
        }

        remoteNewsgroupAdministrationGeneration &+= 1
        let generation = remoteNewsgroupAdministrationGeneration
        let target = client
        remoteNewsgroupAdministrationLoading = true
        remoteAdminNewsgroups = []
        adminNewsgroupTable.reloadData()
        updateAdminSelectionButtons()

        target.requestAdminNewsgroups { [weak self, weak target] result in
            guard let self, let target, self.client === target,
                  generation == self.remoteNewsgroupAdministrationGeneration else { return }
            do {
                let records = try result.get()
                self.remoteAdminNewsgroups = try records.map { record in
                    guard let name = String(data: record.name, encoding: .macOSRoman) else {
                        throw LegacyProtocolError.invalidRecord("remote news category name is not MacRoman")
                    }
                    return ServerNewsgroup(name: name, articleCount: record.articleCount,
                                           expireAfterSeconds: record.expireAfterSeconds,
                                           access: ServerNewsgroupAccess(legacyFlags: record.flags))
                }
                self.adminNewsgroupTable.reloadData()

                target.requestServerSettings(fields: [LegacyServerSettingField.newsExpireTime]) { [weak self, weak target] settingsResult in
                    guard let self, let target, self.client === target,
                          generation == self.remoteNewsgroupAdministrationGeneration else { return }
                    self.remoteNewsgroupAdministrationLoading = false
                    do {
                        let values = try settingsResult.get()
                        guard let data = values[LegacyServerSettingField.newsExpireTime] else {
                            throw LegacyControlClientError.missingField(LegacyServerSettingField.newsExpireTime)
                        }
                        var cursor = LegacyByteCursor(data)
                        let packed = try cursor.readUInt16BE()
                        try cursor.requireEnd()
                        let parts = LegacyServerSettingField.unpackNewsExpireTime(packed)
                        guard parts.hour < 24, parts.minute < 60 else {
                            throw LegacyProtocolError.invalidRecord("remote news expiration time is invalid")
                        }
                        self.adminNewsExpireTimeField.stringValue = String(format: "%02d:%02d", parts.hour, parts.minute)
                    } catch {
                        self.showAdminError(error)
                    }
                    self.updateAdminSelectionButtons()
                }
            } catch {
                self.remoteNewsgroupAdministrationLoading = false
                self.remoteAdminNewsgroups = []
                self.adminNewsgroupTable.reloadData()
                self.updateAdminSelectionButtons()
                self.showAdminError(error)
            }
        }
    }

    @objc func showNewsgroupEditor(_ sender: Any?) {
        presentNewsgroupEditor(existing: nil)
    }

    @objc func modifySelectedNewsgroup(_ sender: Any?) {
        let row = adminNewsgroupTable.clickedRow >= 0 ? adminNewsgroupTable.clickedRow : adminNewsgroupTable.selectedRow
        guard row >= 0, row < displayedAdminNewsgroups.count else { return }
        presentNewsgroupEditor(existing: displayedAdminNewsgroups[row])
    }

    @objc func deleteSelectedNewsgroup(_ sender: Any?) {
        let row = adminNewsgroupTable.selectedRow
        guard row >= 0, row < displayedAdminNewsgroups.count else { return }
        let group = displayedAdminNewsgroups[row]
        let remoteTarget = client.isConnected ? client : nil
        if remoteTarget != nil && !canManageRemoteNewsgroups { return }
        let localBackend = remoteTarget == nil ? serverBackend : nil
        guard remoteTarget != nil || localBackend != nil else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Delete News Category")
        alert.informativeText = remoteTarget == nil
            ? LF("Delete “%@” from the modern server configuration?", group.name)
            : LF("Delete “%@” from the connected server?", group.name)
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self, weak remoteTarget] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if let target = remoteTarget {
                guard self.client === target, let name = group.name.data(using: .macOSRoman) else { return }
                target.deleteNewsgroup(name: name) { [weak self, weak target] result in
                    guard let self, let target, self.client === target else { return }
                    switch result {
                    case .success:
                        self.showAdminSaved(LF("News category “%@” deleted.", group.name))
                        self.reloadNewsgroupAdministration()
                        self.loadInitialNewsgroups(completion: nil)
                    case let .failure(error): self.showAdminError(error)
                    }
                }
                return
            }
            guard let backend = localBackend else { return }
            do {
                try backend.deleteNewsgroup(id: group.id)
                self.localServerRuntime?.refreshNewsConfiguration()
                self.reloadLocalStateFromBackend()
                self.showAdminSaved(LF("News category “%@” deleted.", group.name))
            } catch { self.showAdminError(error) }
        }
    }

    func presentNewsgroupEditor(existing: ServerNewsgroup?) {
        guard let window = view.window else { return }
        let remoteTarget = client.isConnected ? client : nil
        if remoteTarget != nil && !canManageRemoteNewsgroups {
            showAdminError(ServerStateError.invalidValue(L("This account cannot manage News categories on the connected server.")))
            return
        }
        let localBackend = remoteTarget == nil ? serverBackend : nil
        guard remoteTarget != nil || localBackend != nil else {
            showAdminError(ServerStateError.invalidValue(L("Server backend is unavailable.")))
            return
        }
        let alert = NSAlert()
        alert.messageText = existing == nil ? L("New News Category") : L("Modify News Category")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))

        func editorLabel(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 12.5, weight: .medium)
            field.textColor = .secondaryLabelColor
            field.alignment = .right
            return field
        }

        func accessHeader(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 11.5, weight: .semibold)
            field.textColor = .secondaryLabelColor
            field.alignment = .center
            return field
        }

        func accessCheckbox(_ enabled: Bool, label: String) -> NSButton {
            let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            button.state = enabled ? .on : .off
            button.setAccessibilityLabel(label)
            return button
        }

        let name = NSTextField(string: existing?.name ?? "")
        name.placeholderString = L("News Category")
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let amount = NSTextField(string: "1")
        amount.alignment = .right
        amount.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let unit = NSPopUpButton()
        unit.addItems(withTitles: [L("hours"), L("days"), L("weeks"), L("months"), L("years"), L("never")])
        unit.widthAnchor.constraint(equalToConstant: 118).isActive = true
        let parts = expirationEditorParts(existing?.expireAfterSeconds ?? 604_800)
        amount.stringValue = parts.amount
        unit.selectItem(at: parts.unitIndex)

        let expirationControls = NSStackView(views: [amount, unit])
        expirationControls.orientation = .horizontal
        expirationControls.alignment = .centerY
        expirationControls.spacing = 8

        let details = NSGridView(views: [
            [editorLabel(L("News Category")), name],
            [editorLabel(L("Expire articles after")), expirationControls],
        ])
        details.rowSpacing = 10
        details.columnSpacing = 12
        details.column(at: 0).width = 148
        details.column(at: 0).xPlacement = .trailing
        details.column(at: 1).xPlacement = .fill

        let access = existing?.access ?? ServerNewsgroupAccess()
        let adminRead = accessCheckbox(access.administratorsRead, label: L("Administrators can read"))
        let adminPost = accessCheckbox(access.administratorsPost, label: L("Administrators can post"))
        let holderRead = accessCheckbox(access.accountHoldersRead, label: L("Account holders can read"))
        let holderPost = accessCheckbox(access.accountHoldersPost, label: L("Account holders can post"))
        let guestRead = accessCheckbox(access.guestsRead, label: L("Guests can read"))
        let guestPost = accessCheckbox(access.guestsPost, label: L("Guests can post"))

        let permissions = NSGridView(views: [
            [NSTextField(labelWithString: ""), accessHeader(L("Read")), accessHeader(L("Post"))],
            [editorLabel(L("Administrators can")), adminRead, adminPost],
            [editorLabel(L("Account holders can")), holderRead, holderPost],
            [editorLabel(L("Guests can")), guestRead, guestPost],
        ])
        permissions.rowSpacing = 8
        permissions.columnSpacing = 16
        permissions.column(at: 0).width = 148
        permissions.column(at: 0).xPlacement = .trailing
        permissions.column(at: 1).width = 72
        permissions.column(at: 1).xPlacement = .center
        permissions.column(at: 2).width = 72
        permissions.column(at: 2).xPlacement = .center

        let accessTitle = sectionCaption(L("User Access"))
        let divider = CarrachoDividerView()

        let content = NSStackView(views: [details, divider, accessTitle, permissions])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setCustomSpacing(14, after: details)
        content.setCustomSpacing(12, after: divider)
        content.setCustomSpacing(7, after: accessTitle)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 205))
        accessory.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: 6),
            content.trailingAnchor.constraint(equalTo: accessory.trailingAnchor, constant: -6),
            content.topAnchor.constraint(equalTo: accessory.topAnchor, constant: 4),
            content.bottomAnchor.constraint(lessThanOrEqualTo: accessory.bottomAnchor, constant: -4),
            name.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        alert.accessoryView = accessory

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                let expiration = try self.expirationSeconds(amount: amount.stringValue, unitIndex: unit.indexOfSelectedItem)
                let groupAccess = ServerNewsgroupAccess(administratorsRead: adminRead.state == .on,
                                                        administratorsPost: adminPost.state == .on,
                                                        accountHoldersRead: holderRead.state == .on,
                                                        accountHoldersPost: holderPost.state == .on,
                                                        guestsRead: guestRead.state == .on,
                                                        guestsPost: guestPost.state == .on)
                var value = existing ?? ServerNewsgroup(name: name.stringValue)
                value.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                value.expireAfterSeconds = expiration
                value.access = groupAccess
                guard !value.name.isEmpty, let newName = value.name.data(using: .macOSRoman),
                      newName.count <= LegacyNewsTransfer.maximumGroupNameLength else {
                    throw ServerStateError.invalidValue(L("News category name must be MacRoman-compatible and at most 64 bytes."))
                }

                if let target = remoteTarget {
                    guard self.client === target else { return }
                    let finish: (Result<Void, Error>) -> Void = { [weak self, weak target] result in
                        guard let self, let target, self.client === target else { return }
                        switch result {
                        case .success:
                            self.showAdminSaved(existing == nil ? L("News category created.") : L("News category updated."))
                            self.reloadNewsgroupAdministration()
                            self.loadInitialNewsgroups(completion: nil)
                        case let .failure(error): self.showAdminError(error)
                        }
                    }
                    if let existing {
                        guard let oldName = existing.name.data(using: .macOSRoman) else {
                            throw ServerStateError.invalidValue(L("The existing News category name cannot be encoded for this server."))
                        }
                        target.modifyNewsgroup(oldName: oldName, newName: newName,
                                               expireAfterSeconds: expiration, flags: groupAccess.legacyFlags,
                                               completion: finish)
                    } else {
                        target.createNewsgroup(name: newName, expireAfterSeconds: expiration,
                                              flags: groupAccess.legacyFlags, completion: finish)
                    }
                    return
                }

                guard let backend = localBackend else { return }
                if let existing {
                    _ = try backend.updateNewsgroup(id: existing.id, with: value)
                } else {
                    _ = try backend.createNewsgroup(value)
                }
                self.localServerRuntime?.refreshNewsConfiguration()
                self.reloadLocalStateFromBackend()
                self.showAdminSaved(existing == nil ? L("News category created.") : L("News category updated."))
            } catch { self.showAdminError(error) }
        }
    }

    func expirationEditorParts(_ seconds: UInt32) -> (amount: String, unitIndex: Int) {
        if seconds == UInt32.max { return ("1", 5) }
        let factors: [UInt32] = [3600, 86400, 604800, 2592000, 31536000]
        for index in stride(from: factors.count - 1, through: 0, by: -1) where seconds >= factors[index] && seconds % factors[index] == 0 {
            return (String(seconds / factors[index]), index)
        }
        return (String(max(1, seconds / 3600)), 0)
    }

    func expirationSeconds(amount: String, unitIndex: Int) throws -> UInt32 {
        if unitIndex == 5 { return UInt32.max }
        let factors: [UInt64] = [3600, 86400, 604800, 2592000, 31536000]
        guard unitIndex >= 0, unitIndex < factors.count,
              let count = UInt64(amount.trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 else {
            throw ServerStateError.invalidValue(L("Expiration amount must be a positive number."))
        }
        let (value, overflow) = count.multipliedReportingOverflow(by: factors[unitIndex])
        guard !overflow, value <= UInt64(UInt32.max) else { throw ServerStateError.invalidValue(L("Expiration interval is too large.")) }
        return UInt32(value)
    }

    @objc func saveNewsExpirationTime(_ sender: Any?) {
        do {
            let parts = adminNewsExpireTimeField.stringValue.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let hour = UInt8(parts[0]), let minute = UInt8(parts[1]), hour < 24, minute < 60 else {
                throw ServerStateError.invalidValue(L("Expiration time must use HH:MM (00:00…23:59)."))
            }

            if client.isConnected {
                guard canManageRemoteNewsgroups else {
                    throw ServerStateError.invalidValue(L("This account cannot manage News categories on the connected server."))
                }
                let value = try LegacyServerSettingField.packNewsExpireTime(hour: hour, minute: minute)
                let target = client
                target.setServerSettings([LegacyTLV(type: LegacyServerSettingField.newsExpireTime,
                                                    value: LegacyWire.uint16BE(value))]) { [weak self, weak target] result in
                    guard let self, let target, self.client === target else { return }
                    switch result {
                    case .success:
                        self.showAdminSaved(L("News category expiration time saved."))
                        self.reloadNewsgroupAdministration()
                    case let .failure(error): self.showAdminError(error)
                    }
                }
                return
            }

            guard let backend = serverBackend else {
                throw ServerStateError.invalidValue(L("Server backend is unavailable."))
            }
            var advanced = localServerState.advanced
            advanced.newsExpirationHour = hour
            advanced.newsExpirationMinute = minute
            try backend.updateAdvanced(advanced)
            localServerRuntime?.refreshNewsConfiguration()
            reloadLocalStateFromBackend()
            showAdminSaved(L("News category expiration time saved."))
        } catch { showAdminError(error) }
    }

}
