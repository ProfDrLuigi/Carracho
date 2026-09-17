#if CARRACHO_SERVER
import AppKit
import Foundation
import Sparkle
import UniformTypeIdentifiers

private func setServerPrimaryButtonTitle(_ button: NSButton, _ title: String) {
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

private func applyServerPrimaryButtonStyle(_ button: NSButton) {
    button.bezelStyle = .rounded
    button.bezelColor = .systemBlue
    button.contentTintColor = .white
    setServerPrimaryButtonTitle(button, button.title)
}

private enum CarrachoServerPresentationPreferences {
    static let menuBarIconEnabledKey = "Carracho.ServerApp.MenuBarIconEnabled.v1"
    static let hideDockIconKey = "Carracho.ServerApp.HideDockIcon.v1"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            menuBarIconEnabledKey: false,
            hideDockIconKey: false,
        ])
    }

    static var menuBarIconEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: menuBarIconEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: menuBarIconEnabledKey)
            if !newValue { UserDefaults.standard.set(false, forKey: hideDockIconKey) }
        }
    }

    static var hideDockIcon: Bool {
        get { menuBarIconEnabled && UserDefaults.standard.bool(forKey: hideDockIconKey) }
        set { UserDefaults.standard.set(menuBarIconEnabled && newValue, forKey: hideDockIconKey) }
    }
}

private struct CarrachoServerMenuBarSnapshot {
    var statusTitle: String
    var statusDetail: String
    var connections: String
    var transfers: String
    var ports: String
    var serverRunning: Bool
    var canToggleServer: Bool
    var trackerRunning: Bool
    var trackerStatus: String
    var canToggleTracker: Bool
}

@main
enum CarrachoServerApplication {
    static func main() {
        CarrachoServerPresentationPreferences.registerDefaults()
        if let daemonKind = CarrachoDaemonEntryPoint.requestedKind() {
            exit(CarrachoDaemonEntryPoint.run(kind: daemonKind))
        }
        let application = NSApplication.shared
        let delegate = CarrachoServerAppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}

private final class ServerFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class ServerCardView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill = dark
            ? NSColor(calibratedRed: 0.115, green: 0.118, blue: 0.140, alpha: 0.72)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.82)
        fill.setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private final class ServerResponsiveStatusView: NSView {
    private let identity: NSView
    private let metrics: NSView
    private let action: NSView
    private let collapseWidth: CGFloat = 700
    private var compact: Bool?
    private var wideConstraints: [NSLayoutConstraint] = []
    private var compactConstraints: [NSLayoutConstraint] = []

    init(identity: NSView, metrics: NSView, action: NSView) {
        self.identity = identity
        self.metrics = metrics
        self.action = action
        super.init(frame: .zero)
        for view in [identity, metrics, action] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        wideConstraints = [
            identity.leadingAnchor.constraint(equalTo: leadingAnchor),
            identity.topAnchor.constraint(equalTo: topAnchor),
            identity.bottomAnchor.constraint(equalTo: bottomAnchor),
            metrics.leadingAnchor.constraint(equalTo: identity.trailingAnchor, constant: 24),
            metrics.centerYAnchor.constraint(equalTo: identity.centerYAnchor),
            action.trailingAnchor.constraint(equalTo: trailingAnchor),
            action.centerYAnchor.constraint(equalTo: identity.centerYAnchor),
            metrics.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -24),
        ]
        compactConstraints = [
            identity.leadingAnchor.constraint(equalTo: leadingAnchor),
            identity.trailingAnchor.constraint(equalTo: trailingAnchor),
            identity.topAnchor.constraint(equalTo: topAnchor),
            metrics.leadingAnchor.constraint(equalTo: leadingAnchor),
            metrics.topAnchor.constraint(equalTo: identity.bottomAnchor, constant: 8),
            metrics.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            action.leadingAnchor.constraint(equalTo: leadingAnchor),
            action.topAnchor.constraint(equalTo: metrics.bottomAnchor, constant: 8),
            action.bottomAnchor.constraint(equalTo: bottomAnchor),
            action.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ]
        NSLayoutConstraint.activate(compactConstraints)
        compact = true
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        let shouldCompact = bounds.width < collapseWidth
        if compact != shouldCompact {
            compact = shouldCompact
            if shouldCompact {
                NSLayoutConstraint.deactivate(wideConstraints)
                NSLayoutConstraint.activate(compactConstraints)
            } else {
                NSLayoutConstraint.deactivate(compactConstraints)
                NSLayoutConstraint.activate(wideConstraints)
            }
        }
        super.layout()
    }
}

/// Two-column server settings layout that collapses to one column when the window gets narrow.
private final class ServerResponsiveColumnsView: NSView {
    private let leftColumn: NSStackView
    private let rightColumn: NSStackView
    private var compact: Bool?
    private let collapseWidth: CGFloat = 700
    private var wideConstraints: [NSLayoutConstraint] = []
    private var compactConstraints: [NSLayoutConstraint] = []

