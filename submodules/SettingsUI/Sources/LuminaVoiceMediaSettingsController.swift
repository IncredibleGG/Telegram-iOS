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

// LuminaGram: the "Voice & Media" settings sub-controller - live toggles for every field
// LuminaSettings.swift already seeded under its "Voice & Media" section (sttAutoPipeline,
// autoTranslateTranscript, reverseVoice, ocrTranslate, keepOriginalFilename,
// autoPauseBackgroundVideo, saveMediaToLuminaAlbum). Structured exactly like
// ArchiveSettingsController.swift: presentationData + a live settings signal combined into
// entries, switches write straight through updateLuminaSettingsInteractively.
//
// NOT wired into LuminaGramSettingsController.swift's "Voice & Media" placeholder row - that file
// is out of this bucket's ownership per the task's file-ownership split. See the port report for
// the exact one-line change needed there (replace the luminaGramPlaceholderController push with
// luminaVoiceMediaSettingsController(context:)).
private final class LuminaVoiceMediaSettingsControllerArguments {
    let context: AccountContext
    let pushController: (ViewController) -> Void
    let updateSttAutoPipeline: (Bool) -> Void
    let updateAutoTranslateTranscript: (Bool) -> Void
    let updateReverseVoice: (Bool) -> Void
    let updateOcrTranslate: (Bool) -> Void
    let updateKeepOriginalFilename: (Bool) -> Void
    let updateAutoPauseBackgroundVideo: (Bool) -> Void
    let updateSaveMediaToLuminaAlbum: (Bool) -> Void
    let updateSwipeVideoPip: (Bool) -> Void
    let updateSendLargePhotos: (Bool) -> Void
    let updateTransferBoost: (Bool) -> Void
    let pickPhotoQuality: (Int32) -> Void
    let openReverseVoiceComposer: () -> Void

    init(
        context: AccountContext,
        pushController: @escaping (ViewController) -> Void,
        updateSttAutoPipeline: @escaping (Bool) -> Void,
        updateAutoTranslateTranscript: @escaping (Bool) -> Void,
        updateReverseVoice: @escaping (Bool) -> Void,
        updateOcrTranslate: @escaping (Bool) -> Void,
        updateKeepOriginalFilename: @escaping (Bool) -> Void,
        updateAutoPauseBackgroundVideo: @escaping (Bool) -> Void,
        updateSaveMediaToLuminaAlbum: @escaping (Bool) -> Void,
        updateSwipeVideoPip: @escaping (Bool) -> Void,
        updateSendLargePhotos: @escaping (Bool) -> Void,
        updateTransferBoost: @escaping (Bool) -> Void,
        pickPhotoQuality: @escaping (Int32) -> Void,
        openReverseVoiceComposer: @escaping () -> Void
    ) {
        self.context = context
        self.pushController = pushController
        self.updateSttAutoPipeline = updateSttAutoPipeline
        self.updateAutoTranslateTranscript = updateAutoTranslateTranscript
        self.updateReverseVoice = updateReverseVoice
        self.updateOcrTranslate = updateOcrTranslate
        self.updateKeepOriginalFilename = updateKeepOriginalFilename
        self.updateAutoPauseBackgroundVideo = updateAutoPauseBackgroundVideo
        self.updateSaveMediaToLuminaAlbum = updateSaveMediaToLuminaAlbum
        self.updateSwipeVideoPip = updateSwipeVideoPip
        self.updateSendLargePhotos = updateSendLargePhotos
        self.updateTransferBoost = updateTransferBoost
        self.pickPhotoQuality = pickPhotoQuality
        self.openReverseVoiceComposer = openReverseVoiceComposer
    }
}

private enum LuminaVoiceMediaSection: Int32 {
    case voice
    case reverseVoice
    case ocr
    case media
    case photos
    case transfers
}

private enum LuminaVoiceMediaEntry: ItemListNodeEntry {
    case voiceHeader
    case sttAutoPipeline(Bool)
    case autoTranslateTranscript(Bool)
    case voiceFooter

    case reverseVoiceHeader
    case reverseVoice(Bool)
    case reverseVoiceCompose(Bool)
    case reverseVoiceFooter

    case ocrHeader
    case ocrTranslate(Bool)
    case ocrFooter

    case mediaHeader
    case keepOriginalFilename(Bool)
    case autoPauseBackgroundVideo(Bool)
    case saveMediaToLuminaAlbum(Bool)
    case swipeVideoPip(Bool)
    case mediaFooter

    case photosHeader
    case photoQuality(Int32)
    case sendLargePhotos(Bool)
    case photosFooter

    case transfersHeader
    case transferBoost(Bool)
    case transfersFooter

