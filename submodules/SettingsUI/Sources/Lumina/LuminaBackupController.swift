import Foundation
import UIKit
import UniformTypeIdentifiers
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext
import AlertUI
import TranslateUI

// LuminaGram: encrypted local backup (.lgbak) - export/import UI over LuminaBackup.swift
// (submodules/TelegramUIPreferences/Sources/LuminaBackup.swift), which does the actual
// AES-GCM encode/decode of the LuminaSettings struct. Export goes through the standard
// share sheet (UIActivityViewController) so the user picks where the file lands - Files,
// AirDrop, a messaging app, etc. - the same "user-initiated document action" pattern
// AppDelegate.swift already uses elsewhere in this codebase. Import goes through
// UIDocumentPickerViewController.

private final class LuminaBackupDocumentPickerHandler: NSObject, UIDocumentPickerDelegate {
    let completion: (URL?) -> Void

    init(completion: @escaping (URL?) -> Void) {
        self.completion = completion
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        self.completion(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.completion(nil)
    }
}

private struct LuminaBackupState: Equatable {
    var passphrase: String
}

private final class LuminaBackupControllerArguments {
    let updatePassphrase: (String) -> Void
    let exportBackup: () -> Void
    let importBackup: () -> Void

    init(updatePassphrase: @escaping (String) -> Void, exportBackup: @escaping () -> Void, importBackup: @escaping () -> Void) {
        self.updatePassphrase = updatePassphrase
        self.exportBackup = exportBackup
        self.importBackup = importBackup
    }
}

private enum LuminaBackupEntry: ItemListNodeEntry {
    case passphraseHeader
    case passphrase(String)
    case passphraseFooter
    case export
    case importAction
    case actionsFooter

    var section: ItemListSectionId {
        switch self {
        case .passphraseHeader, .passphrase, .passphraseFooter:
            return 0
        case .export, .importAction, .actionsFooter:
            return 1
        }
    }

    var stableId: Int32 {
        switch self {
        case .passphraseHeader:
            return 0
        case .passphrase:
            return 1
        case .passphraseFooter:
            return 2
        case .export:
            return 3
        case .importAction:
            return 4
        case .actionsFooter:
            return 5
        }
    }

    static func <(lhs: LuminaBackupEntry, rhs: LuminaBackupEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaBackupControllerArguments
        switch self {
        case .passphraseHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("BACKUP PASSPHRASE"), sectionId: self.section)
        case let .passphrase(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: ""), text: value, placeholder: LuminaL10n.tr("Passphrase"), type: .password, sectionId: self.section, textUpdated: { text in
                arguments.updatePassphrase(text)
            }, action: {})
        case .passphraseFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Used to encrypt (export) or decrypt (import) the backup file. Not stored anywhere - re-enter it each time. If you lose it, the backup cannot be recovered.")), sectionId: self.section)
        case .export:
            return ItemListActionItem(presentationData: presentationData, title: LuminaL10n.tr("Export Backup"), kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.exportBackup()
            })
        case .importAction:
            return ItemListActionItem(presentationData: presentationData, title: LuminaL10n.tr("Import Backup"), kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.importBackup()
            })
        case .actionsFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Backs up quick-reply templates, bookmarks, contact notes and every other LuminaGram setting on this device. Importing replaces all current LuminaGram settings on this device.")), sectionId: self.section)
        }
    }
}

private func luminaBackupControllerEntries(state: LuminaBackupState) -> [LuminaBackupEntry] {
    return [
        .passphraseHeader,
        .passphrase(state.passphrase),
        .passphraseFooter,
        .export,
        .importAction,
        .actionsFooter
    ]
}

// LuminaGram: an imported backup must never silently re-point translation / AI traffic. The
// LLM base URL is shared by the LLM translation engine and Explain, and the user's saved LLM key
// (Keychain, never in the backup) is sent to whatever host it names - so a backup that changes
// that endpoint, or switches translation to the custom-endpoint (LLM) provider, is confirmed
// first, listing the destination host. Declining still imports everything else and keeps the
// current provider selection, endpoint, model and prompt. API keys are not part of an iOS backup
// (LuminaKeychain), so an import can never set or replace a key. Export is unchanged.
private func luminaBackupEffectiveLLMEndpoint(_ baseUrl: String) -> String {
    let trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    return LuminaLLMDefaults.trimTrailingSlash(trimmed.isEmpty ? LuminaLLMDefaults.baseUrl : trimmed)
}

private func luminaBackupDisplayHost(_ endpoint: String) -> String {
    if let host = URL(string: endpoint)?.host, !host.isEmpty {
        return host
    }
    // Not an absolute URL: show the raw value (shortened) so the user still sees where it points.
    return endpoint.count > 80 ? String(endpoint.prefix(80)) + "…" : endpoint
}

// The destination host(s) the imported settings would newly send translation / Explain requests
// to, or nil when the import leaves the provider endpoint and custom-endpoint selection as is.
private func luminaBackupProviderEndpointHosts(current: LuminaSettings, imported: LuminaSettings) -> [String]? {
    let currentEndpoint = luminaBackupEffectiveLLMEndpoint(current.translateBaseUrl)
    let importedEndpoint = luminaBackupEffectiveLLMEndpoint(imported.translateBaseUrl)
    let endpointChanged = currentEndpoint != importedEndpoint
    let selectsCustomEndpoint = imported.translateEngine == "llm" && current.translateEngine != "llm"
    guard endpointChanged || selectsCustomEndpoint else {
        return nil
    }
    return [luminaBackupDisplayHost(importedEndpoint)]
}

