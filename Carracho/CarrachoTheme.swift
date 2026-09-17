import Cocoa

enum CarrachoTheme {
    static let workspaceHeaderHeight: CGFloat = 45

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func cardColor(for appearance: NSAppearance) -> NSColor {
        isDark(appearance)
            ? NSColor(calibratedRed: 0.115, green: 0.118, blue: 0.140, alpha: 1)
            : .white
    }

    static func selectionColor(for appearance: NSAppearance) -> NSColor {
        isDark(appearance)
            ? NSColor(calibratedRed: 0.460, green: 0.390, blue: 0.945, alpha: 1)
            : NSColor(calibratedRed: 0.405, green: 0.337, blue: 0.865, alpha: 1)
    }

    private static func adaptive(_ name: String,
                                 light: @escaping () -> NSColor,
                                 dark: @escaping () -> NSColor) -> NSColor {
        NSColor(name: NSColor.Name("Carracho.\(name)")) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark() : light()
        }
    }

    static var sidebar: NSColor {
        adaptive("sidebar",
                 light: { NSColor(calibratedRed: 0.922, green: 0.920, blue: 0.975, alpha: 1) },
                 dark: { NSColor(calibratedRed: 0.105, green: 0.105, blue: 0.145, alpha: 1) })
    }

    static var sidebarSecondary: NSColor {
        adaptive("sidebarSecondary",
                 light: { NSColor(calibratedRed: 0.875, green: 0.868, blue: 0.955, alpha: 1) },
                 dark: { NSColor(calibratedRed: 0.145, green: 0.140, blue: 0.205, alpha: 1) })
    }

    static var selection: NSColor {
        adaptive("selection",
                 light: { NSColor(calibratedRed: 0.405, green: 0.337, blue: 0.865, alpha: 1) },
                 dark: { NSColor(calibratedRed: 0.460, green: 0.390, blue: 0.945, alpha: 1) })
    }

    static var selectionSoft: NSColor {
        adaptive("selectionSoft",
                 light: { NSColor(calibratedRed: 0.932, green: 0.920, blue: 0.990, alpha: 1) },
                 dark: { NSColor(calibratedRed: 0.190, green: 0.170, blue: 0.285, alpha: 1) })
    }

    static var canvas: NSColor {
        adaptive("canvas",
                 light: { NSColor(calibratedRed: 0.965, green: 0.969, blue: 0.982, alpha: 1) },
                 dark: { NSColor(calibratedRed: 0.075, green: 0.078, blue: 0.095, alpha: 1) })
    }

    static var card: NSColor {
        adaptive("card",
                 light: { .white },
                 dark: { NSColor(calibratedRed: 0.115, green: 0.118, blue: 0.140, alpha: 1) })
    }

    static var elevatedCard: NSColor {
        adaptive("elevatedCard",
                 light: { NSColor(calibratedWhite: 0.992, alpha: 1) },
                 dark: { NSColor(calibratedRed: 0.145, green: 0.148, blue: 0.175, alpha: 1) })
    }

    static var hairline: NSColor { NSColor.separatorColor }
    static var secondaryText: NSColor { NSColor.secondaryLabelColor }
    static var tertiaryText: NSColor { NSColor.tertiaryLabelColor }
    static var accent: NSColor { selection }
    /// Primary action buttons intentionally use a fixed macOS blue instead of the app's
    /// lavender selection colour or the user's system Accent Color. This keeps CTAs visually
    /// consistent across windows while selection/highlight styling remains unchanged.
    static var primaryAction: NSColor { NSColor.systemBlue }
    static var success: NSColor { NSColor.systemGreen }
    static var warning: NSColor { NSColor.systemOrange }
    static var tableBackground: NSColor { card }

    static var stripedRowBackground: NSColor {
        adaptive("stripedRowBackground",
                 light: { .white },
                 dark: { NSColor(calibratedRed: 0.108, green: 0.110, blue: 0.125, alpha: 1) })
    }

    static var stripedRowAlternateBackground: NSColor {
        adaptive("stripedRowAlternateBackground",
                 light: { NSColor(calibratedWhite: 0.955, alpha: 1) },
                 dark: { NSColor(calibratedRed: 0.145, green: 0.146, blue: 0.158, alpha: 1) })
    }

    static var userRowBackground: NSColor {
        adaptive("userRowBackground",
                 light: { NSColor(calibratedWhite: 0.955, alpha: 1) },
                 dark: { NSColor(calibratedWhite: 0.185, alpha: 1) })
    }

    static var userRowAlternateBackground: NSColor {
        adaptive("userRowAlternateBackground",
                 light: { NSColor(calibratedWhite: 0.925, alpha: 1) },
                 dark: { NSColor(calibratedWhite: 0.225, alpha: 1) })
    }

    static func applyCardStyle(_ view: NSView, radius: CGFloat = 10) {
        view.wantsLayer = true
        view.layer?.backgroundColor = cardColor(for: view.effectiveAppearance).cgColor
        view.layer?.cornerRadius = radius
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.layer?.borderWidth = 1
    }

    static func applyPrimaryButtonStyle(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.bezelColor = primaryAction
        button.contentTintColor = .white
        setPrimaryButtonImageWhite(button)
        setPrimaryButtonTitle(button, button.title)
    }

    private static func setPrimaryButtonImageWhite(_ button: NSButton) {
        if let image = button.image {
            button.image = whitePrimaryButtonImage(from: image)
        }
        if let image = button.alternateImage {
            button.alternateImage = whitePrimaryButtonImage(from: image)
        }
        button.contentTintColor = .white
    }

    private static func whitePrimaryButtonImage(from source: NSImage) -> NSImage {
        let size = source.size
        guard size.width > 0, size.height > 0 else { return source }

        let result = NSImage(size: size)
        result.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: size),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill(using: .sourceIn)
        result.unlockFocus()
        // Keep the baked white pixels. Template images would let NSButton recolour it again.
        result.isTemplate = false
        return result
    }

    /// NSButton's contentTintColor reliably tints template images, but AppKit may still draw the
    /// title with controlTextColor. Rebuild the attributed title after every title change so the
    /// label stays white on the blue primary-action bezel.
    static func setPrimaryButtonTitle(_ button: NSButton, _ title: String) {
        button.title = title
        let attributed = NSMutableAttributedString(attributedString: button.attributedTitle)
        if attributed.string != title {
            attributed.mutableString.setString(title)
        }
        if attributed.length > 0 {
            attributed.addAttribute(.foregroundColor,
                                    value: NSColor.white,
                                    range: NSRange(location: 0, length: attributed.length))
        }
        button.attributedTitle = attributed
    }

    static func applySidebarButtonStyle(_ button: NSButton, selected: Bool) {
        (button as? CarrachoSidebarButton)?.sidebarSelected = selected
        button.isBordered = false
        button.alignment = .left
        button.imagePosition = .imageLeading
        button.font = NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium)
        button.contentTintColor = selected ? .white : .labelColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.backgroundColor = selected
            ? selectionColor(for: button.effectiveAppearance).cgColor
            : NSColor.clear.cgColor
    }
}

