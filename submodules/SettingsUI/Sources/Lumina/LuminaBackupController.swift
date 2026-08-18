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
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "BACKUP PASSPHRASE", sectionId: self.section)
        case let .passphrase(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: ""), text: value, placeholder: "Passphrase", type: .password, sectionId: self.section, textUpdated: { text in
                arguments.updatePassphrase(text)
            }, action: {})
        case .passphraseFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Used to encrypt (export) or decrypt (import) the backup file. Not stored anywhere - re-enter it each time. If you lose it, the backup cannot be recovered."), sectionId: self.section)
        case .export:
            return ItemListActionItem(presentationData: presentationData, title: "Export Backup", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.exportBackup()
            })
        case .importAction:
            return ItemListActionItem(presentationData: presentationData, title: "Import Backup", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.importBackup()
            })
        case .actionsFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Backs up quick-reply templates, bookmarks, contact notes and every other LuminaGram setting on this device. Importing replaces all current LuminaGram settings on this device."), sectionId: self.section)
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

    let arguments = LuminaBackupControllerArguments(updatePassphrase: { text in
        updateState { state in
            var state = state
            state.passphrase = text
            return state
        }
    }, exportBackup: {
        let passphrase = stateValue.with { $0.passphrase }
        guard !passphrase.isEmpty else {
            presentError("Enter a passphrase first.")
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
                presentError("Could not create the backup file.")
            }
        })
    }, importBackup: {
        let passphrase = stateValue.with { $0.passphrase }
        guard !passphrase.isEmpty else {
            presentError("Enter the backup's passphrase first.")
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
                let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { _ in
                    return settings
                }).start()
                presentError("Backup restored.")
            } catch {
                presentError("Could not restore the backup. Check the passphrase and try again.")
            }
        })
        pickerHandler = handler
        _ = pickerHandler // retain-only: read-back to satisfy -warnings-as-errors
        let pickerController: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            pickerController = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        } else {
            pickerController = UIDocumentPickerViewController(documentTypes: ["public.data"], in: .open)
        }
        pickerController.delegate = handler
        context.sharedContext.applicationBindings.presentNativeController(pickerController)
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Backup"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaBackupControllerEntries(state: state), style: .blocks, animateChanges: false)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