    init(left: [NSView], right: [NSView]) {
        leftColumn = NSStackView(views: left)
        rightColumn = NSStackView(views: right)
        super.init(frame: .zero)

        for (column, views) in [(leftColumn, left), (rightColumn, right)] {
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 12
            column.translatesAutoresizingMaskIntoConstraints = false
            addSubview(column)
            for view in views {
                view.translatesAutoresizingMaskIntoConstraints = false
                view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
        }

        wideConstraints = [
            leftColumn.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftColumn.topAnchor.constraint(equalTo: topAnchor),
            leftColumn.bottomAnchor.constraint(equalTo: bottomAnchor),
            rightColumn.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightColumn.topAnchor.constraint(equalTo: topAnchor),
            rightColumn.bottomAnchor.constraint(equalTo: bottomAnchor),
            rightColumn.leadingAnchor.constraint(equalTo: leftColumn.trailingAnchor, constant: 12),
            leftColumn.widthAnchor.constraint(equalTo: rightColumn.widthAnchor),
        ]
        compactConstraints = [
            leftColumn.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftColumn.trailingAnchor.constraint(equalTo: trailingAnchor),
            leftColumn.topAnchor.constraint(equalTo: topAnchor),
            rightColumn.leadingAnchor.constraint(equalTo: leadingAnchor),
            rightColumn.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightColumn.topAnchor.constraint(equalTo: leftColumn.bottomAnchor, constant: 12),
            rightColumn.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(compactConstraints)
        compact = true
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        let shouldCompact = bounds.width < collapseWidth
        if compact != shouldCompact {
            compact = shouldCompact
            if shouldCompact {
                NSLayoutConstraint.deactivate(wideConstraints)
                NSLayoutConstraint.activate(compactConstraints)
            } else {
                NSLayoutConstraint.deactivate(compactConstraints)
                NSLayoutConstraint.activate(wideConstraints)
            }
        }
        super.layout()
    }
}

final class CarrachoServerAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windowController: CarrachoServerWindowController?
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu(title: L("Carracho Server"))
    private let applicationServerMenu = NSMenu(title: L("Server"))
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let controller = CarrachoServerWindowController()
        windowController = controller
        controller.onPresentationPreferencesChanged = { [weak self] menuBarIconEnabled, hideDockIcon in
            self?.applyPresentationPreferences(menuBarIconEnabled: menuBarIconEnabled,
                                               hideDockIcon: hideDockIcon)
        }
        applyPresentationPreferences(menuBarIconEnabled: CarrachoServerPresentationPreferences.menuBarIconEnabled,
                                     hideDockIcon: CarrachoServerPresentationPreferences.hideDockIcon)
        controller.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func installMainMenu() {
        let main = NSMenu(title: L("Carracho Server"))
        NSApplication.shared.mainMenu = main

        let appItem = NSMenuItem(title: L("Carracho Server"), action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: L("Carracho Server"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let about = NSMenuItem(title: L("About Carracho Server"),
                               action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                               keyEquivalent: "")
        about.target = NSApplication.shared
        appMenu.addItem(about)

        let updates = NSMenuItem(title: L("Check for Update…"),
                                 action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                 keyEquivalent: "")
        updates.target = updaterController
        appMenu.addItem(updates)
        appMenu.addItem(.separator())

        let services = NSMenuItem(title: L("Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: L("Services"))
        services.submenu = servicesMenu
        appMenu.addItem(services)
        NSApplication.shared.servicesMenu = servicesMenu
        appMenu.addItem(.separator())

        let hide = NSMenuItem(title: L("Hide Carracho Server"),
                              action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApplication.shared
        appMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: L("Hide Others"),
                                    action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApplication.shared
        appMenu.addItem(hideOthers)
        let showAll = NSMenuItem(title: L("Show All"),
                                 action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        showAll.target = NSApplication.shared
        appMenu.addItem(showAll)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit Carracho Server"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared
        appMenu.addItem(quit)

        let serverItem = NSMenuItem(title: L("Server"), action: nil, keyEquivalent: "")
        applicationServerMenu.delegate = self
        serverItem.submenu = applicationServerMenu
        main.addItem(serverItem)
        rebuildApplicationServerMenu()

        let editItem = NSMenuItem(title: L("Edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L("Edit"))
        editItem.submenu = editMenu
        main.addItem(editItem)
        editMenu.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Cut"), action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copy"), action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste"), action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All"), action: Selector(("selectAll:")), keyEquivalent: "a")

        let windowItem = NSMenuItem(title: L("Window"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: L("Window"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        let minimize = windowMenu.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        minimize.target = nil
        let zoom = windowMenu.addItem(withTitle: L("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        zoom.target = nil
        windowMenu.addItem(.separator())
        let front = windowMenu.addItem(withTitle: L("Bring All to Front"), action: Selector(("arrangeInFront:")), keyEquivalent: "")
        front.target = NSApplication.shared
        NSApplication.shared.windowsMenu = windowMenu

        let helpItem = NSMenuItem(title: L("Help"), action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: L("Help"))
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        let github = NSMenuItem(title: L("Carracho Server on GitHub"),
                                action: #selector(openServerGitHub(_:)), keyEquivalent: "")
        github.target = self
        helpMenu.addItem(github)
        NSApplication.shared.helpMenu = helpMenu
    }

    private func rebuildApplicationServerMenu() {
        applicationServerMenu.removeAllItems()
        let snapshot = windowController?.menuBarSnapshot()
        let serverRunning = snapshot?.serverRunning == true
        let toggleServer = NSMenuItem(title: serverRunning ? L("Stop Server") : L("Start Server"),
                                      action: #selector(toggleServerFromStatusMenu(_:)), keyEquivalent: "")
        toggleServer.target = self
        toggleServer.isEnabled = snapshot?.canToggleServer ?? (windowController != nil)
        applicationServerMenu.addItem(toggleServer)

        let trackerRunning = snapshot?.trackerRunning == true
        let tracker = NSMenuItem(title: trackerRunning ? L("Stop Tracker") : L("Start Tracker"),
                                 action: #selector(toggleTrackerFromStatusMenu(_:)), keyEquivalent: "")
        tracker.target = self
        tracker.isEnabled = snapshot?.canToggleTracker ?? (windowController != nil)
        applicationServerMenu.addItem(tracker)
        applicationServerMenu.addItem(.separator())

        let windowVisible = windowController?.window?.isVisible == true
        let show = NSMenuItem(title: windowVisible ? L("Hide Server Window") : L("Show Server Window"),
                              action: #selector(toggleServerWindow(_:)), keyEquivalent: "")
        show.target = self
        applicationServerMenu.addItem(show)
    }

    @objc private func openServerGitHub(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/ProfDrLuigi/Carracho") else { return }
        NSWorkspace.shared.open(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !CarrachoServerPresentationPreferences.menuBarIconEnabled
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showServerWindow(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.shutdown()
    }

    private func applyPresentationPreferences(menuBarIconEnabled: Bool, hideDockIcon: Bool) {
        if menuBarIconEnabled {
            installStatusItemIfNeeded()
        } else {
            removeStatusItem()
        }

        let shouldHideDock = menuBarIconEnabled && hideDockIcon
        NSApplication.shared.setActivationPolicy(shouldHideDock ? .accessory : .regular)
        windowController?.syncPresentationPreferences()
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let image = NSImage(named: NSImage.Name("MenuBarServer")) {
                // MenuBarServer contains explicit light/dark appearance variants. Keep it
                // non-template so AppKit uses those assets instead of tinting the artwork.
                image.isTemplate = false
                image.size = NSSize(width: 18, height: 18)
                button.image = image
                button.imageScaling = .scaleProportionallyDown
            }
            button.toolTip = L("Carracho Server")
        }
        statusMenu.delegate = self
        item.menu = statusMenu
        statusItem = item
        rebuildStatusMenu()
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        statusMenu.removeAllItems()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu { rebuildStatusMenu() }
        else if menu === applicationServerMenu { rebuildApplicationServerMenu() }
    }

    private func rebuildStatusMenu() {
        guard CarrachoServerPresentationPreferences.menuBarIconEnabled else { return }
        statusMenu.removeAllItems()
        let snapshot = windowController?.menuBarSnapshot()

        let title = NSMenuItem(title: L("Carracho Server"), action: nil, keyEquivalent: "")
        title.isEnabled = false
        statusMenu.addItem(title)

        if let snapshot {
            let state = NSMenuItem(title: snapshot.statusTitle, action: nil, keyEquivalent: "")
            state.isEnabled = false
            statusMenu.addItem(state)

            if !snapshot.statusDetail.isEmpty {
                let detail = NSMenuItem(title: snapshot.statusDetail, action: nil, keyEquivalent: "")
                detail.isEnabled = false
                statusMenu.addItem(detail)
            }

            let metrics = NSMenuItem(
                title: LF("Connections: %@ · Transfers: %@ · Ports: %@", snapshot.connections, snapshot.transfers, snapshot.ports),
                action: nil,
                keyEquivalent: ""
            )
            metrics.isEnabled = false
            statusMenu.addItem(metrics)
        } else {
            let state = NSMenuItem(title: L("Loading server state…"), action: nil, keyEquivalent: "")
            state.isEnabled = false
            statusMenu.addItem(state)
        }

        statusMenu.addItem(.separator())

        let serverRunning = snapshot?.serverRunning == true
        let toggleServer = NSMenuItem(title: serverRunning ? L("Stop Server") : L("Start Server"),
                                      action: #selector(toggleServerFromStatusMenu(_:)), keyEquivalent: "")
        toggleServer.target = self
        toggleServer.isEnabled = snapshot?.canToggleServer == true
        statusMenu.addItem(toggleServer)

        let trackerRunning = snapshot?.trackerRunning == true
        let tracker = NSMenuItem(title: trackerRunning ? L("Stop Tracker") : L("Start Tracker"),
                                 action: #selector(toggleTrackerFromStatusMenu(_:)), keyEquivalent: "")
        tracker.target = self
        tracker.isEnabled = snapshot?.canToggleTracker == true
        statusMenu.addItem(tracker)
        if let trackerStatus = snapshot?.trackerStatus, !trackerStatus.isEmpty {
            let trackerState = NSMenuItem(title: LF("Tracker: %@", trackerStatus), action: nil, keyEquivalent: "")
            trackerState.isEnabled = false
            statusMenu.addItem(trackerState)
        }

        statusMenu.addItem(.separator())

        let dockHidden = CarrachoServerPresentationPreferences.hideDockIcon
        let windowVisible = windowController?.window?.isVisible == true
        let windowItem = NSMenuItem(
            title: dockHidden ? L("Show Server Window") : (windowVisible ? L("Hide Server Window") : L("Show Server Window")),
            action: dockHidden ? #selector(showServerWindow(_:)) : #selector(toggleServerWindow(_:)),
            keyEquivalent: ""
        )
        windowItem.target = self
        statusMenu.addItem(windowItem)

        let dockItem = NSMenuItem(title: L("Hide Dock Icon"), action: #selector(toggleDockIcon(_:)), keyEquivalent: "")
        dockItem.target = self
        dockItem.state = CarrachoServerPresentationPreferences.hideDockIcon ? .on : .off
        dockItem.isEnabled = CarrachoServerPresentationPreferences.menuBarIconEnabled
        statusMenu.addItem(dockItem)

        statusMenu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit Carracho Server"), action: #selector(quitServerApp(_:)), keyEquivalent: "q")
        quit.target = self
        statusMenu.addItem(quit)
    }

    @objc private func toggleServerFromStatusMenu(_ sender: Any?) {
        windowController?.toggleServerFromMenuBar()
        rebuildStatusMenu()
        rebuildApplicationServerMenu()
    }

    @objc private func toggleTrackerFromStatusMenu(_ sender: Any?) {
        windowController?.toggleTrackerFromMenuBar()
        rebuildStatusMenu()
        rebuildApplicationServerMenu()
    }

    @objc private func toggleServerWindow(_ sender: Any?) {
        if windowController?.window?.isVisible == true {
            windowController?.window?.orderOut(nil)
        } else {
            showServerWindow(sender)
        }
        rebuildStatusMenu()
        rebuildApplicationServerMenu()
    }

    @objc private func showServerWindow(_ sender: Any?) {
        guard let controller = windowController, let window = controller.window else { return }
        if window.isMiniaturized { window.deminiaturize(sender) }
        controller.showWindow(sender)
        // Accessory apps have no Dock icon to reactivate them. Force the existing server
        // window in front without changing the activation policy, so the Dock stays hidden.
        window.orderFrontRegardless()
        window.makeKey()
        NSApplication.shared.activate(ignoringOtherApps: true)
        rebuildStatusMenu()
        rebuildApplicationServerMenu()
    }

    @objc private func toggleDockIcon(_ sender: Any?) {
        guard CarrachoServerPresentationPreferences.menuBarIconEnabled else { return }
        CarrachoServerPresentationPreferences.hideDockIcon.toggle()
        applyPresentationPreferences(menuBarIconEnabled: true,
                                     hideDockIcon: CarrachoServerPresentationPreferences.hideDockIcon)
        rebuildStatusMenu()
    }

    @objc private func quitServerApp(_ sender: Any?) {
        NSApplication.shared.terminate(sender)
    }
}

@MainActor
private final class ServerDisclosureView: NSStackView {
    private let toggle = NSButton()
    private let body: NSView

    init(title: String, content: NSView) {
        body = content
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        toggle.title = title
        toggle.isBordered = false
        toggle.alignment = .left
        toggle.font = .systemFont(ofSize: 12, weight: .medium)
        toggle.target = self
        toggle.action = #selector(toggleContent)
        body.isHidden = true
        addArrangedSubview(toggle)
        addArrangedSubview(body)
        for view in [toggle, body] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        updateIcon()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func toggleContent() {
        body.isHidden.toggle()
        updateIcon()
    }

    private func updateIcon() {
        if #available(macOS 11.0, *) {
            toggle.image = NSImage(systemSymbolName: body.isHidden ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        }
        toggle.imagePosition = .imageLeading
        toggle.setAccessibilityValue(body.isHidden ? L("Collapsed") : L("Expanded"))
    }
}

@MainActor
private final class ServerLogPanel: NSView {
    private let textView = NSTextView()
    private let search = NSSearchField(string: "")
    private let empty = NSTextField(labelWithString: L("No log entries"))
    private let scroll = NSScrollView()
    private var localLines: [String] = []
    private var daemonLines: [String] = []

    init(title: String) {
        super.init(frame: .zero)
        search.placeholderString = L("Filter log")
        search.setAccessibilityLabel(title + " · " + L("Filter log"))
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(filterChanged)
        search.translatesAutoresizingMaskIntoConstraints = false
        search.widthAnchor.constraint(equalToConstant: 200).isActive = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel(title)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 210).isActive = true
        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.addSubview(scroll)
        host.addSubview(empty)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let header = NSStackView(views: [label, NSView(), search])
        header.orientation = .horizontal
        let body = NSStackView(views: [header, host])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.translatesAutoresizingMaskIntoConstraints = false
        let background = ServerCardView()
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        background.addSubview(body)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            body.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
            header.widthAnchor.constraint(equalTo: body.widthAnchor),
            host.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func append(_ line: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        localLines.append("[\(timestamp)] \(line)")
        if localLines.count > 5_000 { localLines.removeFirst(localLines.count - 5_000) }
        render()
    }

    func setDaemonLines(_ lines: [String]) {
        if daemonLines.isEmpty {
            localLines.insert(contentsOf: lines, at: 0)
        } else {
            // Append only new daemon entries, retaining GUI actions and scroll order.
            let overlap = stride(from: min(daemonLines.count, lines.count), through: 1, by: -1)
                .first { daemonLines.suffix($0).elementsEqual(lines.prefix($0)) } ?? 0
            localLines.append(contentsOf: lines.dropFirst(overlap))
        }
        daemonLines = lines
        if localLines.count > 5_000 { localLines.removeFirst(localLines.count - 5_000) }
        render()
    }

    @objc private func filterChanged() { render() }

    private func render() {
        let oldOrigin = scroll.contentView.bounds.origin
        let wasAtBottom = textView.bounds.maxY - scroll.contentView.bounds.maxY < 28
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = localLines
        let visible = query.isEmpty ? lines : lines.filter { $0.localizedCaseInsensitiveContains(query) }
        textView.string = visible.joined(separator: "\n") + (visible.isEmpty ? "" : "\n")
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        empty.stringValue = lines.isEmpty ? L("No log entries") : L("No log entries match the filter")
        empty.isHidden = !visible.isEmpty
        if wasAtBottom { textView.scrollToEndOfDocument(nil) }
        else {
            scroll.contentView.scroll(to: oldOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

@MainActor
final class CarrachoServerWindowController: NSWindowController, NSTextFieldDelegate {
    private let statusDot = NSView()
    private let statusTitle = NSTextField(labelWithString: L("Loading…"))
    private let statusDetail = NSTextField(labelWithString: L("Opening server state"))
    private let startStopButton = NSButton(title: L("Start Server"), target: nil, action: nil)
    private let portValue = NSTextField(labelWithString: "—")
    private let clientsValue = NSTextField(labelWithString: "0")
    private let transfersValue = NSTextField(labelWithString: "0")
    private let serverPortField = NSTextField(string: "")
    private let serverPortApplyButton = NSButton(title: L("Apply"), target: nil, action: nil)
    private let configuredTransferPortLabel = NSTextField(labelWithString: L("Transfer port — · configured"))
    private let serverSettingsStatusLabel = NSTextField(labelWithString: "")
    private let adminValue = NSTextField(labelWithString: "—")
    private let passwordButton = NSButton(title: L("Change Password…"), target: nil, action: nil)
    private let storageValue = NSTextField(labelWithString: "—")
    private let fileRootValue = NSTextField(labelWithString: "—")
    private let fileRootButton = NSButton(title: L("Choose Folder…"), target: nil, action: nil)
    private let legacyFileRootValue = NSTextField(labelWithString: L("Uses normal File Root"))
    private let legacyUseModernRadio = NSButton(radioButtonWithTitle: L("Use modern folder"), target: nil, action: nil)
    private let legacyUseSeparateRadio = NSButton(radioButtonWithTitle: L("Use separate folder"), target: nil, action: nil)
    private let legacyFileRootButton = NSButton(title: L("Choose…"), target: nil, action: nil)
    private let legacyFileRootClearButton = NSButton(title: L("Use Normal Root"), target: nil, action: nil)
    private let fileRootsHelpButton = NSButton(title: L("Folder details"), target: nil, action: nil)
    private let fileRootsHelpLabel = NSTextField(wrappingLabelWithString: L("Account and group roots remain relative to the selected base folder. Choosing a folder changes only the configured root; files are not moved, copied, or deleted."))
    private let trackerStatusDot = NSView()
    private let trackerStatusLabel = NSTextField(labelWithString: L("Not running"))
    private let trackerStartStopButton = NSButton(title: L("Start Tracker"), target: nil, action: nil)
    private let trackerPortField = NSTextField(string: String(LegacyTrackerProtocol.port))
    private let trackerPortButton = NSButton(title: L("Set Port"), target: nil, action: nil)
    private let trackerServersValue = NSTextField(labelWithString: "0")
    private let botStatusDot = NSView()
    private let botStatusLabel = NSTextField(labelWithString: L("Not connected"))
    private let botStartStopButton = NSButton(title: L("Connect Bot"), target: nil, action: nil)
    private let botAvatarImageView = NSImageView()
    private let botAvatarChooseButton = NSButton(title: L("Choose PNG…"), target: nil, action: nil)
    private let botAvatarRemoveButton = NSButton(title: L("Remove"), target: nil, action: nil)
    private let botAvatarDetailLabel = NSTextField(labelWithString: L("No custom Bot avatar"))
    private let botGreetingEnabledButton = NSButton(checkboxWithTitle: L("Greet new users in Public"), target: nil, action: nil)
    private let botGreetingTemplateField = NSTextField(string: LegacyBotAdminStatus.defaultGreetingTemplate)
    private let botGreetingSaveButton = NSButton(title: L("Save Greeting"), target: nil, action: nil)
    private let botPipeValue = NSTextField(labelWithString: "~/Bot")
    private let botCommandValue = NSTextField(labelWithString: "echo \"Ich schreibe das hier in den Chat\" > Bot")
    private let botErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let serverDaemonStatusLabel = NSTextField(labelWithString: L("Not installed"))
    private let serverDaemonInstallButton = NSButton(title: L("Install"), target: nil, action: nil)
    private let serverDaemonUninstallButton = NSButton(title: L("Uninstall"), target: nil, action: nil)
    private let trackerDaemonStatusLabel = NSTextField(labelWithString: L("Not installed"))
    private let trackerDaemonInstallButton = NSButton(title: L("Install"), target: nil, action: nil)
    private let trackerDaemonUninstallButton = NSButton(title: L("Uninstall"), target: nil, action: nil)
    private let serverLog = ServerLogPanel(title: L("Server Log"))
    private let trackerLog = ServerLogPanel(title: L("Tracker Log"))
    private let serviceTabs = NSSegmentedControl(labels: [L("Server"), L("Tracker"), L("Bot")], trackingMode: .selectOne, target: nil, action: nil)
    private var serverPage: NSView?
    private var trackerPage: NSView?
    private var botPage: NSView?
    private let preferencesPopover = NSPopover()
    private let menuBarIconButton = NSButton(checkboxWithTitle: L("Show menu bar icon"), target: nil, action: nil)
    private let hideDockIconButton = NSButton(checkboxWithTitle: L("Hide Dock icon while menu bar icon is active"), target: nil, action: nil)
    var onPresentationPreferencesChanged: ((Bool, Bool) -> Void)?

    private enum ServerOperationState { case idle, starting, stopping }
    private var serverOperationState: ServerOperationState = .idle
    private var lastServerOperationError: String?
    private var trackerOperationInProgress = false
    private var botOperationInProgress = false

    private let daemonManager = CarrachoLaunchDaemonManager()
    private var cachedServerDaemonStatus = CarrachoLaunchDaemonStatus(installed: false, loaded: false, running: false, snapshot: nil)
    private var cachedTrackerDaemonStatus = CarrachoLaunchDaemonStatus(installed: false, loaded: false, running: false, snapshot: nil)
    private var service: CarrachoServerService?
    private var statusTimer: Timer?
    private var daemonLogSignatures: [CarrachoDaemonKind: String] = [:]
    private var smokeDumpPath: String?
    private var serverStateRootURL: URL?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("Carracho Server")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 560)
        window.center()
        self.init(window: window)
        configureWindow()
        loadServer()
    }

    deinit { statusTimer?.invalidate() }

    func shutdown() {
        statusTimer?.invalidate()
        statusTimer = nil
        service?.shutdown()
    }

    private func configureWindow() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window?.titlebarAppearsTransparent = true

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let document = ServerFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let server = stack([
            makeHeader(),
            ServerResponsiveColumnsView(left: [makeServerSettingsCard()], right: [makeFilesRootCard()]),
            makeDisclosure(title: L("System Service"), content: makeDaemonCard(kind: .server)),
            makeDisclosure(title: L("Administrator"), content: makeAdminCard()),
            serverLog,
        ], vertical: true, spacing: 12)
        let tracker = stack([
            makeTrackerHeader(), makeTrackerCard(),
            makeDisclosure(title: L("System Service"), content: makeDaemonCard(kind: .tracker)),
            trackerLog,
        ], vertical: true, spacing: 12)
        let bot = stack([
            makeBotHeader(), makeBotCard(),
        ], vertical: true, spacing: 12)
        serverPage = server
        trackerPage = tracker
        botPage = bot
        tracker.isHidden = true
        bot.isHidden = true
        let root = stack([makeNavigation(), server, tracker, bot], vertical: true, spacing: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        for child in root.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        document.addSubview(root)
        let preferredWidth = root.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -32)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            root.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            root.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            root.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -16),
            root.widthAnchor.constraint(lessThanOrEqualToConstant: 1180),
            preferredWidth,
        ])

        startStopButton.target = self
        startStopButton.action = #selector(toggleServer(_:))
        startStopButton.keyEquivalent = "\r"
        startStopButton.isEnabled = false
        startStopButton.controlSize = .regular
        startStopButton.font = .systemFont(ofSize: 13, weight: .semibold)
        applyServerPrimaryButtonStyle(startStopButton)
        startStopButton.setAccessibilityLabel(L("Start or stop server"))
        startStopButton.translatesAutoresizingMaskIntoConstraints = false
        startStopButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

        passwordButton.target = self
        passwordButton.action = #selector(administratorAction(_:))
        passwordButton.isEnabled = false

        for field in [serverPortField, trackerPortField] {
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        serverPortField.widthAnchor.constraint(equalToConstant: 92).isActive = true
        trackerPortField.widthAnchor.constraint(equalToConstant: 76).isActive = true
        serverPortField.setAccessibilityLabel(L("Server port"))
        trackerPortField.setAccessibilityLabel(L("Built-in tracker TCP port"))

        serverPortApplyButton.target = self
        serverPortApplyButton.action = #selector(saveServerSettings(_:))
        serverPortApplyButton.controlSize = .small
        trackerPortButton.target = self
        trackerPortButton.action = #selector(trackerPortChanged(_:))
        trackerPortButton.controlSize = .small
        trackerPortButton.title = L("Apply")

        fileRootButton.target = self
        fileRootButton.action = #selector(chooseFileRoot(_:))
        legacyFileRootButton.target = self
        legacyFileRootButton.action = #selector(chooseLegacyFileRoot(_:))
        legacyFileRootClearButton.target = self
        legacyFileRootClearButton.action = #selector(clearLegacyFileRoot(_:))
        legacyUseModernRadio.target = self
        legacyUseModernRadio.action = #selector(useModernRootForLegacy(_:))
        legacyUseSeparateRadio.target = self
        legacyUseSeparateRadio.action = #selector(useSeparateLegacyRoot(_:))
        fileRootsHelpButton.target = self
        fileRootsHelpButton.action = #selector(toggleFileRootHelp(_:))

        trackerStartStopButton.target = self
        trackerStartStopButton.action = #selector(toggleTracker(_:))
        trackerStartStopButton.controlSize = .regular
        trackerStartStopButton.font = .systemFont(ofSize: 12, weight: .semibold)
        applyServerPrimaryButtonStyle(trackerStartStopButton)
        trackerStartStopButton.setAccessibilityLabel(L("Start or stop tracker"))
        trackerStartStopButton.translatesAutoresizingMaskIntoConstraints = false
        trackerStartStopButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

        botStartStopButton.target = self
        botStartStopButton.action = #selector(toggleBot(_:))
        botStartStopButton.controlSize = .regular
        botStartStopButton.font = .systemFont(ofSize: 12, weight: .semibold)
        applyServerPrimaryButtonStyle(botStartStopButton)
        botStartStopButton.setAccessibilityLabel(L("Connect or disconnect Bot"))
        botStartStopButton.translatesAutoresizingMaskIntoConstraints = false
        botStartStopButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

        botAvatarChooseButton.target = self
        botAvatarChooseButton.action = #selector(chooseBotAvatar(_:))
        botAvatarRemoveButton.target = self
        botAvatarRemoveButton.action = #selector(removeBotAvatar(_:))
        botGreetingSaveButton.target = self
        botGreetingSaveButton.action = #selector(saveBotGreeting(_:))
        botGreetingSaveButton.font = .systemFont(ofSize: 12, weight: .semibold)
        applyServerPrimaryButtonStyle(botGreetingSaveButton)

        serverDaemonInstallButton.target = self
        serverDaemonInstallButton.action = #selector(installServerDaemon(_:))
        trackerDaemonInstallButton.target = self
        trackerDaemonInstallButton.action = #selector(installTrackerDaemon(_:))
        serverDaemonUninstallButton.target = self
        serverDaemonUninstallButton.action = #selector(showServerDaemonMenu(_:))
        trackerDaemonUninstallButton.target = self
        trackerDaemonUninstallButton.action = #selector(showTrackerDaemonMenu(_:))

        menuBarIconButton.target = self
        menuBarIconButton.action = #selector(menuBarIconPreferenceChanged(_:))
        hideDockIconButton.target = self
        hideDockIconButton.action = #selector(hideDockIconPreferenceChanged(_:))
        syncPresentationPreferences()
        updateApplyButtonStates()
    }

    private func makeHeader() -> NSView {
        let icon = NSImageView()
        if #available(macOS 11.0, *) {
            icon.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: L("Server"))
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .medium)
        } else {
            icon.image = NSImage(named: NSImage.networkName)
        }
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 54),
            icon.heightAnchor.constraint(equalToConstant: 54),
        ])

        let title = NSTextField(labelWithString: L("Server"))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        statusTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        statusDetail.font = .systemFont(ofSize: 11.5)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.lineBreakMode = .byTruncatingTail
        statusDetail.toolTip = statusDetail.stringValue
        let stateRow = stack([statusDot, statusTitle, NSView()], spacing: 7)
        let identity = stack([title, stateRow, statusDetail], vertical: true, spacing: 2)
        identity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let identityRow = stack([icon, identity], spacing: 12)
        let metrics = stack([
            metric(title: L("Connections"), value: clientsValue),
            metric(title: L("Transfers"), value: transfersValue),
        ], spacing: 24)
        metrics.setContentHuggingPriority(.required, for: .horizontal)
        let row = ServerResponsiveStatusView(identity: identityRow, metrics: metrics, action: startStopButton)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func sectionHeader(symbol: String, title: String, trailing: NSView? = nil) -> NSView {
        let icon = NSImageView()
        if #available(macOS 11.0, *) {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        return stack([icon, label, NSView()] + (trailing.map { [$0] } ?? []), spacing: 8)
    }

    private func makeServerSettingsCard() -> NSView {
        configuredTransferPortLabel.font = .systemFont(ofSize: 11)
        configuredTransferPortLabel.textColor = .secondaryLabelColor
        serverSettingsStatusLabel.font = .systemFont(ofSize: 11)
        serverSettingsStatusLabel.textColor = .secondaryLabelColor
        serverSettingsStatusLabel.lineBreakMode = .byTruncatingTail

        let portLabel = NSTextField(labelWithString: L("Server port"))
        portLabel.font = .systemFont(ofSize: 11.5)
        let controls = stack([serverPortField, serverPortApplyButton, NSView()], spacing: 8)
        let note = NSTextField(wrappingLabelWithString: L("Transfers use server port + 1. A live GUI listener is restarted after a successful change; an installed running daemon is restarted separately."))
        note.font = .systemFont(ofSize: 10.5)
        note.textColor = .secondaryLabelColor
        let body = stack([
            sectionHeader(symbol: "network", title: L("Connection")),
            stack([portLabel, NSView(), controls]), configuredTransferPortLabel,
            stack([settingsLabel(L("Active Ports")), NSView(), portValue]), serverSettingsStatusLabel,
        ], vertical: true, spacing: 6)
        body.toolTip = note.stringValue
        return card(body)
    }

    private func daemonMenuButton(_ button: NSButton, help: String) {
        button.title = ""
        button.bezelStyle = .texturedRounded
        if #available(macOS 11.0, *) { button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: help) }
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
    }

    private func makeDaemonCard(kind: CarrachoDaemonKind) -> NSView {
        let status = kind == .server ? serverDaemonStatusLabel : trackerDaemonStatusLabel
        let install = kind == .server ? serverDaemonInstallButton : trackerDaemonInstallButton
        let menu = kind == .server ? serverDaemonUninstallButton : trackerDaemonUninstallButton
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        install.controlSize = .small
        daemonMenuButton(menu, help: kind == .server ? L("Server service actions") : L("Tracker service actions"))
        let note = NSTextField(wrappingLabelWithString: L("Installed services run independently of this window and are configured to start with macOS. Installation and removal require administrator approval."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        return card(stack([stack([status, NSView(), install, menu]), note], vertical: true))
    }

    private func makeNavigation() -> NSView {
        serviceTabs.selectedSegment = 0
        serviceTabs.segmentStyle = .rounded
        serviceTabs.target = self
        serviceTabs.action = #selector(selectServiceTab(_:))
        serviceTabs.setAccessibilityLabel(L("Server, Tracker and Bot"))
        for index in 0..<3 { serviceTabs.setWidth(120, forSegment: index) }
        let settings = NSButton(title: "", target: self, action: #selector(showPreferences(_:)))
        settings.bezelStyle = .texturedRounded
        if #available(macOS 11.0, *) {
            settings.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: L("General Settings"))
            settings.contentTintColor = .labelColor
        } else { settings.title = L("General Settings") }
        settings.toolTip = L("General Settings")
        settings.setAccessibilityLabel(L("General Settings"))
        let row = NSView()
        for view in [serviceTabs, settings] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            serviceTabs.centerXAnchor.constraint(equalTo: row.centerXAnchor),
            serviceTabs.topAnchor.constraint(equalTo: row.topAnchor),
            serviceTabs.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            settings.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            settings.centerYAnchor.constraint(equalTo: serviceTabs.centerYAnchor),
            settings.leadingAnchor.constraint(greaterThanOrEqualTo: serviceTabs.trailingAnchor, constant: 12),
        ])
        let preferences = NSViewController()
        preferences.view = makeBackgroundControlCard()
        preferencesPopover.contentViewController = preferences
        preferencesPopover.contentSize = NSSize(width: 430, height: 150)
        preferencesPopover.behavior = .transient
        return row
    }

    @objc private func selectServiceTab(_ sender: NSSegmentedControl) {
        let selected = sender.selectedSegment
        serverPage?.isHidden = selected != 0
        trackerPage?.isHidden = selected != 1
        botPage?.isHidden = selected != 2
        startStopButton.keyEquivalent = selected == 0 ? "\r" : ""
        trackerStartStopButton.keyEquivalent = selected == 1 ? "\r" : ""
        botStartStopButton.keyEquivalent = selected == 2 ? "\r" : ""
        window?.makeFirstResponder(sender)
    }

    @objc private func showPreferences(_ sender: NSButton) {
        if preferencesPopover.isShown { preferencesPopover.close() }
        else { preferencesPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY) }
    }

    private func makeDisclosure(title: String, content: NSView) -> NSView {
        ServerDisclosureView(title: title, content: content)
    }

    private func makeBackgroundControlCard() -> NSView {
        menuBarIconButton.controlSize = .small
        hideDockIconButton.controlSize = .small
        let note = NSTextField(wrappingLabelWithString: L("The menu bar icon keeps server controls available when this window is closed or hidden. The Dock icon can be hidden only while the menu bar icon is enabled."))
        note.font = .systemFont(ofSize: 10.5)
        note.textColor = .secondaryLabelColor
        let body = stack([
            sectionHeader(symbol: "menubar.rectangle", title: L("Background Control")),
            menuBarIconButton,
            hideDockIconButton,
            note,
        ], vertical: true, spacing: 7)
        return card(body)
    }

    @objc private func menuBarIconPreferenceChanged(_ sender: Any?) {
        let enabled = menuBarIconButton.state == .on
        CarrachoServerPresentationPreferences.menuBarIconEnabled = enabled
        if !enabled {
            CarrachoServerPresentationPreferences.hideDockIcon = false
        }
        syncPresentationPreferences()
        onPresentationPreferencesChanged?(enabled, CarrachoServerPresentationPreferences.hideDockIcon)
    }

    @objc private func hideDockIconPreferenceChanged(_ sender: Any?) {
        guard CarrachoServerPresentationPreferences.menuBarIconEnabled else {
            CarrachoServerPresentationPreferences.hideDockIcon = false
            syncPresentationPreferences()
            return
        }
        CarrachoServerPresentationPreferences.hideDockIcon = hideDockIconButton.state == .on
        syncPresentationPreferences()
        onPresentationPreferencesChanged?(true, CarrachoServerPresentationPreferences.hideDockIcon)
    }

    func syncPresentationPreferences() {
        let menuEnabled = CarrachoServerPresentationPreferences.menuBarIconEnabled
        menuBarIconButton.state = menuEnabled ? .on : .off
        hideDockIconButton.state = CarrachoServerPresentationPreferences.hideDockIcon ? .on : .off
        hideDockIconButton.isEnabled = menuEnabled
    }

    private func makeAdminCard() -> NSView {
        let adminCaption = NSTextField(labelWithString: L("Account"))
        adminCaption.font = .systemFont(ofSize: 10.5)
        adminCaption.textColor = .secondaryLabelColor
        adminValue.font = .systemFont(ofSize: 12.5, weight: .medium)
        let account = stack([adminCaption, adminValue], vertical: true, spacing: 2)
        passwordButton.controlSize = .small
        let accountRow = stack([account, NSView(), passwordButton], spacing: 10)

        let storageCaption = NSTextField(labelWithString: L("Server data"))
        storageCaption.font = .systemFont(ofSize: 10.5)
        storageCaption.textColor = .secondaryLabelColor
        storageValue.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        storageValue.textColor = .secondaryLabelColor
        storageValue.lineBreakMode = .byTruncatingMiddle
        storageValue.isSelectable = true
        storageValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let body = stack([
            sectionHeader(symbol: "person.badge.key", title: L("Administrator")), accountRow,
            separator(), storageCaption, storageValue,
        ], vertical: true, spacing: 7)
        return card(body)
    }

    private func makeFilesRootCard() -> NSView {
        fileRootButton.controlSize = .small
        legacyFileRootButton.controlSize = .small
        fileRootValue.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        fileRootValue.lineBreakMode = .byTruncatingMiddle
        fileRootValue.isSelectable = true
        fileRootValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        legacyFileRootValue.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        legacyFileRootValue.lineBreakMode = .byTruncatingMiddle
        legacyFileRootValue.isSelectable = true
        legacyFileRootValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let modernCaption = NSTextField(labelWithString: L("Modern"))
        modernCaption.font = .systemFont(ofSize: 11)
        modernCaption.textColor = .secondaryLabelColor
        let folderIcon = NSImageView()
        if #available(macOS 11.0, *) { folderIcon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: L("Folder")) }
        folderIcon.contentTintColor = .systemBlue
        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        folderIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let modernRow = stack([folderIcon, fileRootValue, NSView(), fileRootButton], spacing: 7)

        let classicCaption = NSTextField(labelWithString: L("Classic / Legacy"))
        classicCaption.font = .systemFont(ofSize: 11)
        classicCaption.textColor = .secondaryLabelColor
        let separateRow = stack([legacyUseSeparateRadio, legacyFileRootButton], spacing: 7)
        let legacyPathRow = stack([legacyFileRootValue, NSView()], spacing: 6)

        fileRootsHelpButton.isBordered = false
        fileRootsHelpButton.alignment = .left
        fileRootsHelpButton.font = .systemFont(ofSize: 10.5)
        fileRootsHelpButton.contentTintColor = .secondaryLabelColor
        if #available(macOS 11.0, *) { fileRootsHelpButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L("Folder details")) }
        fileRootsHelpButton.imagePosition = .imageLeading
        fileRootsHelpLabel.font = .systemFont(ofSize: 10.5)
        fileRootsHelpLabel.textColor = .secondaryLabelColor
        fileRootsHelpLabel.isHidden = true

        let stopNote = NSTextField(labelWithString: L("Folders can be changed only while the effective server process is stopped."))
        stopNote.font = .systemFont(ofSize: 10.5)
        stopNote.textColor = .secondaryLabelColor
        stopNote.lineBreakMode = .byTruncatingTail
        let body = stack([
            sectionHeader(symbol: "folder", title: L("File Folders")),
            modernCaption, modernRow,
            makeDisclosure(title: classicCaption.stringValue, content: stack([
                legacyUseModernRadio, separateRow, legacyPathRow,
                fileRootsHelpButton, fileRootsHelpLabel, stopNote,
            ], vertical: true, spacing: 7)),
        ], vertical: true, spacing: 7)
        return card(body)
    }

    private func makeTrackerHeader() -> NSView {
        trackerStatusDot.wantsLayer = true
        trackerStatusDot.layer?.cornerRadius = 5
        trackerStatusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        trackerStatusDot.translatesAutoresizingMaskIntoConstraints = false
        trackerStatusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        trackerStatusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        trackerStatusLabel.font = .systemFont(ofSize: 12)
        trackerStatusLabel.lineBreakMode = .byTruncatingTail
        trackerStatusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        trackerStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        trackerStatusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        let title = NSTextField(labelWithString: L("Tracker"))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let icon = NSImageView()
        if #available(macOS 11.0, *) {
            icon.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: L("Tracker"))
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .medium)
        }
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 54).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 54).isActive = true
        let identity = stack([icon, stack([title, stack([trackerStatusDot, trackerStatusLabel, NSView()])], vertical: true, spacing: 4)], spacing: 12)
        return ServerResponsiveStatusView(identity: identity,
            metrics: metric(title: L("Registered servers"), value: trackerServersValue), action: trackerStartStopButton)
    }

    private func makeTrackerCard() -> NSView {
        let controls = stack([settingsLabel(L("TCP port")), trackerPortField, trackerPortButton, NSView()])
        let note = NSTextField(wrappingLabelWithString: L("Accepts Classic CTT registrations and CTQ list queries. This is separate from installing the tracker as a macOS system service."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        return card(stack([sectionHeader(symbol: "network", title: L("Connection")), controls, note], vertical: true))
    }

    private func makeBotHeader() -> NSView {
        botStatusDot.wantsLayer = true
        botStatusDot.layer?.cornerRadius = 5
        botStatusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        botStatusDot.translatesAutoresizingMaskIntoConstraints = false
        botStatusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        botStatusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true

        botStatusLabel.font = .systemFont(ofSize: 12)
        botStatusLabel.lineBreakMode = .byTruncatingTail
        botStatusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let title = NSTextField(labelWithString: L("Bot"))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let icon = NSImageView()
        if #available(macOS 11.0, *) {
            icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: L("Bot"))
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .medium)
        } else {
            icon.image = NSImage(named: NSImage.advancedName)
        }
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 54).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 54).isActive = true

        let identity = stack([
            icon,
            stack([title, stack([botStatusDot, botStatusLabel, NSView()])], vertical: true, spacing: 4),
        ], spacing: 12)
        let publicValue = NSTextField(labelWithString: L("Public"))
        publicValue.font = .systemFont(ofSize: 18, weight: .semibold)
        return ServerResponsiveStatusView(identity: identity,
            metrics: metric(title: L("Conference"), value: publicValue), action: botStartStopButton)
    }

    private func makeBotCard() -> NSView {
        let intro = NSTextField(wrappingLabelWithString: L("The Bot appears as a normal user named “Bot” in the user list and automatically joins the Public conference on this local server."))
        intro.font = .systemFont(ofSize: 11.5)
        intro.textColor = .secondaryLabelColor
        let locality = NSTextField(wrappingLabelWithString: L("Localhost only: the Bot is an in-process server session and cannot connect to a remote server."))
        locality.font = .systemFont(ofSize: 11, weight: .medium)
        locality.textColor = .secondaryLabelColor
        let accountNote = NSTextField(wrappingLabelWithString: L("The Bot uses a persistent account. Its login, name, color and permissions are managed in Accounts; its avatar is configured here."))
        accountNote.font = .systemFont(ofSize: 11)
        accountNote.textColor = .secondaryLabelColor

        let avatarTitle = settingsLabel(L("Bot avatar"))
        botAvatarImageView.imageScaling = .scaleProportionallyUpOrDown
        botAvatarImageView.wantsLayer = true
        botAvatarImageView.layer?.cornerRadius = 10
        botAvatarImageView.layer?.masksToBounds = true
        botAvatarImageView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        botAvatarImageView.translatesAutoresizingMaskIntoConstraints = false
        botAvatarImageView.widthAnchor.constraint(equalToConstant: 96).isActive = true
        botAvatarImageView.heightAnchor.constraint(equalToConstant: 96).isActive = true
        botAvatarDetailLabel.font = .systemFont(ofSize: 11)
        botAvatarDetailLabel.textColor = .secondaryLabelColor
        let avatarButtons = stack([botAvatarChooseButton, botAvatarRemoveButton, NSView()])
        let avatarText = stack([avatarTitle, botAvatarDetailLabel, avatarButtons], vertical: true, spacing: 6)
        let avatarRow = stack([botAvatarImageView, avatarText], spacing: 12)
        let avatarNote = NSTextField(wrappingLabelWithString: L("The selected PNG is normalized to 128 × 128 pixels and stored as the Bot's server-side avatar."))
        avatarNote.font = .systemFont(ofSize: 11)
        avatarNote.textColor = .secondaryLabelColor

        let greetingTitle = settingsLabel(L("Automatic greeting"))
        botGreetingTemplateField.placeholderString = LegacyBotAdminStatus.defaultGreetingTemplate
        botGreetingTemplateField.font = .systemFont(ofSize: 12)
        botGreetingTemplateField.lineBreakMode = .byTruncatingTail
        botGreetingTemplateField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let greetingTextRow = stack([botGreetingTemplateField, botGreetingSaveButton], spacing: 8)
        let greetingNote = NSTextField(wrappingLabelWithString: L("When enabled, the Bot greets each newly connected user once when they first join Public. Use {name} for the visible nickname and {login} for the account login."))
        greetingNote.font = .systemFont(ofSize: 11)
        greetingNote.textColor = .secondaryLabelColor

        let pipeTitle = settingsLabel(L("Terminal interface"))
        botPipeValue.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        botPipeValue.isSelectable = true
        botPipeValue.lineBreakMode = .byTruncatingMiddle
        botPipeValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pipeNote = NSTextField(wrappingLabelWithString: L("Each UTF-8 line written to this named pipe is posted to Public. The pipe exists only while the Bot is connected."))
        pipeNote.font = .systemFont(ofSize: 11)
        pipeNote.textColor = .secondaryLabelColor

        let commandTitle = settingsLabel(L("Terminal example"))
        botCommandValue.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        botCommandValue.isSelectable = true
        botCommandValue.lineBreakMode = .byClipping
        botCommandValue.toolTip = botCommandValue.stringValue

        let commandNote = NSTextField(wrappingLabelWithString: L("The short form works when Terminal is in your home folder. From any other folder, write to ~/Bot instead."))
        commandNote.font = .systemFont(ofSize: 11)
        commandNote.textColor = .secondaryLabelColor

        botErrorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        botErrorLabel.textColor = .systemRed
        botErrorLabel.isHidden = true

        let body = stack([
            sectionHeader(symbol: "terminal", title: L("Local Bot Interface")),
            intro,
            locality,
            accountNote,
            separator(),
            avatarRow,
            avatarNote,
            separator(),
            greetingTitle,
            botGreetingEnabledButton,
            greetingTextRow,
            greetingNote,
            separator(),
            stack([pipeTitle, botPipeValue], vertical: true, spacing: 4),
            pipeNote,
            stack([commandTitle, botCommandValue], vertical: true, spacing: 4),
            commandNote,
            botErrorLabel,
        ], vertical: true, spacing: 8)
        return card(body)
    }

    func controlTextDidChange(_ obj: Notification) {
        updateApplyButtonStates()
    }

    private func configuredServerPort() -> UInt16? { service?.serverState.advanced.controlPort }

    private func portsConflict(serverPort: UInt16, trackerPort: UInt16) -> Bool {
        trackerPort == serverPort || (serverPort < UInt16.max && trackerPort == serverPort + 1)
    }

    private func updateApplyButtonStates() {
        guard let service else {
            serverPortApplyButton.isEnabled = false
            trackerPortButton.isEnabled = false
            return
        }
        let serverText = serverPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverPort = UInt16(serverText)
        let validServer = serverPort.map { $0 > 0 && $0 < UInt16.max } == true
        let serverChanged = serverPort != service.serverState.advanced.controlPort
        let trackerPort = UInt16(trackerPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        let trackerConflict = serverPort.map { candidate in
            portsConflict(serverPort: candidate, trackerPort: service.trackerConfiguration.port)
        } ?? false
        serverPortApplyButton.isEnabled = validServer && serverChanged && !trackerConflict && serverOperationState == .idle

        let trackerDaemon = cachedTrackerDaemonStatus
        let trackerActive = service.trackerStatus.isRunning || (trackerDaemon.loaded && service.trackerConfiguration.enabled)
        let validTracker = trackerPort.map { $0 > 0 && !portsConflict(serverPort: service.serverState.advanced.controlPort, trackerPort: $0) } == true
        trackerPortButton.isEnabled = validTracker && trackerPort != service.trackerConfiguration.port && !trackerActive && !trackerOperationInProgress
        trackerStartStopButton.isEnabled = !trackerOperationInProgress
    }

    @objc private func useModernRootForLegacy(_ sender: Any?) {
        guard let service else { return }
        let daemon = daemonStatus(.server)
        guard !service.status.isRunning && !daemon.loaded else {
            refreshLegacyFileRootDisplay()
            presentMessage(title: L("Stop the Server First"), message: L("The Classic / Legacy file root cannot be changed while the effective server process is running."))
            return
        }
        do {
            try service.updateLegacyFilesRoot(nil)
            refreshLegacyFileRootDisplay()
            appendLog(L("Classic / Legacy connections now use the modern file root."))
        } catch {
            refreshLegacyFileRootDisplay()
            presentError(title: L("Legacy File Root Could Not Be Changed"), error: error)
        }
    }

    @objc private func useSeparateLegacyRoot(_ sender: Any?) {
        guard let service else { return }
        if service.legacyFilesURL != nil {
            refreshLegacyFileRootDisplay()
            return
        }
        // No separate path exists yet. Ask for it now; cancelling leaves the effective mode unchanged.
        legacyUseModernRadio.state = .on
        legacyUseSeparateRadio.state = .off
        chooseLegacyFileRoot(sender)
    }

    @objc private func toggleFileRootHelp(_ sender: Any?) {
        fileRootsHelpLabel.isHidden.toggle()
        if #available(macOS 11.0, *) {
            fileRootsHelpButton.image = NSImage(systemSymbolName: fileRootsHelpLabel.isHidden ? "chevron.right" : "chevron.down", accessibilityDescription: L("Folder details"))
        }
    }

    @objc private func showServerDaemonMenu(_ sender: NSButton) {
        let menu = NSMenu(title: L("Server Service"))
        let status = daemonStatus(.server)
        if status.installed {
            let restart = NSMenuItem(title: status.loaded ? L("Restart Service") : L("Start Service"), action: #selector(restartServerDaemonFromMenu(_:)), keyEquivalent: "")
            restart.target = self
            menu.addItem(restart)
            let remove = NSMenuItem(title: L("Uninstall Service…"), action: #selector(uninstallServerDaemon(_:)), keyEquivalent: "")
            remove.target = self
            menu.addItem(remove)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc private func restartServerDaemonFromMenu(_ sender: Any?) {
        do {
            try daemonManager.setRunning(true, kind: .server)
            appendLog(L("Server system service restarted."))
            refreshRuntimeStatus(); refreshDaemonControls()
        } catch {
            presentError(title: L("Server Service Could Not Be Restarted"), error: error)
        }
    }

    @objc private func showTrackerDaemonMenu(_ sender: NSButton) {
        let menu = NSMenu(title: L("Tracker Service"))
        let status = daemonStatus(.tracker)
        if status.installed {
            let restart = NSMenuItem(title: status.loaded ? L("Restart Service") : L("Start Service"), action: #selector(restartTrackerDaemonFromMenu(_:)), keyEquivalent: "")
            restart.target = self
            restart.isEnabled = service?.trackerConfiguration.enabled == true
            menu.addItem(restart)
            let remove = NSMenuItem(title: L("Uninstall Service…"), action: #selector(uninstallTrackerDaemon(_:)), keyEquivalent: "")
            remove.target = self
            menu.addItem(remove)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc private func restartTrackerDaemonFromMenu(_ sender: Any?) {
        guard service?.trackerConfiguration.enabled == true else { return }
        do {
            try daemonManager.setRunning(true, kind: .tracker)
            appendTrackerLog(L("Tracker system service restarted."))
            refreshRuntimeStatus(); refreshDaemonControls()
        } catch {
            presentError(title: L("Tracker Service Could Not Be Restarted"), error: error)
        }
    }

    private func loadServer() {
        appendLog(L("Opening server state…"))
        let root: URL
        if let value = argumentValue(prefix: "--server-root=") {
            root = URL(fileURLWithPath: value, isDirectory: true)
        } else {
            root = CarrachoServerService.defaultRootURL()
        }
        serverStateRootURL = root.standardizedFileURL
        smokeDumpPath = argumentValue(prefix: "--server-app-smoke-dump=")

        do {
            try installService(rootURL: root)
            appendLog(LF("Server state ready at %@", service?.databaseURL.path ?? root.path))
            appendLog(LF("Config: %@", CarrachoServerService.configurationURL(rootURL: root).path))
            appendLog(LF("File root: %@", service?.filesURL.path ?? CarrachoServerService.defaultFilesURL(rootURL: root).path))
            startStatusTimer()
            runSmokeIfRequested()
        } catch {
            statusTitle.stringValue = L("Server unavailable")
            statusDetail.stringValue = error.localizedDescription
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            appendLog(LF("ERROR: %@", error.localizedDescription))
            startStopButton.isEnabled = false
            trackerStartStopButton.isEnabled = false
            passwordButton.isEnabled = false
            fileRootButton.isEnabled = false
            legacyFileRootButton.isEnabled = false
            legacyFileRootClearButton.isEnabled = false
            writeSmokeSnapshot(success: false, note: error.localizedDescription)
        }
    }

    private func installService(rootURL: URL) throws {
        configureService(try CarrachoServerService(rootURL: rootURL,
                                                   defaultBannerPNG: CarrachoDefaultServerBanner.pngData()))
    }

    private func configureService(_ service: CarrachoServerService) {
        // Assign first so replacing the service tears down an old built-in tracker before
        // we try to bind the same configured tracker port in the replacement runtime.
        self.service = service
        service.runtime.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.updateStatus(status) }
        }
        service.runtime.onLog = { [weak self] line in
            DispatchQueue.main.async { self?.appendLog(line) }
        }
        service.runtime.onStateChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshAdminAccount()
                self?.refreshServerSettings()
            }
        }
        service.trackerRuntime.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.updateTrackerStatus(status) }
        }
        service.trackerRuntime.onLog = { [weak self] line in
            DispatchQueue.main.async { self?.appendTrackerLog(line) }
        }
        storageValue.stringValue = service.databaseURL.path
        storageValue.toolTip = service.databaseURL.path
        fileRootValue.stringValue = service.filesURL.path
        fileRootValue.toolTip = service.filesURL.path
        refreshLegacyFileRootDisplay()
        trackerPortField.stringValue = String(service.trackerConfiguration.port)
        startStopButton.isEnabled = true
        passwordButton.isEnabled = service.administratorAccount != nil
        refreshAdminAccount()
        refreshServerSettings()
        refreshRuntimeStatus()
        refreshBotAvatar()
        refreshBotGreetingConfiguration()
        refreshBotStatus()
        let trackerDaemon = cachedTrackerDaemonStatus
        if service.trackerConfiguration.enabled && !trackerDaemon.installed {
            do {
                _ = try service.startConfiguredTracker()
                updateTrackerStatus(service.trackerStatus)
            } catch {
                appendTrackerLog(LF("ERROR: Built-in tracker could not start: %@", error.localizedDescription))
                updateTrackerStatus(service.trackerStatus)
            }
        }
        refreshDaemonControls()
    }

    private func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self,
                                           selector: #selector(pollStatus(_:)),
                                           userInfo: nil, repeats: true)
    }

    @objc private func pollStatus(_ timer: Timer) {
        refreshRuntimeStatus(checkLaunchd: false)
        refreshBotStatus()
        refreshDaemonControls()
        refreshDaemonLogIfNeeded()
    }

    private func daemonStatus(_ kind: CarrachoDaemonKind) -> CarrachoLaunchDaemonStatus {
        guard let root = serverStateRootURL else {
            let empty = CarrachoLaunchDaemonStatus(installed: false, loaded: false, running: false, snapshot: nil)
            cacheDaemonStatus(empty, for: kind)
            return empty
        }
        let status = daemonManager.status(for: kind, rootURL: root)
        cacheDaemonStatus(status, for: kind)
        return status
    }

    private func heartbeatDaemonStatus(_ kind: CarrachoDaemonKind) -> CarrachoLaunchDaemonStatus {
        guard let root = serverStateRootURL else {
            let empty = CarrachoLaunchDaemonStatus(installed: false, loaded: false, running: false, snapshot: nil)
            cacheDaemonStatus(empty, for: kind)
            return empty
        }
        let status = daemonManager.heartbeatStatus(for: kind, rootURL: root)
        cacheDaemonStatus(status, for: kind)
        return status
    }

    private func cacheDaemonStatus(_ status: CarrachoLaunchDaemonStatus, for kind: CarrachoDaemonKind) {
        switch kind {
        case .server: cachedServerDaemonStatus = status
        case .tracker: cachedTrackerDaemonStatus = status
        }
    }

    fileprivate func menuBarSnapshot() -> CarrachoServerMenuBarSnapshot? {
        guard let service else { return nil }
        let serverDaemon = cachedServerDaemonStatus
        let trackerDaemon = cachedTrackerDaemonStatus
        let serverRunning = serverDaemon.installed ? serverDaemon.loaded : service.status.isRunning
        let trackerRunning = trackerDaemon.running || service.trackerStatus.isRunning ||
            (trackerDaemon.loaded && service.trackerConfiguration.enabled)
        let trackerStatus: String
        if trackerDaemon.installed {
            if trackerDaemon.running { trackerStatus = L("Running as system service") }
            else if trackerDaemon.loaded && service.trackerConfiguration.enabled { trackerStatus = L("Starting as system service") }
            else if service.trackerConfiguration.enabled { trackerStatus = L("Configured to run · system service stopped") }
            else { trackerStatus = L("Stopped · system service installed") }
        } else if service.trackerStatus.isRunning {
            trackerStatus = L("Running in this app")
        } else if service.trackerConfiguration.enabled {
            trackerStatus = L("Configured to run · not running")
        } else {
            trackerStatus = L("Stopped")
        }
        return CarrachoServerMenuBarSnapshot(
            statusTitle: statusTitle.stringValue,
            statusDetail: statusDetail.stringValue,
            connections: clientsValue.stringValue,
            transfers: transfersValue.stringValue,
            ports: portValue.stringValue,
            serverRunning: serverRunning,
            canToggleServer: serverOperationState == .idle,
            trackerRunning: trackerRunning,
            trackerStatus: trackerStatus,
            canToggleTracker: !trackerOperationInProgress
        )
    }

    fileprivate func toggleServerFromMenuBar() {
        toggleServer(nil)
    }

    fileprivate func toggleTrackerFromMenuBar() {
        toggleTracker(nil)
    }

    private func refreshRuntimeStatus(checkLaunchd: Bool = true) {
        guard let service else { return }
        let serverDaemon = checkLaunchd ? daemonStatus(.server) : heartbeatDaemonStatus(.server)
        if serverDaemon.installed { updateServerDaemonStatus(serverDaemon) }
        else { updateStatus(service.status) }

        let trackerDaemon = checkLaunchd ? daemonStatus(.tracker) : heartbeatDaemonStatus(.tracker)
        if trackerDaemon.installed { updateTrackerDaemonStatus(trackerDaemon) }
        else { updateTrackerStatus(service.trackerStatus) }
    }

    private func refreshDaemonControls() {
        guard let service else { return }
        let serverDaemon = cachedServerDaemonStatus
        let trackerDaemon = cachedTrackerDaemonStatus

        serverDaemonStatusLabel.stringValue = daemonStatusText(serverDaemon)
        serverDaemonInstallButton.title = serverDaemon.installed ? L("Reinstall…") : L("Install…")
        serverDaemonInstallButton.isEnabled = serverOperationState == .idle
        serverDaemonUninstallButton.isEnabled = serverDaemon.installed && serverOperationState == .idle

        if trackerDaemon.installed && !service.trackerConfiguration.enabled && trackerDaemon.loaded {
            trackerDaemonStatusLabel.stringValue = L("Installed · idle (tracker stopped)")
        } else {
            trackerDaemonStatusLabel.stringValue = daemonStatusText(trackerDaemon)
        }
        trackerDaemonInstallButton.title = trackerDaemon.installed ? L("Reinstall…") : L("Install…")
        trackerDaemonInstallButton.isEnabled = !trackerOperationInProgress
        trackerDaemonUninstallButton.isEnabled = trackerDaemon.installed && !trackerOperationInProgress
        updateApplyButtonStates()
    }

    private func daemonStatusText(_ status: CarrachoLaunchDaemonStatus) -> String {
        guard status.installed else { return L("Not installed") }
        if status.running, let pid = status.snapshot?.pid { return LF("Installed · running (PID %@)", String(pid)) }
        if status.loaded { return L("Installed · starting / unavailable") }
        return L("Installed · stopped")
    }

    private func updateServerDaemonStatus(_ daemon: CarrachoLaunchDaemonStatus) {
        let snapshot = daemon.snapshot
        if daemon.running, let snapshot {
            statusTitle.stringValue = L("Running · System Service")
            let control = snapshot.port.map(String.init) ?? "?"
            let transfer = snapshot.transferPort.map(String.init) ?? "?"
            statusDetail.stringValue = LF("Independent of this window · control TCP %@, transfers TCP %@", control, transfer)
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            setServerPrimaryButtonTitle(startStopButton, L("Stop Server"))
            portValue.stringValue = "\(control) / \(transfer)"
            clientsValue.stringValue = String(snapshot.connectedClients)
            transfersValue.stringValue = String(snapshot.activeFileTransfers)
        } else if daemon.loaded {
            statusTitle.stringValue = L("Starting · System Service")
            statusDetail.stringValue = L("launchd has loaded the service; waiting for a live listener heartbeat.")
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            setServerPrimaryButtonTitle(startStopButton, L("Stop Server"))
            portValue.stringValue = "—"
            clientsValue.stringValue = "—"
            transfersValue.stringValue = "—"
        } else if let lastServerOperationError {
            statusTitle.stringValue = L("Error · System Service")
            statusDetail.stringValue = lastServerOperationError
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            setServerPrimaryButtonTitle(startStopButton, L("Start Server"))
            portValue.stringValue = "—"
            clientsValue.stringValue = "—"
            transfersValue.stringValue = "—"
        } else {
            statusTitle.stringValue = L("Stopped · Service installed")
            statusDetail.stringValue = L("No server listener is active. The installed service remains available.")
            statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
            setServerPrimaryButtonTitle(startStopButton, L("Start Server"))
            portValue.stringValue = "—"
            clientsValue.stringValue = "0"
            transfersValue.stringValue = "0"
        }
        statusDetail.toolTip = statusDetail.stringValue
        let effectiveRunning = daemon.loaded
        fileRootButton.isEnabled = !effectiveRunning
        legacyFileRootButton.isEnabled = !effectiveRunning && legacyUseSeparateRadio.state == .on
        legacyUseModernRadio.isEnabled = !effectiveRunning
        legacyUseSeparateRadio.isEnabled = !effectiveRunning
        startStopButton.isEnabled = serverOperationState == .idle
        applyServerOperationPresentationIfNeeded()
        updateApplyButtonStates()
    }

    private func updateTrackerDaemonStatus(_ daemon: CarrachoLaunchDaemonStatus) {
        guard let service else { return }
        let configuredToRun = service.trackerConfiguration.enabled
        if daemon.running, let snapshot = daemon.snapshot {
            trackerStatusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            trackerStatusLabel.stringValue = LF("Running as system service · TCP %@", snapshot.port.map(String.init) ?? "?")
            trackerServersValue.stringValue = String(snapshot.registeredServers)
            setServerPrimaryButtonTitle(trackerStartStopButton, L("Stop Tracker"))
        } else if daemon.loaded && configuredToRun {
            trackerStatusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            trackerStatusLabel.stringValue = L("Starting · system service loaded")
            trackerServersValue.stringValue = "—"
            setServerPrimaryButtonTitle(trackerStartStopButton, L("Stop Tracker"))
        } else if configuredToRun {
            trackerStatusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            trackerStatusLabel.stringValue = L("Configured to run, but system service is stopped")
            trackerServersValue.stringValue = "0"
            setServerPrimaryButtonTitle(trackerStartStopButton, L("Start Tracker"))
        } else {
            trackerStatusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
            trackerStatusLabel.stringValue = daemon.installed ? L("Stopped · system service installed") : L("Stopped")
            trackerServersValue.stringValue = "0"
            setServerPrimaryButtonTitle(trackerStartStopButton, L("Start Tracker"))
        }
        let active = daemon.loaded && configuredToRun
        trackerPortField.isEnabled = !active && !trackerOperationInProgress
        trackerStartStopButton.isEnabled = !trackerOperationInProgress
        updateApplyButtonStates()
    }

    private func refreshAdminAccount() {
        guard let service else { return }
        if let admin = service.administratorAccount {
            adminValue.stringValue = "\(admin.login) · \(admin.name.isEmpty ? L("Administrator") : admin.name)"
            passwordButton.title = L("Change Password…")
        } else {
            adminValue.stringValue = L("No administrator account")
            passwordButton.title = L("Create Administrator…")
        }
        passwordButton.isEnabled = true
    }

    private func refreshServerSettings() {
        guard let service else { return }
        let control = service.serverState.advanced.controlPort
        serverPortField.stringValue = String(control)
        configuredTransferPortLabel.stringValue = LF("Transfer port %@ · configured (server port + 1)", String(UInt32(control) + 1))
        serverSettingsStatusLabel.stringValue = ""
        refreshLegacyFileRootDisplay()
        updateApplyButtonStates()
    }

    private func refreshLegacyFileRootDisplay() {
        guard let service else { return }
        let serverDaemon = daemonStatus(.server)
        let canChange = !service.status.isRunning && !serverDaemon.loaded
        if let url = service.legacyFilesURL {
            legacyFileRootValue.stringValue = url.path
            legacyFileRootValue.toolTip = url.path
            legacyUseModernRadio.state = .off
            legacyUseSeparateRadio.state = .on
            legacyFileRootButton.isEnabled = canChange
            legacyFileRootValue.isHidden = false
        } else {
            legacyFileRootValue.stringValue = L("Uses modern folder")
            legacyFileRootValue.toolTip = service.filesURL.path
            legacyUseModernRadio.state = .on
            legacyUseSeparateRadio.state = .off
            legacyFileRootButton.isEnabled = false
            legacyFileRootValue.isHidden = true
        }
        legacyUseModernRadio.isEnabled = canChange
        legacyUseSeparateRadio.isEnabled = canChange
        legacyFileRootClearButton.isEnabled = false
    }

    private func updateStatus(_ status: LegacyServerRuntimeStatus) {
        if status.isRunning {
            statusTitle.stringValue = L("Running · This App")
            let control = status.port.map(String.init) ?? "?"
            let transfer = status.transferPort.map(String.init) ?? "?"
            statusDetail.stringValue = LF("GUI-managed listeners · control TCP %@, transfers TCP %@", control, transfer)
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            setServerPrimaryButtonTitle(startStopButton, L("Stop Server"))
            portValue.stringValue = "\(control) / \(transfer)"
        } else if let lastServerOperationError {
            statusTitle.stringValue = L("Error")
            statusDetail.stringValue = lastServerOperationError
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            setServerPrimaryButtonTitle(startStopButton, L("Start Server"))
            portValue.stringValue = "—"
        } else {
            statusTitle.stringValue = L("Stopped")
            statusDetail.stringValue = L("No server listener is active in this app.")
            statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
            setServerPrimaryButtonTitle(startStopButton, L("Start Server"))
            portValue.stringValue = "—"
        }
        statusDetail.toolTip = statusDetail.stringValue
        fileRootButton.isEnabled = !status.isRunning
        legacyUseModernRadio.isEnabled = !status.isRunning
        legacyUseSeparateRadio.isEnabled = !status.isRunning
        legacyFileRootButton.isEnabled = !status.isRunning && service?.legacyFilesURL != nil
        clientsValue.stringValue = String(status.connectedClients)
        transfersValue.stringValue = String(status.activeFileTransfers)
        startStopButton.isEnabled = serverOperationState == .idle
        applyServerOperationPresentationIfNeeded()
        updateApplyButtonStates()
    }

    private func applyServerOperationPresentationIfNeeded() {
        switch serverOperationState {
        case .idle: return
        case .starting:
            statusTitle.stringValue = L("Starting…")
            statusDetail.stringValue = L("Opening the configured listeners.")
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            setServerPrimaryButtonTitle(startStopButton, L("Starting…"))
        case .stopping:
            statusTitle.stringValue = L("Stopping…")
            statusDetail.stringValue = L("Closing active listeners and sessions.")
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            setServerPrimaryButtonTitle(startStopButton, L("Stopping…"))
        }
        startStopButton.isEnabled = false
    }

    @objc private func saveServerSettings(_ sender: Any?) {
        guard let service, serverOperationState == .idle else { return }
        let port: UInt16
        do {
            port = try parseUInt16(serverPortField, name: L("Server port"), requirePositive: true)
            guard port < UInt16.max else {
                throw ServerStateError.invalidValue(L("Server port must be between 1 and 65534 because transfers use port +1."))
            }
            if portsConflict(serverPort: port, trackerPort: service.trackerConfiguration.port) {
                throw ServerStateError.invalidValue(L("Server/control and transfer ports must not conflict with the configured tracker TCP port."))
            }
        } catch {
            serverSettingsStatusLabel.stringValue = L("Not saved")
            presentError(title: L("Server Port Could Not Be Saved"), error: error)
            updateApplyButtonStates()
            return
        }

        let daemon = daemonStatus(.server)
        serverSettingsStatusLabel.stringValue = L("Applying…")
        serverPortApplyButton.isEnabled = false
        do {
            try service.updateServerPort(port)
        } catch {
            // Keep the edited value so it can be corrected, while the top status continues
            // to describe the listener that is actually active.
            refreshRuntimeStatus()
            serverSettingsStatusLabel.stringValue = L("Not saved")
            presentError(title: L("Server Port Could Not Be Saved"), error: error)
            appendLog(LF("ERROR: Server port change failed: %@", error.localizedDescription))
            updateApplyButtonStates()
            return
        }

        refreshServerSettings()
        if daemon.installed && daemon.loaded {
            do {
                try daemonManager.setRunning(true, kind: .server)
                serverSettingsStatusLabel.stringValue = L("Saved · system service restarted")
                appendLog(LF("Server port changed to %@. System service restarted.", String(port)))
            } catch {
                serverSettingsStatusLabel.stringValue = L("Saved · restart failed")
                appendLog(LF("ERROR: Server port %@ was saved, but the system service restart failed: %@", String(port), error.localizedDescription))
                presentMessage(title: L("Port Saved, but Service Restart Failed"),
                               message: L("The configured server port was saved, but the system service could not be restarted. The status above still shows the actual listener state."),
                               style: .warning)
            }
        } else {
            serverSettingsStatusLabel.stringValue = L("Saved")
            appendLog(LF("Server port changed to %@.", String(port)))
        }
        refreshRuntimeStatus()
        updateApplyButtonStates()
    }

    private func parseUInt16(_ field: NSTextField, name: String, requirePositive: Bool) throws -> UInt16 {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UInt16(text), !requirePositive || value > 0 else {
            throw ServerStateError.invalidValue(LF("%@ must be %@.", name, requirePositive ? "1…65535" : "0…65535"))
        }
        return value
    }

    private func updateTrackerStatus(_ status: LegacyTrackerRuntimeStatus) {
        guard let service else { return }
        trackerServersValue.stringValue = String(status.registeredServers)
        if status.isRunning {
            trackerStatusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            trackerStatusLabel.stringValue = LF("Running in this app · TCP %@", status.port.map(String.init) ?? "?")
            setServerPrimaryButtonTitle(trackerStartStopButton, L("Stop Tracker"))
        } else if service.trackerConfiguration.enabled {
            trackerStatusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            trackerStatusLabel.stringValue = L("Configured to run, but not running")
            setServerPrimaryButtonTitle(trackerStartStopButton, L("Start Tracker"))
        } else {
            trackerStatusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
            trackerStatusLabel.stringValue = L("Stopped")
            setServerPrimaryButtonTitle(trackerStartStopButton, L("Start Tracker"))
        }
        trackerPortField.isEnabled = !status.isRunning && !trackerOperationInProgress
        trackerStartStopButton.isEnabled = !trackerOperationInProgress
        updateApplyButtonStates()
    }

    private func localServerRunningForBot() -> Bool {
        guard let service else { return false }
        let daemon = cachedServerDaemonStatus
        return daemon.installed ? daemon.running : service.status.isRunning
    }

    private func refreshBotAvatar() {
        guard let service else {
            botAvatarImageView.image = nil
            botAvatarDetailLabel.stringValue = L("No custom Bot avatar")
            botAvatarRemoveButton.isEnabled = false
            return
        }
        if let data = service.botAvatarData, let image = NSImage(data: data) {
            botAvatarImageView.contentTintColor = nil
            botAvatarImageView.image = image
            botAvatarDetailLabel.stringValue = LF("128 × 128 PNG · %@ bytes", String(data.count))
            botAvatarRemoveButton.isEnabled = true
        } else {
            if #available(macOS 11.0, *) {
                botAvatarImageView.image = NSImage(systemSymbolName: "person.crop.square", accessibilityDescription: L("Bot avatar"))
                botAvatarImageView.contentTintColor = .secondaryLabelColor
            } else {
                botAvatarImageView.image = NSImage(named: NSImage.userName)
            }
            botAvatarDetailLabel.stringValue = L("No custom Bot avatar")
            botAvatarRemoveButton.isEnabled = false
        }
        botAvatarImageView.toolTip = service.botAvatarURL.path
    }

    @objc private func chooseBotAvatar(_ sender: Any?) {
        guard let service else { return }
        let panel = NSOpenPanel()
        panel.title = L("Choose Bot Avatar PNG")
        panel.prompt = L("Use Avatar")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.png] }
        else { panel.setValue(["png"], forKey: "allowedFileTypes") }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let png = try CarrachoServerBotAvatar.normalizedPNG(from: url)
            try service.setBotAvatar(png)
            refreshBotAvatar()
            refreshBotStatus()
        } catch {
            presentError(title: L("Bot Avatar Could Not Be Saved"), error: error)
        }
    }

