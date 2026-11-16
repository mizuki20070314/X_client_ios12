import UIKit

/// Measured, drawable and hit-testable text (TextKit 1, ui-spec §3.4). One text storage, layout manager and text
/// container per layout. The same object measures and draws, so the heights the rows use are the heights drawn.
final class TextLayout {
    /// The used rect of the text, rounded up to whole points.
    let size: CGSize
    /// True when `maxLines` cut off the end of the text.
    let isTruncated: Bool

    private let textStorage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let textContainer: NSTextContainer
    private let textLength: Int
    private let entities: [TextEntity]

    init(_ text: NSAttributedString, width: CGFloat, maxLines: Int = 0, entities: [TextEntity] = []) {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        // a width of 0 would put one character on each line
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = max(0, maxLines)
        if maxLines > 0 {
            container.lineBreakMode = .byTruncatingTail
        }
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)

        let used = manager.usedRect(for: container)
        size = CGSize(width: ceil(used.width), height: ceil(used.height))
        // compare characters, not glyphs: the glyphs after a cut are generated lazily, so their count is not reliable
        let laidOut = manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil)
        isTruncated = NSMaxRange(laidOut) < storage.length

        textStorage = storage
        layoutManager = manager
        textContainer = container
        textLength = storage.length
        // entity ranges come from the server: an out-of-range one is dropped instead of crashing
        self.entities = entities.filter { entity in
            entity.range.location >= 0 && NSMaxRange(entity.range) <= storage.length
        }
    }

    /// Draws the text with its top left corner at `origin` in the current graphics context.
    func draw(at origin: CGPoint) {
        let glyphs = layoutManager.glyphRange(for: textContainer)
        layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }

    /// The entity whose glyphs lie under `point` (layout coordinates, the same as `draw(at:)` with origin zero).
    func entity(at point: CGPoint) -> TextEntity? {
        guard let index = entityIndex(at: point) else { return nil }
        return entities[index]
    }

    /// The rects that cover `range`, one per line, in layout coordinates.
    func rects(for range: NSRange) -> [CGRect] {
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= textLength else { return [] }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [CGRect] = []
        var glyph = glyphs.location
        let end = NSMaxRange(glyphs)
        while glyph < end {
            var line = NSRange(location: 0, length: 0)
            _ = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &line)
            let part = NSIntersectionRange(line, glyphs)
            guard part.length > 0 else { break }
            rects.append(layoutManager.boundingRect(forGlyphRange: part, in: textContainer))
            glyph = NSMaxRange(line)
        }
        return rects
    }

    /// Index into `entities` of the entity under `point`, or nil.
    private func entityIndex(at point: CGPoint) -> Int? {
        guard textLength > 0, !entities.isEmpty else { return nil }
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        // the nearest glyph comes back even far from the text, so the point must lie on that glyph itself
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                                   in: textContainer)
        guard glyphRect.contains(point) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return entities.firstIndex(where: { NSLocationInRange(character, $0.range) })
    }
}

/// A label that draws a TextLayout. Only the entities take touches: `hitTest` returns nil elsewhere, so a tap on
/// plain text falls through to the row behind (ui-spec §3.4).
final class LinkLabel: UIView {
    var textLayout: TextLayout? {
        didSet {
            pressedEntity = nil
            setNeedsDisplay()
        }
    }
    var onTapEntity: ((TextEntity) -> Void)?

    private var pressedEntity: TextEntity?
    /// True while the touch sequence that is running began on an entity. Such a sequence belongs to the label alone
    /// and is not passed on to the row: tapping a mention must not also open the post.
    private var ownsTouches = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setUp()
    }

    private func setUp() {
        isOpaque = false
        backgroundColor = UIColor.clear
        contentMode = .redraw
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point), let layout = textLayout, layout.entity(at: point) != nil else { return nil }
        return self
    }

    override func draw(_ rect: CGRect) {
        guard let layout = textLayout else { return }
        // a pressed entity is marked with a light accent behind its glyphs
        if let entity = pressedEntity {
            Theme.palette.accent.withAlphaComponent(0.15).setFill()
            for part in layout.rects(for: entity.range) {
                UIBezierPath(roundedRect: part, cornerRadius: 3).fill()
            }
        }
        layout.draw(at: CGPoint.zero)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let layout = textLayout,
              let entity = layout.entity(at: touch.location(in: self)) else {
            // not on an entity: the touch goes on to the row behind, as if the label were not there
            ownsTouches = false
            super.touchesBegan(touches, with: event)
            return
        }
        ownsTouches = true
        pressedEntity = entity
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard ownsTouches else {
            super.touchesMoved(touches, with: event)
            return
        }
        guard let touch = touches.first, let layout = textLayout, let pressed = pressedEntity else { return }
        // the mark goes away once the finger leaves the entity: lifting it there is no tap
        let current = layout.entity(at: touch.location(in: self))
        if !LinkLabel.isSame(current, pressed) {
            pressedEntity = nil
            setNeedsDisplay()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard ownsTouches else {
            super.touchesEnded(touches, with: event)
            return
        }
        ownsTouches = false
        let pressed = pressedEntity
        pressedEntity = nil
        setNeedsDisplay()
        guard let touch = touches.first, let layout = textLayout, let target = pressed else { return }
        let hit = layout.entity(at: touch.location(in: self))
        if LinkLabel.isSame(hit, target), let entity = hit {
            onTapEntity?(entity)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard ownsTouches else {
            super.touchesCancelled(touches, with: event)
            return
        }
        ownsTouches = false
        pressedEntity = nil
        setNeedsDisplay()
    }

    private static func isSame(_ entity: TextEntity?, _ other: TextEntity) -> Bool {
        guard let entity = entity else { return false }
        return entity.range == other.range && entity.kind == other.kind
    }
}

enum TweetText {
    /// The text with its entities drawn in the link colour. Entity ranges are UTF-16 and are checked against the
    /// length of the text; a bad range is skipped. The link colour is `.foregroundColor`: `.link` would let UIKit
    /// style the text on its own.
    static func attributed(_ text: String, entities: [TextEntity], font: UIFont, color: UIColor,
                           linkColor: UIColor, lineSpacing: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key.font: font,
            NSAttributedString.Key.foregroundColor: color,
            NSAttributedString.Key.paragraphStyle: paragraph,
        ]
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        let length = NSString(string: text).length
        for entity in entities {
            let range = entity.range
            guard range.location >= 0, range.length > 0, NSMaxRange(range) <= length else { continue }
            result.addAttribute(NSAttributedString.Key.foregroundColor, value: linkColor, range: range)
        }
        return result
    }
}
