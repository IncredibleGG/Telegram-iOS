import Foundation
import UIKit
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import TelegramPresentationData
import PresentationDataUtils
import Display
import AccountContext
import ComponentFlow
import AlertComponent
import AlertInputFieldComponent

// LuminaGram: link safety check — the AccountContext/UI-aware half of `LuminaLinkSafety`
// (submodules/TelegramUIPreferences/Sources/LuminaLinkSafety.swift). Called from the link-open
// hook in `ChatController.swift`'s `openUrl(...)` (`self.luminaCheckLinkSafetyBeforeOpening`,
// added at the very top of that function, before `commitPurposefulAction()`).
//
// UNSURE-compiles: `luminaKnownTelegramHosts` is a hand-picked approximation of the "is this an
// internal Telegram destination" check Android's `Browser.isInternalUri` does with the app's
// full authDomains/autologinDomains/instant-view host lists (`MessagesController`-backed, not
// reproduced here). A real "internal" host that isn't on this short list will incorrectly get a
// safety sheet instead of being silently skipped — annoying, not unsafe, and easy to extend.
private let luminaKnownTelegramHosts: Set<String> = ["t.me", "telegram.me", "telegram.org", "telegram.dog", "telesco.pe"]

private func luminaIsKnownTelegramHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else {
        return false
    }
    let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    return luminaKnownTelegramHosts.contains(bare)
}

extension ChatControllerImpl {
    /// Last URL the user approved via the safety sheet, so an async re-open of the exact same
    /// string (e.g. `openResolved` calling back into `openUrl`) is not prompted twice. Extensions
    /// cannot add stored INSTANCE properties, but a stored STATIC property is fine — mirrors
    /// Android's own `static volatile String luminaLinkSafetyApprovedUrl`.
    private static var luminaApprovedLinkSafetyUrl: String?