    var section: ItemListSectionId {
        switch self {
        case .voiceHeader, .sttAutoPipeline, .autoTranslateTranscript, .voiceFooter:
            return LuminaVoiceMediaSection.voice.rawValue
        case .reverseVoiceHeader, .reverseVoice, .reverseVoiceCompose, .reverseVoiceFooter:
            return LuminaVoiceMediaSection.reverseVoice.rawValue
        case .ocrHeader, .ocrTranslate, .ocrFooter:
            return LuminaVoiceMediaSection.ocr.rawValue
        case .mediaHeader, .keepOriginalFilename, .autoPauseBackgroundVideo, .saveMediaToLuminaAlbum, .swipeVideoPip, .mediaFooter:
            return LuminaVoiceMediaSection.media.rawValue
        case .photosHeader, .photoQuality, .sendLargePhotos, .photosFooter:
            return LuminaVoiceMediaSection.photos.rawValue
        case .transfersHeader, .transferBoost, .transfersFooter:
            return LuminaVoiceMediaSection.transfers.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .voiceHeader: return 0
        case .sttAutoPipeline: return 1
        case .autoTranslateTranscript: return 2
        case .voiceFooter: return 3
        case .reverseVoiceHeader: return 4
        case .reverseVoice: return 5
        case .reverseVoiceCompose: return 6
        case .reverseVoiceFooter: return 7
        case .ocrHeader: return 8
        case .ocrTranslate: return 9
        case .ocrFooter: return 10
        case .mediaHeader: return 11
        case .keepOriginalFilename: return 12
        case .autoPauseBackgroundVideo: return 13
        case .saveMediaToLuminaAlbum: return 14
        case .swipeVideoPip: return 15
        case .mediaFooter: return 16
        case .photosHeader: return 17
        case .photoQuality: return 18
        case .sendLargePhotos: return 19
        case .photosFooter: return 20
        case .transfersHeader: return 21
        case .transferBoost: return 22
        case .transfersFooter: return 23
        }
    }

    static func <(lhs: LuminaVoiceMediaEntry, rhs: LuminaVoiceMediaEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaVoiceMediaSettingsControllerArguments
        switch self {
        case .voiceHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("VOICE-TO-TEXT"), sectionId: self.section)
        case let .sttAutoPipeline(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Auto-transcribe in translated chats"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSttAutoPipeline(value)
            })
        case let .autoTranslateTranscript(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Translate transcript automatically"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateAutoTranslateTranscript(value)
            })
        case .voiceFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Transcribe a voice message from its context menu. Runs fully on-device with Apple's Speech framework - never sent to a server. \"Auto-transcribe\" also runs this automatically for incoming voice notes in chats you already have translation on for.")), sectionId: self.section)
        case .reverseVoiceHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("REVERSE VOICE (EXPERIMENTAL)"), sectionId: self.section)
        case let .reverseVoice(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Enable reverse voice"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateReverseVoice(value)
            })
        case let .reverseVoiceCompose(enabled):
            return ItemListDisclosureItem(presentationData: presentationData, title: LuminaL10n.tr("Send a Reverse Voice Message"), enabled: enabled, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: enabled ? {
                arguments.openReverseVoiceComposer()
            } : nil)
        case .reverseVoiceFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Type a message, speak it on-device with the system voice, and send it as a real voice message. No cloud text-to-speech, no voice cloning. Off by default.")), sectionId: self.section)
        case .ocrHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("IMAGE TEXT"), sectionId: self.section)
        case let .ocrTranslate(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Show \"Translate Image\" action"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateOcrTranslate(value)
            })
        case .ocrFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Uses Telegram's existing on-device Vision text recognition to translate text found in photos and screenshots, from the image viewer's menu.")), sectionId: self.section)
        case .mediaHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("MEDIA"), sectionId: self.section)
        case let .keepOriginalFilename(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Keep original filename on save"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateKeepOriginalFilename(value)
            })
        case let .autoPauseBackgroundVideo(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Auto-pause video in background"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateAutoPauseBackgroundVideo(value)
            })
        case let .saveMediaToLuminaAlbum(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Save to \"LuminaGram\" album"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSaveMediaToLuminaAlbum(value)
            })
        case let .swipeVideoPip(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Swipe Down for Picture-in-Picture"), text: LuminaL10n.tr("Swipe a full-screen video down to enter picture-in-picture instead of closing it."), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSwipeVideoPip(value)
            })
        case .mediaFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Applies to media saved through auto-save. Photos/videos are also added to a separate \"LuminaGram\" album alongside your camera roll when enabled.")), sectionId: self.section)
        case .photosHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("PHOTOS"), sectionId: self.section)
        case let .photoQuality(value):
            return ItemListDisclosureItem(presentationData: presentationData, title: LuminaL10n.tr("Photo Quality"), label: value == 0 ? LuminaL10n.tr("Default") : "\(value)%", sectionId: self.section, style: .blocks, action: {
                arguments.pickPhotoQuality(value)
            })
        case let .sendLargePhotos(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Send Photos in Higher Resolution"), text: LuminaL10n.tr("Send photos at up to 2560px instead of 1280px. Uses more data."), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSendLargePhotos(value)
            })
        case .photosFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Photos are sent through Telegram's normal upload. These options only change the compression quality and size before upload.")), sectionId: self.section)
        case .transfersHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("FAST TRANSFERS (EXPERIMENTAL)"), sectionId: self.section)
        case let .transferBoost(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Speed Up Large File Transfers"), text: LuminaL10n.tr("Use larger upload and download chunks to move big files faster."), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateTransferBoost(value)
            })
        case .transfersFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Experimental. Sends and receives files in larger pieces to speed up big transfers. If uploads or downloads start failing on your network, turn this off. Off by default - and when off, Telegram's standard transfer behavior is completely unchanged.")), sectionId: self.section)
        }
    }
}

