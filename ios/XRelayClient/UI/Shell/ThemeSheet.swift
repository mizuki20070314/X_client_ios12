import UIKit

/// The ダークモード sheet (ui-spec §5.8), shared by the drawer and the settings screen.
enum ThemeSheet {
    static func present(from presenter: UIViewController?) {
        let current = effectiveMode
        var items: [BottomSheetItem] = [
            makeItem(.light, current: current),
            makeItem(.dim, current: current),
            makeItem(.black, current: current),
        ]
        if #available(iOS 13.0, *) {
            items.append(makeItem(.system, current: current))
        }
        BottomSheet.present(from: presenter, title: "ダークモード", items: items)
    }

    /// The name of a theme, as the sheet and the settings row show it.
    static func name(for mode: ThemeMode) -> String {
        switch mode {
        case .light:
            return "ライト"
        case .dim:
            return "ダークブルー"
        case .black:
            return "ブラック"
        case .system:
            return "端末の設定に合わせる"
        }
    }

    /// The mode in effect for the checkmark and the settings row. iOS 12 has no system style, so there it is light.
    static var effectiveMode: ThemeMode {
        if #available(iOS 13.0, *) {
            return Theme.mode
        }
        return Theme.mode == .system ? .light : Theme.mode
    }

    private static func makeItem(_ mode: ThemeMode, current: ThemeMode) -> BottomSheetItem {
        return BottomSheetItem(icon: nil, title: name(for: mode), isChecked: mode == current, handler: {
            ThemeSheet.choose(mode)
        })
    }

    /// Saving a theme posts a change, and AppDelegate builds a new root for it. The same theme changes nothing.
    private static func choose(_ mode: ThemeMode) {
        guard Theme.mode != mode else { return }
        Theme.mode = mode
    }
}
