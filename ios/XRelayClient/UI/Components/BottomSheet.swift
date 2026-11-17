import UIKit

/// One row of a bottom sheet (ui-spec §3.3).
struct BottomSheetItem {
    enum Style {
        case normal, destructive
    }

    let icon: IconName?
    let title: String
    var style: Style = .normal
    /// Shows a check mark at the right: the current choice of a list.
    var isChecked: Bool = false
    let handler: () -> Void
}

/// The Android-style bottom sheet that replaces the iOS action sheet (ui-spec §3.3).
enum BottomSheet {
    /// Shows the sheet over `presenter` (the top-most controller when it is nil). Tapping a row closes the sheet and
    /// then runs its handler.
    static func present(from presenter: UIViewController?, title: String? = nil, items: [BottomSheetItem]) {
        guard let base = presenter ?? Router.topViewController else { return }
        var top = base
        while let presented = top.presentedViewController {
            top = presented
        }
        top.present(BottomSheetViewController(title: title, items: items), animated: false, completion: nil)
    }
}

/// A row of the sheet: its icon, title and check mark are its subviews, the touch target is the row itself.
private final class SheetRowControl: UIControl {
    let index: Int
    let iconView: UIImageView?
    let titleLabel = UILabel()
    let checkView: UIImageView?

    init(index: Int, iconView: UIImageView?, checkView: UIImageView?) {
        self.index = index
        self.iconView = iconView
        self.checkView = checkView
        super.init(frame: .zero)
        if let iconView = iconView {
            addSubview(iconView)
        }
        addSubview(titleLabel)
        if let checkView = checkView {
            addSubview(checkView)
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Pressed rows show the highlight colour while the finger is on them.
    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? Theme.palette.highlight : UIColor.clear
        }
    }
}

/// The sheet itself: a controller over the whole screen, with a dimming view and the sheet at the bottom. It slides in
/// when it appears and out when it closes; the exit animation runs before the (unanimated) dismissal.
private final class BottomSheetViewController: UIViewController {
    private static let grabberZone: CGFloat = 20
    private static let titleHeight: CGFloat = 44
    private static let rowHeight: CGFloat = 52
    private static let bottomGap: CGFloat = 8
    /// The Material maximum width of a sheet; on a large screen the sheet is centred at this width (ui-spec §8.3).
    private static let maxWidth: CGFloat = 640

    private let sheetTitle: String?
    private let items: [BottomSheetItem]
    private let dimView = UIView()
    private let sheetView = UIView()
    private let grabber = UIView()
    private let titleLabel = UILabel()
    private var rows: [SheetRowControl] = []
    /// 0 when the sheet is below the screen, 1 when it is shown; the dimming follows it.
    private var progress: CGFloat = 0
    private var isDismissing = false

    init(title: String?, items: [BottomSheetItem]) {
        sheetTitle = title
        self.items = items
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return Theme.statusBarStyle
    }

    /// Every orientation on an iPad (ui-spec §8.1): the sheet rotates with the screen under it.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = Theme.palette
        view.backgroundColor = UIColor.clear

