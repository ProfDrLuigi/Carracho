import Cocoa
import QuickLookUI

// MARK: - Users

extension ViewController {

    func makeRightPanel() -> NSView {
        let container = CarrachoBackgroundView()
        container.fillColor = CarrachoTheme.card

        userTable.usesAlternatingRowBackgroundColors = false
        userTable.backgroundColor = .clear
        let usersScroll = tableScroll(userTable)
        usersScroll.drawsBackground = false
        usersScroll.borderType = .noBorder
        usersScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        usersScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        usersScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        let generalContent = verticalStack([usersScroll], spacing: 0)
        generalInspectorContent = generalContent

        conferenceInspectorTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        conferenceInspectorRoomLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        conferenceInspectorRoomLabel.lineBreakMode = .byTruncatingTail
        conferenceInspectorRoomLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        conferenceInspectorPropertiesLabel.font = .systemFont(ofSize: 11)
        conferenceInspectorPropertiesLabel.textColor = CarrachoTheme.secondaryText
        conferenceInspectorPropertiesLabel.lineBreakMode = .byTruncatingTail
        conferenceInspectorPropertiesLabel.maximumNumberOfLines = 2

        conferenceInspectorParticipantsLabel.font = .systemFont(ofSize: 10.5, weight: .bold)
        conferenceInspectorParticipantsLabel.textColor = CarrachoTheme.secondaryText
        conferenceInspectorParticipantsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let participantsHeader = horizontalStack([
            conferenceInspectorParticipantsLabel, NSView(), channelMemberActionsButton,
        ], spacing: 6)

        channelMemberTable.backgroundColor = .clear
        // The room participant table lives in the resizable inspector. Keep its single column
        // pinned to the actual viewport width; otherwise the original 260 pt construction width
        // survives when the inspector is narrower and the nickname/role/status content is simply
        // clipped off at the right edge.
        channelMemberTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        if let memberColumn = channelMemberTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("member")) {
            memberColumn.minWidth = 120
            memberColumn.resizingMask = [.autoresizingMask]
        }
        let membersScroll = tableScroll(channelMemberTable, tracksViewportWidth: true)
        membersScroll.drawsBackground = false
        membersScroll.borderType = .noBorder
        membersScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        membersScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        membersScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

        channelInviteButton.image = symbolImage("person.badge.plus", fallback: NSImage.addTemplateName)
        channelInviteButton.imagePosition = .imageLeading
        channelInviteButton.bezelStyle = .rounded
        channelSettingsButton.image = symbolImage("gearshape", fallback: NSImage.actionTemplateName)
        channelSettingsButton.imagePosition = .imageLeading
        channelSettingsButton.bezelStyle = .inline
        channelSettingsButton.alignment = .left
        channelModeButton.image = symbolImage("person.crop.circle.badge.checkmark", fallback: NSImage.userAccountsName)
        channelModeButton.imagePosition = .imageLeading
        channelModeButton.bezelStyle = .inline
        channelModeButton.alignment = .left
        channelLeaveButton.image = symbolImage("rectangle.portrait.and.arrow.right", fallback: NSImage.stopProgressTemplateName)
        channelLeaveButton.imagePosition = .imageLeading
        channelLeaveButton.bezelStyle = .inline
        channelLeaveButton.alignment = .left
        channelLeaveButton.contentTintColor = .systemRed

        let roomDivider = CarrachoDividerView()
        roomDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let managementTitle = sidebarSectionLabel(L("ROOM MANAGEMENT"))
        let roomIdentity = verticalStack([
            conferenceInspectorTitleLabel, conferenceInspectorRoomLabel, conferenceInspectorPropertiesLabel,
        ], spacing: 4)
        let conferenceContent = verticalStack([
            roomIdentity, roomDivider,
            participantsHeader, membersScroll, channelInviteButton,
            managementTitle, channelSettingsButton, channelModeButton, channelLeaveButton,
        ], spacing: 8)
        conferenceInspectorContent = conferenceContent

