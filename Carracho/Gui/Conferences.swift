import Cocoa
import QuickLookUI

private enum RoomDiscoveryStyle {
    static func color(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name("Carracho.Discovery." + name)) { appearance in
            let value = CarrachoTheme.isDark(appearance) ? dark : light
            return NSColor(calibratedRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
    static let background = color("background", light: 0xF3F7FB, dark: 0x101E2B)
    static let surface = color("surface", light: 0xFFFFFF, dark: 0x172939)
    static let selected = color("selected", light: 0xE4F2FC, dark: 0x20394F)
    static let border = color("border", light: 0xC6DAE8, dark: 0x34546E)
    static let accent = color("accent", light: 0x008BBA, dark: 0x38D4F3)
    static let secondary = color("secondary", light: 0x516577, dark: 0xB0C1D4)
    static let joined = color("joined", light: 0x187737, dark: 0x99F287)
    static let joinedBackground = color("joinedBackground", light: 0xDDF2E1, dark: 0x21492B)
}

final class RoomDiscoveryTableRowView: NSTableRowView {
    override var isSelected: Bool { didSet { needsDisplay = true } }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func drawBackground(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        (isSelected ? RoomDiscoveryStyle.selected : RoomDiscoveryStyle.surface).setFill()
        path.fill()
        RoomDiscoveryStyle.border.setStroke()
        path.lineWidth = 1
        path.stroke()
        if isSelected {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            RoomDiscoveryStyle.accent.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: 5, height: rect.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {}
}

final class RoomDiscoveryView: NSView {
    let countLabel = NSTextField(labelWithString: "")
    let emptyLabel = NSTextField(labelWithString: "")
    let refreshButton = NSButton(title: L("Refresh"), target: nil, action: nil)
    let closeButton = NSButton(title: L("Close"), target: nil, action: nil)
    private let listHeight: NSLayoutConstraint
    private let emptyHost: NSView

    init(table: NSTableView, joinedLabel: NSTextField, joinButton: NSButton, deleteButton: NSButton) {
        let scroll = ViewportWidthTableScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 90)
        emptyHost = NSView()
        super.init(frame: .zero)
        let background = CarrachoBackgroundView()
        background.fillColor = RoomDiscoveryStyle.background
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let icon = NSImageView()
        icon.image = NSImage(named: "Discover Rooms")
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 60).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 60).isActive = true
        let title = NSTextField(labelWithString: L("Discover Rooms"))
        title.font = .systemFont(ofSize: 23, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: L("Find a room on this server and join the conversation."))
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = RoomDiscoveryStyle.secondary
        let intro = row([icon, column([title, subtitle], spacing: 7)], spacing: 20)

        let heading = NSTextField(labelWithString: L("Available Rooms"))
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        refreshButton.bezelStyle = .rounded
        refreshButton.font = .systemFont(ofSize: 14)
        refreshButton.imagePosition = .imageLeading
        if #available(macOS 11.0, *) {
            refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        } else { refreshButton.image = NSImage(named: NSImage.refreshTemplateName) }
        let listHeading = row([heading, NSView(), refreshButton], spacing: 12)

        emptyHost.addSubview(scroll)
        emptyHost.addSubview(emptyLabel)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = RoomDiscoveryStyle.secondary
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: emptyHost.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: emptyHost.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: emptyHost.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: emptyHost.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: emptyHost.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: emptyHost.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: emptyHost.widthAnchor, constant: -20),
            listHeight,
        ])
        for label in [countLabel, joinedLabel] {
            label.font = .systemFont(ofSize: 13)
            label.textColor = RoomDiscoveryStyle.secondary
        }
        let counts = row([countLabel, NSView(), joinedLabel], spacing: 12)
        let list = column([listHeading, emptyHost, counts], spacing: 10)

        let note = CarrachoCardView()
        note.fillColor = RoomDiscoveryStyle.surface
        let lock = NSImageView()
        if #available(macOS 11.0, *) {
            lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
            lock.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        } else { lock.image = NSImage(named: NSImage.lockLockedTemplateName) }
        lock.contentTintColor = .systemYellow
        lock.translatesAutoresizingMaskIntoConstraints = false
        lock.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let noteText = NSTextField(wrappingLabelWithString: L("A password is requested only when you join a protected room."))
        noteText.font = .systemFont(ofSize: 14)
        noteText.textColor = RoomDiscoveryStyle.secondary
        let noteContent = row([lock, noteText], spacing: 16)
        note.addSubview(noteContent)
        NSLayoutConstraint.activate([
            noteContent.leadingAnchor.constraint(equalTo: note.leadingAnchor, constant: 18),
            noteContent.trailingAnchor.constraint(equalTo: note.trailingAnchor, constant: -18),
            noteContent.topAnchor.constraint(equalTo: note.topAnchor, constant: 16),
            noteContent.bottomAnchor.constraint(equalTo: note.bottomAnchor, constant: -16),
            note.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
        let body = column([intro, list, note], spacing: 24)
        addSubview(body)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        let hint = NSTextField(wrappingLabelWithString: L("Double-click a room to join."))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = RoomDiscoveryStyle.secondary
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        joinButton.bezelStyle = .rounded
        joinButton.keyEquivalent = "\r"
        for button in [closeButton, joinButton, deleteButton] {
            button.controlSize = .regular
            button.font = .systemFont(ofSize: 14)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let footer = row([hint, NSView(), deleteButton, closeButton, joinButton], spacing: 12)
        addSubview(footer)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            body.topAnchor.constraint(equalTo: topAnchor, constant: 26),
            divider.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 24),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            footer.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 16),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            joinButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
    }
    required init?(coder: NSCoder) { nil }

    func update(roomCount: Int, loading: Bool, manualRefresh: Bool, connected: Bool) {
        countLabel.stringValue = roomCount == 1 ? L("1 room available") : LF("%@ rooms available", String(roomCount))
        // Background polling must not make the Refresh control flash every cycle. Only a
        // user-initiated refresh owns the visible busy state of this button.
        refreshButton.isEnabled = connected && !manualRefresh
        refreshButton.title = manualRefresh ? L("Refreshing…") : L("Refresh")
        emptyLabel.stringValue = loading ? L("Loading rooms…") : L("No rooms available")
        emptyLabel.isHidden = roomCount > 0
        listHeight.constant = CGFloat(min(max(roomCount, 1), 4)) * 90
    }

    func showRefreshError(_ message: String) {
        countLabel.stringValue = L("Rooms could not be refreshed.")
        countLabel.toolTip = message
        if !emptyLabel.isHidden { emptyLabel.stringValue = L("Rooms could not be refreshed.") }
    }

    private func row(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = .horizontal
        result.alignment = .centerY
        result.spacing = spacing
        result.translatesAutoresizingMaskIntoConstraints = false
        return result
    }
    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = .vertical
        result.alignment = .leading
        result.spacing = spacing
        result.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true
        }
        return result
    }
}

