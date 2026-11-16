import UIKit

/// The tab titles above a pager (ui-spec §3.1). `fill` spreads the titles evenly; `scroll` sizes each title to its text
/// plus 32 pt and scrolls the row. The indicator is measured with the bold title, so the segments do not change width
/// when the selection moves.
final class TabStripView: UIView {
    enum Style {
        case fill, scroll
    }

    /// Called for every tap on a title, including the selected one. Setting `selectedIndex` does not call it.
    var onSelect: ((Int) -> Void)?

    private static let indicatorHeight: CGFloat = 4
    private static let scrollPadding: CGFloat = 32

    private let style: Style
    private var titles: [String]
    private var selection = 0
    private let scrollView = UIScrollView()
    private var labels: [UILabel] = []
    /// Segment frames and indicator rects in the content coordinates of the scroll view.
    private var segments: [CGRect] = []
    private var indicatorRects: [CGRect] = []
    private let indicator = UIView()
    private let hairline = UIView()

    init(titles: [String], style: Style) {
        self.style = style
        self.titles = titles
        super.init(frame: .zero)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.isScrollEnabled = style == .scroll
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)
        scrollView.addSubview(indicator)
        addSubview(hairline)
        indicator.layer.cornerRadius = TabStripView.indicatorHeight / 2
        scrollView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        rebuildLabels()
        updateColors()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The index of the selected title. Setting it moves the indicator in 0.2 s and scrolls the title into view.
    var selectedIndex: Int {
        get {
            return selection
        }
        set {
            select(newValue, animated: true)
        }
    }

    func setTitles(_ titles: [String]) {
        self.titles = titles
        selection = min(selection, max(0, titles.count - 1))
        rebuildLabels()
        updateColors()
        setNeedsLayout()
    }

    /// Moves the indicator to a fractional index while a pager is dragged (0 is the first title).
    func setProgress(_ position: CGFloat) {
        guard !indicatorRects.isEmpty else { return }
        let last = CGFloat(indicatorRects.count - 1)
        let clamped = min(max(position, 0), last)
        let base = Int(clamped.rounded(.down))
        let next = min(base + 1, indicatorRects.count - 1)
        let fraction = clamped - CGFloat(base)
        let from = indicatorRects[base]
        let to = indicatorRects[next]
        // a running move would overwrite the frame set here on every frame
        indicator.layer.removeAllAnimations()
        indicator.frame = CGRect(x: from.minX + (to.minX - from.minX) * fraction,
                                 y: from.minY,
                                 width: from.width + (to.width - from.width) * fraction,
                                 height: from.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = bounds.height
        scrollView.frame = bounds
        hairline.frame = CGRect(x: 0, y: height - Metrics.hairline, width: bounds.width, height: Metrics.hairline)

        let widths = titleWidths()
        var newSegments: [CGRect] = []
        var newIndicators: [CGRect] = []
        var contentWidth = bounds.width
        if style == .fill {
            let each = bounds.width / CGFloat(max(1, titles.count))
            for index in 0..<titles.count {
                newSegments.append(CGRect(x: each * CGFloat(index), y: 0, width: each, height: height))
            }
        } else {
            var x: CGFloat = 0
            for index in 0..<titles.count {
                let width = widths[index] + TabStripView.scrollPadding
                newSegments.append(CGRect(x: x, y: 0, width: width, height: height))
                x += width
            }
            contentWidth = max(bounds.width, x)
        }
        let indicatorY = height - Metrics.hairline - TabStripView.indicatorHeight
        for (index, segment) in newSegments.enumerated() {
            let textWidth = widths[index]
            newIndicators.append(CGRect(x: segment.midX - textWidth / 2, y: indicatorY,
                                        width: textWidth, height: TabStripView.indicatorHeight))
        }
        segments = newSegments
        indicatorRects = newIndicators
        scrollView.contentSize = CGSize(width: contentWidth, height: height)
        for (index, label) in labels.enumerated() where index < segments.count {
            label.frame = segments[index]
        }
        if selection < indicatorRects.count {
            indicator.frame = indicatorRects[selection]
        }
    }

    private func select(_ index: Int, animated: Bool) {
        guard !titles.isEmpty else {
            selection = 0
            return
        }
        selection = min(max(index, 0), titles.count - 1)
        updateColors()
        scrollSelectionIntoView(animated: animated)
        moveIndicator(animated: animated)
    }

    private func moveIndicator(animated: Bool) {
        guard selection < indicatorRects.count else { return }
        let target = indicatorRects[selection]
        if animated {
            UIView.animate(withDuration: 0.2) {
                self.indicator.frame = target
            }
        } else {
            indicator.frame = target
        }
    }

    /// Only the `scroll` style scrolls; the title keeps a 16 pt margin when it is brought into view.
    private func scrollSelectionIntoView(animated: Bool) {
        guard style == .scroll, selection < segments.count else { return }
        let target = segments[selection].insetBy(dx: -16, dy: 0)
        scrollView.scrollRectToVisible(target, animated: animated)
    }

    private func rebuildLabels() {
        for label in labels {
            label.removeFromSuperview()
        }
        labels = []
        for title in titles {
            let label = UILabel()
            label.text = title
            label.textAlignment = .center
            label.numberOfLines = 1
            scrollView.addSubview(label)
            labels.append(label)
        }
    }

    /// The selected title is bold and dark, the others medium and secondary.
    private func updateColors() {
        let palette = Theme.palette
        backgroundColor = palette.background
        hairline.backgroundColor = palette.separator
        indicator.backgroundColor = palette.accent
        for (index, label) in labels.enumerated() {
            let selected = index == selection
            label.font = Theme.font(15, selected ? .bold : .medium)
            label.textColor = selected ? palette.text : palette.secondaryText
        }
    }

    /// Width of every title in the bold face, rounded up.
    private func titleWidths() -> [CGFloat] {
        let font = Theme.font(15, .bold)
        return titles.map { title in
            ceil(NSString(string: title).size(withAttributes: [NSAttributedString.Key.font: font]).width)
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: scrollView)
        guard let index = segments.firstIndex(where: { $0.contains(point) }) else { return }
        select(index, animated: true)
        onSelect?(index)
    }
}
