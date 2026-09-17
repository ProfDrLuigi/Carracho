import Cocoa
import QuickLookUI

extension NSTextView {
    /// Keep links visually clickable without AppKit's default blue underline. This applies to
    /// app-actions (News edit/delete/reactions) and ordinary detected/rendered links.
    func useCarrachoLinkAppearance() {
        linkTextAttributes = [
            .foregroundColor: CarrachoTheme.selection,
            .underlineStyle: 0,
        ]
    }
}

final class CarrachoQuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
    }
}

/// Visual content placed inside a bookmark button must not become the AppKit hit target.
/// Returning nil makes the surrounding NSButton receive real mouse clicks on labels/icons.
final class BookmarkButtonContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Placeholder text drawn on top of an editor must remain purely visual. A normal disabled
/// NSTextField still participates in hit testing and can swallow the click that should focus the
/// NSTextView underneath it.
final class MousePassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class BookmarkActionButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(point) else { return nil }
        return self
    }
}

/// NSTableView keeps the document width it had when it first became an NSScrollView document
/// view. News uses resizable panes, so pin its table document to the live viewport from the very
/// first layout pass. Column autoresizing can then distribute that width immediately instead of
/// waiting for the user to drag a divider once.
final class LeadingInsetTableHeaderCell: NSTableHeaderCell {
    let leadingInset: CGFloat

    init(textCell string: String, leadingInset: CGFloat) {
        self.leadingInset = leadingInset
        super.init(textCell: string)
    }

    required init(coder: NSCoder) {
        leadingInset = 0
        super.init(coder: coder)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawing = super.drawingRect(forBounds: rect)
        drawing.origin.x += leadingInset
        drawing.size.width = max(0, drawing.size.width - leadingInset)
        return drawing
    }
}

final class ViewportWidthTableScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let table = documentView as? NSTableView, !table.tableColumns.isEmpty else { return }
        let viewportWidth = contentView.bounds.width
        guard viewportWidth > 0 else { return }
        let minimumWidth = table.tableColumns.reduce(CGFloat.zero) { $0 + $1.minWidth }
        let width = max(minimumWidth, viewportWidth)
        if abs(table.frame.width - width) > 0.5 {
            table.setFrameSize(NSSize(width: width, height: table.frame.height))
        }
        if table.tableColumns.count == 1 {
            let column = table.tableColumns[0]
            if abs(column.width - width) > 0.5 { column.width = width }
        }
    }
}

let sidebarBlockPasteboardType = NSPasteboard.PasteboardType("com.carracho.sidebar-block")
let sidebarBlockViewIdentifierPrefix = "carracho.sidebar.block."

/// Small grip used to drag a whole sidebar section without stealing clicks from the
/// buttons contained in that section.
final class SidebarBlockDragHandle: NSView, NSDraggingSource {
    let blockIdentifier: String
    weak var draggedView: NSView?
    let imageView = NSImageView()
    var draggingStarted = false

    init(blockIdentifier: String) {
        self.blockIdentifier = blockIdentifier
        super.init(frame: .zero)
        toolTip = L("Drag to reorder this sidebar block")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *) {
            imageView.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: L("Drag"))
        } else {
            imageView.image = NSImage(named: NSImage.listViewTemplateName)
        }
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = CarrachoTheme.secondaryText
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 13),
            imageView.heightAnchor.constraint(equalToConstant: 13),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: draggingStarted ? .closedHand : .openHand)
    }

    func resetDraggingState() {
        draggingStarted = false
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        resetDraggingState()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !draggingStarted, let draggedView else { return }
        draggingStarted = true
        window?.invalidateCursorRects(for: self)

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(blockIdentifier, forType: sidebarBlockPasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

        let dragBounds = draggedView.bounds
        var snapshot: NSImage?
        if dragBounds.width > 0, dragBounds.height > 0,
           let rep = draggedView.bitmapImageRepForCachingDisplay(in: dragBounds) {
            draggedView.cacheDisplay(in: dragBounds, to: rep)
            let image = NSImage(size: dragBounds.size)
            image.addRepresentation(rep)
            snapshot = image
        }
        let location = convert(event.locationInWindow, from: nil)
        let frame = NSRect(x: location.x - 12,
                           y: location.y - max(11, dragBounds.height / 2),
                           width: max(1, dragBounds.width),
                           height: max(1, dragBounds.height))
        draggingItem.setDraggingFrame(frame, contents: snapshot)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        resetDraggingState()
    }

    /// A successful sidebar reorder used to detach this handle's whole block while AppKit
    /// was still finishing the drag session. In that case `draggingSession(...endedAt:)` was
    /// not guaranteed to arrive, leaving `draggingStarted` stuck at true until relaunch.
    /// Reset it explicitly before the destination mutates the stack.
    func prepareForAcceptedDrop() {
        resetDraggingState()
    }
}