    @objc private func removeBotAvatar(_ sender: Any?) {
        guard let service else { return }
        do {
            try service.setBotAvatar(nil)
            refreshBotAvatar()
            refreshBotStatus()
        } catch {
            presentError(title: L("Bot Avatar Could Not Be Removed"), error: error)
        }
    }

    private func refreshBotGreetingConfiguration() {
        guard let service else {
            botGreetingEnabledButton.state = .off
            botGreetingTemplateField.stringValue = LegacyBotAdminStatus.defaultGreetingTemplate
            botGreetingSaveButton.isEnabled = false
            return
        }
        let greeting = service.botGreetingConfiguration
        botGreetingEnabledButton.state = greeting.enabled ? .on : .off
        botGreetingTemplateField.stringValue = greeting.template
        botGreetingSaveButton.isEnabled = true
    }

    @objc private func saveBotGreeting(_ sender: Any?) {
        guard let service else { return }
        do {
            try service.setBotGreeting(enabled: botGreetingEnabledButton.state == .on,
                                       template: botGreetingTemplateField.stringValue)
            refreshBotGreetingConfiguration()
        } catch {
            presentError(title: L("Bot Greeting Could Not Be Saved"), error: error)
        }
    }

    private func refreshBotStatus() {
        guard let service else {
            botStatusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
            botStatusLabel.stringValue = L("Not connected")
            botStartStopButton.isEnabled = false
            return
        }

        refreshBotAvatar()
        let desired = service.botDesiredEnabled
        let status = service.botStatus
        let serverRunning = localServerRunningForBot()
        let connected = status?.connected == true
        botPipeValue.stringValue = service.botInterfaceURL.path
        botPipeValue.toolTip = service.botInterfaceURL.path

        if connected {
            botStatusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            botStatusLabel.stringValue = L("Connected · Public")
        } else if desired, let error = status?.lastError, !error.isEmpty {
            botStatusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            botStatusLabel.stringValue = L("Connection error")
        } else if desired && serverRunning {
            botStatusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            botStatusLabel.stringValue = L("Connecting…")
        } else if desired {
            botStatusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            botStatusLabel.stringValue = L("Waiting for local server")
        } else {
            botStatusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
            botStatusLabel.stringValue = L("Not connected")
        }

        setServerPrimaryButtonTitle(botStartStopButton, desired ? L("Disconnect Bot") : L("Connect Bot"))
        botStartStopButton.isEnabled = !botOperationInProgress && (desired || serverRunning)
        let errorText = status?.lastError ?? ""
        botErrorLabel.stringValue = errorText
        botErrorLabel.isHidden = errorText.isEmpty
    }

