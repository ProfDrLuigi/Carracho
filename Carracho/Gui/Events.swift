import Cocoa
import QuickLookUI

// MARK: - Events

extension ViewController {

    func makeEventsAdminPage() -> NSView {
        let page = adminPage(title: L("Events"), subtitle: L("User activity audit trail, independent of the server log"))
        eventLogTextView.isEditable = false
        eventLogTextView.isSelectable = true
        eventLogTextView.isRichText = false
        applyEventsFontSize()
        let log = textScroll(eventLogTextView)

        eventLogFilterPopup.removeAllItems()
        for (title, tag) in [("All Events", 0), ("Sessions", 1), ("Files", 2), ("News", 3),
                             ("Chat & Messages", 4), ("Transfers", 5), ("Administration", 6)] {
            eventLogFilterPopup.addItem(withTitle: L(title))
            eventLogFilterPopup.lastItem?.tag = tag
        }
        eventLogFilterPopup.selectItem(withTag: 0)
        eventLogFilterPopup.target = self
        eventLogFilterPopup.action = #selector(eventLogFilterChanged(_:))
        eventLogFilterPopup.toolTip = L("Filter events by category")
        eventLogFilterPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true

        eventLogFilterField.placeholderString = L("Filter events…")
        eventLogFilterField.target = self
        eventLogFilterField.action = #selector(eventLogFilterChanged(_:))
        eventLogFilterField.sendsSearchStringImmediately = true
        eventLogFilterField.sendsWholeSearchString = false
        eventLogFilterField.toolTip = L("Filter by user, action, path, category, IP or any event text")
        eventLogFilterField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        configureContentFontSizePopup(eventsFontSizePopup, selectedSize: eventsFontSize, help: L("Events font size"))
        eventLogFilterStatusLabel.textColor = CarrachoTheme.secondaryText
        eventLogFilterStatusLabel.font = .systemFont(ofSize: 11)

        let save = NSButton(title: L("Save Events"), target: self, action: #selector(saveEventLog(_:)))
        let refresh = NSButton(title: L("Refresh"), target: self, action: #selector(refreshEventLog(_:)))
        let clear = NSButton(title: L("Clear Events"), target: self, action: #selector(clearEventLog(_:)))
        let controls = NSStackView(views: [eventLogFilterPopup, eventLogFilterField, eventsFontSizePopup, NSView(), refresh, save, clear])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        appendAdminContent([controls, eventLogFilterStatusLabel, log], to: page, minimumBodyHeight: 520)
        return page
    }

    @objc func eventLogFilterChanged(_ sender: Any?) {
        applyEventLogFilters()
    }

    func eventLogLineMatchesPreset(_ line: String) -> Bool {
        switch eventLogFilterPopup.selectedTag() {
        case 1: return line.contains("category=\"session\"")
        case 2: return line.contains("category=\"files\"")
        case 3: return line.contains("category=\"news\"")
        case 4: return line.contains("category=\"chat\"") || line.contains("category=\"messages\"")
        case 5: return line.contains("category=\"transfers\"")
        case 6: return line.contains("category=\"administration\"") || line.contains("category=\"account\"")
        default: return true
        }
    }

    func applyEventLogFilters(scrollToEnd: Bool = false) {
        let lines = eventLogRawText.split(whereSeparator: \.isNewline).map(String.init)
        let queryTokens = eventLogFilterField.stringValue
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased() }
        let warningLines = lines.filter { $0.hasPrefix("[Showing the last ") }
        let eventLines = lines.filter { !$0.hasPrefix("[Showing the last ") }
        let filtered = eventLines.filter { line in
            guard eventLogLineMatchesPreset(line) else { return false }
            if queryTokens.isEmpty { return true }
            let haystack = line.lowercased()
            return queryTokens.allSatisfy { haystack.contains($0) }
        }
        var visibleLines = warningLines
        visibleLines.append(contentsOf: filtered)
        eventLogTextView.string = visibleLines.joined(separator: "\n")
        eventLogFilterStatusLabel.stringValue = LF("Showing %@ of %@ events", String(filtered.count), String(eventLines.count))
        if scrollToEnd { eventLogTextView.scrollToEndOfDocument(nil) }
    }

    @objc func refreshEventLog(_ sender: Any?) {
        guard client.isConnected else {
            remoteEventLogLoading = false
            do {
                eventLogRawText = try localServerRuntime?.eventLogTextSnapshot() ?? ""
                applyEventLogFilters(scrollToEnd: true)
            } catch {
                eventLogRawText = ""
                eventLogTextView.string = LF("Event log could not be loaded.\n\n%@", Self.displayMessage(for: error))
                eventLogFilterStatusLabel.stringValue = ""
            }
            return
        }
        guard canAccessAdministrativeWorkspace(.events), !remoteEventLogLoading else { return }
        remoteEventLogLoading = true
        eventLogTextView.string = L("Loading events…")
        let requestClient = client
        requestClient.requestEventLog { [weak self, weak requestClient] result in
            guard let self, let requestClient, self.client === requestClient else { return }
            self.remoteEventLogLoading = false
            switch result {
            case let .success(text):
                self.eventLogRawText = text
                self.applyEventLogFilters(scrollToEnd: true)
            case let .failure(error):
                self.eventLogRawText = ""
                self.eventLogTextView.string = LF("Event log could not be loaded.\n\n%@", Self.displayMessage(for: error))
                self.eventLogFilterStatusLabel.stringValue = ""
            }
        }
    }

    @objc func clearEventLog(_ sender: Any?) {
        guard client.isConnected else {
            do {
                try localServerRuntime?.clearEventLogLocally()
                eventLogRawText = ""
                applyEventLogFilters()
            } catch { showAdminError(error) }
            return
        }
        guard canAccessAdministrativeWorkspace(.events), !remoteEventLogLoading else { return }
        remoteEventLogLoading = true
        let requestClient = client
        requestClient.clearEventLog { [weak self, weak requestClient] result in
            guard let self, let requestClient, self.client === requestClient else { return }
            self.remoteEventLogLoading = false
            switch result {
            case .success: self.refreshEventLog(nil)
            case let .failure(error): self.showAdminError(error)
            }
        }
    }

    @objc func saveEventLog(_ sender: Any?) {
        guard let window = view.window else { return }
        let text = eventLogTextView.string
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Carracho Events.txt"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                self.showAdminSaved(LF("Events saved to %@.", url.lastPathComponent))
            } catch { self.showAdminError(error) }
        }
    }

    func applyEventsFontSize() {
        eventLogTextView.font = NSFont.monospacedSystemFont(ofSize: eventsFontSize, weight: .regular)
    }

}