/// Destination stack for the reorderable sidebar modules. The actual order mutation is
/// delegated back to the view controller so it can be persisted in UserDefaults.
final class SidebarBlockStackView: NSStackView {
    var onMoveBlock: ((String, Int) -> Void)?
    let dropBoundaryTolerance: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([sidebarBlockPasteboardType])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([sidebarBlockPasteboardType])
    }

    func draggedIdentifier(_ sender: NSDraggingInfo) -> String? {
        sender.draggingPasteboard.string(forType: sidebarBlockPasteboardType)
    }

    func blockIdentifier(for view: NSView) -> String? {
        guard let raw = view.identifier?.rawValue,
              raw.hasPrefix(sidebarBlockViewIdentifierPrefix) else { return nil }
        return String(raw.dropFirst(sidebarBlockViewIdentifierPrefix.count))
    }

    /// Sidebar modules are deliberately a flat list. Only a drag that originates from a
    /// direct arranged subview of this stack may be reordered here. A handle that somehow
    /// lives inside another module is therefore never accepted as a valid source.
    func directDraggedBlock(_ sender: NSDraggingInfo) -> (identifier: String, view: NSView)? {
        guard let identifier = draggedIdentifier(sender),
              let handle = sender.draggingSource as? SidebarBlockDragHandle,
              handle.blockIdentifier == identifier,
              let draggedView = handle.draggedView,
              draggedView.superview === self,
              arrangedSubviews.contains(where: { $0 === draggedView }),
              blockIdentifier(for: draggedView) == identifier else { return nil }
        return (identifier, draggedView)
    }

    /// Return only insertion positions *between* top-level modules. Dropping over the body
    /// of another module is rejected instead of being interpreted as an "inside" drop.
    func insertionIndex(for draggedView: NSView, at point: NSPoint) -> Int? {
        guard bounds.insetBy(dx: -4, dy: -4).contains(point) else { return nil }

        let remaining = arrangedSubviews.filter { $0 !== draggedView }
        let visible = remaining.filter { !$0.isHidden && $0.frame.height > 1 }
        guard !visible.isEmpty else { return 0 }

        struct Boundary {
            let coordinate: CGFloat
            let insertionIndex: Int
        }
        var boundaries: [Boundary] = []

        func topEdge(of view: NSView) -> CGFloat { isFlipped ? view.frame.minY : view.frame.maxY }
        func bottomEdge(of view: NSView) -> CGFloat { isFlipped ? view.frame.maxY : view.frame.minY }

        if let first = visible.first,
           let firstIndex = remaining.firstIndex(where: { $0 === first }) {
            boundaries.append(Boundary(coordinate: topEdge(of: first), insertionIndex: firstIndex))
        }

        for pairIndex in 0..<(visible.count - 1) {
            let upper = visible[pairIndex]
            let lower = visible[pairIndex + 1]
            guard let lowerIndex = remaining.firstIndex(where: { $0 === lower }) else { continue }
            let boundary = (bottomEdge(of: upper) + topEdge(of: lower)) / 2
            boundaries.append(Boundary(coordinate: boundary, insertionIndex: lowerIndex))
        }

        if let last = visible.last,
           let lastIndex = remaining.firstIndex(where: { $0 === last }) {
            boundaries.append(Boundary(coordinate: bottomEdge(of: last), insertionIndex: lastIndex + 1))
        }

        let axis = point.y
        guard let closest = boundaries.min(by: {
            abs($0.coordinate - axis) < abs($1.coordinate - axis)
        }), abs(closest.coordinate - axis) <= dropBoundaryTolerance else { return nil }
        return min(max(0, closest.insertionIndex), remaining.count)
    }

    func validDrop(_ sender: NSDraggingInfo) -> (identifier: String, insertionIndex: Int)? {
        guard let source = directDraggedBlock(sender) else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        guard let index = insertionIndex(for: source.view, at: point) else { return nil }
        return (source.identifier, index)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        validDrop(sender) == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        validDrop(sender) == nil ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let drop = validDrop(sender),
              let handle = sender.draggingSource as? SidebarBlockDragHandle else { return false }
        // Clear the source state while the handle is still attached to the window. The reorder
        // may change the arranged-subview hierarchy synchronously below.
        handle.prepareForAcceptedDrop()
        onMoveBlock?(drop.identifier, drop.insertionIndex)
        return true
    }
}

