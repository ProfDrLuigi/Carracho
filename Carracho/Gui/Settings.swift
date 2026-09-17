import Cocoa

// MARK: - Client Settings

extension ViewController {

    func presentClientSettings() {
        if let existing = clientSettingsWindow, existing.isVisible {
            clientSettingsTabControl?.selectedSegment = 0
            updateClientSettingsTabPresentation()
            existing.makeKeyAndOrderFront(nil)
            existing.makeFirstResponder(clientSettingsNicknameField)
            return
        }

        clientSettingsSoundPopups.removeAll(keepingCapacity: true)
        clientSettingsSoundPreviewButtons.removeAll(keepingCapacity: true)
        clientSettingsNotificationCheckboxes.removeAll(keepingCapacity: true)
        clientSettingsGeneralWasVisited = resumeConnectionAfterIdentitySetup

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 710),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("Carracho Settings")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = CarrachoTheme.canvas
        window.minSize = NSSize(width: 720, height: 680)
        clientSettingsWindow = window

        let root = CarrachoBackgroundView()
        root.fillColor = CarrachoTheme.canvas
        window.contentView = root

        let title = NSTextField(labelWithString: L("Carracho Settings"))
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = .labelColor
        title.setContentHuggingPriority(.required, for: .vertical)

        let subtitle = NSTextField(labelWithString: L("Settings for identity, downloads and sounds."))
        subtitle.font = .systemFont(ofSize: 12.5)
        subtitle.textColor = CarrachoTheme.secondaryText
        subtitle.setContentHuggingPriority(.required, for: .vertical)

        let tabs = NSSegmentedControl(
            labels: [L("General"), L("Sounds")],
            trackingMode: .selectOne,
            target: self,
            action: #selector(clientSettingsTabChanged(_:))
        )
        tabs.segmentStyle = .rounded
        tabs.controlSize = .regular
        tabs.setWidth(122, forSegment: 0)
        tabs.setWidth(122, forSegment: 1)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.heightAnchor.constraint(equalToConstant: 28).isActive = true
        clientSettingsTabControl = tabs

        let tabRow = horizontalStack([NSView(), tabs, NSView()], spacing: 0)

        let generalView = makeClientSettingsGeneralTab()
        let soundsView = makeClientSettingsSoundsTab()
        clientSettingsGeneralView = generalView
        clientSettingsSoundsView = soundsView

