import Cocoa
import UniformTypeIdentifiers
import QuickLookUI

private extension LegacyFileLabel {
    static let finderDisplayOrder: [LegacyFileLabel] = [.none, .red, .orange, .yellow, .green, .blue, .purple, .gray]

    var localizedTitle: String {
        switch self {
        case .none: return L("No Label")
        case .red: return L("Red")
        case .orange: return L("Orange")
        case .yellow: return L("Yellow")
        case .green: return L("Green")
        case .blue: return L("Blue")
        case .purple: return L("Purple")
        case .gray: return L("Gray")
        }
    }

    var displayColor: NSColor? {
        switch self {
        case .none: return nil
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .gray: return .systemGray
        }
    }

    func dotImage(size: CGFloat = 11) -> NSImage? {
        guard let color = displayColor else { return nil }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: size - 2, height: size - 2)).fill()
        NSColor.black.withAlphaComponent(0.22).setStroke()
        let outline = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: size - 2, height: size - 2))
        outline.lineWidth = 0.6
        outline.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}


/// File-promise provider used for both Finder downloads and Carracho-internal moves.
///
/// `NSFilePromiseProvider.init(fileType:delegate:)` is an Objective-C convenience initializer.
/// Calling it from a Swift subclass eventually dispatches to the subclass' designated `init()`;
/// without that initializer AppKit traps at runtime. Initialize the designated superclass state
/// first, then assign `fileType` and `delegate` explicitly.
final class CarrachoRemoteFilePromiseProvider: NSFilePromiseProvider {
    private var remotePath = Data()

    override init() {
        super.init()
    }

    init(fileType: String, delegate: NSFilePromiseProviderDelegate, remotePath: Data) {
        self.remotePath = remotePath
        super.init()
        self.fileType = fileType
        self.delegate = delegate
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if !types.contains(ViewController.remoteFileMovePasteboardType) {
            types.append(ViewController.remoteFileMovePasteboardType)
        }
        return types
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType,
                                 pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == ViewController.remoteFileMovePasteboardType { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == ViewController.remoteFileMovePasteboardType { return remotePath }
        return super.pasteboardPropertyList(forType: type)
    }
}

final class FileInfoWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    let nameField = NSTextField(string: "")
    let commentView = NSTextView()
    let folderModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let fileLabelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let validationLabel = NSTextField(labelWithString: "")
    let saveButton = NSButton(title: L("Save"), target: nil, action: nil)

    var onSave: ((String, String, LegacyFolderMode, LegacyFileLabel) -> String?)?
    var onFinish: (() -> Void)?

    private let canRename: Bool
    private let canComment: Bool
    private let canChangeFlags: Bool
    private let supportsLabels: Bool
    private let canLabel: Bool
    private let canSave: Bool
    private var didFinish = false

    init(info: LegacyFileInfoReply,
         isFolder: Bool,
         canRename: Bool,
         canComment: Bool,
         canChangeFlags: Bool,
         supportsLabels: Bool,
         canLabel: Bool) {
        self.canRename = canRename
        self.canComment = canComment
        self.canChangeFlags = canChangeFlags
        self.supportsLabels = supportsLabels
        self.canLabel = canLabel
        self.canSave = canRename || canComment || canChangeFlags || canLabel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: (isFolder ? 350 : 340) + (supportsLabels ? 30 : 0)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = isFolder ? L("Folder Info") : L("File Info")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        buildInterface(in: window, info: info, isFolder: isFolder)
    }

    required init?(coder: NSCoder) { nil }

    private func buildInterface(in window: NSWindow, info: LegacyFileInfoReply, isFolder: Bool) {
        let root = CarrachoBackgroundView()
        root.fillColor = CarrachoTheme.canvas
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let title = NSTextField(labelWithString: isFolder ? L("Folder Info") : L("File Info"))
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = .labelColor

        let path = NSTextField(labelWithString: LegacyPath.displayString(info.path))
        path.font = .systemFont(ofSize: 12.5)
        path.textColor = CarrachoTheme.secondaryText
        path.lineBreakMode = .byTruncatingMiddle
        path.toolTip = LegacyPath.displayString(info.path)

        let editorCard = CarrachoCardView()
        editorCard.fillColor = CarrachoTheme.elevatedCard
        editorCard.cornerRadius = 11

        nameField.stringValue = ViewController.macRomanString(info.name)
        nameField.font = .systemFont(ofSize: 13)
        nameField.controlSize = .regular
        nameField.isEditable = canRename
        nameField.isSelectable = true
        nameField.delegate = self
        nameField.setAccessibilityLabel(L("Name"))
        nameField.toolTip = canRename ? L("Rename this item") : L("Only administrators with rename permission can change the name.")
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.heightAnchor.constraint(equalToConstant: 30).isActive = true
        if !canRename {
            nameField.isBezeled = false
            nameField.drawsBackground = false
        }

        commentView.string = ViewController.macRomanString(info.comment)
        commentView.font = .systemFont(ofSize: 13)
        commentView.isRichText = false
        commentView.allowsUndo = true
        commentView.isEditable = canComment
        commentView.isSelectable = true
        commentView.delegate = self
        commentView.isAutomaticQuoteSubstitutionEnabled = false
        commentView.isAutomaticDashSubstitutionEnabled = false
        commentView.textContainerInset = NSSize(width: 8, height: 7)
        commentView.isVerticallyResizable = true
        commentView.isHorizontallyResizable = false
        commentView.autoresizingMask = [.width]
        commentView.textContainer?.widthTracksTextView = true
        commentView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        commentView.drawsBackground = canComment

        let commentScroll = NSScrollView()
        commentScroll.translatesAutoresizingMaskIntoConstraints = false
        commentScroll.borderType = canComment ? .bezelBorder : .noBorder
        commentScroll.hasVerticalScroller = true
        commentScroll.hasHorizontalScroller = false
        commentScroll.autohidesScrollers = true
        commentScroll.drawsBackground = canComment
        commentScroll.documentView = commentView
        // Roughly three comfortable lines of body text plus the text container insets.
        commentScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let nameGroup = labeledControl(L("Name"), control: nameField)
        let commentGroup = labeledControl(L("Comment"), control: commentScroll)
        let editorStack = NSStackView(views: [nameGroup, commentGroup])
        editorStack.orientation = .vertical
        editorStack.alignment = .leading
        editorStack.spacing = 13
        editorStack.translatesAutoresizingMaskIntoConstraints = false
        editorCard.addSubview(editorStack)
        NSLayoutConstraint.activate([
            editorStack.leadingAnchor.constraint(equalTo: editorCard.leadingAnchor, constant: 16),
            editorStack.trailingAnchor.constraint(equalTo: editorCard.trailingAnchor, constant: -16),
            editorStack.topAnchor.constraint(equalTo: editorCard.topAnchor, constant: 15),
            editorStack.bottomAnchor.constraint(equalTo: editorCard.bottomAnchor, constant: -15),
            // NSStackView otherwise keeps these groups at their intrinsic width, which made the
            // name editor collapse to a tiny field. Both editors should use the card width.
            nameGroup.widthAnchor.constraint(equalTo: editorStack.widthAnchor),
            commentGroup.widthAnchor.constraint(equalTo: editorStack.widthAnchor),
        ])

        let metadataCard = CarrachoCardView()
        metadataCard.fillColor = CarrachoTheme.elevatedCard
        metadataCard.cornerRadius = 11

        var metadataRows: [(String, String)] = []
        if !isFolder {
            metadataRows.append((L("Size"), ByteCountFormatter.string(fromByteCount: Int64(info.metadata.size), countStyle: .file)))
        }
        metadataRows.append((L("Created"), ViewController.macDateString(info.metadata.created)))
        metadataRows.append((L("Modified"), ViewController.macDateString(info.metadata.modified)))

        let metadataStack = NSStackView()
        metadataStack.orientation = .vertical
        metadataStack.alignment = .leading
        metadataStack.spacing = 8
        metadataStack.translatesAutoresizingMaskIntoConstraints = false

        if supportsLabels {
            for label in LegacyFileLabel.finderDisplayOrder {
                fileLabelPopup.addItem(withTitle: label.localizedTitle)
                if let item = fileLabelPopup.lastItem {
                    item.tag = Int(label.rawValue)
                    item.image = label.dotImage()
                }
            }
            fileLabelPopup.selectItem(withTag: Int(info.label.rawValue))
            fileLabelPopup.isEnabled = canLabel
            fileLabelPopup.toolTip = canLabel
                ? L("Use a Finder-style color label for this server item.")
                : L("Changing labels requires permission to edit file comments.")
            let row = metadataControlRow(label: L("Label"), control: fileLabelPopup)
            metadataStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: metadataStack.widthAnchor).isActive = true
        }