    /// `proceed(urlToOpen, confirmedBySheet)`: the address to open (the tapped one, or what the user
    /// accepted in the short-link sheet) and whether a LuminaGram sheet showing it was accepted. With
    /// the setting off, or for a link no sheet is shown for, it is `(url, false)`.
    func luminaCheckLinkSafetyBeforeOpening(_ url: String, proceed: @escaping (_ urlToOpen: String, _ confirmedBySheet: Bool) -> Void) {
        // A link to a known URL shortener gets the short-link sheet, which looks up where it leads.
        if let shortLink = LuminaShortLink.shortLinkUrl(fromLinkString: url) {
            self.luminaCheckShortLinkBeforeOpening(url, shortLink: shortLink, proceed: proceed)
            return
        }

        guard let parsed = URL(string: url) else {
            proceed(url, false)
            return
        }
        let isInternal = luminaIsKnownTelegramHost(parsed.host)
        guard LuminaLinkSafety.shouldConfirm(url: parsed, isInternalUri: isInternal, alreadyApproved: ChatControllerImpl.luminaApprovedLinkSafetyUrl) else {
            proceed(url, false)
            return
        }

        let _ = (self.context.sharedContext.accountManager.sharedData(keys: Set([ApplicationSpecificSharedDataKeys.luminaSettings]))
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] sharedData in
            guard let self else {
                proceed(url, false)
                return
            }
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? LuminaSettings.defaultSettings
            guard settings.linkSafetyCheck else {
                proceed(url, false)
                return
            }

            let warnings = LuminaLinkSafety.warnings(for: parsed)
            var text = url
            for warning in warnings {
                text += "\n\n⚠ \(warning.text)"
            }

            self.present(textAlertController(
                context: self.context,
                updatedPresentationData: self.updatedPresentationData,
                title: LuminaL10n.tr("Check This Link"),
                text: text,
                actions: [
                    TextAlertAction(type: .defaultAction, title: LuminaL10n.tr("Open"), action: {
                        ChatControllerImpl.luminaApprovedLinkSafetyUrl = url
                        proceed(url, true)
                    }),
                    TextAlertAction(type: .genericAction, title: LuminaL10n.tr("Cancel"), action: {}),
                ]
            ), in: .window(.root))
        })
    }

    /// The short-link path of `luminaCheckLinkSafetyBeforeOpening`: `url` as tapped, `shortLink` the
    /// http(s) address it names on a known shortener (see `LuminaShortLink.shortLinkUrl`).
    private func luminaCheckShortLinkBeforeOpening(_ url: String, shortLink: URL, proceed: @escaping (_ urlToOpen: String, _ confirmedBySheet: Bool) -> Void) {
        if let approved = ChatControllerImpl.luminaApprovedLinkSafetyUrl, approved == url || approved == shortLink.absoluteString {
            proceed(url, false)
            return
        }

        let _ = (self.context.sharedContext.accountManager.sharedData(keys: Set([ApplicationSpecificSharedDataKeys.luminaSettings]))
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] sharedData in
            guard let self else {
                proceed(url, false)
                return
            }
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? LuminaSettings.defaultSettings
            guard settings.linkSafetyCheck else {
                proceed(url, false)
                return
            }
            self.luminaPresentShortLinkSheet(url: url, shortLink: shortLink, proceed: proceed)
        })
    }

    /// The short-link sheet: looks up the real address in the background (LuminaShortLink.swift), shows it
    /// with its registrable domain emphasised, and lets the user edit the address before opening it.
    /// "Open" opens exactly the field's text; Cancel, or a tap outside, opens nothing.
    private func luminaPresentShortLinkSheet(url: String, shortLink: URL, proceed: @escaping (_ urlToOpen: String, _ confirmedBySheet: Bool) -> Void) {
        let model = LuminaShortLinkSheetModel(context: self.context, originalUrl: url)
        let updatedPresentationData = self.updatedPresentationData

        var openImpl: (() -> Void)?
        let presentationDataSignal: Signal<PresentationData, NoError> = .single(updatedPresentationData.0) |> then(updatedPresentationData.1)
        let contentSignal = combineLatest(
            queue: Queue.mainQueue(),
            model.updated,
            presentationDataSignal
        )
        |> map { _, presentationData -> [AnyComponentWithIdentity<AlertComponentEnvironment>] in
            return model.content(presentationData: presentationData, returnAction: {
                openImpl?()
            })
        }

        let controller = AlertScreen(
            configuration: AlertScreen.Configuration(allowInputInset: true),
            contentSignal: contentSignal,
            actionsSignal: .single([
                AlertScreen.Action(id: "cancel", title: LuminaL10n.tr("Cancel"), action: {
                    model.dispose()
                }),
                AlertScreen.Action(id: "open", title: LuminaL10n.tr("Open"), type: .default, action: {
                    openImpl?()
                }, autoDismiss: false),
            ]),
            updatedPresentationData: (initial: updatedPresentationData.0, signal: updatedPresentationData.1)
        )
        controller.dismissed = { _ in
            model.dispose()
        }
        openImpl = { [weak controller] in
            // At most once, and never after Cancel: the sheet still takes taps while it animates out, so a
            // second tap on Open (or Go, then Open) must not open the address a second time.
            if model.isDisposed {
                return
            }
            guard let target = model.addressToOpen() else {
                model.showInvalidAddress()
                return
            }
            model.dispose()
            controller?.dismiss()
            ChatControllerImpl.luminaApprovedLinkSafetyUrl = target
            proceed(target, true)
        }
        self.present(controller, in: .window(.root))
        model.start(shortLink: shortLink)
    }
}

/// The short-link sheet's state, used on the main queue only.
private final class LuminaShortLinkSheetModel {
    private enum Phase {
        case resolving
        case resolved(URL, redirects: Int)
        case failed(LuminaShortLinkResolver.Failure)
    }

    private let context: AccountContext
    /// The link as tapped. Opening it unchanged behaves as before this sheet existed.
    private let originalUrl: String
    private var phase: Phase = .resolving
    private var resolver: LuminaShortLinkResolver?
    /// Set once the sheet is opened or cancelled (or goes away); nothing is opened after that.
    private(set) var isDisposed = false

