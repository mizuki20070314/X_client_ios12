import UIKit

/// Debug screen (route step `icons`): every icon at 24 pt with its name, on the current theme,
/// plus the action-row icons in their colours. The visual check of the icon set.
final class IconGalleryViewController: UIViewController {
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .custom)
    private let scrollView = UIScrollView()
    private let divider = UIView()
    private var actionIcons: [UIImageView] = []
    private var iconViews: [UIImageView] = []
    private var nameLabels: [UILabel] = []

    private let columns = 3
    private let barHeight: CGFloat = 44
    private let actionRowHeight: CGFloat = 50
    private let cellHeight: CGFloat = 84

    // The screen is always shown full screen. (UIView keeps init() through init(frame:); a view controller
    // needs its own, and it is not an override.)
    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("IconGalleryViewController is only created in code")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return Theme.statusBarStyle
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = Theme.palette
        view.backgroundColor = palette.background

        titleLabel.text = "アイコン一覧"
        titleLabel.font = Theme.font(17, .semibold)
        titleLabel.textColor = palette.text
        titleLabel.textAlignment = .center
        view.addSubview(titleLabel)

        closeButton.setImage(Icons.image(.close, size: 24), for: .normal)
        closeButton.tintColor = palette.text
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        // Insets are set by hand in viewDidLayoutSubviews.
        if #available(iOS 11.0, *) {
            scrollView.contentInsetAdjustmentBehavior = .never
        }
        view.addSubview(scrollView)

        // First row: the action-row icons in the colours they have under a post.
        let actions: [(IconName, UIColor)] = [
            (.reply, palette.secondaryText),
            (.repost, palette.repost),
            (.heartFill, palette.like),
            (.views, palette.secondaryText),
            (.bookmarkFill, palette.accent),
            (.share, palette.secondaryText),
        ]
        for (name, color) in actions {
            let icon = UIImageView(image: Icons.image(name, size: 18))
            icon.tintColor = color
            scrollView.addSubview(icon)
            actionIcons.append(icon)
        }
        divider.backgroundColor = palette.separator
        scrollView.addSubview(divider)

        for name in IconName.allCases {
            let icon = UIImageView(image: Icons.image(name, size: 24))
            icon.tintColor = palette.text
            let label = UILabel()
            label.text = name.rawValue
            label.font = Theme.font(10)
            label.textColor = palette.secondaryText
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingTail
            scrollView.addSubview(icon)
            scrollView.addSubview(label)
            iconViews.append(icon)
            nameLabels.append(label)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let insets = view.safeAreaInsets
        let width = view.bounds.width
        let top = insets.top

        titleLabel.frame = CGRect(x: 0, y: top, width: width, height: barHeight)
        closeButton.frame = CGRect(x: insets.left + 4, y: top, width: barHeight, height: barHeight)

        let contentTop = top + barHeight
        scrollView.frame = CGRect(x: 0, y: contentTop, width: width,
                                  height: view.bounds.height - contentTop)
        scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: insets.bottom + 8, right: 0)

        // Action row: the six icons share the width evenly.
        let slot = width / CGFloat(actionIcons.count)
        for (index, icon) in actionIcons.enumerated() {
            let x = slot * CGFloat(index) + (slot - 18) / 2
            icon.frame = CGRect(x: x, y: 16, width: 18, height: 18)
        }
        divider.frame = CGRect(x: 0, y: actionRowHeight, width: width, height: 1 / UIScreen.main.scale)

        // Grid: three columns, each an icon above its name.
        let cellWidth = width / CGFloat(columns)
        let gridTop = actionRowHeight + 1
        for (index, icon) in iconViews.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = CGFloat(column) * cellWidth
            let y = gridTop + CGFloat(row) * cellHeight
            icon.frame = CGRect(x: x + (cellWidth - 24) / 2, y: y + 14, width: 24, height: 24)
            nameLabels[index].frame = CGRect(x: x + 4, y: y + 46, width: cellWidth - 8, height: 14)
        }
        let rows = (iconViews.count + columns - 1) / columns
        scrollView.contentSize = CGSize(width: width, height: gridTop + CGFloat(rows) * cellHeight)
    }

    @objc private func closeTapped() {
        dismiss(animated: true, completion: nil)
    }
}
