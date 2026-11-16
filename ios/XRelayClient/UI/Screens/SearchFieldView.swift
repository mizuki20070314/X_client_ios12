import UIKit

/// The search pill of the search screens: a 36 pt field with a search icon, used as the centre view of the top bar.
final class SearchFieldView: UIView, UITextFieldDelegate {
    /// Called with the text when the user presses the search key.
    var onSubmit: ((String) -> Void)?

    var text: String {
        get { return textField.text ?? "" }
        set { textField.text = newValue }
    }

    private let iconView = UIImageView()
    private let textField = UITextField()
    private static let pillHeight: CGFloat = 36

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setUp()
    }

    private func setUp() {
        let palette = Theme.palette
        backgroundColor = palette.surface
        layer.cornerRadius = SearchFieldView.pillHeight / 2
        clipsToBounds = true

        iconView.image = Icons.image(.search, size: 16).withRenderingMode(.alwaysTemplate)
        iconView.tintColor = palette.secondaryText
        iconView.contentMode = .center
        addSubview(iconView)

        textField.font = Theme.font(15)
        textField.textColor = palette.text
        textField.placeholder = "検索"
        textField.returnKeyType = .search
        textField.clearButtonMode = .whileEditing
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.delegate = self
        addSubview(textField)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The field is centred vertically in whatever height the top bar gives it.
        let iconSide: CGFloat = 16
        iconView.frame = CGRect(x: 12, y: (bounds.height - iconSide) / 2, width: iconSide, height: iconSide)
        let fieldX: CGFloat = 12 + iconSide + 8
        let fieldHeight: CGFloat = 22
        textField.frame = CGRect(x: fieldX,
                                 y: (bounds.height - fieldHeight) / 2,
                                 width: max(0, bounds.width - fieldX - 12),
                                 height: fieldHeight)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let query = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        textField.resignFirstResponder()
        if !query.isEmpty {
            onSubmit?(query)
        }
        return true
    }
}