    // The address field. Filling in the resolved address puts a new field (new id and state) in place of
    // the old one, since a field takes its initial value only once.
    private var inputState = AlertInputFieldComponent.ExternalState()
    private var inputGeneration = 0
    private var inputInitialValue: String
    /// The field's text as last reported, and whether it has reported its initial value yet (its state
    /// reads "" until the field is first laid out).
    private var reportedValue: String
    private var hasReportedInitialValue = false
    private let inputValueDisposable = MetaDisposable()
    private var showsInvalidAddress = false

    private var revisionValue = 0
    private let revision = ValuePromise<Int>(0, ignoreRepeated: true)

    init(context: AccountContext, originalUrl: String) {
        self.context = context
        self.originalUrl = originalUrl
        self.inputInitialValue = originalUrl
        self.reportedValue = originalUrl
        self.observeInput()
    }

    var updated: Signal<Int, NoError> {
        return self.revision.get()
    }

    func start(shortLink: URL) {
        if self.isDisposed {
            return
        }
        self.resolver = LuminaShortLinkResolver.start(url: shortLink, completion: { [weak self] outcome in
            self?.resolutionFinished(outcome)
        })
    }

    func dispose() {
        if self.isDisposed {
            return
        }
        self.isDisposed = true
        self.resolver?.cancel()
        self.resolver = nil
        self.inputValueDisposable.dispose()
    }

    /// What "Open" opens: the link as tapped when the field still holds it, otherwise the field's text
    /// when it is an http(s) address. Nil when the text cannot be opened.
    func addressToOpen() -> String? {
        let text = self.fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == self.originalUrl.trimmingCharacters(in: .whitespacesAndNewlines) {
            return self.originalUrl
        }
        if LuminaShortLink.openableEditedUrl(text) != nil {
            return text
        }
        return nil
    }

    func showInvalidAddress() {
        self.showsInvalidAddress = true
        self.bump()
        self.inputState.animateError()
    }

    private var fieldText: String {
        if self.hasReportedInitialValue || self.inputState.value == self.inputInitialValue {
            return self.inputState.value
        }
        return self.inputInitialValue
    }

    private func bump() {
        self.revisionValue += 1
        self.revision.set(self.revisionValue)
    }

    private func observeInput() {
        let state = self.inputState
        self.inputValueDisposable.set(state.valueSignal.start(next: { [weak self] value in
            // The field reports its text from inside the alert's layout pass; a content update emitted
            // there would wait for the next pass, so it is handled right after.
            Queue.mainQueue().justDispatch {
                guard let self, self.inputState === state else {
                    return
                }
                self.inputValueChanged(value)
            }
        }))
    }

    private func inputValueChanged(_ value: String) {
        if self.isDisposed {
            return
        }
        if !self.hasReportedInitialValue {
            if value == self.inputInitialValue {
                self.hasReportedInitialValue = true
                self.reportedValue = value
            }
            return
        }
        if value == self.reportedValue {
            return
        }
        self.reportedValue = value
        self.bump()
    }

    private func resolutionFinished(_ outcome: LuminaShortLinkResolver.Outcome) {
        if self.isDisposed {
            return
        }
        self.resolver = nil
        switch outcome {
        case let .resolved(url, redirects):
            self.phase = .resolved(url, redirects: redirects)
            // The resolved address goes into the field, unless the user has already typed their own.
            if self.fieldText == self.inputInitialValue {
                self.inputGeneration += 1
                self.inputState = AlertInputFieldComponent.ExternalState()
                self.inputInitialValue = url.absoluteString
                self.reportedValue = url.absoluteString
                self.hasReportedInitialValue = false
                self.observeInput()
            }
        case let .failed(failure):
            self.phase = .failed(failure)
        }
        self.bump()
    }

