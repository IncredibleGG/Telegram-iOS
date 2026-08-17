import Foundation

// LuminaGram: hide own phone number (privacy bucket) - port of Android's hideOwnPhone
// (LuminaConfig "hideOwnPhone", masked via the LuminaHideOwnPhoneMasked string resource).
//
// Pure local render gate: LuminaSettingsCache.settings.hideOwnPhone decides, at each of the
// two places iOS shows the ACCOUNT'S OWN phone number, whether to show `maskedText` instead
// of the real formatted number - PeerInfoSettingsItems.swift's Settings-screen phone row, and
// PeerInfoHeaderNode.swift's Settings-screen header subtitle. Nothing here touches the phone
// number Telegram itself holds, nowhere else's phone number is ever masked (this is "own",
// not "any"), and no network call is involved.
//
// English-hardcoded rather than routed through PresentationStrings, for the same reason
// LuminaGramSettingsController.swift's own UI text is (see that file's header comment): a
// PresentationStrings key this fork invents has no cloud translation and would silently read
// English for every non-English user regardless of their selected language.
public enum LuminaHidePhone {
    public static let maskedText = "Hidden"
}
