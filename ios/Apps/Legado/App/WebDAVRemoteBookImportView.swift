import AppUseCases
import IntegrationKit
import SwiftUI

struct WebDAVRemoteBookImportView: View {
    @Bindable var library: ShelfLibrary
    @State private var browser: WebDAVRemoteBookBrowserStore
    @State private var importStatus: String?
    @State private var serverManagementPresented = false
    private let repository: any WebDAVServerProfileRepository
    private let credentialVault: any WebDAVServerCredentialVault
    @Environment(\.dismiss) private var dismiss

    init(
        library: ShelfLibrary,
        repository: any WebDAVServerProfileRepository,
        credentialVault: any WebDAVServerCredentialVault,
        transfer: any WebDAVRemoteBookTransferring
    ) {
        self.library = library
        self.repository = repository
        self.credentialVault = credentialVault
        _browser = State(
            initialValue: WebDAVRemoteBookBrowserStore(
                repository: repository,
                transfer: transfer
            )
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if browser.profiles.count > 1 {
                    Picker(
                        "服务器",
                        selection: Binding(
                            get: { browser.selectedProfileID ?? -1 },
                            set: { id in
                                Task { await browser.selectProfile(id: id) }
                            }
                        )
                    ) {
                        ForEach(browser.profiles, id: \.id) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    .accessibilityIdentifier(
                        "field.webdavRemoteBooks.server"
                    )
                } else if let profile = browser.selectedProfile {
                    LabeledContent("服务器", value: profile.name)
                        .accessibilityIdentifier(
                            "state.webdavRemoteBooks.server"
                        )
                }

                if browser.canNavigateBack {
                    Button {
                        Task { await browser.navigateBack() }
                    } label: {
                        Label("返回上一级", systemImage: "arrow.up")
                    }
                    .accessibilityIdentifier(
                        "action.webdavRemoteBooks.back"
                    )
                }

                ForEach(browser.resources, id: \.url) { resource in
                    Button {
                        Task { await activate(resource) }
                    } label: {
                        HStack {
                            Image(
                                systemName: resource.isDirectory
                                    ? "folder"
                                    : "doc.text"
                            )
                            Text(resource.name)
                            Spacer()
                            if resource.isDirectory {
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .accessibilityIdentifier(
                        resource.isDirectory
                            ? "action.webdavRemoteBooks.directory"
                            : "action.webdavRemoteBooks.file"
                    )
                }

                if let message = importStatus ?? browser.statusMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "state.webdavRemoteBooks.status"
                        )
                }
            }
            .overlay {
                if browser.isLoading {
                    ProgressView()
                        .accessibilityIdentifier(
                            "state.webdavRemoteBooks.loading"
                        )
                }
            }
            .navigationTitle("WebDAV 远程书")
            .accessibilityIdentifier("screen.webdavRemoteBooks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        serverManagementPresented = true
                    } label: {
                        Label("服务器管理", systemImage: "externaldrive.connected.to.line.below")
                    }
                    .accessibilityIdentifier(
                        "action.webdavRemoteBooks.manageServers"
                    )
                }
            }
            .task { await browser.load() }
            .sheet(
                isPresented: $serverManagementPresented,
                onDismiss: { Task { await browser.load() } }
            ) {
                WebDAVServerManagementView(
                    repository: repository,
                    credentialVault: credentialVault
                )
            }
        }
    }

    private func activate(_ resource: WebDAVRemoteBookResource) async {
        if resource.isDirectory {
            await browser.open(resource)
            return
        }
        let lowercasedName = resource.name.lowercased()
        guard lowercasedName.hasSuffix(".txt")
            || lowercasedName.hasSuffix(".epub")
            || lowercasedName.hasSuffix(".zip")
        else {
            importStatus = "当前 iOS 阅读内核支持 TXT、EPUB 和 ZIP"
            return
        }
        guard let download = await browser.download(resource) else {
            importStatus = browser.statusMessage ?? "远程书下载失败"
            return
        }
        do {
            let file = try ManagedBookFileStore.persist(
                data: download.data,
                fileName: download.name
            )
            if lowercasedName.hasSuffix(".zip") {
                let prepared = try ManagedBookFileStore
                    .localArchiveItems(from: file)
                let report = await library.importLocalArchive(
                    archiveName: file.fileName,
                    items: prepared.items,
                    skipped: prepared.skipped
                )
                guard let profileID = browser.selectedProfileID else {
                    importStatus = "远程书服务器身份丢失"
                    return
                }
                for imported in report.imported {
                    guard let item = await library.item(id: imported.bookID) else {
                        continue
                    }
                    _ = await library.markWebDAVOrigin(
                        for: item,
                        remoteURL: resource.url,
                        serverID: profileID
                    )
                }
                importStatus = "已导入 \(report.imported.count) 本，"
                    + "失败 \(report.failures.count) 本，"
                    + "跳过 \(report.skipped.count) 项"
                if !report.imported.isEmpty { dismiss() }
                return
            }
            let payload: LocalBookPayload = lowercasedName.hasSuffix(".epub")
                ? .epub(try ManagedBookFileStore.epubMembers(from: file))
                : .text(file.data)
            guard
                let item = await library.importLocalBook(
                    fileName: file.fileName,
                    managedReference: file.reference,
                    payload: payload
                )
            else {
                importStatus = library.errorMessage ?? "远程书导入失败"
                return
            }
            guard let profileID = browser.selectedProfileID else {
                importStatus = "远程书服务器身份丢失"
                return
            }
            let persisted = await library.markWebDAVOrigin(
                for: item,
                remoteURL: resource.url,
                serverID: profileID
            )
            guard persisted != nil else {
                importStatus = library.errorMessage ?? "远程书来源保存失败"
                return
            }
            importStatus = "已导入《\(item.candidate.name)》"
            dismiss()
        } catch {
            importStatus = "无法保存远程书文件"
        }
    }
}