    func content(presentationData: PresentationData, returnAction: @escaping () -> Void) -> [AnyComponentWithIdentity<AlertComponentEnvironment>] {
        var content: [AnyComponentWithIdentity<AlertComponentEnvironment>] = []
        content.append(AnyComponentWithIdentity(id: "title", component: AnyComponent(AlertTitleComponent(title: LuminaL10n.tr("Check This Link")))))

        // Where the link leads. The shortener's own address is never presented as the destination.
        switch self.phase {
        case .resolving:
            content.append(AnyComponentWithIdentity(id: "status", component: AnyComponent(AlertTextComponent(
                content: .plain(LuminaL10n.tr("Fetching the real address…")),
                style: .plain(.small)
            ))))
        case let .resolved(url, redirects):
            let heading: String
            if redirects == 1 {
                heading = LuminaL10n.tr("Real address (after 1 redirect):")
            } else {
                heading = LuminaL10n.tr("Real address (after %@ redirects):").replacingOccurrences(of: "%@", with: "\(redirects)")
            }
            content.append(AnyComponentWithIdentity(id: "status", component: AnyComponent(AlertTextComponent(
                content: .plain(heading),
                style: .plain(.small)
            ))))
            let display = LuminaShortLink.displayText(for: url)
            let textColor = presentationData.theme.actionSheet.primaryTextColor
            let attributed = NSMutableAttributedString(string: display.text, attributes: [
                .font: Font.regular(14.0),
                .foregroundColor: textColor,
            ])
            if let domainRange = display.domainRange {
                attributed.addAttribute(.font, value: Font.semibold(14.0), range: domainRange)
            }
            content.append(AnyComponentWithIdentity(id: "resolved", component: AnyComponent(AlertTextComponent(
                content: .attributed(attributed),
                style: .background(.small),
                insets: UIEdgeInsets(top: 4.0, left: 4.0, bottom: 0.0, right: 4.0)
            ))))
        case let .failed(failure):
            content.append(AnyComponentWithIdentity(id: "status", component: AnyComponent(AlertTextComponent(
                content: .plain(LuminaL10n.tr("The real address can't be known before opening.")),
                style: .plain(.bold)
            ))))
            content.append(AnyComponentWithIdentity(id: "reason", component: AnyComponent(AlertTextComponent(
                content: .plain(failure.text),
                style: .plain(.small)
            ))))
        }

        content.append(AnyComponentWithIdentity(id: "hint", component: AnyComponent(AlertTextComponent(
            content: .plain(LuminaL10n.tr("You can edit the address before opening it.")),
            color: .secondary,
            style: .plain(.small)
        ))))
        content.append(AnyComponentWithIdentity(id: "input-\(self.inputGeneration)", component: AnyComponent(AlertInputFieldComponent(
            context: self.context,
            initialValue: self.inputInitialValue,
            placeholder: LuminaL10n.tr("Link address"),
            hasClearButton: true,
            returnKeyType: .go,
            keyboardType: .URL,
            autocapitalizationType: .none,
            autocorrectionType: .no,
            isInitiallyFocused: false,
            externalState: self.inputState,
            returnKeyAction: returnAction
        ))))

        // The same checks as for any other link, on whatever the field holds now. The link as tapped is
        // not called a hidden short link again: the lines above already say what is known about it.
        let text = self.fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        var warningLines: [String] = []
        if let fieldUrl = URL(string: text) {
            for warning in LuminaLinkSafety.warnings(for: fieldUrl) {
                if case .shortener = warning, text == self.originalUrl.trimmingCharacters(in: .whitespacesAndNewlines) {
                    continue
                }
                warningLines.append("⚠ \(warning.text)")
            }
        }
        if !warningLines.isEmpty {
            content.append(AnyComponentWithIdentity(id: "warnings", component: AnyComponent(AlertTextComponent(
                content: .plain(warningLines.joined(separator: "\n")),
                color: .destructive,
                style: .plain(.small)
            ))))
        }
        if self.showsInvalidAddress && self.addressToOpen() == nil {
            content.append(AnyComponentWithIdentity(id: "invalid", component: AnyComponent(AlertTextComponent(
                content: .plain(LuminaL10n.tr("Only http:// and https:// links can be opened here.")),
                color: .destructive,
                style: .plain(.small)
            ))))
        }
        return content
    }
}
