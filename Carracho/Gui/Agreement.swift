import Cocoa
import QuickLookUI

// MARK: - Agreement

extension ViewController {

    func makeAgreementAdminPage() -> NSView {
        let page = adminPage(title: L("Agreement"), subtitle: L("Text shown during login when the agreement is enabled"))
        agreementEditor.font = NSFont.systemFont(ofSize: 13)
        agreementEditor.isRichText = false
        let scroll = textScroll(agreementEditor)
        let save = NSButton(title: L("Save"), target: self, action: #selector(saveAgreement(_:)))
        let controls = NSStackView(views: [save, agreementCheckbox])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 12
        appendAdminContent([scroll, controls], to: page, minimumBodyHeight: 520)
        return page
    }

    func reloadAgreementAdministration() {
        guard client.isConnected else {
            agreementEditor.string = localServerState.agreement.text
            agreementCheckbox.state = localServerState.agreement.enabled ? .on : .off
            return
        }
        guard remotePermissionEnabled(LegacyAccountPermissionBit.editServerAgreement) else {
            agreementEditor.string = ""
            agreementCheckbox.state = .off
            return
        }
        client.requestServerSettings(fields: [LegacyServerSettingField.agreement]) { [weak self] result in
            guard let self else { return }
            do {
                let values = try result.get()
                guard let raw = values[LegacyServerSettingField.agreement] else {
                    throw LegacyProtocolError.invalidRecord("connected server did not return its Agreement setting")
                }
                let setting = try LegacyAgreementSetting.decode(raw)
                guard let text = String(data: setting.content.text, encoding: .macOSRoman) else {
                    throw LegacyProtocolError.invalidRecord("server Agreement is not valid MacRoman")
                }
                self.agreementEditor.string = text
                self.agreementCheckbox.state = setting.enabled ? .on : .off
            } catch {
                self.showAdminError(error)
            }
        }
    }

    @objc func saveAgreement(_ sender: Any?) {
        let enabled = agreementCheckbox.state == .on
        let text = agreementEditor.string
        if client.isConnected {
            guard remotePermissionEnabled(LegacyAccountPermissionBit.editServerAgreement) else {
                showAdminError(ServerStateError.invalidValue(L("This account cannot edit the server Agreement.")))
                return
            }
            do {
                guard let textData = text.data(using: .macOSRoman) else {
                    throw ServerStateError.invalidValue(L("Agreement contains characters that cannot be represented in MacRoman."))
                }
                let setting = LegacyAgreementSetting(
                    enabled: enabled,
                    content: LegacyAgreementContent(text: textData, styleData: Data())
                )
                let value = try setting.encoded()
                client.setServerSettings([LegacyTLV(type: LegacyServerSettingField.agreement, value: value)]) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.showAdminSaved(L("Agreement saved on the connected server."))
                        self.reloadAgreementAdministration()
                    case let .failure(error):
                        self.showAdminError(error)
                        self.reloadAgreementAdministration()
                    }
                }
            } catch { showAdminError(error) }
            return
        }

        guard let backend = serverBackend else { showAdminError(ServerStateError.invalidValue(L("Server backend is unavailable."))); return }
        do {
            try backend.updateAgreement(ServerAgreement(enabled: enabled, text: text))
            reloadLocalStateFromBackend()
            showAdminSaved(L("Agreement saved."))
        } catch { showAdminError(error) }
    }

}
