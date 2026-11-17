import UIKit

/// Sizes shared by every screen (ui-spec §1). Widths come from the view that lays out, never from the screen.
enum Metrics {
    /// Side padding of a page: 12 on a 320 pt wide view, 16 otherwise.
    static func pad(_ width: CGFloat) -> CGFloat {
        return width <= 320 ? 12 : 16
    }

    /// Gap between an avatar and the content next to it.
    static func gap(_ width: CGFloat) -> CGFloat {
        return width <= 320 ? 10 : 12
    }

    static let avatar: CGFloat = 40
    /// One device pixel.
    static let hairline: CGFloat = 1 / UIScreen.main.scale
    static let topBarHeight: CGFloat = 44
    static let tabStripHeight: CGFloat = 44
    /// Without the bottom safe area, which the bar adds itself.
    static let bottomBarHeight: CGFloat = 49

    static func contentX(_ width: CGFloat) -> CGFloat {
        return pad(width) + avatar + gap(width)
    }

    static func contentWidth(_ width: CGFloat) -> CGFloat {
        return width - contentX(width) - pad(width)
    }

    /// The widest content column (ui-spec §8.2): X's own reading width.
    static let columnMaxWidth: CGFloat = 600

    /// True for a large screen: the view is at least 600 pt wide (an iPad in both orientations, never an iPhone).
    static func isLarge(_ width: CGFloat) -> Bool {
        return width >= columnMaxWidth
    }

    /// The content column inside `bounds`: the full width below 600 + 2 × 16 pt, otherwise 600 pt wide and centred,
    /// its x rounded to whole points. Height and y are those of `bounds`.
    static func column(in bounds: CGRect) -> CGRect {
        guard bounds.width >= columnMaxWidth + 2 * 16 else {
            return bounds
        }
        let x = ((bounds.width - columnMaxWidth) / 2).rounded()
        return CGRect(x: bounds.minX + x, y: bounds.minY, width: columnMaxWidth, height: bounds.height)
    }
}
