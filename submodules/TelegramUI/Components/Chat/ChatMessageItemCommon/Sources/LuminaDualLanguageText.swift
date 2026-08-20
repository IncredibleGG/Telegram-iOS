import Foundation
import TelegramCore

// LuminaGram — dual-language incoming display + folding long originals (iOS twin of
// Android's dual-language rendering and desktop's lumina_dual_language_line.{h,cpp}).
// Telegram-iOS's own translation rendering (ChatMessageTextBubbleContentNode.swift) replaces
// the original text with the translation outright; this instead composes both, so the reader
// keeps the source text as a reference — see the `// LuminaGram: dual-language display`
// insertion at that file's translation-attribute branch for the call site.
//
// Rendering: original first (the message as sent, in the bubble's normal style), then the
// translation below it, set in italics so the two are visually distinguishable within the
// single text node Telegram-iOS already lays out for a bubble's text content. A genuinely
// separate second text node/sub-bubble (as desktop renders it) is out of scope at this call
// site: AsyncDisplayKit's bubble content-node layout is not built for adding a dynamic
// sibling node here without touching the surrounding layout math.
//
// Folding: desktop truncates the ORIGINAL to ~4 wrapped lines with a tap-to-expand
// affordance once it grows past that. This port keeps "long originals are folded" but as a
// static character-count truncation with no interactive expand: a genuine per-message
// expand/collapse would need a state table keyed by message id plus a link-style tap handler
// threaded through this node's existing text-selection/link handling, which is a reasonable
// follow-up rather than something to guess at without being able to build and click it.
public enum LuminaDualLanguageText {
    // A static stand-in for desktop's "wraps past 4 lines" rule: AsyncDisplayKit does not
    // expose a wrapped line count before layout runs, so this approximates it in characters
    // instead (roughly 4 lines of a typical bubble width).
    private static let foldCharacterThreshold = 320

    public struct Composed {
        public let text: String
        public let entities: [MessageTextEntity]
    }

    // Combine `original` (the message as authored) and `translated` (the cached
    // TranslationMessageAttribute text) into one string plus the entities needed to render
    // it, applying the fold when `fold` is true and the original is long.
    public static func compose(original: String, originalEntities: [MessageTextEntity], translated: String, translatedEntities: [MessageTextEntity], fold: Bool) -> Composed {
        var originalPart = original
        var originalWasFolded = false
        if fold && originalPart.count > self.foldCharacterThreshold {
            let cutIndex = originalPart.index(originalPart.startIndex, offsetBy: self.foldCharacterThreshold)
            originalPart = String(originalPart[originalPart.startIndex..<cutIndex]) + "…"
            originalWasFolded = true
        }

        // Folded originals drop their own entities: a mid-entity truncation would otherwise
        // leave a range pointing past the end of the (now shorter) string.
        var entities: [MessageTextEntity] = originalWasFolded ? [] : originalEntities

        let separator = "\n\n"
        let text = originalPart + separator + translated
        // MessageTextEntity.range is UTF-16 code units (NSString length) everywhere in this codebase
        // (stringWithAppliedEntities maps range straight onto an NSRange over the NSString; API
        // entities carry UTF-16 offset/length). Character count drifts left on emoji / non-BMP, so
        // compute the translation's start + ranges in UTF-16, not Swift Character count.
        let translationStart = ((originalPart + separator) as NSString).length

        entities.append(MessageTextEntity(range: translationStart ..< (translationStart + (translated as NSString).length), type: .Italic))
        // Re-offset the translation's own entities (links, mentions, bold, …) so they still
        // land correctly inside the combined string.
        for entity in translatedEntities {
            entities.append(MessageTextEntity(range: (entity.range.lowerBound + translationStart) ..< (entity.range.upperBound + translationStart), type: entity.type))
        }

        return Composed(text: text, entities: entities)
    }
}
