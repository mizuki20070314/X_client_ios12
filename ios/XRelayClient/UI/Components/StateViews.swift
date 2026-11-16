import UIKit

/// A spinner in the middle of its bounds, for a first load (ui-spec §3.11).
final class LoadingView: UIView {
    private let indicator = LoadingView.makeIndicator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setUp()
    }

    private func setUp() {
        backgroundColor = UIColor.clear
        indicator.color = Theme.palette.secondaryText
        addSubview(indicator)
        indicator.startAnimating()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        indicator.sizeToFit()
        indicator.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// The style of iOS 13 and later is `.medium`; iOS 12 has only `.gray`.
    private static func makeIndicator() -> UIActivityIndicatorView {
        if #available(iOS 13.0, *) {
            return UIActivityIndicatorView(style: .medium)
        }
        return UIActivityIndicatorView(style: .gray)
    }
}

/// A centred message for an empty, failed or blocked state: a title, an optional detail and an optional pill button
/// (ui-spec §3.11). The text is limited to the width minus 32 pt on each side.
final class MessageView: UIView {
    private static let buttonHeight: CGFloat = 36
    private static let titleDetailGap: CGFloat = 8
    private static let detailButtonGap: CGFloat = 20

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let button = UIButton(type: .custom)
    private let action: (() -> Void)?
    private let buttonWidth: CGFloat

    init(title: String, detail: String?, buttonTitle: String?, action: (() -> Void)?) {
        self.action = action
        let palette = Theme.palette
        let buttonFont = Theme.font(14, .bold)
        let buttonLabelWidth = NSString(string: buttonTitle ?? "")
            .size(withAttributes: [NSAttributedString.Key.font: buttonFont]).width
        buttonWidth = max(96, ceil(buttonLabelWidth) + 40)
        super.init(frame: .zero)
        backgroundColor = UIColor.clear

        titleLabel.text = title
        titleLabel.font = Theme.font(20, .bold)
        titleLabel.textColor = palette.text
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        addSubview(titleLabel)

        detailLabel.text = detail
        detailLabel.font = Theme.font(15)
        detailLabel.textColor = palette.secondaryText
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        detailLabel.isHidden = detail == nil
        addSubview(detailLabel)

        button.setTitle(buttonTitle, for: .normal)
        button.titleLabel?.font = buttonFont
        button.setTitleColor(UIColor.white, for: .normal)
        button.backgroundColor = palette.accent
        button.layer.cornerRadius = MessageView.buttonHeight / 2
        button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
        button.isHidden = buttonTitle == nil
        addSubview(button)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let maxWidth = max(0, bounds.width - 64)
        let titleSize = fitted(titleLabel, maxWidth: maxWidth)
        let detailShown = !detailLabel.isHidden
        let detailSize = detailShown ? fitted(detailLabel, maxWidth: maxWidth) : CGSize.zero
        let buttonShown = !button.isHidden

        // the block (title, detail, button) is centred vertically
        var total = titleSize.height
        if detailShown {
            total += MessageView.titleDetailGap + detailSize.height
        }
        if buttonShown {
            total += MessageView.detailButtonGap + MessageView.buttonHeight
        }
        var y = (bounds.height - total) / 2
        titleLabel.frame = CGRect(x: (bounds.width - titleSize.width) / 2, y: y,
                                  width: titleSize.width, height: titleSize.height)
        y += titleSize.height
        if detailShown {
            y += MessageView.titleDetailGap
            detailLabel.frame = CGRect(x: (bounds.width - detailSize.width) / 2, y: y,
                                       width: detailSize.width, height: detailSize.height)
            y += detailSize.height
        }
        if buttonShown {
            y += MessageView.detailButtonGap
            button.frame = CGRect(x: (bounds.width - buttonWidth) / 2, y: y,
                                  width: buttonWidth, height: MessageView.buttonHeight)
        }
    }

    /// A label's size for `maxWidth`, rounded up; the width never exceeds `maxWidth`.
    private func fitted(_ label: UILabel, maxWidth: CGFloat) -> CGSize {
        let size = label.sizeThatFits(CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: min(ceil(size.width), maxWidth), height: ceil(size.height))
    }

    @objc private func buttonTapped() {
        action?()
    }
}
