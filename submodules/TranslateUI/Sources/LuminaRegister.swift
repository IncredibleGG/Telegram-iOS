import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramUIPreferences

// LuminaGram — per-chat register/tone (iOS twin of Android's LuminaRegister and desktop's
// register support in lumina_translate_providers.cpp). Each dialog may carry one register
// (LuminaSettings.trRegisterDialog); every translation of that dialog is asked to speak in
// it wherever the active engine has a channel for tone at all:
//   - LLM (OpenAI-compatible): the register is appended to the system prompt as an extra
//     paragraph (promptSuffix), layered under the user's own translatePrompt, never replacing it.
//   - Telegram (native messages.translateText RPC): the register collapses onto the RPC's
//     own `tone` parameter (neutral/casual/formal) via telegramTone.
//   - DeepL: collapses onto its native `formality` parameter, only for the target languages
//     DeepL documents as supporting it (deeplFormality).
//   - Google (free web): no channel for tone at all; nothing is sent.
public enum LuminaRegisterCode {
    public static let none = ""
    public static let client = "client"
    public static let colleague = "colleague"
    public static let friend = "friend"
    public static let family = "family"
    public static let elder = "elder"
    public static let romance = "romance"
    public static let customPrefix = "custom:"

    // The preset registers, in the order a picker should list them.
    public static let presets: [String] = [client, colleague, friend, family, elder, romance]

    public static func isCustom(_ stored: String) -> Bool {
        return stored.hasPrefix(customPrefix)
    }

    public static func customText(_ stored: String) -> String {
        guard isCustom(stored) else {
            return ""
        }
        return String(stored.dropFirst(customPrefix.count))
    }

    // Build the stored form of a user-written description, or `none` when it is blank.
    public static func custom(_ description: String) -> String {
        let cleaned = sanitize(description)
        return cleaned.isEmpty ? none : customPrefix + cleaned
    }