    @objc private func toggleBot(_ sender: Any?) {
        guard let service, !botOperationInProgress else { return }
        let shouldEnable = !service.botDesiredEnabled
        if shouldEnable && !localServerRunningForBot() {
            presentMessage(title: L("Start the Server First"),
                           message: L("The Bot can connect only while the local Carracho server is running."),
                           style: .warning)
            return
        }

        botOperationInProgress = true
        botStartStopButton.isEnabled = false
        defer {
            botOperationInProgress = false
            refreshBotStatus()
        }
        do {
            try service.setBotEnabled(shouldEnable)
        } catch {
            presentError(title: shouldEnable ? L("Bot Could Not Connect") : L("Bot Could Not Disconnect"), error: error)
        }
    }

    @objc private func toggleTracker(_ sender: Any?) {
        guard let service, !trackerOperationInProgress else { return }
        let daemon = daemonStatus(.tracker)
        let currentlyRunning = daemon.running || service.trackerStatus.isRunning ||
            (daemon.loaded && service.trackerConfiguration.enabled)
        let shouldRun = !currentlyRunning

        if shouldRun && portsConflict(serverPort: service.serverState.advanced.controlPort,
                                      trackerPort: service.trackerConfiguration.port) {
            presentMessage(title: L("Tracker Port Conflict"),
                           message: L("The tracker port conflicts with the configured server control or transfer port."),
                           style: .warning)
            return
        }

        trackerOperationInProgress = true
        trackerStartStopButton.isEnabled = false
        defer {
            trackerOperationInProgress = false
            refreshRuntimeStatus()
            refreshDaemonControls()
            updateApplyButtonStates()
        }

        if daemon.installed {
            let previousEnabled = service.trackerConfiguration.enabled
            do {
                if shouldRun {
                    try service.setTrackerEnabled(true, manageRuntime: false)
                    do {
                        try daemonManager.setRunning(true, kind: .tracker)
                    } catch {
                        if !previousEnabled { try? service.setTrackerEnabled(false, manageRuntime: false) }
                        throw error
                    }
                    appendTrackerLog(LF("Tracker system service started on TCP %@.", String(service.trackerConfiguration.port)))
                } else {
                    try daemonManager.setRunning(false, kind: .tracker)
                    do {
                        try service.setTrackerEnabled(false, manageRuntime: false)
                    } catch {
                        if previousEnabled { try? daemonManager.setRunning(true, kind: .tracker) }
                        throw error
                    }
                    appendTrackerLog(L("Tracker system service stopped."))
                }
            } catch {
                presentError(title: shouldRun ? L("Tracker Service Could Not Be Started") : L("Tracker Service Could Not Be Stopped"),
                             error: error)
                appendTrackerLog(LF("ERROR: Tracker service control failed: %@", error.localizedDescription))
            }
            return
        }

        do {
            try service.setTrackerEnabled(shouldRun, manageRuntime: true)
            if shouldRun {
                appendTrackerLog(LF("GUI-managed tracker started on TCP %@.", String(service.trackerConfiguration.port)))
            } else {
                appendTrackerLog(L("GUI-managed tracker stopped."))
            }
        } catch {
            presentError(title: shouldRun ? L("Tracker Could Not Start") : L("Tracker Could Not Stop"), error: error)
            appendTrackerLog(LF("ERROR: Tracker control failed: %@", error.localizedDescription))
        }
    }