final class CarrachoUserTableRowView: NSTableRowView {
    var alternate = false { didSet { needsDisplay = true } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // User rows should blend into the inspector surface. Selection highlighting is still
        // drawn by NSTableRowView, but unselected users no longer get individual gray tiles.
        NSColor.clear.setFill()
        dirtyRect.intersection(bounds).fill()
    }
}

final class CarrachoStripedTableRowView: NSTableRowView {
    var alternate = false { didSet { needsDisplay = true } }
    var rowTintColor: NSColor? { didSet { needsDisplay = true } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let base = alternate ? CarrachoTheme.stripedRowAlternateBackground : CarrachoTheme.stripedRowBackground
        base.setFill()
        dirtyRect.intersection(bounds).fill()
        if let rowTintColor {
            rowTintColor.setFill()
            dirtyRect.intersection(bounds).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 4, dy: 2)
        CarrachoTheme.selectionSoft.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }
}

final class CarrachoNewsTableRowView: NSTableRowView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 4, dy: 2)
        CarrachoTheme.selectionSoft.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }
}

final class CarrachoBackgroundView: NSView {
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        // AppKit can invalidate outside a view's bounds when clipping is off.
        // Painting dirtyRect directly lets small backgrounds cover sibling views.
        dirtyRect.intersection(bounds).fill()
    }
}

