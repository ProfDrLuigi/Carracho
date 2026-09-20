import Cocoa
import QuickLookUI

final class TrackerPrivateLoginWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let loginField = NSTextField(string: "")
    let passwordField = NSSecureTextField(string: "")
    let validationLabel = NSTextField(labelWithString: "")
    private let submitButton = NSButton(title: L("Verify"), target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var didFinish = false

    var onSubmit: ((String, String) -> Void)?
    var onFinish: (() -> Void)?

    init(serverName: String, endpoint: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("Private Server")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface(in: window, serverName: serverName, endpoint: endpoint)
    }

    required init?(coder: NSCoder) { nil }

    private func buildInterface(in window: NSWindow, serverName: String, endpoint: String) {
        let root = CarrachoBackgroundView()
        root.fillColor = CarrachoTheme.canvas
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let title = NSTextField(labelWithString: L("Private Server"))
        title.font = .systemFont(ofSize: 18, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: LF("%@ requires a server account before a bookmark can be created.", serverName))
        subtitle.font = .systemFont(ofSize: 12.5)
        subtitle.textColor = CarrachoTheme.secondaryText
        subtitle.maximumNumberOfLines = 2
        let endpointLabel = NSTextField(labelWithString: endpoint)
        endpointLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        endpointLabel.textColor = CarrachoTheme.tertiaryText
        endpointLabel.lineBreakMode = .byTruncatingMiddle
        endpointLabel.toolTip = endpoint

        loginField.placeholderString = L("Login")
        passwordField.placeholderString = L("Password")
        loginField.delegate = self
        passwordField.delegate = self
        loginField.setAccessibilityLabel(L("Login"))
        passwordField.setAccessibilityLabel(L("Password"))
        for field in [loginField, passwordField] {
            field.font = .systemFont(ofSize: 13)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }

        let form = NSStackView(views: [formRow(L("Login"), control: loginField),
                                      formRow(L("Password"), control: passwordField)])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.translatesAutoresizingMaskIntoConstraints = false
        for row in form.arrangedSubviews { row.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }

        validationLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        validationLabel.textColor = .systemRed
        validationLabel.maximumNumberOfLines = 2
        validationLabel.lineBreakMode = .byWordWrapping
        validationLabel.isHidden = true

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false

        submitButton.target = self
        submitButton.action = #selector(submitPressed(_:))
        CarrachoTheme.applyPrimaryButtonStyle(submitButton)
        submitButton.keyEquivalent = "\r"
        submitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 104).isActive = true
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelPressed(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 104).isActive = true
        let buttons = NSStackView(views: [progress, NSView(), cancel, submitButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        for child in [title, subtitle, endpointLabel, form, validationLabel, buttons] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            endpointLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            endpointLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            endpointLabel.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 3),
            form.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            form.topAnchor.constraint(equalTo: endpointLabel.bottomAnchor, constant: 15),
            validationLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            validationLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            validationLabel.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: validationLabel.bottomAnchor, constant: 8),
            buttons.heightAnchor.constraint(equalToConstant: 32),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
    }

    private func formRow(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12.5)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 78).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        control.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -88).isActive = true
        row.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return row
    }

    func beginSheet(for parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self.loginField)
        }
    }

    func setValidating(_ validating: Bool) {
        loginField.isEnabled = !validating
        passwordField.isEnabled = !validating
        submitButton.isEnabled = !validating
        if validating {
            validationLabel.isHidden = true
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
    }

    func showValidation(_ message: String) {
        setValidating(false)
        validationLabel.stringValue = message
        validationLabel.isHidden = false
        NSSound.beep()
        window?.makeFirstResponder(passwordField)
        passwordField.selectText(nil)
    }

    func completeSuccessfully() {
        dismiss()
    }

    func controlTextDidChange(_ obj: Notification) {
        validationLabel.isHidden = true
    }

    @objc private func submitPressed(_ sender: Any?) {
        // NSSecureTextField uses the shared field editor. When Return activates the default
        // button while the password field is still first responder, stringValue can otherwise
        // still contain the previously committed value (usually the initial empty string).
        // Commit editing first so password-protected Tracker accounts are validated with the
        // password the user actually typed.
        window?.endEditing(for: nil)
        let login = loginField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.stringValue
        guard !login.isEmpty else {
            showValidation(L("Enter a login."))
            window?.makeFirstResponder(loginField)
            return
        }
        setValidating(true)
        onSubmit?(login, password)
    }

    @objc private func cancelPressed(_ sender: Any?) { dismiss() }

    private func dismiss() {
        guard !didFinish else { return }
        didFinish = true
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        else { window?.orderOut(nil) }
        onFinish?()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFinish else { return }
        didFinish = true
        onFinish?()
    }
}

final class TrackerEditorWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let nameField = NSTextField(string: "")
    let addressField = NSTextField(string: "")
    let validationLabel = NSTextField(labelWithString: "")
    let applyButton: NSButton
    var onApply: ((String, String) -> String?)?
    var onFinish: (() -> Void)?
    private var didFinish = false

    init(existingName: String, existingAddress: String, isNew: Bool) {
        applyButton = NSButton(title: isNew ? L("Add") : L("Apply"), target: nil, action: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = isNew ? L("Add Tracker") : L("Edit Tracker")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        nameField.stringValue = existingName
        addressField.stringValue = existingAddress
        buildInterface(in: window, isNew: isNew)
    }

    required init?(coder: NSCoder) { nil }

    private func buildInterface(in window: NSWindow, isNew: Bool) {
        let root = CarrachoBackgroundView()
        root.fillColor = CarrachoTheme.canvas
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let title = NSTextField(labelWithString: isNew ? L("Add Tracker") : L("Edit Tracker"))
        title.font = .systemFont(ofSize: 22, weight: .bold)

        let subtitle = NSTextField(wrappingLabelWithString: L("Use a host name or host:port. When no port is specified, the server uses the Classic Tracker port 6702."))
        subtitle.font = .systemFont(ofSize: 12.5)
        subtitle.textColor = CarrachoTheme.secondaryText
        subtitle.maximumNumberOfLines = 2

        let card = CarrachoCardView()
        card.fillColor = CarrachoTheme.elevatedCard
        card.cornerRadius = 11

        nameField.placeholderString = L("Optional display name")
        nameField.setAccessibilityLabel(L("Tracker name"))
        addressField.placeholderString = "tracker.example.org or tracker.example.org:6702"
        addressField.setAccessibilityLabel(L("Tracker address"))
        for field in [nameField, addressField] {
            field.controlSize = .regular
            field.font = .systemFont(ofSize: 13)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(equalToConstant: 30).isActive = true
            field.delegate = self
        }

        let nameGroup = labeledField(L("Name"), field: nameField)
        let addressGroup = labeledField(L("Address"), field: addressField)
        let fields = stack([nameGroup, addressGroup], spacing: 12)
        card.addSubview(fields)
        NSLayoutConstraint.activate([
            fields.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            fields.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            fields.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
            fields.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -15),
        ])

        validationLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        validationLabel.textColor = .systemRed
        validationLabel.maximumNumberOfLines = 2
        validationLabel.lineBreakMode = .byWordWrapping
        validationLabel.isHidden = true
        validationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cancelButton = NSButton(title: L("Cancel"), target: self, action: #selector(cancelPressed(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 94).isActive = true

        applyButton.target = self
        applyButton.action = #selector(applyPressed(_:))
        CarrachoTheme.applyPrimaryButtonStyle(applyButton)
        applyButton.keyEquivalent = "\r"
        applyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 106).isActive = true
        applyButton.isEnabled = !addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let buttons = NSStackView(views: [validationLabel, NSView(), cancelButton, applyButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for view in [title, subtitle, card, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),

            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            card.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            card.heightAnchor.constraint(equalToConstant: 130),

            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 18),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
    }

    private func labeledField(_ text: String, field: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = CarrachoTheme.secondaryText
        return stack([label, field], spacing: 5)
    }

    private func stack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    func beginSheet(for parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self.addressField.stringValue.isEmpty ? self.addressField : self.nameField)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        applyButton.isEnabled = !addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        validationLabel.isHidden = true
    }

    @objc private func applyPressed(_ sender: Any?) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            showValidation(L("Tracker address must not be empty."))
            return
        }
        if let error = onApply?(name, address) {
            showValidation(error)
            return
        }
        dismiss()
    }

    @objc private func cancelPressed(_ sender: Any?) { dismiss() }

    private func showValidation(_ message: String) {
        validationLabel.stringValue = message
        validationLabel.isHidden = false
        NSSound.beep()
    }

    private func dismiss() {
        guard !didFinish else { return }
        didFinish = true
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        else { window?.orderOut(nil) }
        onFinish?()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFinish else { return }
        didFinish = true
        onFinish?()
    }
}