final class ResponsiveAdvancedGridView: NSStackView {
    let cards: [NSView]
    let leftColumn = NSStackView()
    let rightColumn = NSStackView()
    let columnRow = NSStackView()
    var cardWidthConstraints: [NSLayoutConstraint] = []
    var pairHeightConstraints: [NSLayoutConstraint] = []
    var singleColumn: Bool?
    let collapseWidth: CGFloat = 720

    init(cards: [NSView]) {
        self.cards = cards
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .width
        spacing = 0
        translatesAutoresizingMaskIntoConstraints = false

        for column in [leftColumn, rightColumn] {
            column.orientation = .vertical
            column.alignment = .width
            column.spacing = 14
        }
        columnRow.orientation = .horizontal
        columnRow.alignment = .top
        columnRow.distribution = .fillEqually
        columnRow.spacing = 14
        applyLayout(single: false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        let shouldCollapse = bounds.width > 0 && bounds.width < collapseWidth
        if singleColumn != shouldCollapse { applyLayout(single: shouldCollapse) }
        super.layout()
    }

    func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    func applyLayout(single: Bool) {
        NSLayoutConstraint.deactivate(cardWidthConstraints)
        NSLayoutConstraint.deactivate(pairHeightConstraints)
        cardWidthConstraints.removeAll()
        pairHeightConstraints.removeAll()
        clear(leftColumn)
        clear(rightColumn)
        clear(columnRow)
        clear(self)

        if single {
            spacing = 14
            for card in cards {
                addArrangedSubview(card)
                cardWidthConstraints.append(card.widthAnchor.constraint(equalTo: widthAnchor))
            }
        } else {
            spacing = 0
            for (index, card) in cards.enumerated() {
                let column = index.isMultiple(of: 2) ? leftColumn : rightColumn
                column.addArrangedSubview(card)
                cardWidthConstraints.append(card.widthAnchor.constraint(equalTo: column.widthAnchor))
            }
            columnRow.addArrangedSubview(leftColumn)
            columnRow.addArrangedSubview(rightColumn)
            addArrangedSubview(columnRow)
            cardWidthConstraints.append(columnRow.widthAnchor.constraint(equalTo: widthAnchor))
            cardWidthConstraints.append(leftColumn.widthAnchor.constraint(equalTo: rightColumn.widthAnchor))
            for pairStart in stride(from: 0, to: cards.count - 1, by: 2) {
                pairHeightConstraints.append(cards[pairStart].heightAnchor.constraint(equalTo: cards[pairStart + 1].heightAnchor))
            }
        }
        NSLayoutConstraint.activate(cardWidthConstraints)
        NSLayoutConstraint.activate(pairHeightConstraints)
        singleColumn = single
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}

final class ResponsiveServerInfoLayout: NSStackView {
    let leftPane: NSView
    let rightPane: NSView
    var compact: Bool?
    var widthConstraints: [NSLayoutConstraint] = []
    let collapseWidth: CGFloat = 760

    init(left: NSView, right: NSView) {
        leftPane = left
        rightPane = right
        super.init(frame: .zero)
        alignment = .top
        spacing = 28
        translatesAutoresizingMaskIntoConstraints = false
        apply(compact: false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        let shouldCompact = bounds.width > 0 && bounds.width < collapseWidth
        if compact != shouldCompact { apply(compact: shouldCompact) }
        super.layout()
    }

    func detach(_ view: NSView) {
        if arrangedSubviews.contains(where: { $0 === view }) { removeArrangedSubview(view) }
        view.removeFromSuperview()
    }

    func apply(compact: Bool) {
        NSLayoutConstraint.deactivate(widthConstraints)
        widthConstraints.removeAll()
        detach(leftPane)
        detach(rightPane)

        orientation = compact ? .vertical : .horizontal
        alignment = compact ? .width : .top
        distribution = compact ? .fill : .fillEqually
        spacing = compact ? 22 : 28
        addArrangedSubview(leftPane)
        addArrangedSubview(rightPane)

        if compact {
            widthConstraints.append(leftPane.widthAnchor.constraint(equalTo: widthAnchor))
            widthConstraints.append(rightPane.widthAnchor.constraint(equalTo: widthAnchor))
        } else {
            widthConstraints.append(leftPane.widthAnchor.constraint(equalTo: rightPane.widthAnchor))
        }
        NSLayoutConstraint.activate(widthConstraints)
        self.compact = compact
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}

final class ResponsiveStatisticsGridView: NSStackView {
    let cards: [NSView]
    var rowStacks: [NSStackView] = []
    var lastColumns = 0

    init(cards: [NSView]) {
        self.cards = cards
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .width
        spacing = 10
        translatesAutoresizingMaskIntoConstraints = false
        rebuild(columns: 4)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        let width = bounds.width
        let columns: Int
        if width > 0 && width < 430 { columns = 1 }
        else if width > 0 && width < 760 { columns = 2 }
        else { columns = 4 }
        if columns != lastColumns { rebuild(columns: columns) }
        super.layout()
    }

    func rebuild(columns: Int) {
        for row in rowStacks {
            for view in row.arrangedSubviews {
                row.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        rowStacks.removeAll()

        for start in stride(from: 0, to: cards.count, by: columns) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            let end = min(cards.count, start + columns)
            for card in cards[start..<end] { row.addArrangedSubview(card) }
            if end - start < columns {
                for _ in (end - start)..<columns {
                    let spacer = NSView()
                    spacer.translatesAutoresizingMaskIntoConstraints = false
                    row.addArrangedSubview(spacer)
                }
            }
            addArrangedSubview(row)
            rowStacks.append(row)
        }
        lastColumns = columns
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}

final class EmojiPickerButton: NSButton {
    weak var editor: NSView?
    var preservedSelection: NSRange?

    init(editor: NSView) {
        self.editor = editor
        super.init(frame: .zero)
        title = "😀"
        font = .systemFont(ofSize: 15)
        bezelStyle = .rounded
        toolTip = L("Emoji")
        target = self
        action = #selector(openEmojiPicker(_:))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        widthAnchor.constraint(equalToConstant: 34).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        preservedSelection = currentSelection()
        super.mouseDown(with: event)
    }

    func currentSelection() -> NSRange? {
        if let textView = editor as? NSTextView { return textView.selectedRange() }
        if let field = editor as? NSTextField,
           let fieldEditor = field.currentEditor() as? NSTextView {
            return fieldEditor.selectedRange()
        }
        return nil
    }

    func restoreSelection(_ selection: NSRange, in textView: NSTextView) {
        let length = (textView.string as NSString).length
        let location = min(selection.location, length)
        let rangeLength = min(selection.length, max(0, length - location))
        textView.setSelectedRange(NSRange(location: location, length: rangeLength))
    }

    @objc func openEmojiPicker(_ sender: Any?) {
        guard let editor, let window = editor.window else { return }
        window.makeFirstResponder(editor)
        if let selection = preservedSelection {
            if let textView = editor as? NSTextView {
                restoreSelection(selection, in: textView)
            } else if let fieldEditor = window.fieldEditor(true, for: editor) as? NSTextView {
                restoreSelection(selection, in: fieldEditor)
            }
        }
        DispatchQueue.main.async {
            NSApp.orderFrontCharacterPalette(nil)
        }
    }
}

final class ClearEditorButton: NSButton {
    weak var editor: NSView?

    init(editor: NSView) {
        self.editor = editor
        super.init(frame: .zero)
        title = L("Clear")
        bezelStyle = .rounded
        toolTip = L("Clear message text")
        target = self
        action = #selector(clearEditor(_:))
    }

    required init?(coder: NSCoder) { nil }

    @objc func clearEditor(_ sender: Any?) {
        if let textView = editor as? NSTextView {
            textView.string = ""
            textView.undoManager?.removeAllActions()
            textView.window?.makeFirstResponder(textView)
        } else if let field = editor as? NSTextField {
            field.stringValue = ""
            field.window?.makeFirstResponder(field)
        }
    }
}

final class PrivateMessageComposerWindowController: NSWindowController, NSWindowDelegate {
    let messageView = NSTextView()
    let validationLabel = NSTextField(labelWithString: "")
    var didFinish = false

    var onSend: ((String) -> String?)?
    var onFinish: (() -> Void)?

    init(recipient: String, editorHint: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 470),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = LF("Message to %@", recipient)
        window.minSize = NSSize(width: 500, height: 340)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let toCaption = NSTextField(labelWithString: L("To:"))
        toCaption.font = .systemFont(ofSize: 13, weight: .semibold)
        toCaption.setContentHuggingPriority(.required, for: .horizontal)

        let recipientLabel = NSTextField(labelWithString: recipient)
        recipientLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        recipientLabel.lineBreakMode = .byTruncatingTail
        recipientLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let recipientRow = NSStackView(views: [toCaption, recipientLabel])
        recipientRow.orientation = .horizontal
        recipientRow.alignment = .centerY
        recipientRow.spacing = 7
        recipientRow.translatesAutoresizingMaskIntoConstraints = false

        messageView.isRichText = false
        messageView.allowsUndo = true
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        messageView.isAutomaticDashSubstitutionEnabled = false
        messageView.isAutomaticLinkDetectionEnabled = true
        messageView.useCarrachoLinkAppearance()
        messageView.font = .systemFont(ofSize: 14)
        messageView.textContainerInset = NSSize(width: 10, height: 10)
        messageView.isVerticallyResizable = true
        messageView.isHorizontallyResizable = false
        messageView.autoresizingMask = [.width]
        messageView.textContainer?.widthTracksTextView = true
        messageView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = messageView

        let hint = NSTextField(wrappingLabelWithString: editorHint)
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.translatesAutoresizingMaskIntoConstraints = false

        validationLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        validationLabel.textColor = .systemRed
        validationLabel.isHidden = true
        validationLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded

        let send = NSButton(title: L("Send"), target: self, action: #selector(sendPressed(_:)))
        send.keyEquivalent = "\r"
        send.keyEquivalentModifierMask = [.command]
        CarrachoTheme.applyPrimaryButtonStyle(send)
        send.toolTip = L("Send message (⌘Return)")

        let emoji = EmojiPickerButton(editor: messageView)
        let clear = ClearEditorButton(editor: messageView)
        let buttons = NSStackView(views: [emoji, clear, cancel, send])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(recipientRow)
        root.addSubview(scroll)
        root.addSubview(hint)
        root.addSubview(validationLabel)
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            recipientRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            recipientRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            recipientRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 17),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: recipientRow.bottomAnchor, constant: 13),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -9),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),

            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            validationLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            validationLabel.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            validationLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),

            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            buttons.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 13),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
        send.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    func beginSheet(for parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self.messageView)
        }
    }

    @objc func sendPressed(_ sender: Any?) {
        let source = messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = onSend?(source) {
            validationLabel.stringValue = error
            validationLabel.isHidden = false
            NSSound.beep()
            return
        }
        dismiss()
    }

    @objc func cancelPressed(_ sender: Any?) {
        dismiss()
    }

    func dismiss() {
        guard !didFinish else { return }
        didFinish = true
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window?.orderOut(nil)
        }
        onFinish?()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFinish else { return }
        didFinish = true
        onFinish?()
    }
}