final class CarrachoCardView: NSView {
    var cornerRadius: CGFloat = 10
    var fillColor: NSColor = CarrachoTheme.card { didSet { refreshColors() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        refreshColors()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        refreshColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        guard let layer else { return }
        if #available(macOS 11.0, *) { effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = fillColor.cgColor
            layer.borderColor = CarrachoTheme.hairline.withAlphaComponent(0.55).cgColor
        } } else {
            layer.backgroundColor = fillColor.cgColor
            layer.borderColor = CarrachoTheme.hairline.cgColor
        }
        layer.cornerRadius = cornerRadius
        layer.borderWidth = 1
        layer.masksToBounds = true
    }
}

final class CarrachoFlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class CarrachoDividerView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        CarrachoTheme.hairline.setFill()
        dirtyRect.intersection(bounds).fill()
    }
}


/// Horizontal split view used for vertically stacked client cards. The wider divider is
/// intentionally visible as a grab handle, while NSSplitView's autosave support persists
/// each workspace's pane heights in UserDefaults across launches.
final class CarrachoResizableSplitView: NSSplitView, NSSplitViewDelegate {
    private let initialFractions: [CGFloat]
    private let minimumPaneHeights: [CGFloat]
    private let layoutDefaultsKey: String
    private var isInstallingPanes = false

    init(layoutName: String, initialFractions: [CGFloat], minimumPaneHeights: [CGFloat]) {
        self.initialFractions = initialFractions
        self.minimumPaneHeights = minimumPaneHeights
        self.layoutDefaultsKey = "Carracho.SplitLayout.\(layoutName)"
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        isVertical = false
        dividerStyle = .thin
        arrangesAllSubviews = true
        delegate = self
        toolTip = L("Drag the handle to resize these panels")
    }

    required init?(coder: NSCoder) {
        initialFractions = []
        minimumPaneHeights = []
        layoutDefaultsKey = ""
        super.init(coder: coder)
        isVertical = false
        dividerStyle = .thin
        arrangesAllSubviews = true
        delegate = self
    }

    override var dividerThickness: CGFloat { 12 }