    @objc private func trackerPortChanged(_ sender: Any?) {
        guard let service, !trackerOperationInProgress else { return }
        let raw = trackerPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UInt16(raw), value > 0 else {
            presentMessage(title: L("Invalid Tracker Port"), message: L("Enter a TCP port between 1 and 65535."), style: .warning)
            updateApplyButtonStates()
            return
        }
        guard !portsConflict(serverPort: service.serverState.advanced.controlPort, trackerPort: value) else {
            presentMessage(title: L("Tracker Port Conflict"), message: L("The tracker port must differ from both the server control port and its transfer port (+1)."), style: .warning)
            updateApplyButtonStates()
            return
        }
        let daemon = daemonStatus(.tracker)
        let trackerActive = service.trackerStatus.isRunning || (daemon.loaded && service.trackerConfiguration.enabled)
        guard !trackerActive else {
            presentMessage(title: L("Stop the Tracker First"), message: L("The tracker TCP port can be changed only while the effective tracker process is stopped."), style: .warning)
            return
        }
        trackerOperationInProgress = true
        updateApplyButtonStates()
        defer {
            trackerOperationInProgress = false
            refreshRuntimeStatus()
            refreshDaemonControls()
            updateApplyButtonStates()
        }

        do {
            try service.setTrackerPort(value)
            trackerPortField.stringValue = String(service.trackerConfiguration.port)
        } catch {
            // Keep the typed value after a persistence failure for correction.
            presentError(title: L("Tracker Port Could Not Be Changed"), error: error)
            appendTrackerLog(LF("ERROR: Tracker port change failed: %@", error.localizedDescription))
            return
        }

        appendTrackerLog(LF("Built-in tracker port set to TCP %@.", String(value)))
    }