        let contextHost = NSView()
        contextHost.translatesAutoresizingMaskIntoConstraints = false
        for content in [generalContent, conferenceContent] {
            content.translatesAutoresizingMaskIntoConstraints = false
            contextHost.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: contextHost.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: contextHost.trailingAnchor),
                content.topAnchor.constraint(equalTo: contextHost.topAnchor),
                content.bottomAnchor.constraint(equalTo: contextHost.bottomAnchor),
            ])
        }
        contextHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        func infoRow(_ title: String, _ value: NSTextField) -> NSView {
            let label = infoLabel(L(title))
            label.font = .systemFont(ofSize: 10.5)
            label.widthAnchor.constraint(equalToConstant: 76).isActive = true
            label.setContentHuggingPriority(.required, for: .horizontal)
            value.font = .systemFont(ofSize: 11)
            value.alignment = .left
            value.textColor = .labelColor
            value.lineBreakMode = .byTruncatingMiddle
            value.maximumNumberOfLines = 1
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return horizontalStack([label, value], spacing: 8)
        }

        let serverInfoBody = verticalStack([
            infoRow("Uptime", rightServerUptimeValue),
            infoRow("Software", rightServerVersionValue),
        ], spacing: 7)
        inspectorServerInfoBody = serverInfoBody

        let connectionBody = verticalStack([
            infoRow("Protocol", rightServerProtocolValue),
            infoRow("Encryption", rightServerCipherValue),
            infoRow("Endpoint", rightEndpointValue),
        ], spacing: 7)
        inspectorConnectionDetailsBody = connectionBody

        let serverInfoCollapsed = UserDefaults.standard.bool(forKey: Self.inspectorServerInfoCollapsedDefaultsKey)
        let connectionCollapsed = UserDefaults.standard.bool(forKey: Self.inspectorConnectionDetailsCollapsedDefaultsKey)
        serverInfoBody.isHidden = serverInfoCollapsed
        connectionBody.isHidden = connectionCollapsed

        let serverInfoButton = inspectorDisclosureButton(title: L("Server Information"), collapsed: serverInfoCollapsed,
                                                         action: #selector(toggleInspectorServerInfo(_:)))
        inspectorServerInfoDisclosureButton = serverInfoButton
        let connectionButton = inspectorDisclosureButton(title: L("Connection Details"), collapsed: connectionCollapsed,
                                                         action: #selector(toggleInspectorConnectionDetails(_:)))
        inspectorConnectionDetailsDisclosureButton = connectionButton

        let divider1 = CarrachoDividerView()
        divider1.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let divider2 = CarrachoDividerView()
        divider2.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let stack = verticalStack([
            contextHost,
            divider1, serverInfoButton, serverInfoBody,
            divider2, connectionButton, connectionBody,
        ], spacing: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        updateInspectorContext()
        return container
    }

    func reloadUserTablePreservingSelection() {
        let rememberedUserID = selectedUserID
        isReloadingUserTable = true
        userTable.reloadData()
        if let rememberedUserID,
           let row = visibleUsers.firstIndex(where: { $0.userID == rememberedUserID }) {
            userTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            userTable.deselectAll(nil)
            selectedUserID = nil
        }
        isReloadingUserTable = false
        updateUserActionButtons()
    }

    func updateUserActionButtons() {
        let connected = client.isConnected
        let selectedUser = selectedUserEntry
        let selected = selectedUser != nil
        let ownUserID = lastLoginResult?.session.userID
        let mayModerateSelection = selectedUser.map { $0.userID != ownUserID } ?? false
        userInfoButton.isEnabled = connected && selected
        userMessageButton.isEnabled = connected && selected
        userOfflineMessageButton.isEnabled = connected
        userDisconnectButton.isEnabled = connected && mayModerateSelection
            && remotePermissionEnabled(LegacyAccountPermissionBit.disconnectUsers)
        userBanButton.isEnabled = connected && mayModerateSelection
            && remotePermissionEnabled(LegacyAccountPermissionBit.banUsers)
        userDisconnectButton.toolTip = userDisconnectButton.isEnabled ? L("Disconnect this user's current session. The user may reconnect immediately.") : nil
        userBanButton.toolTip = userBanButton.isEnabled ? L("Persistently block the user's current IP address and disconnect the session.") : nil
        let ownSelected = selectedUser?.userID == ownUserID && ownUserID != nil
        presenceButton.title = L("Sleep")
        presenceButton.isHidden = !ownSelected
        presenceButton.isEnabled = connected && ownSelected && ownUserID.map { !sleepingUsers.contains($0) } == true
    }

    @objc func showSelectedUserInfo(_ sender: Any?) {
        guard let user = selectedUserEntry else { return }
        userInfoButton.isEnabled = false
        client.requestUserInfo(userID: user.userID) { [weak self] result in
            guard let self else { return }
            self.updateUserActionButtons()
            switch result {
            case let .failure(error):
                self.appendLine("\n" + LF("User Info could not be loaded: %@", Self.displayMessage(for: error)))
                self.showError(LF("User Info could not be loaded: %@", Self.displayMessage(for: error)))
            case let .success(info):
                self.presentUserInfo(info, listEntry: user)
            }
        }
    }

    func presentUserInfo(_ info: LegacyUserInfoReply, listEntry: LegacyUserListEntry) {
        guard let window = view.window else { return }
        let nicknameText = Self.macRomanString(info.nickname).isEmpty ? Self.macRomanString(listEntry.nickname) : Self.macRomanString(info.nickname)
        let isOwnUser = info.userID == lastLoginResult?.session.userID
        let isSleeping = sleepingUsers.contains(info.userID)

        let alert = NSAlert()
        // The hero already contains the nickname and presence state. Repeating the nickname plus
        // a generic "reported by the server" line above it only wastes vertical space. Leaving
        // NSAlert's message/informative text empty collapses those two standard rows so the actual
        // profile content begins at the top of the sheet.
        alert.addButton(withTitle: L("Close"))
        alert.addButton(withTitle: L("Refresh"))

        func valueRowWithField(_ title: String, _ value: String, selectable: Bool = false) -> (row: NSView, field: NSTextField) {
            let label = infoLabel(L(title))
            label.widthAnchor.constraint(equalToConstant: 112).isActive = true
            let field = NSTextField(labelWithString: value.isEmpty ? "—" : value)
            field.font = .systemFont(ofSize: 12.5)
            field.lineBreakMode = .byTruncatingMiddle
            field.isSelectable = selectable
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return (horizontalStack([label, field], spacing: 12), field)
        }

        func valueRow(_ title: String, _ value: String, selectable: Bool = false) -> NSView {
            valueRowWithField(title, value, selectable: selectable).row
        }

        func liveDurationString(_ seconds: TimeInterval) -> String {
            guard seconds.isFinite else { return "—" }
            let total = max(0, Int(seconds.rounded(.down)))
            let days = total / 86_400
            let hours = (total % 86_400) / 3_600
            let minutes = (total % 3_600) / 60
            let secs = total % 60
            if days > 0 { return LF("%@d %@h %@m %@s", String(days), String(hours), String(minutes), String(secs)) }
            if hours > 0 { return LF("%@h %@m %@s", String(hours), String(minutes), String(secs)) }
            if minutes > 0 { return LF("%@m %@s", String(minutes), String(secs)) }
            return LF("%@s", String(secs))
        }

        func section(_ title: String, _ rows: [NSView]) -> NSView {
            let card = cardView()
            let stack = verticalStack([cardTitle(L(title))] + rows, spacing: 8)
            pin(stack, in: card, inset: 12)
            return card
        }

        let avatar = NSImageView()
        if let picture = NSImage(data: info.picture), !info.picture.isEmpty {
            avatar.image = picture
        } else if let picture = NSImage(data: listEntry.picture), !listEntry.picture.isEmpty {
            avatar.image = picture
        } else {
            avatar.image = AvatarArtwork.defaultImage()
            avatar.contentTintColor = nil
        }
        avatar.imageScaling = .scaleProportionallyDown
        avatar.translatesAutoresizingMaskIntoConstraints = false
        // Do not crop arbitrary user artwork into a circle. Classic avatars often use the full
        // square canvas (stars and other irregular shapes in particular), so a circular mask can
        // shave off corners even though the image itself is valid. Proportional-down scaling keeps
        // the complete avatar inside the 88 pt frame.
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 88),
            avatar.heightAnchor.constraint(equalToConstant: 88),
        ])

        let heroName = NSTextField(labelWithString: nicknameText.isEmpty ? L("User") : nicknameText)
        heroName.font = .systemFont(ofSize: 22, weight: .semibold)
        heroName.lineBreakMode = .byTruncatingTail
        let status = NSTextField(labelWithString: isSleeping ? L("Sleeping") : L("Online"))
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = isSleeping ? CarrachoTheme.secondaryText : CarrachoTheme.success
        let heroText = verticalStack([heroName, status], spacing: 5)
        let hero = horizontalStack([avatar, heroText], spacing: 16)

        let aboutText = isOwnUser ? generalAboutMe : Self.macRomanString(info.aboutMe)
        let emailText = isOwnUser ? generalEmail : Self.macRomanString(info.email)
        let about = NSTextField(wrappingLabelWithString: aboutText.isEmpty ? "—" : aboutText)
        about.font = .systemFont(ofSize: 12.5)
        about.maximumNumberOfLines = 0
        about.isSelectable = true

        let profileDetails = section("Profile", [
            valueRow("Nickname", nicknameText, selectable: true),
            valueRow("Name", Self.macRomanString(info.name), selectable: true),
            valueRow("eMail", emailText, selectable: true),
        ])
        let aboutCard = section("About me", [about])

        // Connection details used to live behind their own tab. Keep the exact permission
        // semantics, but show the returned data inline below About Me so the sheet reads top to bottom.
        let hasExtendedInfo = info.loginName != nil || info.ipAddress != nil || info.loginTime != nil || info.taskList != nil ||
            info.operatingSystem != nil || info.cpuArchitecture != nil || info.clientVersion != nil || info.clientBuild != nil
        var connectionRows: [NSView] = []
        let openedAt = Date()
        let idleReferenceDate = info.idleTime.map { openedAt.addingTimeInterval(-Double($0) / 60.0) }
        let loginDate = info.loginTime.flatMap { Date.fromLegacyMacTimestamp($0) }
        let idleValue = idleReferenceDate.map { liveDurationString(openedAt.timeIntervalSince($0)) } ?? "—"
        var idleValueField: NSTextField?
        var onlineValueField: NSTextField?
        if hasExtendedInfo {
            let loginTimeValue = info.loginTime.map { Self.macDateString($0) } ?? "—"
            let onlineValue = loginDate.map { liveDurationString(openedAt.timeIntervalSince($0)) } ?? "—"
            let clientVersionValue: String
            if let version = info.clientVersion, let build = info.clientBuild {
                clientVersionValue = "\(version) (Build \(build))"
            } else if let version = info.clientVersion {
                clientVersionValue = version
            } else if let build = info.clientBuild {
                clientVersionValue = "Build \(build)"
            } else {
                clientVersionValue = "—"
            }

            let idleRow = valueRowWithField("Idle", idleValue)
            idleValueField = idleRow.field
            let onlineRow = valueRowWithField("Online for", onlineValue)
            onlineValueField = onlineRow.field
            let leftColumn = verticalStack([
                idleRow.row,
                valueRow("Login", info.loginName.map { Self.macRomanString($0) } ?? "—", selectable: true),
                valueRow("IP address", info.ipAddress.map { Self.ipv4String($0) } ?? "—", selectable: true),
                valueRow("Login time", loginTimeValue),
            ], spacing: 8)
            let rightColumn = verticalStack([
                onlineRow.row,
                valueRow("Operating system", info.operatingSystem ?? "—", selectable: true),
                valueRow("CPU architecture", info.cpuArchitecture ?? "—", selectable: true),
                valueRow("Carracho client", clientVersionValue, selectable: true),
            ], spacing: 8)
            let columns = horizontalStack([leftColumn, rightColumn], spacing: 20)
            leftColumn.widthAnchor.constraint(equalTo: rightColumn.widthAnchor).isActive = true
            connectionRows.append(columns)
        } else {
            let idleRow = valueRowWithField("Idle", idleValue)
            idleValueField = idleRow.field
            connectionRows.append(idleRow.row)
            let note = NSTextField(wrappingLabelWithString: L("Login name, IP address, login time and active tasks require extended user-information access on servers that enforce this permission."))
            note.font = .systemFont(ofSize: 12.5)
            note.textColor = CarrachoTheme.secondaryText
            note.maximumNumberOfLines = 0
            connectionRows.append(note)
        }
        let connectionCard = section("Connection", connectionRows)

        // Live task / transfer information follows Connection in the same scrollable page.
        let tasks: [LegacyCompactTaskInfo]
        var taskDecodeError: String?
        if let raw = info.taskList {
            do { tasks = try LegacyPackedRecords.decodeCompactTaskList(raw) }
            catch {
                tasks = []
                taskDecodeError = Self.displayMessage(for: error)
            }
        } else {
            tasks = []
        }

        let taskCard: NSView
        if let taskDecodeError {
            let text = NSTextField(wrappingLabelWithString: LF("The task list could not be decoded: %@", taskDecodeError))
            text.textColor = .systemRed
            taskCard = section("Tasks", [text])
        } else if info.taskList == nil {
            let text = NSTextField(wrappingLabelWithString: L("No privileged task information was returned by the server."))
            text.textColor = CarrachoTheme.secondaryText
            taskCard = section("Tasks", [text])
        } else if tasks.isEmpty {
            let emptyIcon = symbolView("checkmark.circle", size: 28, tint: CarrachoTheme.success)
            let text = NSTextField(labelWithString: L("No active transfers"))
            text.font = .systemFont(ofSize: 13, weight: .medium)
            let detail = infoLabel(L("This user currently has no upload or download task reported by the server."))
            taskCard = section("Tasks", [horizontalStack([emptyIcon, verticalStack([text, detail], spacing: 3)], spacing: 12)])
        } else {
            var taskRows: [NSView] = []
            for task in tasks {
                let direction: String
                let symbol: String
                switch task.kind {
                case LegacyTransferKind.download: direction = L("Download"); symbol = "arrow.down.circle.fill"
                case LegacyTransferKind.upload: direction = L("Upload"); symbol = "arrow.up.circle.fill"
                default: direction = LF("Transfer %@", String(task.kind)); symbol = "arrow.left.arrow.right.circle.fill"
                }
                let icon = symbolView(symbol, size: 26, tint: CarrachoTheme.selection)
                let name = NSTextField(labelWithString: Self.macRomanString(task.displayName))
                name.font = .systemFont(ofSize: 13, weight: .semibold)
                name.lineBreakMode = .byTruncatingMiddle
                let metadata = infoLabel(LF("%@  ·  Task #%@", direction, String(task.transferID)))
                let labels = verticalStack([name, metadata], spacing: 3)
                let percent = NSTextField(labelWithString: "\(task.progressPercent)%")
                percent.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                percent.alignment = .right
                percent.widthAnchor.constraint(equalToConstant: 46).isActive = true
                let top = horizontalStack([icon, labels, percent], spacing: 10)
                let progress = NSProgressIndicator()
                progress.style = .bar
                progress.isIndeterminate = false
                progress.minValue = 0
                progress.maxValue = 100
                progress.doubleValue = Double(task.progressPercent)
                taskRows.append(verticalStack([top, progress], spacing: 7))
            }
            taskCard = section("Tasks", taskRows)
        }

        let contentStack = verticalStack([hero, profileDetails, aboutCard, connectionCard, taskCard], spacing: 12)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let document = CarrachoFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contentStack)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 500))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        alert.accessoryView = scroll

        func updateLiveDurations() {
            let now = Date()
            if let idleReferenceDate, let idleValueField {
                idleValueField.stringValue = liveDurationString(now.timeIntervalSince(idleReferenceDate))
            }
            if let loginDate, let onlineValueField {
                onlineValueField.stringValue = liveDurationString(now.timeIntervalSince(loginDate))
            }
        }
        updateLiveDurations()
        let durationTimer = Timer(timeInterval: 1.0, repeats: true) { _ in updateLiveDurations() }
        RunLoop.main.add(durationTimer, forMode: .common)

        alert.beginSheetModal(for: window) { [weak self] response in
            durationTimer.invalidate()
            guard let self else { return }
            if response == .alertSecondButtonReturn {
                guard let row = self.visibleUsers.firstIndex(where: { $0.userID == info.userID }) else { return }
                self.userTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                self.showSelectedUserInfo(nil)
            }
        }
    }

    func presentRichMessage(title: String, senderLine: String, message: Data) {
        guard let window = view.window else { return }
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 190))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.useCarrachoLinkAppearance()
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textStorage?.setAttributedString(
            CarrachoHTMLText.attributedString(fromWire: message, baseFont: .systemFont(ofSize: 13), expandLegacyEmoticons: true)
        )
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 190))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = senderLine
        alert.addButton(withTitle: L("OK"))
        alert.accessoryView = scroll
        alert.beginSheetModal(for: window)
    }

    @objc func messageSelectedUser(_ sender: Any?) {
        guard let user = selectedUserEntry else { return }
        openPrivateConversation(with: user)
    }

    @objc func kickSelectedUser(_ sender: Any?) {
        guard let user = selectedUserEntry, let window = view.window,
              user.userID != lastLoginResult?.session.userID else { return }
        let nickname = Self.macRomanString(user.nickname)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Kick User")
        alert.informativeText = LF("Disconnect %@’s current session? The user can reconnect immediately.", nickname)
        alert.addButton(withTitle: L("Kick"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.client.kickUser(userID: user.userID) { [weak self] result in
                switch result {
                case .success:
                    self?.appendLine("\n" + LF("%@ was disconnected.", nickname))
                case let .failure(error):
                    self?.appendLine("\n" + LF("Kick failed: %@", Self.displayMessage(for: error)))
                }
            }
        }
    }

    @objc func banSelectedUser(_ sender: Any?) {
        guard let user = selectedUserEntry, let window = view.window,
              user.userID != lastLoginResult?.session.userID else { return }
        let nickname = Self.macRomanString(user.nickname)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L("Ban User")
        alert.informativeText = LF("Persistently ban the IP address currently used by %@ and disconnect that session? The deny rule remains active until it is removed from the server’s IP restrictions.", nickname)
        alert.addButton(withTitle: L("Ban"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.client.banUser(userID: user.userID) { [weak self] result in
                switch result {
                case .success:
                    self?.appendLine("\n" + LF("%@ was banned.", nickname))
                    if self?.currentWorkspace == .advanced { self?.reloadBanManagement() }
                case let .failure(error):
                    self?.appendLine("\n" + LF("Ban failed: %@", Self.displayMessage(for: error)))
                }
            }
        }
    }

    func synchronizeLocalAvatarAfterLogin(_ login: LegacyLoginResult) {
        guard let identity = activeAvatarIdentity else { return }
        let storageIdentity = avatarStorageIdentity(for: identity)
        let ownUser = login.users.first(where: { $0.userID == login.session.userID })
        let avatarData: Data
        do {
            switch try localAvatarStore.state(for: storageIdentity) {
            case let .avatar(data):
                avatarData = data
            case .none:
                avatarData = Data()
            case .unconfigured:
                if let serverPicture = ownUser?.picture, !serverPicture.isEmpty, let image = NSImage(data: serverPicture) {
                    avatarData = try AvatarImageProcessor.normalizedPNG(from: image)
                    try localAvatarStore.save(avatarData, for: storageIdentity)
                    appendLine("\n" + L("Existing server avatar migrated to local profile storage."))
                } else {
                    avatarData = Data()
                    try localAvatarStore.save(Data(), for: storageIdentity)
                }
            }
        } catch {
            appendLine("\n" + LF("Local avatar could not be loaded: %@", Self.displayMessage(for: error)))
            return
        }

        let nickname = ownUser?.nickname ?? (nicknameField.stringValue.data(using: .macOSRoman) ?? Data())
        guard !nickname.isEmpty else { return }
        client.updateUser(nickname: nickname, picture: avatarData) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if var current = self.liveUsers[login.session.userID] {
                    current.picture = avatarData
                    self.liveUsers[login.session.userID] = current
                    self.renderSession()
                }
                self.appendLine("\n" + L("Local avatar synchronized with server."))
            case let .failure(error):
                self.appendLine("\n" + LF("Local avatar could not be synchronized: %@", Self.displayMessage(for: error)))
            }
        }
    }

    func setSleepingState(_ sleeping: Bool, for userID: UInt32) {
        if sleeping { sleepingUsers.insert(userID) } else { sleepingUsers.remove(userID) }

        // Keep the Classic user-list flag in sync as a second source of truth. The UI is rebuilt
        // frequently (sorting, bookmark switching, status refreshes), so carrying the presence bit
        // in the actual row model prevents a later repaint from losing an already received state.
        if var user = liveUsers[userID] {
            if sleeping { user.flags |= 0x0100 } else { user.flags &= ~UInt16(0x0100) }
            liveUsers[userID] = user
        }
        if var login = lastLoginResult,
           let index = login.users.firstIndex(where: { $0.userID == userID }) {
            if sleeping { login.users[index].flags |= 0x0100 }
            else { login.users[index].flags &= ~UInt16(0x0100) }
            lastLoginResult = login
        }
    }

    @objc func toggleOwnPresence(_ sender: Any?) {
        guard let ownID = lastLoginResult?.session.userID,
              selectedUserEntry?.userID == ownID,
              !sleepingUsers.contains(ownID) else { return }
        presenceButton.isEnabled = false
        client.setPresence(sleeping: true) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // The server broadcasts the same state as well. Updating optimistically here keeps
                // the menu and user row correct even if the async event arrives a moment later.
                self.setSleepingState(true, for: ownID)
                self.reloadUserTablePreservingSelection()
            case let .failure(error):
                self.updateUserActionButtons()
                self.appendLine("\n" + LF("Sleep could not be enabled: %@", Self.displayMessage(for: error)))
            }
        }
    }

    func userListCell(for user: LegacyUserListEntry) -> NSView {
        let avatar = NSImageView()
        if user.isLegacyTransport {
            // Classic sessions always use the dedicated Legacy avatar. Their stored/profile
            // picture is deliberately ignored so transport origin is immediately visible.
            avatar.image = NSImage(named: NSImage.Name("LegacyAvatar")) ?? AvatarArtwork.defaultImage()
            avatar.contentTintColor = nil
        } else if let picture = NSImage(data: user.picture), !user.picture.isEmpty {
            avatar.image = picture
        } else {
            avatar.image = AvatarArtwork.defaultImage()
            avatar.contentTintColor = nil
        }
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 15
        avatar.layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 30),
            avatar.heightAnchor.constraint(equalToConstant: 30),
        ])

        let name = NSTextField(labelWithString: Self.macRomanString(user.nickname))
        name.font = .systemFont(ofSize: 12.5, weight: .medium)
        if let rgb = userGroupColors[user.userID] { name.textColor = Self.colorFromRGB(rgb) }
        name.lineBreakMode = .byTruncatingTail
        // The nickname must yield space before the sleep marker does. With the old priorities a
        // long nickname compressed zZZ to zero width, making presence look randomly broken.
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let sleeping = sleepingUsers.contains(user.userID) || (user.flags & 0x0100) != 0
        let sleepIndicator = NSTextField(labelWithString: "zZZ")
        sleepIndicator.font = .systemFont(ofSize: 9.5, weight: .semibold)
        sleepIndicator.textColor = CarrachoTheme.secondaryText
        sleepIndicator.toolTip = L("Sleeping")
        sleepIndicator.setContentHuggingPriority(.required, for: .horizontal)
        sleepIndicator.setContentCompressionResistancePriority(.required, for: .horizontal)
        let nameRow = horizontalStack([name, sleepIndicator], spacing: 5)
        // NSStackView(views:) may normalize hidden state while adopting arranged subviews.
        // Apply it afterwards so awake users never inherit a visible zZZ indicator.
        sleepIndicator.isHidden = !sleeping

        let status = Self.macRomanString(userStatusMessages[user.userID] ?? Data())
        let labelViews: [NSView]
        if status.isEmpty {
            // No fake blank second line: a single-line name stack is centered vertically next to
            // the avatar by the horizontal row stack.
            labelViews = [nameRow]
        } else {
            let detail = infoLabel(status)
            detail.lineBreakMode = .byTruncatingTail
            detail.toolTip = status
            labelViews = [nameRow, detail]
        }
        let labels = verticalStack(labelViews, spacing: 2)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = horizontalStack([avatar, labels], spacing: 9)
        row.distribution = .fill
        return row
    }

    func refreshUserStatuses(excluding excludedUserID: UInt32? = nil) {
        guard client.isConnected else { return }
        for userID in liveUsers.keys where userID != excludedUserID {
            refreshUserStatus(userID: userID)
        }
    }

    func refreshUserStatus(userID: UInt32) {
        guard client.isConnected, liveUsers[userID] != nil else { return }
        client.requestUserInfo(userID: userID) { [weak self] result in
            guard let self, self.liveUsers[userID] != nil else { return }
            if case let .success(info) = result {
                self.userStatusMessages[userID] = info.statusMessage
                if let color = info.groupColorRGB { self.userGroupColors[userID] = color }
                else { self.userGroupColors.removeValue(forKey: userID) }
                self.reloadUserTablePreservingSelection()
                if self.channelMembers[userID] != nil { self.channelMemberTable.reloadData() }
            }
        }
    }

    func publishNickname(for bookmark: ServerBookmark, logErrors: Bool) {
        let effectiveNickname = effectiveNickname(for: bookmark)
        guard let data = effectiveNickname.data(using: .macOSRoman), !data.isEmpty, data.count <= 64 else {
            if logErrors { appendLine("\n" + L("Bookmark nickname is not MacRoman-compatible or exceeds 64 bytes.")) }
            return
        }

        let isActive = activeBookmarkConnectionID == bookmark.id && client.isConnected
        let context = bookmarkConnections[bookmark.id]
        let targetClient: LegacyControlClient?
        if isActive {
            targetClient = client
        } else if let context, context.client.isConnected {
            targetClient = context.client
        } else {
            targetClient = nil
        }
        guard let targetClient else { return }

        let ownUserID = isActive
            ? lastLoginResult?.session.userID
            : context?.snapshot?.lastLoginResult?.session.userID
        if let ownUserID {
            if isActive {
                if var ownUser = liveUsers[ownUserID] {
                    ownUser.nickname = data
                    liveUsers[ownUserID] = ownUser
                }
                reloadUserTablePreservingSelection()
            } else if let context, var snapshot = context.snapshot {
                if var ownUser = snapshot.liveUsers[ownUserID] {
                    ownUser.nickname = data
                    snapshot.liveUsers[ownUserID] = ownUser
                }
                context.snapshot = snapshot
            }
        }

        targetClient.updateNickname(data) { [weak self] result in
            guard let self else { return }
            if case let .failure(error) = result, logErrors {
                self.appendLine("\n" + LF("Nickname could not be updated: %@", Self.displayMessage(for: error)))
            }
        }
    }

    func publishStatusMessage(for bookmark: ServerBookmark, logErrors: Bool) {
        let status = effectiveStatusMessage(for: bookmark)
        guard let data = status.data(using: .macOSRoman), data.count <= 255 else {
            if logErrors { appendLine("\n" + L("Status is not MacRoman-compatible or exceeds 255 bytes.")) }
            return
        }

        let isActive = activeBookmarkConnectionID == bookmark.id && client.isConnected
        let context = bookmarkConnections[bookmark.id]
        let targetClient: LegacyControlClient?
        if isActive {
            targetClient = client
        } else if let context, context.client.isConnected {
            targetClient = context.client
        } else {
            targetClient = nil
        }
        guard let targetClient else { return }

        let ownUserID = isActive ? lastLoginResult?.session.userID : context?.snapshot?.lastLoginResult?.session.userID
        if let ownUserID {
            if isActive {
                userStatusMessages[ownUserID] = data
                reloadUserTablePreservingSelection()
            } else if let context, var snapshot = context.snapshot {
                snapshot.userStatusMessages[ownUserID] = data
                context.snapshot = snapshot
            }
        }

        targetClient.updateStatusMessage(data) { [weak self] result in
            guard let self else { return }
            if case let .failure(error) = result, logErrors {
                self.appendLine("\n" + LF("Status could not be updated: %@", Self.displayMessage(for: error)))
            }
        }
    }
    @objc func menuUsers(_ sender: Any?) {
        selectWorkspace(.conferences)
        view.window?.makeFirstResponder(userTable)
    }

}
