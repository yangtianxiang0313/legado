import AppUseCases
import IntegrationKit
import SwiftUI
import WebDAVFoundation

struct KeychainWebDAVServerCredentialVault: WebDAVServerCredentialVault {
    let store: KeychainWebDAVCredentialStore

    func credential(
        for reference: WebDAVCredentialReference
    ) async -> WebDAVServerCredential? {
        guard let value = try? await store.credentials(for: reference) else {
            return nil
        }
        return WebDAVServerCredential(
            username: value.username,
            password: value.password
        )
    }

    func save(
        _ credential: WebDAVServerCredential,
        for reference: WebDAVCredentialReference
    ) async throws {
        try await store.save(
            WebDAVBasicCredentials(
                username: credential.username,
                password: credential.password
            ),
            for: reference
        )
    }

    func remove(reference: WebDAVCredentialReference) async {
        await store.remove(reference: reference)
    }
}

struct WebDAVServerManagementView: View {
    let repository: any WebDAVServerProfileRepository
    let credentialVault: any WebDAVServerCredentialVault

    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [WebDAVServerProfile] = []
    @State private var selectedID: Int64?
    @State private var editorProfile: WebDAVServerProfile?
    @State private var editorPresented = false
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(profiles, id: \.id) { profile in
                    serverRow(profile)
                        .swipeActions(edge: .trailing) {
                            if !profile.isAndroidDefault {
                                Button("删除", role: .destructive) {
                                    Task { await delete(profile) }
                                }
                                .accessibilityIdentifier(
                                    "action.webdavServers.delete.\(profile.id)"
                                )
                                Button("编辑") { presentEditor(profile) }
                                    .tint(.blue)
                                    .accessibilityIdentifier(
                                        "action.webdavServers.edit.\(profile.id)"
                                    )
                            }
                        }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("state.webdavServers.status")
                }
            }
            .navigationTitle("服务器配置")
            .accessibilityIdentifier("screen.webdavServers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        presentEditor(nil)
                    } label: {
                        Label("添加服务器", systemImage: "plus")
                    }
                    .accessibilityIdentifier("action.webdavServers.add")
                }
            }
            .task { await reload() }
            .sheet(isPresented: $editorPresented) {
                WebDAVServerEditorView(
                    profile: editorProfile,
                    credentialVault: credentialVault
                ) { draft in
                    try await save(draft)
                }
            }
        }
    }

    private func serverRow(_ profile: WebDAVServerProfile) -> some View {
        Button {
            Task { await select(profile) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                    Text(profile.serverAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if selectedID == profile.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("action.webdavServers.select.\(profile.id)")
        .contextMenu {
            if !profile.isAndroidDefault {
                Button("编辑") { presentEditor(profile) }
                Button("删除", role: .destructive) {
                    Task { await delete(profile) }
                }
            }
        }
    }

    private func presentEditor(_ profile: WebDAVServerProfile?) {
        editorProfile = profile
        editorPresented = true
    }

    private func reload() async {
        do {
            profiles = try await repository.webDAVServerProfiles()
            selectedID = try await repository.selectedWebDAVServerProfileID()
            statusMessage = nil
        } catch {
            statusMessage = "无法读取服务器配置"
        }
    }

    private func select(_ profile: WebDAVServerProfile) async {
        do {
            try await WebDAVServerProfileManagementUseCase(
                repository: repository,
                vault: credentialVault
            ).select(id: profile.id)
            selectedID = profile.id
            statusMessage = nil
        } catch {
            statusMessage = "无法选择服务器"
        }
    }

    private func save(_ draft: WebDAVServerEditorDraft) async throws {
        _ = try await WebDAVServerProfileManagementUseCase(
            repository: repository,
            vault: credentialVault
        ).save(
            id: draft.id,
            name: draft.name,
            serverAddress: draft.serverAddress,
            username: draft.username,
            password: draft.password,
            sortNumber: draft.sortNumber
        )
        await reload()
    }

    private func delete(_ profile: WebDAVServerProfile) async {
        do {
            selectedID = try await WebDAVServerProfileManagementUseCase(
                repository: repository,
                vault: credentialVault
            ).delete(id: profile.id)
            await reload()
        } catch {
            statusMessage = "无法删除服务器"
        }
    }
}

struct WebDAVServerEditorDraft: Sendable {
    let id: Int64?
    let name: String
    let serverAddress: String
    let username: String
    let password: String
    let sortNumber: Int
}

private struct WebDAVServerEditorView: View {
    let profile: WebDAVServerProfile?
    let credentialVault: any WebDAVServerCredentialVault
    let onSave: (WebDAVServerEditorDraft) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name)
                    .accessibilityIdentifier("field.webdavServer.name")
                TextField("WebDAV 地址", text: $serverAddress)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .accessibilityIdentifier("field.webdavServer.url")
                TextField("账号", text: $username)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("field.webdavServer.username")
                SecureField("密码", text: $password)
                    .accessibilityIdentifier("field.webdavServer.password")
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("state.webdavServer.error")
                }
            }
            .navigationTitle(profile == nil ? "添加服务器" : "编辑服务器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(isSaving)
                        .accessibilityIdentifier("action.webdavServer.save")
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let profile else { return }
        name = profile.name
        serverAddress = profile.serverAddress
        if let credential = await credentialVault.credential(
            for: profile.credentialReference
        ) {
            username = credential.username
            password = credential.password
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(
                WebDAVServerEditorDraft(
                    id: profile?.id,
                    name: name,
                    serverAddress: serverAddress,
                    username: username,
                    password: password,
                    sortNumber: profile?.sortNumber ?? 0
                )
            )
            dismiss()
        } catch WebDAVServerProfileManagementError.invalidName {
            errorMessage = "请输入服务器名称"
        } catch WebDAVServerProfileManagementError.invalidServerAddress {
            errorMessage = "请输入有效的 HTTP 或 HTTPS 地址"
        } catch WebDAVServerProfileManagementError.invalidCredentials {
            errorMessage = "请输入账号和密码"
        } catch {
            errorMessage = "保存服务器失败"
        }
    }
}
