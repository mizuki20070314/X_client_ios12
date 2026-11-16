import UIKit

/// The frames of a trend row at one width (ui-spec.md §5.5). Built once per width by TrendRow.
struct TrendLayout {
    let width: CGFloat
    let height: CGFloat
    let contextFrame: CGRect?
    let nameFrame: CGRect
    let metaFrame: CGRect?
    let hairlineFrame: CGRect
}

extension TrendLayout {
    /// Context, name and meta: each only when present, 2 pt apart, 12 pt above and below.
    static func make(trend: Trend, width: CGFloat) -> TrendLayout {
        let pad = Metrics.pad(width)
        let textWidth = width - 2 * pad
        let smallHeight = ceil(Theme.font(13).lineHeight)
        let nameHeight = ceil(Theme.font(15, .bold).lineHeight)
        var y: CGFloat = 12

        var contextFrame: CGRect?
        if trend.context != nil {
            contextFrame = CGRect(x: pad, y: y, width: textWidth, height: smallHeight)
            y += smallHeight + 2
        }
        let nameFrame = CGRect(x: pad, y: y, width: textWidth, height: nameHeight)
        y += nameHeight

        var metaFrame: CGRect?
        if trend.meta != nil {
            y += 2
            metaFrame = CGRect(x: pad, y: y, width: textWidth, height: smallHeight)
            y += smallHeight
        }

        let height = y + 12
        return TrendLayout(
            width: width,
            height: height,
            contextFrame: contextFrame,
            nameFrame: nameFrame,
            metaFrame: metaFrame,
            hairlineFrame: CGRect(x: 0, y: height - Metrics.hairline, width: width, height: Metrics.hairline)
        )
    }
}

extension TrendRow {
    /// The layout at `width`, computed once and then reused.
    func layout(for width: CGFloat) -> TrendLayout {
        if let cached = layoutCache, cached.width == width {
            return cached
        }
        let fresh = TrendLayout.make(trend: trend, width: width)
        layoutCache = fresh
        return fresh
    }
}

/// A trend of the explore list: context (13), name (15 bold) and meta (13), each line only when present.
final class TrendCell: TimelineCellBase {
    private let contextLabel = UILabel()
    private let nameLabel = UILabel()
    private let metaLabel = UILabel()

    override func setUpContent() {
        let palette = Theme.palette
        contextLabel.font = Theme.font(13)
        contextLabel.textColor = palette.secondaryText
        nameLabel.font = Theme.font(15, .bold)
        nameLabel.textColor = palette.text
        metaLabel.font = Theme.font(13)
        metaLabel.textColor = palette.secondaryText
        let labels: [UILabel] = [contextLabel, nameLabel, metaLabel]
        for label in labels {
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            contentView.addSubview(label)
        }
    }

    func configure(_ row: TrendRow, layout: TrendLayout) {
        contextLabel.text = row.trend.context
        contextLabel.timelinePlace(layout.contextFrame)
        nameLabel.text = row.trend.name
        nameLabel.timelinePlace(layout.nameFrame)
        metaLabel.text = row.trend.meta
        metaLabel.timelinePlace(layout.metaFrame)
        hairline.timelinePlace(layout.hairlineFrame)
    }
}