    @objc private func installServerDaemon(_ sender: Any?) {
        guard let root = serverStateRootURL, let service else { return }
        do {
            if service.status.isRunning { service.stop() }
            try daemonManager.install(.server, rootURL: root)
            appendLog(L("System server daemon installed and started."))
            refreshRuntimeStatus()
            refreshDaemonControls()
        } catch {
            presentError(title: L("Server Daemon Could Not Be Installed"), error: error)
            appendLog(LF("ERROR: Server daemon install failed: %@", error.localizedDescription))
            refreshDaemonControls()
        }
    }

    @objc private func uninstallServerDaemon(_ sender: Any?) {
        guard let root = serverStateRootURL else { return }
        do {
            try daemonManager.uninstall(.server)
            try? FileManager.default.removeItem(at: CarrachoLaunchDaemonManager.statusURL(kind: .server, rootURL: root))
            appendLog(L("System server daemon uninstalled."))
            refreshRuntimeStatus()
            refreshDaemonControls()
        } catch {
            presentError(title: L("Server Daemon Could Not Be Uninstalled"), error: error)
            appendLog(LF("ERROR: Server daemon uninstall failed: %@", error.localizedDescription))
        }
    }

    @objc private func installTrackerDaemon(_ sender: Any?) {
        guard let root = serverStateRootURL, let service else { return }
        do {
            service.trackerRuntime.stop()
            try daemonManager.install(.tracker, rootURL: root)
            appendTrackerLog(service.trackerConfiguration.enabled
                ? L("System tracker daemon installed; tracker is running as a service.")
                : L("System tracker daemon installed; tracker remains stopped."))
            refreshRuntimeStatus()
            refreshDaemonControls()
        } catch {
            presentError(title: L("Tracker Daemon Could Not Be Installed"), error: error)
            appendTrackerLog(LF("ERROR: Tracker daemon install failed: %@", error.localizedDescription))
            refreshDaemonControls()
        }
    }

