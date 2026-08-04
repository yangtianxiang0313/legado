import BackupInteropUseCases
import UniformTypeIdentifiers
import UIKit

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.text = "正在交给 Legado…"
        statusLabel.textAlignment = .center
        statusLabel.textColor = .secondaryLabel
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: 24
            ),
        ])
        importFirstAttachment()
    }

    private func importFirstAttachment() {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []
        guard let provider = providers.first else {
            finish(message: "没有可导入的内容")
            return
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { [weak self] value, _ in
                guard let url = value as? URL else {
                    self?.finish(message: "无法读取分享文件")
                    return
                }
                self?.storeFile(at: url, suggestedName: provider.suggestedName)
            }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(
                forTypeIdentifier: UTType.url.identifier,
                options: nil
            ) { [weak self] value, _ in
                guard let url = value as? URL else {
                    self?.finish(message: "无法读取分享链接")
                    return
                }
                self?.store(
                    AndroidSharePayload(
                        kind: .url,
                        data: Data(url.absoluteString.utf8)
                    )
                )
            }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            provider.loadItem(
                forTypeIdentifier: UTType.text.identifier,
                options: nil
            ) { [weak self] value, _ in
                guard let text = value as? String else {
                    self?.finish(message: "无法读取分享文本")
                    return
                }
                self?.store(
                    AndroidSharePayload(kind: .text, data: Data(text.utf8))
                )
            }
            return
        }
        loadData(from: provider)
    }

    private func loadData(from provider: NSItemProvider) {
        guard let typeIdentifier = provider.registeredTypeIdentifiers.first else {
            finish(message: "不支持此分享内容")
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) {
            [weak self] data, _ in
            guard let data else {
                self?.finish(message: "无法读取分享文件")
                return
            }
            self?.store(AndroidSharePayload(
                kind: .file,
                data: data,
                suggestedName: provider.suggestedName
            ))
        }
    }

    private func storeFile(at url: URL, suggestedName: String?) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= AndroidShareInbox.maximumPayloadBytes
            else {
                finish(message: "分享文件超过 32 MB")
                return
            }
            store(AndroidSharePayload(
                kind: .file,
                data: try Data(contentsOf: url, options: [.mappedIfSafe]),
                suggestedName: suggestedName ?? url.lastPathComponent
            ))
        } catch {
            finish(message: "无法读取分享文件")
        }
    }

    private func store(_ payload: AndroidSharePayload) {
        do {
            let inbox = try AndroidShareInbox.applicationGroup()
            let token = try inbox.store(payload)
            let url = try AndroidShareInbox.openURL(token: token)
            extensionContext?.open(url) { [weak self] opened in
                // Share extensions are not always allowed to activate their
                // containing app. The inbox remains discoverable on next launch.
                _ = opened
                self?.extensionContext?.completeRequest(returningItems: [])
            }
        } catch AndroidShareInboxError.payloadTooLarge {
            finish(message: "分享内容超过 32 MB")
        } catch {
            finish(message: "无法暂存分享内容")
        }
    }

    private func finish(message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = message
            self?.extensionContext?.cancelRequest(
                withError: NSError(
                    domain: "LegadoShareExtension",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            )
        }
    }
}
