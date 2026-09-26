import Cocoa
import QuickLookUI

// MARK: - MessageCenter

extension ViewController {

    func makeMessageCenterPage() -> NSView {
        let page = CarrachoBackgroundView()
        page.fillColor = CarrachoTheme.conferenceTranscriptBackground

        let title = NSTextField(labelWithString: L("Message Center"))
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.setContentHuggingPriority(.required, for: .horizontal)

        privateMessageMarkReadButton.target = self
        privateMessageMarkReadButton.action = #selector(markAllPrivateMessagesRead(_:))
        privateMessageMarkReadButton.controlSize = .regular
        privateMessageMarkReadButton.bezelStyle = .inline
        privateMessageMarkReadButton.font = .systemFont(ofSize: 13, weight: .medium)
        privateMessageMarkReadButton.image = sizedAssetImage(named: "Mark All Read", size: 18)
        privateMessageMarkReadButton.imagePosition = .imageLeading
        privateMessageMarkReadButton.imageScaling = .scaleNone
        privateMessageMarkReadButton.contentTintColor = nil
        privateMessageMarkReadButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        privateMessageNewButton.target = self
        privateMessageNewButton.action = #selector(showNewPrivateMessageMenu(_:))
        privateMessageNewButton.controlSize = .regular
        privateMessageNewButton.bezelStyle = .rounded
        privateMessageNewButton.image = symbolImage("plus", fallback: NSImage.addTemplateName)
        privateMessageNewButton.image?.size = NSSize(width: 18, height: 18)
        privateMessageNewButton.imagePosition = .imageLeading
        privateMessageNewButton.imageScaling = .scaleNone
        privateMessageNewButton.font = .systemFont(ofSize: 13, weight: .medium)
        privateMessageNewButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        configureContentFontSizePopup(messageCenterFontSizePopup, selectedSize: messageCenterFontSize, help: L("Message Center font size"))
        messageCenterFontSizePopup.controlSize = .regular
        messageCenterFontSizePopup.font = .systemFont(ofSize: 13)

        let topBar = CarrachoBackgroundView()
        topBar.fillColor = CarrachoTheme.elevatedCard
        let topStack = horizontalStack([title, NSView(), privateMessageMarkReadButton, messageCenterFontSizePopup, privateMessageNewButton], spacing: 10)
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(topStack)
        let topDivider = CarrachoDividerView()
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(topDivider)
        NSLayoutConstraint.activate([
            topStack.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 18),
            topStack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -14),
            topStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            topDivider.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            topDivider.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),
        ])

        let conversationsPane = CarrachoBackgroundView()
        conversationsPane.fillColor = CarrachoTheme.conferenceTranscriptBackground
        privateMessageSearchField.placeholderString = L("Search conversations…")
        privateMessageSearchField.target = self
        privateMessageSearchField.action = #selector(privateMessageSearchChanged(_:))
        privateMessageSearchField.sendsSearchStringImmediately = true
        if let searchCell = privateMessageSearchField.cell as? NSSearchFieldCell {
            searchCell.searchButtonCell?.image = sizedAssetImage(named: "Search", size: 14)
        }
        privateMessageSearchField.translatesAutoresizingMaskIntoConstraints = false

        configure(table: privateMessageConversationTable, columns: [("conversation", "", 280)])
        privateMessageConversationTable.headerView = nil
        privateMessageConversationTable.rowHeight = max(68, messageCenterFontSize * 2 + 22)
        privateMessageConversationTable.intercellSpacing = .zero
        privateMessageConversationTable.usesAlternatingRowBackgroundColors = false
        privateMessageConversationTable.allowsMultipleSelection = false
        privateMessageConversationTable.allowsEmptySelection = true
        privateMessageConversationTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        if let column = privateMessageConversationTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("conversation")) {
            column.minWidth = 190
            column.resizingMask = [.autoresizingMask]
        }
        let conversationScroll = tableScroll(privateMessageConversationTable, tracksViewportWidth: true)
        conversationScroll.drawsBackground = true
        conversationScroll.backgroundColor = CarrachoTheme.conferenceTranscriptBackground
        privateMessageConversationTable.backgroundColor = CarrachoTheme.conferenceTranscriptBackground
        conversationScroll.borderType = .noBorder
        conversationScroll.translatesAutoresizingMaskIntoConstraints = false
        conversationsPane.addSubview(privateMessageSearchField)
        conversationsPane.addSubview(conversationScroll)
        NSLayoutConstraint.activate([
            privateMessageSearchField.leadingAnchor.constraint(equalTo: conversationsPane.leadingAnchor, constant: 10),
            privateMessageSearchField.trailingAnchor.constraint(equalTo: conversationsPane.trailingAnchor, constant: -10),
            privateMessageSearchField.topAnchor.constraint(equalTo: conversationsPane.topAnchor, constant: 10),
            conversationScroll.leadingAnchor.constraint(equalTo: conversationsPane.leadingAnchor),
            conversationScroll.trailingAnchor.constraint(equalTo: conversationsPane.trailingAnchor),
            conversationScroll.topAnchor.constraint(equalTo: privateMessageSearchField.bottomAnchor, constant: 8),
            conversationScroll.bottomAnchor.constraint(equalTo: conversationsPane.bottomAnchor),
        ])

        let conversationPane = CarrachoBackgroundView()
        conversationPane.fillColor = CarrachoTheme.conferenceTranscriptBackground

        privateMessageHeaderAvatar.imageScaling = .scaleProportionallyUpOrDown
        privateMessageHeaderAvatar.wantsLayer = true
        privateMessageHeaderAvatar.layer?.cornerRadius = 18
        privateMessageHeaderAvatar.layer?.masksToBounds = true
        privateMessageHeaderAvatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            privateMessageHeaderAvatar.widthAnchor.constraint(equalToConstant: 36),
            privateMessageHeaderAvatar.heightAnchor.constraint(equalToConstant: 36),
        ])
        privateMessageHeaderNameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        privateMessageHeaderNameLabel.lineBreakMode = .byTruncatingTail
        privateMessageHeaderStatusLabel.font = .systemFont(ofSize: 10.5)
        privateMessageHeaderStatusLabel.textColor = CarrachoTheme.secondaryText
        privateMessageHeaderStatusLabel.lineBreakMode = .byTruncatingTail
        privateMessageClearChatButton.target = self
        privateMessageClearChatButton.action = #selector(clearSelectedPrivateChat(_:))
        privateMessageClearChatButton.controlSize = .small
        privateMessageClearChatButton.bezelStyle = .inline
        privateMessageClearChatButton.image = sizedAssetImage(named: "Clear", size: 16)
        privateMessageClearChatButton.imagePosition = .imageLeading
        privateMessageClearChatButton.imageScaling = .scaleNone
        privateMessageClearChatButton.contentTintColor = nil
        privateMessageClearChatButton.toolTip = L("Remove all messages from this chat but keep the conversation")
        privateMessageClearChatButton.isHidden = true
        privateMessageDeleteChatButton.target = self
        privateMessageDeleteChatButton.action = #selector(deleteSelectedPrivateChat(_:))
        privateMessageDeleteChatButton.controlSize = .small
        privateMessageDeleteChatButton.bezelStyle = .inline
        privateMessageDeleteChatButton.image = sizedAssetImage(named: "Trash", size: 16)
        privateMessageDeleteChatButton.imagePosition = .imageLeading
        privateMessageDeleteChatButton.imageScaling = .scaleNone
        privateMessageDeleteChatButton.contentTintColor = nil
        privateMessageDeleteChatButton.toolTip = L("Delete this chat from Message Center")
        privateMessageDeleteChatButton.isHidden = true
        let headerLabels = verticalStack([privateMessageHeaderNameLabel, privateMessageHeaderStatusLabel], spacing: 2)
        let threadHeader = horizontalStack([privateMessageHeaderAvatar, headerLabels, NSView(), privateMessageClearChatButton, privateMessageDeleteChatButton], spacing: 9)
        threadHeader.translatesAutoresizingMaskIntoConstraints = false
        let threadHeaderDivider = CarrachoDividerView()
        threadHeaderDivider.translatesAutoresizingMaskIntoConstraints = false
        conversationPane.addSubview(threadHeader)
        conversationPane.addSubview(threadHeaderDivider)

        let transcriptScroll = NSScrollView()
        transcriptScroll.drawsBackground = false
        transcriptScroll.borderType = .noBorder
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false
        let transcriptDocument = CarrachoFlippedView()
        transcriptDocument.translatesAutoresizingMaskIntoConstraints = false
        transcriptScroll.documentView = transcriptDocument
        privateMessageTranscriptStack.orientation = .vertical
        privateMessageTranscriptStack.alignment = .width
        privateMessageTranscriptStack.spacing = 8
        privateMessageTranscriptStack.translatesAutoresizingMaskIntoConstraints = false
        transcriptDocument.addSubview(privateMessageTranscriptStack)
        NSLayoutConstraint.activate([
            transcriptDocument.widthAnchor.constraint(equalTo: transcriptScroll.contentView.widthAnchor),
            privateMessageTranscriptStack.leadingAnchor.constraint(equalTo: transcriptDocument.leadingAnchor, constant: 12),
            privateMessageTranscriptStack.trailingAnchor.constraint(equalTo: transcriptDocument.trailingAnchor, constant: -12),
            privateMessageTranscriptStack.topAnchor.constraint(equalTo: transcriptDocument.topAnchor, constant: 12),
            privateMessageTranscriptStack.bottomAnchor.constraint(equalTo: transcriptDocument.bottomAnchor, constant: -12),
        ])
        privateMessageTranscriptScroll = transcriptScroll
        privateMessageEmptyLabel.alignment = .center
        privateMessageEmptyLabel.textColor = CarrachoTheme.secondaryText
        privateMessageEmptyLabel.font = .systemFont(ofSize: messageCenterFontSize)
        privateMessageEmptyLabel.maximumNumberOfLines = 3
        privateMessageEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        conversationPane.addSubview(transcriptScroll)
        conversationPane.addSubview(privateMessageEmptyLabel)

        privateMessageComposer.delegate = self
        privateMessageComposer.isRichText = false
        privateMessageComposer.allowsUndo = true
        privateMessageComposer.isAutomaticQuoteSubstitutionEnabled = false
        privateMessageComposer.isAutomaticDashSubstitutionEnabled = false
        privateMessageComposer.isHorizontallyResizable = false
        privateMessageComposer.isVerticallyResizable = true
        privateMessageComposer.autoresizingMask = [.width]
        privateMessageComposer.textContainer?.widthTracksTextView = true
        privateMessageComposer.textContainerInset = NSSize(width: 9, height: 8)
        privateMessageComposer.font = .systemFont(ofSize: messageCenterFontSize)
        privateMessageComposer.drawsBackground = false
        privateMessageComposer.toolTip = CarrachoHTMLText.editorHint
        privateMessageComposer.setAccessibilityLabel(L("Private message"))
        privateMessageComposer.imageFileHandler = { [weak self] urls in
            self?.uploadPrivateMessageImages(urls: urls)
        }
        privateMessageComposer.imageDataHandler = { [weak self] data in
            self?.uploadPrivateMessageImage(data: data)
        }
        privateMessageComposer.youTubeURLHandler = { [weak self] reference in
            guard let self,
                  let userID = self.selectedPrivateConversationID,
                  let conversation = self.privateMessageConversations[userID],
                  !conversation.isLegacyTransport,
                  self.lastLoginResult?.supportsYouTubeLinks == true,
                  self.privateMessageAttachments.youtubeCount < LegacyMediaTransfer.maximumYouTubeLinksPerChatMessage else {
                return false
            }
            self.privateMessageAttachments.addYouTube(reference)
            return true
        }
        privateMessageAttachments.onRemoveImage = { [weak self] id in self?.deletePendingMedia(id) }
        let composerScroll = NSScrollView()
        composerScroll.documentView = privateMessageComposer
        composerScroll.drawsBackground = true
        composerScroll.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.34)
        composerScroll.borderType = .bezelBorder
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.translatesAutoresizingMaskIntoConstraints = false
        composerScroll.heightAnchor.constraint(equalToConstant: 92).isActive = true

        privateMessageSendButton.target = self
        privateMessageSendButton.action = #selector(sendPrivateMessageFromCenter(_:))
        privateMessageSendButton.keyEquivalent = "\r"
        CarrachoTheme.applyPrimaryButtonStyle(privateMessageSendButton)
        privateMessageSendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true
        privateMessageComposerStatusLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        privateMessageComposerStatusLabel.textColor = CarrachoTheme.secondaryText
        privateMessageComposerStatusLabel.lineBreakMode = .byTruncatingTail
        privateMessageComposerHintLabel.font = .systemFont(ofSize: 10)
        privateMessageComposerHintLabel.textColor = CarrachoTheme.tertiaryText
        privateMessageComposerHintLabel.setContentHuggingPriority(.required, for: .horizontal)
        let composerTop = horizontalStack([privateMessageComposerStatusLabel, NSView(), privateMessageComposerHintLabel], spacing: 8)
        let composerActions = horizontalStack([privateMessageEmojiButton, NSView(), privateMessageSendButton], spacing: 8)
        let composer = verticalStack([composerTop, privateMessageAttachments, composerScroll, composerActions], spacing: 7)
        composer.translatesAutoresizingMaskIntoConstraints = false
        let composerDivider = CarrachoDividerView()
        composerDivider.translatesAutoresizingMaskIntoConstraints = false
        conversationPane.addSubview(composerDivider)
        conversationPane.addSubview(composer)

        NSLayoutConstraint.activate([
            threadHeader.leadingAnchor.constraint(equalTo: conversationPane.leadingAnchor, constant: 14),
            threadHeader.trailingAnchor.constraint(equalTo: conversationPane.trailingAnchor, constant: -14),
            threadHeader.topAnchor.constraint(equalTo: conversationPane.topAnchor, constant: 9),
            threadHeader.heightAnchor.constraint(equalToConstant: 42),
            threadHeaderDivider.leadingAnchor.constraint(equalTo: conversationPane.leadingAnchor),
            threadHeaderDivider.trailingAnchor.constraint(equalTo: conversationPane.trailingAnchor),
            threadHeaderDivider.topAnchor.constraint(equalTo: threadHeader.bottomAnchor, constant: 6),
            threadHeaderDivider.heightAnchor.constraint(equalToConstant: 1),

            transcriptScroll.leadingAnchor.constraint(equalTo: conversationPane.leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: conversationPane.trailingAnchor),
            transcriptScroll.topAnchor.constraint(equalTo: threadHeaderDivider.bottomAnchor),
            transcriptScroll.bottomAnchor.constraint(equalTo: composerDivider.topAnchor),
            privateMessageEmptyLabel.centerXAnchor.constraint(equalTo: transcriptScroll.centerXAnchor),
            privateMessageEmptyLabel.centerYAnchor.constraint(equalTo: transcriptScroll.centerYAnchor),
            privateMessageEmptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: transcriptScroll.leadingAnchor, constant: 24),
            privateMessageEmptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: transcriptScroll.trailingAnchor, constant: -24),

            composerDivider.leadingAnchor.constraint(equalTo: conversationPane.leadingAnchor),
            composerDivider.trailingAnchor.constraint(equalTo: conversationPane.trailingAnchor),
            composerDivider.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
            composerDivider.heightAnchor.constraint(equalToConstant: 1),
            composer.leadingAnchor.constraint(equalTo: conversationPane.leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: conversationPane.trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: conversationPane.bottomAnchor, constant: -10),
        ])

        let contentSplit = makeResizableColumnSplit(
            panes: [conversationsPane, conversationPane],
            autosaveName: "Carracho.MessageCenterColumns.v1",
            edge: .leading,
            initialEdgeWidth: 300,
            minimumPaneWidths: [230, 460]
        )
        topBar.translatesAutoresizingMaskIntoConstraints = false
        contentSplit.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(topBar)
        page.addSubview(contentSplit)
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: page.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: CarrachoTheme.workspaceHeaderHeight),
            contentSplit.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            contentSplit.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            contentSplit.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            contentSplit.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        refreshPrivateMessageCenter(scrollToBottom: false)
        return page
    }

    func storedConversation(_ conversation: PrivateMessageConversation) -> MessageCenterStoredConversation {
        MessageCenterStoredConversation(
            userID: conversation.userID,
            nickname: conversation.nickname,
            picture: conversation.picture,
            isLegacyTransport: conversation.isLegacyTransport,
            unreadCount: conversation.unreadCount,
            draftText: conversation.draftText,
            lastActivity: conversation.lastActivity,
            messages: conversation.entries.map {
                MessageCenterStoredPrivateMessage(id: $0.id, userID: conversation.userID,
                                                  timestamp: $0.timestamp, outgoing: $0.outgoing,
                                                  message: $0.message)
            }
        )
    }

    func restoredConversation(_ conversation: MessageCenterStoredConversation) -> PrivateMessageConversation {
        PrivateMessageConversation(
            userID: conversation.userID,
            nickname: conversation.nickname,
            picture: conversation.picture,
            isLegacyTransport: conversation.isLegacyTransport,
            entries: conversation.messages.map {
                PrivateMessageEntry(id: $0.id, timestamp: $0.timestamp, outgoing: $0.outgoing,
                                    message: $0.message, edited: $0.edited, editable: $0.editable)
            },
            unreadCount: conversation.unreadCount,
            draftText: conversation.draftText,
            lastActivity: conversation.lastActivity
        )
    }

    func reportMessageCenterStoreError(_ error: Error) {
        appendLine("\n" + LF("Message Center storage error: %@", Self.displayMessage(for: error)))
    }

    func configureMessageCenterPersistence(host: String, port: UInt16, login: String) {
        let scope = MessageCenterStoreScope(host: host, port: port, login: login)
        messageCenterPersistenceScope = scope
        do {
            let snapshot = try messageCenterStore.load(scope: scope)
            privateMessageConversations = Dictionary(uniqueKeysWithValues: snapshot.conversations.map {
                let restored = restoredConversation($0)
                return (restored.userID, restored)
            })
            offlineMessageCenterMessages = snapshot.offlineMessages.map {
                LegacyOfflineMessage(id: $0.id, sentAtUnix: $0.sentAtUnix,
                                     senderLogin: $0.senderLogin, senderNickname: $0.senderNickname,
                                     message: $0.message)
            }
            offlineMessageCenterUnreadIDs = Set(snapshot.offlineMessages.lazy.filter(\.isUnread).map(\.id))
            offlineMessageCenterUnreadCount = offlineMessageCenterUnreadIDs.count
        } catch {
            privateMessageConversations = [:]
            offlineMessageCenterMessages = []
            offlineMessageCenterUnreadIDs = []
            offlineMessageCenterUnreadCount = 0
            reportMessageCenterStoreError(error)
        }
        refreshPrivateMessageCenter(scrollToBottom: false)
    }

    func persistPrivateConversation(_ userID: UInt32) {
        guard let scope = messageCenterPersistenceScope,
              let conversation = privateMessageConversations[userID] else { return }
        do {
            try messageCenterStore.saveConversation(storedConversation(conversation), scope: scope)
        } catch {
            reportMessageCenterStoreError(error)
        }
    }

    func persistPrivateMessage(_ entry: PrivateMessageEntry, conversation: PrivateMessageConversation) {
        guard let scope = messageCenterPersistenceScope else { return }
        let stored = MessageCenterStoredPrivateMessage(id: entry.id, userID: conversation.userID,
                                                       timestamp: entry.timestamp, outgoing: entry.outgoing,
                                                       message: entry.message, edited: entry.edited, editable: entry.editable)
        do {
            try messageCenterStore.insertPrivateMessage(stored, conversation: storedConversation(conversation), scope: scope)
        } catch {
            reportMessageCenterStoreError(error)
        }
    }

    func persistOfflineMessages(_ newMessages: [LegacyOfflineMessage], unread: Bool) {
        guard let scope = messageCenterPersistenceScope, !newMessages.isEmpty else { return }
        let stored = newMessages.map {
            MessageCenterStoredOfflineMessage(id: $0.id, sentAtUnix: $0.sentAtUnix,
                                              senderLogin: $0.senderLogin, senderNickname: $0.senderNickname,
                                              message: $0.message, isUnread: unread)
        }
        do {
            _ = try messageCenterStore.insertOfflineMessages(stored, scope: scope)
        } catch {
            reportMessageCenterStoreError(error)
        }
    }

    func markOfflineMessagesReadInStore() {
        guard let scope = messageCenterPersistenceScope else { return }
        do {
            try messageCenterStore.markAllOfflineMessagesRead(scope: scope)
        } catch {
            reportMessageCenterStoreError(error)
        }
    }

    @objc func sendOfflineMessage(_ sender: Any?) {
        guard client.isConnected else { return }
        userOfflineMessageButton.isEnabled = false
        client.requestOfflineMessageRecipients { [weak self] result in
            guard let self else { return }
            self.userOfflineMessageButton.isEnabled = self.client.isConnected
            switch result {
            case let .failure(error):
                self.showError(LF("Recipient list could not be loaded: %@", Self.displayMessage(for: error)))
            case let .success(allRecipients):
                let ownLogin = (self.activeAvatarIdentity?.login ?? self.loginField.stringValue)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let recipients = allRecipients.filter {
                    Self.macRomanString($0.login).compare(ownLogin,
                                                         options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
                }
                self.presentOfflineMessageComposer(recipients: recipients)
            }
        }
    }

    func presentOfflineMessageComposer(recipients: [LegacyOfflineMessageRecipient]) {
        guard let window = view.window else { return }
        guard !recipients.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L("No Offline Message Recipients")
            alert.informativeText = L("No other account on this server currently allows offline messages.")
            alert.addButton(withTitle: L("OK"))
            alert.beginSheetModal(for: window)
            return
        }

        let nicknameCounts = Dictionary(grouping: recipients, by: { Self.macRomanString($0.nickname).lowercased() }).mapValues(\.count)
        let entries = recipients.map { recipient -> (title: String, login: Data) in
            let login = Self.macRomanString(recipient.login)
            let nickname = Self.macRomanString(recipient.nickname).trimmingCharacters(in: .whitespacesAndNewlines)
            let base = nickname.isEmpty ? login : nickname
            let duplicate = nicknameCounts[nickname.lowercased(), default: 0] > 1
            let title = duplicate || base == login ? (base == login ? login : "\(base) (\(login))") : base
            return (title, recipient.login)
        }

        offlineMessageComposer?.close()
        let composer = OfflineMessageComposerWindowController(recipients: entries)
        composer.onSend = { [weak self] loginData, recipientName, messageText in
            guard let self else { return L("The connection is no longer available.") }
            let messageData: Data
            do {
                messageData = try CarrachoTextWire.encodeIfNotEmpty(
                    messageText,
                    maximumBytes: LegacyOfflineMessage.maximumMessageLength
                )
            } catch {
                return L("The message exceeds the 4096-byte limit after Unicode encoding.")
            }
            guard !messageData.isEmpty else { return L("Enter a message.") }

            self.client.sendOfflineCapableMessage(toLogin: loginData, message: messageData) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.appendLine("\n" + LF("Offline message sent/queued for %@.", recipientName))
                case let .failure(error):
                    self.showError(Self.displayMessage(for: error))
                }
            }
            return nil
        }
        composer.onFinish = { [weak self, weak composer] in
            guard let self else { return }
            if self.offlineMessageComposer === composer { self.offlineMessageComposer = nil }
        }
        offlineMessageComposer = composer
        composer.beginSheet(for: window)
    }

    func offlineMessageSmokePath() -> String? {
        if let path = offlineMessageSmokeDumpPath { return path }
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--offline-message-smoke-dump=") }) else { return nil }
        let path = String(argument.dropFirst("--offline-message-smoke-dump=".count))
        guard !path.isEmpty else { return nil }
        offlineMessageSmokeDumpPath = path
        return path
    }

    func writeOfflineMessageSmokeSnapshot(messages: [LegacyOfflineMessage]) {
        guard let path = offlineMessageSmokePath() else { return }
        let object: [String: Any] = [
            "noticePresented": offlineMessageSmokeNoticeCount > 0,
            "noticeCount": offlineMessageSmokeNoticeCount,
            "messageWindowPresented": false,
            "messageCenterImported": true,
            "messageCount": messages.count,
            "senderLogins": messages.map { Self.macRomanString($0.senderLogin) },
            "senderNicknames": messages.map { Self.macRomanString($0.senderNickname) },
            "messages": messages.map { Self.macRomanString($0.message) },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func presentOfflineMessageNotice(count: Int) {
        guard count > 0 else { return }
        offlineMessageSmokeNoticeCount = max(offlineMessageSmokeNoticeCount, count)
        loadOfflineMessagesIntoMessageCenter(expectedCount: count)
        presentOfflineMessageLoginAlertIfNeeded(count: max(count, offlineMessageCenterUnreadCount))
    }

    func presentOfflineMessageLoginAlertIfNeeded(count: Int) {
        guard count > 0, !offlineMessageLoginNoticePresented else { return }
        guard let window = view.window else {
            appendLine("\n" + (count == 1 ? LF("%@ unread offline message is waiting in Message Center.", String(count)) : LF("%@ unread offline messages are waiting in Message Center.", String(count))))
            return
        }
        offlineMessageLoginNoticePresented = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = count == 1 ? L("Unread Offline Message") : L("Unread Offline Messages")
        alert.informativeText = count == 1
            ? L("You have 1 unread offline message waiting in Message Center.")
            : LF("You have %@ unread offline messages waiting in Message Center.", String(count))
        alert.addButton(withTitle: L("Open Message Center"))
        alert.addButton(withTitle: L("Later"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.selectWorkspace(.messageCenter)
            self.selectOfflineMessageCategory()
        }

        if offlineMessageSmokePath() != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak alert] in
                alert?.buttons.dropFirst().first?.performClick(nil)
            }
        }
    }

    func loadOfflineMessagesIntoMessageCenter(expectedCount: Int? = nil) {
        guard client.isConnected, !offlineMessageFetchInFlight else { return }
        offlineMessageFetchInFlight = true
        client.requestOfflineMessages { [weak self] result in
            guard let self else { return }
            self.offlineMessageFetchInFlight = false
            switch result {
            case let .failure(error):
                self.appendLine("\n" + LF("Offline messages could not be loaded into Message Center: %@", Self.displayMessage(for: error)))
            case let .success(messages):
                guard !messages.isEmpty else {
                    if let expectedCount, expectedCount > 0 {
                        self.appendLine("\n" + LF("The server announced %@ offline message(s), but none remained to load.", String(expectedCount)))
                    }
                    self.refreshPrivateMessageCenter(scrollToBottom: false)
                    return
                }
                self.importOfflineMessagesIntoMessageCenter(messages)
                if self.offlineMessageSmokePath() != nil {
                    self.didRunOfflineMessageSmoke = true
                    self.writeOfflineMessageSmokeSnapshot(messages: messages)
                }
                self.client.acknowledgeOfflineMessages(ids: messages.map(\.id)) { [weak self] result in
                    if case let .failure(error) = result {
                        self?.appendLine("\n" + LF("Offline messages are visible in Message Center, but the server could not mark them received: %@", Self.displayMessage(for: error)))
                    }
                }
            }
        }
    }

    func importOfflineMessagesIntoMessageCenter(_ messages: [LegacyOfflineMessage]) {
        let existingIDs = Set(offlineMessageCenterMessages.map(\.id))
        let newMessages = messages.filter { !existingIDs.contains($0.id) }
        guard !newMessages.isEmpty else {
            refreshPrivateMessageCenter(scrollToBottom: selectedOfflineMessages)
            return
        }
        offlineMessageCenterMessages.append(contentsOf: newMessages)
        offlineMessageCenterMessages.sort {
            if $0.sentAtUnix != $1.sentAtUnix { return $0.sentAtUnix < $1.sentAtUnix }
            return $0.id < $1.id
        }
        let categoryVisible = currentWorkspace == .messageCenter && selectedOfflineMessages
        if !categoryVisible {
            offlineMessageCenterUnreadIDs.formUnion(newMessages.map(\.id))
        }
        offlineMessageCenterUnreadCount = offlineMessageCenterUnreadIDs.count
        persistOfflineMessages(newMessages, unread: !categoryVisible)
        refreshPrivateMessageCenter(scrollToBottom: selectedOfflineMessages)
    }

    func offlineMessageCategoryMatchesSearch(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if L("Offline Messages").range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
        return offlineMessageCenterMessages.contains { message in
            let nickname = Self.macRomanString(message.senderNickname)
            let login = Self.macRomanString(message.senderLogin)
            let body = CarrachoHTMLText.plainText(fromWire: message.message)
            return nickname.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || login.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || body.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    func offlineMessageCategoryCell() -> NSView {
        let avatar = NSImageView()
        avatar.image = sizedAssetImage(named: "Inbox", size: 30)
        avatar.imageScaling = .scaleNone
        avatar.contentTintColor = nil
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 36),
            avatar.heightAnchor.constraint(equalToConstant: 36),
        ])

        let name = NSTextField(labelWithString: L("Offline Messages"))
        name.font = .systemFont(ofSize: messageCenterFontSize, weight: offlineMessageCenterUnreadCount > 0 ? .semibold : .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let count = NSTextField(labelWithString: "\(offlineMessageCenterMessages.count)")
        count.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        count.textColor = CarrachoTheme.tertiaryText
        count.setContentHuggingPriority(.required, for: .horizontal)
        let titleRow = horizontalStack([name, NSView(), count], spacing: 6)

        let previewText: String
        if let last = offlineMessageCenterMessages.last {
            let nickname = Self.macRomanString(last.senderNickname).trimmingCharacters(in: .whitespacesAndNewlines)
            let login = Self.macRomanString(last.senderLogin).trimmingCharacters(in: .whitespacesAndNewlines)
            let sender = nickname.isEmpty ? login : nickname
            let body = CarrachoHTMLText.plainText(fromWire: last.message, expandLegacyEmoticons: true).replacingOccurrences(of: "\n", with: " ")
            previewText = sender.isEmpty ? body : "\(sender): \(body)"
        } else {
            previewText = L("Messages received while you were offline")
        }
        let preview = NSTextField(labelWithString: previewText)
        preview.font = .systemFont(ofSize: max(10, messageCenterFontSize - 2))
        preview.textColor = CarrachoTheme.secondaryText
        preview.lineBreakMode = .byTruncatingTail
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var lowerViews: [NSView] = [preview, NSView()]
        if offlineMessageCenterUnreadCount > 0 { lowerViews.append(newsBadgeLabel(offlineMessageCenterUnreadCount)) }
        let lowerRow = horizontalStack(lowerViews, spacing: 6)
        let labels = verticalStack([titleRow, lowerRow], spacing: 3)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = horizontalStack([avatar, labels], spacing: 9)
        row.setAccessibilityLabel(LF("Offline Messages, %@ unread", String(offlineMessageCenterUnreadCount)))
        return row
    }

    func messageCenterTextLabel(_ attributed: NSAttributedString) -> NSTextField {
        let body = NSTextField(wrappingLabelWithString: "")
        body.attributedStringValue = attributed
        body.font = .systemFont(ofSize: messageCenterFontSize)
        body.maximumNumberOfLines = 0
        body.isEditable = false
        body.isSelectable = true
        body.allowsEditingTextAttributes = true
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return body
    }

    func messageCenterBodyLabel(fromWire data: Data) -> NSTextField {
        messageCenterTextLabel(CarrachoHTMLText.attributedString(
            fromWire: data,
            baseFont: .systemFont(ofSize: messageCenterFontSize),
            expandLegacyEmoticons: true
        ))
    }

    func messageCenterBodyView(fromWire data: Data, allowMedia: Bool = true) -> NSView {
        guard allowMedia else { return messageCenterBodyLabel(fromWire: data) }
        let source = CarrachoTextWire.string(from: data)
        let segments = LegacyMediaReference.segments(in: source)
        guard segments.contains(where: {
            switch $0 {
            case .image, .youtube: return true
            case .text: return false
            }
        }) else {
            return messageCenterBodyLabel(fromWire: data)
        }

        var views: [NSView] = []
        for segment in segments {
            switch segment {
            case let .text(text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                views.append(messageCenterTextLabel(CarrachoHTMLText.attributedString(
                    from: text,
                    baseFont: .systemFont(ofSize: messageCenterFontSize),
                    expandLegacyEmoticons: true
                )))
            case let .image(id):
                if hiddenMediaIDs.contains(id) { continue }
                if let image = mediaCache?.image(id: id) {
                    let availableWidth = privateMessageTranscriptScroll?.contentView.bounds.width ?? 640
                    let maximumWidth = max(160, min(520, availableWidth * 0.62))
                    let maximumHeight: CGFloat = 280
                    let rawWidth = max(1, image.size.width)
                    let rawHeight = max(1, image.size.height)
                    let scale = min(1, maximumWidth / rawWidth, maximumHeight / rawHeight)
                    let button = NSButton(image: image, target: self, action: #selector(openMessageCenterImage(_:)))
                    button.identifier = NSUserInterfaceItemIdentifier(id.uuidString.lowercased())
                    button.imagePosition = .imageOnly
                    button.imageScaling = .scaleProportionallyUpOrDown
                    button.isBordered = false
                    button.focusRingType = .none
                    button.toolTip = L("Open image preview")
                    button.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        button.widthAnchor.constraint(equalToConstant: max(1, floor(rawWidth * scale))),
                        button.heightAnchor.constraint(equalToConstant: max(1, floor(rawHeight * scale))),
                    ])
                    views.append(button)
                } else {
                    let failed = mediaDownloadFailures.contains(id)
                    let placeholder = NSTextField(labelWithString: failed ? L("[Image unavailable]") : L("[Loading image…]"))
                    placeholder.font = .systemFont(ofSize: max(10, messageCenterFontSize - 1))
                    placeholder.textColor = CarrachoTheme.secondaryText
                    views.append(placeholder)
                    requestMediaIfNeeded(id: id, context: .privateMessage) { [weak self] in
                        self?.refreshPrivateMessageCenter(scrollToBottom: false)
                    }
                }
            case let .youtube(reference):
                views.append(messageCenterTextLabel(CarrachoHTMLText.addingDetectedLinks(to:
                    NSAttributedString(
                        string: reference.canonicalURLString,
                        attributes: [.font: NSFont.systemFont(ofSize: messageCenterFontSize)]
                    )
                )))
            }
        }

        if views.isEmpty { return messageCenterBodyLabel(fromWire: data) }
        return views.count == 1 ? views[0] : verticalStack(views, spacing: 6)
    }

    @objc func openMessageCenterImage(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let id = UUID(uuidString: raw) else { return }
        showMediaPreview(id)
    }

    func messageCenterPreviewText(fromWire data: Data, allowMedia: Bool = true) -> String {
        if !allowMedia {
            return CarrachoHTMLText.plainText(fromWire: data, expandLegacyEmoticons: true)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let source = CarrachoTextWire.string(from: data)
        return LegacyMediaReference.segments(in: source).map { segment in
            switch segment {
            case let .text(text):
                return CarrachoHTMLText.attributedString(
                    from: text,
                    baseFont: .systemFont(ofSize: messageCenterFontSize),
                    expandLegacyEmoticons: true
                ).string
            case .image:
                return L("[Image]")
            case let .youtube(reference):
                return reference.canonicalURLString
            }
        }.joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func offlineMessageTranscriptCard(_ message: LegacyOfflineMessage) -> NSView {
        let card = CarrachoCardView()
        card.cornerRadius = 7
        card.fillColor = CarrachoTheme.elevatedCard

        let nickname = Self.macRomanString(message.senderNickname).trimmingCharacters(in: .whitespacesAndNewlines)
        let login = Self.macRomanString(message.senderLogin).trimmingCharacters(in: .whitespacesAndNewlines)
        let senderTitle: String
        if nickname.isEmpty { senderTitle = login.isEmpty ? L("Unknown sender") : login }
        else if login.isEmpty || nickname.compare(login, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { senderTitle = nickname }
        else { senderTitle = "\(nickname) (\(login))" }

        let sender = NSTextField(labelWithString: senderTitle)
        sender.font = .systemFont(ofSize: max(10.5, messageCenterFontSize - 1), weight: .semibold)
        let time = NSTextField(labelWithString: DateFormatter.localizedString(
            from: Date(timeIntervalSince1970: TimeInterval(message.sentAtUnix)), dateStyle: .medium, timeStyle: .short
        ))
        time.font = .systemFont(ofSize: 9.5)
        time.textColor = CarrachoTheme.tertiaryText
        time.setContentHuggingPriority(.required, for: .horizontal)
        let deleteButton = NSButton(title: "", target: self, action: #selector(deleteOfflineMessage(_:)))
        deleteButton.image = symbolImage("trash", fallback: NSImage.trashEmptyName)
        deleteButton.imagePosition = .imageOnly
        deleteButton.isBordered = false
        deleteButton.bezelStyle = .inline
        deleteButton.contentTintColor = CarrachoTheme.secondaryText
        deleteButton.identifier = NSUserInterfaceItemIdentifier(message.id)
        deleteButton.toolTip = L("Delete this offline message from local storage")
        deleteButton.setAccessibilityLabel(L("Delete offline message"))
        deleteButton.setContentHuggingPriority(.required, for: .horizontal)
        let header = horizontalStack([sender, NSView(), time, deleteButton], spacing: 8)

        let body = messageCenterBodyLabel(fromWire: message.message)
        let offlineLabel = NSTextField(labelWithString: L("Offline Message"))
        offlineLabel.font = .systemFont(ofSize: 9.5, weight: .medium)
        offlineLabel.textColor = CarrachoTheme.secondaryText
        let stack = verticalStack([header, body, offlineLabel], spacing: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        return card
    }

    @objc func deleteOfflineMessage(_ sender: NSButton) {
        guard let messageID = sender.identifier?.rawValue, !messageID.isEmpty else { return }
        offlineMessageCenterMessages.removeAll { $0.id == messageID }
        offlineMessageCenterUnreadIDs.remove(messageID)
        offlineMessageCenterUnreadCount = offlineMessageCenterUnreadIDs.count
        if let scope = messageCenterPersistenceScope {
            do { try messageCenterStore.deleteOfflineMessage(id: messageID, scope: scope) }
            catch { reportMessageCenterStoreError(error) }
        }
        refreshPrivateMessageCenter(scrollToBottom: false)
    }

    func privateMessageAvatarImage(for conversation: PrivateMessageConversation) -> NSImage? {
        if let live = liveUsers[conversation.userID] {
            return AvatarArtwork.userImage(picture: live.picture,
                                           isLegacyTransport: live.isLegacyTransport)
        }
        return AvatarArtwork.userImage(picture: conversation.picture,
                                       isLegacyTransport: conversation.isLegacyTransport)
    }

    func updatePrivateConversationMetadata(_ userID: UInt32) {
        guard var conversation = privateMessageConversations[userID], let user = liveUsers[userID] else { return }
        let oldNickname = conversation.nickname
        let oldPicture = conversation.picture
        let oldLegacy = conversation.isLegacyTransport
        let nickname = Self.macRomanString(user.nickname).trimmingCharacters(in: .whitespacesAndNewlines)
        if !nickname.isEmpty { conversation.nickname = nickname }
        conversation.picture = user.picture
        conversation.isLegacyTransport = user.isLegacyTransport
        privateMessageConversations[userID] = conversation
        if oldNickname != conversation.nickname || oldPicture != conversation.picture || oldLegacy != conversation.isLegacyTransport {
            persistPrivateConversation(userID)
        }
    }

    @discardableResult
    func ensurePrivateConversation(userID: UInt32) -> PrivateMessageConversation {
        if privateMessageConversations[userID] == nil {
            let user = liveUsers[userID]
            let nickname = user.map { Self.macRomanString($0.nickname).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            privateMessageConversations[userID] = PrivateMessageConversation(
                userID: userID,
                nickname: nickname.isEmpty ? LF("User %@", String(userID)) : nickname,
                picture: user?.picture ?? Data(),
                isLegacyTransport: user?.isLegacyTransport ?? false,
                entries: [], unreadCount: 0, draftText: "", lastActivity: Date()
            )
            persistPrivateConversation(userID)
        } else {
            updatePrivateConversationMetadata(userID)
        }
        return privateMessageConversations[userID]!
    }

    func appendPrivateMessage(userID: UInt32, message: Data, outgoing: Bool, timestamp: Date = Date(),
                              id: UUID = UUID(), editable: Bool = false) {
        var conversation = ensurePrivateConversation(userID: userID)
        let entry = PrivateMessageEntry(id: id, timestamp: timestamp, outgoing: outgoing, message: message,
                                        editable: editable)
        conversation.entries.append(entry)
        if conversation.entries.count > 500 { conversation.entries.removeFirst(conversation.entries.count - 500) }
        conversation.lastActivity = timestamp
        if !outgoing {
            let visibleAndSelected = currentWorkspace == .messageCenter && selectedPrivateConversationID == userID
            if visibleAndSelected { conversation.unreadCount = 0 }
            else { conversation.unreadCount = min(999, conversation.unreadCount + 1) }
        }
        privateMessageConversations[userID] = conversation
        persistPrivateMessage(entry, conversation: conversation)
        refreshPrivateMessageCenter(scrollToBottom: selectedPrivateConversationID == userID)
        if outgoing && editable {
            let remaining = entry.timestamp.addingTimeInterval(LegacyMessageEdit.maximumAge).timeIntervalSinceNow
            if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 0.1) { [weak self] in
                    guard let self, self.selectedPrivateConversationID == userID else { return }
                    self.refreshPrivateMessageCenter(scrollToBottom: false)
                }
            }
        }
    }

    func applyPrivateMessageEdit(_ edit: LegacyMessageEdited) {
        guard var conversation = privateMessageConversations[edit.scope],
              let index = conversation.entries.firstIndex(where: { $0.id == edit.id }) else { return }
        conversation.entries[index].message = edit.message
        conversation.entries[index].edited = true
        let changed = conversation.entries[index]
        privateMessageConversations[edit.scope] = conversation
        persistPrivateMessage(changed, conversation: conversation)
        refreshPrivateMessageCenter(scrollToBottom: false)
    }

    @objc func editPrivateMessageFromButton(_ sender: NSButton) {
        guard let parts = sender.identifier?.rawValue.split(separator: ":"), parts.count == 2,
              let userID = UInt32(parts[0]), let messageID = UUID(uuidString: String(parts[1])),
              let conversation = privateMessageConversations[userID], !conversation.isLegacyTransport,
              let entry = conversation.entries.first(where: { $0.id == messageID && $0.outgoing && $0.editable }),
              client.supportsMessageEditing,
              Date().timeIntervalSince(entry.timestamp) >= 0,
              Date().timeIntervalSince(entry.timestamp) < LegacyMessageEdit.maximumAge,
              LegacyMediaReference.references(inWire: entry.message).isEmpty else { return }
        presentMessageEdit(original: entry.message, maximumBytes: 0x8000, id: messageID)
    }

    func presentMessageEdit(original: Data, maximumBytes: Int, id: UUID) {
        let alert = NSAlert()
        alert.messageText = L("Edit message")
        alert.informativeText = L("You can edit your own message for five minutes after sending it.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 410, height: 108))
        editor.font = NSFont.systemFont(ofSize: 13)
        editor.isRichText = false
        editor.string = CarrachoTextWire.string(from: original)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 410, height: 108))
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        alert.accessoryView = scroll
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { showError(L("A message cannot be empty.")); return }
        do {
            let data = try CarrachoTextWire.encode(text, maximumBytes: maximumBytes)
            guard LegacyMediaReference.references(inWire: data).isEmpty else {
                showError(L("Image attachments cannot be changed when editing a message.")); return
            }
            client.editMessage(id: id, message: data) { [weak self] result in
                if case let .failure(error) = result {
                    self?.showError(LF("Message could not be edited: %@", Self.displayMessage(for: error)))
                }
            }
        } catch {
            showError(LF("Message could not be edited: %@", Self.displayMessage(for: error)))
        }
    }

    func selectPrivateConversation(_ userID: UInt32, focusComposer: Bool) {
        _ = ensurePrivateConversation(userID: userID)
        selectedOfflineMessages = false
        if let previousID = selectedPrivateConversationID, previousID != userID,
           var previous = privateMessageConversations[previousID] {
            previous.draftText = privateMessageComposer.string
            privateMessageConversations[previousID] = previous
            persistPrivateConversation(previousID)
        }
        if selectedPrivateConversationID != userID {
            privateMessageAttachments.imageIDs.forEach(deletePendingMedia)
            privateMessageAttachments.clear()
        }
        selectedPrivateConversationID = userID
        if var conversation = privateMessageConversations[userID] {
            conversation.unreadCount = 0
            privateMessageConversations[userID] = conversation
            persistPrivateConversation(userID)
            privateMessageComposer.string = conversation.draftText
        }
        refreshPrivateMessageCenter(scrollToBottom: true)
        if focusComposer { view.window?.makeFirstResponder(privateMessageComposer) }
    }

    func selectOfflineMessageCategory() {
        if let previousID = selectedPrivateConversationID, var previous = privateMessageConversations[previousID] {
            previous.draftText = privateMessageComposer.string
            privateMessageConversations[previousID] = previous
            persistPrivateConversation(previousID)
        }
        privateMessageAttachments.imageIDs.forEach(deletePendingMedia)
        privateMessageAttachments.clear()
        selectedPrivateConversationID = nil
        selectedOfflineMessages = true
        offlineMessageCenterUnreadIDs.removeAll()
        offlineMessageCenterUnreadCount = 0
        markOfflineMessagesReadInStore()
        privateMessageComposer.string = ""
        refreshPrivateMessageCenter(scrollToBottom: true)
    }

    func privateMessageConversationCell(_ conversation: PrivateMessageConversation) -> NSView {
        let avatar = NSImageView()
        avatar.image = privateMessageAvatarImage(for: conversation)
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = conversation.isLegacyTransport ? 0 : 18
        avatar.layer?.masksToBounds = !conversation.isLegacyTransport
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 36),
            avatar.heightAnchor.constraint(equalToConstant: 36),
        ])

        let name = NSTextField(labelWithString: conversation.nickname)
        name.font = .systemFont(ofSize: messageCenterFontSize, weight: conversation.unreadCount > 0 ? .semibold : .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let time = NSTextField(labelWithString: DateFormatter.localizedString(from: conversation.lastActivity, dateStyle: .none, timeStyle: .short))
        time.font = .systemFont(ofSize: 9.5)
        time.textColor = CarrachoTheme.tertiaryText
        time.setContentHuggingPriority(.required, for: .horizontal)
        let titleRow = horizontalStack([name, NSView(), time], spacing: 6)

        let previewText: String
        if let last = conversation.entries.last {
            let plain = messageCenterPreviewText(fromWire: last.message, allowMedia: !conversation.isLegacyTransport)
            previewText = (last.outgoing ? L("You: ") : "") + plain
        } else {
            previewText = conversation.isLegacyTransport ? L("Classic client · one PM per message") : L("No messages yet")
        }
        let preview = NSTextField(labelWithString: previewText)
        preview.font = .systemFont(ofSize: max(10, messageCenterFontSize - 2))
        preview.textColor = CarrachoTheme.secondaryText
        preview.lineBreakMode = .byTruncatingTail
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var lowerViews: [NSView] = [preview, NSView()]
        if conversation.unreadCount > 0 { lowerViews.append(newsBadgeLabel(conversation.unreadCount)) }
        let lowerRow = horizontalStack(lowerViews, spacing: 6)
        let labels = verticalStack([titleRow, lowerRow], spacing: 3)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = horizontalStack([avatar, labels], spacing: 9)
        row.setAccessibilityLabel(LF("Conversation with %@, %@ unread", conversation.nickname, String(conversation.unreadCount)))
        return row
    }

    func leftAlignedMessageTranscriptRow(_ card: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            card.topAnchor.constraint(equalTo: row.topAnchor),
            card.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            card.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.72),
        ])
        return row
    }

    func privateMessageTranscriptCard(_ entry: PrivateMessageEntry,
                                              conversation: PrivateMessageConversation) -> NSView {
        let card = CarrachoCardView()
        card.cornerRadius = 7
        card.fillColor = entry.outgoing ? CarrachoTheme.selection.withAlphaComponent(0.12) : CarrachoTheme.elevatedCard

        let sender = NSTextField(labelWithString: entry.outgoing ? L("You") : conversation.nickname)
        sender.font = .systemFont(ofSize: max(10.5, messageCenterFontSize - 1), weight: .semibold)
        sender.textColor = entry.outgoing ? CarrachoTheme.selection : .labelColor
        let time = NSTextField(labelWithString: DateFormatter.localizedString(from: entry.timestamp, dateStyle: .medium, timeStyle: .short))
        time.font = .systemFont(ofSize: 9.5)
        time.textColor = CarrachoTheme.tertiaryText
        time.setContentHuggingPriority(.required, for: .horizontal)
        var headerViews: [NSView] = [sender, NSView(), time]
        if entry.edited {
            let badge = NSTextField(labelWithString: L("Edited"))
            badge.font = .systemFont(ofSize: 9.5)
            badge.textColor = CarrachoTheme.tertiaryText
            headerViews.append(badge)
        }
        if entry.outgoing, entry.editable, !conversation.isLegacyTransport, client.supportsMessageEditing,
           Date().timeIntervalSince(entry.timestamp) >= 0,
           Date().timeIntervalSince(entry.timestamp) < LegacyMessageEdit.maximumAge,
           LegacyMediaReference.references(inWire: entry.message).isEmpty {
            let edit = NSButton(title: L("Edit"), target: self, action: #selector(editPrivateMessageFromButton(_:)))
            edit.bezelStyle = .inline
            edit.controlSize = .small
            edit.font = .systemFont(ofSize: 10)
            edit.identifier = NSUserInterfaceItemIdentifier(String(conversation.userID) + ":" + entry.id.uuidString)
            headerViews.append(edit)
        }
        let header = horizontalStack(headerViews, spacing: 8)

        let body = messageCenterBodyView(fromWire: entry.message, allowMedia: !conversation.isLegacyTransport)
        let stack = verticalStack([header, body], spacing: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        return card
    }

    func applyMessageCenterFontSize() {
        privateMessageConversationTable.rowHeight = max(68, messageCenterFontSize * 2 + 22)
        privateMessageComposer.font = .systemFont(ofSize: messageCenterFontSize)
        privateMessageEmptyLabel.font = .systemFont(ofSize: messageCenterFontSize)
        refreshPrivateMessageCenter(scrollToBottom: false)
    }

    func renderPrivateMessageTranscript(scrollToBottom: Bool) {
        for view in privateMessageTranscriptStack.arrangedSubviews {
            privateMessageTranscriptStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if selectedOfflineMessages {
            if offlineMessageCenterMessages.isEmpty {
                privateMessageEmptyLabel.stringValue = L("No offline messages.")
                privateMessageEmptyLabel.isHidden = false
            } else {
                privateMessageEmptyLabel.isHidden = true
                for message in offlineMessageCenterMessages {
                    privateMessageTranscriptStack.addArrangedSubview(
                        leftAlignedMessageTranscriptRow(offlineMessageTranscriptCard(message))
                    )
                }
            }
        } else if let userID = selectedPrivateConversationID,
                  let conversation = privateMessageConversations[userID] {
            if conversation.entries.isEmpty {
                privateMessageEmptyLabel.stringValue = conversation.isLegacyTransport
                    ? L("This user is on a Classic client. Every message you send is delivered as a normal individual Private Message.")
                    : L("No messages yet. Write the first one below.")
                privateMessageEmptyLabel.isHidden = false
            } else {
                privateMessageEmptyLabel.isHidden = true
                for entry in conversation.entries {
                    privateMessageTranscriptStack.addArrangedSubview(
                        leftAlignedMessageTranscriptRow(privateMessageTranscriptCard(entry, conversation: conversation))
                    )
                }
            }
        } else {
            privateMessageEmptyLabel.stringValue = L("Choose a conversation or Offline Messages.")
            privateMessageEmptyLabel.isHidden = false
        }

        guard scrollToBottom, let scroll = privateMessageTranscriptScroll else { return }
        DispatchQueue.main.async {
            guard let document = scroll.documentView else { return }
            document.layoutSubtreeIfNeeded()
            let y = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func updateMessageCenterSidebarBadge() {
        guard let button = sidebarButtons[.messageCenter] else { return }
        let unread = privateMessageUnreadCount
        button.title = unread > 0 ? LF("Message Center  %@", String(unread)) : L("Message Center")
        button.toolTip = unread > 0 ? (unread == 1 ? LF("%@ unread message", String(unread)) : LF("%@ unread messages", String(unread))) : L("Private conversations and offline messages")
    }

    func refreshPrivateMessageCenter(scrollToBottom: Bool) {
        for userID in Array(privateMessageConversations.keys) { updatePrivateConversationMetadata(userID) }
        let rows = displayedMessageCenterRows
        isReloadingPrivateMessageTable = true
        privateMessageConversationTable.reloadData()

        var selectedRow: Int?
        if selectedOfflineMessages {
            selectedRow = rows.firstIndex { row in
                if case .offlineMessages = row { return true }
                return false
            }
        } else if let selectedID = selectedPrivateConversationID {
            selectedRow = rows.firstIndex { row in
                if case let .conversation(conversation) = row { return conversation.userID == selectedID }
                return false
            }
        }
        if let selectedRow {
            privateMessageConversationTable.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        } else {
            privateMessageConversationTable.deselectAll(nil)
        }
        isReloadingPrivateMessageTable = false

        updateMessageCenterSidebarBadge()
        privateMessageMarkReadButton.isEnabled = privateMessageUnreadCount > 0
        privateMessageNewButton.isEnabled = client.isConnected && !liveUsers.isEmpty

        if selectedOfflineMessages {
            privateMessageClearChatButton.isHidden = true
            privateMessageDeleteChatButton.isHidden = true
            privateMessageHeaderAvatar.image = sizedAssetImage(named: "Inbox", size: 30)
            privateMessageHeaderNameLabel.stringValue = L("Offline Messages")
            let count = offlineMessageCenterMessages.count
            privateMessageHeaderStatusLabel.stringValue = count == 1
                ? "1 message received while you were offline"
                : "\(count) messages received while you were offline"
            privateMessageHeaderStatusLabel.textColor = CarrachoTheme.secondaryText
            privateMessageComposerStatusLabel.stringValue = L("Stored messages received while you were offline")
            privateMessageComposerStatusLabel.textColor = CarrachoTheme.secondaryText
            privateMessageComposer.string = ""
            privateMessageComposer.isEditable = false
            privateMessageSendButton.isEnabled = false
            privateMessageEmojiButton.isEnabled = false
            renderPrivateMessageTranscript(scrollToBottom: scrollToBottom)
            return
        }

        guard let userID = selectedPrivateConversationID,
              let conversation = privateMessageConversations[userID] else {
            privateMessageClearChatButton.isHidden = true
            privateMessageDeleteChatButton.isHidden = true
            privateMessageHeaderAvatar.image = nil
            privateMessageHeaderNameLabel.stringValue = L("Select a conversation")
            privateMessageHeaderStatusLabel.stringValue = ""
            privateMessageComposerStatusLabel.stringValue = ""
            privateMessageComposer.isEditable = false
            privateMessageSendButton.isEnabled = false
            privateMessageEmojiButton.isEnabled = false
            renderPrivateMessageTranscript(scrollToBottom: false)
            return
        }

        privateMessageClearChatButton.isHidden = false
        privateMessageClearChatButton.isEnabled = !conversation.entries.isEmpty
        privateMessageDeleteChatButton.isHidden = false
        privateMessageDeleteChatButton.isEnabled = true
        privateMessageHeaderAvatar.image = privateMessageAvatarImage(for: conversation)
        privateMessageHeaderAvatar.layer?.cornerRadius = conversation.isLegacyTransport ? 0 : 18
        privateMessageHeaderAvatar.layer?.masksToBounds = !conversation.isLegacyTransport
        privateMessageHeaderNameLabel.stringValue = conversation.nickname
        let online = client.isConnected && liveUsers[userID] != nil
        var statusParts = [online ? L("Online") : L("Offline")]
        if conversation.isLegacyTransport { statusParts.append(L("Classic client")) }
        privateMessageHeaderStatusLabel.stringValue = statusParts.joined(separator: " · ")
        privateMessageHeaderStatusLabel.textColor = online ? CarrachoTheme.success : CarrachoTheme.secondaryText
        if conversation.isLegacyTransport {
            privateMessageComposerStatusLabel.stringValue = online
                ? LF("Message to %@ · delivered as an individual Classic Private Message", conversation.nickname)
                : LF("%@ is offline", conversation.nickname)
        } else {
            privateMessageComposerStatusLabel.stringValue = online ? LF("Message to %@", conversation.nickname) : LF("%@ is offline", conversation.nickname)
        }
        privateMessageComposer.isEditable = online
        privateMessageSendButton.isEnabled = online
        privateMessageEmojiButton.isEnabled = online
        renderPrivateMessageTranscript(scrollToBottom: scrollToBottom)
    }

    func openPrivateConversation(with user: LegacyUserListEntry, focusComposer: Bool = true) {
        _ = ensurePrivateConversation(userID: user.userID)
        selectWorkspace(.messageCenter)
        selectPrivateConversation(user.userID, focusComposer: focusComposer)
    }

    @objc func privateMessageSearchChanged(_ sender: NSSearchField) {
        privateMessageSearchQuery = sender.stringValue
        refreshPrivateMessageCenter(scrollToBottom: false)
    }

    @objc func markAllPrivateMessagesRead(_ sender: Any?) {
        for userID in privateMessageConversations.keys {
            privateMessageConversations[userID]?.unreadCount = 0
        }
        offlineMessageCenterUnreadIDs.removeAll()
        offlineMessageCenterUnreadCount = 0
        if let scope = messageCenterPersistenceScope {
            do {
                try messageCenterStore.markAllConversationsRead(scope: scope)
                try messageCenterStore.markAllOfflineMessagesRead(scope: scope)
            } catch {
                reportMessageCenterStoreError(error)
            }
        }
        refreshPrivateMessageCenter(scrollToBottom: false)
    }

    @objc func clearSelectedPrivateChat(_ sender: Any?) {
        guard let userID = selectedPrivateConversationID,
              let conversation = privateMessageConversations[userID],
              !conversation.entries.isEmpty, let window = view.window else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Clear Chat?")
        alert.informativeText = LF("Remove all messages from the chat with %@? The conversation itself stays available. This cannot be undone.", conversation.nickname)
        alert.addButton(withTitle: L("Clear Chat"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  var current = self.privateMessageConversations[userID] else { return }
            current.entries.removeAll()
            current.unreadCount = 0
            self.privateMessageConversations[userID] = current
            if let scope = self.messageCenterPersistenceScope {
                do {
                    try self.messageCenterStore.clearConversation(userID: userID, scope: scope)
                    try self.messageCenterStore.saveConversation(self.storedConversation(current), scope: scope)
                } catch {
                    self.reportMessageCenterStoreError(error)
                }
            }
            self.refreshPrivateMessageCenter(scrollToBottom: false)
        }
    }

    @objc func deleteSelectedPrivateChat(_ sender: Any?) {
        guard let userID = selectedPrivateConversationID,
              let conversation = privateMessageConversations[userID],
              let window = view.window else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Delete Chat?")
        alert.informativeText = LF("Delete the chat with %@ from Message Center? This removes the complete conversation and cannot be undone.", conversation.nickname)
        alert.addButton(withTitle: L("Delete Chat"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.privateMessageConversations.removeValue(forKey: userID)
            if let scope = self.messageCenterPersistenceScope {
                do { try self.messageCenterStore.deleteConversation(userID: userID, scope: scope) }
                catch { self.reportMessageCenterStoreError(error) }
            }
            if self.selectedPrivateConversationID == userID {
                self.selectedPrivateConversationID = nil
                self.privateMessageComposer.string = ""
            }
            self.refreshPrivateMessageCenter(scrollToBottom: false)
        }
    }

    @objc func showNewPrivateMessageMenu(_ sender: NSButton) {
        let menu = NSMenu(title: L("New Message"))
        let ownID = lastLoginResult?.session.userID
        let users = liveUsers.values.filter { $0.userID != ownID }.sorted {
            Self.macRomanString($0.nickname).localizedCaseInsensitiveCompare(Self.macRomanString($1.nickname)) == .orderedAscending
        }
        if users.isEmpty {
            let item = NSMenuItem(title: L("No other users online"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for user in users {
                let title = Self.macRomanString(user.nickname)
                let item = NSMenuItem(title: title.isEmpty ? LF("User %@", String(user.userID)) : title,
                                      action: #selector(newPrivateMessageRecipientSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: user.userID)
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc func newPrivateMessageRecipientSelected(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber,
              let user = liveUsers[number.uint32Value] else { return }
        openPrivateConversation(with: user)
    }

    @MainActor func uploadPrivateMessageImages(urls: [URL]) {
        guard let userID = selectedPrivateConversationID,
              let conversation = privateMessageConversations[userID],
              !conversation.isLegacyTransport,
              let mediaClient else {
            showError(L("Images in private messages require a modern Carracho peer."))
            return
        }
        let remaining = max(0, LegacyMediaTransfer.maximumImagesPerPrivateMessage - privateMessageAttachments.imageCount)
        let selected = Array(urls.prefix(remaining))
        guard !selected.isEmpty else { return }
        do {
            let prepared = try selected.map { try CarrachoMediaImageProcessor.prepare(url: $0) }
            privateMessageSendButton.isEnabled = false
            privateMessageComposerStatusLabel.stringValue = L("Uploading image…")
            uploadPreparedMedia(prepared, client: mediaClient) { [weak self, weak mediaClient] result in
                guard let self, self.mediaClient === mediaClient else { return }
                switch result {
                case let .success(ids):
                    self.addUploadedImages(ids: ids, prepared: prepared, to: self.privateMessageAttachments)
                    self.privateMessageComposerStatusLabel.stringValue = LF("Message to %@", conversation.nickname)
                case let .failure(error):
                    self.showError(LF("Image upload failed: %@", Self.displayMessage(for: error)))
                }
                self.privateMessageSendButton.isEnabled = self.client.isConnected && self.liveUsers[userID] != nil
            }
        } catch {
            showError(LF("Image could not be prepared: %@", Self.displayMessage(for: error)))
        }
    }

    @MainActor func uploadPrivateMessageImage(data: Data) {
        guard let userID = selectedPrivateConversationID,
              let conversation = privateMessageConversations[userID],
              !conversation.isLegacyTransport,
              let mediaClient else {
            showError(L("Images in private messages require a modern Carracho peer."))
            return
        }
        guard privateMessageAttachments.imageCount < LegacyMediaTransfer.maximumImagesPerPrivateMessage else {
            showError(LF("A private message can contain at most %@ images.",
                         String(LegacyMediaTransfer.maximumImagesPerPrivateMessage)))
            return
        }
        do {
            let prepared = try CarrachoMediaImageProcessor.prepare(data: data)
            privateMessageSendButton.isEnabled = false
            privateMessageComposerStatusLabel.stringValue = L("Uploading image…")
            uploadPreparedMedia([prepared], client: mediaClient) { [weak self, weak mediaClient] result in
                guard let self, self.mediaClient === mediaClient else { return }
                switch result {
                case let .success(ids):
                    self.addUploadedImages(ids: ids, prepared: [prepared], to: self.privateMessageAttachments)
                    self.privateMessageComposerStatusLabel.stringValue = LF("Message to %@", conversation.nickname)
                case let .failure(error):
                    self.showError(LF("Image upload failed: %@", Self.displayMessage(for: error)))
                }
                self.privateMessageSendButton.isEnabled = self.client.isConnected && self.liveUsers[userID] != nil
            }
        } catch {
            showError(LF("Clipboard image could not be prepared: %@", Self.displayMessage(for: error)))
        }
    }

    @objc func sendPrivateMessageFromCenter(_ sender: Any?) {
        guard let userID = selectedPrivateConversationID,
              liveUsers[userID] != nil, client.isConnected else {
            privateMessageComposerStatusLabel.stringValue = L("The recipient is offline.")
            privateMessageComposerStatusLabel.textColor = .systemRed
            return
        }
        let plainSource = privateMessageComposer.string
        let source = composedRichText(plainSource, attachments: privateMessageAttachments)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            privateMessageComposerStatusLabel.stringValue = L("Enter a message or add an attachment before sending.")
            privateMessageComposerStatusLabel.textColor = .systemRed
            return
        }
        let data: Data
        do {
            data = try CarrachoTextWire.encodeIfNotEmpty(source, maximumBytes: 0x8000)
        } catch {
            privateMessageComposerStatusLabel.stringValue = L("The message exceeds the protocol limit after encoding.")
            privateMessageComposerStatusLabel.textColor = .systemRed
            return
        }
        guard !data.isEmpty else { return }
        privateMessageSendButton.isEnabled = false
        let messageID = client.supportsMessageEditing &&
            privateMessageConversations[userID]?.isLegacyTransport == false &&
            LegacyMediaReference.references(inWire: data).isEmpty ? UUID() : nil
        client.sendPrivateMessage(to: userID, message: data, messageID: messageID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if var conversation = self.privateMessageConversations[userID] {
                    conversation.draftText = ""
                    self.privateMessageConversations[userID] = conversation
                }
                if self.selectedPrivateConversationID == userID, self.privateMessageComposer.string == plainSource {
                    self.privateMessageComposer.string = ""
                    self.privateMessageAttachments.clear()
                }
                self.privateMessageComposerStatusLabel.textColor = CarrachoTheme.secondaryText
                self.appendPrivateMessage(userID: userID, message: data, outgoing: true,
                                          id: messageID ?? UUID(), editable: messageID != nil)
            case let .failure(error):
                self.privateMessageComposerStatusLabel.stringValue = LF("Message could not be sent: %@", Self.displayMessage(for: error))
                self.privateMessageComposerStatusLabel.textColor = .systemRed
                self.privateMessageSendButton.isEnabled = self.liveUsers[userID] != nil && self.client.isConnected
            }
        }
    }
}
