import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext

// LuminaGram account security checkup — read-only status of 2FA / recovery email / privacy /
// active sessions, port of Android's `org.telegram.ui.LuminaSecurityCheckupActivity`, mirroring
// desktop's `lumina_security_checkup.cpp`. Reached from `luminaSecuritySettingsController`
// (LuminaSecuritySettingsController.swift, same module) via the "Security Checkup" row.
//
// This screen never changes anything itself: every row just deep-links to the OFFICIAL Telegram
// settings screen that owns that setting (`SharedAccountContext.makePrivacyAndSecurityController`,
// `.makeRecentSessionsController`), exactly like the roadmap specifies. Status is read through
// official engine APIs only:
//   two-step verification / recovery email -> context.engine.auth.twoStepVerificationConfiguration()
//   who can add me to groups / call me /
//   see my phone number                    -> context.engine.privacy.requestAccountPrivacySettings()
//   active sessions (devices)               -> context.engine.privacy.activeSessions()
// Anything not yet loaded shows "Checking…" rather than a guessed value, matching Android's
// "unknown until the request actually returns" rule.
private final class LuminaSecurityCheckupControllerArguments {
    let openPrivacyAndSecurity: () -> Void
    let openSessions: () -> Void

    init(openPrivacyAndSecurity: @escaping () -> Void, openSessions: @escaping () -> Void) {
        self.openPrivacyAndSecurity = openPrivacyAndSecurity
        self.openSessions = openSessions
    }
}

private enum LuminaSecurityCheckupSection: Int32 {
    case summary
    case twoStep
    case privacy
    case sessions
}

private enum LuminaSecurityCheckupEntry: ItemListNodeEntry {
    case summary(String)

    case twoStepHeader
    case twoStepValue(String)
    case recoveryEmailValue(String)
    case twoStepFooter

    case privacyHeader
    case privacyGroups(String)
    case privacyCalls(String)
    case privacyPhone(String)
    case privacyFooter

    case sessionsHeader
    case sessionsValue(String)
    case sessionsFooter

    var section: ItemListSectionId {
        switch self {
        case .summary:
            return LuminaSecurityCheckupSection.summary.rawValue
        case .twoStepHeader, .twoStepValue, .recoveryEmailValue, .twoStepFooter:
            return LuminaSecurityCheckupSection.twoStep.rawValue
        case .privacyHeader, .privacyGroups, .privacyCalls, .privacyPhone, .privacyFooter:
            return LuminaSecurityCheckupSection.privacy.rawValue
        case .sessionsHeader, .sessionsValue, .sessionsFooter:
            return LuminaSecurityCheckupSection.sessions.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .summary: return 0
        case .twoStepHeader: return 1
        case .twoStepValue: return 2
        case .recoveryEmailValue: return 3
        case .twoStepFooter: return 4
        case .privacyHeader: return 5
        case .privacyGroups: return 6
        case .privacyCalls: return 7
        case .privacyPhone: return 8
        case .privacyFooter: return 9
        case .sessionsHeader: return 10
        case .sessionsValue: return 11
        case .sessionsFooter: return 12
        }
    }

    static func <(lhs: LuminaSecurityCheckupEntry, rhs: LuminaSecurityCheckupEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaSecurityCheckupControllerArguments
        switch self {
        case let .summary(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .twoStepHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("TWO-STEP VERIFICATION"), sectionId: self.section)
        case let .twoStepValue(value):
            return ItemListDisclosureItem(presentationData: presentationData, title: LuminaL10n.tr("Two-Step Verification"), label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openPrivacyAndSecurity()
            })
        case let .recoveryEmailValue(value):
            return ItemListDisclosureItem(presentationData: presentationData, title: LuminaL10n.tr("Recovery E-Mail"), label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openPrivacyAndSecurity()
            })
        case .twoStepFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("A password (plus a recovery e-mail) is the single strongest protection against a stolen login code.")), sectionId: self.section)
        case .privacyHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("PRIVACY"), sectionId: self.section)
        case let .privacyGroups(value):
            return ItemListDisclosureItem(presentationData: presentationData, title: LuminaL10n.tr("Who Can Add Me to Groups"), label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openPrivacyAndSecurity()
            })
        case let .privacyCalls(value):
            return ItemListDisclosureItem(presentationData: presentationData, title: LuminaL10n.tr("Who Can Call Me"), label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openPrivacyAndSecurity()
            })
        case let .privacyPhone(value):
            return ItemListDisclosureItem(presentationData: presentationData, title: LuminaL10n.tr("Who Can See My Phone Number"), label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openPrivacyAndSecurity()
            })
        case .privacyFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Tap any row to open Telegram's own Privacy and Security settings.")), sectionId: self.section)
        case .sessionsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("ACTIVE SESSIONS"), sectionId: self.section)
        case let .sessionsValue(value):
            return ItemListDisclosureItem(presentationData: presentationData, title: LuminaL10n.tr("Devices Signed In"), label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openSessions()
            })
        case .sessionsFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Review every device signed in to your account and end any you don't recognize.")), sectionId: self.section)
        }
    }
}