final class OfflineMessageComposerWindowController: NSWindowController, NSWindowDelegate {
    static let defaultContentSize = NSSize(width: 560, height: 430)
    static let minimumContentSize = NSSize(width: 460, height: 340)

    let recipientPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let messageView = NSTextView()
    let validationLabel = NSTextField(labelWithString: "")
    var didFinish = false

    var onSend: ((Data, String, String) -> String?)?
    var onFinish: (() -> Void)?

    init(recipients: [(title: String, login: Data)]) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("Send Offline Message")
        window.minSize = NSSize(width: Self.minimumContentSize.width,
                                height: Self.minimumContentSize.height + window.frame.height - window.contentLayoutRect.height)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let recipientLabel = NSTextField(labelWithString: L("Recipient"))
        recipientLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        recipientLabel.setContentHuggingPriority(.required, for: .horizontal)

        for recipient in recipients {
            let item = NSMenuItem(title: recipient.title, action: nil, keyEquivalent: "")
            item.representedObject = recipient.login
            recipientPopup.menu?.addItem(item)
        }
        recipientPopup.selectItem(at: recipients.isEmpty ? -1 : 0)
        recipientPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let recipientRow = NSStackView(views: [recipientLabel, recipientPopup])
        recipientRow.orientation = .horizontal
        recipientRow.alignment = .centerY
        recipientRow.spacing = 12
        recipientRow.translatesAutoresizingMaskIntoConstraints = false