    @objc private func uninstallTrackerDaemon(_ sender: Any?) {
        guard let root = serverStateRootURL, let service else { return }
        do {
            try daemonManager.uninstall(.tracker)
            try? FileManager.default.removeItem(at: CarrachoLaunchDaemonManager.statusURL(kind: .tracker, rootURL: root))
            if service.trackerConfiguration.enabled { _ = try service.startConfiguredTracker() }
            appendTrackerLog(L("System tracker daemon uninstalled. Tracker returned to GUI-managed mode."))
            refreshRuntimeStatus()
            refreshDaemonControls()
        } catch {
            presentError(title: L("Tracker Daemon Could Not Be Uninstalled"), error: error)
            appendTrackerLog(LF("ERROR: Tracker daemon uninstall failed: %@", error.localizedDescription))
        }
    }

    @objc private func toggleServer(_ sender: Any?) {
        guard let service, serverOperationState == .idle else { return }
        let daemon = daemonStatus(.server)
        let currentlyRunning = daemon.installed ? daemon.loaded : service.status.isRunning
        lastServerOperationError = nil
        serverOperationState = currentlyRunning ? .stopping : .starting
        applyServerOperationPresentationIfNeeded()
        updateApplyButtonStates()
        window?.displayIfNeeded()
        defer {
            serverOperationState = .idle
            refreshRuntimeStatus()
            refreshDaemonControls()
        }

        if daemon.installed {
            do {
                try daemonManager.setRunning(!daemon.loaded, kind: .server)
                appendLog(daemon.loaded ? L("Server system service stopped.") : L("Server system service started."))
            } catch {
                lastServerOperationError = error.localizedDescription
                presentError(title: daemon.loaded ? L("Server Service Could Not Be Stopped") : L("Server Service Could Not Be Started"), error: error)
                appendLog(LF("ERROR: %@", error.localizedDescription))
            }
            return
        }
        if service.status.isRunning {
            service.stop()
            appendLog(L("GUI-managed server stopped."))
            return
        }
        do {
            let port = try service.start()
            appendLog(LF("GUI-managed server started on TCP %@.", String(port)))
            fileRootValue.stringValue = service.filesURL.path
            fileRootValue.toolTip = service.filesURL.path
            refreshServerSettings()
        } catch {
            lastServerOperationError = error.localizedDescription
            presentError(title: L("Server Could Not Start"), error: error)
            appendLog(LF("ERROR: %@", error.localizedDescription))
        }
    }