private func luminaBackupKeepingCurrentProvider(_ imported: LuminaSettings, current: LuminaSettings) -> LuminaSettings {
    var result = imported
    result.translateEngine = current.translateEngine
    result.translateBaseUrl = current.translateBaseUrl
    result.translateModel = current.translateModel
    result.translatePrompt = current.translatePrompt
    return result
}

public func luminaBackupController(context: AccountContext) -> ViewController {
    let initialState = LuminaBackupState(passphrase: "")
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)

    let updateState: ((LuminaBackupState) -> LuminaBackupState) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }

    var presentControllerImpl: ((ViewController) -> Void)?
    var pickerHandler: LuminaBackupDocumentPickerHandler?

    func presentError(_ text: String) {
        presentControllerImpl?(textAlertController(context: context, title: nil, text: text, actions: [
            TextAlertAction(type: .defaultAction, title: context.sharedContext.currentPresentationData.with { $0 }.strings.Common_OK, action: {})
        ]))
    }

    func applyImportedSettings(_ imported: LuminaSettings, keepCurrentProvider: Bool) {
        let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { current in
            return keepCurrentProvider ? luminaBackupKeepingCurrentProvider(imported, current: current) : imported
        }).start()
        presentError(keepCurrentProvider ? LuminaL10n.tr("Backup restored. Your current translation provider was kept.") : LuminaL10n.tr("Backup restored."))
    }

    let arguments = LuminaBackupControllerArguments(updatePassphrase: { text in
        updateState { state in
            var state = state
            state.passphrase = text
            return state
        }
    }, exportBackup: {
        let passphrase = stateValue.with { $0.passphrase }
        guard !passphrase.isEmpty else {
            presentError(LuminaL10n.tr("Enter a passphrase first."))
            return
        }
        let _ = (context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
        |> take(1)
        |> deliverOnMainQueue).start(next: { sharedData in
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? .defaultSettings
            do {
                let data = try LuminaBackup.export(settings, passphrase: passphrase)
                let fileUrl = FileManager.default.temporaryDirectory.appendingPathComponent("LuminaGram-\(Int32(Date().timeIntervalSince1970)).lgbak")
                try data.write(to: fileUrl, options: .atomic)
                let activityController = UIActivityViewController(activityItems: [fileUrl], applicationActivities: nil)
                context.sharedContext.applicationBindings.presentNativeController(activityController)
            } catch {
                presentError(LuminaL10n.tr("Could not create the backup file."))
            }
        })
    }, importBackup: {
        let passphrase = stateValue.with { $0.passphrase }
        guard !passphrase.isEmpty else {
            presentError(LuminaL10n.tr("Enter the backup's passphrase first."))
            return
        }
        let handler = LuminaBackupDocumentPickerHandler(completion: { url in
            guard let url else {
                return
            }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                let settings = try LuminaBackup.importData(LuminaSettings.self, data: data, passphrase: passphrase)
                let _ = (context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
                |> take(1)
                |> deliverOnMainQueue).start(next: { sharedData in
                    let current = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? .defaultSettings
                    guard let hosts = luminaBackupProviderEndpointHosts(current: current, imported: settings) else {
                        applyImportedSettings(settings, keepCurrentProvider: false)
                        return
                    }
                    let text = LuminaL10n.tr("This backup changes where translation and Explain requests are sent:")
                        + "\n\n" + hosts.joined(separator: "\n") + "\n\n"
                        + LuminaL10n.tr("Messages you translate or explain, and your saved LLM API key, would be sent to this server. Use it only if you trust it.")
                    presentControllerImpl?(textAlertController(context: context, title: LuminaL10n.tr("Translation Provider"), text: text, actions: [
                        TextAlertAction(type: .genericAction, title: LuminaL10n.tr("Use Backup's Provider"), action: {
                            applyImportedSettings(settings, keepCurrentProvider: false)
                        }),
                        TextAlertAction(type: .defaultAction, title: LuminaL10n.tr("Keep Current Provider"), action: {
                            applyImportedSettings(settings, keepCurrentProvider: true)
                        })
                    ], actionLayout: .vertical, dismissOnOutsideTap: false))
                })
            } catch {
                presentError(LuminaL10n.tr("Could not restore the backup. Check the passphrase and try again."))
            }
        })
        pickerHandler = handler
        _ = pickerHandler // retain-only: read-back to satisfy -warnings-as-errors
        // iOS 15 is the minimum deployment target (upstream 13.0): the content-type initializer
        // (iOS 14+) is always available, so the deprecated init(documentTypes:in:) fallback is gone.
        let pickerController = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        pickerController.delegate = handler
        context.sharedContext.applicationBindings.presentNativeController(pickerController)
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuminaL10n.tr("Backup")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaBackupControllerEntries(state: state), style: .blocks, animateChanges: false)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
