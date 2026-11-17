import Foundation
import SwiftSignalKit

// The few TelegramCore / Postbox declarations the TelegramUIPreferences files under test use (LuminaSettings.swift,
// LuminaSettingsCache-free subset, LuminaAdShieldService.swift), compiled as a stand-in module named TelegramCore.
// NOT part of any Bazel target: see run.sh in this directory.

public struct StringCodingKey: CodingKey, ExpressibleByStringLiteral {
    public var stringValue: String
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init(_ stringValue: String) { self.stringValue = stringValue }
    public init(stringLiteral: String) { self.stringValue = stringLiteral }
    public var intValue: Int? { return nil }
    public init?(intValue: Int) { return nil }
}

public final class ValueBoxKey: Hashable {
    public init() {}
    public static func ==(lhs: ValueBoxKey, rhs: ValueBoxKey) -> Bool { return lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

public final class PreferencesEntry: Equatable {
    public let data: Data
    public init(data: Data) { self.data = data }
    public init?<T: Encodable>(_ value: T?) {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        self.data = data
    }
    public func get<T: Decodable>(_ type: T.Type) -> T? { return try? JSONDecoder().decode(T.self, from: self.data) }
    public static func ==(lhs: PreferencesEntry, rhs: PreferencesEntry) -> Bool { return lhs.data == rhs.data }
}
public typealias SharedPreferencesEntry = PreferencesEntry

public protocol AccountManagerTypes: AnyObject {}
public final class TelegramAccountManagerTypes: AccountManagerTypes {}

public final class AccountSharedDataView<Types: AccountManagerTypes> {
    public let entries: [ValueBoxKey: PreferencesEntry]
    init(entries: [ValueBoxKey: PreferencesEntry]) { self.entries = entries }
}

public final class AccountManagerModifier<Types: AccountManagerTypes> {
    public func updateSharedData(_ key: ValueBoxKey, _ f: (PreferencesEntry?) -> PreferencesEntry?) {}
}

/// Never emits: the checker feeds settings through LuminaAdShieldService.settingsLoaded directly.
public final class AccountManager<Types: AccountManagerTypes> {
    public init() {}
    public func sharedData(keys: Set<ValueBoxKey>) -> Signal<AccountSharedDataView<Types>, NoError> { return .never() }
    public func transaction<T>(ignoreDisabled: Bool = false, _ f: @escaping (AccountManagerModifier<Types>) -> T) -> Signal<T, NoError> { return .never() }
}
