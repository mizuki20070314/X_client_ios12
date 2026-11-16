import UIKit

/// A link card of a post (ui-spec §3.8): a large image, a summary box, or a poll. A tap on a link card opens its URL.
/// A poll, or a card without a link, takes no touches, so a tap there opens the post.
final class CardView: UIControl {
    private enum Mode {
        case image, summary, poll
    }

    private var linkURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Builds the card for `width`. Its height is `height(card:width:)`.
    func configure(card: Card, width: CGFloat) {
        subviews.forEach { $0.removeFromSuperview() }
        linkURL = card.url
        let mode = CardView.mode(of: card)
        switch mode {
        case .image:
            buildImage(card, width: width)
        case .summary:
            buildSummary(card, width: width)
        case .poll:
            buildPoll(card, width: width)
        }
        isUserInteractionEnabled = mode != .poll && linkURL != nil
    }

    /// The height of the card at `width`: the image (round(width / 1.91)) with its domain line, the 88 pt summary
    /// box, or the poll rows with the footer.
    static func height(card: Card, width: CGFloat) -> CGFloat {
        switch mode(of: card) {
        case .image:
            return imageHeight(width) + 4 + 18
        case .summary:
            return 88
        case .poll:
            let rows = CGFloat(card.poll?.choices.count ?? 0)
            return rows * 36 + 20
        }
    }

    @objc private func tapped() {
        guard let url = linkURL else { return }
        Router.openURL(url)
    }

    private static func mode(of card: Card) -> Mode {
        if card.kind == .poll, card.poll != nil {
            return .poll
        }
        if card.kind == .large || card.kind == .player, card.imageURL != nil {
            return .image
        }
        return .summary
    }

    private static func imageHeight(_ width: CGFloat) -> CGFloat {
        return (width / 1.91).rounded()
    }

    // MARK: - image

    private func buildImage(_ card: Card, width: CGFloat) {
        let palette = Theme.palette
        let height = CardView.imageHeight(width)
        let image = RemoteImageView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        image.backgroundColor = palette.surface
        image.layer.cornerRadius = 16
        image.setImage(url: card.imageURL, maxPixel: width * UIScreen.main.scale)
        addSubview(image)

        // the title sits in a pill at the bottom-left of the picture
        if !card.title.isEmpty {
            let pill = MediaOverlayPill(frame: .zero)
            let size = pill.configure(text: card.title, font: Theme.font(13), maxWidth: max(0, width - 24))
            pill.frame = CGRect(x: 12, y: height - 12 - size.height, width: size.width, height: size.height)
            addSubview(pill)
        }
        if card.kind == .player {
            let side: CGFloat = 48
            addSubview(MediaPlayBadge(frame: CGRect(x: (width - side) / 2, y: (height - side) / 2,
                                                    width: side, height: side)))
        }
        let domain = makeLabel(domainLine(card), font: Theme.font(13), color: palette.secondaryText, lines: 1)
        domain.frame = CGRect(x: 0, y: height + 4, width: width, height: 18)
        addSubview(domain)
        addBorder(CGRect(x: 0, y: 0, width: width, height: height), palette: palette)
    }

    // MARK: - summary

    /// The 88 pt box: a square thumbnail, a vertical hairline, and the domain and title.
    private func buildSummary(_ card: Card, width: CGFloat) {
        let palette = Theme.palette
        let side: CGFloat = 88
        let thumb = UIView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        thumb.backgroundColor = palette.surface
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 16
        thumb.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        addSubview(thumb)
        if card.imageURL != nil {
            let image = RemoteImageView(frame: thumb.bounds)
            image.setImage(url: card.imageURL, maxPixel: side * UIScreen.main.scale)
            thumb.addSubview(image)
        } else {
            let icon = UIImageView(image: Icons.image(.link, size: 24))
            icon.tintColor = palette.secondaryText
            icon.frame = CGRect(x: 32, y: 32, width: 24, height: 24)
            thumb.addSubview(icon)
        }

        let divider = UIView(frame: CGRect(x: side, y: 0, width: Metrics.hairline, height: side))
        divider.backgroundColor = palette.border
        addSubview(divider)

        let textX = side + 12
        let textWidth = max(0, width - textX - 12)
        let domain = makeLabel(card.domain, font: Theme.font(13), color: palette.secondaryText, lines: 1)
        domain.frame = CGRect(x: textX, y: 12, width: textWidth, height: 16)
        addSubview(domain)
        let title = makeLabel(card.title, font: Theme.font(15), color: palette.text, lines: 2)
        title.frame = CGRect(x: textX, y: 30, width: textWidth, height: 36)
        addSubview(title)
        addBorder(CGRect(x: 0, y: 0, width: width, height: side), palette: palette)
    }

