import UIKit

/// The one line under a post or a profile bio that offers, shows or hides a translation (ui-spec §7). Rows and the
/// profile header draw it with this helper, so the texts and colours are the same everywhere. The caller places the
/// text (15 pt in the focal post, 13 pt in list rows) and makes the line its own touch target.
enum TranslationLine {
    /// The line for a text, or nil when there is nothing to show (the text is not translatable). `promptTitle` is the
    /// offer: "ポストを翻訳" or "自己紹介を翻訳".
    static func attributed(isTranslatable: Bool, isTranslating: Bool, translation: Translation?,
                           showsTranslation: Bool, promptTitle: String, fontSize: CGFloat) -> NSAttributedString? {
        guard isTranslatable else { return nil }
        let palette = Theme.palette
        let font = Theme.font(fontSize)
        if isTranslating {
            return styled("翻訳中…", color: palette.secondaryText, font: font)
        }
        guard let translation = translation else {
            return styled(promptTitle, color: palette.accent, font: font)
        }
        guard showsTranslation else {
            return styled("翻訳を表示", color: palette.accent, font: font)
        }
        // "英語からGoogleによる翻訳 · 原文を表示": the origin part is secondary, the way back is the accent
        let line = NSMutableAttributedString(string: "")
        line.append(styled("\(translation.sourceLangName)から\(translation.provider)による翻訳 · ",
                           color: palette.secondaryText, font: font))
        line.append(styled("原文を表示", color: palette.accent, font: font))
        return line
    }

    private static func styled(_ text: String, color: UIColor, font: UIFont) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key.font: font,
            NSAttributedString.Key.foregroundColor: color,
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }
}
