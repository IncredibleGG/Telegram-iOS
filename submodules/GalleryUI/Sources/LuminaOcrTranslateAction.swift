import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import AccountContext
import ImageContentAnalysis
import ChatRichTextEditorComposer

// LuminaGram: one-tap "Translate Image" for the full-screen photo viewer. Telegram-iOS already
// ships on-device Vision-based text recognition for images (ImageContentAnalysis.recognizedContent,
// used today to let you manually select recognized text and translate it - see
// ChatImageGalleryItem.swift's RecognizedTextSelectionAction.translate case). This adds a single
// menu action that runs that SAME recognizer and opens the SAME translate screen with every piece
// of recognized text already joined, instead of requiring a manual text selection first -
// mirroring the one-tap flow the Android port's LuminaOcr gives (recognize -> translate directly).
// No new OCR engine, no ML Kit, nothing bundled - purely wiring on top of what already ships.
// Gated on LuminaSettings.ocrTranslate (default ON).
public enum LuminaOcrTranslateAction {
    public static func isEnabled(context: AccountContext, completion: @escaping (Bool) -> Void) {
        let _ = (context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
        |> take(1)
        |> deliverOnMainQueue).start(next: { sharedData in
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? .defaultSettings
            completion(settings.ocrTranslate)
        })
    }

    /// Recognizes text in `image()` (reusing the cached-per-message recognition Telegram already
    /// computes) and, if any was found, presents Telegram's own translate screen with it.
    public static func translateImageText(context: AccountContext, image: @escaping () -> UIImage?, messageId: EngineMessage.Id, presentController: @escaping (ViewController, Any?) -> Void, noTextFound: @escaping () -> Void) {
        let _ = (recognizedContent(context: context, image: image, messageId: messageId)
        |> take(1)
        |> deliverOnMainQueue).start(next: { results in
            var pieces: [String] = []
            for result in results {
                if case let .text(text, _) = result.content, !text.isEmpty {
                    pieces.append(text)
                }
            }
            let joined = pieces.joined(separator: "\n")
            guard !joined.isEmpty else {
                noTextFound()
                return
            }
            Task { @MainActor in
                let controller = await context.sharedContext.makeTextProcessingScreen(
                    context: context,
                    theme: nil,
                    mode: .translate(fromLanguage: nil, applyResult: nil),
                    inputText: .plain(text: joined, entities: []),
                    copyResult: { composed in
                        storeComposedRichMessageInPasteboard(composed)
                    },
                    translateChat: nil
                )
                presentController(controller, nil)
            }
        })
    }
}