    // MARK: - poll

    /// One row per choice (32 pt, 4 pt apart), the footer 4 pt below the last row.
    private func buildPoll(_ card: Card, width: CGFloat) {
        guard let poll = card.poll else { return }
        let palette = Theme.palette
        let leader = CardView.leadingIndex(poll.choices)
        let total = max(0, poll.total)
        for (index, choice) in poll.choices.enumerated() {
            let share: CGFloat = total > 0 ? CGFloat(choice.count) / CGFloat(total) : 0
            let isLeader = index == leader
            let row = UIView(frame: CGRect(x: 0, y: CGFloat(index) * 36, width: width, height: 32))
            addSubview(row)

            // the bar is the share of the row, at least 4 pt
            let barWidth = min(width, max(4, (width * share).rounded()))
            let bar = UIView(frame: CGRect(x: 0, y: 0, width: barWidth, height: 32))
            bar.layer.cornerRadius = 4
            bar.backgroundColor = isLeader ? palette.accent.withAlphaComponent(0.3) : palette.surface
            row.addSubview(bar)

            let percent = CardView.percentText(share)
            let shareLabel = makeLabel(percent, font: Theme.font(15), color: palette.text, lines: 1)
            let shareWidth = ceil(shareLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                                 height: 32)).width)
            shareLabel.frame = CGRect(x: width - 12 - shareWidth, y: 0, width: shareWidth, height: 32)
            row.addSubview(shareLabel)

            let labelFont = isLeader ? Theme.font(15, .bold) : Theme.font(15)
            let label = makeLabel(choice.label, font: labelFont, color: palette.text, lines: 1)
            label.frame = CGRect(x: 12, y: 0, width: max(0, width - 32 - shareWidth), height: 32)
            row.addSubview(label)
        }

        let footerY = CGFloat(poll.choices.count) * 36
        let footer = makeLabel(footerText(poll), font: Theme.font(13), color: palette.secondaryText, lines: 1)
        footer.frame = CGRect(x: 0, y: footerY, width: width, height: 20)
        addSubview(footer)
    }

    /// The choice with the most votes; with a tie the first of them.
    private static func leadingIndex(_ choices: [(label: String, count: Int)]) -> Int? {
        var leader: Int?
        var most = Int.min
        for (index, choice) in choices.enumerated() where choice.count > most {
            most = choice.count
            leader = index
        }
        return leader
    }

    private static func percentText(_ share: CGFloat) -> String {
        return String(format: "%.1f%%", Double(share) * 100)
    }

    /// `1,234票 · 最終結果`, or the time left: `残り2日`, `残り3時間`, `残り12分`.
    private func footerText(_ poll: Poll) -> String {
        let votes = Format.count(poll.total) + "票"
        if poll.isFinal {
            return votes + " · 最終結果"
        }
        guard let endsAt = poll.endsAt else {
            return votes
        }
        let remaining = endsAt.timeIntervalSinceNow
        if remaining <= 0 {
            return votes + " · 最終結果"
        }
        if remaining >= 86_400 {
            return votes + " · 残り\(Int(remaining / 86_400))日"
        }
        if remaining >= 3_600 {
            return votes + " · 残り\(Int(remaining / 3_600))時間"
        }
        return votes + " · 残り\(max(1, Int(remaining / 60)))分"
    }

    // MARK: - helpers

    private func domainLine(_ card: Card) -> String {
        return card.domain.isEmpty ? "" : card.domain + " から"
    }

    private func makeLabel(_ text: String, font: UIFont, color: UIColor, lines: Int) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = lines
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    /// The hairline outline, added last so that it lies above the picture.
    private func addBorder(_ frame: CGRect, palette: Palette) {
        let border = UIView(frame: frame)
        border.isUserInteractionEnabled = false
        border.layer.cornerRadius = 16
        border.layer.borderWidth = Metrics.hairline
        border.layer.borderColor = palette.border.cgColor
        addSubview(border)
    }
}