        dimView.backgroundColor = palette.overlay
        dimView.alpha = 0
        view.addSubview(dimView)
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimTapped)))

        sheetView.backgroundColor = palette.background
        sheetView.clipsToBounds = true
        sheetView.layer.cornerRadius = 16
        sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.addSubview(sheetView)
        sheetView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(sheetPanned(_:))))

        grabber.backgroundColor = palette.border
        grabber.layer.cornerRadius = 2
        sheetView.addSubview(grabber)

        titleLabel.text = sheetTitle
        titleLabel.font = Theme.font(15, .bold)
        titleLabel.textColor = palette.text
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        // a long title shrinks to 80 % before it is truncated
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.8
        titleLabel.isHidden = sheetTitle == nil
        sheetView.addSubview(titleLabel)

        for (index, item) in items.enumerated() {
            let row = makeRow(item, index: index, palette: palette)
            sheetView.addSubview(row)
            rows.append(row)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutSheet()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIView.animate(withDuration: 0.25) {
            self.progress = 1
            self.layoutSheet()
        }
    }

    private func makeRow(_ item: BottomSheetItem, index: Int, palette: Palette) -> SheetRowControl {
        let color = item.style == .destructive ? palette.danger : palette.text
        var iconView: UIImageView?
        if let icon = item.icon {
            let iconImage = UIImageView(image: Icons.image(icon, size: 22))
            iconImage.tintColor = color
            iconView = iconImage
        }
        var checkView: UIImageView?
        if item.isChecked {
            let checkImage = UIImageView(image: Icons.image(.check, size: 22))
            checkImage.tintColor = palette.accent
            checkView = checkImage
        }
        let row = SheetRowControl(index: index, iconView: iconView, checkView: checkView)
        row.titleLabel.text = item.title
        row.titleLabel.font = Theme.font(16)
        row.titleLabel.textColor = color
        row.titleLabel.numberOfLines = 1
        row.titleLabel.lineBreakMode = .byTruncatingTail
        // a long row title shrinks to 80 % first, and only then is truncated at the tail
        row.titleLabel.adjustsFontSizeToFitWidth = true
        row.titleLabel.minimumScaleFactor = 0.8
        row.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
        return row
    }

    /// Places the sheet for its progress: the bottom of the screen at 0, the shown position at 1. The sheet is at most
    /// 640 pt wide and centred, so on a phone it is the full width as before.
    private func layoutSheet() {
        let screenWidth = view.bounds.width
        let width = min(screenWidth, BottomSheetViewController.maxWidth)
        let originX = ((screenWidth - width) / 2).rounded(.down)
        let titleHeight = sheetTitle == nil ? CGFloat(0) : BottomSheetViewController.titleHeight
        let rowsHeight = CGFloat(items.count) * BottomSheetViewController.rowHeight
        let chromeHeight = BottomSheetViewController.grabberZone + BottomSheetViewController.bottomGap
        let bottomInset = view.safeAreaInsets.bottom
        let height = chromeHeight + titleHeight + rowsHeight + bottomInset

        dimView.frame = view.bounds
        dimView.alpha = progress
        sheetView.frame = CGRect(x: originX, y: view.bounds.height - height * progress, width: width, height: height)

        grabber.frame = CGRect(x: (width - 36) / 2, y: 8, width: 36, height: 4)
        let pad = Metrics.pad(width)
        titleLabel.frame = CGRect(x: pad, y: BottomSheetViewController.grabberZone, width: max(0, width - 2 * pad),
                                  height: titleHeight)

        let rowTop = BottomSheetViewController.grabberZone + titleHeight
        for row in rows where row.index < items.count {
            layoutRow(row, item: items[row.index], top: rowTop + CGFloat(row.index) * BottomSheetViewController.rowHeight,
                      width: width)
        }
    }

    private func layoutRow(_ row: SheetRowControl, item: BottomSheetItem, top: CGFloat, width: CGFloat) {
        row.frame = CGRect(x: 0, y: top, width: width, height: BottomSheetViewController.rowHeight)
        // the icon is at x = 20; the title at 60, or at 20 when there is no icon
        let titleX: CGFloat = item.icon == nil ? 20 : 60
        let checkSpace: CGFloat = item.isChecked ? 34 : 0
        row.iconView?.frame = CGRect(x: 20, y: 15, width: 22, height: 22)
        row.titleLabel.frame = CGRect(x: titleX, y: 0, width: max(0, width - titleX - 20 - checkSpace),
                                      height: BottomSheetViewController.rowHeight)
        row.checkView?.frame = CGRect(x: width - 20 - 22, y: 15, width: 22, height: 22)
    }

    /// Slides the sheet down and fades the dimming, then dismisses without animation and runs `handler`.
    private func dismissSheet(then handler: (() -> Void)?) {
        guard !isDismissing else { return }
        isDismissing = true
        UIView.animate(withDuration: 0.25, animations: {
            self.progress = 0
            self.layoutSheet()
        }, completion: { _ in
            self.dismiss(animated: false, completion: handler)
        })
    }

    @objc private func rowTapped(_ sender: UIControl) {
        guard let row = sender as? SheetRowControl, row.index < items.count else { return }
        dismissSheet(then: items[row.index].handler)
    }

    @objc private func dimTapped() {
        dismissSheet(then: nil)
    }

    /// Dragging the sheet down follows the finger; past 30 % of its height, or on a fast flick, it closes.
    @objc private func sheetPanned(_ recognizer: UIPanGestureRecognizer) {
        let sheetHeight = max(1, sheetView.bounds.height)
        switch recognizer.state {
        case .changed:
            let dragged = max(0, recognizer.translation(in: view).y)
            progress = max(0, min(1, 1 - dragged / sheetHeight))
            layoutSheet()
        case .ended, .cancelled:
            let velocity = recognizer.velocity(in: view).y
            if progress < 0.7 || velocity > 500 {
                dismissSheet(then: nil)
            } else {
                UIView.animate(withDuration: 0.2, animations: {
                    self.progress = 1
                    self.layoutSheet()
                })
            }
        default:
            break
        }
    }
}