    // One line, no quotes: this lands inside a quoted phrase in the system prompt, and a
    // newline or an unescaped quote there would read as the end of the instruction.
    private static func sanitize(_ s: String) -> String {
        var result = ""
        for ch in s.prefix(200) {
            if ch == "\n" || ch == "\r" || ch == "\t" {
                result.append(" ")
            } else if ch == "\"" || ch == "\\" {
                result.append("'")
            } else if ch >= " " {
                result.append(ch)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // English label for a stored code; a custom register shows the user's own sentence.
    // LuminaGram's own UI text is hardcoded English throughout this fork (see
    // LuminaGramSettingsController.swift's header comment) since PresentationStrings has
    // no cloud translation for keys this fork invents.
    public static func displayName(_ stored: String) -> String {
        if isCustom(stored) {
            let text = customText(stored)
            return text.isEmpty ? "Custom" : text
        }
        switch stored {
        case client:
            return "Client"
        case colleague:
            return "Colleague"
        case friend:
            return "Friend"
        case family:
            return "Family"
        case elder:
            return "Elder"
        case romance:
            return "Romantic interest"
        default:
            return "None"
        }
    }
}

public enum LuminaRegister {
    // The stored register for a dialog, or LuminaRegisterCode.none when unset.
    public static func get(settings: LuminaSettings, peerId: EnginePeer.Id) -> String {
        return settings.trRegisterDialog.first(where: { $0.peerId == peerId.toInt64() })?.value ?? LuminaRegisterCode.none
    }

    // Store (or, for LuminaRegisterCode.none, clear) the register for a dialog.
    public static func set(accountManager: AccountManager<TelegramAccountManagerTypes>, peerId: EnginePeer.Id, value: String) -> Signal<Void, NoError> {
        return updateLuminaSettingsInteractively(accountManager: accountManager) { settings in
            var settings = settings
            var list = settings.trRegisterDialog
            list.removeAll(where: { $0.peerId == peerId.toInt64() })
            if value != LuminaRegisterCode.none {
                list.append(LuminaSettings.DialogTextValue(peerId: peerId.toInt64(), value: value))
            }
            settings.trRegisterDialog = list
            return settings
        }
    }

    // True when the given engine id has no channel for tone whatsoever (Google web).
    public static func engineIgnoresRegister(engineId: String) -> Bool {
        return engineId != "llm" && engineId != "deepl" && engineId != "telegram"
    }

    // MARK: - LLM system-prompt injection

    // The paragraph to append to the LLM system prompt, or nil when no register applies.
    // Appended, never substituted: the user's own translatePrompt keeps saying whatever it
    // says; this only adds how it should sound.
    public static func promptSuffix(stored: String) -> String? {
        guard let body = instruction(stored) else {
            return nil
        }
        return "\n\nTone and register for this conversation: " + body
            + " Adapt only the tone, the politeness level and the choice of words. Never change "
            + "the meaning, never add or drop information, and never mention or explain the tone "
            + "— output the translation only."
    }

    // The instruction itself is written in English on purpose: it is read by the model, not
    // by the user, and English is the language these models follow instructions in most
    // reliably. Ported verbatim from Android's LuminaRegister.instruction(...) / desktop's
    // RegisterPromptSuffix so the three platforms translate a given register the same way.
    private static func instruction(_ stored: String) -> String? {
        if stored.isEmpty {
            return nil
        }
        if LuminaRegisterCode.isCustom(stored) {
            let text = LuminaRegisterCode.customText(stored)
            if text.isEmpty {
                return nil
            }
            return "the sender describes this relationship as \"" + text + "\". Match the tone, the "
                + "formality and the vocabulary that relationship calls for, including the "
                + "appropriate politeness level in languages that mark politeness grammatically."
        }
        switch stored {
        case LuminaRegisterCode.client:
            return "the other person is a business client or customer. Write the translation in polite, "
                + "professional, formal business language. In languages that mark politeness "
                + "grammatically, use the formal or honorific register (Japanese 敬語 with です・ます, "
                + "Korean 하십시오체, Chinese 您, German Sie, French vous, Spanish usted). No slang, "
                + "no over-familiar wording."
        case LuminaRegisterCode.colleague:
            return "the other person is a work colleague of roughly equal standing. Write the "
                + "translation in ordinary polite workplace language — courteous but relaxed, not "
                + "stiff. In languages that mark politeness grammatically, use the standard polite "
                + "register (Japanese です・ます, Korean 해요체, German Sie, French vous). Everyday "
                + "workplace shorthand is fine; slang is not."
        case LuminaRegisterCode.friend:
            return "the other person is a close friend. Write the translation in casual, informal, "
                + "everyday spoken language, with the contractions and colloquialisms a friend would "
                + "actually use. In languages that mark politeness grammatically, use the plain or "
                + "casual register (Japanese 常体 / タメ口, Korean 반말, German du, French tu, "
                + "Spanish tú)."
        case LuminaRegisterCode.family:
            return "the other person is a family member. Write the translation in warm, familiar, "
                + "everyday language of the kind used at home. In languages that mark politeness "
                + "grammatically, use the plain or familiar register (Japanese 常体, German du, "
                + "French tu), and keep kinship terms natural for the target culture."
        case LuminaRegisterCode.elder:
            return "the other person is an elder or a senior the sender owes respect to. Write the "
                + "translation in respectful, deferential language that still sounds warm and "
                + "personal rather than corporate. In languages with honorifics, use the honorific "
                + "register (Japanese 敬語, Korean 존댓말, Chinese 您) and respectful forms of "
                + "address."
        case LuminaRegisterCode.romance:
            return "the other person is someone the sender is romantically interested in. Write the "
                + "translation in warm, playful, affectionate language with a light flirtatious "
                + "touch — never crude or explicit. In languages that mark politeness "
                + "grammatically, use the soft casual register (Japanese 常体, Korean 반말 or a "
                + "gentle 해요체, French tu, Spanish tú)."
        default:
            return nil
        }
    }

    // MARK: - DeepL formality

    // The target languages DeepL documents formality support for (as LuminaLang.deepl spells
    // them). Sending the parameter for any other target is an error response, so this list is
    // a gate, not an optimization.
    private static let deeplFormalityLangs: Set<String> = ["DE", "FR", "IT", "ES", "NL", "PL", "PT-BR", "PT-PT", "JA", "RU"]

    // DeepL's `formality` value for a stored register and a DeepL-spelled target language, or
    // nil when it does not apply.
    public static func deeplFormality(stored: String, toLangDeepL: String) -> String? {
        let value: String
        switch stored {
        case LuminaRegisterCode.client, LuminaRegisterCode.colleague, LuminaRegisterCode.elder:
            value = "prefer_more"
        case LuminaRegisterCode.friend, LuminaRegisterCode.family, LuminaRegisterCode.romance:
            value = "prefer_less"
        default:
            return nil
        }
        guard self.deeplFormalityLangs.contains(toLangDeepL) else {
            return nil
        }
        return value
    }

    // MARK: - Telegram native tone

    // Telegram's own messages.translateText RPC carries a real (if coarse) tone parameter;
    // collapse the six presets onto it the same way DeepL's formality does.
    public static func telegramTone(stored: String) -> TranslationTone {
        switch stored {
        case LuminaRegisterCode.client, LuminaRegisterCode.colleague, LuminaRegisterCode.elder:
            return .formal
        case LuminaRegisterCode.friend, LuminaRegisterCode.family, LuminaRegisterCode.romance:
            return .casual
        default:
            return .neutral
        }
    }
}