// MARK: - Tracker

extension ViewController {

    func makeTrackerBrowserPage() -> NSView {
        let page = NSView()
        let card = CarrachoCardView()
        card.fillColor = CarrachoTheme.conferenceTranscriptBackground
        trackerBrowserTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        trackerBrowserTitleLabel.lineBreakMode = .byTruncatingMiddle
        trackerBrowserTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let icon = symbolView("point.3.filled.connected.trianglepath.dotted", size: 21, tint: CarrachoTheme.selection)
        let refresh = NSButton(title: L("Refresh"), target: self, action: #selector(refreshSelectedClientTracker(_:)))
        styleIconButton(refresh, symbol: "arrow.clockwise", help: L("Refresh Tracker"))
        let header = horizontalStack([icon, trackerBrowserTitleLabel, NSView(), refresh], spacing: 8)
        let scroll = tableScroll(trackerBrowserTable)
        let stack = verticalStack([header, trackerBrowserStatusLabel, scroll], spacing: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
        card.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            card.topAnchor.constraint(equalTo: page.topAnchor),
            card.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        return page
    }

    func makeTrackersAdminPage() -> NSView {
        let page = adminPage(title: L("Trackers"), subtitle: L("Choose where this server is published"))
        guard let header = page.subviews.first(where: { $0.identifier?.rawValue == "adminHeader" }) else { return page }

        adminTrackerRegisterCheckbox.target = self
        adminTrackerRegisterCheckbox.action = #selector(trackerDraftControlChanged(_:))
        adminTrackerRegisterCheckbox.toolTip = L("Controls whether the server sends registrations to the trackers marked Use. Turning this off keeps the configured tracker list and selections.")
        adminTrackerRegisterCheckbox.setAccessibilityLabel(L("Publish server on trackers"))

        adminTrackerPrivateCheckbox.target = self
        adminTrackerPrivateCheckbox.action = #selector(trackerDraftControlChanged(_:))
        adminTrackerPrivateCheckbox.toolTip = L("Advertise this server as private. Legacy Trackers use this flag to decide whether clients should ask for a server account before connecting.")
        adminTrackerPrivateCheckbox.setAccessibilityLabel(L("Private Tracker listing"))

        adminTrackerBandwidthPopup.removeAllItems()
        for option in LegacyTrackerProtocol.bandwidthOptions {
            adminTrackerBandwidthPopup.addItem(withTitle: option.title)
            adminTrackerBandwidthPopup.lastItem?.tag = Int(option.code)
        }
        adminTrackerBandwidthPopup.target = self
        adminTrackerBandwidthPopup.action = #selector(trackerDraftControlChanged(_:))
        adminTrackerBandwidthPopup.toolTip = L("Directory listing value advertised to Trackers. This is not a transfer speed limit or a measurement.")
        adminTrackerBandwidthPopup.setAccessibilityLabel(L("Tracker bandwidth class"))

        adminTrackerDescriptionField.placeholderString = L("Description shown in tracker listings")
        adminTrackerDescriptionField.delegate = self
        adminTrackerDescriptionField.toolTip = L("Separate description sent in Tracker registrations. Classic encoding limits still apply.")
        adminTrackerDescriptionField.setAccessibilityLabel(L("Tracker listing description"))

        configure(table: adminTrackerTable, columns: [
            ("enabled", "Use", 64),
            ("name", "Tracker", 230),
            ("address", "Address", 360),
            ("actions", "", 76),
        ])
        adminTrackerTable.usesAlternatingRowBackgroundColors = false
        adminTrackerTable.backgroundColor = .clear
        adminTrackerTable.rowHeight = 38
        adminTrackerTable.intercellSpacing = NSSize(width: 8, height: 1)
        adminTrackerTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        adminTrackerTable.allowsMultipleSelection = false
        if let enabledColumn = adminTrackerTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("enabled")) {
            enabledColumn.width = 64
            enabledColumn.minWidth = 64
            enabledColumn.maxWidth = 64
            enabledColumn.resizingMask = []
            enabledColumn.sortDescriptorPrototype = nil
        }
        if let actionsColumn = adminTrackerTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("actions")) {
            actionsColumn.width = 76
            actionsColumn.minWidth = 76
            actionsColumn.maxWidth = 76
            actionsColumn.resizingMask = []
            actionsColumn.sortDescriptorPrototype = nil
        }
        adminTrackerTable.target = self
        adminTrackerTable.doubleAction = #selector(modifySelectedTracker(_:))

        let listScroll = tableScroll(adminTrackerTable)
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        adminTrackerEmptyLabel.font = .systemFont(ofSize: 11.5)
        adminTrackerEmptyLabel.textColor = CarrachoTheme.secondaryText
        adminTrackerEmptyLabel.alignment = .center
        adminTrackerEmptyLabel.maximumNumberOfLines = 2
        adminTrackerEmptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let listSurface = CarrachoCardView()
        listSurface.fillColor = CarrachoTheme.card
        listSurface.cornerRadius = 8
        listSurface.translatesAutoresizingMaskIntoConstraints = false
        listSurface.addSubview(listScroll)
        listSurface.addSubview(adminTrackerEmptyLabel)
        adminTrackerListHeightConstraint = listSurface.heightAnchor.constraint(equalToConstant: 132)
        adminTrackerListHeightConstraint?.isActive = true
        NSLayoutConstraint.activate([
            listScroll.leadingAnchor.constraint(equalTo: listSurface.leadingAnchor, constant: 1),
            listScroll.trailingAnchor.constraint(equalTo: listSurface.trailingAnchor, constant: -1),
            listScroll.topAnchor.constraint(equalTo: listSurface.topAnchor, constant: 1),
            listScroll.bottomAnchor.constraint(equalTo: listSurface.bottomAnchor, constant: -1),
            adminTrackerEmptyLabel.centerXAnchor.constraint(equalTo: listSurface.centerXAnchor),
            adminTrackerEmptyLabel.centerYAnchor.constraint(equalTo: listSurface.centerYAnchor, constant: 12),
            adminTrackerEmptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: listSurface.leadingAnchor, constant: 24),
            adminTrackerEmptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: listSurface.trailingAnchor, constant: -24),
        ])

        adminTrackerAddButton.target = self
        adminTrackerAddButton.action = #selector(addTracker(_:))
        adminTrackerAddButton.bezelStyle = .rounded
        adminTrackerAddButton.image = symbolImage("plus", fallback: NSImage.addTemplateName)
        adminTrackerAddButton.imagePosition = .imageLeading
        adminTrackerAddButton.toolTip = L("Add a configured Tracker")
        adminTrackerAddButton.setAccessibilityLabel(L("Add Tracker"))

        let publicationTitle = NSTextField(labelWithString: L("Publish server on trackers"))
        publicationTitle.font = .systemFont(ofSize: 13.5, weight: .semibold)
        let publicationSubtitle = infoLabel(L("Uses the trackers marked Use below."))
        let publicationText = verticalStack([publicationTitle, publicationSubtitle], spacing: 2)
        let publicationHelp = infoLabel(L("Turning publication off keeps the configured tracker list and every per-tracker selection. No selected Tracker is used for registration while this switch is off."))
        publicationHelp.maximumNumberOfLines = 3
        let publicationCard = CarrachoCardView()
        publicationCard.fillColor = CarrachoTheme.card
        publicationCard.cornerRadius = 8
        let publicationStack = verticalStack([
            horizontalStack([symbolView("globe", size: 16, tint: CarrachoTheme.accent), publicationText, NSView(), adminTrackerRegisterCheckbox], spacing: 10),
            publicationHelp,
        ], spacing: 8)
        publicationStack.translatesAutoresizingMaskIntoConstraints = false
        publicationCard.addSubview(publicationStack)
        NSLayoutConstraint.activate([
            publicationStack.leadingAnchor.constraint(equalTo: publicationCard.leadingAnchor, constant: 13),
            publicationStack.trailingAnchor.constraint(equalTo: publicationCard.trailingAnchor, constant: -13),
            publicationStack.topAnchor.constraint(equalTo: publicationCard.topAnchor, constant: 12),
            publicationStack.bottomAnchor.constraint(equalTo: publicationCard.bottomAnchor, constant: -12),
        ])

        let trackerSectionTitle = NSTextField(labelWithString: L("Tracker Selection"))
        trackerSectionTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        adminTrackerSelectionSummaryLabel.font = .systemFont(ofSize: 10.5)
        adminTrackerSelectionSummaryLabel.textColor = CarrachoTheme.secondaryText
        adminTrackerSelectionSummaryLabel.lineBreakMode = .byTruncatingTail
        let trackerHeader = horizontalStack([trackerSectionTitle, NSView(), adminTrackerAddButton], spacing: 10)
        let trackerSection = verticalStack([trackerHeader, listSurface, adminTrackerSelectionSummaryLabel], spacing: 7)

        let listingTitle = NSTextField(labelWithString: L("Directory Details"))
        listingTitle.font = .systemFont(ofSize: 13.5, weight: .semibold)
        let privacyTitle = makeLabel(L("Private"))
        privacyTitle.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let privacyHelp = infoLabel(L("Public entries connect directly as guests. Private entries ask for an account login before creating a bookmark."))
        privacyHelp.maximumNumberOfLines = 2
        let privacyControl = verticalStack([
            horizontalStack([privacyTitle, adminTrackerPrivateCheckbox, NSView()], spacing: 10),
            privacyHelp,
        ], spacing: 4)
        let bandwidthLabel = makeLabel(L("Bandwidth class"))
        bandwidthLabel.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let bandwidthHelp = infoLabel(L("This value is only advertised in Tracker directory entries. It is not a transfer limit and is not measured automatically."))
        bandwidthHelp.maximumNumberOfLines = 2
        let bandwidthControl = verticalStack([
            horizontalStack([bandwidthLabel, adminTrackerBandwidthPopup, NSView()], spacing: 10),
            bandwidthHelp,
        ], spacing: 4)
        let descriptionLabel = makeLabel(L("Description"))
        descriptionLabel.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let descriptionRow = horizontalStack([descriptionLabel, adminTrackerDescriptionField], spacing: 10)
        adminTrackerDescriptionField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let descriptionHelp = infoLabel(L("This Tracker description is separate from the general server description and follows the existing Classic MacRoman/255-byte limit."))
        descriptionHelp.maximumNumberOfLines = 2
        let listingCard = CarrachoCardView()
        listingCard.fillColor = CarrachoTheme.card
        listingCard.cornerRadius = 8
        let listingStack = verticalStack([
            horizontalStack([symbolView("text.badge.checkmark", size: 16, tint: CarrachoTheme.accent), listingTitle, NSView()], spacing: 8),
            CarrachoDividerView(),
            privacyControl,
            bandwidthControl,
            descriptionRow,
            descriptionHelp,
        ], spacing: 9)
        listingStack.translatesAutoresizingMaskIntoConstraints = false
        listingCard.addSubview(listingStack)
        NSLayoutConstraint.activate([
            listingStack.leadingAnchor.constraint(equalTo: listingCard.leadingAnchor, constant: 13),
            listingStack.trailingAnchor.constraint(equalTo: listingCard.trailingAnchor, constant: -13),
            listingStack.topAnchor.constraint(equalTo: listingCard.topAnchor, constant: 12),
            listingStack.bottomAnchor.constraint(equalTo: listingCard.bottomAnchor, constant: -12),
        ])

        adminTrackerDiscardButton.target = self
        adminTrackerDiscardButton.action = #selector(discardTrackerChanges(_:))
        adminTrackerDiscardButton.bezelStyle = .rounded
        adminTrackerDiscardButton.setAccessibilityLabel(L("Discard Tracker changes"))
        adminTrackerSaveButton.target = self
        adminTrackerSaveButton.action = #selector(saveTrackerSettings(_:))
        CarrachoTheme.applyPrimaryButtonStyle(adminTrackerSaveButton)
        adminTrackerSaveButton.keyEquivalent = "\r"
        adminTrackerSaveButton.setAccessibilityLabel(L("Save Tracker settings"))
        adminTrackerStatusLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        adminTrackerStatusLabel.textColor = CarrachoTheme.secondaryText
        adminTrackerStatusLabel.lineBreakMode = .byTruncatingTail
        adminTrackerStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions = horizontalStack([
            adminTrackerStatusLabel, NSView(), adminTrackerDiscardButton, adminTrackerSaveButton,
        ], spacing: 9)

        let protocolNote = infoLabel(L("Saving configures the server and, when publication is enabled, triggers its normal Tracker registration/refresh behavior. It does not confirm that a Tracker accepted or currently lists the server."))
        protocolNote.maximumNumberOfLines = 3
        let content = verticalStack([
            publicationCard,
            trackerSection,
            listingCard,
            CarrachoDividerView(),
            actions,
            protocolNote,
        ], spacing: 14)
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

        updateTrackerEditorState()
        return page
    }

    func confirmTrackerChangesCanBeAbandoned() -> Bool {
        guard trackerHasUnsavedChanges else { return true }
        if trackerSaveInProgress {
            showError(L("Tracker settings are still being saved. Wait for the operation to finish before leaving this view."))
            return false
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Discard Unsaved Tracker Changes?")
        alert.informativeText = L("The current Tracker configuration draft has not been saved. Discard it before leaving this server or view?")
        alert.addButton(withTitle: L("Keep Editing"))
        alert.addButton(withTitle: L("Discard Changes"))
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        discardTrackerChanges(nil)
        return true
    }

    func currentTrackerSourceKey() -> String {
        if client.isConnected {
            if let id = activeBookmarkConnectionID { return "remote:\(id.uuidString.lowercased())" }
            return "remote:\(hostField.stringValue.lowercased()):\(portField.stringValue):\(loginField.stringValue.lowercased())"
        }
        return "local"
    }

    func selectTrackerBandwidth(from flags: UInt32) {
        let code = UInt8((flags >> 24) & 0xff)
        if let transientIndex = adminTrackerBandwidthPopup.itemArray.firstIndex(where: { $0.representedObject as? String == "transient" }) {
            adminTrackerBandwidthPopup.removeItem(at: transientIndex)
        }
        if let item = adminTrackerBandwidthPopup.itemArray.first(where: { $0.tag == Int(code) }) {
            adminTrackerBandwidthPopup.select(item)
            return
        }
        // Zero is the old/unset default. Unknown legacy values are kept visible rather than
        // silently rewritten merely because the administrator opened this page.
        let title = code == 0 ? L("Not specified") : LF("Unknown (code %@)", String(code))
        adminTrackerBandwidthPopup.insertItem(withTitle: title, at: 0)
        adminTrackerBandwidthPopup.item(at: 0)?.tag = Int(code)
        adminTrackerBandwidthPopup.item(at: 0)?.representedObject = "transient"
        adminTrackerBandwidthPopup.selectItem(at: 0)
    }

    func decodeTrackerAdvertisementFlags(_ data: Data) throws -> UInt32 {
        switch data.count {
        case 4:
            var cursor = LegacyByteCursor(data)
            return try cursor.readUInt32BE()
        case 3:
            let bytes = Array(data)
            return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8)
        default:
            throw LegacyProtocolError.invalidLength("tracker advertisement flags must be 3 or 4 bytes")
        }
    }

    func currentTrackerDraft() -> TrackerAdminSnapshot {
        TrackerAdminSnapshot(
            trackers: trackerDraftTrackers,
            advertisementFlags: LegacyTrackerProtocol.advertisementFlags(
                preserving: trackerDraftAdvertisementFlags,
                bandwidthCode: selectedTrackerBandwidthCode,
                registered: adminTrackerRegisterCheckbox.state == .on,
                isPrivate: adminTrackerPrivateCheckbox.state == .on
            ),
            description: adminTrackerDescriptionField.stringValue
        )
    }

    func normalizedTrackerDraftForSaving() -> TrackerAdminSnapshot {
        var draft = currentTrackerDraft()
        draft.description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft
    }

    func trackerValidationError(for draft: TrackerAdminSnapshot) -> String? {
        guard draft.trackers.count <= Int(UInt16.max) else { return L("The Tracker list exceeds 65535 entries.") }
        for (index, tracker) in draft.trackers.enumerated() {
            do {
                _ = try tracker.legacyRecord()
                _ = try LegacyTrackerNotifier.parseEndpoint(tracker.address)
            } catch {
                let label = tracker.name.isEmpty ? LF("Tracker %@", String(index + 1)) : "“\(tracker.name)”"
                return "\(label): \(Self.displayMessage(for: error))"
            }
        }
        guard let description = draft.description.data(using: .macOSRoman), description.count <= 255 else {
            return L("Tracker description must be MacRoman-compatible and at most 255 bytes.")
        }
        if !client.isConnected, let backend = serverBackend,
           (draft.advertisementFlags & LegacyTrackerProtocol.registeredFlag) != 0 {
            do {
                var state = backend.snapshot()
                state.advanced.trackers = draft.trackers
                state.advanced.trackerAdvertisementFlags = draft.advertisementFlags
                state.advanced.trackerDescription = draft.description
                try ServerStateValidator.validateTrackerRegistrationEligibility(state)
            } catch {
                return Self.displayMessage(for: error)
            }
        }
        return nil
    }

    func applyTrackerSnapshot(_ snapshot: TrackerAdminSnapshot, sourceKey: String, status: String? = nil) {
        trackerLoadedSnapshot = snapshot
        trackerDraftTrackers = snapshot.trackers
        trackerDraftAdvertisementFlags = snapshot.advertisementFlags
        trackerSourceKey = sourceKey
        trackerHasUnsavedChanges = false
        trackerSaveInProgress = false
        remoteTrackerSettingsLoading = false
        adminTrackerRegisterCheckbox.state = (snapshot.advertisementFlags & LegacyTrackerProtocol.registeredFlag) != 0 ? .on : .off
        adminTrackerPrivateCheckbox.state = (snapshot.advertisementFlags & LegacyTrackerProtocol.privateFlag) != 0 ? .on : .off
        selectTrackerBandwidth(from: snapshot.advertisementFlags)
        adminTrackerDescriptionField.stringValue = snapshot.description
        trackerStatusOverride = status
        trackerStatusColor = nil
        adminTrackerTable.reloadData()
        updateTrackerEditorState()
    }

    func updateTrackerListPresentation() {
        let total = trackerDraftTrackers.count
        let selected = trackerDraftTrackers.filter(\.isRegistrationEnabled).count
        adminTrackerEmptyLabel.isHidden = total != 0 || remoteTrackerSettingsLoading
        adminTrackerListHeightConstraint?.constant = min(300, max(122, 34 + CGFloat(max(1, total)) * 39))
        if total == 0 {
            adminTrackerSelectionSummaryLabel.stringValue = adminTrackerRegisterCheckbox.state == .on
                ? L("No trackers selected · publication has no destinations")
                : L("No trackers configured")
        } else {
            let suffix = adminTrackerRegisterCheckbox.state == .on ? "" : L(" · publication is off")
            adminTrackerSelectionSummaryLabel.stringValue = LF("%@ of %@ selected%@", String(selected), String(total), suffix)
        }
    }

    func updateTrackerEditorState() {
        let canEdit = client.isConnected
            ? remotePermissionEnabled(LegacyAccountPermissionBit.editTrackers)
            : serverBackend != nil
        let sourceMatchesCurrent = trackerSourceKey == currentTrackerSourceKey()
        let ready = trackerLoadedSnapshot != nil && !remoteTrackerSettingsLoading
        // A disconnected remote draft must never become editable against the local server backend.
        // Keep it visible for reconnect/discard, but only enable Save once the original source is active again.
        let editorEnabled = canEdit && sourceMatchesCurrent && ready && !trackerSaveInProgress
        let draft = currentTrackerDraft()
        let validationError = ready ? trackerValidationError(for: draft) : nil

        adminTrackerRegisterCheckbox.isEnabled = editorEnabled
        adminTrackerPrivateCheckbox.isEnabled = editorEnabled
        adminTrackerBandwidthPopup.isEnabled = editorEnabled
        adminTrackerDescriptionField.isEnabled = editorEnabled
        adminTrackerAddButton.isEnabled = editorEnabled
        adminTrackerTable.isEnabled = editorEnabled
        adminTrackerDiscardButton.isEnabled = trackerHasUnsavedChanges && !trackerSaveInProgress
        adminTrackerSaveButton.isEnabled = editorEnabled && trackerHasUnsavedChanges && validationError == nil
        CarrachoTheme.setPrimaryButtonTitle(adminTrackerSaveButton, trackerSaveInProgress ? L("Saving…") : L("Save"))
        updateTrackerListPresentation()

        if let status = trackerStatusOverride {
            adminTrackerStatusLabel.stringValue = status
            adminTrackerStatusLabel.textColor = trackerStatusColor ?? CarrachoTheme.secondaryText
        } else if remoteTrackerSettingsLoading {
            adminTrackerStatusLabel.stringValue = L("Loading Tracker settings…")
            adminTrackerStatusLabel.textColor = CarrachoTheme.secondaryText
        } else if trackerSaveInProgress {
            adminTrackerStatusLabel.stringValue = L("Saving Tracker settings…")
            adminTrackerStatusLabel.textColor = CarrachoTheme.secondaryText
        } else if let validationError {
            adminTrackerStatusLabel.stringValue = LF("Cannot save: %@", validationError)
            adminTrackerStatusLabel.textColor = .systemRed
        } else if trackerHasUnsavedChanges {
            adminTrackerStatusLabel.stringValue = L("Unsaved changes")
            adminTrackerStatusLabel.textColor = CarrachoTheme.warning
        } else if ready {
            adminTrackerStatusLabel.stringValue = L("No unsaved changes")
            adminTrackerStatusLabel.textColor = CarrachoTheme.secondaryText
        } else if client.isConnected && !canEdit {
            adminTrackerStatusLabel.stringValue = L("This account cannot edit Tracker settings on the connected server.")
            adminTrackerStatusLabel.textColor = .systemRed
        } else {
            adminTrackerStatusLabel.stringValue = L("Tracker settings are unavailable.")
            adminTrackerStatusLabel.textColor = CarrachoTheme.secondaryText
        }
        adminTrackerStatusLabel.toolTip = adminTrackerStatusLabel.stringValue
        adminTrackerModifyButton.isEnabled = editorEnabled && adminTrackerTable.selectedRow >= 0 && adminTrackerTable.selectedRow < displayedTrackers.count
        adminTrackerDeleteButton.isEnabled = adminTrackerModifyButton.isEnabled
    }

    func markTrackerDraftChanged() {
        guard !trackerSaveInProgress, trackerLoadedSnapshot != nil else { return }
        trackerStatusOverride = nil
        trackerStatusColor = nil
        trackerHasUnsavedChanges = currentTrackerDraft() != trackerLoadedSnapshot
        adminTrackerTable.reloadData()
        updateTrackerEditorState()
    }

    @objc func trackerDraftControlChanged(_ sender: Any?) {
        markTrackerDraftChanged()
    }

    func reloadTrackerAdministration() {
        let sourceKey = currentTrackerSourceKey()
        if trackerHasUnsavedChanges, trackerSourceKey == sourceKey {
            updateTrackerEditorState()
            return
        }
        if !client.isConnected,
           trackerHasUnsavedChanges,
           trackerSourceKey?.hasPrefix("remote:") == true {
            trackerStatusOverride = L("Connection lost. Unsaved Tracker changes were kept; reconnect, save, or discard them before editing another server.")
            trackerStatusColor = CarrachoTheme.warning
            updateTrackerEditorState()
            return
        }

        if !client.isConnected {
            trackerLoadGeneration &+= 1
            remoteTrackerSettingsLoading = false
            guard let backend = serverBackend else {
                trackerLoadedSnapshot = nil
                trackerDraftTrackers = []
                trackerSourceKey = "local"
                trackerStatusOverride = L("Local server Tracker settings are unavailable.")
                trackerStatusColor = .systemRed
                adminTrackerTable.reloadData()
                updateTrackerEditorState()
                return
            }
            let advanced = backend.snapshot().advanced
            applyTrackerSnapshot(TrackerAdminSnapshot(trackers: advanced.trackers,
                                                      advertisementFlags: advanced.trackerAdvertisementFlags,
                                                      description: advanced.trackerDescription),
                                 sourceKey: "local")
            return
        }

        trackerLoadGeneration &+= 1
        let generation = trackerLoadGeneration
        let target = client
        let sourceChanged = trackerSourceKey != sourceKey
        trackerSourceKey = sourceKey
        trackerStatusOverride = nil
        trackerStatusColor = nil
        guard remotePermissionEnabled(LegacyAccountPermissionBit.editTrackers) else {
            remoteTrackerSettingsLoading = false
            trackerLoadedSnapshot = nil
            trackerDraftTrackers = []
            trackerDraftAdvertisementFlags = 0
            adminTrackerRegisterCheckbox.state = .off
            adminTrackerPrivateCheckbox.state = .off
            selectTrackerBandwidth(from: 0)
            adminTrackerDescriptionField.stringValue = ""
            trackerStatusOverride = L("This account cannot edit Tracker settings on the connected server.")
            trackerStatusColor = .systemRed
            adminTrackerTable.reloadData()
            updateTrackerEditorState()
            return
        }

        if trackerLoadedSnapshot == nil || sourceChanged {
            trackerLoadedSnapshot = nil
            trackerDraftTrackers = []
            trackerDraftAdvertisementFlags = 0
            adminTrackerRegisterCheckbox.state = .off
            adminTrackerPrivateCheckbox.state = .off
            selectTrackerBandwidth(from: 0)
            adminTrackerDescriptionField.stringValue = ""
            adminTrackerTable.reloadData()
        }
        remoteTrackerSettingsLoading = true
        updateTrackerEditorState()
        target.requestServerSettings(fields: [LegacyServerSettingField.trackerList,
                                              LegacyServerSettingField.trackerRegistrationFlags,
                                              LegacyServerSettingField.trackerDescription]) { [weak self, weak target] result in
            guard let self, let target, self.client === target,
                  self.trackerLoadGeneration == generation,
                  self.currentTrackerSourceKey() == sourceKey else { return }
            self.remoteTrackerSettingsLoading = false
            do {
                let values = try result.get()
                guard let listData = values[LegacyServerSettingField.trackerList],
                      let flagsData = values[LegacyServerSettingField.trackerRegistrationFlags],
                      let descriptionData = values[LegacyServerSettingField.trackerDescription] else {
                    throw LegacyProtocolError.invalidRecord(L("Connected server did not return complete Tracker settings."))
                }
                let trackers = try LegacyServerSettingField.decodeTrackerSettings(listData).map(ServerTrackerSetting.init(legacy:))
                let flags = try self.decodeTrackerAdvertisementFlags(flagsData)
                guard let description = String(data: descriptionData, encoding: .macOSRoman) else {
                    throw LegacyProtocolError.invalidRecord(L("Tracker description is not valid MacRoman."))
                }
                self.applyTrackerSnapshot(TrackerAdminSnapshot(trackers: trackers,
                                                               advertisementFlags: flags,
                                                               description: description),
                                          sourceKey: sourceKey)
            } catch {
                self.trackerStatusOverride = self.trackerLoadedSnapshot == nil
                    ? LF("Could not load Tracker settings: %@", Self.displayMessage(for: error))
                    : LF("Refresh failed: %@. Existing values were kept.", Self.displayMessage(for: error))
                self.trackerStatusColor = .systemRed
                self.updateTrackerEditorState()
            }
        }
    }

    @objc func addTracker(_ sender: Any?) {
        presentTrackerEditor(index: nil)
    }

    @objc func toggleTrackerRegistration(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < displayedTrackers.count else {
            adminTrackerTable.reloadData()
            return
        }
        guard let index = trackerDraftIndex(forDisplayedRow: row) else {
            adminTrackerTable.reloadData()
            return
        }
        trackerDraftTrackers[index].isRegistrationEnabled = sender.state == .on
        markTrackerDraftChanged()
    }

    func trackerEnabledCell(for tracker: ServerTrackerSetting, row: Int) -> NSView {
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleTrackerRegistration(_:)))
        checkbox.state = tracker.isRegistrationEnabled ? .on : .off
        checkbox.tag = row
        checkbox.toolTip = tracker.isRegistrationEnabled ? L("Use this Tracker for publication") : L("Do not use this Tracker for publication")
        checkbox.setAccessibilityLabel(LF("Use %@", tracker.name.isEmpty ? tracker.address : tracker.name))
        checkbox.isEnabled = adminTrackerTable.isEnabled
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            checkbox.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    func trackerActionsCell(row: Int) -> NSView {
        let edit = NSButton(title: "", target: self, action: #selector(editTrackerRow(_:)))
        edit.tag = row
        styleIconButton(edit, symbol: "pencil", help: L("Edit Tracker"))
        edit.isEnabled = adminTrackerTable.isEnabled
        let more = NSButton(title: "", target: self, action: #selector(showTrackerRowActions(_:)))
        more.tag = row
        styleIconButton(more, symbol: "ellipsis", help: L("Tracker actions"))
        more.isEnabled = adminTrackerTable.isEnabled
        return horizontalStack([edit, more], spacing: 2)
    }

    @objc func editTrackerRow(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < displayedTrackers.count else { return }
        editDisplayedTracker(at: sender.tag)
    }

    @objc func showTrackerRowActions(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < displayedTrackers.count else { return }
        let menu = NSMenu(title: L("Tracker Actions"))
        let edit = NSMenuItem(title: L("Edit Tracker…"), action: #selector(editTrackerFromMenu(_:)), keyEquivalent: "")
        edit.target = self
        edit.tag = sender.tag
        menu.addItem(edit)
        menu.addItem(.separator())
        let remove = NSMenuItem(title: L("Remove Tracker…"), action: #selector(removeTrackerFromMenu(_:)), keyEquivalent: "")
        remove.target = self
        remove.tag = sender.tag
        menu.addItem(remove)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc func editTrackerFromMenu(_ sender: NSMenuItem) {
        editDisplayedTracker(at: sender.tag)
    }

    @objc func removeTrackerFromMenu(_ sender: NSMenuItem) {
        requestRemoveDisplayedTracker(at: sender.tag)
    }

    func editDisplayedTracker(at row: Int) {
        guard row >= 0, row < displayedTrackers.count else { return }
        guard let index = trackerDraftIndex(forDisplayedRow: row) else { return }
        presentTrackerEditor(index: index)
    }

    @objc func modifySelectedTracker(_ sender: Any?) {
        let row = adminTrackerTable.clickedRow >= 0 ? adminTrackerTable.clickedRow : adminTrackerTable.selectedRow
        editDisplayedTracker(at: row)
    }

    func requestRemoveDisplayedTracker(at row: Int) {
        guard row >= 0, row < displayedTrackers.count, let window = view.window else { return }
        let tracker = displayedTrackers[row]
        guard let draftIndex = trackerDraftIndex(forDisplayedRow: row) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Remove Tracker?")
        alert.informativeText = LF("Remove “%@” from this configuration draft? The server is not changed until you choose Save.", tracker.name.isEmpty ? tracker.address : tracker.name)
        alert.addButton(withTitle: L("Remove"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  self.trackerDraftTrackers.indices.contains(draftIndex),
                  self.trackerDraftTrackers[draftIndex] == tracker else { return }
            self.trackerDraftTrackers.remove(at: draftIndex)
            self.markTrackerDraftChanged()
        }
    }

    @objc func deleteSelectedTracker(_ sender: Any?) {
        let row = adminTrackerTable.clickedRow >= 0 ? adminTrackerTable.clickedRow : adminTrackerTable.selectedRow
        requestRemoveDisplayedTracker(at: row)
    }

    func presentTrackerEditor(index: Int?, nameValue: String? = nil, addressValue: String? = nil, validationMessage: String? = nil) {
        guard let window = view.window else { return }
        let existing = index.flatMap { trackerDraftTrackers.indices.contains($0) ? trackerDraftTrackers[$0] : nil }
        let controller = TrackerEditorWindowController(
            existingName: nameValue ?? existing?.name ?? "",
            existingAddress: addressValue ?? existing?.address ?? "",
            isNew: existing == nil
        )
        trackerEditorWindowController = controller
        controller.onApply = { [weak self] name, address in
            guard let self else { return L("The Tracker editor is no longer available.") }
            do {
                let endpoint = try LegacyTrackerNotifier.parseEndpoint(address)
                let isClassicRemote = self.client.isConnected && self.client.transferSession?.usesModernCrypto == false
                if isClassicRemote && endpoint.port != LegacyTrackerProtocol.port {
                    return LF("Classic Carracho Server uses Tracker port %@ only. Use a Tracker listening on that port.",
                              String(LegacyTrackerProtocol.port))
                }
                // Server 1.0b13 passes the configured address directly to its resolver and
                // always connects to TCP 6702. Strip an explicit :6702 before storing the
                // record so a modern editor cannot accidentally give Classic a host:port
                // string that it would try to resolve as a literal host name.
                let storedAddress = isClassicRemote ? endpoint.host : address
                var tracker = ServerTrackerSetting(name: name,
                                                   address: storedAddress,
                                                   reservedString: existing?.reservedString ?? "",
                                                   reservedValue: existing?.reservedValue ?? 0)
                if existing == nil { tracker.isRegistrationEnabled = true }
                _ = try tracker.legacyRecord()
                if let index {
                    guard self.trackerDraftTrackers.indices.contains(index) else {
                        throw ServerStateError.invalidValue(L("The Tracker draft changed while the editor was open."))
                    }
                    self.trackerDraftTrackers[index] = tracker
                } else {
                    self.trackerDraftTrackers.append(tracker)
                }
                self.markTrackerDraftChanged()
                return nil
            } catch {
                return Self.displayMessage(for: error)
            }
        }
        controller.onFinish = { [weak self, weak controller] in
            guard let self else { return }
            if self.trackerEditorWindowController === controller {
                self.trackerEditorWindowController = nil
            }
        }
        if let validationMessage {
            controller.validationLabel.stringValue = validationMessage
            controller.validationLabel.isHidden = false
        }
        controller.beginSheet(for: window)
    }

    @objc func discardTrackerChanges(_ sender: Any?) {
        guard let snapshot = trackerLoadedSnapshot, let sourceKey = trackerSourceKey else { return }
        applyTrackerSnapshot(snapshot, sourceKey: sourceKey, status: L("Unsaved Tracker changes discarded."))
    }

    @objc func saveTrackerSettings(_ sender: Any?) {
        guard !trackerSaveInProgress else { return }
        var draft = normalizedTrackerDraftForSaving()
        if let validationError = trackerValidationError(for: draft) {
            trackerStatusOverride = LF("Cannot save: %@", validationError)
            trackerStatusColor = .systemRed
            updateTrackerEditorState()
            return
        }
        do {
            // Encoding here validates all Classic string sizes before any server mutation is attempted.
            let listData = try LegacyServerSettingField.encodeTrackerSettings(draft.trackers.map { try $0.legacyRecord() })
            guard let descriptionData = draft.description.data(using: .macOSRoman), descriptionData.count <= 255 else {
                throw ServerStateError.invalidValue(L("Tracker description must be MacRoman-compatible and at most 255 bytes."))
            }
            trackerSaveInProgress = true
            trackerStatusOverride = nil
            trackerStatusColor = nil
            updateTrackerEditorState()

            if client.isConnected {
                guard remotePermissionEnabled(LegacyAccountPermissionBit.editTrackers) else {
                    throw ServerStateError.invalidValue(L("This account cannot edit Tracker settings on the connected server."))
                }
                let target = client
                let sourceKey = currentTrackerSourceKey()
                target.setServerSettings([
                    LegacyTLV(type: LegacyServerSettingField.trackerList, value: listData),
                    LegacyTLV(type: LegacyServerSettingField.trackerRegistrationFlags, value: LegacyWire.uint32BE(draft.advertisementFlags)),
                    LegacyTLV(type: LegacyServerSettingField.trackerDescription, value: descriptionData),
                ]) { [weak self, weak target] result in
                    guard let self, let target, self.client === target,
                          self.currentTrackerSourceKey() == sourceKey else { return }
                    self.trackerSaveInProgress = false
                    switch result {
                    case .success:
                        self.applyTrackerSnapshot(draft, sourceKey: sourceKey,
                                                  status: L("Tracker configuration saved. Publication settings are active on the server; directory acceptance is not confirmed by this response."))
                        self.showAdminSaved(L("Tracker configuration saved on the connected server."))
                    case let .failure(error):
                        self.trackerStatusOverride = LF("Save failed: %@. Your draft was kept.", Self.displayMessage(for: error))
                        self.trackerStatusColor = .systemRed
                        self.updateTrackerEditorState()
                        self.showAdminError(error)
                    }
                }
                return
            }

            guard let backend = serverBackend else {
                throw ServerStateError.invalidValue(L("Server backend is unavailable."))
            }
            var advanced = backend.snapshot().advanced
            advanced.trackers = draft.trackers
            advanced.trackerAdvertisementFlags = draft.advertisementFlags
            advanced.trackerDescription = draft.description
            try backend.updateAdvanced(advanced)
            localServerRuntime?.refreshTrackerConfiguration()
            localServerState = backend.snapshot()
            draft.trackers = localServerState.advanced.trackers
            draft.advertisementFlags = localServerState.advanced.trackerAdvertisementFlags
            draft.description = localServerState.advanced.trackerDescription
            trackerSaveInProgress = false
            applyTrackerSnapshot(draft, sourceKey: "local",
                                 status: L("Tracker configuration saved locally. Publication will use the selected Trackers while the server is running."))
            showAdminSaved(L("Tracker configuration saved."))
        } catch {
            trackerSaveInProgress = false
            trackerStatusOverride = LF("Save failed: %@. Your draft was kept.", Self.displayMessage(for: error))
            trackerStatusColor = .systemRed
            updateTrackerEditorState()
            showAdminError(error)
        }
    }

    func loadTrackerBookmarks() {
        trackerBookmarks = trackerBookmarkStore.load()
        if let selectedTrackerID, !trackerBookmarks.contains(where: { $0.id == selectedTrackerID }) {
            self.selectedTrackerID = nil
        }
    }

    func saveTrackerBookmarks() {
        trackerBookmarkStore.save(trackerBookmarks)
    }

    func startTrackerRefreshTimer() {
        trackerRefreshTimer?.invalidate()
        refreshAllClientTrackers()
        trackerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refreshAllClientTrackers()
        }
    }

    func refreshAllClientTrackers() {
        for tracker in trackerBookmarks { refreshClientTracker(tracker.id) }
    }

    func refreshClientTracker(_ trackerID: UUID) {
        guard !trackerRefreshInFlight.contains(trackerID),
              let tracker = trackerBookmarks.first(where: { $0.id == trackerID }) else { return }
        let generation = (trackerRefreshGeneration[trackerID] ?? 0) + 1
        trackerRefreshGeneration[trackerID] = generation
        trackerRefreshInFlight.insert(trackerID)
        reloadTrackerStack()
        if selectedTrackerID == trackerID { reloadTrackerBrowser() }
        LegacyTrackerClient().query(address: tracker.address) { [weak self] result in
            guard let self,
                  self.trackerRefreshGeneration[trackerID] == generation,
                  self.trackerBookmarks.first(where: { $0.id == trackerID })?.address == tracker.address else { return }
            self.trackerRefreshInFlight.remove(trackerID)
            switch result {
            case let .success(entries):
                self.trackerResults[trackerID] = entries
                self.trackerErrors.removeValue(forKey: trackerID)
            case let .failure(error):
                self.trackerResults.removeValue(forKey: trackerID)
                self.trackerErrors[trackerID] = Self.displayMessage(for: error)
            }
            self.reloadTrackerStack()
            if self.selectedTrackerID == trackerID { self.reloadTrackerBrowser() }
        }
    }

    func reloadTrackerBrowser() {
        trackerBrowserTable.reloadData()
        guard let trackerID = selectedTrackerID,
              let tracker = trackerBookmarks.first(where: { $0.id == trackerID }) else {
            trackerBrowserTitleLabel.stringValue = L("Tracker")
            trackerBrowserStatusLabel.stringValue = L("Select a Tracker from the sidebar.")
            return
        }
        trackerBrowserTitleLabel.stringValue = tracker.address
        if trackerRefreshInFlight.contains(trackerID) {
            trackerBrowserStatusLabel.stringValue = L("Refreshing…")
            trackerBrowserStatusLabel.textColor = CarrachoTheme.secondaryText
        } else if let error = trackerErrors[trackerID] {
            trackerBrowserStatusLabel.stringValue = error
            trackerBrowserStatusLabel.textColor = .systemRed
        } else {
            let count = trackerResults[trackerID]?.count ?? 0
            trackerBrowserStatusLabel.stringValue = count == 1 ? LF("%@ registered server · Double-click to connect", String(count)) : LF("%@ registered servers · Double-click to connect", String(count))
            trackerBrowserStatusLabel.textColor = CarrachoTheme.secondaryText
        }
    }

    func activateClientTracker(_ tracker: TrackerBookmark) {
        if currentWorkspace != .trackerBrowser { serverWorkspaceBeforeTracker = currentWorkspace }
        selectedTrackerID = tracker.id
        selectWorkspace(.trackerBrowser)
        reloadTrackerStack()
        reloadTrackerBrowser()
        refreshClientTracker(tracker.id)
    }

    @objc func trackerBookmarkPressed(_ sender: NSButton) {
        guard trackerBookmarks.indices.contains(sender.tag) else { return }
        activateClientTracker(trackerBookmarks[sender.tag])
    }

    @objc func addClientTrackerPressed(_ sender: Any?) {
        presentClientTrackerEditor(existing: nil)
    }

    @objc func editClientTrackerPressed(_ sender: NSButton) {
        guard trackerBookmarks.indices.contains(sender.tag) else { return }
        presentClientTrackerEditor(existing: trackerBookmarks[sender.tag])
    }

    @objc func refreshSelectedClientTracker(_ sender: Any?) {
        guard let selectedTrackerID else { return }
        refreshClientTracker(selectedTrackerID)
    }

    @objc func connectSelectedTrackerServer(_ sender: Any?) {
        let row = trackerBrowserTable.clickedRow >= 0 ? trackerBrowserTable.clickedRow : trackerBrowserTable.selectedRow
        guard row >= 0, row < displayedTrackerServers.count else { return }
        let entry = displayedTrackerServers[row]
        let host = Self.trackerIPv4String(entry.ipv4)
        guard host != "0.0.0.0", entry.port != 0 else {
            showError(L("The selected Tracker entry has no usable server address."))
            return
        }

        if entry.isPrivate {
            presentPrivateTrackerLogin(for: entry)
            return
        }

        if let bookmark = serverBookmarks.first(where: {
            $0.port == entry.port && $0.host.caseInsensitiveCompare(host) == .orderedSame &&
            temporaryServerBookmarkIDs.contains($0.id)
        }) {
            connect(to: bookmark)
            return
        }
        if let bookmark = serverBookmarks.first(where: {
            $0.port == entry.port && $0.host.caseInsensitiveCompare(host) == .orderedSame &&
            $0.login.caseInsensitiveCompare("anonymous") == .orderedSame
        }), (try? serverBookmarkKeychain.password(for: bookmark.id))?.isEmpty != false {
            connect(to: bookmark)
            return
        }

        let trackerName = Self.macRomanString(entry.serverName).trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = ServerBookmark(
            name: trackerName.isEmpty ? "\(host):\(entry.port)" : trackerName,
            host: host,
            port: entry.port,
            login: "anonymous",
            nickname: "",
            statusMessage: "",
            autoReconnect: false,
            connectAtLaunch: false,
            acceptsOfflineMessages: true
        )
        serverBookmarks.insert(bookmark, at: 0)
        temporaryServerBookmarkIDs.insert(bookmark.id)
        selectedBookmarkID = bookmark.id
        reloadBookmarkStack()
        connect(to: bookmark)
    }

    func presentPrivateTrackerLogin(for entry: LegacyTrackerServerEntry) {
        guard let window = view.window else { return }
        let host = Self.trackerIPv4String(entry.ipv4)
        guard host != "0.0.0.0", entry.port != 0 else {
            showError(L("The selected Tracker entry has no usable server address."))
            return
        }

        trackerCredentialValidationClient?.disconnect()
        trackerCredentialValidationClient = nil
        if let existing = trackerPrivateLoginWindowController?.window {
            if let parent = existing.sheetParent { parent.endSheet(existing) }
            else { existing.orderOut(nil) }
        }

        let trackerName = Self.macRomanString(entry.serverName).trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trackerName.isEmpty ? "\(host):\(entry.port)" : trackerName
        let endpoint = "\(host):\(entry.port)"
        let controller = TrackerPrivateLoginWindowController(serverName: displayName, endpoint: endpoint)
        trackerPrivateLoginWindowController = controller

        controller.onSubmit = { [weak self, weak controller] login, password in
            guard let self, let controller else { return }
            self.trackerCredentialValidationClient?.disconnect()
            let probe = LegacyControlClient()
            self.trackerCredentialValidationClient = probe
            let preferredNickname = self.generalNickname?.trimmingCharacters(in: .whitespacesAndNewlines)
            let validationNickname = preferredNickname.flatMap { $0.isEmpty ? nil : $0 } ?? L("Tracker User")

            probe.connect(host: host, port: entry.port, login: login, password: password,
                          nickname: validationNickname) { [weak self, weak controller, weak probe] result in
                DispatchQueue.main.async {
                    guard let self, let controller, let probe,
                          self.trackerCredentialValidationClient === probe else { return }
                    probe.disconnect()
                    self.trackerCredentialValidationClient = nil
                    switch result {
                    case let .failure(error):
                        controller.showValidation(LF("Login failed: %@", Self.displayMessage(for: error)))
                    case .success:
                        let draft = ServerBookmarkDraft(
                            name: displayName,
                            host: host,
                            port: String(entry.port),
                            login: login,
                            password: password,
                            nickname: "",
                            statusMessage: "",
                            autoReconnect: false,
                            connectAtLaunch: false,
                            acceptsOfflineMessages: true
                        )
                        controller.completeSuccessfully()
                        DispatchQueue.main.async { [weak self] in
                            self?.presentBookmarkEditor(bookmark: nil, draft: draft)
                        }
                    }
                }
            }
        }
        controller.onFinish = { [weak self, weak controller] in
            guard let self else { return }
            self.trackerCredentialValidationClient?.disconnect()
            self.trackerCredentialValidationClient = nil
            if self.trackerPrivateLoginWindowController === controller {
                self.trackerPrivateLoginWindowController = nil
            }
        }
        controller.beginSheet(for: window)
    }

    func connectAdHocTrackerServer(host: String, port: UInt16) {
        if currentWorkspace == .serverInfo, !confirmServerInfoChangesCanBeAbandoned() { return }
        if currentWorkspace == .trackers, !confirmTrackerChangesCanBeAbandoned() { return }
        guard !isAwaitingAgreementAcceptance else {
            showError(L("Finish the current server Agreement before connecting to another server."))
            return
        }
        guard connectionSetupBookmarkID == nil else {
            showError(L("Wait for the current connection attempt to finish before connecting to another server."))
            return
        }

        cancelAutoReconnect()
        pendingBookmarkActivationID = nil
        if activeBookmarkConnectionID != nil {
            parkActiveBookmarkConnection()
        } else {
            switch client.state {
            case .idle: break
            default: client.disconnect()
            }
            resetSessionViews()
        }

        clearPresentationForBookmarkSwitch()
        activeBookmarkConnectionID = nil
        connectedBookmarkID = nil
        connectingBookmarkID = nil
        selectedBookmarkID = nil
        serverWorkspaceBeforeTracker = nil
        client = LegacyControlClient()
        configureClientCallbacks()

        hostField.stringValue = host
        portField.stringValue = String(port)
        // A tracker entry carries no account credentials. For an unbookmarked server, connect
        // as a guest while retaining the user's chosen nickname. Account-only servers can then
        // be bookmarked/configured normally instead of accidentally reusing another server's password.
        loginField.stringValue = "anonymous"
        passwordField.stringValue = ""
        if let nickname = generalNickname { nicknameField.stringValue = nickname }
        reloadBookmarkStack()
        selectWorkspace(.overview)
        refreshShellChrome()
        connectPressed(nil)
    }

    func presentClientTrackerEditor(existing: TrackerBookmark?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = existing == nil ? L("Add Tracker") : L("Edit Tracker")
        alert.informativeText = L("Enter a Classic Carracho Tracker address. Port 6702 is used when no port is specified.")
        alert.addButton(withTitle: existing == nil ? L("Add") : L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        if existing != nil { alert.addButton(withTitle: L("Delete")) }
        let address = NSTextField(string: existing?.address ?? "")
        address.placeholderString = "tracker.example.org:6702"
        address.frame = NSRect(x: 0, y: 0, width: 430, height: 24)
        alert.accessoryView = address
        alert.window.initialFirstResponder = address
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertThirdButtonReturn, let existing {
                self.trackerBookmarks.removeAll { $0.id == existing.id }
                self.trackerResults.removeValue(forKey: existing.id)
                self.trackerErrors.removeValue(forKey: existing.id)
                self.trackerRefreshInFlight.remove(existing.id)
                self.trackerRefreshGeneration[existing.id] = (self.trackerRefreshGeneration[existing.id] ?? 0) + 1
                if self.selectedTrackerID == existing.id { self.selectedTrackerID = nil }
                self.saveTrackerBookmarks()
                self.reloadTrackerStack()
                self.reloadTrackerBrowser()
                return
            }
            guard response == .alertFirstButtonReturn else { return }
            let value = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                _ = try LegacyTrackerEndpoint.parse(value)
                if self.trackerBookmarks.contains(where: {
                    $0.id != existing?.id && $0.address.caseInsensitiveCompare(value) == .orderedSame
                }) {
                    throw LegacyTrackerClientError.invalidAddress("This Tracker is already in the sidebar.")
                }
                let tracker = TrackerBookmark(id: existing?.id ?? UUID(), address: value)
                if let index = self.trackerBookmarks.firstIndex(where: { $0.id == tracker.id }) {
                    self.trackerBookmarks[index] = tracker
                } else {
                    self.trackerBookmarks.append(tracker)
                }
                self.trackerResults.removeValue(forKey: tracker.id)
                self.trackerErrors.removeValue(forKey: tracker.id)
                self.trackerRefreshInFlight.remove(tracker.id)
                self.trackerRefreshGeneration[tracker.id] = (self.trackerRefreshGeneration[tracker.id] ?? 0) + 1
                self.saveTrackerBookmarks()
                self.reloadTrackerStack()
                self.activateClientTracker(tracker)
            } catch {
                self.showTrackerBookmarkError(error, existing: existing, value: value)
            }
        }
    }

    func showTrackerBookmarkError(_ error: Error, existing: TrackerBookmark?, value: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Invalid Tracker")
        alert.informativeText = Self.displayMessage(for: error)
        alert.addButton(withTitle: L("OK"))
        alert.beginSheetModal(for: window) { [weak self] _ in
            guard let self else { return }
            var retry = existing
            if retry == nil { retry = TrackerBookmark(address: value) }
            else { retry?.address = value }
            self.presentClientTrackerEditor(existing: retry)
        }
    }

    func trackerSidebarCountText(for trackerID: UUID) -> String {
        if trackerRefreshInFlight.contains(trackerID), trackerResults[trackerID] == nil { return "…" }
        if trackerErrors[trackerID] != nil { return "—" }
        return String(trackerResults[trackerID]?.count ?? 0)
    }

    func reloadTrackerStack() {
        for view in trackerStack.arrangedSubviews {
            trackerStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !trackerBookmarks.isEmpty else {
            let empty = infoLabel(L("No saved trackers"))
            empty.font = .systemFont(ofSize: 10.5)
            empty.heightAnchor.constraint(equalToConstant: 18).isActive = true
            trackerStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: trackerStack.widthAnchor).isActive = true
            return
        }
        for (index, tracker) in trackerBookmarks.enumerated() {
            let row = CarrachoBackgroundView()
            row.fillColor = currentWorkspace == .trackerBrowser && tracker.id == selectedTrackerID
                ? CarrachoTheme.selectionSoft : .clear
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 32).isActive = true

            let open = BookmarkActionButton(title: "", target: self, action: #selector(trackerBookmarkPressed(_:)))
            open.tag = index
            open.isBordered = false
            open.toolTip = LF("Open Tracker %@", tracker.address)
            open.translatesAutoresizingMaskIntoConstraints = false
            let icon = symbolView("point.3.connected.trianglepath.dotted", size: 16, tint: CarrachoTheme.secondaryText)
            let address = NSTextField(labelWithString: tracker.address)
            address.font = .systemFont(ofSize: 11.5, weight: .medium)
            address.lineBreakMode = .byTruncatingMiddle
            address.toolTip = tracker.address
            address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let count = NSTextField(labelWithString: trackerSidebarCountText(for: tracker.id))
            count.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
            count.alignment = .center
            count.textColor = trackerErrors[tracker.id] == nil ? CarrachoTheme.secondaryText : .systemRed
            count.toolTip = trackerErrors[tracker.id] ?? L("Registered servers")
            count.translatesAutoresizingMaskIntoConstraints = false
            count.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
            let contentStack = horizontalStack([icon, address, count], spacing: 6)
            contentStack.translatesAutoresizingMaskIntoConstraints = false
            let openContent = BookmarkButtonContentView()
            openContent.translatesAutoresizingMaskIntoConstraints = false
            openContent.addSubview(contentStack)

            let edit = NSButton(title: "", target: self, action: #selector(editClientTrackerPressed(_:)))
            edit.tag = index
            edit.isBordered = false
            edit.toolTip = L("Edit Tracker")
            edit.image = sizedAssetImage(named: "Edit", size: 13)
            edit.imagePosition = .imageOnly
            edit.imageScaling = .scaleNone
            edit.contentTintColor = nil
            edit.translatesAutoresizingMaskIntoConstraints = false
            edit.widthAnchor.constraint(equalToConstant: 22).isActive = true
            edit.heightAnchor.constraint(equalToConstant: 26).isActive = true

            row.addSubview(open)
            row.addSubview(openContent)
            row.addSubview(edit)
            NSLayoutConstraint.activate([
                open.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                open.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                open.topAnchor.constraint(equalTo: row.topAnchor),
                open.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                edit.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
                edit.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                openContent.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 6),
                openContent.trailingAnchor.constraint(equalTo: edit.leadingAnchor, constant: -4),
                openContent.topAnchor.constraint(equalTo: row.topAnchor, constant: 3),
                openContent.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -3),
                contentStack.leadingAnchor.constraint(equalTo: openContent.leadingAnchor),
                contentStack.trailingAnchor.constraint(equalTo: openContent.trailingAnchor),
                contentStack.centerYAnchor.constraint(equalTo: openContent.centerYAnchor),
            ])
            trackerStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: trackerStack.widthAnchor).isActive = true
        }
    }

    static func trackerIPv4String(_ data: Data) -> String {
        guard data.count == 4 else { return "0.0.0.0" }
        return data.map(String.init).joined(separator: ".")
    }

    static func trackerServerEndpoint(_ entry: LegacyTrackerServerEntry) -> String {
        "\(trackerIPv4String(entry.ipv4)):\(entry.port)"
    }

    func trackerDraftIndex(forDisplayedRow row: Int) -> Int? {
        let indices = displayedTrackerDraftIndices
        guard row >= 0, row < indices.count else { return nil }
        return indices[row]
    }
}