    @objc private func administratorAction(_ sender: Any?) {
        guard let service else { return }
        if service.administratorAccount == nil {
            createAdministrator(sender)
        } else {
            changePassword(sender)
        }
    }

    private func createAdministrator(_ sender: Any?) {
        guard let service, service.administratorAccount == nil, let window else { return }

        let login = NSTextField(string: service.suggestedAdministratorLogin)
        let name = NSTextField(string: L("Administrator"))
        let first = NSSecureTextField(string: "")
        let second = NSSecureTextField(string: "")
        login.placeholderString = L("Login")
        name.placeholderString = L("Display name")
        first.placeholderString = L("Password")
        second.placeholderString = L("Repeat password")
        for field in [login, name, first, second] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }

        let note = NSTextField(wrappingLabelWithString: L("The new administrator receives all server permissions. In Legacy Compatible mode the password must fit the Classic 64-byte MacRoman limit."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 320
        let accessory = stack([
            labeled(L("Login"), login),
            labeled(L("Name"), name),
            labeled(L("Password"), first),
            labeled(L("Repeat password"), second),
            note,
        ], vertical: true, spacing: 9)
        accessory.frame = NSRect(x: 0, y: 0, width: 340, height: 245)

        let alert = NSAlert()
        alert.messageText = L("Create Administrator Account")
        alert.informativeText = L("No administrator account currently exists on this server.")
        alert.alertStyle = .informational
        alert.accessoryView = accessory
        alert.addButton(withTitle: L("Create Administrator"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = login
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let accountLogin = login.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let accountName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let password = first.stringValue
            guard !accountLogin.isEmpty else {
                self.presentMessage(title: L("Login Required"), message: L("Enter a login for the administrator account."))
                return
            }
            guard !password.isEmpty else {
                self.presentMessage(title: L("Password Required"), message: L("The administrator password must not be empty."))
                return
            }
            guard password == second.stringValue else {
                self.presentMessage(title: L("Passwords Do Not Match"), message: L("Enter the same password in both fields."))
                return
            }
            do {
                let created = try service.createAdministrator(login: accountLogin, name: accountName, password: password)
                self.restartServerDaemonIfLoadedReportingFailure()
                self.refreshAdminAccount()
                self.appendLog(LF("Administrator account created: %@.", created.login))
                self.presentMessage(title: L("Administrator Created"), message: LF("The administrator account ‘%@’ was created with full permissions.", created.login))
            } catch {
                self.presentError(title: L("Administrator Could Not Be Created"), error: error)
                self.appendLog(LF("ERROR: Could not create administrator: %@", error.localizedDescription))
            }
        }
    }

    @objc private func changePassword(_ sender: Any?) {
        guard let service, let admin = service.administratorAccount, let window else { return }

        let first = NSSecureTextField(string: "")
        let second = NSSecureTextField(string: "")
        first.placeholderString = L("New password")
        second.placeholderString = L("Repeat password")
        first.translatesAutoresizingMaskIntoConstraints = false
        second.translatesAutoresizingMaskIntoConstraints = false
        first.widthAnchor.constraint(equalToConstant: 320).isActive = true
        second.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let note = NSTextField(wrappingLabelWithString: L("The new password is stored using the server's password verifier. In Legacy Compatible mode it must fit the Classic 64-byte MacRoman limit."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 320
        let accessory = stack([
            labeled(L("New password"), first),
            labeled(L("Repeat password"), second),
            note,
        ], vertical: true, spacing: 10)
        accessory.frame = NSRect(x: 0, y: 0, width: 340, height: 145)

        let alert = NSAlert()
        alert.messageText = L("Change Administrator Password")
        alert.informativeText = LF("Account: %@", admin.login)
        alert.alertStyle = .informational
        alert.accessoryView = accessory
        alert.addButton(withTitle: L("Change Password"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = first
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let password = first.stringValue
            guard !password.isEmpty else {
                self.presentMessage(title: L("Password Required"), message: L("The administrator password must not be empty."))
                return
            }
            guard password == second.stringValue else {
                self.presentMessage(title: L("Passwords Do Not Match"), message: L("Enter the same password in both fields."))
                return
            }
            do {
                _ = try service.changeAdministratorPassword(to: password)
                self.restartServerDaemonIfLoadedReportingFailure()
                self.refreshAdminAccount()
                self.appendLog(LF("Administrator password changed for %@.", admin.login))
                self.presentMessage(title: L("Password Changed"), message: L("The administrator password was updated successfully."))
            } catch {
                self.presentError(title: L("Password Could Not Be Changed"), error: error)
                self.appendLog(LF("ERROR: Could not change administrator password: %@", error.localizedDescription))
            }
        }
    }

    @objc private func chooseFileRoot(_ sender: Any?) {
        guard let currentService = service, serverStateRootURL != nil, let window else { return }
        let serverDaemon = daemonStatus(.server)
        guard !currentService.status.isRunning && !serverDaemon.loaded else {
            presentMessage(title: L("Stop the Server First"),
                           message: L("The file root cannot be changed while the local server or system daemon is running."))
            return
        }

        let panel = NSOpenPanel()
        panel.title = L("Choose Carracho File Root")
        panel.prompt = L("Use as File Root")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = currentService.filesURL
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let selected = panel.url else { return }
            let selectedRoot = selected.standardizedFileURL
            do {
                try currentService.updateFilesRoot(selectedRoot)
                self.fileRootValue.stringValue = currentService.filesURL.path
                self.fileRootValue.toolTip = currentService.filesURL.path
                self.refreshLegacyFileRootDisplay()
                self.appendLog(LF("File root changed to %@", currentService.filesURL.path))
            } catch {
                self.presentError(title: L("File Root Could Not Be Changed"), error: error)
                self.appendLog(LF("ERROR: Could not change file root: %@", error.localizedDescription))
            }
        }
    }

    @objc private func chooseLegacyFileRoot(_ sender: Any?) {
        guard let currentService = service, serverStateRootURL != nil, let window else { return }
        let serverDaemon = daemonStatus(.server)
        guard !currentService.status.isRunning && !serverDaemon.loaded else {
            presentMessage(title: L("Stop the Server First"),
                           message: L("The Classic / Legacy file root cannot be changed while the server is running."))
            return
        }
        let panel = NSOpenPanel()
        panel.title = L("Choose Classic / Legacy File Root")
        panel.prompt = L("Use for Classic")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = currentService.legacyFilesURL ?? currentService.filesURL
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let selected = panel.url else { return }
            do {
                try currentService.updateLegacyFilesRoot(selected.standardizedFileURL)
                self.refreshLegacyFileRootDisplay()
                self.appendLog(LF("Classic / Legacy file root changed to %@", selected.standardizedFileURL.path))
            } catch {
                self.presentError(title: L("Legacy File Root Could Not Be Changed"), error: error)
                self.appendLog(LF("ERROR: Could not change Classic / Legacy file root: %@", error.localizedDescription))
            }
        }
    }

    @objc private func clearLegacyFileRoot(_ sender: Any?) {
        guard let currentService = service else { return }
        let serverDaemon = daemonStatus(.server)
        guard !currentService.status.isRunning && !serverDaemon.loaded else {
            presentMessage(title: L("Stop the Server First"),
                           message: L("The Classic / Legacy file root cannot be changed while the server is running."))
            return
        }
        do {
            try currentService.updateLegacyFilesRoot(nil)
            refreshLegacyFileRootDisplay()
            appendLog(L("Classic / Legacy file root disabled; Classic uses the normal File Root"))
        } catch {
            presentError(title: L("Legacy File Root Could Not Be Changed"), error: error)
        }
    }

    private func restartServerDaemonIfLoadedReportingFailure() {
        let daemon = daemonStatus(.server)
        guard daemon.installed && daemon.loaded else { return }
        do {
            try daemonManager.setRunning(true, kind: .server)
        } catch {
            appendLog(LF("ERROR: Server daemon could not be restarted after the saved account change: %@", error.localizedDescription))
            presentMessage(title: L("Saved, but Daemon Restart Failed"),
                           message: L("The account change was saved, but the running server daemon could not be restarted. Restart it from the Server controls so it loads the new account data."),
                           style: .warning)
        }
    }

    private func refreshDaemonLogIfNeeded() {
        guard let root = serverStateRootURL else { return }
        for kind in CarrachoDaemonKind.allCases {
            guard daemonStatus(kind).installed else {
                daemonLogSignatures[kind] = nil
                continue
            }
            let fileName = kind == .server ? "carracho-server.log" : "tracker-daemon.stderr.log"
            let url = root.appendingPathComponent("logs/" + fileName)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date else { continue }
            let signature = "\(modified.timeIntervalSince1970)-\(attributes[.size] ?? 0)"
            guard signature != daemonLogSignatures[kind],
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { handle.closeFile() }
            let size = handle.seekToEndOfFile()
            let maximum: UInt64 = 1_000_000
            handle.seek(toFileOffset: size > maximum ? size - maximum : 0)
            var lines = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").map(String.init)
            if size > maximum, !lines.isEmpty {
                lines.removeFirst()
            }
            let panel = kind == .server ? serverLog : trackerLog
            panel.setDaemonLines(Array(lines.suffix(5_000)))
            daemonLogSignatures[kind] = signature
        }
    }

    private func runSmokeIfRequested() {
        guard smokeDumpPath != nil, let service else { return }
        do {
            let before = service.status
            let admin = service.administratorAccount
            let smokePassword = "CarrachoSmoke42"
            if let admin {
                _ = try service.changeAdministratorPassword(to: smokePassword)
                guard service.backend.authenticateModern(login: admin.login, password: smokePassword) != nil else {
                    throw ServerStateError.invalidValue("administrator password smoke verification failed")
                }
            }
            let port = try service.start(port: 0)
            let running = service.status
            service.stop()
            let stopped = service.status
            writeSmokeSnapshot(success: admin != nil && !before.isRunning && running.isRunning && !stopped.isRunning,
                               note: "ephemeral control port \(port)")
        } catch {
            writeSmokeSnapshot(success: false, note: error.localizedDescription)
        }
    }

    private func writeSmokeSnapshot(success: Bool, note: String) {
        guard let path = smokeDumpPath else { return }
        let status = service?.status
        let object: [String: Any] = [
            "success": success,
            "note": note,
            "adminAccount": service?.administratorAccount?.login ?? NSNull(),
            "databasePath": service?.databaseURL.path ?? NSNull(),
            "fileRootPath": service?.filesURL.path ?? NSNull(),
            "isRunningAfterSmoke": status?.isRunning ?? false,
            "connectedClients": status?.connectedClients ?? 0,
            "activeFileTransfers": status?.activeFileTransfers ?? 0,
            "trackerEnabled": service?.trackerConfiguration.enabled ?? false,
            "trackerRunning": service?.trackerStatus.isRunning ?? false,
            "trackerPort": service?.trackerStatus.port ?? service?.trackerConfiguration.port ?? LegacyTrackerProtocol.port,
            "trackerRegisteredServers": service?.trackerStatus.registeredServers ?? 0,
            "bannerBytes": service?.serverState.identity.bannerData?.count ?? 0,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private func argumentValue(prefix: String) -> String? {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
    }

    private func appendLog(_ line: String) { serverLog.append(line) }
    private func appendTrackerLog(_ line: String) { trackerLog.append(line) }

    private func presentError(title: String, error: Error) {
        presentMessage(title: title, message: error.localizedDescription, style: .critical)
    }

    private func presentMessage(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: L("OK"))
        if let window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func metric(title: String, value: NSTextField) -> NSView {
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        value.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        let column = stack([caption, value], vertical: true, spacing: 2)
        column.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return column
    }

    private func settingsLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        return stack([label, control], vertical: true, spacing: 4)
    }

    private func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        return view
    }

    private func card(_ content: NSView) -> NSView {
        let view = ServerCardView()
        view.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 9),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -9),
        ])
        return view
    }

    private func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.distribution = .fill
        stack.spacing = spacing
        if vertical {
            for child in views {
                child.translatesAutoresizingMaskIntoConstraints = false
                let width = child.widthAnchor.constraint(equalTo: stack.widthAnchor)
                width.priority = .defaultHigh
                width.isActive = true
            }
        }
        return stack
    }
}

#endif