    func installPanes(_ panes: [NSView]) {
        guard !panes.isEmpty else { return }
        isInstallingPanes = true
        defer { isInstallingPanes = false }

        for pane in arrangedSubviews { pane.removeFromSuperview() }
        let fractions = restoredFractions(count: panes.count) ?? normalized(initialFractions, count: panes.count)
        let availableHeight = max(1, frame.height - dividerThickness * CGFloat(max(0, panes.count - 1)))
        var originY: CGFloat = 0
        for (index, pane) in panes.enumerated() {
            let height = availableHeight * fractions[index]
            pane.translatesAutoresizingMaskIntoConstraints = true
            pane.frame = NSRect(x: 0, y: originY, width: frame.width, height: height)
            addArrangedSubview(pane)
            originY += height + dividerThickness
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func drawDivider(in rect: NSRect) {
        let line = NSRect(x: rect.minX + 6, y: rect.midY - 0.5,
                          width: max(0, rect.width - 12), height: 1)
        CarrachoTheme.hairline.withAlphaComponent(0.7).setFill()
        line.fill()

        let gripWidth: CGFloat = min(38, max(20, rect.width * 0.08))
        let grip = NSRect(x: rect.midX - gripWidth / 2, y: rect.midY - 2,
                          width: gripWidth, height: 4)
        CarrachoTheme.secondaryText.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isInstallingPanes, arrangedSubviews.count == initialFractions.count else { return }
        let heights = arrangedSubviews.map { max(0, $0.frame.height) }
        let total = heights.reduce(0, +)
        guard total > 1 else { return }
        UserDefaults.standard.set(heights.map { Double($0 / total) }, forKey: layoutDefaultsKey)
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard minimumPaneHeights.count == arrangedSubviews.count,
              dividerIndex >= 0, dividerIndex + 1 < arrangedSubviews.count else {
            return proposedPosition
        }
        let upper = arrangedSubviews[dividerIndex]
        let lower = arrangedSubviews[dividerIndex + 1]
        let minimum = upper.frame.minY + minimumPaneHeights[dividerIndex]
        let maximum = lower.frame.maxY - dividerThickness - minimumPaneHeights[dividerIndex + 1]
        guard minimum <= maximum else { return proposedPosition }
        return min(max(proposedPosition, minimum), maximum)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    private func restoredFractions(count: Int) -> [CGFloat]? {
        guard let values = UserDefaults.standard.array(forKey: layoutDefaultsKey) as? [NSNumber],
              values.count == count else { return nil }
        let fractions = values.map { CGFloat($0.doubleValue) }
        guard fractions.allSatisfy({ $0 > 0 }), fractions.reduce(0, +) > 0 else { return nil }
        return normalized(fractions, count: count)
    }

    private func normalized(_ values: [CGFloat], count: Int) -> [CGFloat] {
        guard values.count == count, values.allSatisfy({ $0 > 0 }) else {
            return Array(repeating: 1 / CGFloat(max(1, count)), count: count)
        }
        let total = values.reduce(0, +)
        guard total > 0 else { return Array(repeating: 1 / CGFloat(max(1, count)), count: count) }
        return values.map { $0 / total }
    }
}


/// Side-by-side shell split used for the navigation sidebar and the right inspector.
/// This intentionally does not use NSSplitView. The application nests the right column inside
/// an Auto Layout workspace, and NSSplitView can treat the current fitted pane widths as fixed,
/// making even setPosition(_:ofDividerAt:) a no-op. These two shell dividers are simple frame-
/// based columns instead: Auto Layout sizes this container, and this view alone owns its panes.
final class CarrachoResizableColumnSplitView: NSView {
    enum Edge { case leading, trailing }

    private final class DividerHitView: NSView {
        weak var owner: CarrachoResizableColumnSplitView?

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            owner?.trackDivider(with: event)
        }
    }

    private let edge: Edge
    private let initialEdgeWidth: CGFloat
    private let minimumPaneWidths: [CGFloat]
    private let layoutDefaultsKey: String
    private let collapsedDefaultsKey: String
    private let visualDividerThickness: CGFloat = 1
    private let dividerHitWidth: CGFloat = 11
    private let dividerHitView = DividerHitView()
    private var panes: [NSView] = []
    private var edgeWidth: CGFloat
    private(set) var isEdgeCollapsed = false

    init(layoutName: String, edge: Edge, initialEdgeWidth: CGFloat, minimumPaneWidths: [CGFloat]) {
        self.edge = edge
        self.initialEdgeWidth = initialEdgeWidth
        self.minimumPaneWidths = minimumPaneWidths
        self.layoutDefaultsKey = "Carracho.ColumnLayout.\(layoutName).edgeWidth"
        self.collapsedDefaultsKey = "Carracho.ColumnLayout.\(layoutName).collapsed"
        self.edgeWidth = initialEdgeWidth
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        dividerHitView.owner = self
        toolTip = L("Drag the divider to resize this column")
    }

    required init?(coder: NSCoder) {
        edge = .leading
        initialEdgeWidth = 236
        minimumPaneWidths = []
        layoutDefaultsKey = ""
        collapsedDefaultsKey = ""
        edgeWidth = 236
        super.init(coder: coder)
        dividerHitView.owner = self
        toolTip = L("Drag the divider to resize this column")
    }

    func installPanes(_ newPanes: [NSView]) {
        guard newPanes.count == 2 else { return }
        panes.forEach { $0.removeFromSuperview() }
        dividerHitView.removeFromSuperview()
        panes = newPanes
        edgeWidth = restoredEdgeWidth() ?? initialEdgeWidth
        if !collapsedDefaultsKey.isEmpty, UserDefaults.standard.object(forKey: collapsedDefaultsKey) != nil {
            isEdgeCollapsed = UserDefaults.standard.bool(forKey: collapsedDefaultsKey)
        }
        for pane in panes {
            pane.translatesAutoresizingMaskIntoConstraints = true
            pane.autoresizingMask = []
            addSubview(pane)
        }
        dividerHitView.translatesAutoresizingMaskIntoConstraints = true
        dividerHitView.autoresizingMask = []
        addSubview(dividerHitView)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        guard panes.count == 2 else { return }
        let edgeIndex = edge == .leading ? 0 : 1
        let otherIndex = edgeIndex == 0 ? 1 : 0
        if isEdgeCollapsed {
            panes[edgeIndex].isHidden = true
            panes[otherIndex].isHidden = false

            // Keep the hidden pane at a real layout width instead of forcing it to 0. Its
            // descendants still have active Auto Layout constraints while hidden; a zero-width
            // autoresizing constraint therefore conflicts with ordinary leading/trailing insets
            // inside the inspector. Move the hidden pane just outside the visible bounds instead.
            let hiddenWidth = max(edgeWidth, minimumWidth(at: edgeIndex), 1)
            panes[edgeIndex].frame = NSRect(
                x: edge == .leading ? -hiddenWidth : bounds.width,
                y: 0,
                width: hiddenWidth,
                height: bounds.height
            )
            panes[otherIndex].frame = bounds
            dividerHitView.isHidden = true
            needsDisplay = true
            return
        }
        panes[0].isHidden = false
        panes[1].isHidden = false
        dividerHitView.isHidden = false
        let available = max(0, bounds.width - visualDividerThickness)
        let edgeMinimum = minimumWidth(at: edgeIndex)
        let otherMinimum = minimumWidth(at: otherIndex)
        let maximumEdge = max(1, available - otherMinimum)
        if maximumEdge >= edgeMinimum {
            edgeWidth = min(max(edgeWidth, edgeMinimum), maximumEdge)
        } else {
            edgeWidth = min(maximumEdge, max(1, available / 2))
        }

        let leadingWidth = edge == .leading ? edgeWidth : max(0, available - edgeWidth)
        let dividerX = leadingWidth
        let trailingX = dividerX + visualDividerThickness
        let trailingWidth = max(0, bounds.width - trailingX)
        panes[0].frame = NSRect(x: 0, y: 0, width: leadingWidth, height: bounds.height)
        panes[1].frame = NSRect(x: trailingX, y: 0, width: trailingWidth, height: bounds.height)
        dividerHitView.frame = NSRect(x: dividerX - (dividerHitWidth - visualDividerThickness) / 2,
                                      y: 0, width: dividerHitWidth, height: bounds.height)
        window?.invalidateCursorRects(for: dividerHitView)
        needsDisplay = true
    }

    func setEdgeCollapsed(_ collapsed: Bool, persist: Bool = true) {
        guard isEdgeCollapsed != collapsed else { return }
        isEdgeCollapsed = collapsed
        if persist, !collapsedDefaultsKey.isEmpty {
            UserDefaults.standard.set(collapsed, forKey: collapsedDefaultsKey)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func toggleEdgeCollapsed() {
        setEdgeCollapsed(!isEdgeCollapsed)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard panes.count == 2, !isEdgeCollapsed else { return }
        let dividerX = panes[0].frame.maxX
        let line = NSRect(x: dividerX, y: bounds.minY,
                          width: visualDividerThickness, height: bounds.height)
        CarrachoTheme.hairline.withAlphaComponent(0.8).setFill()
        line.fill()
    }

    private func trackDivider(with event: NSEvent) {
        guard !isEdgeCollapsed, panes.count == 2, let window else { return }
        while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if next.type == .leftMouseUp { break }
            let point = convert(next.locationInWindow, from: nil)
            updateDividerPosition(point.x)
        }
        persistEdgeWidth()
    }

    private func updateDividerPosition(_ proposed: CGFloat) {
        guard panes.count == 2 else { return }
        let minimumLeading = minimumWidth(at: 0)
        let maximumLeading = bounds.width - visualDividerThickness - minimumWidth(at: 1)
        let leading: CGFloat
        if maximumLeading >= minimumLeading {
            leading = min(max(proposed, minimumLeading), maximumLeading)
        } else {
            leading = min(max(0, proposed), max(0, bounds.width - visualDividerThickness))
        }
        edgeWidth = edge == .leading
            ? leading
            : max(0, bounds.width - visualDividerThickness - leading)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func persistEdgeWidth() {
        guard !layoutDefaultsKey.isEmpty else { return }
        let edgeIndex = edge == .leading ? 0 : 1
        guard edgeWidth >= min(1, minimumWidth(at: edgeIndex)) else { return }
        UserDefaults.standard.set(Double(edgeWidth), forKey: layoutDefaultsKey)
    }

    private func restoredEdgeWidth() -> CGFloat? {
        guard !layoutDefaultsKey.isEmpty, UserDefaults.standard.object(forKey: layoutDefaultsKey) != nil else { return nil }
        let width = CGFloat(UserDefaults.standard.double(forKey: layoutDefaultsKey))
        return width > 0 ? width : nil
    }

    private func minimumWidth(at index: Int) -> CGFloat {
        guard minimumPaneWidths.indices.contains(index) else { return 1 }
        return max(1, minimumPaneWidths[index])
    }
}

/// A compact, vector mark that stays sharp in the sidebar and server header.
final class CarrachoSidebarButton: NSButton {
    var sidebarSelected = false
    /// Adds the crossed-envelope mark used by Offline Messages without baking in a fixed color.
    var showsOfflineSlash = false { didSet { needsDisplay = true } }
    /// A separate disclosure mark keeps expandable rows aligned with the other sidebar icons.
    var disclosureImage: NSImage? { didSet { needsDisplay = true } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CarrachoTheme.applySidebarButtonStyle(self, selected: sidebarSelected)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = contentTintColor ?? .labelColor
        var icon = image
        if #available(macOS 12.0, *) { icon = image?.withSymbolConfiguration(.init(paletteColors: [color])) }
        let hasDisclosure = disclosureImage != nil
        if var disclosure = disclosureImage {
            if #available(macOS 12.0, *) {
                disclosure = disclosure.withSymbolConfiguration(.init(paletteColors: [color])) ?? disclosure
            }
            let scale = min(10 / max(disclosure.size.width, 1), 10 / max(disclosure.size.height, 1))
            let size = NSSize(width: disclosure.size.width * scale, height: disclosure.size.height * scale)
            // The leading edge matches the house icon in the Overview row (12 pt).
            disclosure.draw(in: NSRect(x: 12, y: (bounds.height - size.height) / 2,
                                       width: size.width, height: size.height))
        }
        let iconRect = NSRect(x: hasDisclosure ? 28 : 12, y: (bounds.height - 18) / 2, width: 18, height: 18)
        icon?.draw(in: iconRect)
        if showsOfflineSlash {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: iconRect.minX + 3, y: iconRect.maxY - 2.5))
            slash.line(to: NSPoint(x: iconRect.maxX - 2.5, y: iconRect.minY + 2.5))
            slash.lineWidth = 1.8
            slash.lineCapStyle = .round
            color.setStroke()
            slash.stroke()
        }
        let titleX: CGFloat = hasDisclosure ? 60 : 44
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: color]
        (title as NSString).draw(in: NSRect(x: titleX, y: (bounds.height - 17) / 2, width: max(0, bounds.width - titleX - 8), height: 17), withAttributes: attributes)
    }
}

final class CarrachoToolbarButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let color = isHighlighted ? CarrachoTheme.accent : CarrachoTheme.secondaryText
        var icon = image
        if #available(macOS 12.0, *) { icon = image?.withSymbolConfiguration(.init(paletteColors: [color])) }
        icon?.draw(in: NSRect(x: (bounds.width - 21) / 2, y: 22, width: 21, height: 21))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        (title as NSString).draw(in: NSRect(x: 0, y: 1, width: bounds.width, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: color, .paragraphStyle: paragraph,
        ])
    }
}
