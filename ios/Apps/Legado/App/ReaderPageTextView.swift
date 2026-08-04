import AppUseCases
import SwiftUI
import UIKit

struct ReaderPageTextView: UIViewRepresentable {
    let text: String
    let attachments: [ReaderImageAttachmentLayout]
    let images: [String: UIImage]
    let imageSources: [Int: String]
    let fontSize: Double
    let lineSpacing: Double

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.isScrollEnabled = false
        view.isSelectable = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityIdentifier = "text.reader.content"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let value = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize),
                .paragraphStyle: paragraph,
                .foregroundColor: UIColor.label,
            ]
        )
        for attachmentLayout in attachments.sorted(
            by: { $0.layoutCharacterOffset > $1.layoutCharacterOffset }
        ) {
            let offset = attachmentLayout.layoutCharacterOffset
            guard offset >= 0, offset < (text as NSString).length else {
                continue
            }
            let attachment = NSTextAttachment()
            attachment.bounds = CGRect(
                x: attachmentLayout.size.horizontalInset,
                y: 0,
                width: attachmentLayout.size.width,
                height: attachmentLayout.size.height
            )
            if let source = imageSources[offset] {
                attachment.image = images[source]
            }
            value.replaceCharacters(
                in: NSRange(location: offset, length: 1),
                with: NSAttributedString(attachment: attachment)
            )
        }
        view.attributedText = value
        view.accessibilityLabel = text
            .replacingOccurrences(of: "\u{fffc}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        view.accessibilityValue = attachments.isEmpty
            ? nil : "当前页含 \(attachments.count) 张插图"
    }
}

struct ReaderScrollableTextView: UIViewRepresentable {
    let text: String
    let attachments: [ReaderImageAttachmentLayout]
    let images: [String: UIImage]
    let imageSources: [Int: String]
    let fontSize: Double
    let lineSpacing: Double
    let initialCharacterOffset: Int
    let identity: String
    let offsetChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(offsetChanged: offsetChanged)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.isScrollEnabled = true
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "text.reader.content"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.offsetChanged = offsetChanged
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let value = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize),
                .paragraphStyle: paragraph,
                .foregroundColor: UIColor.label,
            ]
        )
        for attachmentLayout in attachments.sorted(
            by: { $0.layoutCharacterOffset > $1.layoutCharacterOffset }
        ) {
            let offset = attachmentLayout.layoutCharacterOffset
            guard offset >= 0, offset < (text as NSString).length else {
                continue
            }
            let attachment = NSTextAttachment()
            attachment.bounds = CGRect(
                x: attachmentLayout.size.horizontalInset,
                y: 0,
                width: attachmentLayout.size.width,
                height: attachmentLayout.size.height
            )
            if let source = imageSources[offset] {
                attachment.image = images[source]
            }
            value.replaceCharacters(
                in: NSRange(location: offset, length: 1),
                with: NSAttributedString(attachment: attachment)
            )
        }
        if view.attributedText != value {
            view.attributedText = value
        }
        view.accessibilityLabel = text
            .replacingOccurrences(of: "\u{fffc}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let restoreKey = "\(identity):\(initialCharacterOffset):"
            + "\(fontSize):\(lineSpacing):\(attachments.count)"
        guard context.coordinator.restoreKey != restoreKey else { return }
        context.coordinator.restoreKey = restoreKey
        context.coordinator.isRestoring = true
        let offset = min(
            max(0, initialCharacterOffset),
            max(0, view.textStorage.length - 1)
        )
        view.layoutManager.ensureLayout(for: view.textContainer)
        let glyph = view.layoutManager.glyphIndexForCharacter(at: offset)
        let rect = view.layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: view.textContainer
        )
        view.setContentOffset(
            CGPoint(x: 0, y: max(0, rect.minY - view.adjustedContentInset.top)),
            animated: false
        )
        context.coordinator.isRestoring = false
        offsetChanged(offset)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var offsetChanged: (Int) -> Void
        var restoreKey: String?
        var isRestoring = false

        init(offsetChanged: @escaping (Int) -> Void) {
            self.offsetChanged = offsetChanged
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard
                !isRestoring,
                let view = scrollView as? UITextView,
                view.textStorage.length > 0
            else { return }
            let point = CGPoint(
                x: view.textContainerInset.left,
                y: max(0, view.contentOffset.y)
                    + view.textContainerInset.top
            )
            let glyph = view.layoutManager.glyphIndex(
                for: point,
                in: view.textContainer,
                fractionOfDistanceThroughGlyph: nil
            )
            let character = view.layoutManager.characterIndexForGlyph(
                at: glyph
            )
            offsetChanged(min(character, view.textStorage.length))
        }
    }
}