        if isFolder {
            folderModePopup.addItems(withTitles: [L("Normal Folder"), L("Upload Folder"), L("Dropbox")])
            folderModePopup.selectItem(at: LegacyFolderMode(flags: info.metadata.flags).rawValue)
            folderModePopup.isEnabled = canChangeFlags
            folderModePopup.toolTip = canChangeFlags
                ? L("Upload Folder accepts uploads; Dropbox also hides contents from users without View Dropboxes.")
                : L("Changing folder mode requires the Change Folder Mode permission.")
            let row = metadataControlRow(label: L("Folder Mode"), control: folderModePopup)
            metadataStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: metadataStack.widthAnchor).isActive = true
        }

        for item in metadataRows {
            let row = metadataValueRow(label: item.0, value: item.1)
            metadataStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: metadataStack.widthAnchor).isActive = true
        }

        metadataCard.addSubview(metadataStack)
        NSLayoutConstraint.activate([
            metadataStack.leadingAnchor.constraint(equalTo: metadataCard.leadingAnchor, constant: 16),
            metadataStack.trailingAnchor.constraint(equalTo: metadataCard.trailingAnchor, constant: -16),
            metadataStack.topAnchor.constraint(equalTo: metadataCard.topAnchor, constant: 14),
            metadataStack.bottomAnchor.constraint(equalTo: metadataCard.bottomAnchor, constant: -14),
        ])

        validationLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        validationLabel.textColor = .systemRed
        validationLabel.maximumNumberOfLines = 2
        validationLabel.lineBreakMode = .byWordWrapping
        validationLabel.isHidden = true
        validationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cancelTitle = canSave ? L("Cancel") : L("Close")
        let cancelButton = NSButton(title: cancelTitle, target: self, action: #selector(cancelPressed(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

        saveButton.target = self
        saveButton.action = #selector(savePressed(_:))
        CarrachoTheme.applyPrimaryButtonStyle(saveButton)
        saveButton.keyEquivalent = "\r"
        saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        saveButton.isHidden = !canSave

        let buttons = NSStackView(views: [validationLabel, NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for view in [title, path, editorCard, metadataCard, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),

            path.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            path.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            path.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),

            editorCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            editorCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            editorCard.topAnchor.constraint(equalTo: path.bottomAnchor, constant: 17),
            editorCard.heightAnchor.constraint(equalToConstant: 184),

            metadataCard.leadingAnchor.constraint(equalTo: editorCard.leadingAnchor),
            metadataCard.trailingAnchor.constraint(equalTo: editorCard.trailingAnchor),
            metadataCard.topAnchor.constraint(equalTo: editorCard.bottomAnchor, constant: 12),
            metadataCard.heightAnchor.constraint(equalToConstant: (isFolder ? 108 : 98) + (supportsLabels ? 30 : 0)),

            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.topAnchor.constraint(equalTo: metadataCard.bottomAnchor, constant: 18),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
    }

    private func labeledControl(_ text: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = CarrachoTheme.secondaryText
        label.setContentHuggingPriority(.required, for: .vertical)
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func metadataValueRow(label: String, value: String) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 12, weight: .semibold)
        labelField.textColor = CarrachoTheme.secondaryText
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        labelField.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let valueField = NSTextField(labelWithString: value)
        valueField.font = .systemFont(ofSize: 12.5)
        valueField.lineBreakMode = .byTruncatingTail
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [labelField, valueField])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func metadataControlRow(label: String, control: NSView) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 12, weight: .semibold)
        labelField.textColor = CarrachoTheme.secondaryText
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        labelField.widthAnchor.constraint(equalToConstant: 96).isActive = true
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [labelField, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    func beginSheet(for parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            if self.canRename { window.makeFirstResponder(self.nameField) }
            else if self.canComment { window.makeFirstResponder(self.commentView) }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        validationLabel.isHidden = true
    }

    func textDidChange(_ notification: Notification) {
        validationLabel.isHidden = true
    }

    @objc private func savePressed(_ sender: Any?) {
        guard canSave else { dismiss(); return }
        let name = nameField.stringValue
        let comment = commentView.string
        let mode = LegacyFolderMode(rawValue: folderModePopup.indexOfSelectedItem) ?? .normal
        let label = supportsLabels
            ? (LegacyFileLabel(rawValue: UInt8(clamping: fileLabelPopup.selectedTag())) ?? .none)
            : .none
        if let error = onSave?(name, comment, mode, label) {
            validationLabel.stringValue = error
            validationLabel.isHidden = false
            NSSound.beep()
            return
        }
        dismiss()
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

// MARK: - Files

extension ViewController {

    /// Shared left edge for the Files table header and root-level row content.
    /// This visually lines the list up with the workspace heading instead of the table border.
    private var filesListLeadingInset: CGFloat { 14 }

    func makeFilesPage() -> NSView {
        let page = CarrachoBackgroundView()
        page.fillColor = CarrachoTheme.card

        // Keep the standalone Files workspace aligned with News and Transfers: one calm
        // section title strip, then the existing shared browser with its own compact toolbar.
        // Overview still mounts the same browser card directly and therefore does not gain a
        // redundant Files heading inside its split pane.
        let title = NSTextField(labelWithString: L("Files"))
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
        standaloneFilesHost.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(topBar)
        page.addSubview(standaloneFilesHost)
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

            standaloneFilesHost.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            standaloneFilesHost.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            standaloneFilesHost.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            standaloneFilesHost.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        return page
    }

    private func styleMacFilesToolbarButton(_ button: NSButton,
                                                title: String? = nil,
                                                image: NSImage?,
                                                help: String,
                                                templateTint: NSColor? = CarrachoTheme.secondaryText,
                                                iconOnly: Bool = false) {
        button.title = title ?? ""
        if let source = image, let displayImage = source.copy() as? NSImage {
            // Match the compact Transfer Monitor controls: the icon supports the label instead of
            // dominating the whole toolbar. Native AppKit artwork is deliberately kept modest here.
            let maximumDimension = max(displayImage.size.width, displayImage.size.height)
            if maximumDimension > 0 {
                let target: CGFloat = iconOnly ? 16 : 14
                let scale = min(1, target / maximumDimension)
                displayImage.size = NSSize(width: displayImage.size.width * scale,
                                           height: displayImage.size.height * scale)
            }
            button.image = displayImage
        } else {
            button.image = image
        }
        button.imagePosition = iconOnly ? .imageOnly : .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.imageHugsTitle = true
        button.controlSize = .small
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 11.5, weight: .medium)
        button.focusRingType = .none
        button.contentTintColor = templateTint
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        if iconOnly {
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 30),
                button.heightAnchor.constraint(equalToConstant: 26),
            ])
        } else {
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
    }


    func makeFilesCard() -> NSView {
        let surface = CarrachoBackgroundView()
        surface.fillColor = CarrachoTheme.card

        // Keep navigation icon-only, but present file actions like the Transfer Monitor: compact
        // inline buttons with a small icon and a readable label. This avoids the oversized blue
        // glyph strip while preserving the native AppKit artwork requested for Files.
        styleMacFilesToolbarButton(fileBackButton, image: NSImage(named: NSImage.Name("Arrow Left")), help: L("Back"), templateTint: nil, iconOnly: true)
        styleMacFilesToolbarButton(fileForwardButton, image: NSImage(named: NSImage.Name("Arrow Right")), help: L("Forward"), templateTint: nil, iconOnly: true)
        styleMacFilesToolbarButton(fileParentButton, image: NSImage(named: NSImage.Name("Arrow Up")), help: L("Go to Parent Folder"), templateTint: nil, iconOnly: true)
        styleMacFilesToolbarButton(fileRefreshButton, image: NSImage(named: NSImage.Name("Refresh")), help: L("Refresh"), templateTint: nil, iconOnly: true)
        styleMacFilesToolbarButton(fileNewFolderButton, title: L("New Folder"), image: NSImage(named: NSImage.Name("Add Folder")), help: L("Create New Folder"), templateTint: nil)
        styleMacFilesToolbarButton(fileUploadButton, title: L("Upload"), image: NSImage(named: NSImage.Name("Upload")), help: L("Upload File or Folder"), templateTint: nil)
        styleMacFilesToolbarButton(fileInfoButton, title: L("Get Info"), image: NSImage(named: NSImage.Name("Get Info")), help: L("Information"), templateTint: nil)
        styleMacFilesToolbarButton(fileQuickViewButton, title: L("Quick View"), image: NSImage(named: NSImage.Name("Quickview")), help: L("Quick View"), templateTint: nil)
        styleMacFilesToolbarButton(fileDownloadButton, title: L("Download"), image: NSImage(named: NSImage.Name("Download")), help: L("Download Selected"), templateTint: nil)
        styleMacFilesToolbarButton(fileDeleteButton, title: L("Delete"), image: NSImage(named: NSImage.Name("Trash")), help: L("Move to Server Trash"), templateTint: nil)

        let breadcrumbIcon = NSImageView(image: NSImage(named: NSImage.Name("Folder")) ?? nativeMacOSFolderImage())
        breadcrumbIcon.imageScaling = .scaleProportionallyDown
        breadcrumbIcon.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        breadcrumbIcon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let breadcrumbs = horizontalStack([breadcrumbIcon, fileBreadcrumbStack], spacing: 5)
        breadcrumbs.setContentHuggingPriority(.defaultLow, for: .horizontal)
        breadcrumbs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        fileSearchField.translatesAutoresizingMaskIntoConstraints = false
        if let searchCell = fileSearchField.cell as? NSSearchFieldCell {
            searchCell.searchButtonCell?.image = sizedAssetImage(named: "Search", size: 14)
        }
        let searchWidth = fileSearchField.widthAnchor.constraint(equalToConstant: 180)
        searchWidth.priority = .defaultHigh
        searchWidth.isActive = true
        let searchMinimum = fileSearchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
        searchMinimum.priority = .defaultHigh
        searchMinimum.isActive = true

        let toolbar = horizontalStack([
            fileBackButton, fileForwardButton, fileParentButton, fileRefreshButton,
            breadcrumbs, NSView(),
            fileNewFolderButton, fileUploadButton, fileDownloadButton, fileInfoButton,
            fileQuickViewButton, fileDeleteButton, filesFontSizePopup, fileSearchField,
        ], spacing: 5)
        toolbar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // On the compact Overview card AppKit may detach lower-priority controls rather than
        // crushing breadcrumbs/search into nonsense. The full Files workspace shows all of them.
        for control in [fileInfoButton, fileQuickViewButton, fileDownloadButton, fileDeleteButton, filesFontSizePopup] {
            toolbar.setVisibilityPriority(.detachOnlyIfNecessary, for: control)
        }

        let tableScrollView = tableScroll(fileTable)
        tableScrollView.hasHorizontalScroller = true
        tableScrollView.drawsBackground = true
        tableScrollView.backgroundColor = CarrachoTheme.conferenceTranscriptBackground
        fileTable.backgroundColor = CarrachoTheme.conferenceTranscriptBackground
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        let listHost = NSView()
        listHost.translatesAutoresizingMaskIntoConstraints = false
        listHost.addSubview(tableScrollView)

        fileLoadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        fileEmptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        fileEmptyStateRetryButton.translatesAutoresizingMaskIntoConstraints = false
        let emptyState = verticalStack([fileLoadingIndicator, fileEmptyStateLabel, fileEmptyStateRetryButton], spacing: 7)
        emptyState.alignment = .centerX
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        listHost.addSubview(emptyState)
        NSLayoutConstraint.activate([
            tableScrollView.leadingAnchor.constraint(equalTo: listHost.leadingAnchor),
            tableScrollView.trailingAnchor.constraint(equalTo: listHost.trailingAnchor),
            tableScrollView.topAnchor.constraint(equalTo: listHost.topAnchor),
            tableScrollView.bottomAnchor.constraint(equalTo: listHost.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: listHost.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: listHost.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: listHost.widthAnchor, multiplier: 0.72),
        ])

        fileStatusLabel.font = .systemFont(ofSize: 11)
        fileStatusLabel.textColor = CarrachoTheme.secondaryText
        fileStatusLabel.lineBreakMode = .byTruncatingTail
        fileTransferLabel.font = .systemFont(ofSize: 11)
        fileTransferLabel.textColor = CarrachoTheme.secondaryText
        fileTransferLabel.lineBreakMode = .byTruncatingTail
        fileTransferLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusRow = horizontalStack([
            fileStatusLabel, fileTransferLabel, NSView(),
        ], spacing: 8)

        let toolbarDivider = CarrachoDividerView()
        let statusDivider = CarrachoDividerView()
        for divider in [toolbarDivider, statusDivider] {
            divider.translatesAutoresizingMaskIntoConstraints = false
            divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }

        for child in [toolbar, toolbarDivider, listHost, statusDivider, statusRow] {
            child.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(child)
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10),
            toolbar.topAnchor.constraint(equalTo: surface.topAnchor, constant: 4),
            toolbar.heightAnchor.constraint(equalToConstant: 34),

            toolbarDivider.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            toolbarDivider.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            toolbarDivider.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4),

            listHost.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            listHost.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            listHost.topAnchor.constraint(equalTo: toolbarDivider.bottomAnchor),
            listHost.bottomAnchor.constraint(equalTo: statusDivider.topAnchor),
            listHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 96),

            statusDivider.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            statusDivider.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            statusDivider.bottomAnchor.constraint(equalTo: statusRow.topAnchor),

            statusRow.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10),
            statusRow.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10),
            statusRow.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -3),
            statusRow.heightAnchor.constraint(equalToConstant: 28),
        ])

        updateFileBrowserPresentation()
        return surface
    }

    func currentFilesSourceKey() -> String {
        if let id = activeBookmarkConnectionID { return "bookmark:\(id.uuidString.lowercased())" }
        return "remote:\(hostField.stringValue.lowercased()):\(portField.stringValue):\(loginField.stringValue.lowercased())"
    }

    /// Folder navigation must always start with a fully visible first row. AppKit can carry the
    /// old clip origin across `reloadData()` and then re-apply it while the table/header layout is
    /// being tiled, which is why row 0 could end up partially (or completely) above the viewport.
    /// Reset the scroll view itself, not merely the row visibility, after forcing that layout.
    private func scrollFileTableToTop() {
        guard let scrollView = fileTable.enclosingScrollView else { return }
        scrollView.layoutSubtreeIfNeeded()
        fileTable.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        let topY: CGFloat
        if fileTable.numberOfRows > 0 {
            topY = fileTable.rect(ofRow: 0).minY
        } else {
            topY = fileTable.bounds.minY
        }
        clipView.setBoundsOrigin(NSPoint(x: 0, y: topY))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// Re-assert the top after the shared Files card reaches its final host size. This is used
    /// only for initial/near-top states; real user scroll positions farther down the list are kept.
    func alignFilesToTopAfterFinalLayout() {
        view.layoutSubtreeIfNeeded()
        scrollFileTableToTop()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            self.scrollFileTableToTop()
        }
    }

    func scheduleOverviewFilesTopAlignmentAfterLayout() {
        guard currentWorkspace == .overview,
              !fileDirectoryLoading, fileSearchResults == nil, lastDirectory != nil else { return }
        pendingFileScrollRestoreY = nil
        fileNeedsOverviewTopAlignmentAfterLayout = true
        view.needsLayout = true
    }

    /// Runs from ViewController.viewDidLayout(), not from reloadData(). This distinction matters
    /// for long Overview lists: NSScrollView only knows its final clip geometry after deciding
    /// that the autohiding vertical scroller is needed. Tiling here prevents that late scroller
    /// pass from resurrecting the previous vertical origin.
    func alignOverviewFilesToTopAfterLayoutIfNeeded() {
        guard fileNeedsOverviewTopAlignmentAfterLayout, currentWorkspace == .overview,
              !fileDirectoryLoading, fileSearchResults == nil, lastDirectory != nil,
              let scrollView = fileTable.enclosingScrollView else { return }

        scrollView.tile()
        scrollView.layoutSubtreeIfNeeded()
        fileTable.layoutSubtreeIfNeeded()
        scrollFileTableToTop()
        fileNeedsOverviewTopAlignmentAfterLayout = false
    }

    func alignInitialFilesWorkspaceToTopIfNeeded() {
        guard fileNeedsInitialWorkspaceTopAlignment,
              currentWorkspace == .files || currentWorkspace == .overview,
              !fileDirectoryLoading, fileSearchResults == nil, lastDirectory != nil else { return }
        fileNeedsInitialWorkspaceTopAlignment = false
        pendingFileScrollRestoreY = nil
        if currentWorkspace == .overview {
            scheduleOverviewFilesTopAlignmentAfterLayout()
        } else {
            alignFilesToTopAfterFinalLayout()
        }
    }

    func reloadFileTablePreservingState() {
        let shouldResetScroll = fileShouldResetScrollOnNextReload
        let preserve = !shouldResetScroll
        let selectedPaths: Set<Data> = preserve ? selectedFilePaths : []
        let clipView = fileTable.enclosingScrollView?.contentView
        let oldOrigin = clipView?.bounds.origin ?? .zero
        let resetPath = shouldResetScroll ? lastDirectory?.currentPath : nil

        // A navigation reset is authoritative. A delayed workspace-state restoration must never
        // win over it and resurrect the old folder's vertical offset.
        if shouldResetScroll { pendingFileScrollRestoreY = nil }

        // NSTableView may ask for numberOfRows/viewFor dozens of times during a single scroll.
        // Build and sort the logical row tree once per model reload, not once per cell callback.
        rebuildVisibleFileRowSnapshot()
        fileTable.reloadData()
        let currentRows = visibleFileRows
        if !selectedPaths.isEmpty {
            let indexes = IndexSet(currentRows.indices.filter { selectedPaths.contains(currentRows[$0].path) })
            if !indexes.isEmpty { fileTable.selectRowIndexes(indexes, byExtendingSelection: false) }
            selectedFilePaths = Set(indexes.map { currentRows[$0].path })
        } else if !preserve {
            fileTable.deselectAll(nil)
            selectedFilePaths.removeAll()
        }
        if shouldResetScroll {
            scrollFileTableToTop()
        } else if let clipView {
            let documentHeight = fileTable.bounds.height
            let viewportHeight = clipView.bounds.height
            let maxY = max(0, documentHeight - viewportHeight)
            if let restoredY = pendingFileScrollRestoreY {
                clipView.scroll(to: NSPoint(x: 0, y: min(max(0, restoredY), maxY)))
                pendingFileScrollRestoreY = nil
            } else {
                clipView.scroll(to: NSPoint(x: oldOrigin.x, y: min(oldOrigin.y, maxY)))
            }
            fileTable.enclosingScrollView?.reflectScrolledClipView(clipView)
        }
        fileShouldResetScrollOnNextReload = false

        if shouldResetScroll {
            // `reloadData()` can trigger one more table/header tiling pass after this method returns.
            // Re-assert the top position on the next run-loop turn, but only for the directory that
            // requested this reset so an older navigation cannot move a newer folder unexpectedly.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.fileDirectoryLoading, self.fileSearchResults == nil,
                      self.lastDirectory?.currentPath == resetPath else { return }
                self.scrollFileTableToTop()
            }
        }
    }

    func updateFileBreadcrumb() {
        for view in fileBreadcrumbStack.arrangedSubviews {
            fileBreadcrumbStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        fileBreadcrumbVisiblePaths.removeAll()
        fileBreadcrumbOverflowPaths.removeAll()

        let path = fileDirectoryLoading ? (filePendingDirectoryPath ?? lastDirectory?.currentPath ?? Data())
                                        : (lastDirectory?.currentPath ?? Data())
        let rootName = lastLoginResult?.filesRootName ?? LegacyFilesRootCapability.defaultDisplayName
        var nodes: [(String, Data)] = [(rootName, Data())]
        var cumulative = Data()
        for part in path.split(separator: LegacyPath.separator, omittingEmptySubsequences: false) where !part.isEmpty {
            let component = Data(part)
            if let next = try? LegacyPath.child(parent: cumulative, name: component) {
                cumulative = next
                nodes.append((CarrachoTextWire.string(from: component), cumulative))
            }
        }

        func addChevron() {
            let label = NSTextField(labelWithString: L("›"))
            label.textColor = CarrachoTheme.secondaryText
            label.font = .systemFont(ofSize: 12, weight: .medium)
            fileBreadcrumbStack.addArrangedSubview(label)
        }
        func addNode(_ node: (String, Data), current: Bool) {
            let button = NSButton(title: node.0, target: self, action: #selector(fileBreadcrumbPressed(_:)))
            button.isBordered = false
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11.5, weight: current ? .semibold : .regular)
            button.contentTintColor = current ? .labelColor : CarrachoTheme.secondaryText
            button.lineBreakMode = .byTruncatingMiddle
            button.toolTip = filesDisplayPath(node.1)
            button.setAccessibilityLabel(current ? LF("Current folder %@", node.0) : LF("Open folder %@", node.0))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            fileBreadcrumbVisiblePaths.append(node.1)
            button.tag = fileBreadcrumbVisiblePaths.count - 1
            button.isEnabled = !current && client.isConnected && !fileDirectoryLoading && fileSearchResults == nil
            fileBreadcrumbStack.addArrangedSubview(button)
        }

        if nodes.count <= 4 {
            for (index, node) in nodes.enumerated() {
                if index > 0 { addChevron() }
                addNode(node, current: index == nodes.count - 1)
            }
        } else {
            addNode(nodes[0], current: false)
            addChevron()
            fileBreadcrumbOverflowPaths = Array(nodes[1..<(nodes.count - 2)])
            let overflow = NSButton(title: L("…"), target: self, action: #selector(showFileBreadcrumbOverflow(_:)))
            overflow.isBordered = false
            overflow.controlSize = .small
            overflow.font = .systemFont(ofSize: 12, weight: .semibold)
            overflow.toolTip = L("Show hidden parent folders")
            overflow.setAccessibilityLabel(L("Show hidden parent folders"))
            overflow.translatesAutoresizingMaskIntoConstraints = false
            overflow.heightAnchor.constraint(equalToConstant: 22).isActive = true
            overflow.isEnabled = client.isConnected && !fileDirectoryLoading && fileSearchResults == nil
            fileBreadcrumbStack.addArrangedSubview(overflow)
            for index in (nodes.count - 2)..<nodes.count {
                addChevron()
                addNode(nodes[index], current: index == nodes.count - 1)
            }
        }
    }

    @objc func fileBreadcrumbPressed(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < fileBreadcrumbVisiblePaths.count else { return }
        let path = fileBreadcrumbVisiblePaths[sender.tag]
        guard path != lastDirectory?.currentPath else { return }
        navigate(to: path)
    }

    @objc func showFileBreadcrumbOverflow(_ sender: NSButton) {
        let menu = NSMenu(title: L("Parent Folders"))
        for (index, node) in fileBreadcrumbOverflowPaths.enumerated() {
            let item = NSMenuItem(title: node.0, action: #selector(fileBreadcrumbOverflowSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc func fileBreadcrumbOverflowSelected(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < fileBreadcrumbOverflowPaths.count else { return }
        navigate(to: fileBreadcrumbOverflowPaths[sender.tag].1)
    }

    func updateFileBrowserPresentation() {
        let connected = client.isConnected
        let rows = visibleFileRows
        let selectedCount = fileTable.selectedRowIndexes.count
        let searching = fileSearchResults != nil || isFileSearchBusy || !fileSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if let results = fileSearchResults {
            fileStatusLabel.stringValue = results.count == 1 ? LF("%@ server-wide search result", String(results.count)) : LF("%@ server-wide search results", String(results.count))
        } else if let directory = lastDirectory {
            let rootCount = directory.entries.count
            var summary = rootCount == 1 ? LF("%@ item in this folder", String(rootCount)) : LF("%@ items in this folder", String(rootCount))
            if rows.count != rootCount { summary += LF(" · %@ rows visible", String(rows.count)) }
            fileStatusLabel.stringValue = summary
        } else {
            fileStatusLabel.stringValue = connected ? L("Files not loaded") : L("Not connected")
        }
        if selectedCount > 0 {
            fileStatusLabel.stringValue += LF(" · %@ selected", String(selectedCount))
        }
        if fileDirectoryLoading { fileStatusLabel.stringValue += L(" · Loading…") }
        else if isFileSearchBusy { fileStatusLabel.stringValue += L(" · Searching server…") }
        else if fileDirectoryError != nil || fileSearchError != nil { fileStatusLabel.stringValue += L(" · Last request failed") }
        fileStatusLabel.toolTip = fileStatusLabel.stringValue

        fileBackButton.isEnabled = connected && !fileDirectoryLoading && (searching || fileNavigationIndex > 0)
        fileForwardButton.isEnabled = connected && !fileDirectoryLoading && !searching && fileNavigationIndex >= 0 && fileNavigationIndex + 1 < fileNavigationHistory.count
        fileRefreshButton.isEnabled = connected && !fileDirectoryLoading && !isFileSearchBusy && (lastDirectory != nil || searching)
        fileParentButton.isEnabled = connected && !fileDirectoryLoading && !isFileSearchBusy && fileSearchResults == nil && lastDirectory?.currentPath.isEmpty == false
        fileSearchField.isEnabled = connected && fileSearchClient != nil && remotePermissionEnabled(LegacyAccountPermissionBit.searchFiles) && !fileDirectoryLoading
        fileSearchField.toolTip = fileSearchField.isEnabled
            ? L("Server-wide recursive filename search. This is not limited to the current folder.")
            : L("File search is unavailable for this account or server connection.")

        let showLoading = (fileDirectoryLoading || isFileSearchBusy) && rows.isEmpty
        let error = fileSearchError ?? fileDirectoryError
        var emptyMessage: String?
        var retryTitle: String?
        if !connected {
            emptyMessage = L("Connect to a server to browse files.")
        } else if showLoading {
            emptyMessage = isFileSearchBusy ? L("Searching the server…") : L("Loading folder…")
        } else if rows.isEmpty, let error {
            emptyMessage = error
            retryTitle = isFileSearchBusy || !fileSearchField.stringValue.isEmpty ? L("Search Again") : L("Retry")
        } else if let results = fileSearchResults, results.isEmpty {
            let query = fileSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            emptyMessage = query.isEmpty ? L("No server-wide search results.") : LF("No server-wide matches for “%@”.", query)
        } else if rows.isEmpty, lastDirectory != nil {
            emptyMessage = L("This folder is empty.")
        } else if rows.isEmpty {
            emptyMessage = L("Files are unavailable.")
            retryTitle = connected ? L("Retry") : nil
        }

        fileEmptyStateLabel.stringValue = emptyMessage ?? ""
        fileEmptyStateLabel.isHidden = emptyMessage == nil
        fileEmptyStateRetryButton.title = retryTitle ?? L("Retry")
        fileEmptyStateRetryButton.isHidden = retryTitle == nil
        fileLoadingIndicator.isHidden = !showLoading
        if showLoading { fileLoadingIndicator.startAnimation(nil) }
        else { fileLoadingIndicator.stopAnimation(nil) }
        updateFileBreadcrumb()
    }

    func populateFileActionMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let selectionCount = selectedVisibleFileRows.count
        let info = NSMenuItem(title: L("Information…"), action: #selector(editSelectedFileInfo(_:)), keyEquivalent: "")
        info.target = self
        info.isEnabled = fileInfoButton.isEnabled
        menu.addItem(info)
        if let entry = selectedVisibleFileRows.count == 1 ? selectedVisibleFileRows[0].entry : nil {
            let renamePermission = entry.isFolder ? LegacyAccountPermissionBit.renameFolders : LegacyAccountPermissionBit.renameFiles
            if remotePermissionEnabled(renamePermission) {
                let rename = NSMenuItem(title: L("Rename / Edit Info…"), action: #selector(editSelectedFileInfo(_:)), keyEquivalent: "")
                rename.target = self
                rename.isEnabled = fileInfoButton.isEnabled
                menu.addItem(rename)
            }
        }
        let preview = NSMenuItem(title: L("Quick View"), action: #selector(quickViewSelectedFile(_:)), keyEquivalent: " ")
        preview.target = self
        preview.isEnabled = fileQuickViewButton.isEnabled
        menu.addItem(preview)
        let download = NSMenuItem(title: selectionCount > 1 ? L("Download Selected…") : L("Download…"), action: #selector(downloadSelectedFile(_:)), keyEquivalent: "")
        download.target = self
        download.isEnabled = fileDownloadButton.isEnabled
        menu.addItem(download)

        if client.transferSession?.usesModernCrypto == true, fileSearchResults == nil, selectionCount > 0 {
            let labelItem = NSMenuItem(title: L("Label"), action: nil, keyEquivalent: "")
            let labelMenu = NSMenu(title: L("Label"))
            let selectedRows = selectedVisibleFileRows
            let selectedLabels = Set(selectedRows.map { $0.entry.label })
            let canChange = selectedRows.allSatisfy { row in
                remotePermissionEnabled(row.entry.isFolder ? LegacyAccountPermissionBit.commentFolders : LegacyAccountPermissionBit.commentFiles)
            }
            for label in LegacyFileLabel.finderDisplayOrder {
                let item = NSMenuItem(title: label.localizedTitle, action: #selector(fileLabelMenuSelected(_:)), keyEquivalent: "")
                item.target = self
                item.tag = Int(label.rawValue)
                item.image = label.dotImage()
                item.state = selectedLabels.count == 1 && selectedLabels.first == label ? .on : .off
                item.isEnabled = canChange
                labelMenu.addItem(item)
            }
            labelItem.submenu = labelMenu
            labelItem.isEnabled = canChange
            menu.addItem(labelItem)
        }
        menu.addItem(.separator())
        let parent = NSMenuItem(title: L("Go to Parent Folder"), action: #selector(goToParentDirectory(_:)), keyEquivalent: "")
        parent.target = self
        parent.isEnabled = client.isConnected && fileSearchResults == nil && lastDirectory?.currentPath.isEmpty == false
        menu.addItem(parent)
        let refresh = NSMenuItem(title: L("Refresh"), action: #selector(refreshFilesPressed(_:)), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = fileRefreshButton.isEnabled
        menu.addItem(refresh)
    }

    func populateUserActionMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        updateUserActionButtons()

        guard selectedUserEntry != nil else {
            let none = NSMenuItem(title: L("No user selected"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }

        let info = NSMenuItem(title: L("Info"), action: #selector(showSelectedUserInfo(_:)), keyEquivalent: "")
        info.target = self
        info.isEnabled = userInfoButton.isEnabled
        menu.addItem(info)

        let message = NSMenuItem(title: L("Message"), action: #selector(messageSelectedUser(_:)), keyEquivalent: "")
        message.target = self
        message.isEnabled = userMessageButton.isEnabled
        menu.addItem(message)

        if !presenceButton.isHidden {
            let sleep = NSMenuItem(title: presenceButton.title, action: #selector(toggleOwnPresence(_:)), keyEquivalent: "")
            sleep.target = self
            sleep.isEnabled = presenceButton.isEnabled
            menu.addItem(sleep)
        }

        menu.addItem(.separator())

        let kick = NSMenuItem(title: L("Kick"), action: #selector(kickSelectedUser(_:)), keyEquivalent: "")
        kick.target = self
        kick.isEnabled = userDisconnectButton.isEnabled
        menu.addItem(kick)

        let ban = NSMenuItem(title: L("Ban"), action: #selector(banSelectedUser(_:)), keyEquivalent: "")
        ban.target = self
        ban.isEnabled = userBanButton.isEnabled
        menu.addItem(ban)
    }

    @objc func fileLabelMenuSelected(_ sender: NSMenuItem) {
        guard client.transferSession?.usesModernCrypto == true,
              let label = LegacyFileLabel(rawValue: UInt8(clamping: sender.tag)) else { return }
        let rows = selectedVisibleFileRows
        guard !rows.isEmpty else { return }

        func apply(_ index: Int) {
            guard index < rows.count else {
                self.reloadFileTablePreservingState()
                return
            }
            let row = rows[index]
            self.client.setFileLabel(path: row.path, label: label) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.applyLoadedFileLabel(label, to: row.path)
                    apply(index + 1)
                case let .failure(error):
                    self.appendLine("\n" + LF("Label could not be changed: %@", Self.displayMessage(for: error)))
                    self.reloadFileTablePreservingState()
                }
            }
        }
        apply(0)
    }

    @discardableResult
    private func applyLoadedFileLabel(_ label: LegacyFileLabel, to path: Data) -> Bool {
        func update(_ listing: inout LegacyDirectoryListing) -> Bool {
            for index in listing.entries.indices {
                guard let entryPath = try? LegacyPath.child(parent: listing.currentPath, name: listing.entries[index].name),
                      entryPath == path else { continue }
                guard listing.entries[index].label != label else { return false }
                listing.entries[index].label = label
                return true
            }
            return false
        }

        var changed = false
        if var root = lastDirectory, update(&root) {
            lastDirectory = root
            changed = true
        }
        for key in Array(expandedDirectoryListings.keys) {
            guard var listing = expandedDirectoryListings[key], update(&listing) else { continue }
            expandedDirectoryListings[key] = listing
            changed = true
        }
        return changed
    }

    func applyRemoteFileLabelChange(path: Data, label: LegacyFileLabel) {
        guard client.transferSession?.usesModernCrypto == true,
              applyLoadedFileLabel(label, to: path) else { return }
        reloadFileTablePreservingState()
        updateFileTransferButtons()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === userContextMenu {
            let clicked = userTable.clickedRow
            if clicked >= 0, clicked < visibleUsers.count {
                if userTable.selectedRow != clicked {
                    userTable.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
                }
                selectedUserID = visibleUsers[clicked].userID
            }
            populateUserActionMenu(menu)
            return
        }

        guard menu === fileContextMenu else { return }
        let clicked = fileTable.clickedRow
        if clicked >= 0, clicked < visibleFileRows.count, !fileTable.selectedRowIndexes.contains(clicked) {
            fileTable.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        updateFileTransferButtons()
        populateFileActionMenu(menu)
    }

    func addFileTextSizeSubmenu(to menu: NSMenu) {
        let textSize = NSMenuItem(title: L("Text Size"), action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu(title: L("Text Size"))
        for size in Self.contentFontSizeOptions {
            let item = NSMenuItem(title: "\(Int(size)) pt", action: #selector(fileFontSizeMenuSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(size)
            item.state = Int(filesFontSize) == Int(size) ? .on : .off
            sizeMenu.addItem(item)
        }
        textSize.submenu = sizeMenu
        menu.addItem(textSize)
    }

    @objc func fileFontSizeMenuSelected(_ sender: NSMenuItem) {
        let size = CGFloat(sender.tag)
        guard Self.contentFontSizeOptions.contains(size) else { return }
        filesFontSize = size
        UserDefaults.standard.set(Double(size), forKey: Self.filesFontSizeDefaultsKey)
        filesFontSizePopup.selectItem(withTag: Int(size))
        applyFilesFontSize()
    }

    @objc func retryFilesPressed(_ sender: Any?) {
        if !fileSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            performRemoteFileSearch()
        } else if lastDirectory != nil {
            refreshCurrentServerDirectory()
        } else if client.isConnected {
            requestFileDirectory(path: Data(), commit: .initialize, resetTree: true, resetScroll: true)
        }
    }

    func commitFileNavigation(_ path: Data, mode: FileNavigationCommit) {
        switch mode {
        case .none:
            break
        case .initialize:
            fileNavigationHistory = [path]
            fileNavigationIndex = 0
        case .push:
            if fileNavigationIndex >= 0, fileNavigationIndex < fileNavigationHistory.count,
               fileNavigationHistory[fileNavigationIndex] == path { return }
            if fileNavigationIndex + 1 < fileNavigationHistory.count {
                fileNavigationHistory.removeSubrange((fileNavigationIndex + 1)..<fileNavigationHistory.count)
            }
            fileNavigationHistory.append(path)
            fileNavigationIndex = fileNavigationHistory.count - 1
        case let .history(index):
            guard index >= 0, index < fileNavigationHistory.count,
                  fileNavigationHistory[index] == path else { return }
            fileNavigationIndex = index
        }
    }

    private func installFileDirectoryListing(_ listing: LegacyDirectoryListing,
                                             requestedPath: Data,
                                             commit: FileNavigationCommit,
                                             resetTree: Bool,
                                             resetScroll: Bool) {
        // The requested path is authoritative. A few Classic-era servers return an empty or
        // parent path in the packed listing even though the entries themselves are correct.
        // Keeping that value would make navigation/history disagree with the exact same folder
        // when it was opened through the inline disclosure triangle.
        var normalized = listing
        normalized.currentPath = requestedPath
        if resetTree { resetInlineFileExpansion() }
        fileDirectoryError = nil
        if fileTransferLabel.stringValue.hasPrefix(L("Could not load")) || fileTransferLabel.stringValue == L("Folder load failed") {
            fileTransferLabel.stringValue = ""
            fileTransferLabel.toolTip = nil
        }
        lastDirectory = normalized
        commitFileNavigation(requestedPath, mode: commit)
        fileShouldResetScrollOnNextReload = resetScroll
        renderSession()
    }

    func requestFileDirectory(path: Data, commit: FileNavigationCommit,
                                      resetTree: Bool, resetScroll: Bool) {
        guard client.isConnected else { return }
        if resetScroll {
            // Do this at navigation start as well as after the new listing arrives. Otherwise the
            // old folder's scroll position remains live during the request and AppKit may carry it
            // into the replacement rows before the normal reload reset gets a chance to run.
            pendingFileScrollRestoreY = nil
            fileShouldResetScrollOnNextReload = true
            scrollFileTableToTop()
        }
        fileDirectoryLoadGeneration &+= 1
        let generation = fileDirectoryLoadGeneration
        let target = client
        let sourceKey = currentFilesSourceKey()
        fileDirectoryLoading = true
        filePendingDirectoryPath = path
        fileDirectoryError = nil
        fileSearchError = nil
        filePathLabel.stringValue = filesDisplayPath(path) + L("  (loading…)")
        updateFileBrowserPresentation()
        target.requestDirectory(pathData: path) { [weak self, weak target] result in
            guard let self, let target, self.client === target,
                  generation == self.fileDirectoryLoadGeneration,
                  sourceKey == self.currentFilesSourceKey() else { return }
            self.fileDirectoryLoading = false
            self.filePendingDirectoryPath = nil
            switch result {
            case let .success(listing):
                self.installFileDirectoryListing(listing, requestedPath: path, commit: commit,
                                                 resetTree: resetTree, resetScroll: resetScroll)
            case let .failure(error):
                self.fileDirectoryError = LF("Could not load this folder: %@", Self.displayMessage(for: error))
                self.fileTransferLabel.stringValue = self.fileDirectoryError ?? L("Folder load failed")
                self.fileTransferLabel.toolTip = self.fileTransferLabel.stringValue
                self.reloadCatalogViews()
                self.appendLine("\n" + LF("Directory could not be loaded: %@", Self.displayMessage(for: error)))
            }
        }
    }

    @objc func goBackInFileHistory(_ sender: Any?) {
        let query = fileSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if fileSearchResults != nil || isFileSearchBusy || !query.isEmpty {
            fileSearchGeneration += 1
            isFileSearchBusy = false
            fileSearchResults = nil
            fileSearchError = nil
            fileSearchField.stringValue = ""
            fileShouldResetScrollOnNextReload = true
            reloadCatalogViews()
            return
        }
        guard fileNavigationIndex > 0 else { return }
        let targetIndex = fileNavigationIndex - 1
        requestFileDirectory(path: fileNavigationHistory[targetIndex], commit: .history(targetIndex), resetTree: true, resetScroll: true)
    }

    @objc func goForwardInFileHistory(_ sender: Any?) {
        guard fileSearchResults == nil, !isFileSearchBusy,
              fileNavigationIndex >= 0, fileNavigationIndex + 1 < fileNavigationHistory.count else { return }
        let targetIndex = fileNavigationIndex + 1
        requestFileDirectory(path: fileNavigationHistory[targetIndex], commit: .history(targetIndex), resetTree: true, resetScroll: true)
    }

    @objc func searchChanged(_ sender: Any?) {
        guard let field = sender as? NSSearchField, field === fileSearchField else { return }
        performRemoteFileSearch()
    }

    func performRemoteFileSearch() {
        let text = fileSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        fileSearchGeneration += 1
        let generation = fileSearchGeneration
        fileSearchError = nil
        if text.isEmpty {
            isFileSearchBusy = false
            fileSearchResults = nil
            fileShouldResetScrollOnNextReload = true
            if fileTransferLabel.stringValue.hasPrefix(L("Search")) { fileTransferLabel.stringValue = "" }
            reloadCatalogViews()
            return
        }
        guard client.isConnected, let searchClient = fileSearchClient else {
            isFileSearchBusy = false
            fileSearchResults = []
            fileSearchError = L("Server-wide file search is unavailable on this connection.")
            reloadCatalogViews()
            return
        }
        guard remotePermissionEnabled(LegacyAccountPermissionBit.searchFiles) else {
            isFileSearchBusy = false
            fileSearchResults = []
            fileSearchError = L("This account does not have permission to search server files.")
            reloadCatalogViews()
            return
        }
        guard let query = text.data(using: .macOSRoman),
              !query.isEmpty, query.count <= LegacyFileSearchQuery.maximumTextLength else {
            isFileSearchBusy = false
            fileSearchResults = []
            fileSearchError = LF("Search text must be MacRoman-compatible and no longer than %@ bytes.", String(LegacyFileSearchQuery.maximumTextLength))
            reloadCatalogViews()
            return
        }

        let target = client
        let sourceKey = currentFilesSourceKey()
        isFileSearchBusy = true
        fileSearchResults = []
        fileShouldResetScrollOnNextReload = true
        fileTransferLabel.stringValue = LF("Search: %@ …", text)
        reloadCatalogViews()
        // Classic Carracho performs normal file searches entirely on transfer operation 9.
        // Control command 0x40 is the separate administrator action “Rebuild Index”. Sending
        // 0x40 here used to rebuild the server index before every search and also made ordinary
        // searches depend on an administration command they do not need.
        searchClient.search(text: query) { [weak self, weak target] result in
            guard let self, let target, self.client === target,
                  generation == self.fileSearchGeneration,
                  sourceKey == self.currentFilesSourceKey() else { return }
            self.isFileSearchBusy = false
            switch result {
            case let .success(results):
                self.fileSearchResults = results
                self.fileSearchError = nil
                self.fileTransferLabel.stringValue = results.count == 1 ? LF("Search: %@ result", String(results.count)) : LF("Search: %@ results", String(results.count))
                self.fileTransferLabel.toolTip = nil
            case let .failure(error):
                self.fileSearchResults = []
                self.fileSearchError = LF("Search failed: %@", Self.displayMessage(for: error))
                self.fileTransferLabel.stringValue = self.fileSearchError ?? L("Search failed")
                self.fileTransferLabel.toolTip = self.fileTransferLabel.stringValue
                self.appendLine("\n" + LF("File search failed: %@", Self.displayMessage(for: error)))
            }
            self.reloadCatalogViews()
        }
    }

    @objc func openSelectedFileEntry(_ sender: Any?) {
        let row = fileTable.clickedRow >= 0 ? fileTable.clickedRow : fileTable.selectedRow
        guard row >= 0, row < visibleFileRows.count else { return }
        let item = visibleFileRows[row]
        if item.entry.isFolder {
            guard !item.path.isEmpty else { return }
            fileSearchField.stringValue = ""
            fileSearchResults = nil
            fileSearchGeneration += 1
            navigate(to: item.path)
        } else {
            downloadFileRows([item])
        }
    }

    func resetInlineFileExpansion() {
        fileExpansionGeneration += 1
        expandedFilePaths.removeAll()
        expandedDirectoryListings.removeAll()
        loadingExpandedFilePaths.removeAll()
    }

    @objc func toggleFileDisclosure(_ sender: NSButton) {
        guard fileSearchResults == nil else { return }
        let row = sender.tag
        guard row >= 0, row < visibleFileRows.count else { return }
        let item = visibleFileRows[row]
        guard item.entry.isFolder else { return }

        if expandedFilePaths.contains(item.path) {
            expandedFilePaths.remove(item.path)
            reloadFileTablePreservingState()
            updateFileTransferButtons()
            return
        }

        expandedFilePaths.insert(item.path)
        reloadFileTablePreservingState()
        updateFileTransferButtons()
        guard expandedDirectoryListings[item.path] == nil,
              !loadingExpandedFilePaths.contains(item.path) else { return }

        loadingExpandedFilePaths.insert(item.path)
        let generation = fileExpansionGeneration
        let requestedPath = item.path
        client.requestDirectory(pathData: requestedPath) { [weak self] result in
            guard let self, generation == self.fileExpansionGeneration else { return }
            self.loadingExpandedFilePaths.remove(requestedPath)
            switch result {
            case let .success(listing):
                var normalized = listing
                normalized.currentPath = requestedPath
                self.expandedDirectoryListings[requestedPath] = normalized
                self.reloadFileTablePreservingState()
                self.updateFileTransferButtons()
            case let .failure(error):
                self.expandedFilePaths.remove(requestedPath)
                self.reloadFileTablePreservingState()
                self.updateFileTransferButtons()
                self.appendLine("\n" + LF("Folder could not be expanded: %@", Self.displayMessage(for: error)))
            }
        }
    }

    func nativeMacOSFolderImage() -> NSImage {
        if let cached = filesFolderIconCache { return cached }
        let systemImage = NSWorkspace.shared.icon(forFileType: "public.folder")
        let image = (systemImage.copy() as? NSImage) ?? systemImage
        image.isTemplate = false
        filesFolderIconCache = image
        return image
    }

    func nativeMacOSFolderIconView(size: CGFloat, badgeSymbol: String? = nil, toolTip: String? = nil) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: size).isActive = true
        container.heightAnchor.constraint(equalToConstant: size).isActive = true
        container.toolTip = toolTip

        let folder = NSImageView(image: nativeMacOSFolderImage())
        folder.imageScaling = .scaleProportionallyUpOrDown
        folder.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(folder)
        NSLayoutConstraint.activate([
            folder.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            folder.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            folder.topAnchor.constraint(equalTo: container.topAnchor),
            folder.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        if let badgeSymbol {
            // Folder badges need to remain legible at the small row icon size. Put the symbol on
            // a dark, outlined disc instead of drawing white directly on top of the blue folder.
            let badgeSize = max(11, size * 0.78)
            let badgeBackground = NSView()
            badgeBackground.wantsLayer = true
            badgeBackground.translatesAutoresizingMaskIntoConstraints = false
            badgeBackground.layer?.backgroundColor = CarrachoTheme.canvas.withAlphaComponent(0.96).cgColor
            badgeBackground.layer?.borderWidth = 1
            badgeBackground.layer?.borderColor = NSColor.white.withAlphaComponent(0.88).cgColor
            badgeBackground.layer?.cornerRadius = badgeSize / 2
            container.addSubview(badgeBackground)

            let badge = NSImageView()
            badge.image = symbolImage(badgeSymbol, fallback: NSImage.actionTemplateName)
            if #available(macOS 11.0, *), let image = badge.image {
                badge.image = image.withSymbolConfiguration(.init(pointSize: badgeSize * 0.68, weight: .semibold)) ?? image
            }
            badge.imageScaling = .scaleProportionallyUpOrDown
            badge.contentTintColor = .white
            badge.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(badge)

            NSLayoutConstraint.activate([
                badgeBackground.widthAnchor.constraint(equalToConstant: badgeSize),
                badgeBackground.heightAnchor.constraint(equalToConstant: badgeSize),
                badgeBackground.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 2),
                badgeBackground.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: 2),

                badge.centerXAnchor.constraint(equalTo: badgeBackground.centerXAnchor),
                badge.centerYAnchor.constraint(equalTo: badgeBackground.centerYAnchor),
                badge.widthAnchor.constraint(equalToConstant: badgeSize * 0.70),
                badge.heightAnchor.constraint(equalToConstant: badgeSize * 0.70),
            ])
        }
        return container
    }

    func genericSystemDocumentImage() -> NSImage {
        if let cached = filesGenericDocumentIconCache { return cached }
        let systemImage: NSImage
        if #available(macOS 12.0, *) {
            systemImage = NSWorkspace.shared.icon(for: .data)
        } else {
            systemImage = NSWorkspace.shared.icon(forFileType: "public.data")
        }
        let image = (systemImage.copy() as? NSImage) ?? systemImage
        image.isTemplate = false
        filesGenericDocumentIconCache = image
        return image
    }

    private func systemFileTypeImage(forExtension fileExtension: String) -> NSImage? {
        let cacheKey = fileExtension.lowercased()
        if let cached = filesSystemFileTypeIconCache[cacheKey] { return cached }
        if filesSystemFileTypeIconMisses.contains(cacheKey) { return nil }

        let systemImage: NSImage
        if #available(macOS 12.0, *), let type = UTType(filenameExtension: cacheKey) {
            systemImage = NSWorkspace.shared.icon(for: type)
        } else {
            systemImage = NSWorkspace.shared.icon(forFileType: cacheKey)
        }
        let genericImage = genericSystemDocumentImage()

        // NSWorkspace also returns a generic document for unknown/unregistered extensions.
        // Treat that as "no system-specific icon" so Carracho's Generic-<ext> asset gets its turn.
        if let systemData = systemImage.tiffRepresentation,
           let genericData = genericImage.tiffRepresentation,
           systemData == genericData {
            filesSystemFileTypeIconMisses.insert(cacheKey)
            return nil
        }
        let image = (systemImage.copy() as? NSImage) ?? systemImage
        image.isTemplate = false
        filesSystemFileTypeIconCache[cacheKey] = image
        return image
    }

    func fileTypeImage(for entry: LegacyDirectoryEntry) -> NSImage {
        let name = Self.macRomanString(entry.name)
        let lowerName = name.lowercased()
        if lowerName.hasSuffix(".carracho") || lowerName.hasPrefix(".carracho.") {
            if let cached = filesIncompleteIconCache { return cached }
            let source = Bundle.main.image(forResource: NSImage.Name("Incomplete"))
                ?? NSImage(named: NSImage.Name("Incomplete"))
            if let source {
                let image = (source.copy() as? NSImage) ?? source
                image.isTemplate = false
                filesIncompleteIconCache = image
                return image
            }
        }
        let parts = name.split(separator: ".", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return genericSystemDocumentImage() }

        // Most-specific suffix first. System/LaunchServices artwork always wins over Carracho
        // assets, then Generic-<extension> assets are tried, then the plain macOS document icon.
        let suffixes = (1..<parts.count).map { parts[$0...].joined(separator: ".").lowercased() }
        for suffix in suffixes {
            if let image = systemFileTypeImage(forExtension: suffix) { return image }
        }
        for suffix in suffixes {
            let assetName = "Generic-\(suffix)"
            // Resolve through the app bundle explicitly. This is important for images that live
            // only in Assets.car (for example Generic-iso) and avoids NSImage's global named-image
            // cache deciding that an unrelated system image with the same lookup path is enough.
            let source = Bundle.main.image(forResource: NSImage.Name(assetName))
                ?? NSImage(named: NSImage.Name(assetName))
            if let source, let image = source.copy() as? NSImage {
                image.isTemplate = false
                return image
            }
        }
        return genericSystemDocumentImage()
    }

    func fileNameCell(for item: VisibleFileRow, row: Int) -> NSView {
        var views: [NSView] = []
        if item.depth > 0 {
            let indentation = NSView()
            indentation.translatesAutoresizingMaskIntoConstraints = false
            indentation.widthAnchor.constraint(equalToConstant: CGFloat(item.depth) * 16).isActive = true
            views.append(indentation)
        }

        if item.entry.isFolder && fileSearchResults == nil {
            let disclosure = NSButton()
            disclosure.isBordered = false
            disclosure.imagePosition = .imageOnly
            disclosure.focusRingType = .none
            disclosure.translatesAutoresizingMaskIntoConstraints = false
            disclosure.widthAnchor.constraint(equalToConstant: 12).isActive = true
            disclosure.heightAnchor.constraint(equalToConstant: 14).isActive = true
            let expanded = expandedFilePaths.contains(item.path)
            let fallback = expanded ? NSImage.touchBarGoDownTemplateName : NSImage.rightFacingTriangleTemplateName
            disclosure.image = symbolImage(expanded ? "chevron.down" : "chevron.right", fallback: fallback)
            disclosure.contentTintColor = CarrachoTheme.secondaryText
            disclosure.target = self
            disclosure.action = #selector(toggleFileDisclosure(_:))
            disclosure.tag = row
            disclosure.toolTip = expanded ? L("Collapse folder") : L("Expand folder")
            disclosure.setAccessibilityLabel(expanded ? L("Collapse folder") : L("Expand folder"))
            views.append(disclosure)
        }

        // Keep file/folder artwork proportional to the configurable Files font size while
        // leaving a little less vertical air in the compact browser rows.
        let iconSize = 15 * (filesFontSize / 13)
        if item.entry.isDropBox {
            views.append(nativeMacOSFolderIconView(
                size: iconSize, badgeSymbol: "tray.and.arrow.down.fill",
                toolTip: L("Dropbox · accepts uploads and hides contents without View Dropboxes permission")
            ))
        } else if item.entry.isUploadFolder {
            views.append(nativeMacOSFolderIconView(
                size: iconSize, badgeSymbol: "arrow.up.circle.fill",
                toolTip: L("Upload Folder · accepts uploads from users with Can Upload permission")
            ))
        } else if item.entry.isFolder {
            // Finder-style folder artwork follows the current macOS appearance automatically.
            views.append(nativeMacOSFolderIconView(size: iconSize))
        } else {
            let iconView = NSImageView()
            if item.entry.isSymbolicLink {
                iconView.image = symbolImage("link", fallback: NSImage.networkName)
                if #available(macOS 11.0, *), let image = iconView.image {
                    iconView.image = image.withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular)) ?? image
                }
                iconView.contentTintColor = CarrachoTheme.selection
            } else {
                // Asset convention: Generic-<extension>, e.g. Generic-7z. If no matching
                // asset exists, deliberately fall back to Finder's plain generic document.
                iconView.image = fileTypeImage(for: item.entry)
            }
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.widthAnchor.constraint(equalToConstant: iconSize).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: iconSize).isActive = true
            views.append(iconView)
        }

        let displayName = Self.macRomanString(item.entry.name)
        let title = NSTextField(labelWithString: displayName)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.font = NSFont.systemFont(ofSize: filesFontSize, weight: .regular)
        title.toolTip = displayName
        views.append(title)

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        return verticallyCenteredTableContent(stack, leadingInset: filesListLeadingInset)
    }

    static func isReservedAnonymousNickname(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("anonymous") == .orderedSame
    }

    func loadGeneralClientPreferences() {
        if let nickname = generalNickname { nicknameField.stringValue = nickname }
    }

    func effectiveNickname(for bookmark: ServerBookmark) -> String {
        let override = bookmark.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty, !Self.isReservedAnonymousNickname(override) { return override }
        return generalNickname ?? ""
    }

    func effectiveStatusMessage(for bookmark: ServerBookmark) -> String {
        let override = bookmark.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? (generalStatusMessage ?? "") : override
    }

    func avatarStorageIdentity(for connectionIdentity: LocalAvatarIdentity) -> LocalAvatarIdentity {
        generalIdentityConfigured ? Self.globalAvatarIdentity : connectionIdentity
    }

    func settingsAvatarInitialData() -> Data {
        if let state = try? localAvatarStore.state(for: Self.globalAvatarIdentity) {
            if case let .avatar(data) = state { return data }
            if case .none = state { return Data() }
        }
        if let activeAvatarIdentity,
           let state = try? localAvatarStore.state(for: activeAvatarIdentity),
           case let .avatar(data) = state {
            return data
        }
        return Data()
    }

    @objc func menuSettings(_ sender: Any?) {
        presentClientSettings()
    }

    func refreshClientSettingsDownloadFolderLabel() {
        guard let field = clientSettingsDownloadFolderField else { return }
        guard let path = clientSettingsPendingDownloadFolderPath, !path.isEmpty else {
            field.stringValue = L("Ask every time")
            field.textColor = CarrachoTheme.secondaryText
            return
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            field.stringValue = path
            field.textColor = .labelColor
        } else {
            field.stringValue = LF("Missing: %@", path)
            field.textColor = CarrachoTheme.warning
        }
    }

    @objc func settingsChooseDownloadFolder(_ sender: Any?) {
        guard let settingsWindow = clientSettingsWindow else { return }
        let panel = NSOpenPanel()
        panel.title = L("Choose Download Folder")
        panel.prompt = L("Use for Downloads")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let path = clientSettingsPendingDownloadFolderPath, !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            panel.directoryURL = configuredDownloadFolderURL
        }
        panel.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.clientSettingsPendingDownloadFolderPath = url.standardizedFileURL.path
            self.refreshClientSettingsDownloadFolderLabel()
        }
    }

    @objc func settingsAskEveryTime(_ sender: Any?) {
        clientSettingsPendingDownloadFolderPath = nil
        refreshClientSettingsDownloadFolderLabel()
    }

    @objc func settingsSave(_ sender: Any?) {
        // Sounds are independent client preferences. A user who has never configured the global
        // identity can still change only the Sounds tab without being forced through nickname
        // validation. Once Allgemein was visited (or identity setup is required), keep the existing
        // identity/download validation and persistence behavior.
        let shouldPersistGeneral = generalIdentityConfigured || clientSettingsGeneralWasVisited || resumeConnectionAfterIdentitySetup
        if !shouldPersistGeneral {
            saveClientSoundPreferencesFromSettings()
            closeClientSettingsWindow()
            return
        }

        guard let nicknameField = clientSettingsNicknameField,
              let statusField = clientSettingsStatusField,
              let emailField = clientSettingsEmailField,
              let aboutView = clientSettingsAboutView,
              let avatarView = clientSettingsAvatarView else { return }
        let nickname = nicknameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = statusField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let aboutMe = aboutView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.isReservedAnonymousNickname(nickname) else {
            showError(L("‘anonymous’ is reserved for the guest login. Choose a different nickname."))
            return
        }
        guard let nicknameData = nickname.data(using: .macOSRoman), !nicknameData.isEmpty, nicknameData.count <= 64 else {
            showError(L("Nickname is required, must be MacRoman-compatible, and may contain at most 64 bytes."))
            return
        }
        guard let statusData = status.data(using: .macOSRoman), statusData.count <= 255 else {
            showError(L("Status must be MacRoman-compatible and at most 255 bytes."))
            return
        }
        guard let emailData = email.data(using: .macOSRoman), emailData.count <= 64 else {
            showError(L("Email must be MacRoman-compatible and at most 64 bytes."))
            return
        }
        guard let aboutMeData = aboutMe.data(using: .macOSRoman), aboutMeData.count <= 128 else {
            showError(L("About Me must be MacRoman-compatible and at most 128 bytes."))
            return
        }
        do {
            try localAvatarStore.save(avatarView.avatarData, for: Self.globalAvatarIdentity)
        } catch {
            showError(LF("Avatar could not be saved: %@", Self.displayMessage(for: error)))
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Self.generalIdentityConfiguredDefaultsKey)
        defaults.set(nickname, forKey: Self.generalNicknameDefaultsKey)
        defaults.set(status, forKey: Self.generalStatusDefaultsKey)
        defaults.set(email, forKey: Self.generalEmailDefaultsKey)
        defaults.set(aboutMe, forKey: Self.generalAboutMeDefaultsKey)
        if let path = clientSettingsPendingDownloadFolderPath, !path.isEmpty {
            defaults.set(path, forKey: Self.downloadFolderDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.downloadFolderDefaultsKey)
        }
        if let activeBookmarkConnectionID,
           let bookmark = serverBookmarks.first(where: { $0.id == activeBookmarkConnectionID }) {
            self.nicknameField.stringValue = effectiveNickname(for: bookmark)
        } else {
            self.nicknameField.stringValue = nickname
        }
        applyGeneralIdentityToConnectedSessions(nickname: nicknameData, status: statusData,
                                                email: emailData, aboutMe: aboutMeData, avatar: avatarView.avatarData)
        saveClientSoundPreferencesFromSettings()
        let shouldResumeConnection = resumeConnectionAfterIdentitySetup
        let bookmarkIDToResume = resumeConnectionBookmarkID
        resumeConnectionAfterIdentitySetup = false
        resumeConnectionBookmarkID = nil
        closeClientSettingsWindow()
        if shouldResumeConnection {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let bookmarkIDToResume, self.serverBookmarks.contains(where: { $0.id == bookmarkIDToResume }) {
                    self.connectingBookmarkID = bookmarkIDToResume
                    self.reloadBookmarkStack()
                }
                self.connectPressed(nil)
            }
        }
    }

    @objc func settingsCancel(_ sender: Any?) {
        let pendingBookmarkID = resumeConnectionBookmarkID
        resumeConnectionAfterIdentitySetup = false
        resumeConnectionBookmarkID = nil
        clearBookmarkConnectingIndicatorAfterRejectedAttempt()
        if let pendingBookmarkID, temporaryServerBookmarkIDs.contains(pendingBookmarkID) {
            discardTemporaryServerBookmarkAfterDisconnect(pendingBookmarkID)
        }
        closeClientSettingsWindow()
    }

    func closeClientSettingsWindow() {
        clientSoundPreferences.stopPreview()
        clientSettingsWindow?.close()
        clientSettingsWindow = nil
        clientSettingsTabControl = nil
        clientSettingsGeneralView = nil
        clientSettingsSoundsView = nil
        clientSettingsRestoreDefaultsButton = nil
        clientSettingsSoundsEnabledCheckbox = nil
        clientSettingsVolumeSlider = nil
        clientSettingsVolumeLabel = nil
        clientSettingsSoundPopups.removeAll()
        clientSettingsSoundPreviewButtons.removeAll()
        clientSettingsNotificationCheckboxes.removeAll()
        clientSettingsGeneralWasVisited = false
        clientSettingsNicknameField = nil
        clientSettingsStatusField = nil
        clientSettingsEmailField = nil
        clientSettingsAboutView = nil
        clientSettingsDownloadFolderField = nil
        clientSettingsAvatarView = nil
        clientSettingsPendingDownloadFolderPath = nil
    }

    func synchronizeGeneralProfileFields(email: Data, aboutMe: Data, to target: LegacyControlClient,
                                                        ownUserID: UInt32?, logErrors: Bool) {
        guard target.isConnected, let ownUserID else { return }
        // Classic saves name/eMail/About Me together. The account name remains server-managed;
        // eMail and About Me are deliberately client-global and therefore replace the server
        // values even when either global field is empty.
        target.requestUserInfo(userID: ownUserID) { [weak self, weak target] result in
            guard let self, let target, target.isConnected else { return }
            guard case let .success(info) = result else {
                if logErrors, case let .failure(error) = result {
                    self.appendLine("\n" + LF("Profile fields could not be loaded before synchronization: %@", Self.displayMessage(for: error)))
                }
                return
            }
            target.updateOwnUserInfo(name: info.name, email: email, aboutMe: aboutMe) { [weak self] updateResult in
                if logErrors, case let .failure(error) = updateResult {
                    self?.appendLine("\n" + LF("eMail/About Me could not be synchronized: %@", Self.displayMessage(for: error)))
                }
            }
        }
    }

    func applyGeneralIdentityToConnectedSessions(nickname: Data, status: Data, email: Data,
                                                          aboutMe: Data, avatar: Data) {
        func apply(to target: LegacyControlClient, ownUserID: UInt32?, active: Bool,
                   context: BookmarkConnectionContext?, bookmark: ServerBookmark?) {
            guard target.isConnected else { return }
            let effectiveNicknameData: Data = bookmark.flatMap {
                effectiveNickname(for: $0).data(using: .macOSRoman)
            }.flatMap { $0.isEmpty || $0.count > 64 ? nil : $0 } ?? nickname
            let effectiveStatusData: Data = bookmark.flatMap {
                effectiveStatusMessage(for: $0).data(using: .macOSRoman)
            }.flatMap { $0.count > 255 ? nil : $0 } ?? status

            target.updateUser(nickname: effectiveNicknameData, picture: avatar) { [weak self] result in
                if case let .failure(error) = result {
                    self?.appendLine("\n" + LF("General profile could not be synchronized: %@", Self.displayMessage(for: error)))
                }
            }
            target.updateStatusMessage(effectiveStatusData) { [weak self] result in
                if case let .failure(error) = result {
                    self?.appendLine("\n" + LF("Status could not be synchronized: %@", Self.displayMessage(for: error)))
                }
            }
            synchronizeGeneralProfileFields(email: email, aboutMe: aboutMe, to: target,
                                            ownUserID: ownUserID, logErrors: true)
            guard let ownUserID else { return }
            if active {
                if var user = liveUsers[ownUserID] {
                    user.nickname = effectiveNicknameData
                    user.picture = avatar
                    liveUsers[ownUserID] = user
                }
                userStatusMessages[ownUserID] = effectiveStatusData
            } else if let context, var snapshot = context.snapshot {
                if var user = snapshot.liveUsers[ownUserID] {
                    user.nickname = effectiveNicknameData
                    user.picture = avatar
                    snapshot.liveUsers[ownUserID] = user
                }
                snapshot.userStatusMessages[ownUserID] = effectiveStatusData
                context.snapshot = snapshot
            }
        }

        if activeBookmarkConnectionID == nil {
            apply(to: client, ownUserID: lastLoginResult?.session.userID, active: true,
                  context: nil, bookmark: nil)
        }
        for bookmark in serverBookmarks {
            let isActive = activeBookmarkConnectionID == bookmark.id
            let context = bookmarkConnections[bookmark.id]
            let target = isActive ? client : context?.client
            let ownUserID = isActive ? lastLoginResult?.session.userID : context?.snapshot?.lastLoginResult?.session.userID
            if let target {
                apply(to: target, ownUserID: ownUserID, active: isActive, context: context, bookmark: bookmark)
            }
        }
        renderSession()
        reloadBookmarkStack()
    }

    @objc func downloadSelectedFile(_ sender: Any?) {
        let items = selectedVisibleFileRows
        guard !items.isEmpty else { return }
        downloadFileRows(items)
    }

    func downloadFileRows(_ items: [VisibleFileRow]) {
        guard client.isConnected, fileTransferClient != nil,
              remotePermissionEnabled(LegacyAccountPermissionBit.download),
              !items.isEmpty else { return }

        if let folder = configuredDownloadFolderURL {
            enqueueDownloadRows(items, into: folder)
            return
        }

        guard let window = view.window else { return }
        if items.count > 1 {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = L("Choose")
            panel.message = LF("Choose a destination folder for %@ selected items", String(items.count))
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .OK, let parentURL = panel.url else { return }
                self.enqueueDownloadRows(items, into: parentURL)
            }
            return
        }

        let item = items[0]
        let entry = item.entry
        let remotePath = item.path
        let displayName = Self.macRomanString(entry.name)
        let remoteDisplay = LegacyPath.displayString(remotePath)
        if entry.isFolder {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = L("Choose")
            panel.message = LF("Choose a destination folder for %@", displayName)
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .OK, let parentURL = panel.url else { return }
                let finalFolder = parentURL.appendingPathComponent(displayName, isDirectory: true)
                guard !FileManager.default.fileExists(atPath: finalFolder.path) else {
                    self.showError(LF("A folder named %@ already exists in the selected destination.", displayName))
                    return
                }
                self.startDownload(remotePath: remotePath, displayName: displayName, remoteDisplay: remoteDisplay,
                                   operation: .downloadDirectory(remotePath: remotePath, parentDirectory: parentURL))
            }
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = displayName
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .OK, let url = panel.url else { return }
                self.startDownload(remotePath: remotePath, displayName: displayName, remoteDisplay: remoteDisplay,
                                   operation: .download(remotePath: remotePath, destination: url))
            }
        }
    }

    func enqueueDownloadRows(_ items: [VisibleFileRow], into folder: URL) {
        var plans: [(VisibleFileRow, String, ClientTransferOperation)] = []
        var reservedPaths = Set<String>()
        for item in items {
            let displayName = Self.macRomanString(item.entry.name)
            guard !displayName.isEmpty else { continue }
            if item.entry.isFolder {
                let finalFolder = folder.appendingPathComponent(displayName, isDirectory: true)
                let key = finalFolder.standardizedFileURL.path
                guard !FileManager.default.fileExists(atPath: finalFolder.path), !reservedPaths.contains(key) else {
                    showError(LF("A folder named %@ already exists in the selected download folder.", displayName))
                    return
                }
                reservedPaths.insert(key)
                plans.append((item, displayName, .downloadDirectory(remotePath: item.path, parentDirectory: folder)))
            } else {
                let destination = availableDownloadDestination(in: folder, preferredName: displayName, reservedPaths: &reservedPaths)
                plans.append((item, displayName, .download(remotePath: item.path, destination: destination)))
            }
        }
        for (item, displayName, operation) in plans {
            startDownload(remotePath: item.path,
                          displayName: displayName,
                          remoteDisplay: LegacyPath.displayString(item.path),
                          operation: operation)
        }
    }

    func availableDownloadDestination(in folder: URL, preferredName: String) -> URL {
        var reserved = Set<String>()
        return availableDownloadDestination(in: folder, preferredName: preferredName, reservedPaths: &reserved)
    }

    func availableDownloadDestination(in folder: URL, preferredName: String,
                                              reservedPaths: inout Set<String>) -> URL {
        func available(_ candidate: URL) -> Bool {
            let key = candidate.standardizedFileURL.path
            let partial = folder.appendingPathComponent("\(candidate.lastPathComponent).carracho", isDirectory: false)
            return !reservedPaths.contains(key) &&
                !FileManager.default.fileExists(atPath: candidate.path) &&
                !FileManager.default.fileExists(atPath: partial.path)
        }
        let direct = folder.appendingPathComponent(preferredName, isDirectory: false)
        if available(direct) {
            reservedPaths.insert(direct.standardizedFileURL.path)
            return direct
        }
        let nsName = preferredName as NSString
        let stem = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        for index in 2...9999 {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName, isDirectory: false)
            if available(candidate) {
                reservedPaths.insert(candidate.standardizedFileURL.path)
                return candidate
            }
        }
        let fallback = folder.appendingPathComponent("\(UUID().uuidString)-\(preferredName)", isDirectory: false)
        reservedPaths.insert(fallback.standardizedFileURL.path)
        return fallback
    }

    func startDownload(remotePath: Data, displayName: String, remoteDisplay: String,
                               operation: ClientTransferOperation) {
        let destination: String
        switch operation {
        case let .download(_, url): destination = url.path
        case let .downloadDirectory(_, parent): destination = parent.path
        case .upload: return
        }
        guard beginClientTransfer(kind: LegacyTransferKind.download,
                                  name: displayName,
                                  detail: "\(remoteDisplay) → \(destination)",
                                  operation: operation) != nil else { return }
        fileTransferLabel.stringValue = LF("Download queued: %@", displayName)
        scheduleClientTransferQueue(refreshCapacity: true)
    }

    func updateFileTransferButtons() {
        let connected = client.isConnected
        let selection = selectedVisibleFileRows
        let selectedEntry = selection.count == 1 ? selection[0].entry : nil
        let available = !isFileSearchBusy && !fileDirectoryLoading
        let canDownload = remotePermissionEnabled(LegacyAccountPermissionBit.download)
        let canUpload = remotePermissionEnabled(LegacyAccountPermissionBit.upload) ||
            remotePermissionEnabled(LegacyAccountPermissionBit.uploadAnywhere)
        let canCreateFolder = remotePermissionEnabled(LegacyAccountPermissionBit.createFolders)
        let canDeleteSingle: Bool = {
            guard let selectedEntry, !selectedEntry.isSymbolicLink else { return false }
            return selectedEntry.isFolder
                ? remotePermissionEnabled(LegacyAccountPermissionBit.deleteFolders)
                : remotePermissionEnabled(LegacyAccountPermissionBit.deleteFiles)
        }()

        fileDownloadButton.isEnabled = available && connected && fileTransferClient != nil && !selection.isEmpty && canDownload
        fileUploadButton.isEnabled = available && connected && fileTransferClient != nil && lastDirectory != nil && fileSearchResults == nil && canUpload
        fileNewFolderButton.isEnabled = available && connected && lastDirectory != nil && fileSearchResults == nil && canCreateFolder
        fileInfoButton.isEnabled = available && connected && selectedEntry != nil
        fileQuickViewButton.isEnabled = available && connected && canDownload && fileTransferClient != nil && !isQuickViewPreparing &&
            quickViewTransferTask == nil && selectedEntry.map(canQuickView) == true
        fileDeleteButton.isEnabled = available && connected && selection.count == 1 && canDeleteSingle
        updateFileBrowserPresentation()
    }

    @objc func refreshFilesPressed(_ sender: Any?) {
        refreshCurrentServerDirectory()
    }

    func refreshCurrentServerDirectory() {
        if !fileSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            performRemoteFileSearch()
            return
        }
        guard client.isConnected else { return }
        let path = lastDirectory?.currentPath ?? Data()
        requestFileDirectory(path: path,
                             commit: lastDirectory == nil ? .initialize : .none,
                             resetTree: false,
                             resetScroll: false)
    }

    @objc func createServerFolder(_ sender: Any?) {
        guard client.isConnected, let parent = lastDirectory?.currentPath, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = L("New Folder")
        alert.informativeText = LF("Create a folder in %@. Upload Folders accept uploads from users with Can Upload; Dropbox additionally hides its contents unless View Dropboxes is permitted.", LegacyPath.displayString(parent))
        alert.addButton(withTitle: L("Create"))
        alert.addButton(withTitle: L("Cancel"))

        let name = NSTextField(string: L("New Folder"))
        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.addItems(withTitles: [L("Normal Folder"), L("Upload Folder"), L("Dropbox")])
        mode.selectItem(at: LegacyFolderMode.normal.rawValue)
        let canChooseMode = remotePermissionEnabled(LegacyAccountPermissionBit.changeFolderMode)
        mode.isEnabled = canChooseMode
        mode.toolTip = canChooseMode ? L("Choose the Classic folder mode.") : L("Changing folder mode requires the Change Folder Mode permission.")

        let grid = NSGridView(views: [
            [makeLabel(L("Name")), name],
            [makeLabel(L("Folder Mode")), mode],
        ])
        grid.rowSpacing = 7
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.frame = NSRect(x: 0, y: 0, width: 390, height: 60)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = name

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let value = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = value.data(using: .macOSRoman), !data.isEmpty else {
                self.showError(L("The folder name must be representable in MacRoman."))
                return
            }
            let selectedMode = LegacyFolderMode(rawValue: mode.indexOfSelectedItem) ?? .normal
            let flags = canChooseMode ? selectedMode.flags : LegacyFolderMode.normal.flags
            self.client.createFolder(parentPath: parent, name: data, flags: flags) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: self.refreshCurrentServerDirectory()
                case let .failure(error): self.appendLine("\n" + LF("Folder could not be created: %@", Self.displayMessage(for: error)))
                }
            }
        }
    }

    static func quickViewExtension(forName name: String) -> String? {
        let suffix = (name as NSString).pathExtension.lowercased()
        return quickViewExtensions.contains(suffix) ? suffix : nil
    }

    func canQuickView(_ entry: LegacyDirectoryEntry) -> Bool {
        guard !entry.isFolder, !entry.isSymbolicLink,
              UInt64(entry.size) <= Self.quickViewMaximumBytes else { return false }
        return Self.quickViewExtension(forName: Self.macRomanString(entry.name)) != nil
    }

    func cleanupQuickView(closePanel: Bool) {
        quickViewGeneration &+= 1
        isQuickViewPreparing = false
        quickViewTransferTask?.cancel()
        quickViewTransferTask = nil
        if closePanel, let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.delegate = nil
            panel.dataSource = nil
            panel.orderOut(nil)
        }
        quickViewItem = nil
        if let directory = quickViewTemporaryDirectory {
            try? FileManager.default.removeItem(at: directory)
            quickViewTemporaryDirectory = nil
        }
        updateFileTransferButtons()
    }

    @objc func quickViewSelectedFile(_ sender: Any?) {
        guard client.isConnected, let path = selectedServerItemPath,
              let selected = selectedDownloadEntry, canQuickView(selected), !isQuickViewPreparing,
              quickViewTransferTask == nil else { return }
        cleanupQuickView(closePanel: true)
        isQuickViewPreparing = true
        let generation = quickViewGeneration
        let requestedPath = path
        fileQuickViewButton.isEnabled = false
        fileTransferLabel.stringValue = L("Preparing Quick View…")
        client.requestFileInfo(path: requestedPath) { [weak self] result in
            guard let self, generation == self.quickViewGeneration else { return }
            switch result {
            case let .failure(error):
                self.isQuickViewPreparing = false
                self.updateFileTransferButtons()
                self.fileTransferLabel.stringValue = ""
                self.showError(LF("Quick View: %@", Self.displayMessage(for: error)))
            case let .success(info):
                let isFolder = (info.metadata.flags & LegacyDirectoryFlags.folder) != 0
                let title = Self.macRomanString(info.name)
                guard !isFolder,
                      let suffix = Self.quickViewExtension(forName: title),
                      UInt64(info.metadata.size) <= Self.quickViewMaximumBytes,
                      let transfer = self.fileTransferClient else {
                    self.isQuickViewPreparing = false
                    self.updateFileTransferButtons()
                    self.fileTransferLabel.stringValue = ""
                    self.showError(L("Quick View is available only for .txt, .jpg, .png, .pdf, .html, .gif and .sh files up to 2 MB."))
                    return
                }

                do {
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("CarrachoQuickView-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    let destination = directory.appendingPathComponent("preview.\(suffix)", isDirectory: false)
                    self.quickViewTemporaryDirectory = directory
                    self.fileTransferLabel.stringValue = LF("Quick View loading %@ …", title)
                    self.quickViewTransferTask = transfer.download(remotePath: requestedPath, to: destination,
                                                                   maximumFileSize: Self.quickViewMaximumBytes) { [weak self] download in
                        guard let self, generation == self.quickViewGeneration else { return }
                        self.quickViewTransferTask = nil
                        self.updateFileTransferButtons()
                        switch download {
                        case let .failure(error):
                            if self.quickViewTemporaryDirectory == directory {
                                try? FileManager.default.removeItem(at: directory)
                                self.quickViewTemporaryDirectory = nil
                            }
                            self.fileTransferLabel.stringValue = ""
                            self.showError(LF("Quick View: %@", Self.displayMessage(for: error)))
                        case let .success(url):
                            do {
                                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                                let actualSize = UInt64(max(values.fileSize ?? 0, 0))
                                guard values.isRegularFile == true, values.isSymbolicLink != true,
                                      actualSize <= Self.quickViewMaximumBytes else {
                                    throw LegacyFileTransferError.fileTooLarge(maximumBytes: Self.quickViewMaximumBytes)
                                }
                                self.quickViewItem = CarrachoQuickLookItem(url: url, title: title)
                                guard let panel = QLPreviewPanel.shared() else {
                                    throw LegacyFileTransferError.localFile(L("Quick Look panel is unavailable."))
                                }
                                panel.dataSource = self
                                panel.delegate = self
                                panel.reloadData()
                                panel.currentPreviewItemIndex = 0
                                panel.makeKeyAndOrderFront(nil)
                                self.fileTransferLabel.stringValue = LF("Quick View · %@", title)
                            } catch {
                                self.cleanupQuickView(closePanel: true)
                                self.fileTransferLabel.stringValue = ""
                                self.showError(LF("Quick View: %@", Self.displayMessage(for: error)))
                            }
                        }
                    }
                    self.isQuickViewPreparing = false
                    self.updateFileTransferButtons()
                } catch {
                    self.cleanupQuickView(closePanel: true)
                    self.fileTransferLabel.stringValue = ""
                    self.showError(LF("Quick View: %@", Self.displayMessage(for: error)))
                }
            }
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickViewItem == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index == 0 else { return nil }
        return quickViewItem
    }

    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow, closingWindow === clientSettingsWindow {
            let pendingBookmarkID = resumeConnectionBookmarkID
            resumeConnectionAfterIdentitySetup = false
            resumeConnectionBookmarkID = nil
            clearBookmarkConnectingIndicatorAfterRejectedAttempt()
            if let pendingBookmarkID, temporaryServerBookmarkIDs.contains(pendingBookmarkID) {
                discardTemporaryServerBookmarkAfterDisconnect(pendingBookmarkID)
            }
            clientSoundPreferences.stopPreview()
            clientSettingsWindow = nil
            clientSettingsTabControl = nil
            clientSettingsGeneralView = nil
            clientSettingsSoundsView = nil
            clientSettingsRestoreDefaultsButton = nil
            clientSettingsSoundsEnabledCheckbox = nil
            clientSettingsVolumeSlider = nil
            clientSettingsVolumeLabel = nil
            clientSettingsSoundPopups.removeAll()
            clientSettingsSoundPreviewButtons.removeAll()
            clientSettingsNotificationCheckboxes.removeAll()
            clientSettingsGeneralWasVisited = false
            clientSettingsNicknameField = nil
            clientSettingsStatusField = nil
            clientSettingsEmailField = nil
            clientSettingsAboutView = nil
            clientSettingsDownloadFolderField = nil
            clientSettingsAvatarView = nil
            clientSettingsPendingDownloadFolderPath = nil
            return
        }
        guard notification.object is QLPreviewPanel else { return }
        cleanupQuickView(closePanel: false)
        fileTransferLabel.stringValue = ""
    }

    @objc func editSelectedFileInfo(_ sender: Any?) {
        guard client.isConnected, let path = selectedServerItemPath else { return }
        client.requestFileInfo(path: path) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                self.appendLine("\n" + LF("File Info could not be loaded: %@", Self.displayMessage(for: error)))
            case let .success(info):
                guard let window = self.view.window else { return }
                let isFolder = (info.metadata.flags & LegacyDirectoryFlags.folder) != 0
                let renamePermission = isFolder ? LegacyAccountPermissionBit.renameFolders : LegacyAccountPermissionBit.renameFiles
                let commentPermission = isFolder ? LegacyAccountPermissionBit.commentFolders : LegacyAccountPermissionBit.commentFiles
                let canRename = self.isRemoteAdministrator && self.remotePermissionEnabled(renamePermission)
                let canComment = self.remotePermissionEnabled(commentPermission)
                let canChangeFlags = isFolder && self.remotePermissionEnabled(LegacyAccountPermissionBit.changeFolderMode)

                if let existing = self.fileInfoWindowController, let sheet = existing.window, sheet.sheetParent === window {
                    window.endSheet(sheet)
                }
                self.fileInfoWindowController = nil

                let supportsLabels = self.client.transferSession?.usesModernCrypto == true
                let controller = FileInfoWindowController(
                    info: info,
                    isFolder: isFolder,
                    canRename: canRename,
                    canComment: canComment,
                    canChangeFlags: canChangeFlags,
                    supportsLabels: supportsLabels,
                    canLabel: supportsLabels && canComment
                )
                self.fileInfoWindowController = controller
                controller.onSave = { [weak self] name, comment, selectedMode, selectedLabel in
                    guard let self else { return L("File Info could not be saved.") }
                    guard let nameData = name.data(using: .macOSRoman), !nameData.isEmpty,
                          let commentData = comment.data(using: .macOSRoman) else {
                        return L("Name and comment must be representable in MacRoman.")
                    }
                    var flagValue = info.metadata.flags & ~LegacyDirectoryFlags.folder
                    if isFolder, canChangeFlags {
                        flagValue &= ~LegacyDirectoryFlags.specialFolderModeMask
                        flagValue |= selectedMode.flags
                    }
                    self.client.setFileInfo(path: path, name: nameData, flags: flagValue, comment: commentData,
                                            label: supportsLabels ? selectedLabel : nil) { [weak self] save in
                        guard let self else { return }
                        switch save {
                        case .success:
                            self.applySuccessfulRemoteFileInfoEdit(sourcePath: path,
                                                                   newName: nameData,
                                                                   isFolder: isFolder,
                                                                   flags: flagValue,
                                                                   label: supportsLabels ? selectedLabel : nil)
                            self.refreshCurrentServerDirectory()
                        case let .failure(error):
                            self.appendLine("\n" + LF("File Info could not be saved: %@", Self.displayMessage(for: error)))
                        }
                    }
                    return nil
                }
                controller.onFinish = { [weak self, weak controller] in
                    guard let self else { return }
                    if self.fileInfoWindowController === controller {
                        self.fileInfoWindowController = nil
                    }
                }
                controller.beginSheet(for: window)
            }
        }
    }

    @objc func deleteSelectedServerItem(_ sender: Any?) {
        guard client.isConnected, let entry = selectedDownloadEntry, let path = selectedServerItemPath,
              let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = entry.isFolder ? L("Delete Folder") : L("Delete File")
        alert.informativeText = LF("Move “%@” to the server Trash?", Self.macRomanString(entry.name))
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.client.deleteFile(path: path) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    // The selected row can come from an inline-expanded child folder. Refreshing
                    // only `lastDirectory` does not update that child's cached listing, leaving the
                    // successfully trashed item visible until the tree is collapsed/reloaded.
                    // Patch the local tree immediately, then ask the server to reconcile the open
                    // directory/search results in the background.
                    self.applySuccessfulRemoteDelete(path: path, wasFolder: entry.isFolder)
                    self.refreshCurrentServerDirectory()
                case let .failure(error):
                    self.appendLine("\n" + LF("Delete failed: %@", Self.displayMessage(for: error)))
                }
            }
        }
    }

    @objc func goToParentDirectory(_ sender: Any?) {
        guard fileSearchResults == nil,
              let current = lastDirectory?.currentPath,
              let parent = LegacyPath.parent(of: current) else { return }
        navigate(to: parent)
    }

    func navigate(to path: Data) {
        guard client.isConnected else { return }
        fileSearchGeneration += 1
        isFileSearchBusy = false
        fileSearchResults = nil
        fileSearchError = nil
        fileSearchField.stringValue = ""

        // If the user just expanded this folder, its complete listing is already in memory.
        // Reuse that exact result when entering it instead of immediately issuing the same
        // directory request again. Besides avoiding needless round-trips, this guarantees that
        // "expanded" and "opened" show the same contents on quirky Classic-compatible servers.
        if let prefetched = expandedDirectoryListings[path] {
            fileDirectoryLoadGeneration &+= 1
            fileDirectoryLoading = false
            filePendingDirectoryPath = nil
            installFileDirectoryListing(prefetched, requestedPath: path, commit: .push,
                                        resetTree: true, resetScroll: true)
            return
        }

        requestFileDirectory(path: path, commit: .push, resetTree: true, resetScroll: true)
    }

    func filesDisplayPath(_ path: Data) -> String {
        let root = lastLoginResult?.filesRootName ?? LegacyFilesRootCapability.defaultDisplayName
        guard !path.isEmpty else { return root }
        let legacy = LegacyPath.displayString(path)
        let suffix = legacy.hasPrefix("/") ? String(legacy.dropFirst()) : legacy
        return suffix.isEmpty ? root : root + " / " + suffix.replacingOccurrences(of: "/", with: " / ")
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tableView === fileTable,
              client.isConnected,
              !isFileSearchBusy,
              let transfer = fileTransferClient,
              row >= 0, row < visibleFileRows.count else { return nil }

        let item = visibleFileRows[row]
        let name = Self.macRomanString(item.entry.name)
        guard !name.isEmpty else { return nil }
        let info = RemoteFilePromiseInfo(remotePath: item.path,
                                         displayName: name,
                                         isFolder: item.entry.isFolder,
                                         transferClient: transfer)
        let provider = CarrachoRemoteFilePromiseProvider(
            fileType: item.entry.isFolder ? "public.directory" : "public.data",
            delegate: self,
            remotePath: item.path
        )
        provider.userInfo = info
        return provider
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === fileTable,
              client.isConnected,
              !isFileSearchBusy,
              fileSearchResults == nil,
              let currentPath = lastDirectory?.currentPath else { return [] }

        let remotePaths = draggedRemoteFilePaths(from: info)
        if !remotePaths.isEmpty {
            let localPoint = tableView.convert(info.draggingLocation, from: nil)
            let hoveredRow = tableView.row(at: localPoint)
            let targetPath: Data
            if hoveredRow >= 0, hoveredRow < visibleFileRows.count,
               visibleFileRows[hoveredRow].entry.isFolder {
                tableView.setDropRow(hoveredRow, dropOperation: .on)
                targetPath = visibleFileRows[hoveredRow].path
            } else {
                // Dropping on free table space means the currently open folder. This also lets
                // an item from an expanded child folder be dragged back up one or more levels.
                tableView.setDropRow(-1, dropOperation: .on)
                targetPath = currentPath
            }
            return canMoveRemoteFilePaths(remotePaths, to: targetPath) ? .move : []
        }

        guard fileTransferClient != nil, draggedLocalFileURLs(from: info).isEmpty == false else { return [] }
        let localPoint = tableView.convert(info.draggingLocation, from: nil)
        let hoveredRow = tableView.row(at: localPoint)
        if hoveredRow >= 0, hoveredRow < visibleFileRows.count,
           visibleFileRows[hoveredRow].entry.isFolder {
            tableView.setDropRow(hoveredRow, dropOperation: .on)
        } else {
            // Row -1 with .on means the whole table. In Files that maps to the currently open folder.
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return .copy
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard tableView === fileTable,
              client.isConnected,
              !isFileSearchBusy,
              fileSearchResults == nil,
              let currentPath = lastDirectory?.currentPath else { return false }

        let remotePaths = draggedRemoteFilePaths(from: info)
        if !remotePaths.isEmpty {
            let targetPath: Data
            if dropOperation == .on,
               row >= 0, row < visibleFileRows.count,
               visibleFileRows[row].entry.isFolder {
                targetPath = visibleFileRows[row].path
            } else {
                targetPath = currentPath
            }
            guard canMoveRemoteFilePaths(remotePaths, to: targetPath) else { return false }
            moveRemoteFilePaths(remotePaths, to: targetPath)
            return true
        }

        guard fileTransferClient != nil else { return false }
        let urls = draggedLocalFileURLs(from: info)
        guard !urls.isEmpty else { return false }
        let targetPath: Data
        if dropOperation == .on,
           row >= 0, row < visibleFileRows.count,
           visibleFileRows[row].entry.isFolder {
            targetPath = visibleFileRows[row].path
        } else {
            targetPath = currentPath
        }
        for url in urls { enqueueUpload(localFile: url, parentPath: targetPath) }
        return true
    }

    func draggedRemoteFilePaths(from info: NSDraggingInfo) -> [Data] {
        guard let source = info.draggingSource as? NSTableView, source === fileTable else { return [] }
        let values = info.draggingPasteboard.pasteboardItems?.compactMap {
            $0.data(forType: Self.remoteFileMovePasteboardType)
        } ?? []
        var seen = Set<Data>()
        return values.filter { seen.insert($0).inserted }
    }

    private func isLegacyPath(_ candidate: Data, descendantOf parent: Data) -> Bool {
        guard candidate.count > parent.count, candidate.starts(with: parent) else { return false }
        return parent.isEmpty || candidate[parent.count] == LegacyPath.separator
    }

    private func normalizedRemoteMovePaths(_ paths: [Data]) -> [Data] {
        let unique = paths.reduce(into: [Data]()) { result, path in
            if !result.contains(path) { result.append(path) }
        }
        // If a selected folder contains another selected row, moving the folder already moves
        // that child. Sending a second server move for the child would only fail afterwards.
        return unique.filter { candidate in
            !unique.contains { other in
                other != candidate && isLegacyPath(candidate, descendantOf: other)
            }
        }
    }

    private func remoteMovePlans(paths: [Data], targetParent: Data) -> [(source: Data, destination: Data, entry: LegacyDirectoryEntry)]? {
        let rowsByPath = Dictionary(uniqueKeysWithValues: visibleFileRows.map { ($0.path, $0.entry) })
        var plans: [(source: Data, destination: Data, entry: LegacyDirectoryEntry)] = []
        var destinations = Set<Data>()

        for source in normalizedRemoteMovePaths(paths) {
            guard let entry = rowsByPath[source] else { return nil }
            let permission = entry.isFolder ? LegacyAccountPermissionBit.moveFolders : LegacyAccountPermissionBit.moveFiles
            guard remotePermissionEnabled(permission) else { return nil }
            if entry.isFolder, (targetParent == source || isLegacyPath(targetParent, descendantOf: source)) { return nil }
            let leafStart: Data.Index
            if let separator = source.lastIndex(of: LegacyPath.separator) {
                leafStart = source.index(after: separator)
            } else {
                leafStart = source.startIndex
            }
            guard leafStart < source.endIndex else { return nil }
            let leaf = Data(source[leafStart..<source.endIndex])
            guard let destination = try? LegacyPath.child(parent: targetParent, name: leaf) else { return nil }
            if destination == source { continue }
            guard destinations.insert(destination).inserted else { return nil }
            plans.append((source, destination, entry))
        }
        return plans
    }

    private func canMoveRemoteFilePaths(_ paths: [Data], to targetParent: Data) -> Bool {
        guard let plans = remoteMovePlans(paths: paths, targetParent: targetParent) else { return false }
        return !plans.isEmpty
    }

    private func remappedLegacyPath(_ path: Data, moving source: Data, to destination: Data) -> Data {
        guard path == source || isLegacyPath(path, descendantOf: source) else { return path }
        var remapped = destination
        if path.count > source.count {
            remapped.append(path[source.count...])
        }
        return remapped
    }

    /// Apply a successful File Info edit to the in-memory tree immediately. A server refresh still
    /// follows, but waiting for that round-trip leaves the old name visible and is especially wrong
    /// for rows coming from an inline-expanded directory cache.
    private func applySuccessfulRemoteFileInfoEdit(sourcePath: Data,
                                                   newName: Data,
                                                   isFolder: Bool,
                                                   flags: UInt16,
                                                   label: LegacyFileLabel?) {
        let parent = LegacyPath.parent(of: sourcePath) ?? Data()
        guard let destinationPath = try? LegacyPath.child(parent: parent, name: newName) else { return }
        let renamed = destinationPath != sourcePath

        func patchEntry(in listing: inout LegacyDirectoryListing) {
            guard listing.currentPath == parent else { return }
            for index in listing.entries.indices {
                guard let candidatePath = try? LegacyPath.child(parent: listing.currentPath,
                                                                 name: listing.entries[index].name),
                      candidatePath == sourcePath else { continue }
                listing.entries[index].name = newName
                listing.entries[index].flags = (listing.entries[index].flags & LegacyDirectoryFlags.folder) | flags
                if let label { listing.entries[index].label = label }
                break
            }
        }

        if var root = lastDirectory {
            patchEntry(in: &root)
            lastDirectory = root
        }
        for key in Array(expandedDirectoryListings.keys) {
            guard var listing = expandedDirectoryListings[key] else { continue }
            patchEntry(in: &listing)
            expandedDirectoryListings[key] = listing
        }

        if renamed {
            selectedFilePaths = Set(selectedFilePaths.map { path in
                if path == sourcePath || (isFolder && isLegacyPath(path, descendantOf: sourcePath)) {
                    return remappedLegacyPath(path, moving: sourcePath, to: destinationPath)
                }
                return path
            })

            if isFolder {
                expandedFilePaths = Set(expandedFilePaths.map {
                    remappedLegacyPath($0, moving: sourcePath, to: destinationPath)
                })
                loadingExpandedFilePaths = Set(loadingExpandedFilePaths.map {
                    remappedLegacyPath($0, moving: sourcePath, to: destinationPath)
                })

                var remappedListings: [Data: LegacyDirectoryListing] = [:]
                for (key, var listing) in expandedDirectoryListings {
                    let newKey = remappedLegacyPath(key, moving: sourcePath, to: destinationPath)
                    listing.currentPath = remappedLegacyPath(listing.currentPath,
                                                              moving: sourcePath,
                                                              to: destinationPath)
                    remappedListings[newKey] = listing
                }
                expandedDirectoryListings = remappedListings
            }
        }

        if var results = fileSearchResults {
            for index in results.indices {
                let oldPath = results[index].path
                guard oldPath == sourcePath || (isFolder && isLegacyPath(oldPath, descendantOf: sourcePath)) else {
                    continue
                }
                results[index].path = remappedLegacyPath(oldPath, moving: sourcePath, to: destinationPath)
                if oldPath == sourcePath { results[index].name = newName }
            }
            fileSearchResults = results
        }

        reloadFileTablePreservingState()
        updateFileTransferButtons()
    }

    private func applySuccessfulRemoteDelete(path: Data, wasFolder: Bool) {
        let parent = LegacyPath.parent(of: path) ?? Data()

        func removeDeletedEntry(from listing: inout LegacyDirectoryListing) {
            guard listing.currentPath == parent else { return }
            listing.entries.removeAll { entry in
                guard let entryPath = try? LegacyPath.child(parent: listing.currentPath, name: entry.name) else {
                    return false
                }
                return entryPath == path
            }
        }

        if var root = lastDirectory {
            removeDeletedEntry(from: &root)
            lastDirectory = root
        }
        for key in Array(expandedDirectoryListings.keys) {
            guard var listing = expandedDirectoryListings[key] else { continue }
            removeDeletedEntry(from: &listing)
            expandedDirectoryListings[key] = listing
        }

        if wasFolder {
            // A deleted folder may itself have been expanded, as may any number of descendants.
            // Remove those orphaned cache entries without collapsing unrelated folders.
            expandedFilePaths = Set(expandedFilePaths.filter {
                $0 != path && !isLegacyPath($0, descendantOf: path)
            })
            loadingExpandedFilePaths = Set(loadingExpandedFilePaths.filter {
                $0 != path && !isLegacyPath($0, descendantOf: path)
            })
            for key in Array(expandedDirectoryListings.keys)
            where key == path || isLegacyPath(key, descendantOf: path) {
                expandedDirectoryListings.removeValue(forKey: key)
            }
        }

        if let results = fileSearchResults {
            fileSearchResults = results.filter {
                $0.path != path && !(wasFolder && isLegacyPath($0.path, descendantOf: path))
            }
        }
        selectedFilePaths = Set(selectedFilePaths.filter {
            $0 != path && !(wasFolder && isLegacyPath($0, descendantOf: path))
        })

        reloadFileTablePreservingState()
        updateFileTransferButtons()
    }

    /// Keep the inline directory tree coherent after a successful server-side move. Previously
    /// the move completion simply threw away every expanded listing, which made all disclosure
    /// triangles snap shut even when the moved item was unrelated to those folders.
    private func applySuccessfulRemoteMove(source: Data,
                                           destination: Data,
                                           entry: LegacyDirectoryEntry) {
        let sourceParent = LegacyPath.parent(of: source) ?? Data()
        let destinationParent = LegacyPath.parent(of: destination) ?? Data()

        func patch(_ listing: inout LegacyDirectoryListing) {
            if listing.currentPath == sourceParent {
                listing.entries.removeAll { candidate in
                    guard let path = try? LegacyPath.child(parent: listing.currentPath, name: candidate.name) else { return false }
                    return path == source
                }
            }
            if listing.currentPath == destinationParent {
                let alreadyPresent = listing.entries.contains { candidate in
                    guard let path = try? LegacyPath.child(parent: listing.currentPath, name: candidate.name) else { return false }
                    return path == destination
                }
                if !alreadyPresent { listing.entries.append(entry) }
            }
        }

        if var root = lastDirectory {
            patch(&root)
            lastDirectory = root
        }
        for key in Array(expandedDirectoryListings.keys) {
            guard var listing = expandedDirectoryListings[key] else { continue }
            patch(&listing)
            expandedDirectoryListings[key] = listing
        }

        guard entry.isFolder else { return }

        // If the moved item itself (or a folder below it) was expanded, let that expansion follow
        // the folder to its new path instead of silently losing the user's tree state.
        expandedFilePaths = Set(expandedFilePaths.map {
            remappedLegacyPath($0, moving: source, to: destination)
        })
        loadingExpandedFilePaths = Set(loadingExpandedFilePaths.map {
            remappedLegacyPath($0, moving: source, to: destination)
        })

        var remappedListings: [Data: LegacyDirectoryListing] = [:]
        for (key, var listing) in expandedDirectoryListings {
            let newKey = remappedLegacyPath(key, moving: source, to: destination)
            listing.currentPath = remappedLegacyPath(listing.currentPath, moving: source, to: destination)
            remappedListings[newKey] = listing
        }
        expandedDirectoryListings = remappedListings
    }

    private func moveRemoteFilePaths(_ paths: [Data], to targetParent: Data) {
        guard let plans = remoteMovePlans(paths: paths, targetParent: targetParent), !plans.isEmpty else { return }
        fileTransferLabel.stringValue = plans.count == 1 ? L("Moving item…") : LF("Moving %@ items…", String(plans.count))
        fileTransferLabel.toolTip = nil

        var failures: [String] = []
        func moveNext(_ index: Int) {
            guard index < plans.count else {
                self.fileTransferLabel.stringValue = failures.isEmpty
                    ? (plans.count == 1 ? L("Item moved") : LF("%@ items moved", String(plans.count)))
                    : LF("Move completed with %@ error(s)", String(failures.count))
                // Refresh only the open directory. The inline child caches were patched for each
                // successful move above, so unrelated expanded folders stay exactly as they were.
                self.refreshCurrentServerDirectory()
                for message in failures { self.appendLine("\n" + message) }
                return
            }

            let plan = plans[index]
            self.client.moveFile(sourcePath: plan.source, destinationPath: plan.destination) { result in
                switch result {
                case .success:
                    self.applySuccessfulRemoteMove(source: plan.source,
                                                   destination: plan.destination,
                                                   entry: plan.entry)
                case let .failure(error):
                    failures.append(LF("Could not move %@: %@", LegacyPath.displayName(plan.source), Self.displayMessage(for: error)))
                }
                moveNext(index + 1)
            }
        }
        moveNext(0)
    }

    func draggedLocalFileURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) else { return [] }
        return objects.compactMap { object in
            if let url = object as? URL { return url }
            if let url = object as? NSURL { return url as URL }
            return nil
        }
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? RemoteFilePromiseInfo)?.displayName ?? L("Carracho Download")
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }

    func fulfillRemoteFilePromise(_ provider: NSFilePromiseProvider,
                                          destinationURL: URL,
                                          completionHandler: @escaping (Error?) -> Void) {
        guard let info = provider.userInfo as? RemoteFilePromiseInfo else {
            completionHandler(NSError(domain: "Carracho.FilePromise", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: L("The dragged server item is no longer available.")]))
            return
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            completionHandler(LegacyFileTransferError.localFile(LF("The drop destination %@ already exists.", destinationURL.lastPathComponent)))
            return
        }

        let progress: (LegacyFileTransferProgress) -> Void = { [weak self] progress in
            guard let self else { return }
            let completed = ByteCountFormatter.string(fromByteCount: Int64(min(progress.completedBytes, UInt64(Int64.max))), countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(min(progress.totalBytes, UInt64(Int64.max))), countStyle: .file)
            self.fileTransferLabel.stringValue = LF("Drag download: %@ · %@ / %@", info.displayName, completed, total)
        }

        if info.isFolder {
            let destinationParent = destinationURL.deletingLastPathComponent()
            let stagingParent = destinationParent.appendingPathComponent(".carracho-file-promise-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: stagingParent, withIntermediateDirectories: false)
            } catch {
                completionHandler(error)
                return
            }
            _ = info.transferClient.downloadDirectory(remotePath: info.remotePath,
                                                      toParentDirectory: stagingParent,
                                                      progress: progress) { [weak self] result in
                defer { try? FileManager.default.removeItem(at: stagingParent) }
                switch result {
                case let .success(downloadedRoot):
                    do {
                        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                            throw LegacyFileTransferError.localFile(LF("The drop destination %@ already exists.", destinationURL.lastPathComponent))
                        }
                        try FileManager.default.moveItem(at: downloadedRoot, to: destinationURL)
                        self?.fileTransferLabel.stringValue = LF("Drag download completed: %@", info.displayName)
                        self?.emitClientEvent(.transferCompleted,
                                              notificationTitle: L("File transfer completed"),
                                              notificationBody: LF("%@ was transferred successfully.", info.displayName))
                        completionHandler(nil)
                    } catch {
                        completionHandler(error)
                    }
                case let .failure(error):
                    self?.fileTransferLabel.stringValue = LF("Drag download failed: %@", info.displayName)
                    completionHandler(error)
                }
            }
        } else {
            _ = info.transferClient.download(remotePath: info.remotePath,
                                             to: destinationURL,
                                             progress: progress) { [weak self] result in
                switch result {
                case .success:
                    self?.fileTransferLabel.stringValue = LF("Drag download completed: %@", info.displayName)
                    self?.emitClientEvent(.transferCompleted,
                                          notificationTitle: L("File transfer completed"),
                                          notificationBody: LF("%@ was transferred successfully.", info.displayName))
                    completionHandler(nil)
                case let .failure(error):
                    let parent = destinationURL.deletingLastPathComponent()
                    try? FileManager.default.removeItem(at: parent.appendingPathComponent("\(destinationURL.lastPathComponent).carracho"))
                    try? FileManager.default.removeItem(at: parent.appendingPathComponent(".carracho.\(destinationURL.lastPathComponent)"))
                    self?.fileTransferLabel.stringValue = LF("Drag download failed: %@", info.displayName)
                    completionHandler(error)
                }
            }
        }
    }

    static func fileKindTitle(_ entry: LegacyDirectoryEntry) -> String {
        if entry.isSymbolicLink { return L("Symlink") }
        if entry.isDropBox { return L("Dropbox") }
        if entry.isUploadFolder { return L("Upload Folder") }
        if entry.isFolder { return L("Folder") }

        let name = macRomanString(entry.name)
        let fileExtension = (name as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return L("File") }

        // Prefer a useful, human-readable type over the old generic "File" label. Keep a few
        // common formats explicit, then let Uniform Type Identifiers classify the rest.
        switch fileExtension {
        case "7z": return LF("%@ Archive", "7z")
        case "zip": return LF("%@ Archive", "ZIP")
        case "rar": return LF("%@ Archive", "RAR")
        case "tar": return LF("%@ Archive", "TAR")
        case "gz", "gzip": return LF("%@ Archive", "GZip")
        case "bz2": return LF("%@ Archive", "BZip2")
        case "xz": return LF("%@ Archive", "XZ")
        case "iso": return L("ISO Disk Image")
        case "dmg": return L("Disk Image")
        case "pdf": return L("PDF Document")
        default: break
        }

        if #available(macOS 12.0, *), let type = UTType(filenameExtension: fileExtension) {
            let format = fileExtension.uppercased()
            if type.conforms(to: .image) { return LF("%@ Image", format) }
            if type.conforms(to: .audio) { return LF("%@ Audio", format) }
            if type.conforms(to: .movie) { return LF("%@ Video", format) }
            if type.conforms(to: .archive) { return LF("%@ Archive", format) }
            if type.conforms(to: .plainText) { return L("Text Document") }
        }

        return LF("%@ File", fileExtension.uppercased())
    }


    func fileRowLabelTint(at row: Int) -> NSColor? {
        guard row >= 0, row < visibleFileRows.count,
              let color = visibleFileRows[row].entry.label.displayColor else { return nil }
        // Finder-style labels color the complete row. Keep enough translucency that the
        // alternating table treatment, text and the normal selection overlay remain legible.
        return color.withAlphaComponent(0.30)
    }

    func sortedDirectoryEntries(_ entries: [LegacyDirectoryEntry]) -> [LegacyDirectoryEntry] {
        sortedForTable(entries, table: fileTable) { lhs, rhs, key in
            switch key {
            case "name": return Self.compareText(Self.macRomanString(lhs.name), Self.macRomanString(rhs.name))
            case "size": return Self.compareNumber(lhs.size, rhs.size)
            case "kind": return Self.compareText(Self.fileKindTitle(lhs), Self.fileKindTitle(rhs))
            case "modified": return Self.compareNumber(lhs.timestamp, rhs.timestamp)
            default: return .orderedSame
            }
        }
    }
    func applyFilesFontSize() {
        // Keep rows comfortably clickable but denser than the previous 30+ pt treatment.
        fileTable.rowHeight = max(27, filesFontSize + 14)
        fileTable.reloadData()
    }

    @objc func menuFiles(_ sender: Any?) { selectWorkspace(.files) }

    @objc func showFiles(_ sender: Any?) { selectWorkspace(.files) }

}
