import Cocoa
import QuickLookUI

// MARK: - Accounts

extension ViewController {

    func makeAccountsAdminPage() -> NSView {
        let page = adminPage(title: L("Accounts"), subtitle: L("Manage logins, Classic account groups and per-user overrides"))
        configure(table: adminAccountTable, columns: [
            ("name", "Name", 190), ("login", "Login", 150), ("status", "Group", 150), ("last", "Last login", 165),
            ("downloads", "Downloads", 90), ("downloadBytes", "Download data", 120),
            ("uploads", "Uploads", 90), ("uploadBytes", "Upload data", 120),
        ])
        adminAccountTable.columnAutoresizingStyle = .noColumnAutoresizing
        for identifier in ["downloads", "downloadBytes", "uploads", "uploadBytes"] {
            adminAccountTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier))?.headerCell.alignment = .right
        }
        adminAccountTable.target = self
        adminAccountTable.doubleAction = #selector(modifySelectedAccount(_:))
        let scroll = tableScroll(adminAccountTable)
        scroll.hasHorizontalScroller = true
        adminAccountNewButton.target = self
        adminAccountNewButton.action = #selector(showAccountEditor(_:))
        adminAccountModifyButton.target = self
        adminAccountModifyButton.action = #selector(modifySelectedAccount(_:))
        adminAccountDeleteButton.target = self
        adminAccountDeleteButton.action = #selector(deleteSelectedAccount(_:))
        adminAccountGroupsButton.target = self
        adminAccountGroupsButton.action = #selector(showAccountGroups(_:))
        adminAccountReloadButton.target = self
        adminAccountReloadButton.action = #selector(reloadAccountsPressed(_:))
        let buttons = NSStackView(views: [adminAccountNewButton, adminAccountModifyButton, adminAccountDeleteButton, adminAccountGroupsButton, adminAccountReloadButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        adminAccountStatusLabel.textColor = CarrachoTheme.secondaryText
        adminAccountStatusLabel.lineBreakMode = .byTruncatingTail
        let note = NSTextField(wrappingLabelWithString: L("Modern servers use the Classic Administrator, Account Holder and Guest groups. Permissions and nickname color are copied from the group, then remain individually editable per account."))
        note.textColor = CarrachoTheme.secondaryText
        appendAdminContent([scroll, buttons, adminAccountStatusLabel, note], to: page, minimumBodyHeight: 430)
        return page
    }

    @objc func reloadAccountsPressed(_ sender: Any?) {
        if usesRemoteAccountAdministration { reloadRemoteAccounts() }
        else { loadModernServerState() }
    }

    func reloadRemoteAccounts() {
        guard client.isConnected else {
            remoteAccountSummaries = []
            remoteAccountGroups = []
            remoteAccountGroupByLogin = [:]
            remoteAccountListLoading = false
            adminAccountTable.reloadData()
            updateAdminSelectionButtons()
            return
        }
        guard canManageRemoteAccounts else {
            remoteAccountSummaries = []
            remoteAccountGroups = []
            remoteAccountGroupByLogin = [:]
            remoteAccountListLoading = false
            adminAccountStatusLabel.stringValue = L("This account does not have permission to manage server accounts.")
            adminAccountTable.reloadData()
            updateAdminSelectionButtons()
            return
        }
        guard !remoteAccountListLoading else { return }
        remoteAccountListLoading = true
        adminAccountStatusLabel.stringValue = usesClassicRemoteAccountAdministration
            ? L("Loading Classic accounts…") : L("Loading accounts and groups…")
        if let statusColumn = adminAccountTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("status")) {
            statusColumn.headerCell.stringValue = usesClassicRemoteAccountAdministration ? L("Type") : L("Group")
        }
        updateAdminSelectionButtons()

        let loadAccountList: (String?) -> Void = { [weak self] modelNote in
            guard let self else { return }
            self.client.requestAccountList { [weak self] result in
                guard let self else { return }
                self.remoteAccountListLoading = false
                switch result {
                case let .success(accounts):
                    self.remoteAccountSummaries = accounts
                    let base = LF(accounts.count == 1 ? "%@ account on %@" : "%@ accounts on %@",
                                  String(accounts.count),
                                  self.lastServerInfo?.serverName ?? self.lastLoginResult?.serverName ?? L("server"))
                    self.adminAccountStatusLabel.stringValue = modelNote.map { base + " · " + $0 } ?? base
                    self.adminAccountTable.reloadData()
                    self.updateAdminSelectionButtons()
                    self.writeUISmokeSnapshotIfRequested()
                case let .failure(error):
                    self.remoteAccountSummaries = []
                    self.adminAccountStatusLabel.stringValue = LF("Could not load accounts: %@", Self.displayMessage(for: error))
                    self.adminAccountTable.reloadData()
                    self.updateAdminSelectionButtons()
                }
            }
        }

        // Server 1.0b13 implements the original account list/get/save/delete commands, but not
        // the modern account-group setting. Do not send it an extension it cannot understand.
        if usesClassicRemoteAccountAdministration {
            remoteAccountGroups = []
            remoteAccountGroupByLogin = [:]
            loadAccountList(L("Classic account model · permissions are stored directly per account"))
            return
        }

        client.requestAccountGroups { [weak self] groupResult in
            guard let self else { return }
            let groupWarning: String?
            switch groupResult {
            case let .success(records):
                do {
                    self.remoteAccountGroups = try records.map(ServerAccountGroup.init(legacy:))
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    var membership: [String: UUID] = [:]
                    for record in records {
                        for login in record.memberLogins {
                            let key = login.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                    locale: Locale(identifier: "en_US_POSIX"))
                            membership[key] = record.id
                        }
                    }
                    self.remoteAccountGroupByLogin = membership
                    groupWarning = nil
                } catch {
                    self.remoteAccountGroups = []
                    self.remoteAccountGroupByLogin = [:]
                    groupWarning = LF("Permission groups could not be decoded: %@", Self.displayMessage(for: error))
                }
            case let .failure(error):
                self.remoteAccountGroups = []
                self.remoteAccountGroupByLogin = [:]
                groupWarning = LF("This server does not expose permission groups: %@", Self.displayMessage(for: error))
            }
            loadAccountList(groupWarning)
        }
    }

    @objc func showAccountEditor(_ sender: Any?) {
        if usesRemoteAccountAdministration {
            guard canManageRemoteAccounts else {
                showAdminError(ServerStateError.invalidValue(L("This account cannot manage server accounts."))); return
            }
            presentAccountEditor(existing: nil, remoteRecord: nil)
        } else {
            presentAccountEditor(existing: nil, remoteRecord: nil)
        }
    }

    @objc func modifySelectedAccount(_ sender: Any?) {
        let row = adminAccountTable.clickedRow >= 0 ? adminAccountTable.clickedRow : adminAccountTable.selectedRow
        if usesRemoteAccountAdministration {
            guard row >= 0, row < displayedRemoteAccounts.count, canManageRemoteAccounts else { return }
            let summary = displayedRemoteAccounts[row]
            adminAccountStatusLabel.stringValue = LF("Loading %@…", Self.macRomanString(summary.login))
            client.requestAccountDetails(login: summary.login) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(details):
                    do {
                        var converted = try ServerAccount.fromLegacyRecord(
                            details.record, allowCarrachoExtensions: !self.usesClassicRemoteAccountAdministration
                        ).account
                        converted.colorRGB = details.colorRGB
                        converted.picture = details.picture
                        converted.localLoginOnly = details.localLoginOnly ? true : nil
                        converted.groupID = details.groupID ?? self.remoteAccountGroupByLogin[
                            Self.macRomanString(summary.login).folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                                      locale: Locale(identifier: "en_US_POSIX"))
                        ]
                        self.presentAccountEditor(existing: converted, remoteRecord: details.record)
                        self.adminAccountStatusLabel.stringValue = self.remoteAccountSummaries.count == 1 ? LF("%@ account", String(self.remoteAccountSummaries.count)) : LF("%@ accounts", String(self.remoteAccountSummaries.count))
                    } catch { self.showAdminError(error) }
                case let .failure(error): self.showAdminError(error)
                }
            }
            return
        }
        guard row >= 0, row < displayedLocalAccounts.count else { return }
        presentAccountEditor(existing: displayedLocalAccounts[row], remoteRecord: nil)
    }

    @objc func deleteSelectedAccount(_ sender: Any?) {
        let row = adminAccountTable.selectedRow
        if usesRemoteAccountAdministration {
            guard row >= 0, row < displayedRemoteAccounts.count, canManageRemoteAccounts else { return }
            let account = displayedRemoteAccounts[row]
            let login = Self.macRomanString(account.login)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("Delete Account")
            alert.informativeText = LF("Delete “%@” from the connected server? This cannot be undone.", login)
            alert.addButton(withTitle: L("Delete"))
            alert.addButton(withTitle: L("Cancel"))
            guard let window = view.window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self else { return }
                self.client.deleteAccount(login: account.login) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.showAdminSaved(LF("Account “%@” deleted.", login))
                        self.reloadRemoteAccounts()
                    case let .failure(error): self.showAdminError(error)
                    }
                }
            }
            return
        }
        guard row >= 0, row < displayedLocalAccounts.count, let backend = serverBackend else { return }
        let account = displayedLocalAccounts[row]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Delete Account")
        alert.informativeText = LF("Delete “%@” from the modern server configuration?", account.login)
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try backend.deleteAccount(id: account.id)
                self.reloadLocalStateFromBackend()
                self.showAdminSaved(LF("Account “%@” deleted.", account.login))
            } catch { self.showAdminError(error) }
        }
    }

    static func colorFromRGB(_ rgb: UInt32) -> NSColor {
        NSColor(deviceRed: CGFloat((rgb >> 16) & 0xff) / 255,
                green: CGFloat((rgb >> 8) & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }

    static func rgbFromColor(_ color: NSColor) -> UInt32 {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0x0A84FF }
        let r = UInt32(max(0, min(255, Int((rgb.redComponent * 255).rounded()))))
        let g = UInt32(max(0, min(255, Int((rgb.greenComponent * 255).rounded()))))
        let b = UInt32(max(0, min(255, Int((rgb.blueComponent * 255).rounded()))))
        return (r << 16) | (g << 8) | b
    }

    func populateGroupPopup(_ popup: NSPopUpButton, groups: [ServerAccountGroup], selectedID: UUID?) {
        popup.removeAllItems()
        for group in groups {
            popup.addItem(withTitle: group.name)
            guard let item = popup.lastItem else { continue }
            item.representedObject = group.id.uuidString
            let title = NSMutableAttributedString(string: "●  \(group.name)")
            title.addAttribute(.foregroundColor, value: Self.colorFromRGB(group.colorRGB), range: NSRange(location: 0, length: 1))
            item.attributedTitle = title
        }
        if let selectedID, let index = groups.firstIndex(where: { $0.id == selectedID }) {
            popup.selectItem(at: index)
        } else if let member = groups.firstIndex(where: { $0.legacyMode == .accountHolder }) {
            popup.selectItem(at: member)
        } else if !groups.isEmpty {
            popup.selectItem(at: 0)
        }
    }

    func presentAccountEditor(existing: ServerAccount?, remoteRecord: LegacyAccountRecord?) {
        guard let window = view.window else { return }
        let remote = usesRemoteAccountAdministration
        if remote && !canManageRemoteAccounts {
            showAdminError(ServerStateError.invalidValue(L("This account cannot manage server accounts."))); return
        }
        if remote && usesClassicRemoteAccountAdministration {
            presentClassicRemoteAccountEditor(existing: existing, remoteRecord: remoteRecord)
            return
        }
        if !remote && serverBackend == nil {
            showAdminError(ServerStateError.invalidValue(L("Server backend is unavailable."))); return
        }
        let groups = availableAccountGroups
        guard groups.count == 3 else {
            showAdminError(ServerStateError.invalidValue(L("Administrator, Account Holder and Guest must be available before editing accounts."))); return
        }

        let alert = NSAlert()
        alert.messageText = existing == nil ? L("New Account") : L("Modify Account")
        alert.informativeText = L("Selecting a group copies its default permissions and color. Both can then be customized for this account.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))

        let loginEditor = NSTextField(string: existing?.login ?? "")
        let nameEditor = NSTextField(string: existing?.name ?? "")
        let passwordEditor = NSSecureTextField(string: "")
        let localOnlyAccount = existing?.isLocalLoginOnly == true
        passwordEditor.placeholderString = localOnlyAccount
            ? L("Local-only account · no network password")
            : (existing == nil ? L("Empty password allowed") : L("Leave blank to keep current password"))
        passwordEditor.isEnabled = !localOnlyAccount
        let groupPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let defaultGroupID = existing?.groupID ?? ServerState.builtInMemberGroupID
        populateGroupPopup(groupPopup, groups: groups, selectedID: defaultGroupID)
        let selectedIndex = max(0, min(groupPopup.indexOfSelectedItem, groups.count - 1))
        let selectedGroup = groups[selectedIndex]

        let color = NSColorWell(frame: NSRect(x: 0, y: 0, width: 80, height: 26))
        color.color = Self.colorFromRGB(existing?.colorRGB ?? selectedGroup.colorRGB)
        let personalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        personalPopup.addItems(withTitles: [L("None"), L("Nested in root"), L("Is root directory")])
        switch existing?.personalDirectory ?? .none {
        case .none: personalPopup.selectItem(at: 0)
        case .nestedInRoot: personalPopup.selectItem(at: 1)
        case .rootDirectory: personalPopup.selectItem(at: 2)
        }

        let headerGrid = NSGridView(views: [
            [makeLabel(L("Login")), loginEditor],
            [makeLabel(L("Name")), nameEditor],
            [makeLabel(L("Password")), passwordEditor],
            [makeLabel(L("Group")), groupPopup],
            [makeLabel(L("Nickname color")), color],
            [makeLabel(L("Personal directory")), personalPopup],
        ])
        headerGrid.rowSpacing = 6
        headerGrid.columnSpacing = 10
        headerGrid.column(at: 0).width = 155
        headerGrid.column(at: 0).xPlacement = .trailing
        headerGrid.column(at: 1).width = 360
        headerGrid.column(at: 1).xPlacement = .fill
        let localOnlyNote = NSTextField(wrappingLabelWithString:
            L("This account can be activated only by the local server Bot and cannot log in over the network."))
        localOnlyNote.font = .systemFont(ofSize: 11, weight: .medium)
        localOnlyNote.textColor = CarrachoTheme.secondaryText
        localOnlyNote.isHidden = !localOnlyAccount

        var controls: [ServerPermission: NSButton] = [:]
        let initialPermissions = existing?.permissions ?? selectedGroup.permissions
        let permissionColumns = NSStackView(views: accountPermissionSections.map { section -> NSView in
            var views: [NSView] = [sectionCaption(L(section.0))]
            for (label, permission) in section.1 {
                let button = NSButton(checkboxWithTitle: L(label), target: nil, action: nil)
                button.state = initialPermissions.contains(permission) ? .on : .off
                button.font = .systemFont(ofSize: 12)
                if permission == .postNews {
                    button.toolTip = L("Modern Carracho permission. Classic servers do not support this account-level right and use the per-category Post access flag instead.")
                }
                controls[permission] = button
                views.append(button)
            }
            let stack = verticalStack(views, spacing: 3)
            stack.alignment = .leading
            return stack
        })
        permissionColumns.orientation = .horizontal
        permissionColumns.alignment = .top
        permissionColumns.distribution = .fillEqually
        permissionColumns.spacing = 20

        let permissionsLabel = NSTextField(labelWithString: L("Account permissions"))
        permissionsLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        permissionsLabel.textColor = CarrachoTheme.secondaryText
        let stack = verticalStack([headerGrid, localOnlyNote, permissionsLabel, permissionColumns], spacing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 810, height: 500))
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            stack.topAnchor.constraint(equalTo: accessory.topAnchor, constant: 4),
        ])
        alert.accessoryView = accessory

        // Group changes are explicit resets to that group's defaults. The user can immediately
        // override individual checkboxes or the color afterwards.
        let groupTarget = CarrachoClosureTarget { _ in
            guard groupPopup.indexOfSelectedItem >= 0, groupPopup.indexOfSelectedItem < groups.count else { return }
            let group = groups[groupPopup.indexOfSelectedItem]
            for (permission, button) in controls {
                button.state = group.permissions.contains(permission) ? .on : .off
            }
            color.color = Self.colorFromRGB(group.colorRGB)
        }
        groupPopup.target = groupTarget
        groupPopup.action = #selector(CarrachoClosureTarget.invoke(_:))

        alert.beginSheetModal(for: window) { [weak self, groupTarget] response in
            _ = groupTarget
            guard response == .alertFirstButtonReturn, let self else { return }
            guard groupPopup.indexOfSelectedItem >= 0, groupPopup.indexOfSelectedItem < groups.count else {
                self.showAdminError(ServerStateError.invalidValue(L("Select an account group."))); return
            }
            let group = groups[groupPopup.indexOfSelectedItem]
            let directoryMode: ServerPersonalDirectoryMode
            switch personalPopup.indexOfSelectedItem {
            case 2: directoryMode = .rootDirectory
            case 1: directoryMode = .nestedInRoot
            default: directoryMode = .none
            }
            let loginText = loginEditor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameText = nameEditor.stringValue
            let permissions = Set(controls.compactMap { $0.value.state == .on ? $0.key : nil })
            let accountColor = Self.rgbFromColor(color.color)
            var value = existing ?? ServerAccount(login: loginText)
            value.login = loginText
            value.name = nameText
            value.groupID = group.id
            value.mode = group.legacyMode
            value.permissions = permissions
            value.colorRGB = accountColor
            value.personalDirectory = directoryMode

            if remote {
                guard let loginData = loginText.data(using: .macOSRoman), !loginData.isEmpty, loginData.count <= 31,
                      let nameData = nameText.data(using: .macOSRoman), nameData.count <= 64 else {
                    self.showAdminError(ServerStateError.invalidValue(L("Login must be 1–31 MacRoman bytes and name at most 64 MacRoman bytes."))); return
                }
                let passwordData: Data
                if localOnlyAccount {
                    passwordData = remoteRecord?.password ?? Data()
                } else if passwordEditor.stringValue.isEmpty, let remoteRecord {
                    passwordData = remoteRecord.password
                } else if let encoded = passwordEditor.stringValue.data(using: .macOSRoman), encoded.count <= 64 {
                    passwordData = encoded
                } else {
                    self.showAdminError(ServerStateError.invalidValue(L("Password must be representable in MacRoman and at most 64 bytes."))); return
                }
                let now = Date().legacyMacTimestamp
                let record = LegacyAccountRecord(login: loginData, name: nameData, password: passwordData,
                                                 created: remoteRecord?.created ?? now, modified: now,
                                                 lastLogin: remoteRecord?.lastLogin ?? 0,
                                                 permissionBytes: value.permissionBytes(includeCarrachoExtensions: true))
                self.client.saveAccount(record, oldLogin: remoteRecord?.login, groupID: group.id,
                                        colorRGB: accountColor) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.showAdminSaved(existing == nil ? LF("Account “%@” created.", loginText) : LF("Account “%@” updated.", loginText))
                        self.reloadRemoteAccounts()
                    case let .failure(error): self.showAdminError(error)
                    }
                }
                return
            }

            guard let backend = self.serverBackend else { return }
            do {
                let saved: ServerAccount
                if let existing {
                    let newPassword = existing.isLocalLoginOnly || passwordEditor.stringValue.isEmpty
                        ? nil : passwordEditor.stringValue
                    saved = try backend.updateAccount(id: existing.id, with: value, newPassword: newPassword)
                } else {
                    saved = try backend.createAccount(value, password: passwordEditor.stringValue)
                }
                try self.localServerRuntime?.synchronizePersonalDirectory(oldAccount: existing, newAccount: saved)
                self.localServerRuntime?.refreshConnectedAccountsFromBackendAndBroadcastColor()
                self.reloadLocalStateFromBackend()
                self.refreshUserStatuses()
                self.showAdminSaved(existing == nil ? L("Account created.") : L("Account updated."))
            } catch { self.showAdminError(error) }
        }
    }

    static func mergedClassicAccountPermissionBytes(existing: Data?, replacement: Data) -> Data {
        guard replacement.count == 8 else { return replacement }
        var result = existing?.count == 8 ? existing! : Data(repeating: 0, count: 8)
        let controlledBits = [
            LegacyAccountPermissionBit.administrator,
            LegacyAccountPermissionBit.accountHolder,
            LegacyAccountPermissionBit.personalDirectoryNestedInRoot,
            LegacyAccountPermissionBit.personalDirectoryIsRoot,
        ] + ServerPermission.allCases.filter(\.isClassicPermission).map(\.rawValue)
        for bit in controlledBits where bit >= 0 && bit < 64 {
            let index = bit / 8
            let mask = UInt8(0x80 >> (bit % 8))
            result[index] &= ~mask
            if replacement[index] & mask != 0 { result[index] |= mask }
        }
        return result
    }

    func presentClassicRemoteAccountEditor(existing: ServerAccount?, remoteRecord: LegacyAccountRecord?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = existing == nil ? L("New Account") : L("Modify Account")
        alert.informativeText = existing == nil
            ? L("Classic servers store account permissions directly in each login.")
            : L("Edit the Classic account directly. Leave Password blank to keep the current password.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))

        let loginEditor = NSTextField(string: existing?.login ?? "")
        let nameEditor = NSTextField(string: existing?.name ?? "")
        let passwordEditor = NSSecureTextField(string: "")
        passwordEditor.placeholderString = existing == nil ? L("Empty password allowed") : L("Leave blank to keep current password")

        let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        typePopup.addItems(withTitles: [L("Guest"), L("Account Holder"), L("Administrator")])
        switch existing?.mode ?? .guest {
        case .guest: typePopup.selectItem(at: 0)
        case .accountHolder: typePopup.selectItem(at: 1)
        case .administrator: typePopup.selectItem(at: 2)
        }

        let personalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        personalPopup.addItems(withTitles: [L("None"), L("Nested in root"), L("Is root directory")])
        switch existing?.personalDirectory ?? .none {
        case .none: personalPopup.selectItem(at: 0)
        case .nestedInRoot: personalPopup.selectItem(at: 1)
        case .rootDirectory: personalPopup.selectItem(at: 2)
        }

        let headerGrid = NSGridView(views: [
            [makeLabel(L("Login")), loginEditor],
            [makeLabel(L("Name")), nameEditor],
            [makeLabel(L("Password")), passwordEditor],
            [makeLabel(L("Type")), typePopup],
            [makeLabel(L("Personal directory")), personalPopup],
        ])
        headerGrid.rowSpacing = 6
        headerGrid.columnSpacing = 10
        headerGrid.column(at: 0).width = 155
        headerGrid.column(at: 0).xPlacement = .trailing
        headerGrid.column(at: 1).width = 410
        headerGrid.column(at: 1).xPlacement = .fill

        var controls: [ServerPermission: NSButton] = [:]
        let selected = existing?.permissions ?? []
        let permissionColumns = NSStackView(views: accountPermissionSections.map { section -> NSView in
            var views: [NSView] = [sectionCaption(L(section.0))]
            for (label, permission) in section.1 where permission.isClassicPermission {
                let button = NSButton(checkboxWithTitle: L(label), target: nil, action: nil)
                button.state = selected.contains(permission) ? .on : .off
                button.font = .systemFont(ofSize: 12)
                controls[permission] = button
                views.append(button)
            }
            let stack = verticalStack(views, spacing: 3)
            stack.alignment = .leading
            return stack
        })
        permissionColumns.orientation = .horizontal
        permissionColumns.alignment = .top
        permissionColumns.distribution = .fillEqually
        permissionColumns.spacing = 20

        let permissionsLabel = NSTextField(labelWithString: L("Permissions"))
        permissionsLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        permissionsLabel.textColor = CarrachoTheme.secondaryText
        let stack = verticalStack([headerGrid, permissionsLabel, permissionColumns], spacing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 430))
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            stack.topAnchor.constraint(equalTo: accessory.topAnchor, constant: 4),
        ])
        alert.accessoryView = accessory

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let loginText = loginEditor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameText = nameEditor.stringValue
            guard let loginData = loginText.data(using: .macOSRoman), !loginData.isEmpty, loginData.count <= 31,
                  let nameData = nameText.data(using: .macOSRoman), nameData.count <= 64 else {
                self.showAdminError(ServerStateError.invalidValue(L("Login must be 1–31 MacRoman bytes and name at most 64 MacRoman bytes.")))
                return
            }
            let passwordData: Data
            if passwordEditor.stringValue.isEmpty, let remoteRecord {
                passwordData = remoteRecord.password
            } else if let encoded = passwordEditor.stringValue.data(using: .macOSRoman), encoded.count <= 64 {
                passwordData = encoded
            } else {
                self.showAdminError(ServerStateError.invalidValue(L("Password must be representable in MacRoman and at most 64 bytes.")))
                return
            }

            let mode: ServerAccountMode
            switch typePopup.indexOfSelectedItem {
            case 2: mode = .administrator
            case 1: mode = .accountHolder
            default: mode = .guest
            }
            let directoryMode: ServerPersonalDirectoryMode
            switch personalPopup.indexOfSelectedItem {
            case 2: directoryMode = .rootDirectory
            case 1: directoryMode = .nestedInRoot
            default: directoryMode = .none
            }
            var value = existing ?? ServerAccount(login: loginText)
            value.login = loginText
            value.name = nameText
            value.groupID = nil
            value.mode = mode
            value.personalDirectory = directoryMode
            value.permissions = Set(controls.compactMap { $0.value.state == .on ? $0.key : nil })
            let permissionBytes = Self.mergedClassicAccountPermissionBytes(existing: remoteRecord?.permissionBytes,
                                                                           replacement: value.legacyPermissionBytes)
            let now = Date().legacyMacTimestamp
            let record = LegacyAccountRecord(login: loginData, name: nameData, password: passwordData,
                                             created: remoteRecord?.created ?? now, modified: now,
                                             lastLogin: remoteRecord?.lastLogin ?? 0,
                                             permissionBytes: permissionBytes)
            self.client.saveAccount(record, oldLogin: remoteRecord?.login, groupID: nil) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.showAdminSaved(existing == nil
                        ? LF("Account “%@” created.", loginText)
                        : LF("Account “%@” updated.", loginText))
                    self.reloadRemoteAccounts()
                case let .failure(error): self.showAdminError(error)
                }
            }
        }
    }

    @objc func showAccountGroups(_ sender: Any?) {
        guard let window = view.window else { return }
        if usesRemoteAccountAdministration && usesClassicRemoteAccountAdministration {
            showAdminError(ServerStateError.invalidValue(L("Classic servers store permissions directly on each account and do not expose editable group defaults.")))
            return
        }
        if usesRemoteAccountAdministration && !canManageRemoteAccounts {
            showAdminError(ServerStateError.invalidValue(L("This account cannot manage server accounts."))); return
        }
        let groups = availableAccountGroups
        guard groups.count == 3 else {
            showAdminError(ServerStateError.invalidValue(L("Administrator, Account Holder and Guest are the only supported account groups."))); return
        }
        let alert = NSAlert()
        alert.messageText = L("Account Groups")
        alert.informativeText = L("Edit the default permissions, nickname color and Files root for Administrator, Account Holder or Guest. Existing per-account overrides are not changed.")
        alert.addButton(withTitle: L("Edit"))
        alert.addButton(withTitle: L("Close"))
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28), pullsDown: false)
        populateGroupPopup(popup, groups: groups, selectedID: groups.first?.id)
        alert.accessoryView = popup
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  popup.indexOfSelectedItem >= 0, popup.indexOfSelectedItem < groups.count else { return }
            self.presentAccountGroupEditor(existing: groups[popup.indexOfSelectedItem])
        }
    }

    func presentAccountGroupEditor(existing: ServerAccountGroup?) {
        guard let window = view.window, let existing else { return }
        let alert = NSAlert()
        alert.messageText = LF("Edit %@ Defaults", existing.name)
        alert.informativeText = L("Accounts that still use these group defaults follow future group changes. Individual account overrides stay untouched.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))

        let name = NSTextField(labelWithString: existing.name)
        let color = NSColorWell(frame: NSRect(x: 0, y: 0, width: 80, height: 26))
        color.color = Self.colorFromRGB(existing.colorRGB)
        let filesRootMode = NSPopUpButton(frame: .zero, pullsDown: false)
        filesRootMode.addItems(withTitles: [L("General — Server Files Root"), L("Dedicated Folder")])
        filesRootMode.selectItem(at: existing.filesRootPath.isEmpty ? 0 : 1)
        let filesRootPath = NSTextField(string: existing.filesRootPath)
        filesRootPath.placeholderString = L("e.g. Groups/Guests")
        filesRootPath.toolTip = L("Relative folder inside General. Absolute paths and .. are not allowed. The last folder name is used as the visible root name.")
        let headerGrid = NSGridView(views: [
            [makeLabel(L("Group")), name],
            [makeLabel(L("Default nickname color")), color],
            [makeLabel(L("Files root")), filesRootMode],
            [makeLabel(L("Folder in Allgemein")), filesRootPath],
        ])
        headerGrid.rowSpacing = 6
        headerGrid.columnSpacing = 10
        headerGrid.column(at: 0).width = 155
        headerGrid.column(at: 0).xPlacement = .trailing
        headerGrid.column(at: 1).width = 410
        headerGrid.column(at: 1).xPlacement = .fill

        var controls: [ServerPermission: NSButton] = [:]
        let columns = accountPermissionSections.map { section -> NSView in
            var views: [NSView] = [sectionCaption(L(section.0))]
            for (label, permission) in section.1 {
                let button = NSButton(checkboxWithTitle: L(label), target: nil, action: nil)
                button.state = existing.permissions.contains(permission) ? .on : .off
                button.font = .systemFont(ofSize: 12)
                if permission == .postNews {
                    button.toolTip = L("Modern Carracho permission. Classic servers do not support this account-level right and use the per-category Post access flag instead.")
                }
                controls[permission] = button
                views.append(button)
            }
            let stack = verticalStack(views, spacing: 3)
            stack.alignment = .leading
            return stack
        }
        let permissionColumns = NSStackView(views: columns)
        permissionColumns.orientation = .horizontal
        permissionColumns.alignment = .top
        permissionColumns.distribution = .fillEqually
        permissionColumns.spacing = 20

        let stack = verticalStack([headerGrid, permissionColumns], spacing: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 370))
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            stack.topAnchor.constraint(equalTo: accessory.topAnchor, constant: 4),
        ])
        alert.accessoryView = accessory

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var group = existing
            group.name = ServerState.builtInAccountGroupName(for: group.legacyMode)
            group.colorRGB = Self.rgbFromColor(color.color)
            group.permissions = Set(controls.compactMap { $0.value.state == .on ? $0.key : nil })
            if filesRootMode.indexOfSelectedItem == 0 {
                group.filesRootPath = ""
                group.filesRootName = ServerAccountGroup.defaultFilesRootName
            } else {
                let path = filesRootPath.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                group.filesRootPath = path
                group.filesRootName = path.split(separator: "/").last.map(String.init)
                    ?? ServerAccountGroup.defaultFilesRootName
            }
            do { try ServerStateValidator.validate(accountGroup: group) }
            catch { self.showAdminError(error); return }

            if self.usesRemoteAccountAdministration {
                var groups = self.remoteAccountGroups
                guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
                groups[index] = group
                self.client.setAccountGroups(groups.map { $0.legacyGroupRecord() }) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.showAdminSaved(L("Account group defaults updated."))
                        self.reloadRemoteAccounts()
                    case let .failure(error): self.showAdminError(error)
                    }
                }
                return
            }

            guard let backend = self.serverBackend else { return }
            do {
                _ = try backend.updateAccountGroup(id: group.id, with: group)
                self.localServerRuntime?.refreshConnectedAccountsFromBackendAndBroadcastColor()
                self.reloadLocalStateFromBackend()
                self.showAdminSaved(L("Account group defaults updated."))
            } catch { self.showAdminError(error) }
        }
    }

}
