import Cocoa
import QuickLookUI

// MARK: - InputDelegates

extension ViewController {

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === transferSearchField {
            transferMonitorSearchQuery = transferSearchField.stringValue
            refreshTransferMonitorUI()
            return
        }
        if [adminServerNameField, adminOperatorField, adminLocationField, adminBannerURLField].contains(where: { $0 === field }) {
            markServerInfoDraftChanged()
            return
        }
        if field === adminTrackerDescriptionField {
            markTrackerDraftChanged()
            return
        }
        let tracked = [adminMaxConnectionsField, adminMaxConnectionsPerIPField,
                       adminMaxTransfersField, adminMaxTransfersPerUserField,
                       adminMaxFolderDepthField, adminLegacyFilesRootField,
                       transferBandwidthField]
        guard tracked.contains(where: { $0 === field }) else { return }
        markAdvancedDirty(bandwidth: field === transferBandwidthField)
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        if textView === adminDescriptionView {
            markServerInfoDraftChanged()
            return
        }
        if textView === privateMessageComposer {
            if let userID = selectedPrivateConversationID, var conversation = privateMessageConversations[userID] {
                conversation.draftText = privateMessageComposer.string
                privateMessageConversations[userID] = conversation
            }
            if privateMessageComposerStatusLabel.textColor == .systemRed {
                privateMessageComposerStatusLabel.textColor = CarrachoTheme.secondaryText
                refreshPrivateMessageCenter(scrollToBottom: false)
            }
            return
        }
        if textView === channelMessageField {
            if channelComposerStatusLabel.stringValue.hasPrefix(L("Enter a message"))
                || channelComposerStatusLabel.stringValue.hasPrefix(L("The message may"))
                || channelComposerStatusLabel.stringValue.hasPrefix(L("Message could not be sent")) {
                channelComposerStatusLabel.stringValue = ""
            }
            persistActiveChannelComposerDraft()
            updateChannelComposerHeight()
            updateChannelComposerPresentation()
            return
        }
        guard textView === adminSearchIndexExclusionsView || textView === adminIPRulesView else { return }
        markAdvancedDirty()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === channelMessageField || textView === privateMessageComposer else { return false }
        let command = NSStringFromSelector(commandSelector)
        if command == "insertNewline:" || command == "insertNewlineIgnoringFieldEditor:" {
            let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if modifiers.contains(.shift) { return false }
            if textView === privateMessageComposer { sendPrivateMessageFromCenter(nil) }
            else { sendChannelChat(nil) }
            return true
        }
        return false
    }

}