        let contentHost = NSView()
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        for content in [generalView, soundsView] {
            content.translatesAutoresizingMaskIntoConstraints = false
            contentHost.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                content.topAnchor.constraint(equalTo: contentHost.topAnchor),
                // These tab roots have no intrinsic height. With only <= on the bottom edge
                // Auto Layout was free to collapse them to height 0. AppKit still drew their
                // overflowing children, which made the Sounds controls visible but excluded them
                // from hit-testing. Pinning the root to the host fixes mouse/keyboard interaction.
                content.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            ])
        }
        contentHost.heightAnchor.constraint(equalToConstant: 548).isActive = true

        let restoreDefaults = NSButton(title: L("Restore Defaults"), target: self,
                                       action: #selector(settingsRestoreSoundDefaults(_:)))
        restoreDefaults.bezelStyle = .rounded
        clientSettingsRestoreDefaultsButton = restoreDefaults

        let save = NSButton(title: L("Save"), target: self, action: #selector(settingsSave(_:)))
        save.keyEquivalent = "\r"
        CarrachoTheme.applyPrimaryButtonStyle(save)
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(settingsCancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        let actions = horizontalStack([restoreDefaults, NSView(), cancel, save], spacing: 10)
        actions.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let stack = verticalStack([title, subtitle, tabRow, contentHost, actions], spacing: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -18),
        ])

        // Settings always opens on General. Sounds remains available as the second tab.
        tabs.selectedSegment = 0
        updateClientSettingsTabPresentation()

        if let parent = view.window {
            let frame = parent.frame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(clientSettingsNicknameField)
    }

    private func makeClientSettingsGeneralTab() -> NSView {
        let container = NSView()

        let identityCard = clientSettingsCard()
        let identityTitle = sectionCaption(L("Identity"))
        let nickname = NSTextField(string: generalNickname ?? "")
        nickname.placeholderString = L("Nickname shown on servers")
        let status = NSTextField(string: generalStatusMessage ?? "")
        status.placeholderString = L("Status shown below your nickname")
        let email = NSTextField(string: generalEmail)
        email.placeholderString = L("Email")
        let about = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 72))
        about.string = generalAboutMe
        about.font = .systemFont(ofSize: 13)
        about.isRichText = false
        about.isAutomaticQuoteSubstitutionEnabled = false
        about.isAutomaticDashSubstitutionEnabled = false
        about.textContainerInset = NSSize(width: 7, height: 7)
        about.textContainer?.widthTracksTextView = true
        about.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let aboutScroll = NSScrollView()
        aboutScroll.hasVerticalScroller = true
        aboutScroll.autohidesScrollers = true
        aboutScroll.borderType = .bezelBorder
        aboutScroll.documentView = about
        aboutScroll.translatesAutoresizingMaskIntoConstraints = false
        aboutScroll.heightAnchor.constraint(equalToConstant: 78).isActive = true
        clientSettingsNicknameField = nickname
        clientSettingsStatusField = status
        clientSettingsEmailField = email
        clientSettingsAboutView = about

        let avatar = AvatarDropView(initialData: settingsAvatarInitialData())
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.widthAnchor.constraint(equalToConstant: 190).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: 218).isActive = true
        clientSettingsAvatarView = avatar

        let identityGrid = NSGridView(views: [
            [makeLabel(L("Nickname")), nickname],
            [makeLabel(L("Status")), status],
            [makeLabel(L("eMail")), email],
            [makeLabel(L("About Me")), aboutScroll],
        ])
        identityGrid.rowSpacing = 8
        identityGrid.columnSpacing = 10
        identityGrid.column(at: 0).xPlacement = .trailing
        identityGrid.column(at: 1).xPlacement = .fill
        identityGrid.translatesAutoresizingMaskIntoConstraints = false
        identityGrid.widthAnchor.constraint(equalToConstant: 430).isActive = true

        let identityNote = infoLabel(L("Nickname and status are defaults for every server. A bookmark can override only those two values. eMail and About Me always come from these client settings and are synchronized even when empty."))
        identityNote.maximumNumberOfLines = 4
        let identityFields = verticalStack([identityGrid, identityNote], spacing: 9)
        identityFields.setContentHuggingPriority(.required, for: .horizontal)
        let identityContent = horizontalStack([avatar, identityFields], spacing: 14)
        let identityStack = verticalStack([identityTitle, identityContent], spacing: 10)
        pin(identityStack, in: identityCard, inset: 14)

        let downloadsCard = clientSettingsCard()
        let downloadsTitle = sectionCaption(L("Downloads"))
        clientSettingsPendingDownloadFolderPath = UserDefaults.standard.string(forKey: Self.downloadFolderDefaultsKey)
        let folder = NSTextField(labelWithString: "")
        folder.isSelectable = true
        folder.lineBreakMode = .byTruncatingMiddle
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clientSettingsDownloadFolderField = folder
        refreshClientSettingsDownloadFolderLabel()
        let choose = NSButton(title: L("Choose Folder…"), target: self,
                              action: #selector(settingsChooseDownloadFolder(_:)))
        let ask = NSButton(title: L("Ask Every Time"), target: self,
                           action: #selector(settingsAskEveryTime(_:)))
        let folderRow = horizontalStack([folder, choose, ask], spacing: 8)
        let downloadsStack = verticalStack([downloadsTitle, folderRow], spacing: 8)
        pin(downloadsStack, in: downloadsCard, inset: 14)

        let stack = verticalStack([identityCard, downloadsCard], spacing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            identityCard.heightAnchor.constraint(equalToConstant: 300),
            downloadsCard.heightAnchor.constraint(equalToConstant: 90),
        ])
        return container
    }

    private func makeClientSettingsSoundsTab() -> NSView {
        let container = NSView()

        let playbackCard = clientSettingsCard()
        let playbackTitle = sectionCaption(L("Playback"))
        let enabled = NSButton(checkboxWithTitle: L("Enable Sounds"), target: nil, action: nil)
        enabled.state = clientSoundPreferences.enabled ? .on : .off
        clientSettingsSoundsEnabledCheckbox = enabled

        let volumeTitle = NSTextField(labelWithString: L("Volume"))
        volumeTitle.font = .systemFont(ofSize: 12.5, weight: .medium)
        let slider = NSSlider(value: clientSoundPreferences.volume * 100,
                              minValue: 0, maxValue: 100,
                              target: self, action: #selector(settingsSoundVolumeChanged(_:)))
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 205).isActive = true
        clientSettingsVolumeSlider = slider
        let volumeValue = NSTextField(labelWithString: "")
        volumeValue.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        volumeValue.alignment = .right
        volumeValue.translatesAutoresizingMaskIntoConstraints = false
        volumeValue.widthAnchor.constraint(equalToConstant: 52).isActive = true
        clientSettingsVolumeLabel = volumeValue
        updateClientSettingsVolumeLabel()
        let playbackRow = horizontalStack([enabled, NSView(), volumeTitle, slider, volumeValue], spacing: 10)
        let playbackStack = verticalStack([playbackTitle, playbackRow], spacing: 12)
        pin(playbackStack, in: playbackCard, inset: 14)

        let eventsCard = clientSettingsCard()
        let eventsTitle = sectionCaption(L("Events"))
        let eventHeader = clientSettingsColumnHeader(L("Event"), width: 250, alignment: .left)
        let soundHeader = clientSettingsColumnHeader(L("Sound"), width: 220, alignment: .left)
        let previewHeader = clientSettingsColumnHeader(L("Preview"), width: 56, alignment: .center)
        let notificationHeader = clientSettingsColumnHeader(L("Notification"), width: 100, alignment: .center)
        let header = horizontalStack([eventHeader, soundHeader, previewHeader, notificationHeader], spacing: 10)

        var eventViews: [NSView] = [eventsTitle, header, clientSettingsSeparator()]
        for (index, event) in ClientSoundEvent.allCases.enumerated() {
            let eventLabel = NSTextField(labelWithString: event.title)
            eventLabel.font = .systemFont(ofSize: 12.5)
            eventLabel.lineBreakMode = .byTruncatingTail
            eventLabel.translatesAutoresizingMaskIntoConstraints = false
            eventLabel.widthAnchor.constraint(equalToConstant: 250).isActive = true

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.target = self
            popup.action = #selector(settingsSoundSelectionChanged(_:))
            popup.identifier = NSUserInterfaceItemIdentifier(event.rawValue)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
            clientSettingsSoundPopups[event] = popup

            let preview = NSButton(title: "", target: self, action: #selector(settingsPreviewSound(_:)))
            preview.image = symbolImage("play.fill", fallback: NSImage.touchBarPlayTemplateName)
            preview.imagePosition = .imageOnly
            preview.bezelStyle = .rounded
            preview.controlSize = .small
            preview.identifier = NSUserInterfaceItemIdentifier(event.rawValue)
            preview.translatesAutoresizingMaskIntoConstraints = false
            preview.widthAnchor.constraint(equalToConstant: 42).isActive = true
            preview.heightAnchor.constraint(equalToConstant: 26).isActive = true
            preview.setAccessibilityLabel(LF("Preview sound for %@", event.title))
            clientSettingsSoundPreviewButtons[event] = preview

            let previewHost = NSView()
            preview.translatesAutoresizingMaskIntoConstraints = false
            previewHost.addSubview(preview)
            previewHost.translatesAutoresizingMaskIntoConstraints = false
            previewHost.widthAnchor.constraint(equalToConstant: 56).isActive = true
            NSLayoutConstraint.activate([
                preview.centerXAnchor.constraint(equalTo: previewHost.centerXAnchor),
                preview.centerYAnchor.constraint(equalTo: previewHost.centerYAnchor),
            ])

            let notification = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            notification.state = clientSoundPreferences.notificationEnabled(for: event) ? .on : .off
            notification.setAccessibilityLabel(LF("Send %@ to Notification Center", event.title))
            clientSettingsNotificationCheckboxes[event] = notification
            let notificationHost = NSView()
            notification.translatesAutoresizingMaskIntoConstraints = false
            notificationHost.addSubview(notification)
            notificationHost.translatesAutoresizingMaskIntoConstraints = false
            notificationHost.widthAnchor.constraint(equalToConstant: 100).isActive = true
            NSLayoutConstraint.activate([
                notification.centerXAnchor.constraint(equalTo: notificationHost.centerXAnchor),
                notification.centerYAnchor.constraint(equalTo: notificationHost.centerYAnchor),
            ])

            let row = horizontalStack([eventLabel, popup, previewHost, notificationHost], spacing: 10)
            row.heightAnchor.constraint(equalToConstant: 27).isActive = true
            eventViews.append(row)
            if index != ClientSoundEvent.allCases.count - 1 { eventViews.append(clientSettingsSeparator()) }
        }
        let eventsStack = verticalStack(eventViews, spacing: 2)
        pin(eventsStack, in: eventsCard, inset: 14)
        refreshClientSettingsSoundPopups(preserveCurrentSelections: false)

        let customCard = clientSettingsCard()
        let customTitle = sectionCaption(L("Custom Sounds"))
        let customHelp = infoLabel(L("Use custom audio files for events."))
        customHelp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let importButton = NSButton(title: L("Import Sound…"), target: self,
                                    action: #selector(settingsImportSound(_:)))
        let openFolderButton = NSButton(title: L("Open Sounds Folder"), target: self,
                                        action: #selector(settingsOpenSoundsFolder(_:)))
        let customRow = horizontalStack([customHelp, NSView(), importButton, openFolderButton], spacing: 10)
        let customStack = verticalStack([customTitle, customRow], spacing: 9)
        pin(customStack, in: customCard, inset: 14)

        let stack = verticalStack([playbackCard, eventsCard, customCard], spacing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            playbackCard.heightAnchor.constraint(equalToConstant: 92),
            eventsCard.heightAnchor.constraint(equalToConstant: 330),
            customCard.heightAnchor.constraint(equalToConstant: 88),
        ])
        return container
    }

    private func clientSettingsCard() -> CarrachoCardView {
        let card = CarrachoCardView()
        card.fillColor = CarrachoTheme.elevatedCard
        card.cornerRadius = 10
        return card
    }

    private func clientSettingsColumnHeader(_ title: String, width: CGFloat, alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = CarrachoTheme.secondaryText
        label.alignment = alignment
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func clientSettingsSeparator() -> NSView {
        let divider = CarrachoDividerView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }

    @objc func clientSettingsTabChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { clientSettingsGeneralWasVisited = true }
        updateClientSettingsTabPresentation()
    }

    private func updateClientSettingsTabPresentation() {
        let showingSounds = clientSettingsTabControl?.selectedSegment == 1
        clientSettingsGeneralView?.isHidden = showingSounds
        clientSettingsSoundsView?.isHidden = !showingSounds
        clientSettingsRestoreDefaultsButton?.isHidden = !showingSounds
    }

    private func updateClientSettingsVolumeLabel() {
        guard let slider = clientSettingsVolumeSlider, let label = clientSettingsVolumeLabel else { return }
        label.stringValue = "\(Int(slider.doubleValue.rounded())) %"
    }

    @objc func settingsSoundVolumeChanged(_ sender: NSSlider) {
        updateClientSettingsVolumeLabel()
    }

    private func selectedClientSoundIdentifier(for event: ClientSoundEvent) -> String {
        clientSettingsSoundPopups[event]?.selectedItem?.representedObject as? String
            ?? event.defaultSoundIdentifier
    }

    private func refreshClientSettingsSoundPopups(preserveCurrentSelections: Bool) {
        let available = clientSoundPreferences.availableSounds()
        for event in ClientSoundEvent.allCases {
            guard let popup = clientSettingsSoundPopups[event] else { continue }
            let desired = preserveCurrentSelections
                ? (popup.selectedItem?.representedObject as? String ?? clientSoundPreferences.selection(for: event))
                : clientSoundPreferences.selection(for: event)
            popup.removeAllItems()
            for option in available {
                popup.addItem(withTitle: option.title)
                popup.lastItem?.representedObject = option.identifier
            }
            let target = available.contains(where: { $0.identifier == desired }) ? desired : event.defaultSoundIdentifier
            if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == target }) {
                popup.select(item)
            } else {
                popup.selectItem(at: 0)
            }
            updateClientSettingsPreviewButton(for: event)
        }
    }

    private func updateClientSettingsPreviewButton(for event: ClientSoundEvent) {
        let identifier = selectedClientSoundIdentifier(for: event)
        clientSettingsSoundPreviewButtons[event]?.isEnabled = identifier != ClientSoundPreferences.noSoundIdentifier
    }

    @objc func settingsSoundSelectionChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue,
              let event = ClientSoundEvent(rawValue: raw) else { return }
        updateClientSettingsPreviewButton(for: event)
    }

    @objc func settingsPreviewSound(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let event = ClientSoundEvent(rawValue: raw) else { return }
        let volume = (clientSettingsVolumeSlider?.doubleValue ?? ClientSoundPreferences.defaultVolume * 100) / 100
        clientSoundPreferences.play(identifier: selectedClientSoundIdentifier(for: event), volume: volume)
    }

    @objc func settingsRestoreSoundDefaults(_ sender: Any?) {
        clientSettingsSoundsEnabledCheckbox?.state = .on
        clientSettingsVolumeSlider?.doubleValue = ClientSoundPreferences.defaultVolume * 100
        updateClientSettingsVolumeLabel()
        let available = clientSoundPreferences.availableSounds()
        for event in ClientSoundEvent.allCases {
            clientSettingsNotificationCheckboxes[event]?.state = .off
            guard let popup = clientSettingsSoundPopups[event] else { continue }
            let desired = event.defaultSoundIdentifier
            if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == desired }) {
                popup.select(item)
            } else if let fallback = available.first {
                popup.selectItem(withTitle: fallback.title)
            }
            updateClientSettingsPreviewButton(for: event)
        }
    }

    @objc func settingsImportSound(_ sender: Any?) {
        guard let window = clientSettingsWindow else { return }
        let panel = NSOpenPanel()
        panel.title = L("Import Sound")
        panel.prompt = L("Import")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["aif", "aiff", "wav", "mp3", "m4a", "caf"]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let source = panel.url else { return }
            let securityScoped = source.startAccessingSecurityScopedResource()
            defer { if securityScoped { source.stopAccessingSecurityScopedResource() } }
            do {
                _ = try self.clientSoundPreferences.importSound(from: source)
                self.refreshClientSettingsSoundPopups(preserveCurrentSelections: true)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L("Sound Could Not Be Imported")
                alert.informativeText = Self.displayMessage(for: error)
                alert.addButton(withTitle: L("OK"))
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc func settingsOpenSoundsFolder(_ sender: Any?) {
        do {
            let url = try clientSoundPreferences.ensureSoundsDirectory()
            NSWorkspace.shared.open(url)
        } catch {
            guard let window = clientSettingsWindow else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("Sounds Folder Could Not Be Opened")
            alert.informativeText = Self.displayMessage(for: error)
            alert.addButton(withTitle: L("OK"))
            alert.beginSheetModal(for: window)
        }
    }

    func saveClientSoundPreferencesFromSettings() {
        guard let enabled = clientSettingsSoundsEnabledCheckbox,
              let slider = clientSettingsVolumeSlider else { return }
        var selections: [ClientSoundEvent: String] = [:]
        var notifications: [ClientSoundEvent: Bool] = [:]
        for event in ClientSoundEvent.allCases {
            selections[event] = selectedClientSoundIdentifier(for: event)
            notifications[event] = clientSettingsNotificationCheckboxes[event]?.state == .on
        }
        clientSoundPreferences.save(enabled: enabled.state == .on,
                                    volume: slider.doubleValue / 100,
                                    selections: selections,
                                    notifications: notifications)
        if notifications.values.contains(true) { clientNotificationManager.prepareAuthorization() }
    }

    func emitClientEvent(_ event: ClientSoundEvent, notificationTitle: String, notificationBody: String) {
        clientSoundPreferences.play(event)
        guard clientSoundPreferences.notificationEnabled(for: event) else { return }
        clientNotificationManager.post(title: notificationTitle, body: notificationBody)
    }

    func clientNotificationSnippet(_ text: String, fallback: String = "") -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let value = collapsed.isEmpty ? fallback : collapsed
        guard value.count > 180 else { return value }
        return String(value.prefix(177)) + "…"
    }
}