final class NewChatRoomWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let nameField = NSTextField(string: "")
    let passwordField = NSSecureTextField(string: "")
    let topicField = NSTextField(string: "")
    let restrictedChatCheckbox = NSButton(checkboxWithTitle: L("Only operators / speakers may chat"), target: nil, action: nil)
    let restrictedTopicCheckbox = NSButton(checkboxWithTitle: L("Only operators may change the topic"), target: nil, action: nil)
    let validationLabel = NSTextField(labelWithString: "")
    let createButton = NSButton(title: L("Create"), target: nil, action: nil)
    var onCreate: ((String, String, String, Bool, Bool) -> String?)?
    var onFinish: (() -> Void)?
    private var didFinish = false

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 570, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("New Chat Room")
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildInterface(in: window)
    }

    required init?(coder: NSCoder) { nil }

    private func buildInterface(in window: NSWindow) {
        let root = CarrachoBackgroundView()
        root.fillColor = CarrachoTheme.canvas
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let title = NSTextField(labelWithString: L("New Chat Room"))
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = .labelColor

        let subtitle = NSTextField(wrappingLabelWithString: L("Create a temporary chat room. You become its operator."))
        subtitle.font = .systemFont(ofSize: 12.5)
        subtitle.textColor = CarrachoTheme.secondaryText
        subtitle.maximumNumberOfLines = 2

        let detailsCard = CarrachoCardView()
        detailsCard.fillColor = CarrachoTheme.elevatedCard
        detailsCard.cornerRadius = 11

        nameField.placeholderString = L("Room name")
        passwordField.placeholderString = L("Optional")
        topicField.placeholderString = L("Optional")
        for field in [nameField, passwordField, topicField] {
            field.controlSize = .regular
            field.font = .systemFont(ofSize: 13)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        nameField.delegate = self

        let nameGroup = labeledField(L("Name"), field: nameField)
        let passwordGroup = labeledField(L("Password"), field: passwordField)
        let topicGroup = labeledField(L("Topic"), field: topicField)
        let fields = stack([nameGroup, passwordGroup, topicGroup], spacing: 12)
        detailsCard.addSubview(fields)
        NSLayoutConstraint.activate([
            fields.leadingAnchor.constraint(equalTo: detailsCard.leadingAnchor, constant: 16),
            fields.trailingAnchor.constraint(equalTo: detailsCard.trailingAnchor, constant: -16),
            fields.topAnchor.constraint(equalTo: detailsCard.topAnchor, constant: 15),
            fields.bottomAnchor.constraint(equalTo: detailsCard.bottomAnchor, constant: -15),
        ])

        let permissionsCard = CarrachoCardView()
        permissionsCard.fillColor = CarrachoTheme.elevatedCard
        permissionsCard.cornerRadius = 11
        let permissionsTitle = NSTextField(labelWithString: L("Room Permissions"))
        permissionsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        restrictedChatCheckbox.font = .systemFont(ofSize: 12.5)
        restrictedTopicCheckbox.font = .systemFont(ofSize: 12.5)
        let permissionsStack = stack([permissionsTitle, restrictedChatCheckbox, restrictedTopicCheckbox], spacing: 8)
        permissionsCard.addSubview(permissionsStack)
        NSLayoutConstraint.activate([
            permissionsStack.leadingAnchor.constraint(equalTo: permissionsCard.leadingAnchor, constant: 16),
            permissionsStack.trailingAnchor.constraint(equalTo: permissionsCard.trailingAnchor, constant: -16),
            permissionsStack.topAnchor.constraint(equalTo: permissionsCard.topAnchor, constant: 14),
            permissionsStack.bottomAnchor.constraint(equalTo: permissionsCard.bottomAnchor, constant: -14),
        ])

        validationLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        validationLabel.textColor = .systemRed
        validationLabel.lineBreakMode = .byTruncatingTail
        validationLabel.isHidden = true
        validationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cancelButton = NSButton(title: L("Cancel"), target: self, action: #selector(cancelPressed(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 94).isActive = true

        createButton.target = self
        createButton.action = #selector(createPressed(_:))
        CarrachoTheme.applyPrimaryButtonStyle(createButton)
        createButton.keyEquivalent = "\r"
        createButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 106).isActive = true
        createButton.isEnabled = false

        let buttons = NSStackView(views: [validationLabel, NSView(), cancelButton, createButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(subtitle)
        root.addSubview(detailsCard)
        root.addSubview(permissionsCard)
        root.addSubview(buttons)
        for view in [title, subtitle, detailsCard, permissionsCard] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),

            detailsCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            detailsCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            detailsCard.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            detailsCard.heightAnchor.constraint(equalToConstant: 205),

            permissionsCard.leadingAnchor.constraint(equalTo: detailsCard.leadingAnchor),
            permissionsCard.trailingAnchor.constraint(equalTo: detailsCard.trailingAnchor),
            permissionsCard.topAnchor.constraint(equalTo: detailsCard.bottomAnchor, constant: 12),
            permissionsCard.heightAnchor.constraint(equalToConstant: 103),

            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.topAnchor.constraint(equalTo: permissionsCard.bottomAnchor, constant: 18),
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
            window.makeFirstResponder(self.nameField)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        createButton.isEnabled = !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        validationLabel.isHidden = true
    }

    @objc private func createPressed(_ sender: Any?) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showValidation(L("Enter a room name."))
            return
        }
        let password = passwordField.stringValue
        let topic = topicField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = onCreate?(name, password, topic, restrictedChatCheckbox.state == .on, restrictedTopicCheckbox.state == .on) {
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

// MARK: - Conferences

extension ViewController {

    func makeConferencesPage() -> NSView {
        let page = CarrachoBackgroundView()
        page.fillColor = CarrachoTheme.card

        // Match the standalone Files, News and Transfers workspaces. Overview keeps the shared
        // chat card unlabelled inside its split pane so the title is not duplicated there.
        let title = NSTextField(labelWithString: L("Conferences"))
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.setContentHuggingPriority(.required, for: .horizontal)

        let topBar = CarrachoBackgroundView()
        topBar.fillColor = CarrachoTheme.elevatedCard
        let topStack = horizontalStack([title, NSView()], spacing: 10)
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(topStack)
        let topDivider = CarrachoDividerView()
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(topDivider)

        topBar.translatesAutoresizingMaskIntoConstraints = false
        standaloneConferencesHost.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(topBar)
        page.addSubview(standaloneConferencesHost)
        NSLayoutConstraint.activate([
            topStack.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 18),
            topStack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -14),
            topStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            topDivider.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            topDivider.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),

            topBar.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: page.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: CarrachoTheme.workspaceHeaderHeight),

            standaloneConferencesHost.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            standaloneConferencesHost.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            standaloneConferencesHost.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            standaloneConferencesHost.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        return page
    }

    func makeChatCard() -> NSView {
        let surface = CarrachoBackgroundView()
        surface.fillColor = CarrachoTheme.card

        channelTitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        channelTitleLabel.lineBreakMode = .byTruncatingTail
        channelTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        channelTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chatRoomStateLabel.textColor = CarrachoTheme.secondaryText
        chatRoomStateLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        chatRoomStateLabel.lineBreakMode = .byTruncatingTail
        chatUsersLabel.textColor = CarrachoTheme.secondaryText
        chatUsersLabel.font = .systemFont(ofSize: 13)
        chatUsersLabel.setContentHuggingPriority(.required, for: .horizontal)

        let titleStack = verticalStack([channelTitleLabel, chatRoomStateLabel], spacing: 0)
        // The room selector is shared by Conferences and Overview. Give its title cluster real
        // horizontal room so ordinary names such as #Public do not collapse to "#Pu…" merely
        // because the trailing participant/actions cluster has high hugging priorities.
        let roomSelectorMinimumWidth = titleStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 280)
        roomSelectorMinimumWidth.priority = .defaultHigh
        roomSelectorMinimumWidth.isActive = true
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleStack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        channelTitleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let usersIcon = NSImageView(image: sizedAssetImage(named: "Accounts", size: 18) ?? NSImage())
        usersIcon.imageScaling = .scaleNone
        usersIcon.translatesAutoresizingMaskIntoConstraints = false
        usersIcon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        usersIcon.heightAnchor.constraint(equalToConstant: 22).isActive = true

        channelChatFontSizePopup.controlSize = .regular
        channelChatFontSizePopup.font = .systemFont(ofSize: 13)
        channelChatFontSizePopup.setContentHuggingPriority(.required, for: .horizontal)
        channelChatFontSizePopup.setContentCompressionResistancePriority(.required, for: .horizontal)
        channelChatFontSizePopup.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let header = horizontalStack([
            titleStack, channelRoomSwitchButton, NSView(), usersIcon, chatUsersLabel,
            channelChatFontSizePopup, channelHeaderSettingsButton, channelClearButton,
        ], spacing: 6)

        chatTopicLabel.textColor = CarrachoTheme.secondaryText
        chatTopicLabel.font = .systemFont(ofSize: 13)
        chatTopicLabel.lineBreakMode = .byTruncatingTail
        chatTopicLabel.maximumNumberOfLines = 1
        chatTopicLabel.isSelectable = true
        chatTopicLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        channelTopicEditButton.title = ""
        channelTopicEditButton.image = sizedAssetImage(named: "Edit", size: 18)
        channelTopicEditButton.imagePosition = .imageOnly
        channelTopicEditButton.imageScaling = .scaleNone
        channelTopicEditButton.isBordered = false
        channelTopicEditButton.contentTintColor = nil
        channelTopicEditButton.translatesAutoresizingMaskIntoConstraints = false
        channelTopicEditButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        channelTopicEditButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let topicRow = horizontalStack([chatTopicLabel, channelTopicEditButton, NSView()], spacing: 5)

        let headerDivider = CarrachoDividerView()
        headerDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        channelChatTextView.textContainerInset = NSSize(width: 18, height: 16)
        channelChatTextView.drawsBackground = true
        channelChatTextView.backgroundColor = CarrachoTheme.conferenceTranscriptBackground
        let chatScroll = textScroll(channelChatTextView, border: false)
        chatScroll.drawsBackground = true
        chatScroll.backgroundColor = CarrachoTheme.conferenceTranscriptBackground
        chatScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        chatScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        chatScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true

        let composerCard = CarrachoCardView()
        composerCard.fillColor = CarrachoTheme.elevatedCard
        composerCard.cornerRadius = 7
        composerCard.setContentHuggingPriority(.defaultLow, for: .horizontal)
        composerCard.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let composerScroll = textScroll(channelMessageField, border: false)
        composerScroll.drawsBackground = false
        composerScroll.backgroundColor = .clear
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.translatesAutoresizingMaskIntoConstraints = false
        channelComposerHeightConstraint = composerScroll.heightAnchor.constraint(equalToConstant: 38)
        channelComposerHeightConstraint?.isActive = true

        channelComposerPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        composerCard.addSubview(composerScroll)
        composerCard.addSubview(channelComposerPlaceholderLabel)
        NSLayoutConstraint.activate([
            composerScroll.leadingAnchor.constraint(equalTo: composerCard.leadingAnchor, constant: 4),
            composerScroll.trailingAnchor.constraint(equalTo: composerCard.trailingAnchor, constant: -4),
            composerScroll.topAnchor.constraint(equalTo: composerCard.topAnchor, constant: 2),
            composerScroll.bottomAnchor.constraint(equalTo: composerCard.bottomAnchor, constant: -2),
            channelComposerPlaceholderLabel.leadingAnchor.constraint(equalTo: composerCard.leadingAnchor, constant: 14),
            channelComposerPlaceholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: composerCard.trailingAnchor, constant: -10),
            channelComposerPlaceholderLabel.topAnchor.constraint(equalTo: composerCard.topAnchor, constant: 10),
        ])

        styleIconButton(channelAttachButton, symbol: "paperclip", help: L("Attach PNG or JPEG image"))
        styleIconButton(channelYouTubeButton, symbol: "play.rectangle", help: L("Attach a verified YouTube link"))
        channelSendButton.title = L("Send")
        channelSendButton.image = symbolImage("paperplane.fill", fallback: NSImage.goRightTemplateName)
        channelSendButton.imagePosition = .imageLeading
        channelSendButton.font = .systemFont(ofSize: 12, weight: .semibold)
        CarrachoTheme.applyPrimaryButtonStyle(channelSendButton)
        channelSendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        channelSendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true

        let composerRow = horizontalStack([
            composerCard, channelEmojiButton, channelAttachButton, channelYouTubeButton, channelSendButton,
        ], spacing: 6)
        composerRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let composerMeta = horizontalStack([channelComposerStatusLabel, NSView(), channelComposerHintLabel], spacing: 8)
        channelComposerStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        channelComposerHintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let composerStack = verticalStack([
            channelAttachmentStrip, composerRow, composerMeta,
        ], spacing: 4)

        let stack = verticalStack([header, topicRow, headerDivider, chatScroll, composerStack], spacing: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -7),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            topicRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
        updateChannelComposerHeight()
        return surface
    }

    func reloadJoinedChannelSidebar() {
        for view in joinedChannelSidebarStack.arrangedSubviews {
            joinedChannelSidebarStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let sessions = joinedChannels.values.sorted {
            let left = Self.macRomanString($0.state.name)
            let right = Self.macRomanString($1.state.name)
            let comparison = left.localizedStandardCompare(right)
            return comparison == .orderedSame ? $0.state.channelID < $1.state.channelID : comparison == .orderedAscending
        }
        for session in sessions {
            let active = activeChannel?.channelID == session.state.channelID
            let name = Self.macRomanString(session.state.name)
            var suffix = "  \(session.members.count)"
            if session.unreadCount > 0 { suffix += "  • \(session.unreadCount)" }
            let button = CarrachoSidebarButton(title: "# \(name)\(suffix)", target: self,
                                               action: #selector(sidebarJoinedChannelPressed(_:)))
            button.tag = Int(session.state.channelID)
            // Joined rooms use the singular Conference asset. Do not use the
            // Conferences asset here; that belongs to the expandable category row.
            button.image = NSImage(named: NSImage.Name("Conference"))
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.font = .systemFont(ofSize: 11.5, weight: active ? .semibold : .regular)
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.toolTip = session.members.count == 1 ? LF("#%@ · %@ participant", name, String(session.members.count)) : LF("#%@ · %@ participants", name, String(session.members.count))
            button.setAccessibilityLabel(session.members.count == 1 ? LF("Joined room %@, %@ participant", name, String(session.members.count)) : LF("Joined room %@, %@ participants", name, String(session.members.count)))
            CarrachoTheme.applySidebarButtonStyle(button,
                                                  selected: active && currentWorkspace == .conferences)
            button.font = .systemFont(ofSize: 11.5, weight: active ? .semibold : .regular)
            joinedChannelSidebarStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: joinedChannelSidebarStack.widthAnchor).isActive = true
        }
        channelDiscoverButton.isEnabled = client.isConnected
        channelNewButton.isEnabled = canJoinChatRooms && joinedChannels.count < Self.maximumJoinedChannels
    }

    @objc func sidebarJoinedChannelPressed(_ sender: NSButton) {
        let channelID = UInt32(clamping: sender.tag)
        guard joinedChannels[channelID] != nil else { return }
        if currentWorkspace != .conferences { selectWorkspace(.conferences) }
        activateJoinedChannel(channelID)
    }

    func applyChannelChatFontSize() {
        channelChatTextView.font = .systemFont(ofSize: channelChatFontSize)
        renderActiveChannelTranscript()
    }

    @objc func menuConferences(_ sender: Any?) { selectWorkspace(.conferences) }

    @objc func showChatRooms(_ sender: Any?) { selectWorkspace(.conferences) }

    @objc func createChannel(_ sender: Any?) {
        guard client.isConnected, canJoinChatRooms, let window = view.window else {
            if client.isConnected { showError(L("This account is not allowed to join or create chat rooms.")) }
            return
        }
        guard joinedChannels.count < Self.maximumJoinedChannels else {
            showError(LF("You can be in at most %@ chat rooms at the same time.", String(Self.maximumJoinedChannels)))
            return
        }

        if let existing = newChatRoomWindowController, let sheet = existing.window {
            if let parent = sheet.sheetParent { parent.endSheet(sheet) }
            else { sheet.orderOut(nil) }
        }
        newChatRoomWindowController = nil

        let controller = NewChatRoomWindowController()
        newChatRoomWindowController = controller
        controller.onFinish = { [weak self, weak controller] in
            guard let self else { return }
            if self.newChatRoomWindowController === controller { self.newChatRoomWindowController = nil }
        }
        controller.onCreate = { [weak self] roomName, password, topic, restrictedChat, restrictedTopic in
            guard let self else { return L("The room could not be created.") }
            guard let nameData = roomName.data(using: .macOSRoman), !nameData.isEmpty, nameData.count <= 64,
                  let passwordData = password.data(using: .macOSRoman), passwordData.count <= 32,
                  let topicData = topic.data(using: .macOSRoman), topicData.count <= 0x100 else {
                return L("Name, password and topic must be representable in MacRoman and stay within the Classic limits.")
            }

            var requestedFlags: UInt16 = 0
            if restrictedChat { requestedFlags |= Self.channelRestrictedChatFlag }
            if restrictedTopic { requestedFlags |= Self.channelRestrictedTopicFlag }

            self.channelNewButton.isEnabled = false
            self.client.joinChannel(channelID: 0, name: nameData, password: passwordData) { [weak self] result in
                guard let self else { return }
                self.channelNewButton.isEnabled = self.canJoinChatRooms && self.joinedChannels.count < Self.maximumJoinedChannels
                switch result {
                case let .success(state):
                    self.installJoinedChannel(state)
                    self.refreshChannelCatalog()
                    if !topicData.isEmpty || requestedFlags != state.flags {
                        self.client.setChannelSettings(channelID: state.channelID, topic: topicData, flags: requestedFlags) { [weak self] settingsResult in
                            if case let .failure(error) = settingsResult {
                                self?.appendChannelSystem(LF("Room settings could not be applied: %@", Self.displayMessage(for: error)), channelID: state.channelID, markUnread: false)
                            }
                        }
                    }
                    self.view.window?.makeFirstResponder(self.channelMessageField)
                case let .failure(error):
                    self.showError(LF("Chat room could not be created: %@", Self.displayMessage(for: error)))
                    self.reloadChannelView()
                }
            }
            return nil
        }
        controller.beginSheet(for: window)
    }

    @objc func showChannelRoomSwitchMenu(_ sender: NSButton) {
        let menu = NSMenu(title: L("Chat Rooms"))
        // AppKit otherwise sizes this menu purely from its current item strings. A comfortably
        // wide minimum keeps room names readable and prevents the selector from feeling like a
        // postage stamp in both Conferences and Overview.
        menu.minimumWidth = 320
        let sessions = joinedChannels.values.sorted {
            let left = Self.macRomanString($0.state.name)
            let right = Self.macRomanString($1.state.name)
            let result = left.localizedStandardCompare(right)
            return result == .orderedSame ? $0.state.channelID < $1.state.channelID : result == .orderedAscending
        }
        for session in sessions {
            let name = Self.macRomanString(session.state.name)
            let item = NSMenuItem(title: "#\(name)", action: #selector(switchJoinedChannelFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(session.state.channelID)
            item.state = activeChannel?.channelID == session.state.channelID ? .on : .off
            menu.addItem(item)
        }
        if !sessions.isEmpty { menu.addItem(.separator()) }
        let discover = NSMenuItem(title: L("Discover Rooms…"), action: #selector(showChannelDiscovery(_:)), keyEquivalent: "")
        discover.target = self
        discover.isEnabled = client.isConnected
        menu.addItem(discover)
        let create = NSMenuItem(title: L("New Room…"), action: #selector(createChannel(_:)), keyEquivalent: "")
        create.target = self
        create.isEnabled = canJoinChatRooms && joinedChannels.count < Self.maximumJoinedChannels
        menu.addItem(create)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc func switchJoinedChannelFromMenu(_ sender: NSMenuItem) {
        let channelID = UInt32(clamping: sender.tag)
        guard joinedChannels[channelID] != nil else { return }
        activateJoinedChannel(channelID)
    }

    func focusGeneralUser(_ user: LegacyUserListEntry) {
        selectedUserID = user.userID
        if let row = visibleUsers.firstIndex(where: { $0.userID == user.userID }) {
            isReloadingUserTable = true
            userTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isReloadingUserTable = false
        }
        updateUserActionButtons()
    }

    @objc func showSelectedChannelMemberInfo(_ sender: Any?) {
        guard let user = selectedChannelMemberUser else { return }
        focusGeneralUser(user)
        showSelectedUserInfo(sender)
    }

    @objc func messageSelectedChannelMember(_ sender: Any?) {
        guard let user = selectedChannelMemberUser else { return }
        focusGeneralUser(user)
        messageSelectedUser(sender)
    }

    @objc func inviteUserToActiveChannel(_ sender: Any?) {
        guard client.isConnected, let active = activeChannel, let window = view.window else { return }
        let candidates = liveUsers.values
            .filter { channelMembers[$0.userID] == nil }
            .sorted { Self.macRomanString($0.nickname).localizedStandardCompare(Self.macRomanString($1.nickname)) == .orderedAscending }
        guard !candidates.isEmpty else {
            showError(L("Every connected user is already in this room."))
            return
        }
        let alert = NSAlert()
        alert.messageText = L("Invite User")
        alert.informativeText = LF("Invite a connected server user to #%@.", Self.macRomanString(active.name))
        alert.addButton(withTitle: L("Invite"))
        alert.addButton(withTitle: L("Cancel"))
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        for candidate in candidates {
            popup.addItem(withTitle: Self.macRomanString(candidate.nickname))
            popup.lastItem?.representedObject = NSNumber(value: candidate.userID)
        }
        popup.setAccessibilityLabel(L("User to invite"))
        alert.accessoryView = popup
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let userID = (popup.selectedItem?.representedObject as? NSNumber)?.uint32Value,
                  let user = self.liveUsers[userID], self.channelMembers[userID] == nil else { return }
            self.client.inviteUser(userID, toChannel: active.channelID) { [weak self] result in
                switch result {
                case .success:
                    self?.channelComposerStatusLabel.stringValue = LF("Invitation sent to %@.", Self.macRomanString(user.nickname))
                    self?.channelComposerStatusLabel.textColor = CarrachoTheme.secondaryText
                case let .failure(error):
                    self?.showError(LF("Invitation failed: %@", Self.displayMessage(for: error)))
                }
            }
        }
    }

    @objc func editChannelSettings(_ sender: Any?) {
        guard client.isConnected, let active = activeChannel, let window = view.window else { return }
        let isOperator = isActiveChannelOperator
        let canEditTopic = canEditActiveChannelTopic
        guard isOperator || canEditTopic else { return }
        let alert = NSAlert()
        alert.messageText = L("Chat Room Settings")
        alert.informativeText = isOperator
            ? L("Change the topic and room restrictions.")
            : L("You may change the topic. Room restrictions are operator-only.")
        alert.addButton(withTitle: L("Apply"))
        alert.addButton(withTitle: L("Cancel"))
        let topic = NSTextField(string: Self.macRomanString(active.topic))
        topic.isEnabled = canEditTopic
        let restrictedChat = NSButton(checkboxWithTitle: L("Restrict chat to operators / speakers"), target: nil, action: nil)
        restrictedChat.state = active.flags & Self.channelRestrictedChatFlag != 0 ? .on : .off
        restrictedChat.isEnabled = isOperator
        let restrictedTopic = NSButton(checkboxWithTitle: L("Restrict topic changes to operators"), target: nil, action: nil)
        restrictedTopic.state = active.flags & Self.channelRestrictedTopicFlag != 0 ? .on : .off
        restrictedTopic.isEnabled = isOperator
        let options = verticalStack([restrictedChat, restrictedTopic], spacing: 6)
        let grid = NSGridView(views: [
            [makeLabel(L("Topic")), topic],
            [NSView(), options],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 1).xPlacement = .fill
        grid.frame = NSRect(x: 0, y: 0, width: 500, height: 92)
        alert.accessoryView = grid
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard let topicData = topic.stringValue.data(using: .macOSRoman), topicData.count <= 0x100 else {
                self.showError(L("The topic must be representable in MacRoman and at most 256 bytes long."))
                return
            }
            var flags = active.flags
            if isOperator {
                flags &= ~(Self.channelRestrictedChatFlag | Self.channelRestrictedTopicFlag)
                if restrictedChat.state == .on { flags |= Self.channelRestrictedChatFlag }
                if restrictedTopic.state == .on { flags |= Self.channelRestrictedTopicFlag }
            }
            self.client.setChannelSettings(channelID: active.channelID, topic: topicData, flags: flags) { [weak self] result in
                if case let .failure(error) = result {
                    self?.showError(LF("Chat room settings could not be changed: %@", Self.displayMessage(for: error)))
                }
            }
        }
    }

    @objc func inviteSelectedUserToChannel(_ sender: Any?) {
        guard let active = activeChannel, let user = selectedUserEntry else { return }
        guard channelMembers[user.userID] == nil else {
            appendChannelSystem(LF("%@ is already in this room.", Self.macRomanString(user.nickname)), channelID: active.channelID, markUnread: false)
            return
        }
        client.inviteUser(user.userID, toChannel: active.channelID) { [weak self] result in
            switch result {
            case .success:
                self?.appendChannelSystem(LF("Invited %@.", Self.macRomanString(user.nickname)), channelID: active.channelID, markUnread: false)
            case let .failure(error):
                self?.showError(LF("Invitation failed: %@", Self.displayMessage(for: error)))
            }
        }
    }

    func updateSelectedChannelMemberModeButtons(member: LegacyChannelMember?) {
        guard let member else {
            channelToggleOperatorButton.state = .off
            channelToggleSpeakButton.state = .off
            channelToggleOperatorButton.image = sizedAssetImage(named: "Toggle Operator Mode Off", size: 20)
            channelToggleSpeakButton.image = sizedAssetImage(named: "Toggle Speak Permission Off", size: 20)
            channelToggleOperatorButton.contentTintColor = nil
            channelToggleSpeakButton.contentTintColor = nil
            channelToggleOperatorButton.toolTip = L("Toggle Operator Mode")
            channelToggleSpeakButton.toolTip = L("Toggle Speak Permission")
            channelToggleOperatorButton.setAccessibilityLabel(L("Toggle Operator Mode"))
            channelToggleSpeakButton.setAccessibilityLabel(L("Toggle Speak Permission"))
            return
        }

        let memberName = liveUsers[member.userID].map { Self.macRomanString($0.nickname) } ?? L("Unknown User")
        let operatorEnabled = member.mode & Self.channelOperatorMode != 0
        let speakEnabled = member.mode & Self.channelSpeechMode != 0

        channelToggleOperatorButton.state = operatorEnabled ? .on : .off
        channelToggleOperatorButton.image = sizedAssetImage(
            named: operatorEnabled ? "Toggle Operator Mode" : "Toggle Operator Mode Off",
            size: 16
        )
        channelToggleOperatorButton.contentTintColor = nil
        channelToggleOperatorButton.toolTip = operatorEnabled
            ? LF("Remove Operator Mode from %@", memberName)
            : LF("Grant Operator Mode to %@", memberName)
        channelToggleOperatorButton.setAccessibilityLabel(channelToggleOperatorButton.toolTip ?? L("Toggle Operator Mode"))

        channelToggleSpeakButton.state = speakEnabled ? .on : .off
        channelToggleSpeakButton.image = sizedAssetImage(
            named: speakEnabled ? "Toggle Speak Permission" : "Toggle Speak Permission Off",
            size: 16
        )
        channelToggleSpeakButton.contentTintColor = nil
        channelToggleSpeakButton.toolTip = speakEnabled
            ? LF("Remove Speak Permission from %@", memberName)
            : LF("Grant Speak Permission to %@", memberName)
        channelToggleSpeakButton.setAccessibilityLabel(channelToggleSpeakButton.toolTip ?? L("Toggle Speak Permission"))
    }

    private func toggleSelectedChannelMemberModeBit(_ bit: UInt8, failureMessage: String) {
        guard client.isConnected,
              let active = activeChannel,
              isActiveChannelOperator,
              let member = selectedChannelMember else { return }

        let newMode = member.mode ^ bit
        client.setChannelUserMode(channelID: active.channelID, userID: member.userID, mode: newMode) { [weak self] result in
            if case let .failure(error) = result {
                self?.showError(LF(failureMessage, Self.displayMessage(for: error)))
            }
        }
        // Toggle buttons are driven by the authoritative channelUserMode event. AppKit flips
        // a toggle button before invoking its action, so immediately restore the currently
        // confirmed mode instead of pretending the server has already accepted the change.
        updateSelectedChannelMemberModeButtons(member: member)
    }

    @objc func toggleSelectedChannelMemberOperatorMode(_ sender: Any?) {
        toggleSelectedChannelMemberModeBit(
            Self.channelOperatorMode,
            failureMessage: L("Operator Mode could not be changed: %@")
        )
    }

    @objc func toggleSelectedChannelMemberSpeakPermission(_ sender: Any?) {
        toggleSelectedChannelMemberModeBit(
            Self.channelSpeechMode,
            failureMessage: L("Speak Permission could not be changed: %@")
        )
    }

    @objc func editSelectedChannelMemberMode(_ sender: Any?) {
        guard let active = activeChannel, isActiveChannelOperator, let window = view.window else { return }
        let row = channelMemberTable.selectedRow
        guard row >= 0, row < sortedChannelMembers.count else { return }
        let member = sortedChannelMembers[row]
        let memberName = liveUsers[member.userID].map { Self.macRomanString($0.nickname) } ?? L("Unknown User")
        let alert = NSAlert()
        alert.messageText = L("Member Permissions")
        alert.informativeText = LF("Change the room role for %@.", memberName)
        alert.addButton(withTitle: L("Apply"))
        alert.addButton(withTitle: L("Cancel"))
        let op = NSButton(checkboxWithTitle: L("Room operator"), target: nil, action: nil)
        op.state = member.mode & Self.channelOperatorMode != 0 ? .on : .off
        let speak = NSButton(checkboxWithTitle: L("May speak in restricted chat"), target: nil, action: nil)
        speak.state = member.mode & Self.channelSpeechMode != 0 ? .on : .off
        let options = verticalStack([op, speak], spacing: 8)
        options.frame = NSRect(x: 0, y: 0, width: 340, height: 56)
        alert.accessoryView = options
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            var mode = member.mode & ~(Self.channelOperatorMode | Self.channelSpeechMode)
            if op.state == .on { mode |= Self.channelOperatorMode }
            if speak.state == .on { mode |= Self.channelSpeechMode }
            self.client.setChannelUserMode(channelID: active.channelID, userID: member.userID, mode: mode) { [weak self] result in
                if case let .failure(error) = result {
                    self?.showError(LF("Member permissions could not be changed: %@", Self.displayMessage(for: error)))
                }
            }
        }
    }

    func persistActiveChannelComposerDraft() {
        guard !isRestoringChannelComposer,
              let channelID = activeChannel?.channelID,
              var session = joinedChannels[channelID] else { return }
        session.draftText = channelMessageField.string
        session.draftAttachmentTokens = channelAttachmentStrip.tokens
        if let scroll = channelChatTextView.enclosingScrollView {
            session.transcriptScrollY = scroll.contentView.bounds.origin.y
        }
        joinedChannels[channelID] = session
    }

    func restoreActiveChannelComposerDraft() {
        isRestoringChannelComposer = true
        defer {
            isRestoringChannelComposer = false
            updateChannelComposerHeight()
            updateChannelComposerPresentation()
        }
        channelAttachmentStrip.clear()
        guard let channelID = activeChannel?.channelID,
              let session = joinedChannels[channelID] else {
            channelMessageField.string = ""
            return
        }
        channelMessageField.string = session.draftText
        for token in session.draftAttachmentTokens {
            for segment in LegacyMediaReference.segments(in: token) {
                switch segment {
                case let .image(id):
                    channelAttachmentStrip.addExistingImage(id: id, preview: mediaCache?.image(id: id), filename: L("Draft image"))
                case let .youtube(reference):
                    channelAttachmentStrip.addYouTube(reference)
                case .text:
                    break
                }
            }
        }
    }

    func updateChannelComposerHeight() {
        guard let constraint = channelComposerHeightConstraint else { return }
        let width = max(120, channelMessageField.bounds.width)
        channelMessageField.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if let layoutManager = channelMessageField.layoutManager,
           let textContainer = channelMessageField.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer).height
            let desired = min(112, max(38, ceil(used + 18)))
            if abs(constraint.constant - desired) > 0.5 { constraint.constant = desired }
        } else if abs(constraint.constant - 38) > 0.5 {
            constraint.constant = 38
        }
    }

    func updateChannelComposerPresentation() {
        let connected = client.isConnected
        let hasRoom = activeChannel != nil
        let writable = hasRoom && canSendToActiveChannel
        let enabled = connected && writable && !channelSendInFlight
        channelMessageField.isEditable = enabled
        channelMessageField.isSelectable = true
        channelComposerPlaceholderLabel.isHidden = !channelMessageField.string.isEmpty
        if !connected {
            channelComposerPlaceholderLabel.stringValue = L("Reconnect to send messages")
            channelComposerStatusLabel.stringValue = L("Disconnected")
            channelComposerStatusLabel.textColor = CarrachoTheme.secondaryText
        } else if !hasRoom {
            channelComposerPlaceholderLabel.stringValue = L("Join a room to chat…")
            channelComposerStatusLabel.stringValue = ""
        } else if !writable {
            channelComposerPlaceholderLabel.stringValue = L("Read-only: an operator must grant speaking permission")
            channelComposerStatusLabel.stringValue = L("You can read this room, but your current role cannot send messages.")
            channelComposerStatusLabel.textColor = CarrachoTheme.secondaryText
        } else if channelSendInFlight {
            channelComposerPlaceholderLabel.stringValue = L("Sending…")
            channelComposerStatusLabel.stringValue = L("Sending…")
            channelComposerStatusLabel.textColor = CarrachoTheme.secondaryText
        } else if let active = activeChannel {
            channelComposerPlaceholderLabel.stringValue = LF("Message #%@…", Self.macRomanString(active.name))
            if !channelComposerStatusLabel.stringValue.hasPrefix(L("Message could not be sent")) {
                channelComposerStatusLabel.stringValue = ""
            }
        }
        channelSendButton.isEnabled = enabled
            && !composedRichText(channelMessageField.string, attachments: channelAttachmentStrip).isEmpty
        channelEmojiButton.isEnabled = enabled
        channelAttachButton.isEnabled = enabled && mediaClient != nil
            && channelAttachmentStrip.imageCount < LegacyMediaTransfer.maximumImagesPerChatMessage
        channelYouTubeButton.isEnabled = enabled && lastLoginResult?.supportsYouTubeLinks == true
            && channelAttachmentStrip.youtubeCount < LegacyMediaTransfer.maximumYouTubeLinksPerChatMessage
    }

    func channelTranscriptIsNearBottom() -> Bool {
        guard let scroll = channelChatTextView.enclosingScrollView else { return true }
        let visible = scroll.contentView.bounds
        let documentHeight = scroll.documentView?.bounds.height ?? 0
        return documentHeight - visible.maxY <= 28
    }

    func restoreChannelTranscriptScrollPosition(scrollToBottom: Bool = false) {
        guard let channelID = activeChannel?.channelID,
              let session = joinedChannels[channelID],
              let scroll = channelChatTextView.enclosingScrollView else { return }
        DispatchQueue.main.async { [weak self, weak scroll] in
            guard let self, let scroll,
                  self.activeChannel?.channelID == channelID else { return }
            if scrollToBottom {
                self.channelChatTextView.scrollToEndOfDocument(nil)
            } else {
                let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                let y = min(max(0, session.transcriptScrollY), maxY)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }

    func persistActiveChannelSnapshot() {
        persistActiveChannelComposerDraft()
        guard let active = activeChannel else { return }
        var session = joinedChannels[active.channelID] ?? JoinedChannelSession(
            state: active, members: channelMembers, transcript: [], unreadCount: 0
        )
        session.state = active
        session.members = channelMembers
        joinedChannels[active.channelID] = session
    }

    func installJoinedChannel(_ state: LegacyChannelState) {
        persistActiveChannelSnapshot()
        let members = Dictionary(uniqueKeysWithValues: state.members.map { ($0.userID, $0.mode) })
        var session = joinedChannels[state.channelID] ?? JoinedChannelSession(
            state: state, members: members, transcript: [], unreadCount: 0
        )
        session.state = state
        session.members = members
        session.unreadCount = 0
        if session.transcript.count > 1000 { session.transcript.removeFirst(session.transcript.count - 1000) }
        joinedChannels[state.channelID] = session
        activeChannel = state
        channelMembers = members
        restoreActiveChannelComposerDraft()
        selectChannelRow(channelID: state.channelID)
        reloadJoinedChannelSidebar()
        reloadChannelView()
        restoreChannelTranscriptScrollPosition(scrollToBottom: session.transcript.isEmpty)
    }

    func activateJoinedChannel(_ channelID: UInt32) {
        guard var session = joinedChannels[channelID] else { return }
        persistActiveChannelSnapshot()
        session.unreadCount = 0
        joinedChannels[channelID] = session
        activeChannel = session.state
        channelMembers = session.members
        restoreActiveChannelComposerDraft()
        selectChannelRow(channelID: channelID)
        reloadJoinedChannelSidebar()
        reloadChannelView()
        restoreChannelTranscriptScrollPosition()
        if currentWorkspace == .conferences, canSendToActiveChannel {
            view.window?.makeFirstResponder(channelMessageField)
        }
    }

    func selectChannelRow(channelID: UInt32) {
        guard let row = displayedChannels.firstIndex(where: { $0.channelID == channelID }) else { return }
        let wasReloading = isReloadingChannelTable
        isReloadingChannelTable = true
        channelTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        channelTable.scrollRowToVisible(row)
        isReloadingChannelTable = wasReloading
    }

    func clearChatSessions() {
        activeChannel = nil
        channelMembers = [:]
        joinedChannels.removeAll()
        channelMessageField.string = ""
        channelAttachmentStrip.clear()
        channelSendInFlight = false
        reloadJoinedChannelSidebar()
        updateChannelComposerPresentation()
        chatSmokeDumpPath = nil
    }

    func leaveJoinedChannelLocally(_ channelID: UInt32) {
        joinedChannels.removeValue(forKey: channelID)
        if activeChannel?.channelID == channelID {
            activeChannel = nil
            channelMembers = [:]
            if let next = joinedChannels.keys.sorted().first { activateJoinedChannel(next) }
            else { reloadChannelView() }
        } else {
            reloadChannelView()
        }
        reloadJoinedChannelSidebar()
        refreshChannelCatalog()
    }

    func channelDisplayName(_ channelID: UInt32) -> String {
        if let session = joinedChannels[channelID] {
            let value = Self.macRomanString(session.state.name)
            if !value.isEmpty { return value }
        }
        if let summary = lastChannels.first(where: { $0.channelID == channelID }) {
            let value = Self.macRomanString(summary.name)
            if !value.isEmpty { return value }
        }
        return LF("Channel %@", String(channelID))
    }

    func appendChannelSystem(_ text: String, channelID: UInt32, markUnread: Bool = true) {
        guard var session = joinedChannels[channelID] else { return }
        session.transcript.append(ChannelTranscriptEntry(timestamp: Date(), kind: .system(text)))
        if session.transcript.count > 1000 { session.transcript.removeFirst(session.transcript.count - 1000) }
        if markUnread && (activeChannel?.channelID != channelID || currentWorkspace != .conferences) {
            session.unreadCount += 1
        }
        joinedChannels[channelID] = session
        reloadJoinedChannelSidebar()
        if activeChannel?.channelID == channelID {
            reloadChannelView(reloadTables: false)
        } else if channelDiscoverySheet != nil {
            channelTable.reloadData()
        }
    }

    func appendChannelMessage(_ message: LegacyChannelMessage) {
        guard var session = joinedChannels[message.channelID] else { return }
        session.transcript.append(ChannelTranscriptEntry(
            timestamp: Date(),
            kind: .message(senderUserID: message.senderUserID, message: message.message, attribute: message.attribute)
        ))
        if session.transcript.count > 1000 { session.transcript.removeFirst(session.transcript.count - 1000) }
        if activeChannel?.channelID != message.channelID || currentWorkspace != .conferences {
            session.unreadCount += 1
        }
        joinedChannels[message.channelID] = session
        reloadJoinedChannelSidebar()
        if activeChannel?.channelID == message.channelID {
            reloadChannelView(reloadTables: false)
        } else if channelDiscoverySheet != nil {
            channelTable.reloadData()
        }
        writeChatSmokeSnapshotIfReady()
    }

    func syncChannelMemberCount(_ channelID: UInt32) {
        if let index = lastChannels.firstIndex(where: { $0.channelID == channelID }),
           let session = joinedChannels[channelID] {
            lastChannels[index].memberCount = UInt32(session.members.count)
        }
        if channelDiscoverySheet != nil { channelTable.reloadData() }
        reloadJoinedChannelSidebar()
        if activeChannel?.channelID == channelID { updateInspectorContext() }
    }

    func removeDisconnectedUserFromChannels(_ userID: UInt32) {
        channelMembers.removeValue(forKey: userID)

        for channelID in Array(joinedChannels.keys) {
            guard var session = joinedChannels[channelID],
                  session.members.removeValue(forKey: userID) != nil else { continue }
            session.state.members = session.members.map { LegacyChannelMember(userID: $0.key, mode: $0.value) }
            joinedChannels[channelID] = session

            if let index = lastChannels.firstIndex(where: { $0.channelID == channelID }) {
                lastChannels[index].memberCount = UInt32(session.members.count)
            }
            if activeChannel?.channelID == channelID {
                activeChannel = session.state
                channelMembers = session.members
            }
        }
    }

    func deletePendingMedia(_ id: UUID) {
        guard lastLoginResult?.supportsMediaOwnerDelete == true, let mediaClient else { return }
        mediaClient.delete(id: id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.applyDeletedMedia(id)
            case let .failure(error):
                self.appendLine("\n" + LF("Unused media could not be deleted immediately: %@", Self.displayMessage(for: error)))
            }
        }
    }

    func confirmDeletePostedMedia(_ id: UUID) {
        guard lastLoginResult?.supportsMediaOwnerDelete == true, let mediaClient, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Delete Image?")
        alert.informativeText = L("This permanently deletes the image from the server's media pool and removes it from currently displayed News/Chat content. Only images uploaded by your account can be deleted.")
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [weak self, weak mediaClient] response in
            guard response == .alertFirstButtonReturn, let self, let mediaClient, self.mediaClient === mediaClient else { return }
            mediaClient.delete(id: id) { [weak self, weak mediaClient] result in
                guard let self, self.mediaClient === mediaClient else { return }
                switch result {
                case .success:
                    self.applyDeletedMedia(id)
                case let .failure(error):
                    if let mediaError = error as? LegacyMediaClientError, case .accessDenied = mediaError {
                        self.showError(L("This image is not owned by your account or has already been deleted."))
                    } else {
                        self.showError(LF("Image could not be deleted: %@", Self.displayMessage(for: error)))
                    }
                }
            }
        }
    }

    func applyDeletedMedia(_ id: UUID) {
        mediaCache?.remove(id: id)
        mediaDownloadsInFlight.remove(id)
        mediaDownloadFailures.remove(id)
        hiddenMediaIDs.insert(id)
        renderActiveChannelTranscript()
        reloadNewsView()
    }

    func mediaAttributedString(fromWire data: Data, context: LegacyMediaContext,
                                       baseFont: NSFont, maximumWidth: CGFloat,
                                       maximumHeight: CGFloat, reload: @escaping () -> Void) -> NSAttributedString {
        let source = CarrachoTextWire.string(from: data)
        let segments = LegacyMediaReference.segments(in: source)
        guard segments.contains(where: {
            switch $0 {
            case .image, .youtube: return true
            case .text: return false
            }
        }) else {
            return CarrachoHTMLText.attributedString(from: source, baseFont: baseFont, expandLegacyEmoticons: true)
        }
        let output = NSMutableAttributedString()
        for segment in segments {
            switch segment {
            case let .text(text):
                output.append(CarrachoHTMLText.attributedString(from: text, baseFont: baseFont, expandLegacyEmoticons: true))
            case let .image(id):
                if hiddenMediaIDs.contains(id) { continue }
                if let image = mediaCache?.image(id: id) {
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    let rawWidth = max(1, image.size.width), rawHeight = max(1, image.size.height)
                    let scale = min(1, maximumWidth / rawWidth, maximumHeight / rawHeight)
                    attachment.bounds = NSRect(x: 0, y: -4, width: max(1, floor(rawWidth * scale)),
                                               height: max(1, floor(rawHeight * scale)))
                    let rendered = NSMutableAttributedString(attachment: attachment)
                    rendered.addAttribute(.carrachoMediaID, value: id.uuidString.lowercased(),
                                          range: NSRange(location: 0, length: rendered.length))
                    output.append(NSAttributedString(string: "\n"))
                    output.append(rendered)
                    output.append(NSAttributedString(string: "\n"))
                } else {
                    let failed = mediaDownloadFailures.contains(id)
                    output.append(NSAttributedString(
                        string: failed ? L("[Image unavailable]") : L("[Loading image…]"),
                        attributes: [.font: NSFont.systemFont(ofSize: max(10, baseFont.pointSize - 1)),
                                     .foregroundColor: CarrachoTheme.secondaryText]
                    ))
                    requestMediaIfNeeded(id: id, context: context, reload: reload)
                }
            case let .youtube(reference):
                let previewWidth = min(maximumWidth, 356)
                let previewImage = CarrachoYouTubeThumbnailCache.shared.image(videoID: reference.videoID)
                let attachment = NSTextAttachment()
                attachment.attachmentCell = CarrachoYouTubePreviewAttachmentCell(
                    previewImage: previewImage,
                    width: previewWidth
                )
                let rendered = NSMutableAttributedString(attachment: attachment)
                rendered.addAttribute(.carrachoYouTubeVideoID, value: reference.videoID,
                                      range: NSRange(location: 0, length: rendered.length))
                let link = NSAttributedString(
                    string: reference.canonicalURLString,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: max(10, baseFont.pointSize - 1)),
                        .link: reference.canonicalURL,
                    ]
                )
                output.append(NSAttributedString(string: "\n"))
                output.append(rendered)
                output.append(NSAttributedString(string: "\n"))
                output.append(link)
                output.append(NSAttributedString(string: "\n"))
                if previewImage == nil {
                    CarrachoYouTubeThumbnailCache.shared.request(videoID: reference.videoID, completion: reload)
                }
            }
        }
        return output
    }

    func requestMediaIfNeeded(id: UUID, context: LegacyMediaContext, reload: @escaping () -> Void) {
        guard !mediaDownloadFailures.contains(id), !mediaDownloadsInFlight.contains(id),
              let mediaClient, let mediaCache else { return }
        mediaDownloadsInFlight.insert(id)
        mediaClient.download(id: id, context: context) { [weak self, weak mediaClient] result in
            guard let self else { return }
            self.mediaDownloadsInFlight.remove(id)
            guard self.mediaClient === mediaClient else { return }
            switch result {
            case let .success(content):
                mediaCache.store(content)
                self.mediaDownloadFailures.remove(id)
            case let .failure(error):
                if let mediaError = error as? LegacyMediaClientError, case .accessDenied = mediaError {
                    self.mediaCache?.remove(id: id)
                    self.mediaDownloadFailures.remove(id)
                    self.hiddenMediaIDs.insert(id)
                } else {
                    self.mediaDownloadFailures.insert(id)
                }
            }
            reload()
        }
    }

    func channelAvatarAttachment(userID: UInt32, size: CGFloat = 28) -> NSAttributedString {
        let image: NSImage?
        if let user = liveUsers[userID] {
            image = AvatarArtwork.userImage(picture: user.picture,
                                            isLegacyTransport: user.isLegacyTransport)
        } else {
            image = AvatarArtwork.defaultImage()
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -7, width: size, height: size)
        return NSAttributedString(attachment: attachment)
    }

    func renderActiveChannelTranscript() {
        let wasAtBottom = channelTranscriptIsNearBottom()
        let oldY = channelChatTextView.enclosingScrollView?.contentView.bounds.origin.y ?? 0

        // Rebuilding NSTextStorage normally resets the selection to insertion point 0. Keep a
        // user's selected transcript text intact so asynchronous media/user updates do not make
        // Copy appear broken.
        let oldSelectedRanges = channelChatTextView.selectedRanges
        let hadTextSelection = oldSelectedRanges.contains { value in
            value.rangeValue.location != NSNotFound && value.rangeValue.length > 0
        }
        guard let active = activeChannel, let session = joinedChannels[active.channelID] else {
            let emptyParagraph = NSMutableParagraphStyle()
            emptyParagraph.firstLineHeadIndent = 8
            emptyParagraph.headIndent = 8
            channelChatTextView.textStorage?.setAttributedString(NSAttributedString(
                string: L("Choose a joined room to open its conversation."),
                attributes: [
                    .font: NSFont.systemFont(ofSize: channelChatFontSize),
                    .foregroundColor: CarrachoTheme.secondaryText,
                    .paragraphStyle: emptyParagraph,
                ]
            ))
            return
        }

        let output = NSMutableAttributedString()
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        let baseFont = NSFont.systemFont(ofSize: channelChatFontSize)
        let authorFont = NSFont.systemFont(ofSize: max(12, channelChatFontSize + 1), weight: .semibold)
        let metaFont = NSFont.systemFont(ofSize: max(10, channelChatFontSize - 1))
        let systemFont = NSFont.systemFont(ofSize: max(10.5, channelChatFontSize - 1))

        let avatarSize: CGFloat = max(28, min(36, channelChatFontSize + 19))
        let contentIndent = avatarSize + 14

        func appendSpacer() {
            output.append(NSAttributedString(
                string: "\n",
                attributes: [.font: NSFont.systemFont(ofSize: max(7, channelChatFontSize - 5))]
            ))
        }

        if session.transcript.isEmpty {
            let name = Self.macRomanString(active.name)
            let welcomeParagraph = NSMutableParagraphStyle()
            welcomeParagraph.firstLineHeadIndent = 8
            welcomeParagraph.headIndent = 8
            welcomeParagraph.paragraphSpacing = 5

            let welcome = NSMutableAttributedString(
                string: LF("Welcome to #%@\n", name),
                attributes: [
                    .font: NSFont.systemFont(ofSize: max(17, channelChatFontSize + 4), weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: welcomeParagraph,
                ]
            )
            welcome.append(NSAttributedString(
                string: L("No messages in this local session yet."),
                attributes: [
                    .font: systemFont,
                    .foregroundColor: CarrachoTheme.secondaryText,
                    .paragraphStyle: welcomeParagraph,
                ]
            ))
            output.append(welcome)
        } else {
            for (index, entry) in session.transcript.enumerated() {
                let time = timeFormatter.string(from: entry.timestamp)

                switch entry.kind {
                case let .system(text):
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.firstLineHeadIndent = contentIndent
                    paragraph.headIndent = contentIndent
                    paragraph.tailIndent = -12
                    paragraph.lineSpacing = 1
                    paragraph.paragraphSpacing = 3

                    output.append(NSAttributedString(
                        string: "\(time)  ",
                        attributes: [
                            .font: metaFont,
                            .foregroundColor: CarrachoTheme.tertiaryText,
                            .paragraphStyle: paragraph,
                        ]
                    ))
                    output.append(NSAttributedString(
                        string: text,
                        attributes: [
                            .font: systemFont,
                            .foregroundColor: CarrachoTheme.secondaryText,
                            .paragraphStyle: paragraph,
                        ]
                    ))

                case let .message(senderUserID, message, attribute):
                    let sender = liveUsers[senderUserID].map { Self.macRomanString($0.nickname) } ?? L("Unknown User")
                    let authorColor = userGroupColors[senderUserID].map(Self.colorFromRGB) ?? CarrachoTheme.accent

                    let headerParagraph = NSMutableParagraphStyle()
                    headerParagraph.firstLineHeadIndent = 0
                    headerParagraph.headIndent = contentIndent
                    headerParagraph.tailIndent = -12
                    headerParagraph.paragraphSpacing = 0

                    output.append(channelAvatarAttachment(userID: senderUserID, size: avatarSize))
                    output.append(NSAttributedString(
                        string: "  \(sender)",
                        attributes: [
                            .font: authorFont,
                            .foregroundColor: authorColor,
                            .paragraphStyle: headerParagraph,
                        ]
                    ))
                    output.append(NSAttributedString(
                        string: "  \(time)",
                        attributes: [
                            .font: metaFont,
                            .foregroundColor: CarrachoTheme.tertiaryText,
                            .paragraphStyle: headerParagraph,
                        ]
                    ))
                    if attribute != 0 {
                        output.append(NSAttributedString(
                            string: String(format: "  · 0x%02X", attribute),
                            attributes: [
                                .font: metaFont,
                                .foregroundColor: CarrachoTheme.tertiaryText,
                                .paragraphStyle: headerParagraph,
                            ]
                        ))
                    }
                    output.append(NSAttributedString(
                        string: "\n",
                        attributes: [.font: NSFont.systemFont(ofSize: max(2, channelChatFontSize - 9))]
                    ))

                    let bodyParagraph = NSMutableParagraphStyle()
                    bodyParagraph.firstLineHeadIndent = contentIndent
                    bodyParagraph.headIndent = contentIndent
                    bodyParagraph.tailIndent = -12
                    bodyParagraph.lineSpacing = 1.5
                    bodyParagraph.paragraphSpacing = 2

                    let body = NSMutableAttributedString(attributedString: mediaAttributedString(
                        fromWire: message,
                        context: .channel(active.channelID),
                        baseFont: baseFont,
                        maximumWidth: 560,
                        maximumHeight: 360
                    ) { [weak self] in
                        self?.renderActiveChannelTranscript()
                    })
                    if body.length > 0 {
                        body.addAttribute(
                            .paragraphStyle,
                            value: bodyParagraph,
                            range: NSRange(location: 0, length: body.length)
                        )
                    }
                    output.append(body)
                }

                if index + 1 < session.transcript.count {
                    appendSpacer()
                    appendSpacer()
                }
            }
        }

        channelChatTextView.textStorage?.setAttributedString(output)
        if hadTextSelection {
            let length = output.length
            let restored = oldSelectedRanges.compactMap { value -> NSValue? in
                let range = value.rangeValue
                guard range.location != NSNotFound, range.location < length else { return nil }
                let end = min(length, range.location + range.length)
                guard end > range.location else { return nil }
                return NSValue(range: NSRange(location: range.location, length: end - range.location))
            }
            if !restored.isEmpty {
                channelChatTextView.setSelectedRanges(restored, affinity: .downstream, stillSelecting: false)
            }
        }
        channelChatTextView.needsDisplay = true

        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeChannel?.channelID == active.channelID,
                  let scroll = self.channelChatTextView.enclosingScrollView else { return }
            if wasAtBottom {
                self.channelChatTextView.scrollToEndOfDocument(nil)
            } else {
                let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                let y = min(max(0, oldY), maxY)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            if var latest = self.joinedChannels[active.channelID] {
                latest.transcriptScrollY = scroll.contentView.bounds.origin.y
                self.joinedChannels[active.channelID] = latest
            }
        }
    }

    func startChannelCatalogPolling() {
        channelCatalogRefreshTimer?.invalidate()
        channelCatalogRefreshTimer = nil
        guard client.isConnected else { return }
        channelCatalogRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshChannelCatalog()
        }
    }

    func stopChannelCatalogPolling() {
        channelCatalogRefreshTimer?.invalidate()
        channelCatalogRefreshTimer = nil
        channelCatalogRefreshInFlight = false
        channelCatalogManualRefreshInFlight = false
    }

    func selectedChannelID() -> UInt32? {
        let row = channelTable.selectedRow
        guard row >= 0, row < displayedChannels.count else { return nil }
        return displayedChannels[row].channelID
    }

    func reloadChannelTablePreservingSelection(preferredChannelID: UInt32? = nil) {
        let channelID = preferredChannelID ?? selectedChannelID() ?? activeChannel?.channelID
        isReloadingChannelTable = true
        defer { isReloadingChannelTable = false }
        channelTable.reloadData()
        if let channelID, let row = displayedChannels.firstIndex(where: { $0.channelID == channelID }) {
            channelTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            channelTable.scrollRowToVisible(row)
        } else {
            channelTable.deselectAll(nil)
        }
    }

    func refreshChannelCatalog(manual: Bool = false) {
        guard client.isConnected else { return }
        if channelCatalogRefreshInFlight {
            if manual && !channelCatalogManualRefreshInFlight {
                // A click during an already-running background poll adopts that request as the
                // manual refresh, so the user still gets feedback without sending a duplicate.
                channelCatalogManualRefreshInFlight = true
                updateChannelDiscoverySelection()
            }
            return
        }
        let requestClient = client
        channelCatalogRefreshInFlight = true
        channelCatalogManualRefreshInFlight = manual
        updateChannelDiscoverySelection()
        requestClient.requestChannels { [weak self, weak requestClient] result in
            guard let self, let requestClient, self.client === requestClient, requestClient.isConnected else { return }
            self.channelCatalogRefreshInFlight = false
            self.channelCatalogManualRefreshInFlight = false
            if case let .success(channels) = result {
                let selectedID = self.selectedChannelID()
                self.lastChannels = channels
                self.reloadChannelTablePreservingSelection(preferredChannelID: selectedID)
                self.reloadChannelView(reloadTables: false, renderTranscript: false)
                self.refreshShellChrome()
            }
            self.updateChannelDiscoverySelection()
            if case let .failure(error) = result {
                self.channelDiscoveryView?.showRefreshError(Self.displayMessage(for: error))
            }
        }
    }

    @objc func showChannelDiscovery(_ sender: Any?) {
        guard client.isConnected, let parent = view.window else { return }
        guard channelDiscoverySheet == nil else {
            channelDiscoverySheet?.makeKeyAndOrderFront(nil)
            return
        }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 460),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        sheet.title = L("Discover Rooms")
        sheet.isReleasedWhenClosed = false
        sheet.titlebarAppearsTransparent = true
        sheet.backgroundColor = RoomDiscoveryStyle.background
        let discovery = RoomDiscoveryView(table: channelTable, joinedLabel: chatJoinedRoomsLabel,
                                          joinButton: channelJoinButton, deleteButton: channelDiscoveryDeleteButton)
        discovery.refreshButton.target = self
        discovery.refreshButton.action = #selector(refreshChannelDiscovery(_:))
        discovery.closeButton.target = self
        discovery.closeButton.action = #selector(closeChannelDiscovery(_:))
        channelDiscoveryDeleteButton.image = symbolImage("trash", fallback: NSImage.trashEmptyName)
        channelDiscoveryDeleteButton.imagePosition = .imageLeading
        channelDiscoveryDeleteButton.contentTintColor = .systemRed
        sheet.contentView = discovery
        channelDiscoveryView = discovery
        channelDiscoverySheet = sheet
        reloadChannelTablePreservingSelection(preferredChannelID: activeChannel?.channelID)
        updateChannelDiscoverySelection()
        sheet.initialFirstResponder = channelTable
        parent.beginSheet(sheet) { [weak self, weak sheet] _ in
            guard let self, self.channelDiscoverySheet === sheet else { return }
            self.channelDiscoverySheet = nil
            self.channelDiscoveryView = nil
        }
        refreshChannelCatalog()
    }

    @objc func closeChannelDiscovery(_ sender: Any?) { closeChannelDiscoverySheet() }

    @objc func refreshChannelDiscovery(_ sender: Any?) {
        refreshChannelCatalog(manual: true)
    }

    func updateChannelDiscoverySelection() {
        channelDiscoveryView?.update(roomCount: displayedChannels.count,
                                     loading: channelCatalogRefreshInFlight,
                                     manualRefresh: channelCatalogManualRefreshInFlight,
                                     connected: client.isConnected)
        chatJoinedRoomsLabel.stringValue = LF("%@/%@ joined", String(joinedChannels.count), String(Self.maximumJoinedChannels))
        if let sheet = channelDiscoverySheet, let discovery = channelDiscoveryView {
            discovery.layoutSubtreeIfNeeded()
            sheet.setContentSize(NSSize(width: 800, height: discovery.fittingSize.height))
        }
        let row = channelTable.selectedRow
        guard row >= 0, row < displayedChannels.count else {
            channelJoinButton.title = L("Join")
            channelJoinButton.isEnabled = false
            channelDiscoveryDeleteButton.isHidden = true
            channelDiscoveryDeleteButton.isEnabled = false
            return
        }
        let summary = displayedChannels[row]
        let canDelete = isRemoteAdministrator && !isConnectedToClassicServer && summary.channelID != 1
        channelDiscoveryDeleteButton.isHidden = !canDelete
        channelDiscoveryDeleteButton.isEnabled = canDelete
        if joinedChannels[summary.channelID] != nil {
            channelJoinButton.title = activeChannel?.channelID == summary.channelID ? L("Already Joined") : L("Open")
            channelJoinButton.isEnabled = activeChannel?.channelID != summary.channelID
        } else {
            channelJoinButton.title = summary.isPasswordProtected ? L("Join…") : L("Join")
            channelJoinButton.isEnabled = canJoinChatRooms && joinedChannels.count < Self.maximumJoinedChannels
        }
    }

    @objc func joinSelectedChannel(_ sender: Any?) {
        let row = (sender as? NSTableView) === channelTable && channelTable.clickedRow >= 0
            ? channelTable.clickedRow : channelTable.selectedRow
        guard client.isConnected, row >= 0, row < displayedChannels.count else { return }
        guard canJoinChatRooms else {
            showError(L("This account is not allowed to join chat rooms."))
            return
        }
        let summary = displayedChannels[row]
        if joinedChannels[summary.channelID] != nil {
            activateJoinedChannel(summary.channelID)
            selectWorkspace(.conferences)
            closeChannelDiscoverySheet()
            return
        }
        guard joinedChannels.count < Self.maximumJoinedChannels else {
            showError(LF("You can be in at most %@ chat rooms at the same time.", String(Self.maximumJoinedChannels)))
            return
        }
        if summary.isPasswordProtected {
            requestChannelPasswordAndJoin(summary)
        } else {
            performChannelJoin(summary: summary, password: Data())
        }
    }

    func requestChannelPasswordAndJoin(_ summary: LegacyChannelSummary) {
        guard let parent = channelDiscoverySheet ?? view.window else { return }
        let alert = NSAlert()
        alert.messageText = LF("Join #%@", Self.macRomanString(summary.name))
        alert.informativeText = L("This room is password protected.")
        alert.addButton(withTitle: L("Join"))
        alert.addButton(withTitle: L("Cancel"))
        let password = NSSecureTextField(string: "")
        password.placeholderString = L("Room password")
        password.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = password
        alert.window.initialFirstResponder = password
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let data = password.stringValue.data(using: .macOSRoman), data.count <= 32 else {
                self.showError(L("The room password must be representable in MacRoman and at most 32 bytes long."))
                return
            }
            self.performChannelJoin(summary: summary, password: data)
        }
    }

    func performChannelJoin(summary: LegacyChannelSummary, password: Data) {
        guard canJoinChatRooms else {
            showError(L("This account is not allowed to join chat rooms."))
            return
        }
        channelJoinButton.isEnabled = false
        channelJoinButton.title = L("Joining…")
        client.joinChannel(channelID: summary.channelID, name: summary.name, password: password) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(state):
                self.installJoinedChannel(state)
                self.refreshChannelCatalog()
                self.selectWorkspace(.conferences)
                self.closeChannelDiscoverySheet()
                self.view.window?.makeFirstResponder(self.channelMessageField)
            case let .failure(error):
                if let clientError = error as? LegacyControlClientError,
                   case .serverError(0xca) = clientError {
                    self.showError(L("The room password is not valid."))
                } else {
                    self.showError(LF("Could not join the chat room: %@", Self.displayMessage(for: error)))
                }
                self.updateChannelDiscoverySelection()
                self.reloadChannelView(reloadTables: false)
            }
        }
    }

    func closeChannelDiscoverySheet() {
        guard let sheet = channelDiscoverySheet else { return }
        if let parent = sheet.sheetParent { parent.endSheet(sheet) }
        sheet.orderOut(nil)
        channelDiscoverySheet = nil
        channelDiscoveryView = nil
    }

    @objc func clearActiveChannelTranscript(_ sender: Any?) {
        guard let channelID = activeChannel?.channelID, var session = joinedChannels[channelID] else { return }
        session.transcript.removeAll(keepingCapacity: true)
        session.unreadCount = 0
        joinedChannels[channelID] = session
        renderActiveChannelTranscript()
        reloadChannelTablePreservingSelection(preferredChannelID: channelID)
        reloadChannelView(reloadTables: false)
        view.window?.makeFirstResponder(channelMessageField)
    }

    @objc func deleteSelectedChannel(_ sender: Any?) {
        let row = (sender as? NSTableView) === channelTable && channelTable.clickedRow >= 0
            ? channelTable.clickedRow : channelTable.selectedRow
        guard row >= 0, row < displayedChannels.count else { return }
        let summary = displayedChannels[row]
        confirmDeleteChannel(channelID: summary.channelID, name: summary.name,
                             parent: channelDiscoverySheet ?? view.window)
    }

    @objc func deleteCurrentChannel(_ sender: Any?) {
        guard let active = activeChannel else { return }
        confirmDeleteChannel(channelID: active.channelID, name: active.name, parent: view.window)
    }

    func confirmDeleteChannel(channelID: UInt32, name: Data, parent: NSWindow?) {
        guard client.isConnected, isRemoteAdministrator, !isConnectedToClassicServer,
              channelID != 1, let parent else { return }
        let roomName = Self.macRomanString(name)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = LF("Delete #%@?", roomName)
        alert.informativeText = L("This permanently removes the room and removes all current participants from it.")
        alert.addButton(withTitle: L("Delete Room"))
        alert.addButton(withTitle: L("Cancel"))
        if #available(macOS 11.0, *) {
            alert.buttons.first?.hasDestructiveAction = true
        }
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.channelDeleteButton.isEnabled = false
            self.channelDiscoveryDeleteButton.isEnabled = false
            self.client.deleteChannel(channelID: channelID) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    // The server also broadcasts channelDeleted. Remove immediately so the
                    // initiating administrator never sees a stale row while that event is queued.
                    self.lastChannels.removeAll { $0.channelID == channelID }
                    if self.joinedChannels[channelID] != nil {
                        self.leaveJoinedChannelLocally(channelID)
                    } else {
                        self.refreshChannelCatalog()
                        if self.channelDiscoverySheet != nil {
                            self.reloadChannelTablePreservingSelection()
                            self.updateChannelDiscoverySelection()
                        }
                    }
                case let .failure(error):
                    self.showError(LF("Could not delete the chat room: %@", Self.displayMessage(for: error)))
                    self.reloadChannelView()
                    self.updateChannelDiscoverySelection()
                }
            }
        }
    }

    @objc func leaveCurrentChannel(_ sender: Any?) {
        guard let active = activeChannel, client.isConnected else { return }
        channelLeaveButton.isEnabled = false
        let leavingID = active.channelID
        client.leaveChannel(channelID: leavingID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.leaveJoinedChannelLocally(leavingID)
            case let .failure(error):
                self.showError(LF("Could not leave the chat room: %@", Self.displayMessage(for: error)))
                self.reloadChannelView()
            }
        }
    }

    @objc func attachYouTubeToChannel(_ sender: Any?) {
        guard client.isConnected, activeChannel != nil,
              lastLoginResult?.supportsYouTubeLinks == true,
              channelAttachmentStrip.youtubeCount < LegacyMediaTransfer.maximumYouTubeLinksPerChatMessage,
              let parent = view.window else { return }
        presentYouTubePrompt(parent: parent) { [weak self] reference in
            self?.channelAttachmentStrip.addYouTube(reference)
        }
    }

    func presentYouTubePrompt(parent: NSWindow,
                                      completion: @escaping (LegacyYouTubeReference) -> Void) {
        let prompt = NSAlert()
        prompt.messageText = L("Add YouTube Video")
        prompt.informativeText = L("Only genuine HTTPS links from youtube.com or youtu.be are accepted. The preview can be played directly in Carracho; the video link below opens YouTube in your browser.")
        prompt.addButton(withTitle: L("Add"))
        prompt.addButton(withTitle: L("Cancel"))
        let field = NSTextField(string: "")
        field.placeholderString = "https://www.youtube.com/watch?v=…"
        field.frame = NSRect(x: 0, y: 0, width: 440, height: 24)
        if let clipboard = NSPasteboard.general.string(forType: .string),
           LegacyYouTubeReference(urlString: clipboard) != nil {
            field.stringValue = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        prompt.accessoryView = field
        prompt.beginSheetModal(for: parent) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard let reference = LegacyYouTubeReference(urlString: field.stringValue) else {
                self?.showError(L("Only real HTTPS YouTube links from youtube.com or youtu.be are allowed. Look-alike domains and arbitrary URLs are rejected."))
                return
            }
            completion(reference)
        }
    }

    @objc func attachImageToChannel(_ sender: Any?) {
        guard mediaClient != nil, activeChannel != nil else { return }
        let remaining = max(0, LegacyMediaTransfer.maximumImagesPerChatMessage - channelAttachmentStrip.imageCount)
        guard remaining > 0 else {
            showError(LF("A chat message can contain at most %@ images.", String(LegacyMediaTransfer.maximumImagesPerChatMessage)))
            return
        }
        chooseMediaImages(maximum: remaining) { [weak self] urls in
            self?.uploadChannelImages(urls: urls)
        }
    }

    func chooseMediaImages(maximum: Int, completion: @escaping @MainActor ([URL]) -> Void) {
        guard maximum > 0 else { completion([]); return }
        let panel = NSOpenPanel()
        panel.title = L("Choose Images")
        panel.prompt = L("Attach")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = maximum > 1
        panel.allowedFileTypes = ["png", "jpg", "jpeg"]
        panel.begin { response in
            Task { @MainActor in
                guard response == .OK else { return }
                completion(Array(panel.urls.prefix(maximum)))
            }
        }
    }

    func uploadPreparedMedia(_ items: [CarrachoPreparedMediaImage], client: LegacyMediaClient,
                                     completion: @escaping (Result<[UUID], Error>) -> Void) {
        guard !items.isEmpty else { completion(.success([])); return }
        var ids: [UUID] = []
        func upload(_ index: Int) {
            guard index < items.count else { completion(.success(ids)); return }
            let item = items[index]
            client.upload(filename: item.filename, data: item.data) { result in
                switch result {
                case let .success(id): ids.append(id); upload(index + 1)
                case let .failure(error): completion(.failure(error))
                }
            }
        }
        upload(0)
    }

    func addUploadedImages(ids: [UUID], prepared: [CarrachoPreparedMediaImage],
                                   to strip: CarrachoComposerAttachmentStrip) {
        for (id, item) in zip(ids, prepared) { strip.addImage(id: id, prepared: item) }
    }

    func composedRichText(_ plainText: String, attachments: CarrachoComposerAttachmentStrip) -> String {
        let base = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let references = attachments.tokens.joined(separator: "\n")
        if base.isEmpty { return references }
        if references.isEmpty { return base }
        return base + "\n" + references
    }

    @objc func sendChannelChat(_ sender: Any?) {
        guard !channelSendInFlight,
              let active = activeChannel,
              client.isConnected,
              canSendToActiveChannel else {
            updateChannelComposerPresentation()
            return
        }
        let raw = composedRichText(channelMessageField.string, attachments: channelAttachmentStrip)
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            updateChannelComposerPresentation()
            channelComposerStatusLabel.stringValue = L("Enter a message or add an attachment before sending.")
            channelComposerStatusLabel.textColor = .systemRed
            NSSound.beep()
            return
        }
        let message: Data
        do {
            message = try CarrachoTextWire.encode(raw, maximumBytes: 0x800)
        } catch {
            channelComposerStatusLabel.stringValue = L("The message may contain at most 2048 bytes after Unicode encoding.")
            channelComposerStatusLabel.textColor = .systemRed
            return
        }

        persistActiveChannelComposerDraft()
        let expectedChannelID = active.channelID
        channelSendInFlight = true
        channelComposerStatusLabel.stringValue = L("Sending…")
        channelComposerStatusLabel.textColor = CarrachoTheme.secondaryText
        updateChannelComposerPresentation()
        client.sendChannelMessage(channelID: expectedChannelID, message: message) { [weak self] result in
            guard let self else { return }
            self.channelSendInFlight = false
            switch result {
            case .success:
                if var session = self.joinedChannels[expectedChannelID] {
                    session.draftText = ""
                    session.draftAttachmentTokens = []
                    self.joinedChannels[expectedChannelID] = session
                }
                if self.activeChannel?.channelID == expectedChannelID {
                    self.isRestoringChannelComposer = true
                    self.channelMessageField.string = ""
                    self.channelAttachmentStrip.clear()
                    self.isRestoringChannelComposer = false
                    self.channelComposerStatusLabel.stringValue = ""
                    self.updateChannelComposerHeight()
                    self.updateChannelComposerPresentation()
                    self.view.window?.makeFirstResponder(self.channelMessageField)
                }
            case let .failure(error):
                self.channelComposerStatusLabel.stringValue = LF("Message could not be sent: %@", Self.displayMessage(for: error))
                self.channelComposerStatusLabel.textColor = .systemRed
                self.persistActiveChannelComposerDraft()
                self.updateChannelComposerPresentation()
            }
            self.reloadChannelView(reloadTables: false)
        }
    }

    func apply(state: LegacyControlClient.State) {
        switch state {
        case .idle:
            connectionSetupBookmarkID = nil
            connectingBookmarkID = nil
            connectedBookmarkID = nil
            resetSessionViews()
            reloadBookmarkStack()
            isAwaitingAgreementAcceptance = false
            deferredInteractiveEvents.removeAll()
            remoteAccountSummaries = []
            remoteAccountListLoading = false
            adminAccountStatusLabel.stringValue = localServerState.accounts.count == 1 ? LF("%@ local account", String(localServerState.accounts.count)) : LF("%@ local accounts", String(localServerState.accounts.count))
            adminAccountTable.reloadData()
            updateAdminSelectionButtons()
            fileTransferClient = nil
            fileSearchClient = nil
            fileSearchResults = nil
            newsClient = nil
            mediaClient = nil
            mediaCache = nil
            mediaDownloadsInFlight = []
            mediaDownloadFailures = []
            currentNewsIndex = nil
            currentArticle = nil
            currentNewsCategory = nil
            currentNewsThreads = []
            currentNewsThreadID = nil
            currentNewsThreadPosts = []
            currentNewsThreadArticles = []
            clearChatSessions()
            statusLabel.stringValue = L("Not connected")
            statusLabel.textColor = .secondaryLabelColor
            CarrachoTheme.setPrimaryButtonTitle(connectButton, L("Connect"))
            connectButton.isEnabled = true
            setInputsEnabled(true)
            activatePendingBookmarkIfPossible()
        case .connecting:
            reloadBookmarkStack()
            statusLabel.stringValue = L("TCP connection…")
            statusLabel.textColor = .secondaryLabelColor
            CarrachoTheme.setPrimaryButtonTitle(connectButton, L("Connecting…"))
            connectButton.isEnabled = false
            setInputsEnabled(false)
        case .handshaking:
            statusLabel.stringValue = L("Carracho handshake…")
            statusLabel.textColor = .secondaryLabelColor
        case .authenticating:
            statusLabel.stringValue = L("Signing in…")
            statusLabel.textColor = .secondaryLabelColor
        case .connected:
            connectedBookmarkID = connectingBookmarkID
            connectingBookmarkID = nil
            if let activeBookmarkConnectionID {
                bookmarkConnections[activeBookmarkConnectionID]?.backgroundNewsSupported = true
            }
            autoReconnectWorkItem?.cancel()
            autoReconnectWorkItem = nil
            autoReconnectAttempt = 0
            if let connectedBookmarkID,
               serverBookmarks.first(where: { $0.id == connectedBookmarkID })?.autoReconnect == true {
                autoReconnectBookmarkID = connectedBookmarkID
            } else {
                autoReconnectBookmarkID = nil
            }
            reloadBookmarkStack()
            statusLabel.stringValue = L("Connected")
            statusLabel.textColor = .systemGreen
            CarrachoTheme.setPrimaryButtonTitle(connectButton, L("Disconnect"))
            connectButton.isEnabled = true
        case .disconnecting:
            statusLabel.stringValue = L("Disconnecting…")
            statusLabel.textColor = .secondaryLabelColor
            connectButton.isEnabled = false
        case let .failed(message):
            let failedTemporaryBookmarkID = connectingBookmarkID.flatMap { id in
                temporaryServerBookmarkIDs.contains(id) ? id : nil
            }
            connectionSetupBookmarkID = nil
            let reconnectID = autoReconnectBookmarkID ?? connectedBookmarkID ?? connectingBookmarkID
            connectingBookmarkID = nil
            connectedBookmarkID = nil
            resetSessionViews()
            reloadBookmarkStack()
            isAwaitingAgreementAcceptance = false
            deferredInteractiveEvents.removeAll()
            remoteAccountSummaries = []
            remoteAccountListLoading = false
            adminAccountStatusLabel.stringValue = localServerState.accounts.count == 1 ? LF("%@ local account", String(localServerState.accounts.count)) : LF("%@ local accounts", String(localServerState.accounts.count))
            adminAccountTable.reloadData()
            updateAdminSelectionButtons()
            fileTransferClient = nil
            fileSearchClient = nil
            fileSearchResults = nil
            newsClient = nil
            currentNewsIndex = nil
            currentArticle = nil
            currentNewsCategory = nil
            currentNewsThreads = []
            currentNewsThreadID = nil
            currentNewsThreadPosts = []
            currentNewsThreadArticles = []
            clearChatSessions()
            statusLabel.stringValue = L("Error")
            statusLabel.textColor = .systemRed
            CarrachoTheme.setPrimaryButtonTitle(connectButton, L("Connect"))
            connectButton.isEnabled = true
            setInputsEnabled(true)
            if !message.isEmpty { appendLine("\n" + LF("Error: %@", message)) }
            if pendingBookmarkActivationID != nil {
                cancelAutoReconnect()
                activatePendingBookmarkIfPossible()
            } else if let reconnectID,
                      serverBookmarks.first(where: { $0.id == reconnectID })?.autoReconnect == true {
                scheduleAutoReconnect(for: reconnectID)
            } else {
                cancelAutoReconnect()
            }
            if let failedTemporaryBookmarkID {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.temporaryServerBookmarkIDs.contains(failedTemporaryBookmarkID),
                          self.bookmarkConnections[failedTemporaryBookmarkID]?.client.isConnected != true else { return }
                    self.discardTemporaryServerBookmarkAfterDisconnect(failedTemporaryBookmarkID)
                }
            }
        }
        reloadChannelView()
        refreshShellChrome()
        updateTransferMonitorPolling()
    }

    func reloadChannelView(reloadTables: Bool = true, renderTranscript: Bool = true) {
        if reloadTables {
            if channelDiscoverySheet != nil { reloadChannelTablePreservingSelection() }
            channelMemberTable.reloadData()
        }
        let connected = client.isConnected
        if channelDiscoverySheet != nil { updateChannelDiscoverySelection() }
        chatJoinedRoomsLabel.stringValue = LF("%@/%@ joined", String(joinedChannels.count), String(Self.maximumJoinedChannels))
        channelDiscoverButton.isEnabled = connected
        channelNewButton.isEnabled = canJoinChatRooms && joinedChannels.count < Self.maximumJoinedChannels
        channelRoomSwitchButton.isEnabled = connected || !joinedChannels.isEmpty
        channelClearButton.isEnabled = activeChannel.flatMap { joinedChannels[$0.channelID] }?.transcript.isEmpty == false
        channelAttachButton.isHidden = mediaClient == nil
        channelYouTubeButton.isHidden = lastLoginResult?.supportsYouTubeLinks != true

        guard let active = activeChannel else {
            channelTitleLabel.stringValue = L("Choose a chat room")
            channelTitleLabel.toolTip = nil
            chatUsersLabel.stringValue = L("0 participants")
            chatRoomStateLabel.stringValue = joinedChannels.isEmpty ? L("Not in a room") : L("Choose one of your joined rooms")
            chatTopicLabel.stringValue = L("No room selected")
            chatTopicLabel.toolTip = nil
            channelTopicEditButton.isHidden = true
            channelHeaderSettingsButton.isHidden = true
            channelHeaderSettingsButton.isEnabled = false
            channelClearButton.isHidden = true
            channelSettingsButton.isHidden = true
            channelModeButton.isHidden = true
            channelToggleOperatorButton.isHidden = true
            channelToggleSpeakButton.isHidden = true
            channelDeleteButton.isHidden = true
            channelDeleteButton.isEnabled = false
            channelInviteButton.isEnabled = false
            channelLeaveButton.isEnabled = false
            updateChannelComposerPresentation()
            if renderTranscript { renderActiveChannelTranscript() }
            updateInspectorContext()
            reloadJoinedChannelSidebar()
            refreshShellChrome()
            return
        }

        let name = Self.macRomanString(active.name)
        let topic = Self.macRomanString(active.topic)
        channelTitleLabel.stringValue = "#\(name)"
        channelTitleLabel.toolTip = "#\(name)"
        chatTopicLabel.stringValue = topic.isEmpty ? L("No topic") : topic
        chatTopicLabel.toolTip = topic.isEmpty ? nil : topic
        chatUsersLabel.stringValue = channelMembers.count == 1 ? LF("%@ participant", String(channelMembers.count)) : LF("%@ participants", String(channelMembers.count))

        var stateParts: [String] = []
        if isActiveChannelOperator { stateParts.append(L("Operator")) }
        else if ownActiveChannelMode & Self.channelSpeechMode != 0 { stateParts.append(L("Speaker")) }
        else { stateParts.append(L("Member")) }
        if active.flags & Self.channelRestrictedChatFlag != 0 { stateParts.append(L("Restricted chat")) }
        if active.flags & Self.channelRestrictedTopicFlag != 0 { stateParts.append(L("Topic locked")) }
        chatRoomStateLabel.stringValue = stateParts.joined(separator: " · ")

        channelTopicEditButton.isHidden = !connected || !canEditActiveChannelTopic
        channelTopicEditButton.isEnabled = connected && canEditActiveChannelTopic
        channelHeaderSettingsButton.isHidden = !(isActiveChannelOperator || canEditActiveChannelTopic)
        channelHeaderSettingsButton.isEnabled = connected && (isActiveChannelOperator || canEditActiveChannelTopic)
        channelClearButton.isHidden = joinedChannels[active.channelID]?.transcript.isEmpty != false
        channelSettingsButton.isHidden = !(isActiveChannelOperator || canEditActiveChannelTopic)
        channelSettingsButton.isEnabled = connected && (isActiveChannelOperator || canEditActiveChannelTopic)
        let selectedMember = selectedChannelMember
        let canManageSelectedMember = connected && isActiveChannelOperator && selectedMember != nil
        channelModeButton.isHidden = !isActiveChannelOperator
        channelModeButton.isEnabled = canManageSelectedMember
        channelToggleOperatorButton.isHidden = !isActiveChannelOperator
        channelToggleSpeakButton.isHidden = !isActiveChannelOperator
        channelToggleOperatorButton.isEnabled = canManageSelectedMember
        channelToggleSpeakButton.isEnabled = canManageSelectedMember
        updateSelectedChannelMemberModeButtons(member: selectedMember)
        channelInviteButton.isEnabled = connected && liveUsers.keys.contains(where: { channelMembers[$0] == nil })
        let canDeleteActive = connected && isRemoteAdministrator && !isConnectedToClassicServer && active.channelID != 1
        channelDeleteButton.isHidden = !canDeleteActive
        channelDeleteButton.isEnabled = canDeleteActive
        channelLeaveButton.isEnabled = connected

        updateChannelComposerPresentation()
        updateChannelComposerHeight()
        if renderTranscript { renderActiveChannelTranscript() }
        updateInspectorContext()
        reloadJoinedChannelSidebar()
        updateChannelDiscoverySelection()
        refreshShellChrome()
    }

    func channelRoomCell(for channel: LegacyChannelSummary) -> NSView {
        let session = joinedChannels[channel.channelID]
        let active = activeChannel?.channelID == channel.channelID
        let iconView = NSImageView()
        iconView.image = symbolImage(active ? "bubble.left.and.bubble.right.fill" : (session == nil ? "bubble.left.and.bubble.right" : "bubble.left.and.bubble.right.fill"), fallback: NSImage.infoName)
        iconView.contentTintColor = active ? CarrachoTheme.selection : (session == nil ? CarrachoTheme.secondaryText : CarrachoTheme.success)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
        ])
        let title = NSTextField(labelWithString: Self.macRomanString(channel.name))
        title.font = .systemFont(ofSize: 12.5, weight: active ? .semibold : .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var titleViews: [NSView] = [title]
        if channel.isPasswordProtected {
            let lock = NSImageView()
            lock.image = symbolImage("lock.fill", fallback: NSImage.lockLockedTemplateName)
            lock.contentTintColor = CarrachoTheme.secondaryText
            lock.imageScaling = .scaleProportionallyDown
            lock.toolTip = L("Password protected")
            lock.setAccessibilityLabel(L("Password protected"))
            lock.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                lock.widthAnchor.constraint(equalToConstant: 12),
                lock.heightAnchor.constraint(equalToConstant: 12),
            ])
            titleViews.append(lock)
        }
        let titleRow = horizontalStack(titleViews, spacing: 5)
        var detailParts: [String] = []
        if active { detailParts.append(L("Active")) }
        else if session != nil { detailParts.append(L("Joined")) }
        if let unread = session?.unreadCount, unread > 0 { detailParts.append(LF("%@ unread", String(unread))) }
        detailParts.append(channel.memberCount == 1 ? LF("%@ participant", String(channel.memberCount)) : LF("%@ participants", String(channel.memberCount)))
        if channel.isPasswordProtected { detailParts.append(L("Password protected")) }
        if channel.flags & Self.channelRestrictedChatFlag != 0 { detailParts.append(L("Restricted chat")) }
        if channel.flags & Self.channelRestrictedTopicFlag != 0 { detailParts.append(L("Topic restricted")) }
        let detail = infoLabel(detailParts.joined(separator: " · "))
        detail.lineBreakMode = .byTruncatingTail
        let labels = verticalStack([titleRow, detail], spacing: 1)
        return horizontalStack([iconView, labels], spacing: 8)
    }

    func channelMemberCell(for member: LegacyChannelMember) -> NSView {
        let user = liveUsers[member.userID]
        let avatar = NSImageView()
        if let user {
            avatar.image = AvatarArtwork.userImage(picture: user.picture,
                                                    isLegacyTransport: user.isLegacyTransport)
        } else {
            avatar.image = AvatarArtwork.defaultImage()
        }
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = user?.isLegacyTransport == true ? 0 : 15
        avatar.layer?.masksToBounds = user?.isLegacyTransport != true
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 30),
            avatar.heightAnchor.constraint(equalToConstant: 30),
        ])

        let name = NSTextField(labelWithString: user.map { Self.macRomanString($0.nickname) } ?? L("Unknown User"))
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = name.stringValue
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let rgb = userGroupColors[member.userID] { name.textColor = Self.colorFromRGB(rgb) }

        let role: String
        if member.mode & Self.channelOperatorMode != 0 { role = L("Operator") }
        else if member.mode & Self.channelSpeechMode != 0 { role = L("Speaker") }
        else { role = L("Member") }
        let roleLabel = NSTextField(labelWithString: role)
        roleLabel.font = .systemFont(ofSize: 9.5, weight: .semibold)
        roleLabel.textColor = member.mode & Self.channelOperatorMode != 0 ? CarrachoTheme.selection : CarrachoTheme.secondaryText
        roleLabel.setContentHuggingPriority(.required, for: .horizontal)
        roleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let sleeping = sleepingUsers.contains(member.userID) || ((user?.flags ?? 0) & 0x0100) != 0
        let statusText = Self.macRomanString(userStatusMessages[member.userID] ?? Data())
        let status = NSTextField(labelWithString: statusText.isEmpty ? (sleeping ? L("Sleeping") : L("Online")) : statusText)
        status.font = .systemFont(ofSize: 10.5)
        status.textColor = sleeping ? CarrachoTheme.secondaryText : (statusText.isEmpty ? CarrachoTheme.success : CarrachoTheme.secondaryText)
        status.lineBreakMode = .byTruncatingTail
        status.toolTip = status.stringValue
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let nameRow = horizontalStack([name, NSView(), roleLabel], spacing: 6)
        let labels = verticalStack([nameRow, status], spacing: 2)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = horizontalStack([avatar, labels], spacing: 8)
        row.setAccessibilityLabel(LF("%@, %@, %@", name.stringValue, role, status.stringValue))
        return row
    }
}
