import Cocoa
@testable import Carracho

// Run against the real client module and AppKit; no server or saved user session is loaded.
let app = NSApplication.shared
let controller = ViewController(nibName: nil, bundle: nil)
controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 1360, height: 820))
controller.didProcessLaunchArguments = true
controller.didRestoreMainWindowFrame = true
controller.buildInterface()
let window = NSWindow(contentRect: controller.view.bounds,
                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.contentView = controller.view
window.orderFront(nil)
let table = controller.fileTable
let scroll = table.enclosingScrollView!
var checks = 0

func settle() {
    controller.view.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    controller.view.layoutSubtreeIfNeeded()
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message); clip=\(scroll.contentView.bounds), insets=\(scroll.contentView.contentInsets)\n", stderr)
        exit(1)
    }
    checks += 1
}

func installRows(_ count: Int, reset: Bool) {
    controller.lastDirectory = LegacyDirectoryListing(currentPath: Data(), entries: (0..<count).map {
        LegacyDirectoryEntry(name: Data(String(format: "File %03d", $0).utf8),
                             size: 1, timestamp: 0, fileType: 0, creator: 0, flags: 0)
    })
    controller.fileShouldResetScrollOnNextReload = reset
    controller.reloadCatalogViews()
    settle()
}

func checkFirstRow(_ context: String) {
    let clip = scroll.contentView
    let firstRow = table.rect(ofRow: 0)
    // Exclude the fixed table header from the visible document area.
    let visibleTop = clip.bounds.minY + clip.contentInsets.top
    let visibleBottom = clip.bounds.maxY - clip.contentInsets.bottom
    check(firstRow.minY >= visibleTop - 0.5 && firstRow.maxY <= visibleBottom + 0.5,
          "\(context): first row must be fully visible below the header")
}

func scrollTo(_ y: CGFloat) {
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
    settle()
}

for style: NSScroller.Style in [.legacy, .overlay] {
    scroll.scrollerStyle = style
    for workspace: ViewController.Workspace in [.overview, .files] {
        controller.selectWorkspace(workspace)
        installRows(120, reset: true)
        checkFirstRow("initial \(workspace), \(style)")
        for _ in 0..<3 { controller.reloadCatalogViews(); settle() }
        checkFirstRow("repeated reload \(workspace), \(style)")

        // Test near-top offsets too: these must not be rounded back to the first row.
        for y: CGFloat in [5, 147, 580] {
            scrollTo(y)
            let saved = scroll.contentView.bounds.origin.y
            for destination: ViewController.Workspace in [.news, .conferences, .messageCenter] {
                controller.selectWorkspace(destination)
                settle()
                controller.selectWorkspace(workspace)
                settle()
                check(abs(scroll.contentView.bounds.origin.y - saved) < 0.5,
                      "\(workspace) -> \(destination) -> \(workspace) preserves \(saved)")
            }
        }

        table.selectRowIndexes(IndexSet(integer: 25), byExtendingSelection: false)
        let selected = controller.selectedFilePaths
        let saved = scroll.contentView.bounds.origin.y
        installRows(125, reset: false)
        check(abs(scroll.contentView.bounds.origin.y - saved) < 0.5, "refresh preserves scroll")
        check(controller.selectedFilePaths == selected && !selected.isEmpty, "refresh preserves selection")

        // A folder navigation still resets the scroll, including when it arrives offscreen.
        controller.selectWorkspace(.news)
        installRows(27, reset: true)
        controller.selectWorkspace(workspace)
        settle()
        checkFirstRow("folder loaded while hidden")
        installRows(2, reset: true)
        checkFirstRow("short folder")
        installRows(0, reset: true)
        installRows(120, reset: true)
        checkFirstRow("empty to long folder")
    }

    controller.selectWorkspace(.overview)
    scrollTo(350)
    controller.selectWorkspace(.files)
    settle()
    check(abs(scroll.contentView.bounds.origin.y - 350) < 0.5, "shared card overview -> files")
    controller.selectWorkspace(.overview)
    settle()
    check(abs(scroll.contentView.bounds.origin.y - 350) < 0.5, "shared card files -> overview")
}
print("PASS: \(checks) AppKit file scrolling regression checks")
window.orderOut(nil)
