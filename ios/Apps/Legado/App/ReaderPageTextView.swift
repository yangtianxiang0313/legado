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
        view.accessibilityValue = attachments.isEmpty
            ? nil : "当前页含 \(attachments.count) 张插图"
    }
}
