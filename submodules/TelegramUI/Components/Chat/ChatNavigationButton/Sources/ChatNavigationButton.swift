import Foundation
import UIKit

public enum ChatNavigationButtonAction: Equatable {
    public enum ChatInfoSection {
        case groupsInCommon
        case recommendedChannels
    }
    case openChatInfo(expandAvatar: Bool, section: ChatInfoSection?)
    case clearHistory
    case clearCache
    case cancelMessageSelection
    case search(hasTags: Bool)
    case dismiss
    case toggleInfoPanel
    case spacer
    case edit
    // LuminaGram: persistent header translate toggle. isActive mirrors the chat's
    // current translation-enabled state so the button diffs (and re-tints) when it flips.
    case luminaToggleTranslation(isActive: Bool)
}

public struct ChatNavigationButton: Equatable {
    public let action: ChatNavigationButtonAction
    public let buttonItem: UIBarButtonItem

    public init(action: ChatNavigationButtonAction, buttonItem: UIBarButtonItem) {
        self.action = action
        self.buttonItem = buttonItem
    }
    
    public static func ==(lhs: ChatNavigationButton, rhs: ChatNavigationButton) -> Bool {
        return lhs.action == rhs.action && lhs.buttonItem === rhs.buttonItem
    }
}
