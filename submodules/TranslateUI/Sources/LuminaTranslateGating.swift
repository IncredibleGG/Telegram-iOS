import Foundation
import TelegramUIPreferences

// LuminaGram — group-skip "only translate what I can't read" (iOS twin of Android's
// groupSkipMyLanguages/myLanguages/isMyLanguage and desktop's TranslateOfferSkip gating in
// lumina_translate_gating.cpp). Telegram-iOS already has the primitive this extends:
// effectiveIgnoredTranslationLanguages(context:ignoredLanguages:) in Translate.swift, which
// returns the set of language codes translation is NOT offered for. This adds LuminaSettings'
// user-editable "my languages" set plus trReadLang on top of that set, gated by
// groupSkipMyLanguages (default ON) — see the `// LuminaGram: group-skip my languages`
// insertion in effectiveIgnoredTranslationLanguages for the call site.
public func luminaAdditionalIgnoredTranslationLanguages(settings: LuminaSettings) -> Set<String> {
    guard settings.groupSkipMyLanguages else {
        return []
    }
    var result = Set<String>()
    for language in settings.myLanguages {
        result.insert(normalizeTranslationLanguage(language))
    }
    // trReadLang is "the language I read chats in"; empty means "follow the interface
    // language", which effectiveIgnoredTranslationLanguages already covers on its own via
    // baseLang/systemLanguageCodes(), so there is nothing to add in that case.
    if !settings.trReadLang.isEmpty {
        result.insert(normalizeTranslationLanguage(settings.trReadLang))
    }
    return result
}
