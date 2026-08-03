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
        guard resource.name.lowercased().hasSuffix(".txt") else {
            importStatus = "当前 iOS 阅读内核仅支持导入 TXT"
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
            guard
                let item = await library.importLocalText(
                    fileName: file.fileName,
                    managedReference: file.reference,
                    data: file.data
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
