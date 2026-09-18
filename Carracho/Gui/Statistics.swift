import Cocoa
import QuickLookUI

// MARK: - Statistics

extension ViewController {

    func makeStatisticsAdminPage() -> NSView {
        let page = NSView()

        func metricCard(title: String, symbol: String, value: NSTextField, detail: String) -> NSView {
            let card = CarrachoCardView()
            card.fillColor = CarrachoTheme.card
            card.cornerRadius = 8
            card.translatesAutoresizingMaskIntoConstraints = false
            card.heightAnchor.constraint(equalToConstant: 112).isActive = true

            let icon = symbolView(symbol, size: 15, tint: CarrachoTheme.accent)
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
            titleLabel.textColor = CarrachoTheme.secondaryText
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.toolTip = title
            let heading = horizontalStack([icon, titleLabel, NSView()], spacing: 7)

            value.font = .monospacedDigitSystemFont(ofSize: 25, weight: .semibold)
            value.textColor = .labelColor
            value.alignment = .left
            value.lineBreakMode = .byTruncatingTail
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            value.setAccessibilityLabel(title)

            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 10.5)
            detailLabel.textColor = CarrachoTheme.tertiaryText
            detailLabel.lineBreakMode = .byTruncatingTail
            detailLabel.toolTip = detail

            let stack = verticalStack([heading, value, detailLabel], spacing: 5)
            stack.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 11),
                stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -11),
                stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -9),
            ])
            return card
        }

        func groupRow(title: String, symbol: String, value: NSTextField) -> NSView {
            let icon = symbolView(symbol, size: 15, tint: CarrachoTheme.accent)
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12.5, weight: .medium)
            value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            value.alignment = .right
            value.setAccessibilityLabel(title)
            value.translatesAutoresizingMaskIntoConstraints = false
            value.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
            let row = horizontalStack([icon, label, NSView(), value], spacing: 10)
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
            return row
        }

        let title = NSTextField(labelWithString: L("Statistics"))
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        let subtitle = NSTextField(labelWithString: L("Server counters and current connections"))
        subtitle.font = .systemFont(ofSize: 12.5)
        subtitle.textColor = CarrachoTheme.secondaryText
        let titleStack = verticalStack([title, subtitle], spacing: 3)

        statsRefreshButton.target = self
        statsRefreshButton.action = #selector(reloadStatisticsAdministrationPressed(_:))
        statsRefreshButton.bezelStyle = .rounded
        statsRefreshButton.image = symbolImage("arrow.clockwise", fallback: NSImage.refreshTemplateName)
        statsRefreshButton.imagePosition = .imageLeading
        statsRefreshButton.toolTip = L("Reload all seven displayed counters from the current server")
        statsRefreshButton.setAccessibilityLabel(L("Refresh statistics"))
        statsLoadingIndicator.style = .spinning
        statsLoadingIndicator.controlSize = .small
        statsLoadingIndicator.isDisplayedWhenStopped = false
        statsLoadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statsLoadingIndicator.widthAnchor.constraint(equalToConstant: 16),
            statsLoadingIndicator.heightAnchor.constraint(equalToConstant: 16),
        ])
        let headerActions = horizontalStack([statsLoadingIndicator, statsRefreshButton], spacing: 7)
        let header = horizontalStack([titleStack, NSView(), headerActions], spacing: 12)

        let metrics = ResponsiveStatisticsGridView(cards: [
            metricCard(title: L("Hits"), symbol: "rectangle.portrait.and.arrow.right", value: statsHitsValue,
                       detail: L("Persistent successful-login counter")),
            metricCard(title: L("Currently connected"), symbol: "person.2.fill", value: statsCurrentUsersValue,
                       detail: L("Server-reported current sessions")),
            metricCard(title: L("Connection peak"), symbol: "chart.line.uptrend.xyaxis", value: statsConnectionPeakValue,
                       detail: L("Persistent maximum connected count")),
            metricCard(title: L("Incorrect logins"), symbol: "lock.slash", value: statsIncorrectLoginsValue,
                       detail: L("Persistent rejected-login counter")),
        ])

        let groupsCard = CarrachoCardView()
        groupsCard.fillColor = CarrachoTheme.card
        groupsCard.cornerRadius = 8
        let groupsTitleIcon = symbolView("person.3.fill", size: 16, tint: CarrachoTheme.accent)
        let groupsTitle = NSTextField(labelWithString: L("Connected user groups"))
        groupsTitle.font = .systemFont(ofSize: 13.5, weight: .semibold)
        let groupsSubtitle = NSTextField(labelWithString: L("Current server-reported session classes"))
        groupsSubtitle.font = .systemFont(ofSize: 10.5)
        groupsSubtitle.textColor = CarrachoTheme.secondaryText
        groupsSubtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let groupsHeader = horizontalStack([groupsTitleIcon, groupsTitle, NSView(), groupsSubtitle], spacing: 8)
        let groupRows = verticalStack([
            groupRow(title: L("Administrators"), symbol: "crown.fill", value: statsAdminsValue),
            CarrachoDividerView(),
            groupRow(title: L("Account holders"), symbol: "person.fill", value: statsAccountHoldersValue),
            CarrachoDividerView(),
            groupRow(title: L("Guests"), symbol: "person.2.fill", value: statsGuestsValue),
        ], spacing: 0)
        let groupsNote = infoLabel(L("These three values are queried independently from the server. The total above uses the server's separate “Currently connected” field; Carracho does not invent or rebalance missing values."))
        groupsNote.maximumNumberOfLines = 3
        let groupsStack = verticalStack([groupsHeader, CarrachoDividerView(), groupRows, CarrachoDividerView(), groupsNote], spacing: 9)
        groupsStack.translatesAutoresizingMaskIntoConstraints = false
        groupsCard.addSubview(groupsStack)
        NSLayoutConstraint.activate([
            groupsStack.leadingAnchor.constraint(equalTo: groupsCard.leadingAnchor, constant: 12),
            groupsStack.trailingAnchor.constraint(equalTo: groupsCard.trailingAnchor, constant: -12),
            groupsStack.topAnchor.constraint(equalTo: groupsCard.topAnchor, constant: 11),
            groupsStack.bottomAnchor.constraint(equalTo: groupsCard.bottomAnchor, constant: -11),
        ])

        statsHelpDisclosureButton.target = self
        statsHelpDisclosureButton.action = #selector(toggleStatisticsHelp(_:))
        statsHelpDisclosureButton.isBordered = false
        statsHelpDisclosureButton.alignment = .left
        statsHelpDisclosureButton.font = .systemFont(ofSize: 12.5, weight: .semibold)
        statsHelpDisclosureButton.contentTintColor = .labelColor
        statsHelpDisclosureButton.imagePosition = .imageLeading
        statsHelpDisclosureButton.setAccessibilityLabel(L("About these statistics counters"))

        let helpHits = infoLabel(L("• Hits: both bundled server implementations increment this persisted field after a successful login. It is not a time-windowed metric."))
        let helpPeak = infoLabel(L("• Connection peak: persisted maximum of the server's connected-session counters. No history or timestamp is stored with the peak."))
        let helpIncorrect = infoLabel(L("• Incorrect logins: persisted count of rejected authentication attempts. A nonzero value alone is not treated as an active warning."))
        let helpGroups = infoLabel(L("• Administrators, account holders and guests are current session counters selected by authenticated account mode and decremented on disconnect. They are stored by the server even though they describe current state."))
        for note in [helpHits, helpPeak, helpIncorrect, helpGroups] { note.maximumNumberOfLines = 4 }
        let helpBody = verticalStack([helpHits, helpPeak, helpIncorrect, helpGroups], spacing: 7)
        statsHelpBody = helpBody
        let collapsed = UserDefaults.standard.object(forKey: Self.statisticsHelpCollapsedDefaultsKey) == nil
            ? true : UserDefaults.standard.bool(forKey: Self.statisticsHelpCollapsedDefaultsKey)
        helpBody.isHidden = collapsed
        updateStatisticsHelpDisclosure(collapsed: collapsed)
        let helpCard = CarrachoCardView()
        helpCard.fillColor = CarrachoTheme.card
        helpCard.cornerRadius = 8
        let helpStack = verticalStack([statsHelpDisclosureButton, helpBody], spacing: 8)
        helpStack.translatesAutoresizingMaskIntoConstraints = false
        helpCard.addSubview(helpStack)
        NSLayoutConstraint.activate([
            helpStack.leadingAnchor.constraint(equalTo: helpCard.leadingAnchor, constant: 12),
            helpStack.trailingAnchor.constraint(equalTo: helpCard.trailingAnchor, constant: -12),
            helpStack.topAnchor.constraint(equalTo: helpCard.topAnchor, constant: 10),
            helpStack.bottomAnchor.constraint(equalTo: helpCard.bottomAnchor, constant: -10),
        ])

        statsStatusLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        statsStatusLabel.textColor = CarrachoTheme.secondaryText
        statsStatusLabel.lineBreakMode = .byTruncatingTail
        let statusRow = horizontalStack([statsStatusLabel, NSView()], spacing: 8)

        let content = verticalStack([header, metrics, groupsCard, helpCard, CarrachoDividerView(), statusRow], spacing: 14)
        content.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = CarrachoTheme.conferenceTranscriptBackground
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = CarrachoFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.addSubview(content)
        page.addSubview(scroll)

        let maxWidth = content.widthAnchor.constraint(lessThanOrEqualToConstant: 1040)
        let fillWidth = content.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -20)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: page.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -4),

            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
            maxWidth,
            fillWidth,
        ])

        updateStatisticsPresentation()
        return page
    }

    func currentStatisticsSourceKey() -> String {
        if client.isConnected {
            if let id = activeBookmarkConnectionID { return "remote:\(id.uuidString.lowercased())" }
            return "remote:\(hostField.stringValue.lowercased()):\(portField.stringValue):\(loginField.stringValue.lowercased())"
        }
        return "local"
    }

    func formattedStatisticsValue(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    func localStatisticsSnapshot(_ stats: ServerStatistics) -> StatisticsAdminSnapshot {
        StatisticsAdminSnapshot(hits: stats.hits,
                                currentlyConnected: stats.adminsConnected + stats.accountHoldersConnected + stats.guestsConnected,
                                connectionPeak: stats.connectionPeak,
                                incorrectLogins: stats.incorrectLogins,
                                adminsConnected: stats.adminsConnected,
                                accountHoldersConnected: stats.accountHoldersConnected,
                                guestsConnected: stats.guestsConnected)
    }

    func decodeStatisticsValue(_ data: Data?) -> UInt64? {
        guard let data, data.count == 4 else { return nil }
        do {
            var cursor = LegacyByteCursor(data)
            let value = try cursor.readUInt32BE()
            try cursor.requireEnd()
            return UInt64(value)
        } catch {
            return nil
        }
    }

    func updateStatisticsHelpDisclosure(collapsed: Bool) {
        statsHelpDisclosureButton.image = symbolImage(collapsed ? "chevron.right" : "chevron.down",
                                                      fallback: collapsed ? NSImage.rightFacingTriangleTemplateName : NSImage.touchBarGoDownTemplateName)
        statsHelpDisclosureButton.toolTip = collapsed ? L("Show counter explanations") : L("Hide counter explanations")
    }

    @objc func toggleStatisticsHelp(_ sender: Any?) {
        guard let body = statsHelpBody else { return }
        let collapsed = !body.isHidden
        body.isHidden = collapsed
        UserDefaults.standard.set(collapsed, forKey: Self.statisticsHelpCollapsedDefaultsKey)
        updateStatisticsHelpDisclosure(collapsed: collapsed)
    }

    func updateStatisticsPresentation() {
        let snapshot = statisticsSnapshot
        statsHitsValue.stringValue = formattedStatisticsValue(snapshot?.hits)
        statsCurrentUsersValue.stringValue = formattedStatisticsValue(snapshot?.currentlyConnected)
        statsConnectionPeakValue.stringValue = formattedStatisticsValue(snapshot?.connectionPeak)
        statsIncorrectLoginsValue.stringValue = formattedStatisticsValue(snapshot?.incorrectLogins)
        statsAdminsValue.stringValue = formattedStatisticsValue(snapshot?.adminsConnected)
        statsAccountHoldersValue.stringValue = formattedStatisticsValue(snapshot?.accountHoldersConnected)
        statsGuestsValue.stringValue = formattedStatisticsValue(snapshot?.guestsConnected)

        let canRefresh = client.isConnected ? canAccessAdministrativeWorkspace(.statistics) : serverBackend != nil
        statsRefreshButton.isEnabled = canRefresh && !statisticsLoading
        if statisticsLoading {
            statsLoadingIndicator.startAnimation(nil)
        } else {
            statsLoadingIndicator.stopAnimation(nil)
        }

        if let override = statisticsStatusOverride {
            statsStatusLabel.stringValue = override
            statsStatusLabel.textColor = statisticsStatusColor ?? CarrachoTheme.secondaryText
        } else if statisticsLoading {
            statsStatusLabel.stringValue = snapshot == nil ? L("Loading statistics…") : L("Refreshing statistics… Existing values remain visible until the server replies.")
            statsStatusLabel.textColor = CarrachoTheme.secondaryText
        } else if let refreshed = statisticsLastSuccessfulRefresh {
            let time = DateFormatter.localizedString(from: refreshed, dateStyle: .none, timeStyle: .medium)
            statsStatusLabel.stringValue = statisticsStale ? LF("Last successful refresh %@ · values may be stale", time) : LF("Updated %@", time)
            statsStatusLabel.textColor = statisticsStale ? CarrachoTheme.warning : CarrachoTheme.secondaryText
        } else if snapshot == nil {
            statsStatusLabel.stringValue = client.isConnected ? L("Statistics have not been loaded yet.") : L("Connect to a server with Statistics permission to load these counters.")
            statsStatusLabel.textColor = CarrachoTheme.secondaryText
        } else {
            statsStatusLabel.stringValue = statisticsStale ? L("Values may be stale.") : L("Statistics loaded.")
            statsStatusLabel.textColor = statisticsStale ? CarrachoTheme.warning : CarrachoTheme.secondaryText
        }
        statsStatusLabel.toolTip = statsStatusLabel.stringValue
    }

    @objc func reloadStatisticsAdministrationPressed(_ sender: Any?) {
        reloadStatisticsAdministration()
    }

    func reloadStatisticsAdministration() {
        guard !statisticsLoading else { return }
        let sourceKey = currentStatisticsSourceKey()
        if statisticsSourceKey != sourceKey {
            statisticsRefreshGeneration &+= 1
            statisticsSourceKey = sourceKey
            statisticsSnapshot = nil
            statisticsLastSuccessfulRefresh = nil
            statisticsStale = false
            statisticsStatusOverride = nil
            statisticsStatusColor = nil
        }

        if !client.isConnected {
            guard let backend = serverBackend else {
                statisticsSnapshot = nil
                statisticsLastSuccessfulRefresh = nil
                statisticsStale = false
                statisticsStatusOverride = L("Local server statistics are unavailable.")
                statisticsStatusColor = .systemRed
                updateStatisticsPresentation()
                return
            }
            let stats = backend.snapshot().statistics
            localServerState.statistics = stats
            statisticsSnapshot = localStatisticsSnapshot(stats)
            statisticsLastSuccessfulRefresh = Date()
            statisticsStale = false
            statisticsStatusOverride = nil
            statisticsStatusColor = nil
            updateStatisticsPresentation()
            return
        }

        guard canAccessAdministrativeWorkspace(.statistics) else {
            statisticsStale = statisticsSnapshot != nil
            statisticsStatusOverride = L("This account does not have permission to view server statistics.")
            statisticsStatusColor = .systemRed
            updateStatisticsPresentation()
            return
        }

        statisticsLoading = true
        statisticsStatusOverride = nil
        statisticsStatusColor = nil
        statisticsRefreshGeneration &+= 1
        let generation = statisticsRefreshGeneration
        let requestClient = client
        let fields: [UInt32] = [
            LegacyServerSettingField.statisticHits,
            LegacyServerSettingField.statisticCurrentlyConnected,
            LegacyServerSettingField.statisticConnectionPeak,
            LegacyServerSettingField.statisticIncorrectLogins,
            LegacyServerSettingField.statisticAdminsConnected,
            LegacyServerSettingField.statisticAccountHoldersConnected,
            LegacyServerSettingField.statisticGuestsConnected,
        ]
        updateStatisticsPresentation()
        requestClient.requestServerSettings(fields: fields) { [weak self, weak requestClient] result in
            guard let self, let requestClient, self.client === requestClient,
                  self.statisticsRefreshGeneration == generation,
                  self.currentStatisticsSourceKey() == sourceKey else { return }
            self.statisticsLoading = false
            switch result {
            case let .failure(error):
                self.statisticsStale = self.statisticsSnapshot != nil
                self.statisticsStatusOverride = self.statisticsSnapshot == nil
                    ? LF("Could not load statistics: %@", Self.displayMessage(for: error))
                    : LF("Refresh failed: %@. Showing the last successfully loaded values.", Self.displayMessage(for: error))
                self.statisticsStatusColor = .systemRed
            case let .success(values):
                let snapshot = StatisticsAdminSnapshot(
                    hits: self.decodeStatisticsValue(values[LegacyServerSettingField.statisticHits]),
                    currentlyConnected: self.decodeStatisticsValue(values[LegacyServerSettingField.statisticCurrentlyConnected]),
                    connectionPeak: self.decodeStatisticsValue(values[LegacyServerSettingField.statisticConnectionPeak]),
                    incorrectLogins: self.decodeStatisticsValue(values[LegacyServerSettingField.statisticIncorrectLogins]),
                    adminsConnected: self.decodeStatisticsValue(values[LegacyServerSettingField.statisticAdminsConnected]),
                    accountHoldersConnected: self.decodeStatisticsValue(values[LegacyServerSettingField.statisticAccountHoldersConnected]),
                    guestsConnected: self.decodeStatisticsValue(values[LegacyServerSettingField.statisticGuestsConnected])
                )
                self.statisticsSnapshot = snapshot
                let available = [snapshot.hits, snapshot.currentlyConnected, snapshot.connectionPeak,
                                 snapshot.incorrectLogins, snapshot.adminsConnected,
                                 snapshot.accountHoldersConnected, snapshot.guestsConnected]
                    .compactMap { $0 }.count
                if available == 7 {
                    self.statisticsLastSuccessfulRefresh = Date()
                    self.statisticsStale = false
                    self.statisticsStatusOverride = nil
                    self.statisticsStatusColor = nil
                } else {
                    self.statisticsStale = false
                    self.statisticsStatusOverride = LF("The server returned %@ of 7 requested statistics. Missing values are shown as —.", String(available))
                    self.statisticsStatusColor = CarrachoTheme.warning
                }
            }
            self.updateStatisticsPresentation()
        }
    }

    func refreshStatisticsFromBackend() {
        guard let backend = serverBackend else { return }
        let stats = backend.snapshot().statistics
        localServerState.statistics = stats
        guard !client.isConnected, statisticsSourceKey == nil || statisticsSourceKey == "local" else { return }
        statisticsSourceKey = "local"
        statisticsSnapshot = localStatisticsSnapshot(stats)
        statisticsLastSuccessfulRefresh = Date()
        statisticsStale = false
        statisticsStatusOverride = nil
        statisticsStatusColor = nil
        updateStatisticsPresentation()
    }

    @objc func reloadServerStatePressed(_ sender: Any?) {
        loadModernServerState()
    }

    func reloadLocalStateFromBackend() {
        guard let serverBackend else { return }
        localServerState = serverBackend.snapshot()
        refreshAdminControls()
    }

}
