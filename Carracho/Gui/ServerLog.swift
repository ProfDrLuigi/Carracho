import Cocoa
import QuickLookUI

// MARK: - ServerLog

extension ViewController {

    func makeServerLogAdminPage() -> NSView {
        let page = adminPage(title: L("Server Log"), subtitle: L("Connection and protocol activity"))
        serverLogTextView.isEditable = false
        serverLogTextView.isSelectable = true
        serverLogTextView.isRichText = false
        applyServerLogFontSize()
        let log = textScroll(serverLogTextView)
        configureContentFontSizePopup(serverLogFontSizePopup, selectedSize: serverLogFontSize, help: L("Server Log font size"))

        serverLogFilterPopup.removeAllItems()
        for category in ServerLogFilter.Category.allCases {
            serverLogFilterPopup.addItem(withTitle: L(category.localizedKey))
            serverLogFilterPopup.lastItem?.tag = category.rawValue
        }
        serverLogFilterPopup.selectItem(withTag: ServerLogFilter.Category.all.rawValue)
        serverLogFilterPopup.target = self
        serverLogFilterPopup.action = #selector(serverLogFilterChanged(_:))
        serverLogFilterPopup.toolTip = L("Filter log lines by keyword category")
        serverLogFilterPopup.widthAnchor.constraint(equalToConstant: 155).isActive = true

        serverLogFilterField.placeholderString = L("Filter server log…")
        serverLogFilterField.toolTip = L("Search server log by IP, username or message text")
        serverLogFilterField.target = self
        serverLogFilterField.action = #selector(serverLogFilterChanged(_:))
        serverLogFilterField.sendsSearchStringImmediately = true
        serverLogFilterField.sendsWholeSearchString = false
        serverLogFilterField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        serverLogFilterStatusLabel.font = .systemFont(ofSize: 11)
        serverLogFilterStatusLabel.textColor = CarrachoTheme.secondaryText

        let save = NSButton(title: L("Save Log"), target: self, action: #selector(saveServerLog(_:)))
        save.toolTip = L("Save complete unfiltered server log")
        let refresh = NSButton(title: L("Refresh"), target: self, action: #selector(refreshServerLog(_:)))
        let clear = NSButton(title: L("Clear Log"), target: self, action: #selector(clearServerLog(_:)))
        let controls = NSStackView(views: [serverLogFilterPopup, serverLogFilterField,
                                           serverLogFontSizePopup, NSView(), refresh, save, clear])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        appendAdminContent([controls, serverLogFilterStatusLabel, log], to: page, minimumBodyHeight: 520)
        return page
    }

    @objc func serverLogFilterChanged(_ sender: Any?) {
        applyServerLogFilters()
    }

    func applyServerLogFilters(scrollToEnd: Bool = false) {
        guard !remoteServerLogLoading else { return }
        let category = ServerLogFilter.Category(rawValue: serverLogFilterPopup.selectedTag()) ?? .all
        let result = ServerLogFilter.apply(to: serverLogRawText,
                                           category: category,
                                           query: serverLogFilterField.stringValue)
        serverLogTextView.string = result.text
        serverLogFilterStatusLabel.stringValue = LF("Showing %@ of %@ log lines",
                                                   String(result.visibleCount), String(result.total))
        if scrollToEnd { serverLogTextView.scrollToEndOfDocument(nil) }
    }

    @objc func refreshServerLog(_ sender: Any?) {
        guard client.isConnected else {
            remoteServerLogLoading = false
            serverLogRawText = localServerLogLines.joined(separator: "\n")
            applyServerLogFilters(scrollToEnd: true)
            return
        }
        guard canAccessAdministrativeWorkspace(.serverLog), !remoteServerLogLoading else { return }
        remoteServerLogLoading = true
        serverLogTextView.string = L("Loading server log…")
        serverLogFilterStatusLabel.stringValue = ""
        let requestClient = client
        requestClient.requestServerLog { [weak self, weak requestClient] result in
            guard let self, let requestClient, self.client === requestClient else { return }
            self.remoteServerLogLoading = false
            switch result {
            case let .success(text):
                self.serverLogRawText = text
                self.applyServerLogFilters(scrollToEnd: true)
            case let .failure(error):
                self.serverLogRawText = ""
                self.serverLogTextView.string = LF("Server log could not be loaded.\n\n%@", Self.displayMessage(for: error))
                self.serverLogFilterStatusLabel.stringValue = ""
            }
        }
    }

    @objc func clearServerLog(_ sender: Any?) {
        guard client.isConnected else {
            localServerLogLines.removeAll(keepingCapacity: true)
            serverLogRawText = ""
            applyServerLogFilters()
            return
        }
        guard canAccessAdministrativeWorkspace(.serverLog), !remoteServerLogLoading else { return }
        remoteServerLogLoading = true
        let requestClient = client
        requestClient.clearServerLog { [weak self, weak requestClient] result in
            guard let self, let requestClient, self.client === requestClient else { return }
            self.remoteServerLogLoading = false
            switch result {
            case .success:
                self.refreshServerLog(nil)
            case let .failure(error):
                self.showAdminError(error)
            }
        }
    }

    @objc func saveServerLog(_ sender: Any?) {
        guard let window = view.window else { return }
        // Filtering is presentation-only. Export all retrieved entries for reliable diagnosis.
        let text = serverLogRawText
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Carracho Server Log.txt"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                self.showAdminSaved(LF("Server log saved to %@.", url.lastPathComponent))
            } catch { self.showAdminError(error) }
        }
    }

    func applyServerLogFontSize() {
        serverLogTextView.font = NSFont.monospacedSystemFont(ofSize: serverLogFontSize, weight: .regular)
    }

}
