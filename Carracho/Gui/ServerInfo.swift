import Cocoa
import QuickLookUI

// MARK: - ServerInfo

extension ViewController {

    func makeServerInfoAdminPage() -> NSView {
        let page = adminPage(title: L("Server Info"), subtitle: L("Server identity shown to connected clients"))
        guard let header = page.subviews.first(where: { $0.identifier?.rawValue == "adminHeader" }) else { return page }

        func fieldBlock(_ title: String, field: NSTextField, help: String? = nil) -> NSView {
            let label = NSTextField(labelWithString: L(title))
            label.font = .systemFont(ofSize: 11.5, weight: .medium)
            field.controlSize = .regular
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            var views: [NSView] = [label, field]
            if let help {
                let note = infoLabel(help)
                note.maximumNumberOfLines = 2
                views.append(note)
            }
            return verticalStack(views, spacing: 5)
        }

        func sectionHeader(_ title: String, symbol: String) -> NSView {
            let icon = symbolView(symbol, size: 16, tint: CarrachoTheme.secondaryText)
            let label = NSTextField(labelWithString: L(title))
            label.font = .systemFont(ofSize: 13.5, weight: .semibold)
            return horizontalStack([icon, label, NSView()], spacing: 8)
        }

        for field in [adminServerNameField, adminOperatorField, adminLocationField, adminBannerURLField] {
            field.delegate = self
        }
        adminServerNameField.setAccessibilityLabel(L("Server name"))
        adminOperatorField.setAccessibilityLabel(L("Operator"))
        adminLocationField.setAccessibilityLabel(L("Location"))
        adminBannerURLField.setAccessibilityLabel(L("Banner link URL"))
        adminDescriptionView.setAccessibilityLabel(L("Server description"))
        adminServerNameField.nextKeyView = adminOperatorField
        adminOperatorField.nextKeyView = adminLocationField
        adminLocationField.nextKeyView = adminDescriptionView
        adminDescriptionView.nextKeyView = adminBannerURLField
        adminBannerURLField.nextKeyView = adminBannerChooseButton
        adminDescriptionView.delegate = self
        adminDescriptionView.font = .systemFont(ofSize: 12.5)
        adminDescriptionView.isRichText = false
        adminDescriptionView.allowsUndo = true
        adminDescriptionView.isAutomaticQuoteSubstitutionEnabled = false
        adminDescriptionView.isAutomaticDashSubstitutionEnabled = false
        adminDescriptionView.textContainerInset = NSSize(width: 7, height: 7)
        let descriptionScroll = textScroll(adminDescriptionView)
        descriptionScroll.heightAnchor.constraint(equalToConstant: 112).isActive = true
        descriptionScroll.hasVerticalScroller = true
        descriptionScroll.autohidesScrollers = true

        let descriptionLabel = NSTextField(labelWithString: L("Description"))
        descriptionLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        let descriptionHelp = infoLabel(L("Short server description. Longer text remains scrollable and fully editable."))
        descriptionHelp.maximumNumberOfLines = 2
        let identity = verticalStack([
            sectionHeader("Identity", symbol: "server.rack"),
            fieldBlock("Server name", field: adminServerNameField),
            fieldBlock("Operator", field: adminOperatorField),
            fieldBlock("Location", field: adminLocationField),
            verticalStack([descriptionLabel, descriptionScroll, descriptionHelp], spacing: 5),
        ], spacing: 12)

        adminBannerURLField.placeholderString = "https://…"
        adminBannerURLField.toolTip = L("Classic banner link target. The PNG image is uploaded separately.")
        adminBannerChooseButton.target = self
        adminBannerChooseButton.action = #selector(chooseLocalBannerImage(_:))
        adminBannerChooseButton.bezelStyle = .rounded
        adminBannerChooseButton.image = symbolImage("photo", fallback: NSImage.addTemplateName)
        adminBannerChooseButton.imagePosition = .imageLeading
        adminBannerRemoveButton.target = self
        adminBannerRemoveButton.action = #selector(removeLocalBannerImage(_:))
        adminBannerRemoveButton.bezelStyle = .rounded

        let bannerHelp = infoLabel(L("The URL is the link target used by Classic clients when the banner is activated. It does not load the image; the selected PNG is transferred separately."))
        bannerHelp.maximumNumberOfLines = 3
        let chooseHint = infoLabel(L("Choose a PNG file, or remove the current banner image. The link target remains independently editable; existing protocol limits are unchanged."))
        chooseHint.maximumNumberOfLines = 2
        let bannerButtons = horizontalStack([adminBannerChooseButton, adminBannerRemoveButton, NSView()], spacing: 8)

        let bannerSurface = CarrachoCardView()
        bannerSurface.fillColor = CarrachoTheme.elevatedCard
        bannerSurface.cornerRadius = 7
        bannerSurface.translatesAutoresizingMaskIntoConstraints = false
        bannerSurface.heightAnchor.constraint(equalToConstant: 104).isActive = true
        adminBannerImageView.imageScaling = .scaleProportionallyDown
        adminBannerImageView.imageAlignment = .alignCenter
        adminBannerImageView.translatesAutoresizingMaskIntoConstraints = false
        adminBannerImageView.setAccessibilityLabel(L("Server banner preview"))
        adminServerInfoPreviewNoBannerLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        adminServerInfoPreviewNoBannerLabel.textColor = CarrachoTheme.secondaryText
        adminServerInfoPreviewNoBannerLabel.alignment = .center
        adminServerInfoPreviewNoBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        bannerSurface.addSubview(adminBannerImageView)
        bannerSurface.addSubview(adminServerInfoPreviewNoBannerLabel)
        NSLayoutConstraint.activate([
            adminBannerImageView.leadingAnchor.constraint(equalTo: bannerSurface.leadingAnchor, constant: 8),
            adminBannerImageView.trailingAnchor.constraint(equalTo: bannerSurface.trailingAnchor, constant: -8),
            adminBannerImageView.topAnchor.constraint(equalTo: bannerSurface.topAnchor, constant: 7),
            adminBannerImageView.bottomAnchor.constraint(equalTo: bannerSurface.bottomAnchor, constant: -7),
            adminServerInfoPreviewNoBannerLabel.centerXAnchor.constraint(equalTo: bannerSurface.centerXAnchor),
            adminServerInfoPreviewNoBannerLabel.centerYAnchor.constraint(equalTo: bannerSurface.centerYAnchor),
            adminServerInfoPreviewNoBannerLabel.leadingAnchor.constraint(greaterThanOrEqualTo: bannerSurface.leadingAnchor, constant: 12),
            adminServerInfoPreviewNoBannerLabel.trailingAnchor.constraint(lessThanOrEqualTo: bannerSurface.trailingAnchor, constant: -12),
        ])

        adminServerInfoPreviewNameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        adminServerInfoPreviewNameLabel.lineBreakMode = .byTruncatingTail
        adminServerInfoPreviewDescriptionLabel.font = .systemFont(ofSize: 11.5)
        adminServerInfoPreviewDescriptionLabel.textColor = CarrachoTheme.secondaryText
        adminServerInfoPreviewDescriptionLabel.maximumNumberOfLines = 2
        adminServerInfoPreviewDescriptionLabel.lineBreakMode = .byTruncatingTail
        adminServerInfoPreviewOperatorLabel.font = .systemFont(ofSize: 10.5)
        adminServerInfoPreviewOperatorLabel.textColor = CarrachoTheme.secondaryText
        adminServerInfoPreviewOperatorLabel.lineBreakMode = .byTruncatingTail
        adminServerInfoPreviewLocationLabel.font = .systemFont(ofSize: 10.5)
        adminServerInfoPreviewLocationLabel.textColor = CarrachoTheme.secondaryText
        adminServerInfoPreviewLocationLabel.lineBreakMode = .byTruncatingTail
        let operatorIcon = symbolView("person.fill", size: 11, tint: CarrachoTheme.secondaryText)
        let locationIcon = symbolView("mappin.and.ellipse", size: 11, tint: CarrachoTheme.secondaryText)
        let metaSeparator = NSTextField(labelWithString: L("·"))
        metaSeparator.font = .systemFont(ofSize: 10.5, weight: .medium)
        metaSeparator.textColor = CarrachoTheme.tertiaryText
        let previewMeta = horizontalStack([
            operatorIcon, adminServerInfoPreviewOperatorLabel,
            metaSeparator,
            locationIcon, adminServerInfoPreviewLocationLabel,
            NSView(),
        ], spacing: 6)

        let previewCard = CarrachoCardView()
        previewCard.fillColor = CarrachoTheme.card
        previewCard.cornerRadius = 8
        let previewStack = verticalStack([
            bannerSurface,
            adminServerInfoPreviewNameLabel,
            adminServerInfoPreviewDescriptionLabel,
            previewMeta,
        ], spacing: 6)
        previewStack.translatesAutoresizingMaskIntoConstraints = false
        previewCard.addSubview(previewStack)
        NSLayoutConstraint.activate([
            previewStack.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor, constant: 10),
            previewStack.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor, constant: -10),
            previewStack.topAnchor.constraint(equalTo: previewCard.topAnchor, constant: 10),
            previewStack.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor, constant: -10),
        ])
        adminServerInfoPreviewCaptionLabel.font = .systemFont(ofSize: 10.5)
        adminServerInfoPreviewCaptionLabel.textColor = CarrachoTheme.secondaryText
        adminServerInfoPreviewCaptionLabel.lineBreakMode = .byTruncatingTail

        let previewTitle = NSTextField(labelWithString: L("Client Preview"))
        previewTitle.font = .systemFont(ofSize: 11.5, weight: .semibold)
        let banner = verticalStack([
            sectionHeader("Server Banner", symbol: "photo.fill"),
            fieldBlock("Banner URL", field: adminBannerURLField, help: nil),
            bannerHelp,
            chooseHint,
            bannerButtons,
            previewTitle,
            previewCard,
            adminServerInfoPreviewCaptionLabel,
        ], spacing: 10)

        let responsive = ResponsiveServerInfoLayout(left: identity, right: banner)

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(responsive)

        let divider = CarrachoDividerView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        content.addArrangedSubview(divider)

        adminServerInfoStatusLabel.textColor = CarrachoTheme.secondaryText
        adminServerInfoStatusLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        adminServerInfoStatusLabel.lineBreakMode = .byTruncatingTail
        adminServerInfoStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        adminServerInfoDiscardButton.target = self
        adminServerInfoDiscardButton.action = #selector(discardServerInfoChanges(_:))
        adminServerInfoDiscardButton.bezelStyle = .rounded
        adminServerInfoSaveButton.target = self
        adminServerInfoSaveButton.action = #selector(saveServerInfo(_:))
        CarrachoTheme.applyPrimaryButtonStyle(adminServerInfoSaveButton)
        adminServerInfoSaveButton.keyEquivalent = "\r"
        adminBannerChooseButton.nextKeyView = adminBannerRemoveButton
        adminBannerRemoveButton.nextKeyView = adminServerInfoDiscardButton
        adminServerInfoDiscardButton.nextKeyView = adminServerInfoSaveButton
        adminServerInfoSaveButton.nextKeyView = adminServerNameField
        let actions = horizontalStack([
            adminServerInfoStatusLabel,
            NSView(),
            adminServerInfoDiscardButton,
            adminServerInfoSaveButton,
        ], spacing: 10)
        content.addArrangedSubview(actions)

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
        maxWidth.priority = .required
        let fillWidth = content.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -20)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -4),

            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
            maxWidth,
            fillWidth,
        ])

        updateServerInfoPreview()
        updateServerInfoEditorState()
        return page
    }

    func currentServerInfoSourceKey() -> String {
        if client.isConnected {
            if let id = activeBookmarkConnectionID { return "remote:\(id.uuidString.lowercased())" }
            return "remote:\(hostField.stringValue.lowercased()):\(portField.stringValue):\(loginField.stringValue.lowercased())"
        }
        return "local"
    }

    func currentServerInfoDraft() -> ServerInfoAdminSnapshot {
        ServerInfoAdminSnapshot(serverName: adminServerNameField.stringValue,
                                operatorName: adminOperatorField.stringValue,
                                location: adminLocationField.stringValue,
                                description: adminDescriptionView.string,
                                bannerURL: adminBannerURLField.stringValue,
                                bannerData: pendingAdminBannerData)
    }

    func setServerInfoDraft(_ snapshot: ServerInfoAdminSnapshot) {
        serverInfoSuppressChangeTracking = true
        adminServerNameField.stringValue = snapshot.serverName
        adminOperatorField.stringValue = snapshot.operatorName
        adminLocationField.stringValue = snapshot.location
        adminDescriptionView.string = snapshot.description
        adminBannerURLField.stringValue = snapshot.bannerURL
        pendingAdminBannerData = snapshot.bannerData
        serverInfoSuppressChangeTracking = false
        updateServerInfoPreview()
    }

    func serverInfoValidationError(for draft: ServerInfoAdminSnapshot) -> String? {
        if client.isConnected || serverInfoDraftSourceKey?.hasPrefix("remote:") == true {
            guard let name = draft.serverName.data(using: .macOSRoman), !name.isEmpty else {
                return L("Server name must be MacRoman-compatible and non-empty.")
            }
            guard let operatorName = draft.operatorName.data(using: .macOSRoman) else {
                return L("Operator must be MacRoman-compatible.")
            }
            guard let location = draft.location.data(using: .macOSRoman) else {
                return L("Location must be MacRoman-compatible.")
            }
            guard let description = draft.description.data(using: .macOSRoman) else {
                return L("Description must be MacRoman-compatible.")
            }
            if isConnectedToClassicServer {
                guard name.count <= 40, operatorName.count <= 40, location.count <= 40 else {
                    return L("Classic server name, operator and location must each be at most 40 MacRoman bytes.")
                }
                guard description.count <= 255 else {
                    return L("Classic server description must be at most 255 MacRoman bytes.")
                }
            } else {
                guard name.count <= 255 else {
                    return L("Server name must be at most 255 MacRoman bytes.")
                }
                guard operatorName.count <= 255 else {
                    return L("Operator must be at most 255 MacRoman bytes.")
                }
                guard location.count <= 255 else {
                    return L("Location must be at most 255 MacRoman bytes.")
                }
                guard description.count <= 16_384 else {
                    return L("Description must be at most 16384 MacRoman bytes.")
                }
            }
            guard let bannerURL = draft.bannerURL.data(using: .macOSRoman), bannerURL.count <= 255 else {
                return L("Banner URL must be MacRoman-compatible and at most 255 bytes.")
            }
            if let data = draft.bannerData, data.count > 8 * 1024 * 1024 {
                return L("Banner image exceeds the existing 8 MiB protocol limit.")
            }
            return nil
        }

        let identity = ServerIdentity(name: draft.serverName,
                                      operatorName: draft.operatorName,
                                      location: draft.location,
                                      description: draft.description,
                                      bannerURL: draft.bannerURL,
                                      bannerData: draft.bannerData)
        do {
            try ServerStateValidator.validate(identity: identity)
            return nil
        } catch {
            return Self.displayMessage(for: error)
        }
    }

    func updateServerInfoPreview() {
        let draft = currentServerInfoDraft()
        let trimmedName = draft.serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOperator = draft.operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocation = draft.location.trimmingCharacters(in: .whitespacesAndNewlines)

        adminServerInfoPreviewNameLabel.stringValue = trimmedName.isEmpty ? L("Untitled Server") : trimmedName
        adminServerInfoPreviewDescriptionLabel.stringValue = trimmedDescription.isEmpty ? L("No description") : trimmedDescription
        adminServerInfoPreviewOperatorLabel.stringValue = trimmedOperator.isEmpty ? L("No operator") : trimmedOperator
        adminServerInfoPreviewLocationLabel.stringValue = trimmedLocation.isEmpty ? L("No location") : trimmedLocation
        adminServerInfoPreviewNameLabel.toolTip = draft.serverName
        adminServerInfoPreviewDescriptionLabel.toolTip = draft.description
        adminServerInfoPreviewOperatorLabel.toolTip = draft.operatorName
        adminServerInfoPreviewLocationLabel.toolTip = draft.location

        if let data = draft.bannerData, !data.isEmpty {
            if let image = NSImage(data: data) {
                adminBannerImageView.image = image
                adminServerInfoPreviewNoBannerLabel.isHidden = true
            } else {
                adminBannerImageView.image = nil
                adminServerInfoPreviewNoBannerLabel.stringValue = L("Banner image cannot be displayed")
                adminServerInfoPreviewNoBannerLabel.isHidden = false
            }
        } else {
            adminBannerImageView.image = nil
            adminServerInfoPreviewNoBannerLabel.stringValue = L("No banner selected")
            adminServerInfoPreviewNoBannerLabel.isHidden = false
        }
    }

    func updateServerInfoEditorState() {
        let draft = currentServerInfoDraft()
        serverInfoHasUnsavedChanges = serverInfoLoadedSnapshot.map { $0 != draft } ?? false
        let sourceMatches = serverInfoDraftSourceKey == currentServerInfoSourceKey()
        let hasLoadedState = serverInfoLoadedSnapshot != nil
        let permission = client.isConnected
            ? canAccessAdministrativeWorkspace(.serverInfo)
            : serverBackend != nil
        let editorEnabled = sourceMatches && hasLoadedState && permission && !serverInfoLoading && !serverInfoSaveInProgress
        let validationError = serverInfoValidationError(for: draft)

        for field in [adminServerNameField, adminOperatorField, adminLocationField, adminBannerURLField] {
            field.isEnabled = editorEnabled
        }
        adminDescriptionView.isEditable = editorEnabled
        adminDescriptionView.isSelectable = true
        adminBannerChooseButton.isEnabled = editorEnabled
        adminBannerRemoveButton.isEnabled = editorEnabled && draft.bannerData != nil
        adminServerInfoDiscardButton.isEnabled = serverInfoHasUnsavedChanges && !serverInfoSaveInProgress
        adminServerInfoSaveButton.isEnabled = editorEnabled && serverInfoHasUnsavedChanges && validationError == nil
        CarrachoTheme.setPrimaryButtonTitle(adminServerInfoSaveButton, serverInfoSaveInProgress ? L("Saving…") : L("Save"))

        if let status = serverInfoStatusOverride {
            adminServerInfoStatusLabel.stringValue = status
            adminServerInfoStatusLabel.textColor = serverInfoStatusColor ?? CarrachoTheme.secondaryText
        } else if serverInfoLoading {
            adminServerInfoStatusLabel.stringValue = L("Loading server information…")
            adminServerInfoStatusLabel.textColor = CarrachoTheme.secondaryText
        } else if serverInfoHasUnsavedChanges, let validationError {
            adminServerInfoStatusLabel.stringValue = LF("Cannot save: %@", validationError)
            adminServerInfoStatusLabel.textColor = .systemRed
        } else if serverInfoHasUnsavedChanges {
            adminServerInfoStatusLabel.stringValue = L("Unsaved changes")
            adminServerInfoStatusLabel.textColor = CarrachoTheme.warning
        } else if hasLoadedState {
            adminServerInfoStatusLabel.stringValue = L("No unsaved changes")
            adminServerInfoStatusLabel.textColor = CarrachoTheme.secondaryText
        } else {
            adminServerInfoStatusLabel.stringValue = permission ? L("Server information is unavailable.") : L("This account cannot edit server information.")
            adminServerInfoStatusLabel.textColor = permission ? CarrachoTheme.warning : .systemRed
        }
    }

    func markServerInfoDraftChanged() {
        guard !serverInfoSuppressChangeTracking else { return }
        serverInfoStatusOverride = nil
        serverInfoStatusColor = nil
        updateServerInfoPreview()
        updateServerInfoEditorState()
    }

    func loadLocalServerInfoAdministration() {
        let identity = localServerState.identity
        let snapshot = ServerInfoAdminSnapshot(serverName: identity.name,
                                               operatorName: identity.operatorName,
                                               location: identity.location,
                                               description: identity.description,
                                               bannerURL: identity.bannerURL,
                                               bannerData: identity.bannerData)
        serverInfoLoadGeneration &+= 1
        serverInfoLoading = false
        serverInfoSaveInProgress = false
        serverInfoDraftSourceKey = "local"
        serverInfoLoadedSnapshot = snapshot
        setServerInfoDraft(snapshot)
        serverInfoStatusOverride = serverBackend == nil ? L("Local server backend is unavailable.") : L("Editing local server information.")
        serverInfoStatusColor = serverBackend == nil ? .systemRed : CarrachoTheme.secondaryText
        updateServerInfoEditorState()
    }

    func finishRemoteServerInfoLoad(_ snapshot: ServerInfoAdminSnapshot,
                                            sourceKey: String,
                                            status: String,
                                            color: NSColor = CarrachoTheme.secondaryText) {
        serverInfoLoading = false
        serverInfoSaveInProgress = false
        serverInfoDraftSourceKey = sourceKey
        serverInfoLoadedSnapshot = snapshot
        setServerInfoDraft(snapshot)
        serverInfoStatusOverride = status
        serverInfoStatusColor = color
        updateServerInfoEditorState()
    }

    @objc func chooseLocalBannerImage(_ sender: Any?) {
        guard !serverInfoSaveInProgress, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["png"]
        panel.message = L("Choose a PNG advertising banner (Classic clients expect approximately 350×45 pixels).")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 8 * 1024 * 1024, NSImage(data: data) != nil else {
                    throw ServerStateError.invalidValue(L("Banner must be a valid PNG image no larger than 8 MiB."))
                }
                self.pendingAdminBannerData = data
                self.serverInfoStatusOverride = nil
                self.serverInfoStatusColor = nil
                self.markServerInfoDraftChanged()
            } catch {
                self.serverInfoStatusOverride = LF("Banner could not be selected: %@", Self.displayMessage(for: error))
                self.serverInfoStatusColor = .systemRed
                self.updateServerInfoEditorState()
                self.showAdminError(error)
            }
        }
    }

    @objc func removeLocalBannerImage(_ sender: Any?) {
        guard !serverInfoSaveInProgress else { return }
        pendingAdminBannerData = nil
        serverInfoStatusOverride = nil
        serverInfoStatusColor = nil
        markServerInfoDraftChanged()
    }

    @objc func discardServerInfoChanges(_ sender: Any?) {
        guard !serverInfoSaveInProgress, let snapshot = serverInfoLoadedSnapshot else { return }
        setServerInfoDraft(snapshot)
        serverInfoStatusOverride = L("Changes discarded.")
        serverInfoStatusColor = CarrachoTheme.secondaryText
        updateServerInfoEditorState()
    }

    func applyRemoteBannerToAdmin(_ banner: LegacyBannerContent?) {
        guard client.isConnected, currentWorkspace == .serverInfo else { return }
        guard serverInfoDraftSourceKey == currentServerInfoSourceKey() else { return }
        if serverInfoLoading || serverInfoSaveInProgress { return }
        if serverInfoHasUnsavedChanges {
            serverInfoStatusOverride = L("The server banner changed while local edits are pending. Discard changes to load the newer server value.")
            serverInfoStatusColor = CarrachoTheme.warning
            updateServerInfoEditorState()
            return
        }
        var snapshot = serverInfoLoadedSnapshot ?? currentServerInfoDraft()
        let imageData = banner?.imageData ?? Data()
        snapshot.bannerData = imageData.isEmpty ? nil : imageData
        snapshot.bannerURL = banner?.urlString ?? ""
        serverInfoLoadedSnapshot = snapshot
        setServerInfoDraft(snapshot)
        serverInfoStatusOverride = L("Banner refreshed from connected server.")
        serverInfoStatusColor = CarrachoTheme.secondaryText
        updateServerInfoEditorState()
    }

    func reloadServerInfoAdministration() {
        if !client.isConnected {
            serverInfoLoadGeneration &+= 1
            serverInfoLoading = false
            serverInfoSaveInProgress = false
            if serverInfoHasUnsavedChanges, serverInfoDraftSourceKey?.hasPrefix("remote:") == true {
                serverInfoStatusOverride = L("Connection lost. Unsaved remote-server changes are retained; reconnect or discard them before editing local settings.")
                serverInfoStatusColor = CarrachoTheme.warning
                updateServerInfoEditorState()
            } else {
                loadLocalServerInfoAdministration()
            }
            return
        }

        let sourceKey = currentServerInfoSourceKey()
        serverInfoLoadGeneration &+= 1
        let generation = serverInfoLoadGeneration
        let requestClient = client
        serverInfoLoading = true
        serverInfoSaveInProgress = false
        serverInfoDraftSourceKey = sourceKey
        serverInfoLoadedSnapshot = nil
        serverInfoStatusOverride = LF("Loading server information from %@:%@…", hostField.stringValue, portField.stringValue)
        serverInfoStatusColor = CarrachoTheme.secondaryText

        let provisional = ServerInfoAdminSnapshot(serverName: lastServerInfo?.serverName ?? "",
                                                  operatorName: lastServerInfo?.systemOperator ?? "",
                                                  location: lastServerInfo?.location ?? "",
                                                  description: lastServerInfo?.description ?? "",
                                                  bannerURL: currentBanner?.urlString ?? "",
                                                  bannerData: currentBanner.flatMap { $0.imageData.isEmpty ? nil : $0.imageData })
        setServerInfoDraft(provisional)
        updateServerInfoEditorState()

        guard canAccessAdministrativeWorkspace(.serverInfo) else {
            serverInfoLoading = false
            serverInfoLoadedSnapshot = provisional
            serverInfoStatusOverride = L("This account cannot edit server information.")
            serverInfoStatusColor = .systemRed
            updateServerInfoEditorState()
            return
        }

        requestClient.requestServerSettings(fields: [LegacyServerSettingField.serverName,
                                                      LegacyServerSettingField.serverOperator,
                                                      LegacyServerSettingField.location,
                                                      LegacyServerSettingField.description]) { [weak self, weak requestClient] result in
            guard let self, let requestClient, self.client === requestClient,
                  self.serverInfoLoadGeneration == generation,
                  self.currentServerInfoSourceKey() == sourceKey else { return }
            switch result {
            case let .failure(error):
                self.serverInfoLoading = false
                self.serverInfoStatusOverride = LF("Could not load server information: %@", Self.displayMessage(for: error))
                self.serverInfoStatusColor = .systemRed
                self.updateServerInfoEditorState()
            case let .success(values):
                guard let nameData = values[LegacyServerSettingField.serverName],
                      let operatorData = values[LegacyServerSettingField.serverOperator],
                      let locationData = values[LegacyServerSettingField.location],
                      let descriptionData = values[LegacyServerSettingField.description],
                      let name = String(data: nameData, encoding: .macOSRoman),
                      let operatorName = String(data: operatorData, encoding: .macOSRoman),
                      let location = String(data: locationData, encoding: .macOSRoman),
                      let description = String(data: descriptionData, encoding: .macOSRoman) else {
                    self.serverInfoLoading = false
                    self.serverInfoStatusOverride = L("Connected server returned incomplete server information.")
                    self.serverInfoStatusColor = .systemRed
                    self.updateServerInfoEditorState()
                    return
                }
                var snapshot = ServerInfoAdminSnapshot(serverName: name,
                                                       operatorName: operatorName,
                                                       location: location,
                                                       description: description,
                                                       bannerURL: self.currentBanner?.urlString ?? "",
                                                       bannerData: self.currentBanner.flatMap { $0.imageData.isEmpty ? nil : $0.imageData })
                guard let bannerClient = self.bannerClient else {
                    self.finishRemoteServerInfoLoad(snapshot, sourceKey: sourceKey,
                                                    status: L("Server information loaded; banner transfer is unavailable."),
                                                    color: CarrachoTheme.warning)
                    return
                }
                self.serverInfoStatusOverride = L("Loading server banner…")
                self.updateServerInfoEditorState()
                bannerClient.download { [weak self, weak requestClient] bannerResult in
                    guard let self, let requestClient, self.client === requestClient,
                          self.serverInfoLoadGeneration == generation,
                          self.currentServerInfoSourceKey() == sourceKey else { return }
                    switch bannerResult {
                    case let .success(banner):
                        self.currentBanner = banner
                        self.rightBannerImageView.image = banner.imageData.isEmpty ? nil : NSImage(data: banner.imageData)
                        snapshot.bannerData = banner.imageData.isEmpty ? nil : banner.imageData
                        snapshot.bannerURL = banner.urlString
                        self.renderSession()
                        self.finishRemoteServerInfoLoad(snapshot, sourceKey: sourceKey,
                                                        status: LF("Loaded from connected server %@:%@.", self.hostField.stringValue, self.portField.stringValue))
                    case let .failure(error):
                        self.finishRemoteServerInfoLoad(snapshot, sourceKey: sourceKey,
                                                        status: LF("Server information loaded; banner could not be refreshed: %@", Self.displayMessage(for: error)),
                                                        color: CarrachoTheme.warning)
                    }
                }
            }
        }
    }

    func refreshRemoteServerInfoAfterSave() {
        let requestClient = client
        requestClient.requestServerInfo { [weak self, weak requestClient] result in
            guard let self, let requestClient, self.client === requestClient else { return }
            if case let .success(info) = result {
                self.lastServerInfo = info
                self.renderSession()
            }
        }
    }

    func mergeSavedIdentityIntoServerInfoBaseline(_ draft: ServerInfoAdminSnapshot) {
        var baseline = serverInfoLoadedSnapshot ?? draft
        baseline.serverName = draft.serverName
        baseline.operatorName = draft.operatorName
        baseline.location = draft.location
        baseline.description = draft.description
        serverInfoLoadedSnapshot = baseline
    }

    @objc func saveServerInfo(_ sender: Any?) {
        guard !serverInfoSaveInProgress, serverInfoDraftSourceKey == currentServerInfoSourceKey() else { return }
        let draft = currentServerInfoDraft()
        if let validationError = serverInfoValidationError(for: draft) {
            serverInfoStatusOverride = LF("Cannot save: %@", validationError)
            serverInfoStatusColor = .systemRed
            updateServerInfoEditorState()
            return
        }

        if client.isConnected {
            guard canAccessAdministrativeWorkspace(.serverInfo) else {
                serverInfoStatusOverride = L("This account cannot edit server information on the connected server.")
                serverInfoStatusColor = .systemRed
                updateServerInfoEditorState()
                return
            }
            guard let name = draft.serverName.data(using: .macOSRoman),
                  let operatorName = draft.operatorName.data(using: .macOSRoman),
                  let location = draft.location.data(using: .macOSRoman),
                  let description = draft.description.data(using: .macOSRoman) else { return }

            let sourceKey = currentServerInfoSourceKey()
            let requestClient = client
            let settings = [
                LegacyTLV(type: LegacyServerSettingField.serverName, value: name),
                LegacyTLV(type: LegacyServerSettingField.serverOperator, value: operatorName),
                LegacyTLV(type: LegacyServerSettingField.location, value: location),
                LegacyTLV(type: LegacyServerSettingField.description, value: description),
            ]
            serverInfoSaveInProgress = true
            serverInfoStatusOverride = L("Saving server information on connected server…")
            serverInfoStatusColor = CarrachoTheme.secondaryText
            updateServerInfoEditorState()
            requestClient.setServerSettings(settings) { [weak self, weak requestClient] result in
                guard let self, let requestClient, self.client === requestClient,
                      self.currentServerInfoSourceKey() == sourceKey else { return }
                switch result {
                case let .failure(error):
                    self.serverInfoSaveInProgress = false
                    self.serverInfoStatusOverride = LF("Save failed: %@. Your changes are still in the form.", Self.displayMessage(for: error))
                    self.serverInfoStatusColor = .systemRed
                    self.updateServerInfoEditorState()
                case .success:
                    self.mergeSavedIdentityIntoServerInfoBaseline(draft)
                    self.refreshRemoteServerInfoAfterSave()
                    let baseline = self.serverInfoLoadedSnapshot ?? draft
                    let bannerChanged = baseline.bannerData != draft.bannerData || baseline.bannerURL != draft.bannerURL
                    guard bannerChanged else {
                        self.serverInfoLoadedSnapshot = draft
                        self.serverInfoSaveInProgress = false
                        self.serverInfoStatusOverride = L("Server information saved.")
                        self.serverInfoStatusColor = CarrachoTheme.success
                        self.updateServerInfoEditorState()
                        return
                    }
                    guard let bannerClient = self.bannerClient else {
                        self.serverInfoSaveInProgress = false
                        self.serverInfoStatusOverride = L("Identity fields were saved, but the banner transfer is unavailable. Banner changes remain unsaved.")
                        self.serverInfoStatusColor = CarrachoTheme.warning
                        self.updateServerInfoEditorState()
                        return
                    }
                    let requestedImage = draft.bannerData ?? Data()
                    bannerClient.upload(imageData: requestedImage, urlString: draft.bannerURL) { [weak self, weak requestClient] bannerResult in
                        guard let self, let requestClient, self.client === requestClient,
                              self.currentServerInfoSourceKey() == sourceKey else { return }
                        self.serverInfoSaveInProgress = false
                        switch bannerResult {
                        case .success:
                            let urlData = draft.bannerURL.data(using: .macOSRoman) ?? Data()
                            self.currentBanner = LegacyBannerContent(imageData: requestedImage, url: urlData)
                            self.rightBannerImageView.image = requestedImage.isEmpty ? nil : NSImage(data: requestedImage)
                            self.serverInfoLoadedSnapshot = draft
                            self.serverInfoStatusOverride = L("Server information and banner saved.")
                            self.serverInfoStatusColor = CarrachoTheme.success
                            self.renderSession()
                        case let .failure(error):
                            self.serverInfoStatusOverride = LF("Identity fields were saved, but banner save failed: %@. Banner changes remain unsaved.", Self.displayMessage(for: error))
                            self.serverInfoStatusColor = .systemRed
                        }
                        self.updateServerInfoEditorState()
                    }
                }
            }
            return
        }

        guard serverInfoDraftSourceKey == "local", let backend = serverBackend else {
            serverInfoStatusOverride = L("Local server backend is unavailable.")
            serverInfoStatusColor = .systemRed
            updateServerInfoEditorState()
            return
        }
        let previousIdentity = localServerState.identity
        let identity = ServerIdentity(name: draft.serverName,
                                      operatorName: draft.operatorName,
                                      location: draft.location,
                                      description: draft.description,
                                      bannerURL: draft.bannerURL,
                                      bannerData: draft.bannerData)
        serverInfoSaveInProgress = true
        serverInfoStatusOverride = L("Saving local server information…")
        serverInfoStatusColor = CarrachoTheme.secondaryText
        updateServerInfoEditorState()
        do {
            try backend.updateIdentity(identity)
            localServerState = backend.snapshot()
            if previousIdentity.bannerData != identity.bannerData || previousIdentity.bannerURL != identity.bannerURL {
                localServerRuntime?.notifyBannerChanged()
            }
            serverInfoLoadedSnapshot = draft
            serverInfoSaveInProgress = false
            serverInfoStatusOverride = L("Server information saved.")
            serverInfoStatusColor = CarrachoTheme.success
            updateServerInfoEditorState()
            showAdminSaved(L("Server information saved."))
        } catch {
            serverInfoSaveInProgress = false
            serverInfoStatusOverride = LF("Save failed: %@. Your changes are still in the form.", Self.displayMessage(for: error))
            serverInfoStatusColor = .systemRed
            updateServerInfoEditorState()
        }
    }

    @objc func menuServerInfo(_ sender: Any?) { selectWorkspace(.serverInfo) }

}