private func luminaVoiceMediaSettingsControllerEntries(settings: LuminaSettings) -> [LuminaVoiceMediaEntry] {
    return [
        .voiceHeader,
        .sttAutoPipeline(settings.sttAutoPipeline),
        .autoTranslateTranscript(settings.autoTranslateTranscript),
        .voiceFooter,
        .reverseVoiceHeader,
        .reverseVoice(settings.reverseVoice),
        .reverseVoiceCompose(settings.reverseVoice),
        .reverseVoiceFooter,
        .ocrHeader,
        .ocrTranslate(settings.ocrTranslate),
        .ocrFooter,
        .mediaHeader,
        .keepOriginalFilename(settings.keepOriginalFilename),
        .autoPauseBackgroundVideo(settings.autoPauseBackgroundVideo),
        .saveMediaToLuminaAlbum(settings.saveMediaToLuminaAlbum),
        .swipeVideoPip(settings.swipeVideoPip),
        .mediaFooter,
        .photosHeader,
        .photoQuality(settings.outgoingPhotoQuality),
        .sendLargePhotos(settings.sendLargePhotos),
        .photosFooter,
        .transfersHeader,
        .transferBoost(settings.transferBoost),
        .transfersFooter
    ]
}

public func luminaVoiceMediaSettingsController(context: AccountContext) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?
    var presentControllerImpl: ((ViewController) -> Void)?

    let arguments = LuminaVoiceMediaSettingsControllerArguments(
        context: context,
        pushController: { c in
            pushControllerImpl?(c)
        },
        updateSttAutoPipeline: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.sttAutoPipeline = value
                return settings
            }).start()
        },
        updateAutoTranslateTranscript: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.autoTranslateTranscript = value
                return settings
            }).start()
        },
        updateReverseVoice: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.reverseVoice = value
                return settings
            }).start()
        },
        updateOcrTranslate: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.ocrTranslate = value
                return settings
            }).start()
        },
        updateKeepOriginalFilename: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.keepOriginalFilename = value
                return settings
            }).start()
        },
        updateAutoPauseBackgroundVideo: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.autoPauseBackgroundVideo = value
                return settings
            }).start()
        },
        updateSaveMediaToLuminaAlbum: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.saveMediaToLuminaAlbum = value
                return settings
            }).start()
        },
        updateSwipeVideoPip: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.swipeVideoPip = value
                return settings
            }).start()
        },
        updateSendLargePhotos: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.sendLargePhotos = value
                return settings
            }).start()
        },
        updateTransferBoost: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.transferBoost = value
                return settings
            }).start()
        },
        pickPhotoQuality: { currentValue in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let makeAction: (Int32, String) -> TextAlertAction = { value, title in
                TextAlertAction(type: value == currentValue ? .defaultAction : .genericAction, title: title, action: {
                    let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                        var settings = settings
                        settings.outgoingPhotoQuality = value
                        return settings
                    }).start()
                })
            }
            presentControllerImpl?(textAlertController(context: context, title: LuminaL10n.tr("Photo Quality"), text: LuminaL10n.tr("Choose the JPEG quality for photos you send. Higher quality means larger uploads. Default keeps Telegram's standard quality."), actions: [
                makeAction(0, LuminaL10n.tr("Default")),
                makeAction(70, "70%"),
                makeAction(80, "80%"),
                makeAction(90, "90%"),
                makeAction(100, LuminaL10n.tr("Maximum (100%)")),
                TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {})
            ], actionLayout: .vertical))
        },
        openReverseVoiceComposer: {
            let controller = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.onlyWriteable, .excludeDisabled], selectForumThreads: true))
            controller.peerSelected = { [weak controller] peer, _ in
                controller?.dismiss()
                pushControllerImpl?(luminaReverseVoiceController(context: context, peerId: peer.id))
            }
            pushControllerImpl?(controller)
        }
    )

    let signal = combineLatest(
        context.sharedContext.presentationData,
        context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
    )
    |> deliverOnMainQueue
    |> map { presentationData, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? .defaultSettings
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuminaL10n.tr("Voice & Media")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaVoiceMediaSettingsControllerEntries(settings: settings), style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
