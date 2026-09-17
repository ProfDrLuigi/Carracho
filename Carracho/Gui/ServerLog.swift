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
        let save = NSButton(title: L("Save Log"), target: self, action: #selector(saveServerLog(_:)))
        let refresh = NSButton(title: L("Refresh"), target: self, action: #selector(refreshServerLog(_:)))
        let clear = NSButton(title: L("Clear Log"), target: self, action: #selector(clearServerLog(_:)))
        let controls = NSStackView(views: [serverLogFontSizePopup, NSView(), refresh, save, clear])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        appendAdminContent([controls, log], to: page, minimumBodyHeight: 520)
        return page
    }

    @objc func refreshServerLog(_ sender: Any?) {
        guard client.isConnected else {
            remoteServerLogLoading = false
            serverLogTextView.string = localServerLogLines.joined(separator: "\n")
            serverLogTextView.scrollToEndOfDocument(nil)
            return
        }
        guard canAccessAdministrativeWorkspace(.serverLog), !remoteServerLogLoading else { return }
        remoteServerLogLoading = true
        serverLogTextView.string = L("Loading server log…")
        let requestClient = client
        requestClient.requestServerLog { [weak self, weak requestClient] result in
            guard let self, let requestClient, self.client === requestClient else { return }
            self.remoteServerLogLoading = false
            switch result {
            case let .success(text):
                self.serverLogTextView.string = text
                self.serverLogTextView.scrollToEndOfDocument(nil)
            case let .failure(error):
                self.serverLogTextView.string = LF("Server log could not be loaded.\n\n%@", Self.displayMessage(for: error))
            }
        }
    }

    @objc func clearServerLog(_ sender: Any?) {
        guard client.isConnected else {
            localServerLogLines.removeAll(keepingCapacity: true)
            serverLogTextView.string = ""
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
        let text = serverLogTextView.string
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