private func formatSelectivePrivacy(_ settings: SelectivePrivacySettings?) -> String {
    guard let settings else {
        return LuminaL10n.tr("Checking…")
    }
    switch settings {
    case .enableEveryone:
        return LuminaL10n.tr("Everybody")
    case .enableContacts:
        return LuminaL10n.tr("My Contacts")
    case .disableEveryone:
        return LuminaL10n.tr("Nobody")
    }
}

private func luminaSecurityCheckupControllerEntries(
    twoStepConfiguration: TwoStepVerificationConfiguration?,
    privacySettings: AccountPrivacySettings?,
    sessionCount: Int?
) -> [LuminaSecurityCheckupEntry] {
    var entries: [LuminaSecurityCheckupEntry] = []

    entries.append(.summary(summaryText(twoStepConfiguration)))

    entries.append(.twoStepHeader)
    entries.append(.twoStepValue(twoStepValueText(twoStepConfiguration)))
    entries.append(.recoveryEmailValue(recoveryEmailValueText(twoStepConfiguration)))
    entries.append(.twoStepFooter)

    entries.append(.privacyHeader)
    entries.append(.privacyGroups(formatSelectivePrivacy(privacySettings?.groupInvitations)))
    entries.append(.privacyCalls(formatSelectivePrivacy(privacySettings?.voiceCalls)))
    entries.append(.privacyPhone(formatSelectivePrivacy(privacySettings?.phoneNumber)))
    entries.append(.privacyFooter)

    entries.append(.sessionsHeader)
    entries.append(.sessionsValue(sessionCount.map { String($0) } ?? LuminaL10n.tr("Checking…")))
    entries.append(.sessionsFooter)

    return entries
}

private func summaryText(_ configuration: TwoStepVerificationConfiguration?) -> String {
    guard let configuration else {
        return LuminaL10n.tr("Checking your account security…")
    }
    var issues = 0
    switch configuration {
    case .notSet:
        issues += 1
    case let .set(_, hasRecoveryEmail, _, _, _):
        if !hasRecoveryEmail {
            issues += 1
        }
    }
    if issues == 0 {
        return LuminaL10n.tr("Your account security looks good.")
    }
    return issues == 1 ? LuminaL10n.tr("1 recommendation to review below.") : "\(issues) " + LuminaL10n.tr("recommendations to review below.")
}

private func twoStepValueText(_ configuration: TwoStepVerificationConfiguration?) -> String {
    guard let configuration else {
        return LuminaL10n.tr("Checking…")
    }
    switch configuration {
    case .notSet:
        return LuminaL10n.tr("Off")
    case .set:
        return LuminaL10n.tr("On")
    }
}

private func recoveryEmailValueText(_ configuration: TwoStepVerificationConfiguration?) -> String {
    guard let configuration else {
        return LuminaL10n.tr("Checking…")
    }
    switch configuration {
    case .notSet:
        return "—"
    case let .set(_, hasRecoveryEmail, _, _, _):
        return hasRecoveryEmail ? LuminaL10n.tr("Set") : LuminaL10n.tr("Not Set")
    }
}

public func luminaSecurityCheckupController(context: AccountContext) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?

    let twoStepConfiguration = Promise<TwoStepVerificationConfiguration?>(nil)
    twoStepConfiguration.set(context.engine.auth.twoStepVerificationConfiguration() |> map(Optional.init))

    let privacySettings = Promise<AccountPrivacySettings?>(nil)
    privacySettings.set(context.engine.privacy.requestAccountPrivacySettings() |> map(Optional.init))

    // Held for the lifetime of the controller via the signal chain below — it performs its own
    // `account.getAuthorizations` fetch on init and is also handed to `makeRecentSessionsController`
    // so the count shown here and the list that screen shows can never disagree.
    let activeSessionsContext = context.engine.privacy.activeSessions()

    let arguments = LuminaSecurityCheckupControllerArguments(
        openPrivacyAndSecurity: {
            pushControllerImpl?(context.sharedContext.makePrivacyAndSecurityController(context: context))
        },
        openSessions: {
            pushControllerImpl?(context.sharedContext.makeRecentSessionsController(context: context, activeSessionsContext: activeSessionsContext))
        }
    )

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        twoStepConfiguration.get(),
        privacySettings.get(),
        activeSessionsContext.state
    )
    |> deliverOnMainQueue
    |> map { presentationData, twoStepConfiguration, privacySettings, sessionsState -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let sessionCount: Int? = sessionsState.isLoadingMore && sessionsState.sessions.isEmpty ? nil : sessionsState.sessions.count

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuminaL10n.tr("Security Checkup")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaSecurityCheckupControllerEntries(
            twoStepConfiguration: twoStepConfiguration,
            privacySettings: privacySettings,
            sessionCount: sessionCount
        ), style: .blocks, animateChanges: true)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    return controller
}
