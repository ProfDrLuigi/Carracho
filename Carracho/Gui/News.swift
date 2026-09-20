import Cocoa
import QuickLookUI

// MARK: - News

extension ViewController {

    func makeNewsClientPage() -> NSView {
        let page = CarrachoBackgroundView()
        page.fillColor = CarrachoTheme.conferenceTranscriptBackground

        let pageTitle = NSTextField(labelWithString: L("News"))
        pageTitle.font = .systemFont(ofSize: 22, weight: .bold)
        pageTitle.setContentHuggingPriority(.required, for: .horizontal)
        let pageIdentity = pageTitle

        let flatNews = NSButton(title: L("Classic News"), target: self, action: #selector(showFlatNewsManager(_:)))
        flatNews.controlSize = .regular
        flatNews.bezelStyle = .inline
        flatNews.font = .systemFont(ofSize: 13, weight: .medium)
        flatNews.image = sizedAssetImage(named: "Classic News", size: 18)
        flatNews.imagePosition = .imageTrailing
        flatNews.imageScaling = .scaleNone
        flatNews.contentTintColor = nil
        flatNews.heightAnchor.constraint(equalToConstant: 30).isActive = true
        flatNews.toolTip = L("Open the historical Flat News view")
        flatNews.setAccessibilityLabel(L("Open Classic Flat News"))
        newsFontSizePopup.controlSize = .regular
        newsFontSizePopup.font = .systemFont(ofSize: 13)
        newsPostButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let topBar = CarrachoBackgroundView()
        topBar.fillColor = CarrachoTheme.elevatedCard
        let topStack = horizontalStack([
            pageIdentity, NSView(), newsRefreshButton, newsFontSizePopup, flatNews, newsPostButton,
        ], spacing: 10)
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

        let categoriesPane = CarrachoBackgroundView()
        categoriesPane.fillColor = CarrachoTheme.conferenceTranscriptBackground
        let categoriesScroll = tableScroll(newsTable, tracksViewportWidth: true)
        categoriesScroll.drawsBackground = true
        categoriesScroll.backgroundColor = CarrachoTheme.conferenceTranscriptBackground
        newsTable.backgroundColor = CarrachoTheme.conferenceTranscriptBackground
        let categoryHeader = horizontalStack([
            newsCategoryHeaderLabel, NSView(), newsNewCategoryButton,
        ], spacing: 5)
        categoryHeader.translatesAutoresizingMaskIntoConstraints = false
        categoriesScroll.translatesAutoresizingMaskIntoConstraints = false
        categoriesPane.addSubview(categoryHeader)
        categoriesPane.addSubview(categoriesScroll)
        NSLayoutConstraint.activate([
            categoryHeader.leadingAnchor.constraint(equalTo: categoriesPane.leadingAnchor, constant: 12),
            categoryHeader.trailingAnchor.constraint(equalTo: categoriesPane.trailingAnchor, constant: -8),
            categoryHeader.topAnchor.constraint(equalTo: categoriesPane.topAnchor, constant: 9),
            categoriesScroll.leadingAnchor.constraint(equalTo: categoriesPane.leadingAnchor, constant: 5),
            categoriesScroll.trailingAnchor.constraint(equalTo: categoriesPane.trailingAnchor, constant: -5),
            categoriesScroll.topAnchor.constraint(equalTo: categoryHeader.bottomAnchor, constant: 5),
            categoriesScroll.bottomAnchor.constraint(equalTo: categoriesPane.bottomAnchor, constant: -5),
            categoriesScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 96),
        ])

        let topicsPane = CarrachoBackgroundView()
        topicsPane.fillColor = CarrachoTheme.conferenceTranscriptBackground
        let topicsScroll = tableScroll(newsArticleTable, tracksViewportWidth: true)
        topicsScroll.drawsBackground = true
        topicsScroll.backgroundColor = CarrachoTheme.conferenceTranscriptBackground
        newsArticleTable.backgroundColor = CarrachoTheme.conferenceTranscriptBackground
        topicsScroll.translatesAutoresizingMaskIntoConstraints = false
        topicsPane.addSubview(topicsScroll)
        NSLayoutConstraint.activate([
            topicsScroll.leadingAnchor.constraint(equalTo: topicsPane.leadingAnchor, constant: 5),
            topicsScroll.trailingAnchor.constraint(equalTo: topicsPane.trailingAnchor, constant: -5),
            topicsScroll.topAnchor.constraint(equalTo: topicsPane.topAnchor, constant: 5),
            topicsScroll.bottomAnchor.constraint(equalTo: topicsPane.bottomAnchor, constant: -5),
            // The topics pane now shares vertical space with the reader, so keep this compact
            // enough for smaller windows while the scroll view remains fully usable.
            topicsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])

        let conversationPane = CarrachoBackgroundView()
        conversationPane.fillColor = CarrachoTheme.conferenceTranscriptBackground
        let conversationHeader = NSView()
        let titleColumn = verticalStack([newsBreadcrumbLabel, newsTitleLabel, newsThreadMetaLabel], spacing: 4)
        // Let the topic identity consume the entire header width minus the compact actions button.
        // The old spacer caused NSStackView to keep this column near its intrinsic width, so a
        // perfectly short subject such as "Corvette ZR4" became "Cor..." with acres of room left.
        titleColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleColumn.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        newsTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        newsTitleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        newsThreadActionsButton.setContentHuggingPriority(.required, for: .horizontal)
        newsThreadActionsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let conversationHeaderStack = horizontalStack([titleColumn, newsThreadActionsButton], spacing: 10)
        conversationHeaderStack.distribution = .fill
        conversationHeaderStack.translatesAutoresizingMaskIntoConstraints = false
        conversationHeader.addSubview(conversationHeaderStack)
        let headerDivider = CarrachoDividerView()
        headerDivider.translatesAutoresizingMaskIntoConstraints = false
        conversationHeader.addSubview(headerDivider)
        NSLayoutConstraint.activate([
            conversationHeaderStack.leadingAnchor.constraint(equalTo: conversationHeader.leadingAnchor, constant: 18),
            conversationHeaderStack.trailingAnchor.constraint(equalTo: conversationHeader.trailingAnchor, constant: -12),
            conversationHeaderStack.topAnchor.constraint(equalTo: conversationHeader.topAnchor, constant: 14),
            conversationHeaderStack.bottomAnchor.constraint(equalTo: conversationHeader.bottomAnchor, constant: -13),
            headerDivider.leadingAnchor.constraint(equalTo: conversationHeader.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: conversationHeader.trailingAnchor),
            headerDivider.bottomAnchor.constraint(equalTo: conversationHeader.bottomAnchor),
            headerDivider.heightAnchor.constraint(equalToConstant: 1),
        ])

        let articleScroll = textScroll(newsArticleTextView, border: false)
        articleScroll.backgroundColor = CarrachoTheme.conferenceTranscriptBackground
        articleScroll.drawsBackground = true
        newsArticleTextView.backgroundColor = CarrachoTheme.conferenceTranscriptBackground

        let composer = CarrachoBackgroundView()
        composer.fillColor = CarrachoTheme.elevatedCard
        let composerDivider = CarrachoDividerView()
        composerDivider.translatesAutoresizingMaskIntoConstraints = false
        composer.addSubview(composerDivider)
        let replyCaption = NSTextField(labelWithString: L("Write a reply"))
        replyCaption.font = .systemFont(ofSize: 12.5, weight: .semibold)
        replyCaption.setContentHuggingPriority(.required, for: .horizontal)
        let targetRow = horizontalStack([
            replyCaption, newsReplyTargetLabel, newsReplyClearTargetButton, NSView(),
        ], spacing: 6)
        let replyScroll = textScroll(newsReplyTextView, border: true)
        replyScroll.heightAnchor.constraint(equalToConstant: 82).isActive = true
        let emoji = EmojiPickerButton(editor: newsReplyTextView)
        let composerButtons = horizontalStack([
            emoji, newsReplyAttachButton, newsReplyYouTubeButton, newsReplyValidationLabel,
            NSView(), newsReplySendingIndicator, newsReplyButton,
        ], spacing: 7)
        newsReplyValidationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let composerStack = verticalStack([
            targetRow, newsReplyAttachments, replyScroll, composerButtons,
        ], spacing: 7)
        composerStack.translatesAutoresizingMaskIntoConstraints = false
        composer.addSubview(composerStack)
        NSLayoutConstraint.activate([
            composerDivider.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            composerDivider.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            composerDivider.topAnchor.constraint(equalTo: composer.topAnchor),
            composerDivider.heightAnchor.constraint(equalToConstant: 1),
            composerStack.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 18),
            composerStack.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -18),
            composerStack.topAnchor.constraint(equalTo: composer.topAnchor, constant: 11),
            composerStack.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -12),
        ])

        for child in [conversationHeader, articleScroll, composer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            conversationPane.addSubview(child)
        }
        NSLayoutConstraint.activate([
            conversationHeader.leadingAnchor.constraint(equalTo: conversationPane.leadingAnchor),
            conversationHeader.trailingAnchor.constraint(equalTo: conversationPane.trailingAnchor),
            conversationHeader.topAnchor.constraint(equalTo: conversationPane.topAnchor),

            articleScroll.leadingAnchor.constraint(equalTo: conversationPane.leadingAnchor),
            articleScroll.trailingAnchor.constraint(equalTo: conversationPane.trailingAnchor),
            articleScroll.topAnchor.constraint(equalTo: conversationHeader.bottomAnchor),
            articleScroll.bottomAnchor.constraint(equalTo: composer.topAnchor),
            // The reader scrolls internally; a small hard minimum avoids Auto Layout fights
            // when the News detail split is compressed vertically.
            articleScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),

            composer.leadingAnchor.constraint(equalTo: conversationPane.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: conversationPane.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: conversationPane.bottomAnchor),
        ])

        // News uses a mail-style hierarchy: categories stay in the left column; the selected
        // category's topics are shown to its right; the reader/composer sits below those topics.
        // Keeping the two detail areas in their own vertical split preserves resize control
        // without forcing the category list to share vertical space with the topic list.
        let detailSplit = makeResizableVerticalSplit(
            panes: [topicsPane, conversationPane],
            autosaveName: "Carracho.NewsDetailRows.v2",
            initialFractions: [0.28, 0.72],
            minimumPaneHeights: [110, 260]
        )

        let contentSplit = makeResizableColumnSplit(
            panes: [categoriesPane, detailSplit],
            autosaveName: "Carracho.NewsColumns",
            edge: .leading,
            initialEdgeWidth: 300,
            minimumPaneWidths: [230, 520]
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
        return page
    }

    func applyNewsFontSize() {
        newsTable.rowHeight = max(42, newsFontSize + 29)
        // Topic rows are single-line table records, not cards. Keep them compact so the list
        // behaves like the classic client instead of burning vertical space between subjects.
        newsArticleTable.rowHeight = max(26, newsFontSize + 12)
        newsArticleTextView.font = .systemFont(ofSize: newsFontSize)
        newsReplyTextView.font = .systemFont(ofSize: newsFontSize)
        reloadNewsView()
    }

    @objc func menuNews(_ sender: Any?) { selectWorkspace(.news) }

    @objc func showNews(_ sender: Any?) { selectWorkspace(.news) }

    func stopBackgroundNewsPolling(for context: BookmarkConnectionContext) {
        context.backgroundNewsTimer?.invalidate()
        context.backgroundNewsTimer = nil
        context.backgroundNewsRefreshInFlight = false
    }

    func startBackgroundNewsPolling(for context: BookmarkConnectionContext) {
        stopBackgroundNewsPolling(for: context)
        guard context.client.isConnected, context.backgroundNewsSupported,
              let snapshot = context.snapshot else { return }
        context.backgroundNewsKnownGroups = Set(snapshot.lastNewsgroups)
        context.backgroundNewsTotals = snapshot.newsThreadsByCategory.mapValues(newsThreadTotals)
        context.newsNotificationCount = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self, weak context] _ in
            guard let self, let context else { return }
            self.pollBackgroundNews(for: context)
        }
        context.backgroundNewsTimer = timer
    }

    func pollBackgroundNews(for context: BookmarkConnectionContext) {
        guard activeBookmarkConnectionID != context.bookmarkID,
              context.client.isConnected, context.backgroundNewsSupported,
              !context.backgroundNewsRefreshInFlight else { return }
        context.backgroundNewsRefreshInFlight = true
        context.client.requestNewsgroups { [weak self, weak context] result in
            guard let self, let context else { return }
            guard self.activeBookmarkConnectionID != context.bookmarkID, context.client.isConnected else {
                context.backgroundNewsRefreshInFlight = false
                return
            }
            switch result {
            case let .success(groups):
                let previouslyKnown = context.backgroundNewsKnownGroups
                context.snapshot?.lastNewsgroups = groups
                self.pollBackgroundNewsGroups(for: context, groups: groups, index: 0,
                                              previouslyKnown: previouslyKnown)
            case .failure:
                context.backgroundNewsRefreshInFlight = false
            }
        }
    }

    func pollBackgroundNewsGroups(for context: BookmarkConnectionContext, groups: [Data], index: Int,
                                          previouslyKnown: Set<Data>) {
        guard activeBookmarkConnectionID != context.bookmarkID, context.client.isConnected else {
            context.backgroundNewsRefreshInFlight = false
            return
        }
        guard index < groups.count else {
            context.backgroundNewsKnownGroups = Set(groups)
            context.backgroundNewsRefreshInFlight = false
            reloadBookmarkStack()
            return
        }
        let group = groups[index]
        context.client.requestNewsThreads(group: group) { [weak self, weak context] result in
            guard let self, let context else { return }
            guard self.activeBookmarkConnectionID != context.bookmarkID, context.client.isConnected else {
                context.backgroundNewsRefreshInFlight = false
                return
            }
            switch result {
            case let .success(threads):
                let totals = self.newsThreadTotals(threads)
                var newPosts = 0
                if let oldTotals = context.backgroundNewsTotals[group] {
                    for (threadID, total) in totals {
                        let old = oldTotals[threadID] ?? 0
                        if total > old { newPosts += Int(total - old) }
                    }
                } else if !previouslyKnown.contains(group) {
                    newPosts = totals.values.reduce(0) { partial, total in
                        min(999, partial + Int(total))
                    }
                }
                if newPosts > 0 {
                    context.newsNotificationCount = min(999, context.newsNotificationCount + newPosts)
                }
                context.backgroundNewsTotals[group] = totals
                context.snapshot?.newsThreadsByCategory[group] = threads
                self.pollBackgroundNewsGroups(for: context, groups: groups, index: index + 1,
                                              previouslyKnown: previouslyKnown)
            case .failure:
                // Old Classic servers have no threaded-news query. Push events such as
                // flat News still contribute to the bookmark badge; just stop this poll.
                context.backgroundNewsSupported = false
                context.backgroundNewsRefreshInFlight = false
                self.stopBackgroundNewsPolling(for: context)
            }
        }
    }

    func loadInitialNewsgroups(completion: (() -> Void)?) {
        client.requestNewsgroups { [weak self] newsResult in
            guard let self else { return }
            switch newsResult {
            case let .success(groups):
                self.lastNewsgroups = groups
                self.renderSession()
                if self.newsTable.selectedRow < 0, let first = self.displayedNewsgroups.first,
                   let row = self.displayedNewsgroups.firstIndex(of: first) {
                    self.newsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    self.reloadNewsView()
                }
                self.startNewsBadgePolling()
            case let .failure(error):
                self.appendLine("\n" + LF("News category list could not be loaded: %@", Self.displayMessage(for: error)))
            }
            self.writeUISmokeSnapshotIfRequested()
            self.runUserInfoSmokeIfRequested()
            self.runChatSmokeIfRequested()
            completion?()
        }
    }

    func newsReplyDraftKey(group: Data, threadID: UInt32) -> String {
        let scope = newsReadScope ?? "session"
        return "\(scope)|\(group.base64EncodedString())|\(threadID)"
    }

    func saveInlineNewsReplyDraft() {
        guard let key = newsReplyContextKey else { return }
        let text = newsReplyTextView.string
        let tokens = newsReplyAttachments.tokens
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           tokens.isEmpty, newsReplyTargetArticleID == nil {
            newsReplyDrafts.removeValue(forKey: key)
        } else {
            newsReplyDrafts[key] = NewsReplyDraft(text: text,
                                                  attachmentTokens: tokens,
                                                  targetArticleID: newsReplyTargetArticleID)
        }
    }

    func restoreInlineNewsReplyDraft(_ draft: NewsReplyDraft?) {
        newsReplyTextView.string = draft?.text ?? ""
        newsReplyAttachments.clear()
        for token in draft?.attachmentTokens ?? [] {
            for segment in LegacyMediaReference.segments(in: token) {
                switch segment {
                case let .image(id):
                    newsReplyAttachments.addExistingImage(id: id, preview: mediaCache?.image(id: id), filename: L("Draft image"))
                case let .youtube(reference):
                    newsReplyAttachments.addYouTube(reference)
                case .text:
                    break
                }
            }
        }
        newsReplyTargetArticleID = draft?.targetArticleID
        newsReplyValidationLabel.isHidden = true
        updateInlineNewsReplyState()
    }

    func activateInlineNewsReplyContext(group: Data?, threadID: UInt32?) {
        let newKey: String?
        if let group, let threadID { newKey = newsReplyDraftKey(group: group, threadID: threadID) }
        else { newKey = nil }
        guard newKey != newsReplyContextKey else {
            updateInlineNewsReplyState()
            return
        }
        saveInlineNewsReplyDraft()
        newsReplyContextKey = newKey
        restoreInlineNewsReplyDraft(newKey.flatMap { newsReplyDrafts[$0] })
    }

    func newsReplyTargetDescription() -> String {
        guard let threadID = currentNewsThreadID else { return "" }
        guard let target = newsReplyTargetArticleID, target != threadID else { return L("To topic") }
        if let post = currentNewsThreadPosts.first(where: { $0.articleID == target }) {
            return LF("Replying to %@", Self.macRomanString(post.sender))
        }
        return LF("Replying to post #%@", String(target))
    }

    func updateInlineNewsReplyState() {
        let hasThread = client.isConnected && newsClient != nil && currentNewsCategory != nil && currentNewsThreadID != nil
            && currentNewsIndex == nil && canPostRemoteNews
        newsReplyTextView.isEditable = hasThread && !newsReplySending && !newsReplyMediaBusy
        newsReplyTextView.isSelectable = true
        newsReplyTargetLabel.stringValue = hasThread ? newsReplyTargetDescription() : L("Select a topic to reply")
        let targetIsSpecific = newsReplyTargetArticleID != nil && newsReplyTargetArticleID != currentNewsThreadID
        newsReplyClearTargetButton.isHidden = !targetIsSpecific
        newsReplyAttachButton.isHidden = mediaClient == nil
        newsReplyYouTubeButton.isHidden = lastLoginResult?.supportsYouTubeLinks != true
        newsReplyAttachButton.isEnabled = hasThread && !newsReplySending && !newsReplyMediaBusy
            && mediaClient != nil && newsReplyAttachments.imageCount < LegacyMediaTransfer.maximumImagesPerNewsPost
        newsReplyYouTubeButton.isEnabled = hasThread && !newsReplySending && !newsReplyMediaBusy
            && lastLoginResult?.supportsYouTubeLinks == true
            && newsReplyAttachments.youtubeCount < LegacyMediaTransfer.maximumYouTubeLinksPerNewsPost
        newsReplyButton.isEnabled = hasThread && !newsReplySending && !newsReplyMediaBusy
        if newsReplySending {
            newsReplySendingIndicator.isHidden = false
            newsReplySendingIndicator.startAnimation(nil)
        } else {
            newsReplySendingIndicator.stopAnimation(nil)
            newsReplySendingIndicator.isHidden = true
        }
    }

    func setInlineNewsReplyTarget(_ articleID: UInt32?) {
        guard currentNewsThreadID != nil else { return }
        newsReplyTargetArticleID = articleID == currentNewsThreadID ? nil : articleID
        newsReplyValidationLabel.isHidden = true
        saveInlineNewsReplyDraft()
        updateInlineNewsReplyState()
        view.window?.makeFirstResponder(newsReplyTextView)
    }

    static func htmlEscapedNewsQuoteText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    func quoteNewsPost(articleID: UInt32) {
        guard currentNewsThreadID != nil,
              let article = currentNewsThreadArticles.first(where: { $0.metadata.articleID == articleID }),
              currentNewsPostCapabilities[articleID]?.isDeleted != true else { return }

        let sender = Self.htmlEscapedNewsQuoteText(Self.macRomanString(article.metadata.sender))
        let bodyText = CarrachoHTMLText.plainText(fromWire: article.body.text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedBody = Self.htmlEscapedNewsQuoteText(bodyText)
            .replacingOccurrences(of: "\n", with: "<br>")
        let quoteBody = escapedBody.isEmpty ? L("(no text)") : escapedBody
        let quote = "<blockquote><b>\(sender) \(L("wrote:"))</b><br>\(quoteBody)</blockquote>"

        let existing = newsReplyTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        newsReplyTextView.string = existing.isEmpty ? quote + "\n\n" : existing + "\n\n" + quote + "\n\n"
        newsReplyTextView.setSelectedRange(NSRange(location: (newsReplyTextView.string as NSString).length, length: 0))
        setInlineNewsReplyTarget(articleID)
        saveInlineNewsReplyDraft()
        updateInlineNewsReplyState()
    }

    @objc func clearInlineNewsReplyTarget(_ sender: Any?) {
        setInlineNewsReplyTarget(nil)
    }

    @objc func attachImageToInlineNewsReply(_ sender: Any?) {
        guard currentNewsThreadID != nil, mediaClient != nil else { return }
        attachImages(to: newsReplyTextView, strip: newsReplyAttachments,
                     maximum: LegacyMediaTransfer.maximumImagesPerNewsPost,
                     attachButton: newsReplyAttachButton) { [weak self] busy in
            guard let self else { return }
            self.newsReplyMediaBusy = busy
            self.updateInlineNewsReplyState()
            if !busy { self.saveInlineNewsReplyDraft() }
        }
    }

    @objc func attachYouTubeToInlineNewsReply(_ sender: Any?) {
        guard currentNewsThreadID != nil,
              lastLoginResult?.supportsYouTubeLinks == true,
              newsReplyAttachments.youtubeCount < LegacyMediaTransfer.maximumYouTubeLinksPerNewsPost,
              let parent = view.window else { return }
        presentYouTubePrompt(parent: parent) { [weak self] reference in
            guard let self else { return }
            self.newsReplyAttachments.addYouTube(reference)
            self.saveInlineNewsReplyDraft()
            self.updateInlineNewsReplyState()
        }
    }

    @objc func sendInlineNewsReply(_ sender: Any?) {
        guard !newsReplySending, !newsReplyMediaBusy,
              client.isConnected, canPostRemoteNews, let newsClient,
              let group = currentNewsCategory,
              let threadID = currentNewsThreadID,
              currentNewsIndex == nil,
              let thread = currentNewsThreads.first(where: { $0.threadID == threadID }) else { return }
        let text = composedRichText(newsReplyTextView.string, attachments: newsReplyAttachments)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            newsReplyValidationLabel.stringValue = L("Write a message or add an attachment before sending.")
            newsReplyValidationLabel.isHidden = false
            view.window?.makeFirstResponder(newsReplyTextView)
            NSSound.beep()
            return
        }
        let wireText = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r")
        let subject: Data
        let message: Data
        do {
            subject = try CarrachoTextWire.encode("Re: \(Self.macRomanString(thread.subject))", maximumBytes: Int(UInt16.max))
            message = try CarrachoTextWire.encode(wireText, maximumBytes: LegacyNewsTransfer.maximumArticleReceiverPayload)
        } catch {
            newsReplyValidationLabel.stringValue = L("The reply exceeds the News protocol size limit.")
            newsReplyValidationLabel.isHidden = false
            return
        }
        var parentID = newsReplyTargetArticleID ?? threadID
        if parentID != threadID && !currentNewsThreadPosts.contains(where: { $0.articleID == parentID }) {
            parentID = threadID
        }
        saveInlineNewsReplyDraft()
        newsReplySending = true
        newsReplyValidationLabel.isHidden = true
        updateInlineNewsReplyState()
        let draftKey = newsReplyContextKey
        newsClient.postArticle(group: group, subject: subject, text: message, parentArticleID: parentID) { [weak self] result in
            guard let self else { return }
            self.newsReplySending = false
            switch result {
            case .success:
                if let draftKey { self.newsReplyDrafts.removeValue(forKey: draftKey) }
                self.newsReplyTextView.string = ""
                self.newsReplyAttachments.clear()
                self.newsReplyTargetArticleID = nil
                self.newsReplyValidationLabel.isHidden = true
                self.appendLine("\n" + LF("Reply posted to topic %@.", String(threadID)))
                self.updateInlineNewsReplyState()
                self.loadNewsIndex(group: group, openThreadID: threadID)
            case let .failure(error):
                self.newsReplyValidationLabel.stringValue = LF("Reply could not be sent: %@", Self.displayMessage(for: error))
                self.newsReplyValidationLabel.isHidden = false
                self.saveInlineNewsReplyDraft()
                self.updateInlineNewsReplyState()
                self.appendLine("\n" + LF("Reply could not be posted: %@", Self.displayMessage(for: error)))
            }
        }
    }

    @objc func refreshCurrentNews(_ sender: Any?) {
        guard client.isConnected else { return }
        if let group = currentNewsCategory {
            loadNewsIndex(group: group, openThreadID: currentNewsThreadID)
        } else {
            refreshNewsCategories()
        }
    }

    @objc func newsThreadSortChanged(_ sender: NSPopUpButton) {
        let descriptor: NSSortDescriptor
        switch sender.indexOfSelectedItem {
        case 1: descriptor = NSSortDescriptor(key: "subject", ascending: true)
        case 2: descriptor = NSSortDescriptor(key: "sender", ascending: true)
        case 3: descriptor = NSSortDescriptor(key: "replies", ascending: false)
        default: descriptor = NSSortDescriptor(key: "activity", ascending: false)
        }
        newsArticleTable.sortDescriptors = [descriptor]
        reloadNewsTablesPreservingSelection()
    }

    @objc func showNewsCategoryActions(_ sender: NSButton) {
        let menu = NSMenu(title: L("News Category"))
        let info = NSMenuItem(title: L("Category Information…"), action: #selector(showSelectedNewsCategoryInfo(_:)), keyEquivalent: "")
        info.target = self
        info.isEnabled = selectedRemoteNewsgroup != nil
        menu.addItem(info)
        let refresh = NSMenuItem(title: L("Refresh Categories"), action: #selector(refreshCurrentNews(_:)), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        if canManageRemoteNewsgroups {
            menu.addItem(.separator())
            let create = NSMenuItem(title: L("New Category…"), action: #selector(createNewsCategoryFromNews(_:)), keyEquivalent: "")
            create.target = self
            menu.addItem(create)
            let manage = NSMenuItem(title: L("Manage News Categories…"), action: #selector(openNewsCategoryAdministration(_:)), keyEquivalent: "")
            manage.target = self
            menu.addItem(manage)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc func showSelectedNewsCategoryInfo(_ sender: Any?) {
        guard let group = selectedRemoteNewsgroup ?? currentNewsCategory else { return }
        let name = Self.macRomanString(group)
        let threads = newsThreadsByCategory[group] ?? (currentNewsCategory == group ? currentNewsThreads : [])
        let posts = threads.reduce(UInt64(0)) { $0 + UInt64($1.replyCount) + 1 }
        let topicText = threads.count == 1 ? LF("%@ topic", String(threads.count)) : LF("%@ topics", String(threads.count))
        let postText = posts == 1 ? LF("%@ post", String(posts)) : LF("%@ posts", String(posts))
        var lines = ["\(topicText) · \(postText)"]
        if let local = localServerState.newsgroups.first(where: { $0.name == name }) {
            lines.append(LF("Retention: %@", Self.expirationDisplay(local.expireAfterSeconds)))
        } else if canManageRemoteNewsgroups {
            lines.append(L("Retention and access rules are available in News Categories administration."))
        }
        let alert = NSAlert()
        alert.messageText = name
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: L("OK"))
        if canManageRemoteNewsgroups { alert.addButton(withTitle: L("Manage…")) }
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.selectWorkspace(.newsgroups) }
        }
    }

    @objc func openNewsCategoryAdministration(_ sender: Any?) {
        selectWorkspace(.newsgroups)
    }

    @objc func showNewsThreadActions(_ sender: NSButton) {
        let menu = NSMenu(title: L("Topic"))
        guard let threadID = currentNewsThreadID else {
            let disabled = NSMenuItem(title: L("No topic selected"), action: nil, keyEquivalent: "")
            disabled.isEnabled = false
            menu.addItem(disabled)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
            return
        }
        let reply = NSMenuItem(title: L("Reply to Topic"), action: #selector(replyToTopicFromMenu(_:)), keyEquivalent: "")
        reply.target = self
        reply.isEnabled = currentNewsIndex == nil
        menu.addItem(reply)
        if currentNewsPostCapabilities[threadID]?.canEdit == true {
            let edit = NSMenuItem(title: L("Edit Topic…"), action: #selector(editCurrentNewsTopic(_:)), keyEquivalent: "")
            edit.target = self
            menu.addItem(edit)
        }
        if canManageRemoteNewsgroups {
            menu.addItem(.separator())
            let delete = NSMenuItem(title: L("Delete Topic…"), action: #selector(deleteCurrentArticle(_:)), keyEquivalent: "")
            delete.target = self
            menu.addItem(delete)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc func replyToTopicFromMenu(_ sender: Any?) {
        setInlineNewsReplyTarget(nil)
    }

    @objc func editCurrentNewsTopic(_ sender: Any?) {
        guard let threadID = currentNewsThreadID else { return }
        editNewsPost(articleID: threadID)
    }

    func newsThreadPreviewText(from article: LegacyArticleReply) -> String {
        let source = editableNewsPostContent(from: article.body.text).text
        let compact = source.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return L("No text preview") }
        if compact.count <= 150 { return compact }
        return String(compact.prefix(147)) + "…"
    }

    func ensureNewsThreadPreview(group: Data, thread: LegacyNewsThreadSummary) {
        if newsThreadPreviewsByCategory[group]?[thread.threadID] != nil { return }
        if newsThreadPreviewLoading[group]?.contains(thread.threadID) == true { return }
        guard client.isConnected else { return }
        newsThreadPreviewLoading[group, default: []].insert(thread.threadID)
        client.requestArticle(group: group, articleID: thread.threadID) { [weak self] result in
            guard let self else { return }
            self.newsThreadPreviewLoading[group]?.remove(thread.threadID)
            switch result {
            case let .success(article):
                self.newsThreadPreviewsByCategory[group, default: [:]][thread.threadID] = self.newsThreadPreviewText(from: article)
            case .failure:
                self.newsThreadPreviewsByCategory[group, default: [:]][thread.threadID] = L("Preview unavailable")
            }
            if self.currentNewsCategory == group,
               let row = self.displayedNewsThreads.firstIndex(where: { $0.threadID == thread.threadID }) {
                self.newsArticleTable.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            }
        }
    }

    func configureNewsReadScope(host: String, port: UInt16, login: String) {
        saveInlineNewsReplyDraft()
        newsReplyContextKey = nil
        newsReplyTargetArticleID = nil
        newsReplyTextView.string = ""
        newsReplyAttachments.clear()
        let scope = "\(host.lowercased()):\(port)|\(login.lowercased())"
        newsReadScope = scope
        newsReadState = newsReadStateStore.load(scope: scope)
        newsThreadsByCategory = [:]
        newsThreadPreviewsByCategory = [:]
        newsThreadPreviewLoading = [:]
        updateInlineNewsReplyState()
    }

    func saveNewsReadState() {
        guard let scope = newsReadScope else { return }
        newsReadStateStore.save(newsReadState, scope: scope)
    }

    func newsThreadTotals(_ threads: [LegacyNewsThreadSummary]) -> [UInt32: UInt32] {
        Dictionary(uniqueKeysWithValues: threads.map { thread in
            let (total, overflow) = thread.replyCount.addingReportingOverflow(1)
            return (thread.threadID, overflow ? UInt32.max : total)
        })
    }

    func newsUnreadCount(group: Data) -> Int {
        guard let threads = newsThreadsByCategory[group] else { return 0 }
        return newsReadState.unreadCount(category: group, totals: newsThreadTotals(threads))
    }

    func newsUnreadCount(group: Data, thread: LegacyNewsThreadSummary) -> Int {
        let (total, overflow) = thread.replyCount.addingReportingOverflow(1)
        return newsReadState.unreadCount(category: group, threadID: thread.threadID,
                                         totalPosts: overflow ? UInt32.max : total)
    }

    func reloadNewsTablesPreservingSelection(category preferredCategory: Data? = nil,
                                                      threadID preferredThreadID: UInt32? = nil) {
        let selectedCategory: Data? = preferredCategory ?? currentNewsCategory ?? {
            let row = newsTable.selectedRow
            return row >= 0 && row < displayedNewsgroups.count ? displayedNewsgroups[row] : nil
        }()
        let selectedThreadID: UInt32? = preferredThreadID ?? currentNewsThreadID ?? {
            let row = newsArticleTable.selectedRow
            return row >= 0 && row < displayedNewsThreads.count ? displayedNewsThreads[row].threadID : nil
        }()

        isReloadingNewsTable = true
        newsTable.reloadData()
        if let selectedCategory,
           let row = displayedNewsgroups.firstIndex(of: selectedCategory) {
            newsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            newsTable.deselectAll(nil)
        }

        newsArticleTable.reloadData()
        if let selectedThreadID,
           let row = displayedNewsThreads.firstIndex(where: { $0.threadID == selectedThreadID }) {
            newsArticleTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            newsArticleTable.deselectAll(nil)
        }
        isReloadingNewsTable = false
    }

    func updateNewsThreadSnapshot(group: Data, threads: [LegacyNewsThreadSummary]) {
        newsThreadsByCategory[group] = threads
        if newsReadState.reconcile(category: group, totals: newsThreadTotals(threads)) { saveNewsReadState() }
        if currentNewsCategory == group { currentNewsThreads = threads }
        reloadNewsTablesPreservingSelection()
    }

    func markNewsThreadRead(group: Data, threadID: UInt32, totalPosts: UInt32) {
        newsReadState.markRead(category: group, threadID: threadID, totalPosts: totalPosts)
        saveNewsReadState()
        reloadNewsTablesPreservingSelection(threadID: threadID)
    }

    func startNewsBadgePolling() {
        newsBadgeRefreshTimer?.invalidate()
        newsBadgeRefreshTimer = nil
        guard client.isConnected, newsBadgesSupported, !lastNewsgroups.isEmpty else { return }
        refreshNewsBadgeSnapshots()
        newsBadgeRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshNewsBadgeSnapshots()
        }
    }

    func stopNewsBadgePolling() {
        newsBadgeRefreshTimer?.invalidate()
        newsBadgeRefreshTimer = nil
        newsBadgeRefreshInFlight = false
    }

    func refreshNewsBadgeSnapshots() {
        guard client.isConnected, newsBadgesSupported, !newsBadgeRefreshInFlight, !lastNewsgroups.isEmpty else { return }
        newsBadgeRefreshInFlight = true
        refreshNewsBadgeCategory(Array(lastNewsgroups), index: 0)
    }

    func refreshNewsBadgeCategory(_ groups: [Data], index: Int) {
        guard client.isConnected, index < groups.count else {
            newsBadgeRefreshInFlight = false
            reloadNewsTablesPreservingSelection()
            return
        }
        let group = groups[index]
        client.requestNewsThreads(group: group) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(threads):
                self.updateNewsThreadSnapshot(group: group, threads: threads)
                self.refreshNewsBadgeCategory(groups, index: index + 1)
            case .failure:
                // Classic servers do not know the threaded-News extension. Once that
                // is detected, stop background requests instead of timing out forever.
                self.newsBadgesSupported = false
                self.newsBadgeRefreshInFlight = false
                self.stopNewsBadgePolling()
            }
        }
    }

    func handleNewsInlineLink(_ rawLink: Any) -> Bool {
        let url: URL?
        if let value = rawLink as? URL { url = value }
        else if let value = rawLink as? String { url = URL(string: value) }
        else { url = nil }
        guard let url,
              let articleText = url.host ?? url.pathComponents.dropFirst().first,
              let articleID = UInt32(articleText), articleID != 0 else { return false }

        switch url.scheme?.lowercased() {
        case "carracho-news-reply":
            guard currentNewsPostCapabilities[articleID]?.isDeleted != true else { return true }
            setInlineNewsReplyTarget(articleID)
            return true
        case "carracho-news-quote":
            guard currentNewsPostCapabilities[articleID]?.isDeleted != true else { return true }
            quoteNewsPost(articleID: articleID)
            return true
        case "carracho-news-edit":
            guard currentNewsPostCapabilities[articleID]?.canEdit == true else { return true }
            editNewsPost(articleID: articleID)
            return true
        case "carracho-news-delete":
            guard currentNewsPostCapabilities[articleID]?.canDelete == true else { return true }
            deleteNewsPost(articleID: articleID)
            return true
        case "carracho-news-post-menu":
            presentNewsPostActionMenu(articleID: articleID)
            return true
        case "carracho-news-react":
            guard newsReactionsSupported,
                  currentNewsPostCapabilities[articleID]?.isDeleted != true else { return true }
            presentNewsReactionMenu(articleID: articleID)
            return true
        default:
            return false
        }
    }

    func presentNewsPostActionMenu(articleID: UInt32) {
        let menu = NSMenu(title: L("Post"))
        if currentNewsPostCapabilities[articleID]?.canDelete == true {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let delete = NSMenuItem(title: L("Delete Post…"), action: #selector(deleteNewsPostFromMenu(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = NSNumber(value: articleID)
            menu.addItem(delete)
        }
        if menu.items.isEmpty {
            let item = NSMenuItem(title: L("No additional actions"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        let point = newsArticleTextView.window.map { newsArticleTextView.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
            ?? NSPoint(x: newsArticleTextView.bounds.midX, y: newsArticleTextView.bounds.midY)
        menu.popUp(positioning: nil, at: point, in: newsArticleTextView)
    }

    @objc func editNewsPostFromMenu(_ sender: NSMenuItem) {
        guard let articleID = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        editNewsPost(articleID: articleID)
    }

    @objc func deleteNewsPostFromMenu(_ sender: NSMenuItem) {
        guard let articleID = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        deleteNewsPost(articleID: articleID)
    }

    func presentNewsReactionMenu(articleID: UInt32) {
        let menu = NSMenu(title: L("Reactions"))
        let summaries = currentNewsReactions[articleID] ?? []
        let mine = summaries.first(where: \.reactedByCurrentUser)?.kind
        for kind in LegacyNewsReactionKind.allCases {
            let summary = summaries.first(where: { $0.kind == kind.rawValue })
            let count = summary?.count ?? 0
            let title = count == 0 ? kind.emoji : "\(kind.emoji)  \(count)"
            let item = NSMenuItem(title: title, action: #selector(setInlineNewsReaction(_:)), keyEquivalent: "")
            item.target = self
            item.state = mine == kind.rawValue ? .on : .off
            item.representedObject = "\(articleID):\(kind.rawValue)"
            menu.addItem(item)
        }
        if mine != nil {
            menu.addItem(.separator())
            let remove = NSMenuItem(title: L("Remove My Reaction"), action: #selector(setInlineNewsReaction(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = "\(articleID):0"
            menu.addItem(remove)
        }
        let point = newsArticleTextView.window.map { newsArticleTextView.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
            ?? NSPoint(x: 12, y: 12)
        menu.popUp(positioning: nil, at: point, in: newsArticleTextView)
    }

    @objc func setInlineNewsReaction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String else { return }
        let parts = payload.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let articleID = UInt32(parts[0]), let raw = UInt8(parts[1]),
              let group = currentNewsCategory,
              currentNewsPostCapabilities[articleID]?.isDeleted != true else { return }
        let requested: UInt8
        if raw == 0 {
            requested = 0
        } else {
            let mine = currentNewsReactions[articleID]?.first(where: \.reactedByCurrentUser)?.kind
            requested = mine == raw ? 0 : raw
        }
        client.setNewsReaction(group: group, articleID: articleID, reaction: requested) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(summary):
                self.currentNewsReactions[articleID] = summary
                self.reloadNewsViewPreservingArticleScrollPosition()
            case let .failure(error):
                self.newsReactionsSupported = false
                self.appendLine("\n" + LF("News reaction could not be saved: %@", Self.displayMessage(for: error)))
                self.reloadNewsViewPreservingArticleScrollPosition()
            }
        }
    }

    func reloadNewsViewPreservingArticleScrollPosition() {
        // reloadNewsView() now preserves the visible position synchronously whenever the same
        // thread is being redrawn. Avoid queuing a delayed clip-view restore that can fight
        // subsequent trackpad/wheel events and make the reader appear to jitter in place.
        reloadNewsView()
    }

    func loadNewsReactions(group: Data, posts: [LegacyNewsThreadPostSummary], index: Int) {
        guard newsReactionsSupported else { reloadNewsView(); return }
        guard index < posts.count else { reloadNewsView(); return }
        let articleID = posts[index].articleID
        client.requestNewsReactions(group: group, articleID: articleID) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(summary):
                self.currentNewsReactions[articleID] = summary
                self.loadNewsReactions(group: group, posts: posts, index: index + 1)
            case .failure:
                self.newsReactionsSupported = false
                self.currentNewsReactions = [:]
                self.reloadNewsView()
            }
        }
    }

    @objc func createNewsCategoryFromNews(_ sender: Any?) {
        guard client.isConnected, canManageRemoteNewsgroups, let window = view.window else {
            showError(L("This account cannot create News categories."))
            return
        }

        let alert = NSAlert()
        alert.messageText = L("New News Category")
        alert.informativeText = L("Create a category first, then add threads and posts directly in News.")
        alert.addButton(withTitle: L("Create"))
        alert.addButton(withTitle: L("Cancel"))

        let name = NSTextField(string: "")
        name.placeholderString = L("Category name")
        let amount = NSTextField(string: "1")
        amount.alignment = .right
        amount.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let unit = NSPopUpButton()
        unit.addItems(withTitles: [L("hours"), L("days"), L("weeks"), L("months"), L("years"), L("never")])
        unit.selectItem(at: 2)
        let expire = horizontalStack([NSTextField(labelWithString: L("Expire posts after")), amount, unit], spacing: 8)

        let stack = verticalStack([
            sectionCaption(L("Category")), name, expire,
            infoLabel(L("The category uses the server's default News access. Detailed access rules remain configurable in News Categories administration.")),
        ], spacing: 10)
        stack.frame = NSRect(x: 0, y: 0, width: 500, height: 150)
        alert.accessoryView = stack

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                let categoryName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !categoryName.isEmpty,
                      let categoryData = categoryName.data(using: .macOSRoman),
                      categoryData.count <= LegacyNewsTransfer.maximumGroupNameLength else {
                    throw ServerStateError.invalidValue(L("The category name must be MacRoman-compatible and at most 64 bytes."))
                }
                let expiration = try self.expirationSeconds(amount: amount.stringValue, unitIndex: unit.indexOfSelectedItem)
                let defaultAccess = ServerNewsgroupAccess()
                self.newsNewCategoryButton.isEnabled = false
                self.client.createNewsgroup(name: categoryData, expireAfterSeconds: expiration,
                                            flags: defaultAccess.legacyFlags) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.appendLine("\n" + LF("News category %@ created.", categoryName))
                        self.refreshNewsCategories(selecting: categoryData, openSelected: true)
                    case let .failure(error):
                        self.showError(LF("News category could not be created: %@", Self.displayMessage(for: error)))
                        self.reloadNewsView()
                    }
                }
            } catch {
                self.showError(Self.displayMessage(for: error))
            }
        }
    }

    func refreshNewsCategories(selecting preferredGroup: Data? = nil, openSelected: Bool = false) {
        guard client.isConnected else { return }
        client.requestNewsgroups { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(groups):
                let previouslySelectedGroup: Data? = {
                    let row = self.newsTable.selectedRow
                    if row >= 0, row < self.displayedNewsgroups.count { return self.displayedNewsgroups[row] }
                    return self.currentNewsCategory
                }()
                self.lastNewsgroups = groups
                var selectedGroup = preferredGroup ?? previouslySelectedGroup
                if selectedGroup == nil { selectedGroup = self.displayedNewsgroups.first }
                self.reloadNewsTablesPreservingSelection(category: selectedGroup)
                if let selectedGroup,
                   let row = self.displayedNewsgroups.firstIndex(of: selectedGroup) {
                    self.newsTable.scrollRowToVisible(row)
                }
                self.reloadNewsView()
                self.startNewsBadgePolling()
                if openSelected, let selectedGroup { self.loadNewsIndex(group: selectedGroup) }
            case let .failure(error):
                self.showError(LF("News categories could not be refreshed: %@", Self.displayMessage(for: error)))
                self.reloadNewsView()
            }
        }
    }

    @objc func loadSelectedNewsgroup(_ sender: Any?) {
        let row = newsTable.clickedRow >= 0 ? newsTable.clickedRow : newsTable.selectedRow
        guard row >= 0, row < displayedNewsgroups.count else { return }
        loadNewsIndex(group: displayedNewsgroups[row])
    }

    func loadNewsIndex(group: Data, openThreadID: UInt32? = nil) {
        guard client.isConnected, newsClient != nil else { return }
        newsLoadErrorMessage = nil
        activateInlineNewsReplyContext(group: openThreadID == nil ? nil : group, threadID: openThreadID)
        currentNewsCategory = group
        currentNewsIndex = nil
        currentArticle = nil
        currentNewsThreads = []
        currentNewsThreadID = nil
        currentNewsThreadPosts = []
        currentNewsThreadArticles = []
        currentNewsReactions = [:]
        currentNewsPostCapabilities = [:]
        newsArticleTextView.string = ""
        newsTitleLabel.stringValue = LF("%@ — loading threads…", Self.macRomanString(group))
        reloadNewsView()

        client.requestNewsThreads(group: group) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(threads):
                self.newsLoadErrorMessage = nil
                self.updateNewsThreadSnapshot(group: group, threads: threads)
                self.currentNewsThreads = threads
                if let openThreadID,
                   self.displayedNewsThreads.contains(where: { $0.threadID == openThreadID }) {
                    self.loadNewsThread(group: group, threadID: openThreadID)
                } else {
                    self.reloadNewsView()
                }
            case let .failure(threadError):
                // Compatibility fallback for older servers: every flat article becomes
                // a one-post thread. Replies require the threaded extension.
                guard let newsClient = self.newsClient else { return }
                newsClient.requestIndex(group: group) { [weak self] legacyResult in
                    guard let self else { return }
                    switch legacyResult {
                    case let .success(index):
                        self.newsLoadErrorMessage = nil
                        self.currentNewsIndex = index ?? LegacyArticleIndex(group: group, entries: [])
                        self.currentNewsThreads = (index?.entries ?? []).map {
                            LegacyNewsThreadSummary(threadID: $0.articleID, subject: $0.subject,
                                                    sender: $0.sender, date: $0.date,
                                                    replyCount: 0, latestDate: $0.date)
                        }
                        self.appendLine("\n" + LF("Server uses the legacy flat article index; threaded News is unavailable: %@", Self.displayMessage(for: threadError)))
                        self.reloadNewsView()
                    case let .failure(error):
                        self.currentNewsThreads = []
                        self.newsLoadErrorMessage = LF("News category could not be loaded: %@", Self.displayMessage(for: error))
                        self.appendLine("\n" + LF("News category could not be loaded: %@", Self.displayMessage(for: error)))
                        self.reloadNewsView()
                    }
                }
            }
        }
    }

    @objc func showArticleEditor(_ sender: Any?) {
        guard client.isConnected, canPostRemoteNews, let newsClient, let group = selectedRemoteNewsgroup,
              let window = view.window else {
            if client.isConnected && !canPostRemoteNews { showError(L("This account cannot post News.")) }
            return
        }
        let alert = NSAlert()
        alert.messageText = L("New Thread")
        alert.informativeText = LF("Start a thread in %@.", Self.macRomanString(group))
        alert.addButton(withTitle: L("Post"))
        alert.addButton(withTitle: L("Cancel"))

        let accessoryWidth: CGFloat = 560
        let accessoryHeight: CGFloat = 500
        let subject = NSTextField(string: "")
        subject.placeholderString = L("Thread subject")
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let body = CarrachoMediaComposerTextView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: 235))
        body.isRichText = false
        body.isEditable = true
        body.isSelectable = true
        body.allowsUndo = true
        body.font = NSFont.systemFont(ofSize: newsFontSize)
        body.textContainerInset = NSSize(width: 8, height: 8)
        body.isHorizontallyResizable = false
        body.isVerticallyResizable = true
        body.autoresizingMask = [.width]
        body.textContainer?.widthTracksTextView = true
        let attachments = CarrachoComposerAttachmentStrip()
        attachments.onRemoveImage = { [weak self] id in self?.deletePendingMedia(id) }
        body.youTubeURLHandler = { [weak self] reference in
            guard let self,
                  self.lastLoginResult?.supportsYouTubeLinks == true,
                  attachments.youtubeCount < LegacyMediaTransfer.maximumYouTubeLinksPerNewsPost else { return false }
            attachments.addYouTube(reference)
            return true
        }
        let bodyScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: 235))
        bodyScroll.hasVerticalScroller = true
        bodyScroll.borderType = .bezelBorder
        bodyScroll.documentView = body
        let htmlHint = infoLabel(CarrachoHTMLText.editorHint)
        htmlHint.lineBreakMode = .byWordWrapping
        htmlHint.maximumNumberOfLines = 2
        htmlHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let attachImage = CarrachoClosureButton(title: L("Attach Image…"))
        attachImage.image = sizedAssetImage(named: "Image", size: 16)
        attachImage.imagePosition = .imageLeading
        attachImage.imageScaling = .scaleNone
        attachImage.contentTintColor = nil
        attachImage.isHidden = mediaClient == nil
        attachImage.handler = { [weak self, weak body, weak attachImage, weak alert] in
            guard let self, let body else { return }
            self.attachImages(to: body, strip: attachments, maximum: LegacyMediaTransfer.maximumImagesPerNewsPost,
                              attachButton: attachImage) { busy in
                alert?.buttons.first?.isEnabled = !busy
            }
        }
        body.imageFileHandler = { [weak self, weak body, weak alert] urls in
            guard let self, let body, let mediaClient = self.mediaClient else { return }
            let remaining = max(0, LegacyMediaTransfer.maximumImagesPerNewsPost - attachments.imageCount)
            do {
                let prepared = try Array(urls.prefix(remaining)).map { try CarrachoMediaImageProcessor.prepare(url: $0) }
                alert?.buttons.first?.isEnabled = false
                self.uploadPreparedMedia(prepared, client: mediaClient) { [weak self, weak body, weak alert] result in
                    alert?.buttons.first?.isEnabled = true
                    guard let self, body != nil else { return }
                    switch result {
                    case let .success(ids): self.addUploadedImages(ids: ids, prepared: prepared, to: attachments)
                    case let .failure(error): self.showError(LF("Image upload failed: %@", Self.displayMessage(for: error)))
                    }
                }
            } catch { self.showError(LF("Image could not be prepared: %@", Self.displayMessage(for: error))) }
        }
        body.imageDataHandler = { [weak self, weak body, weak alert] data in
            guard let self, let body else { return }
            self.attachImageData(data, to: body, strip: attachments, maximum: LegacyMediaTransfer.maximumImagesPerNewsPost) { busy in
                alert?.buttons.first?.isEnabled = !busy
            }
        }
        let attachYouTube = CarrachoClosureButton(title: L("YouTube…"))
        attachYouTube.image = sizedAssetImage(named: "YouTube", size: 16)
        attachYouTube.imagePosition = .imageLeading
        attachYouTube.imageScaling = .scaleNone
        attachYouTube.contentTintColor = nil
        attachYouTube.isHidden = lastLoginResult?.supportsYouTubeLinks != true
        attachYouTube.handler = { [weak self, weak alert] in
            guard let self, attachments.youtubeCount < LegacyMediaTransfer.maximumYouTubeLinksPerNewsPost,
                  let parent = alert?.window else { return }
            self.presentYouTubePrompt(parent: parent) { reference in attachments.addYouTube(reference) }
        }
        let mediaHint = infoLabel(mediaClient == nil
            ? L("Image attachments are not supported by this server.")
            : L("PNG/JPEG: Attach, drag or paste with ⌘V. Upload references stay hidden; unused uploads expire automatically."))
        mediaHint.lineBreakMode = .byWordWrapping
        mediaHint.maximumNumberOfLines = 2
        mediaHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let subjectLabel = NSTextField(labelWithString: L("Subject"))
        subjectLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let validationLabel = NSTextField(wrappingLabelWithString: "")
        validationLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        validationLabel.textColor = .systemRed
        validationLabel.maximumNumberOfLines = 2
        validationLabel.isHidden = true
        let messageLabel = NSTextField(labelWithString: L("Message"))
        messageLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        messageLabel.setContentHuggingPriority(.required, for: .horizontal)
        let emoji = EmojiPickerButton(editor: body)
        let attachRow = horizontalStack([messageLabel, NSView(), emoji, attachImage, attachYouTube], spacing: 8)

        let stack = verticalStack([subjectLabel, subject, validationLabel, attachRow, htmlHint, mediaHint, attachments, bodyScroll], spacing: 6)
        stack.setCustomSpacing(4, after: subjectLabel)
        stack.setCustomSpacing(6, after: subject)
        stack.setCustomSpacing(10, after: validationLabel)
        stack.setCustomSpacing(4, after: attachRow)
        stack.setCustomSpacing(4, after: htmlHint)
        stack.setCustomSpacing(8, after: mediaHint)
        stack.setCustomSpacing(8, after: attachments)

        subject.heightAnchor.constraint(equalToConstant: 28).isActive = true
        // Let the editor consume any spare vertical space in the accessory instead of leaving
        // a dead band above the NSAlert buttons. When attachments appear, the editor can shrink
        // back down to its original minimum height.
        bodyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 235).isActive = true

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: accessoryHeight))
        stack.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            stack.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = subject

        let postValidationTarget = CarrachoClosureTarget { [weak self, weak alert, weak subject, weak body, weak validationLabel, weak attachImage, weak attachYouTube] _ in
            guard let self, let alert, let subject, let body, let validationLabel else { return }
            let subjectText = subject.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let composed = self.composedRichText(body.string, attachments: attachments)
            let messageText = composed.trimmingCharacters(in: .whitespacesAndNewlines)

            if subjectText.isEmpty || messageText.isEmpty {
                validationLabel.textColor = .systemRed
                if subjectText.isEmpty && messageText.isEmpty {
                    validationLabel.stringValue = L("Please enter a subject and a message.")
                    alert.window.makeFirstResponder(subject)
                } else if subjectText.isEmpty {
                    validationLabel.stringValue = L("Please enter a subject.")
                    alert.window.makeFirstResponder(subject)
                } else {
                    validationLabel.stringValue = L("Please enter a message or add an attachment.")
                    alert.window.makeFirstResponder(body)
                }
                validationLabel.isHidden = false
                NSSound.beep()
                return
            }

            let articleString = composed
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: "\r")
            let subjectData: Data
            let articleData: Data
            do {
                subjectData = try CarrachoTextWire.encode(subjectText, maximumBytes: Int(UInt16.max))
                articleData = try CarrachoTextWire.encode(articleString, maximumBytes: LegacyNewsTransfer.maximumArticleReceiverPayload)
            } catch {
                validationLabel.textColor = .systemRed
                validationLabel.stringValue = L("Subject or message exceeds the News protocol size limit after Unicode encoding.")
                validationLabel.isHidden = false
                return
            }

            let postButton = alert.buttons.first
            let cancelButton = alert.buttons.dropFirst().first
            postButton?.isEnabled = false
            cancelButton?.isEnabled = false
            subject.isEnabled = false
            body.isEditable = false
            attachImage?.isEnabled = false
            attachYouTube?.isEnabled = false
            validationLabel.textColor = CarrachoTheme.secondaryText
            validationLabel.stringValue = L("Posting…")
            validationLabel.isHidden = false

            newsClient.postArticle(group: group, subject: subjectData, text: articleData) { [weak self, weak alert, weak subject, weak body, weak validationLabel, weak attachImage, weak attachYouTube] result in
                guard let self, let alert, let subject, let body, let validationLabel else { return }
                switch result {
                case .success:
                    self.appendLine("\n" + LF("Thread posted to %@.", Self.macRomanString(group)))
                    window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
                    self.loadNewsIndex(group: group)
                case let .failure(error):
                    postButton?.isEnabled = true
                    cancelButton?.isEnabled = true
                    subject.isEnabled = true
                    body.isEditable = true
                    attachImage?.isEnabled = self.mediaClient != nil
                    attachYouTube?.isEnabled = self.lastLoginResult?.supportsYouTubeLinks == true
                        && attachments.youtubeCount < LegacyMediaTransfer.maximumYouTubeLinksPerNewsPost
                    validationLabel.textColor = .systemRed
                    validationLabel.stringValue = LF("Thread could not be posted: %@", Self.displayMessage(for: error))
                    validationLabel.isHidden = false
                    self.appendLine("\n" + LF("Thread could not be posted: %@", Self.displayMessage(for: error)))
                    alert.window.makeFirstResponder(body)
                }
            }
        }
        if let postButton = alert.buttons.first {
            postButton.target = postValidationTarget
            postButton.action = #selector(CarrachoClosureTarget.invoke(_:))
        }

        alert.beginSheetModal(for: window) { [postValidationTarget] _ in
            _ = postValidationTarget // Keep the button target alive for the lifetime of the sheet.
        }
    }

    @objc func showNewsReplyEditor(_ sender: Any?) {
        guard client.isConnected, canPostRemoteNews, let newsClient, let group = currentNewsCategory,
              let thread = selectedNewsThreadForPosting,
              let window = view.window else {
            if client.isConnected && !canPostRemoteNews { showError(L("This account cannot post News.")) }
            return
        }
        let threadID = thread.threadID
        let subjectText = "Re: \(Self.macRomanString(thread.subject))"
        let alert = NSAlert()
        alert.messageText = L("Reply to Thread")
        alert.informativeText = Self.macRomanString(thread.subject)
        alert.addButton(withTitle: L("Reply"))
        alert.addButton(withTitle: L("Cancel"))
        let accessoryWidth: CGFloat = 560
        let accessoryHeight: CGFloat = 370
        let body = CarrachoMediaComposerTextView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: 235))
        body.isRichText = false
        body.isEditable = true
        body.isSelectable = true
        body.allowsUndo = true
        body.font = NSFont.systemFont(ofSize: newsFontSize)
        body.textContainerInset = NSSize(width: 8, height: 8)
        body.isHorizontallyResizable = false
        body.isVerticallyResizable = true
        body.autoresizingMask = [.width]
        body.textContainer?.widthTracksTextView = true
        let attachments = CarrachoComposerAttachmentStrip()
        attachments.onRemoveImage = { [weak self] id in self?.deletePendingMedia(id) }
        body.youTubeURLHandler = { [weak self] reference in
            guard let self,
                  self.lastLoginResult?.supportsYouTubeLinks == true,
                  attachments.youtubeCount < LegacyMediaTransfer.maximumYouTubeLinksPerNewsPost else { return false }
            attachments.addYouTube(reference)
            return true
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: 235))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = body
        let htmlHint = infoLabel(CarrachoHTMLText.editorHint)
        htmlHint.lineBreakMode = .byWordWrapping
        htmlHint.maximumNumberOfLines = 2
        htmlHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let attachImage = CarrachoClosureButton(title: L("Attach Image…"))
        attachImage.image = sizedAssetImage(named: "Image", size: 16)
        attachImage.imagePosition = .imageLeading
        attachImage.imageScaling = .scaleNone
        attachImage.contentTintColor = nil
        attachImage.isHidden = mediaClient == nil
        attachImage.handler = { [weak self, weak body, weak attachImage, weak alert] in
            guard let self, let body else { return }
            self.attachImages(to: body, strip: attachments, maximum: LegacyMediaTransfer.maximumImagesPerNewsPost,
                              attachButton: attachImage) { busy in alert?.buttons.first?.isEnabled = !busy }
        }
        body.imageFileHandler = { [weak self, weak body, weak alert] urls in
            guard let self, let body, let mediaClient = self.mediaClient else { return }
            let remaining = max(0, LegacyMediaTransfer.maximumImagesPerNewsPost - attachments.imageCount)
            do {
                let prepared = try Array(urls.prefix(remaining)).map { try CarrachoMediaImageProcessor.prepare(url: $0) }
                alert?.buttons.first?.isEnabled = false
                self.uploadPreparedMedia(prepared, client: mediaClient) { [weak self, weak body, weak alert] result in
                    alert?.buttons.first?.isEnabled = true
                    guard let self, body != nil else { return }
                    switch result {
                    case let .success(ids): self.addUploadedImages(ids: ids, prepared: prepared, to: attachments)
                    case let .failure(error): self.showError(LF("Image upload failed: %@", Self.displayMessage(for: error)))
                    }
                }
            } catch { self.showError(LF("Image could not be prepared: %@", Self.displayMessage(for: error))) }
        }
        body.imageDataHandler = { [weak self, weak body, weak alert] data in
            guard let self, let body else { return }
            self.attachImageData(data, to: body, strip: attachments, maximum: LegacyMediaTransfer.maximumImagesPerNewsPost) { busy in
                alert?.buttons.first?.isEnabled = !busy
            }
        }
        let attachYouTube = CarrachoClosureButton(title: L("YouTube…"))
        attachYouTube.image = sizedAssetImage(named: "YouTube", size: 16)
        attachYouTube.imagePosition = .imageLeading
        attachYouTube.imageScaling = .scaleNone
        attachYouTube.contentTintColor = nil
        attachYouTube.isHidden = lastLoginResult?.supportsYouTubeLinks != true
        attachYouTube.handler = { [weak self, weak alert] in
            guard let self, attachments.youtubeCount < LegacyMediaTransfer.maximumYouTubeLinksPerNewsPost,
                  let parent = alert?.window else { return }
            self.presentYouTubePrompt(parent: parent) { reference in attachments.addYouTube(reference) }
        }
        let mediaHint = infoLabel(mediaClient == nil
            ? L("Image attachments are not supported by this server.")
            : L("PNG/JPEG: Attach, drag or paste with ⌘V. Internal references stay hidden."))
        mediaHint.lineBreakMode = .byWordWrapping
        mediaHint.maximumNumberOfLines = 2
        mediaHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let messageLabel = NSTextField(labelWithString: L("Message"))
        messageLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        messageLabel.setContentHuggingPriority(.required, for: .horizontal)
        let emoji = EmojiPickerButton(editor: body)
        let attachRow = horizontalStack([messageLabel, NSView(), emoji, attachImage, attachYouTube], spacing: 8)
        let validationLabel = NSTextField(wrappingLabelWithString: "")
        validationLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        validationLabel.textColor = .systemRed
        validationLabel.maximumNumberOfLines = 2
        validationLabel.isHidden = true

        let replyStack = verticalStack([attachRow, validationLabel, htmlHint, mediaHint, attachments, scroll], spacing: 6)
        replyStack.setCustomSpacing(4, after: attachRow)
        replyStack.setCustomSpacing(8, after: validationLabel)
        replyStack.setCustomSpacing(4, after: htmlHint)
        replyStack.setCustomSpacing(8, after: mediaHint)
        replyStack.setCustomSpacing(8, after: attachments)
        scroll.heightAnchor.constraint(equalToConstant: 235).isActive = true

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: accessoryHeight))
        replyStack.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(replyStack)
        NSLayoutConstraint.activate([
            replyStack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            replyStack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            replyStack.topAnchor.constraint(equalTo: accessory.topAnchor),
            replyStack.bottomAnchor.constraint(lessThanOrEqualTo: accessory.bottomAnchor),
        ])
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = body

        let replyValidationTarget = CarrachoClosureTarget { [weak alert, weak body, weak validationLabel] _ in
            guard let alert, let body, let validationLabel else { return }
            guard !body.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                validationLabel.stringValue = L("Please enter a message.")
                validationLabel.isHidden = false
                alert.window.makeFirstResponder(body)
                NSSound.beep()
                return
            }
            validationLabel.isHidden = true
            window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        }
        if let replyButton = alert.buttons.first {
            replyButton.target = replyValidationTarget
            replyButton.action = #selector(CarrachoClosureTarget.invoke(_:))
        }

        alert.beginSheetModal(for: window) { [weak self, replyValidationTarget] response in
            _ = replyValidationTarget // Keep the button target alive for the lifetime of the sheet.
            guard response == .alertFirstButtonReturn, let self else { return }
            let text = self.composedRichText(body.string, attachments: attachments)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: "\r")
            let subject: Data
            let message: Data
            do {
                subject = try CarrachoTextWire.encode(subjectText, maximumBytes: Int(UInt16.max))
                message = try CarrachoTextWire.encode(text, maximumBytes: LegacyNewsTransfer.maximumArticleReceiverPayload)
            } catch {
                self.showError(L("Reply exceeds the News protocol size limit after Unicode encoding."))
                return
            }
            self.newsReplyButton.isEnabled = false
            newsClient.postArticle(group: group, subject: subject, text: message,
                                   parentArticleID: threadID) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.appendLine("\n" + LF("Reply posted to thread %@.", String(threadID)))
                    self.loadNewsIndex(group: group, openThreadID: threadID)
                case let .failure(error):
                    self.appendLine("\n" + LF("Reply could not be posted: %@", Self.displayMessage(for: error)))
                    self.reloadNewsView()
                }
            }
        }
    }

    @objc func openSelectedNewsThread(_ sender: Any?) {
        let row = newsArticleTable.clickedRow >= 0 ? newsArticleTable.clickedRow : newsArticleTable.selectedRow
        guard let group = currentNewsCategory, row >= 0, row < displayedNewsThreads.count else { return }
        loadNewsThread(group: group, threadID: displayedNewsThreads[row].threadID)
    }

    func loadNewsThread(group: Data, threadID: UInt32) {
        guard client.isConnected else { return }
        newsLoadErrorMessage = nil
        activateInlineNewsReplyContext(group: group, threadID: threadID)
        currentNewsThreadID = threadID
        currentNewsThreadPosts = []
        currentNewsThreadArticles = []
        currentNewsReactions = [:]
        currentNewsPostCapabilities = [:]
        currentArticle = nil
        newsArticleTextView.string = L("Loading thread…")
        reloadNewsView()
        client.requestNewsThreadEntriesWithCapabilities(group: group, threadID: threadID) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(entries):
                self.currentNewsThreadPosts = entries.posts
                self.currentNewsPostCapabilities = Dictionary(uniqueKeysWithValues: entries.capabilities.map { ($0.articleID, $0) })
                self.loadNewsThreadBodies(group: group, posts: entries.posts, index: 0, articles: [])
            case let .failure(error):
                // A legacy server may not support thread metadata. Open the root article.
                self.client.requestArticle(group: group, articleID: threadID) { [weak self] articleResult in
                    guard let self else { return }
                    switch articleResult {
                    case let .success(article):
                        self.currentNewsThreadPosts = [LegacyNewsThreadPostSummary(articleID: threadID,
                                                                                 parentArticleID: LegacyArticle.noArticle,
                                                                                 sender: article.metadata.sender,
                                                                                 date: article.metadata.date,
                                                                                 bodyLength: UInt32(article.body.text.count))]
                        self.currentNewsThreadArticles = [article]
                        self.currentNewsPostCapabilities = [:]
                        self.currentArticle = article
                        self.markNewsThreadRead(group: group, threadID: threadID, totalPosts: 1)
                        self.loadNewsReactions(group: group, posts: self.currentNewsThreadPosts, index: 0)
                        self.reloadNewsView()
                    case .failure:
                        self.newsLoadErrorMessage = LF("Thread could not be loaded: %@", Self.displayMessage(for: error))
                        self.reloadNewsView()
                    }
                }
            }
        }
    }

    func loadNewsThreadBodies(group: Data,
                                      posts: [LegacyNewsThreadPostSummary],
                                      index: Int,
                                      articles: [LegacyArticleReply]) {
        guard index < posts.count else {
            currentNewsThreadArticles = articles
            currentArticle = articles.first
            if let threadID = currentNewsThreadID {
                markNewsThreadRead(group: group, threadID: threadID, totalPosts: UInt32(clamping: posts.count))
            }
                loadNewsReactions(group: group, posts: posts, index: 0)
            reloadNewsView()
            return
        }
        client.requestArticle(group: group, articleID: posts[index].articleID) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(article):
                var next = articles
                next.append(article)
                self.loadNewsThreadBodies(group: group, posts: posts, index: index + 1, articles: next)
            case let .failure(error):
                let post = posts[index]
                if self.currentNewsPostCapabilities[post.articleID]?.isDeleted == true {
                    let placeholder = LegacyArticleReply(
                        metadata: LegacyArticleReplyMetadata(group: group,
                                                             articleID: post.articleID,
                                                             previousArticleID: LegacyArticle.noArticle,
                                                             nextArticleID: LegacyArticle.noArticle,
                                                             subject: Data(),
                                                             sender: post.sender,
                                                             date: post.date),
                        body: LegacyArticleBodyPayload(articleID: post.articleID,
                                                       reservedWord: UInt32.max,
                                                       text: Data(),
                                                       styleData: Data())
                    )
                    var next = articles
                    next.append(placeholder)
                    self.loadNewsThreadBodies(group: group, posts: posts, index: index + 1, articles: next)
                } else {
                    self.newsLoadErrorMessage = LF("Thread post %@ could not be loaded: %@", String(post.articleID), Self.displayMessage(for: error))
                    self.reloadNewsView()
                }
            }
        }
    }

    func editableNewsPostContent(from wire: Data) -> (text: String, attachments: [LegacyMediaReference.Segment]) {
        let source = CarrachoTextWire.string(from: wire)
        var text = ""
        var attachments: [LegacyMediaReference.Segment] = []
        for segment in LegacyMediaReference.segments(in: source) {
            switch segment {
            case let .text(value):
                text += value
            case .image, .youtube:
                attachments.append(segment)
            }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), attachments)
    }

    func editNewsPost(articleID: UInt32) {
        guard client.isConnected,
              let newsClient,
              let group = currentNewsCategory,
              let threadID = currentNewsThreadID,
              currentNewsPostCapabilities[articleID]?.canEdit == true,
              let article = currentNewsThreadArticles.first(where: { $0.metadata.articleID == articleID }),
              let window = view.window else {
            showError(L("Only the post owner or a News administrator can edit it."))
            return
        }

        let isThreadRoot = articleID == threadID
        let existing = editableNewsPostContent(from: article.body.text)
        let alert = NSAlert()
        alert.messageText = L("Edit Post")
        alert.informativeText = LF("Edit the post by %@.", Self.macRomanString(article.metadata.sender))
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))

        let accessoryWidth: CGFloat = 560
        let accessoryHeight: CGFloat = isThreadRoot ? 480 : 425
        let body = CarrachoMediaComposerTextView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: 235))
        body.isRichText = false
        body.isEditable = true
        body.isSelectable = true
        body.allowsUndo = true
        body.font = NSFont.systemFont(ofSize: newsFontSize)
        body.textContainerInset = NSSize(width: 8, height: 8)
        body.isHorizontallyResizable = false
        body.isVerticallyResizable = true
        body.autoresizingMask = [.width]
        body.textContainer?.widthTracksTextView = true
        body.string = existing.text

        let bodyScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: 235))
        bodyScroll.hasVerticalScroller = true
        bodyScroll.borderType = .bezelBorder
        bodyScroll.documentView = body
        bodyScroll.heightAnchor.constraint(equalToConstant: 235).isActive = true

        // Existing rich-media references must be editable, not silently preserved. Do not use
        // onRemoveImage here: clicking × only changes the draft. The server removes the News
        // reference (and an orphaned pool object) atomically after Save succeeds.
        let attachments = CarrachoComposerAttachmentStrip()
        for segment in existing.attachments {
            switch segment {
            case let .image(id):
                attachments.addExistingImage(id: id, preview: mediaCache?.image(id: id))
            case let .youtube(reference):
                attachments.addYouTube(reference)
            case .text:
                break
            }
        }

        let messageLabel = NSTextField(labelWithString: L("Message"))
        messageLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let emoji = EmojiPickerButton(editor: body)
        let messageRow = horizontalStack([messageLabel, NSView(), emoji], spacing: 8)
        let htmlHint = infoLabel(CarrachoHTMLText.editorHint)
        htmlHint.lineBreakMode = .byWordWrapping
        htmlHint.maximumNumberOfLines = 2
        htmlHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let preservedHint = infoLabel(existing.attachments.isEmpty
            ? L("This editor changes the text of the selected post.")
            : L("Attachments are shown below. Remove an attachment with ×; it is deleted only after Save succeeds."))
        preservedHint.lineBreakMode = .byWordWrapping
        preservedHint.maximumNumberOfLines = 2
        preservedHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let validationLabel = NSTextField(wrappingLabelWithString: "")
        validationLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        validationLabel.textColor = .systemRed
        validationLabel.maximumNumberOfLines = 2
        validationLabel.isHidden = true

        let subjectField: NSTextField? = isThreadRoot ? NSTextField(string: Self.macRomanString(article.metadata.subject)) : nil
        subjectField?.placeholderString = L("Thread subject")
        subjectField?.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let subjectLabel = isThreadRoot ? NSTextField(labelWithString: L("Subject")) : nil
        subjectLabel?.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        var views: [NSView] = []
        if let subjectLabel, let subjectField { views.append(contentsOf: [subjectLabel, subjectField]) }
        views.append(contentsOf: [messageRow, htmlHint, preservedHint, attachments, validationLabel, bodyScroll])
        let stack = verticalStack(views, spacing: 6)
        if let subjectLabel, let subjectField {
            stack.setCustomSpacing(4, after: subjectLabel)
            stack.setCustomSpacing(12, after: subjectField)
        }
        stack.setCustomSpacing(4, after: messageRow)
        stack.setCustomSpacing(4, after: htmlHint)
        stack.setCustomSpacing(6, after: preservedHint)
        stack.setCustomSpacing(8, after: attachments)
        stack.setCustomSpacing(8, after: validationLabel)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: accessoryHeight))
        stack.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: accessory.bottomAnchor),
        ])
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = subjectField ?? body

        let saveTarget = CarrachoClosureTarget { [weak alert, weak body, weak subjectField, weak validationLabel] _ in
            guard let alert, let body, let validationLabel else { return }
            let message = body.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = subjectField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if isThreadRoot, subject?.isEmpty != false {
                validationLabel.stringValue = message.isEmpty
                    ? L("Please enter a subject and a message.")
                    : L("Please enter a subject.")
                validationLabel.isHidden = false
                if let subjectField { alert.window.makeFirstResponder(subjectField) }
                NSSound.beep()
                return
            }
            guard !message.isEmpty || !attachments.tokens.isEmpty else {
                validationLabel.stringValue = L("Please enter a message or keep an attachment.")
                validationLabel.isHidden = false
                alert.window.makeFirstResponder(body)
                NSSound.beep()
                return
            }
            validationLabel.isHidden = true
            window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        }
        if let saveButton = alert.buttons.first {
            saveButton.target = saveTarget
            saveButton.action = #selector(CarrachoClosureTarget.invoke(_:))
        }

        alert.beginSheetModal(for: window) { [weak self, saveTarget] response in
            _ = saveTarget
            guard response == .alertFirstButtonReturn, let self else { return }
            let message = body.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let combined = self.composedRichText(message, attachments: attachments)
            let subjectString = isThreadRoot
                ? (subjectField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                : Self.macRomanString(article.metadata.subject)
            do {
                let subjectData = try CarrachoTextWire.encode(subjectString, maximumBytes: Int(UInt16.max))
                let bodyData = try CarrachoTextWire.encode(combined, maximumBytes: LegacyNewsTransfer.maximumArticleReceiverPayload)
                newsClient.editArticle(group: group, articleID: articleID, subject: subjectData, text: bodyData) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.appendLine("\n" + LF("Post %@ edited.", String(articleID)))
                        self.loadNewsIndex(group: group, openThreadID: threadID)
                    case let .failure(error):
                        self.showError(LF("Post could not be edited: %@", Self.displayMessage(for: error)))
                        self.reloadNewsView()
                    }
                }
            } catch {
                self.showError(L("The edited post exceeds the News protocol size limit after Unicode encoding."))
                self.reloadNewsView()
            }
        }
    }

    func deleteNewsPost(articleID: UInt32) {
        guard client.isConnected,
              let group = currentNewsCategory,
              let threadID = currentNewsThreadID,
              currentNewsPostCapabilities[articleID]?.canDelete == true,
              let window = view.window else {
            showError(L("Only the post owner or a News administrator can delete it."))
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Delete Post")
        alert.informativeText = L("Delete this post? Replies stay in the thread, but this post's text and reactions will be removed.")
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.client.deleteNewsPost(group: group, articleID: articleID) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.appendLine("\n" + LF("Post %@ deleted.", String(articleID)))
                    self.loadNewsIndex(group: group, openThreadID: threadID)
                case let .failure(error):
                    self.showError(LF("Post could not be deleted: %@", Self.displayMessage(for: error)))
                    self.reloadNewsView()
                }
            }
        }
    }

    @objc func deleteCurrentArticle(_ sender: Any?) {
        guard client.isConnected, let group = currentNewsCategory,
              let threadID = currentNewsThreadID,
              let thread = currentNewsThreads.first(where: { $0.threadID == threadID }),
              let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Delete Thread")
        alert.informativeText = LF("Delete “%@” and all of its replies?", Self.macRomanString(thread.subject))
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.newsDeleteButton.isEnabled = false
            self.client.deleteArticle(group: group, articleID: threadID) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.appendLine("\n" + LF("Thread %@ deleted.", String(threadID)))
                    self.loadNewsIndex(group: group)
                case let .failure(error):
                    self.appendLine("\n" + LF("Thread could not be deleted: %@", Self.displayMessage(for: error)))
                    self.reloadNewsView()
                }
            }
        }
    }

    func newsAvatarImage(for sender: Data) -> NSImage? {
        if let user = liveUsers.values.first(where: { $0.nickname == sender }) {
            if let image = AvatarArtwork.userImage(picture: user.picture,
                                                   isLegacyTransport: user.isLegacyTransport) {
                return image
            }
        }
        return AvatarArtwork.defaultImage()
    }

    func newsAvatarAttachment(for sender: Data, size: CGFloat = 28) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = newsAvatarImage(for: sender)
        attachment.bounds = NSRect(x: 0, y: -6, width: size, height: size)
        return NSAttributedString(attachment: attachment)
    }

    func reloadNewsView() {
        let articleScroll = newsArticleTextView.enclosingScrollView
        let sameRenderedThread =
            renderedNewsCategory == currentNewsCategory
            && renderedNewsThreadID == currentNewsThreadID
            && renderedNewsReadScope == newsReadScope
        let preservedArticleOrigin = sameRenderedThread
            ? articleScroll?.contentView.bounds.origin
            : nil

        reloadNewsTablesPreservingSelection()
        let connected = client.isConnected
        let activeCategory = selectedRemoteNewsgroup ?? currentNewsCategory
        newsCategoryHeaderLabel.stringValue = LF("CATEGORIES · %@", String(lastNewsgroups.count))
        if let category = currentNewsCategory {
            newsThreadsHeaderLabel.stringValue = LF("Topics in %@", Self.macRomanString(category))
            newsBreadcrumbLabel.stringValue = LF("%@ / Topic", Self.macRomanString(category))
        } else {
            newsThreadsHeaderLabel.stringValue = L("Topics")
            newsBreadcrumbLabel.stringValue = L("News")
        }
        newsNewCategoryButton.isHidden = !canManageRemoteNewsgroups
        newsNewCategoryButton.isEnabled = connected && canManageRemoteNewsgroups
        newsLoadButton.isEnabled = connected && newsClient != nil && activeCategory != nil
        newsPostButton.isEnabled = connected && newsClient != nil && activeCategory != nil && canPostRemoteNews
        newsDeleteButton.isEnabled = connected && canManageRemoteNewsgroups && currentNewsThreadID != nil
        newsThreadActionsButton.isEnabled = currentNewsThreadID != nil
        newsThreadSortPopup.isEnabled = !currentNewsThreads.isEmpty
        updateInlineNewsReplyState()

        let selectedThread = currentNewsThreadID.flatMap { id in currentNewsThreads.first(where: { $0.threadID == id }) }
        if let thread = selectedThread {
            let subject = Self.macRomanString(thread.subject)
            let sender = Self.macRomanString(thread.sender)
            let started = Self.dateString(Date.fromLegacyMacTimestamp(thread.date))
            newsTitleLabel.stringValue = subject
            newsThreadMetaLabel.stringValue = thread.replyCount == 1 ? LF("Started by %@ · %@ · %@ reply", sender, started, String(thread.replyCount)) : LF("Started by %@ · %@ · %@ replies", sender, started, String(thread.replyCount))
            newsTitleLabel.toolTip = subject
        } else if let category = currentNewsCategory {
            newsTitleLabel.stringValue = currentNewsThreads.isEmpty ? L("No topics yet") : L("Select a topic")
            newsThreadMetaLabel.stringValue = currentNewsThreads.count == 1 ? LF("%@ topic in %@", String(currentNewsThreads.count), Self.macRomanString(category)) : LF("%@ topics in %@", String(currentNewsThreads.count), Self.macRomanString(category))
            newsTitleLabel.toolTip = nil
        } else {
            newsTitleLabel.stringValue = lastNewsgroups.isEmpty ? L("No News categories") : L("Select a category")
            newsThreadMetaLabel.stringValue = connected ? L("Choose a category to browse its topics.") : L("Connect to a server to load News.")
            newsTitleLabel.toolTip = nil
        }

        guard !currentNewsThreadArticles.isEmpty else {
            if let newsLoadErrorMessage {
                newsArticleTextView.string = newsLoadErrorMessage
            } else if currentNewsThreadID != nil {
                if newsArticleTextView.string.isEmpty { newsArticleTextView.string = L("Loading conversation…") }
            } else if lastNewsgroups.isEmpty {
                newsArticleTextView.string = canManageRemoteNewsgroups
                    ? L("No News categories exist yet. Create a category, then start the first topic.")
                    : L("No News categories are available on this server.")
            } else if currentNewsCategory == nil {
                newsArticleTextView.string = L("Select a category on the left.")
            } else if currentNewsThreads.isEmpty {
                newsArticleTextView.string = L("This category has no topics yet. Use New Thread to start the conversation.")
            } else {
                newsArticleTextView.string = L("Select a topic on the left to read the conversation.")
            }
            renderedNewsCategory = currentNewsCategory
            renderedNewsThreadID = currentNewsThreadID
            renderedNewsReadScope = newsReadScope
            if !sameRenderedThread {
                newsArticleTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
            return
        }

        if let group = currentNewsCategory,
           let threadID = currentNewsThreadID,
           let root = currentNewsThreadArticles.first(where: { $0.metadata.articleID == threadID }) {
            newsThreadPreviewsByCategory[group, default: [:]][threadID] = newsThreadPreviewText(from: root)
        }

        let output = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: newsFontSize)
        let metaFont = NSFont.systemFont(ofSize: max(10.5, newsFontSize - 1))
        let actionFont = NSFont.systemFont(ofSize: max(10.5, newsFontSize - 1), weight: .medium)
        let authorFont = NSFont.systemFont(ofSize: max(12, newsFontSize), weight: .semibold)
        for (index, article) in currentNewsThreadArticles.enumerated() {
            let postStart = output.length
            let metadata = article.metadata
            let articleID = metadata.articleID
            let sender = Self.macRomanString(metadata.sender)
            let date = Self.dateString(Date.fromLegacyMacTimestamp(metadata.date))
            let paragraph = NSMutableParagraphStyle()
            paragraph.headIndent = 0
            paragraph.firstLineHeadIndent = 0
            paragraph.tailIndent = -12
            paragraph.paragraphSpacing = 4

            output.append(newsAvatarAttachment(for: metadata.sender))
            output.append(NSAttributedString(
                string: "  \(sender)",
                attributes: [.font: authorFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            ))
            if articleID == currentNewsThreadID {
                output.append(NSAttributedString(
                    string: "  " + L("AUTHOR"),
                    attributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
                                 .foregroundColor: CarrachoTheme.selection,
                                 .paragraphStyle: paragraph]
                ))
            }
            output.append(NSAttributedString(
                string: "\n\(date)\n",
                attributes: [.font: metaFont, .foregroundColor: CarrachoTheme.secondaryText, .paragraphStyle: paragraph]
            ))

            let deleted = currentNewsPostCapabilities[articleID]?.isDeleted == true
            if deleted {
                output.append(NSAttributedString(
                    string: L("This post was deleted."),
                    attributes: [.font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: newsFontSize), toHaveTrait: .italicFontMask),
                                 .foregroundColor: CarrachoTheme.secondaryText,
                                 .paragraphStyle: paragraph]
                ))
            } else {
                let renderedBody: NSAttributedString
                if let category = currentNewsCategory {
                    renderedBody = mediaAttributedString(fromWire: article.body.text, context: .news(category),
                                                         baseFont: bodyFont, maximumWidth: 620, maximumHeight: 420) { [weak self] in
                        self?.reloadNewsView()
                    }
                } else {
                    renderedBody = CarrachoHTMLText.attributedString(fromWire: article.body.text, baseFont: bodyFont)
                }
                let body = NSMutableAttributedString(attributedString: renderedBody)
                if body.length > 0 {
                    let wholeBody = NSRange(location: 0, length: body.length)
                    var quoteRanges: [NSRange] = []
                    // The HTML importer exposes blockquotes as the public NSPresentationIntent
                    // attribute. Swift hides that Obj-C class name on older deployment targets,
                    // so inspect its stable public intentKind value (BlockQuote == 6).
                    let presentationKey = NSAttributedString.Key("NSPresentationIntent")
                    body.enumerateAttribute(presentationKey, in: wholeBody) { value, range, _ in
                        guard let intent = value as? NSObject,
                              (intent.value(forKey: "intentKind") as? NSNumber)?.intValue == 6 else { return }
                        if var last = quoteRanges.last, NSMaxRange(last) == range.location {
                            quoteRanges.removeLast()
                            last.length += range.length
                            quoteRanges.append(last)
                        } else {
                            quoteRanges.append(range)
                        }
                    }

                    body.addAttribute(.paragraphStyle, value: paragraph, range: wholeBody)
                    for range in quoteRanges {
                        body.removeAttribute(.backgroundColor, range: range)
                        body.addAttribute(.carrachoQuoteBlock, value: true, range: range)
                        let quoteParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
                        quoteParagraph.headIndent = 18
                        quoteParagraph.firstLineHeadIndent = 18
                        quoteParagraph.tailIndent = -18
                        quoteParagraph.paragraphSpacingBefore = 5
                        quoteParagraph.paragraphSpacing = 5
                        body.addAttribute(.paragraphStyle, value: quoteParagraph, range: range)
                    }
                }
                output.append(body)
            }

            if !deleted {
                output.append(NSAttributedString(string: "\n\n", attributes: [.paragraphStyle: paragraph]))
                func appendAction(_ title: String, scheme: String) {
                    guard let url = URL(string: "\(scheme)://\(articleID)") else { return }
                    output.append(NSAttributedString(
                        string: title,
                        attributes: [.font: actionFont, .foregroundColor: CarrachoTheme.selection,
                                     .link: url, .paragraphStyle: paragraph]
                    ))
                }
                appendAction(L("❝ Quote"), scheme: "carracho-news-quote")
                if currentNewsPostCapabilities[articleID]?.canEdit == true {
                    output.append(NSAttributedString(string: "    ", attributes: [.paragraphStyle: paragraph]))
                    appendAction(L("✎ Edit"), scheme: "carracho-news-edit")
                }
                if newsReactionsSupported {
                    output.append(NSAttributedString(string: "    ", attributes: [.paragraphStyle: paragraph]))
                    appendAction(L("☺ React"), scheme: "carracho-news-react")
                }
                if currentNewsPostCapabilities[articleID]?.canDelete == true {
                    output.append(NSAttributedString(string: "    ", attributes: [.paragraphStyle: paragraph]))
                    appendAction("•••", scheme: "carracho-news-post-menu")
                }

                let reactions = currentNewsReactions[articleID] ?? []
                let visibleReactions = reactions.compactMap { summary -> (LegacyNewsReactionSummary, LegacyNewsReactionKind)? in
                    guard let kind = LegacyNewsReactionKind(rawValue: summary.kind), summary.count > 0 else { return nil }
                    return (summary, kind)
                }
                if !visibleReactions.isEmpty {
                    output.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
                    for (offset, item) in visibleReactions.enumerated() {
                        if offset > 0 { output.append(NSAttributedString(string: "   ", attributes: [.paragraphStyle: paragraph])) }
                        let summary = item.0, kind = item.1
                        let text = summary.reactedByCurrentUser
                            ? "\(kind.emoji) \(summary.count) ✓"
                            : "\(kind.emoji) \(summary.count)"
                        var attributes: [NSAttributedString.Key: Any] = [
                            .font: metaFont, .foregroundColor: CarrachoTheme.secondaryText, .paragraphStyle: paragraph,
                        ]
                        if !summary.userNames.isEmpty {
                            let names = summary.userNames.map { name in
                                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                                return trimmed.isEmpty ? L("Unknown user") : trimmed
                            }
                            attributes[.carrachoToolTipText] = LF("Reacted by:\n%@", names.joined(separator: "\n"))
                        }
                        output.append(NSAttributedString(string: text, attributes: attributes))
                    }
                }
            }

            // Give every post some breathing room and mark the whole range so the display
            // text view can paint alternating full-width backgrounds, matching Files/Transfers.
            if index + 1 < currentNewsThreadArticles.count {
                output.append(NSAttributedString(string: "\n\n", attributes: [.font: bodyFont]))
            }
            let postRange = NSRange(location: postStart, length: output.length - postStart)
            if postRange.length > 0 {
                output.addAttribute(.carrachoPostBackground, value: index % 2 != 0, range: postRange)
            }
        }
        newsArticleTextView.textStorage?.setAttributedString(output)

        renderedNewsCategory = currentNewsCategory
        renderedNewsThreadID = currentNewsThreadID
        renderedNewsReadScope = newsReadScope

        if let origin = preservedArticleOrigin, let scroll = articleScroll {
            if let layoutManager = newsArticleTextView.layoutManager,
               let textContainer = newsArticleTextView.textContainer {
                layoutManager.ensureLayout(for: textContainer)
            }
            let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
            let y = min(max(0, origin.y), maxY)
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            // A newly selected topic should still start at its first post.
            newsArticleTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }

    func newsBadgeLabel(_ count: Int) -> NSTextField {
        let badge = NSTextField(labelWithString: String(count))
        badge.font = .systemFont(ofSize: 10.5, weight: .semibold)
        badge.alignment = .center
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = CarrachoTheme.selection.cgColor
        badge.layer?.cornerRadius = 8
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: 17),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])
        return badge
    }

    func newsCategoryCell(for group: Data) -> NSView {
        let unread = newsUnreadCount(group: group)
        let iconView = NSImageView()
        iconView.image = symbolImage("folder.fill", fallback: NSImage.folderName)
        iconView.contentTintColor = unread > 0 ? CarrachoTheme.selection : CarrachoTheme.secondaryText
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
        ])

        let title = NSTextField(labelWithString: Self.macRomanString(group))
        title.font = .systemFont(ofSize: newsFontSize, weight: unread > 0 ? .semibold : .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let total: UInt64? = newsThreadsByCategory[group].map { threads in
            threads.reduce(UInt64(0)) { $0 + UInt64($1.replyCount) + 1 }
        }
        let count = NSTextField(labelWithString: total.map { $0 == 1 ? LF("%@ post", String($0)) : LF("%@ posts", String($0)) } ?? L("Posts …"))
        count.font = .systemFont(ofSize: max(10.5, newsFontSize - 2))
        count.textColor = CarrachoTheme.secondaryText
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        var trailing: [NSView] = [count]
        if unread > 0 { trailing.append(newsBadgeLabel(unread)) }
        let row = horizontalStack([iconView, title, NSView()] + trailing, spacing: 7)
        row.setAccessibilityLabel(LF("%@, %@", Self.macRomanString(group), count.stringValue))
        return row
    }

    func newsThreadSubjectCell(for thread: LegacyNewsThreadSummary) -> NSView {
        let unread = currentNewsCategory.map { newsUnreadCount(group: $0, thread: thread) } ?? 0
        let title = NSTextField(labelWithString: Self.macRomanString(thread.subject))
        title.font = .systemFont(ofSize: newsFontSize, weight: unread > 0 ? .semibold : .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var items: [NSView] = [title]
        if unread > 0 { items.append(newsBadgeLabel(unread)) }
        let row = horizontalStack(items, spacing: 6)
        row.setAccessibilityLabel(thread.replyCount == 1 ? LF("%@, by %@, %@ reply", Self.macRomanString(thread.subject), Self.macRomanString(thread.sender), String(thread.replyCount)) : LF("%@, by %@, %@ replies", Self.macRomanString(thread.subject), Self.macRomanString(thread.sender), String(thread.replyCount)))
        return row
    }

    func newsThreadCell(for thread: LegacyNewsThreadSummary) -> NSView {
        let unread = currentNewsCategory.map { newsUnreadCount(group: $0, thread: thread) } ?? 0
        let title = NSTextField(labelWithString: Self.macRomanString(thread.subject))
        title.font = .systemFont(ofSize: newsFontSize, weight: unread > 0 ? .semibold : .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var titleItems: [NSView] = [title]
        if unread > 0 { titleItems.append(newsBadgeLabel(unread)) }
        let titleRow = horizontalStack(titleItems, spacing: 6)

        let author = NSTextField(labelWithString: Self.macRomanString(thread.sender))
        author.font = .systemFont(ofSize: max(10.5, newsFontSize - 1), weight: .medium)
        author.textColor = CarrachoTheme.secondaryText
        author.lineBreakMode = .byTruncatingTail
        author.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let group = currentNewsCategory
        let previewText = group.flatMap { newsThreadPreviewsByCategory[$0]?[thread.threadID] } ?? L("Loading preview…")
        let preview = NSTextField(labelWithString: previewText)
        preview.font = .systemFont(ofSize: max(10.5, newsFontSize - 1))
        preview.textColor = CarrachoTheme.secondaryText
        preview.lineBreakMode = .byTruncatingTail
        preview.maximumNumberOfLines = 1
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let replies = thread.replyCount == 1 ? LF("%@ reply", String(thread.replyCount)) : LF("%@ replies", String(thread.replyCount))
        let activity = Self.dateString(Date.fromLegacyMacTimestamp(thread.latestDate))
        let detail = NSTextField(labelWithString: "\(activity)  ·  \(replies)")
        detail.font = .systemFont(ofSize: max(10, newsFontSize - 2))
        detail.textColor = CarrachoTheme.tertiaryText
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = verticalStack([titleRow, author, preview, detail], spacing: 2)
        stack.setAccessibilityLabel(LF("%@, by %@, %@", Self.macRomanString(thread.subject), Self.macRomanString(thread.sender), replies))
        if let group { ensureNewsThreadPreview(group: group, thread: thread) }
        return stack
    }
    @objc func showFlatNewsManager(_ sender: Any?) {
        reloadFlatNewsManager(presentIfNeeded: true)
    }

    func reloadFlatNewsManager(presentIfNeeded: Bool) {
        guard client.isConnected else { return }
        client.requestFlatNews { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                self.appendLine("\n" + LF("Flat News could not be loaded: %@", Self.displayMessage(for: error)))
            case let .success(items):
                if let manager = self.flatNewsWindowController, manager.window?.isVisible == true {
                    manager.update(items: items)
                    if presentIfNeeded { manager.show(relativeTo: self.view.window) }
                    return
                }
                guard presentIfNeeded else { return }
                let manager = FlatNewsWindowController(items: items, fontSize: self.newsFontSize)
                manager.onPost = { [weak self] data, completion in
                    guard let self else {
                        completion(.failure(LegacyControlClientError.connectionClosed))
                        return
                    }
                    self.client.postFlatNews(data) { [weak self] result in
                        completion(result)
                        if case .success = result {
                            self?.reloadFlatNewsManager(presentIfNeeded: false)
                        }
                    }
                }
                manager.onDelete = { [weak self] maximum, parent in
                    self?.presentFlatNewsDeletePrompt(maximum: maximum, parent: parent)
                }
                manager.onClear = { [weak self] parent in
                    self?.confirmClearFlatNews(parent: parent)
                }
                manager.onFinish = { [weak self, weak manager] in
                    guard let self else { return }
                    if self.flatNewsWindowController === manager { self.flatNewsWindowController = nil }
                }
                self.flatNewsWindowController = manager
                manager.show(relativeTo: self.view.window)
            }
        }
    }

    func presentFlatNewsDeletePrompt(maximum: Int, parent: NSWindow) {
        guard maximum > 0 else { return }
        let alert = NSAlert()
        alert.messageText = L("Delete Flat News")
        alert.informativeText = LF("Enter the 1-based entry number (1…%@).", String(maximum))
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        let field = NSTextField(string: "1")
        field.frame = NSRect(x: 0, y: 0, width: 160, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn,
                  let value = UInt32(field.stringValue), value > 0, value <= UInt32(maximum) else { return }
            self.client.deleteFlatNews(wireIndex: value) { [weak self] result in
                switch result {
                case .success:
                    self?.reloadFlatNewsManager(presentIfNeeded: false)
                case let .failure(error):
                    self?.appendLine("\n" + LF("Flat News could not be deleted: %@", Self.displayMessage(for: error)))
                }
            }
        }
    }

    func confirmClearFlatNews(parent: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Clear all Flat News?")
        alert.informativeText = L("This removes the complete flat-news stream.")
        alert.addButton(withTitle: L("Clear All"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.client.clearFlatNews { [weak self] result in
                switch result {
                case .success:
                    self?.reloadFlatNewsManager(presentIfNeeded: false)
                case let .failure(error):
                    self?.appendLine("\n" + LF("Flat News could not be cleared: %@", Self.displayMessage(for: error)))
                }
            }
        }
    }

}
