import Foundation
import TelegramCore

// Stand-in for TelegramUIPreferences/Sources/PostboxKeys.swift (only the key the files under test use).
public enum ApplicationSpecificSharedDataKeys {
    public static let luminaSettings = ValueBoxKey()
}