        let messageLabel = NSTextField(labelWithString: L("Message"))
        messageLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        messageLabel.setContentHuggingPriority(.required, for: .horizontal)

        messageView.isRichText = false
        messageView.allowsUndo = true
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        messageView.isAutomaticDashSubstitutionEnabled = false
        messageView.isAutomaticLinkDetectionEnabled = true
        messageView.useCarrachoLinkAppearance()
        messageView.font = .systemFont(ofSize: 13)
        messageView.textContainerInset = NSSize(width: 9, height: 9)
        messageView.isVerticallyResizable = true
        messageView.isHorizontallyResizable = false
        messageView.autoresizingMask = [.width]
        messageView.textContainer?.widthTracksTextView = true
        messageView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let emoji = EmojiPickerButton(editor: messageView)
        let clear = ClearEditorButton(editor: messageView)
        let messageHeader = NSStackView(views: [messageLabel, NSView(), emoji, clear])
        messageHeader.orientation = .horizontal
        messageHeader.alignment = .centerY
        messageHeader.spacing = 8
        messageHeader.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = messageView

        validationLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        validationLabel.textColor = .systemRed
        validationLabel.lineBreakMode = .byTruncatingTail
        validationLabel.isHidden = true
        validationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true

        let send = NSButton(title: L("Send"), target: self, action: #selector(sendPressed(_:)))
        send.keyEquivalent = "\r"
        send.keyEquivalentModifierMask = [.command]
        CarrachoTheme.applyPrimaryButtonStyle(send)
        send.toolTip = L("Send offline message (⌘Return)")
        send.widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true

        let bottomRow = NSStackView(views: [validationLabel, NSView(), cancel, send])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 10
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(recipientRow)
        root.addSubview(messageHeader)
        root.addSubview(scroll)
        root.addSubview(bottomRow)
        NSLayoutConstraint.activate([
            recipientRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            recipientRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            recipientRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            recipientPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),

            messageHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            messageHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            messageHeader.topAnchor.constraint(equalTo: recipientRow.bottomAnchor, constant: 14),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: messageHeader.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -14),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),

            bottomRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            bottomRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            bottomRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func beginSheet(for parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self.messageView)
        }
    }

    @objc func sendPressed(_ sender: Any?) {
        guard let login = recipientPopup.selectedItem?.representedObject as? Data else {
            showValidation(L("Select a recipient."))
            return
        }
        let message = messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipientName = recipientPopup.selectedItem?.title ?? L("Recipient")
        if let error = onSend?(login, recipientName, message) {
            showValidation(error)
            return
        }
        dismiss()
    }

    @objc func cancelPressed(_ sender: Any?) {
        dismiss()
    }

    func showValidation(_ text: String) {
        validationLabel.stringValue = text
        validationLabel.isHidden = false
        NSSound.beep()
    }

    func dismiss() {
        guard !didFinish else { return }
        didFinish = true
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window?.orderOut(nil)
        }
        onFinish?()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFinish else { return }
        didFinish = true
        onFinish?()
    }
}

final class FlatNewsWindowController: NSWindowController, NSWindowDelegate {
    static let widthDefaultsKey = "Carracho.FlatNewsWindowWidth.v1"
    static let heightDefaultsKey = "Carracho.FlatNewsWindowHeight.v1"
    static let defaultContentSize = NSSize(width: 760, height: 650)
    static let minimumContentSize = NSSize(width: 560, height: 470)

    let streamView = NSTextView()
    let streamScroll = NSScrollView()
    let editorView = NSTextView()
    let editorScroll = NSScrollView()
    let validationLabel = NSTextField(wrappingLabelWithString: "")
    let postButton = NSButton(title: L("Post"), target: nil, action: nil)
    let deleteButton = NSButton(title: L("Delete"), target: nil, action: nil)
    let clearButton = NSButton(title: L("Clear All"), target: nil, action: nil)
    let closeButton = NSButton(title: L("Close"), target: nil, action: nil)
    var streamMinimumHeightConstraint: NSLayoutConstraint!
    var streamEditorBalanceConstraint: NSLayoutConstraint!
    var items: [Data] = []
    var didFinish = false
    let fontSize: CGFloat

    var onPost: ((Data, @escaping (Result<Void, Error>) -> Void) -> Void)?
    var onDelete: ((Int, NSWindow) -> Void)?
    var onClear: ((NSWindow) -> Void)?
    var onFinish: (() -> Void)?

    init(items: [Data], fontSize: CGFloat) {
        self.fontSize = fontSize
        let defaults = UserDefaults.standard
        let savedWidth = defaults.double(forKey: Self.widthDefaultsKey)
        let savedHeight = defaults.double(forKey: Self.heightDefaultsKey)
        let width = max(Self.minimumContentSize.width, savedWidth > 0 ? savedWidth : Self.defaultContentSize.width)
        let height = max(Self.minimumContentSize.height, savedHeight > 0 ? savedHeight : Self.defaultContentSize.height)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: width, height: height)),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("Flat News")
        window.minSize = NSSize(width: Self.minimumContentSize.width,
                                height: Self.minimumContentSize.height + window.frame.height - window.contentLayoutRect.height)
        window.isReleasedWhenClosed = false
        window.backgroundColor = CarrachoTheme.canvas
        super.init(window: window)
        window.delegate = self

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.backgroundColor = CarrachoTheme.canvas.cgColor
        window.contentView = root

        let subtitle = NSTextField(labelWithString: L("Classic flat-news / spam stream"))
        subtitle.font = .systemFont(ofSize: 13, weight: .medium)
        subtitle.textColor = CarrachoTheme.secondaryText
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        streamView.isEditable = false
        streamView.isSelectable = true
        streamView.isRichText = true
        streamView.isAutomaticLinkDetectionEnabled = true
        streamView.useCarrachoLinkAppearance()
        streamView.font = .systemFont(ofSize: fontSize)
        streamView.textContainerInset = NSSize(width: 10, height: 10)
        streamView.isVerticallyResizable = true
        streamView.isHorizontallyResizable = false
        streamView.autoresizingMask = [.width]
        streamView.textContainer?.widthTracksTextView = true
        streamView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        streamScroll.translatesAutoresizingMaskIntoConstraints = false
        streamScroll.hasVerticalScroller = true
        streamScroll.hasHorizontalScroller = false
        streamScroll.autohidesScrollers = true
        streamScroll.borderType = .bezelBorder
        streamScroll.documentView = streamView

        let composerLabel = NSTextField(labelWithString: L("New Flat News"))
        composerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        composerLabel.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString: CarrachoHTMLText.editorHint)
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = CarrachoTheme.secondaryText
        hint.maximumNumberOfLines = 2
        hint.translatesAutoresizingMaskIntoConstraints = false

        editorView.isEditable = true
        editorView.isSelectable = true
        editorView.isRichText = false
        editorView.allowsUndo = true
        editorView.isAutomaticQuoteSubstitutionEnabled = false
        editorView.isAutomaticDashSubstitutionEnabled = false
        editorView.font = .systemFont(ofSize: fontSize)
        editorView.textContainerInset = NSSize(width: 10, height: 10)
        editorView.isVerticallyResizable = true
        editorView.isHorizontallyResizable = false
        editorView.autoresizingMask = [.width]
        editorView.textContainer?.widthTracksTextView = true
        editorView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        editorScroll.translatesAutoresizingMaskIntoConstraints = false
        editorScroll.hasVerticalScroller = true
        editorScroll.hasHorizontalScroller = false
        editorScroll.autohidesScrollers = true
        editorScroll.borderType = .bezelBorder
        editorScroll.documentView = editorView

        validationLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        validationLabel.textColor = .systemRed
        validationLabel.maximumNumberOfLines = 3
        validationLabel.isHidden = true
        validationLabel.translatesAutoresizingMaskIntoConstraints = false

        postButton.target = self
        postButton.action = #selector(postPressed(_:))
        CarrachoTheme.applyPrimaryButtonStyle(postButton)
        postButton.keyEquivalent = "\r"
        postButton.keyEquivalentModifierMask = [.command]
        postButton.toolTip = L("Post Flat News (⌘Return)")

        deleteButton.target = self
        deleteButton.action = #selector(deletePressed(_:))
        deleteButton.bezelStyle = .rounded

        clearButton.target = self
        clearButton.action = #selector(clearPressed(_:))
        clearButton.bezelStyle = .rounded

        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let emoji = EmojiPickerButton(editor: editorView)
        let buttons = NSStackView(views: [emoji, spacer, postButton, deleteButton, clearButton, closeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        [postButton, deleteButton, clearButton, closeButton].forEach {
            $0.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
        }

        let stack = NSStackView(views: [subtitle, streamScroll, composerLabel, hint, editorScroll, validationLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(12, after: subtitle)
        stack.setCustomSpacing(14, after: streamScroll)
        stack.setCustomSpacing(4, after: composerLabel)
        stack.setCustomSpacing(7, after: hint)
        stack.setCustomSpacing(8, after: editorScroll)
        stack.setCustomSpacing(12, after: validationLabel)
        root.addSubview(stack)

        streamMinimumHeightConstraint = streamScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 185)
        streamEditorBalanceConstraint = streamScroll.heightAnchor.constraint(equalTo: editorScroll.heightAnchor, multiplier: 1.15)
        streamEditorBalanceConstraint.priority = .defaultLow

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            streamScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            composerLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            editorScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            validationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),

            editorScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 155),
        ])

        update(items: items)
    }

    required init?(coder: NSCoder) { nil }

    func update(items: [Data]) {
        self.items = items
        window?.title = LF("Flat News (%@)", String(items.count))
        let rendered = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            rendered.append(NSAttributedString(
                string: "[\(index + 1)]\n",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: max(9, fontSize - 2), weight: .semibold),
                    .foregroundColor: CarrachoTheme.secondaryText,
                ]
            ))
            rendered.append(CarrachoHTMLText.attributedString(fromWire: item, baseFont: .systemFont(ofSize: fontSize)))
            if index + 1 < items.count { rendered.append(NSAttributedString(string: "\n\n")) }
        }
        streamView.textStorage?.setAttributedString(rendered)
        let hasItems = !items.isEmpty
        streamScroll.isHidden = !hasItems
        streamMinimumHeightConstraint.isActive = hasItems
        streamEditorBalanceConstraint.isActive = hasItems
        deleteButton.isEnabled = hasItems
        clearButton.isEnabled = hasItems
    }

    func show(relativeTo parent: NSWindow?) {
        guard let window else { return }
        if !window.isVisible {
            if let parent {
                let parentFrame = parent.frame
                let size = window.frame.size
                window.setFrameOrigin(NSPoint(x: parentFrame.midX - size.width / 2,
                                              y: parentFrame.midY - size.height / 2))
            } else {
                window.center()
            }
        }
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self.editorView)
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let size = window?.contentView?.bounds.size,
              size.width >= Self.minimumContentSize.width,
              size.height >= Self.minimumContentSize.height else { return }
        UserDefaults.standard.set(Double(size.width), forKey: Self.widthDefaultsKey)
        UserDefaults.standard.set(Double(size.height), forKey: Self.heightDefaultsKey)
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFinish else { return }
        didFinish = true
        onFinish?()
    }

    @objc func postPressed(_ sender: Any?) {
        let message = editorView.string
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showValidation(L("Please enter text for Flat News."))
            return
        }
        let data: Data
        do {
            data = try CarrachoTextWire.encode(message, maximumBytes: Int(UInt16.max))
        } catch {
            showValidation(L("Flat News may contain at most 65535 bytes."))
            return
        }
        guard let onPost else { return }
        validationLabel.isHidden = true
        postButton.isEnabled = false
        onPost(data) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.postButton.isEnabled = true
                switch result {
                case .success:
                    self.editorView.string = ""
                    self.validationLabel.isHidden = true
                    self.window?.makeFirstResponder(self.editorView)
                case let .failure(error):
                    self.showValidation(LF("Flat News could not be posted: %@", error.localizedDescription))
                }
            }
        }
    }

    @objc func deletePressed(_ sender: Any?) {
        guard !items.isEmpty, let window else { return }
        onDelete?(items.count, window)
    }

    @objc func clearPressed(_ sender: Any?) {
        guard !items.isEmpty, let window else { return }
        onClear?(window)
    }

    @objc func closePressed(_ sender: Any?) {
        window?.close()
    }

    func showValidation(_ text: String) {
        validationLabel.stringValue = text
        validationLabel.isHidden = false
        window?.makeFirstResponder(editorView)
        NSSound.beep()
    }
}
