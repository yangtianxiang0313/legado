import AppUseCases
import SwiftUI

struct SourceManagementView: View {
    @Bindable var catalog: SourceCatalog
    let openEditor: (String?) -> Void

    var body: some View {
        List {
            if catalog.sources.isEmpty {
                ContentUnavailableView {
                    Label("还没有书源", systemImage: "tray")
                } description: {
                    Text("添加书源后，可以编辑规则并逐阶段调试。")
                } actions: {
                    Button("添加书源") {
                        openEditor(nil)
                    }
                    .accessibilityIdentifier("action.source.add.empty")
                }
                .accessibilityIdentifier("state.source.empty")
            } else {
                Section("书源") {
                    ForEach(catalog.sources) { source in
                        Button {
                            openEditor(source.sourceURL)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name)
                                    .font(.headline)
                                Text(source.sourceURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if !source.group.isEmpty {
                                    Text(source.group)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .accessibilityIdentifier(
                            "action.source.open.\(source.sourceURL)"
                        )
                    }
                }
                .accessibilityIdentifier("list.source.catalog")
            }
            if let error = catalog.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("书源管理")
        .accessibilityIdentifier("screen.source.management")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openEditor(nil)
                } label: {
                    Label("添加书源", systemImage: "plus")
                }
                .accessibilityIdentifier("action.source.add")
            }
        }
        .task {
            await catalog.reload()
        }
    }
}

private enum SourceEditorSection: String, CaseIterable, Identifiable {
    case base
    case search
    case explore
    case bookInfo
    case toc
    case content

    var id: String { rawValue }

    var title: String {
        switch self {
        case .base: "基本"
        case .search: "搜索"
        case .explore: "发现"
        case .bookInfo: "详情"
        case .toc: "目录"
        case .content: "正文"
        }
    }
}

struct SourceEditorView: View {
    @Bindable var catalog: SourceCatalog
    let navigate: (SourceEditorDestination, String) -> Void
    let dismiss: () -> Void

    @State private var original: BookSourceDraft
    @State private var draft: BookSourceDraft
    @State private var selectedSection: SourceEditorSection = .base
    @State private var showsDiscardConfirmation = false
    @State private var validationMessage: String?

    init(
        source: BookSourceDraft?,
        catalog: SourceCatalog,
        navigate: @escaping (SourceEditorDestination, String) -> Void,
        dismiss: @escaping () -> Void
    ) {
        let initial = source ?? BookSourceDraft()
        self.catalog = catalog
        self.navigate = navigate
        self.dismiss = dismiss
        _original = State(initialValue: initial)
        _draft = State(initialValue: initial)
    }

    var body: some View {
        Form {
            Section {
                Picker("规则页面", selection: $selectedSection) {
                    ForEach(SourceEditorSection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("picker.source.editor.section")
            }
            editorFields
        }
        .navigationTitle(original.sourceURL.isEmpty ? "添加书源" : "编辑书源")
        .navigationBarBackButtonHidden(true)
        .accessibilityIdentifier("screen.source.editor")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    perform(.finish)
                }
                .accessibilityIdentifier("action.source.editor.cancel")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("调试书源") {
                        perform(.debug)
                    }
                    .accessibilityIdentifier("action.source.editor.debug")

                    if loginVisible {
                        Button("登录书源") {
                            perform(.login)
                        }
                        .accessibilityIdentifier("action.source.editor.login")
                    }

                    Button("单源搜索") {
                        perform(.search)
                    }
                    .accessibilityIdentifier("action.source.editor.search")
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("action.source.editor.more")

                Button("保存") {
                    perform(.save)
                }
                .accessibilityIdentifier("action.source.editor.save")
            }
        }
        .alert("放弃未保存的修改？", isPresented: $showsDiscardConfirmation) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃修改", role: .destructive) {
                dismiss()
            }
            .accessibilityIdentifier("action.source.editor.discard")
        }
        .alert(
            "无法保存",
            isPresented: Binding(
                get: { validationMessage != nil },
                set: { if !$0 { validationMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(validationMessage ?? "")
        }
    }

    @ViewBuilder
    private var editorFields: some View {
        switch selectedSection {
        case .base:
            Section("基本信息") {
                TextField("名称", text: $draft.name)
                    .accessibilityIdentifier("field.source.name")
                TextField("书源地址", text: $draft.sourceURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .accessibilityIdentifier("field.source.url")
                TextField("分组", text: $draft.group)
                TextField("登录地址", text: $draft.loginURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .accessibilityIdentifier("field.source.loginURL")
                TextField("备注", text: $draft.comment, axis: .vertical)
            }
        case .search:
            ruleSection(
                title: "搜索规则",
                url: $draft.searchURL,
                rule: $draft.searchRule
            )
        case .explore:
            ruleSection(
                title: "发现规则",
                url: $draft.exploreURL,
                rule: $draft.exploreRule
            )
        case .bookInfo:
            ruleOnlySection(title: "详情规则", rule: $draft.bookInfoRule)
        case .toc:
            ruleOnlySection(title: "目录规则", rule: $draft.tocRule)
        case .content:
            ruleOnlySection(title: "正文规则", rule: $draft.contentRule)
        }
    }

    private func ruleSection(
        title: String,
        url: Binding<String>,
        rule: Binding<String>
    ) -> some View {
        Section(title) {
            TextField("请求地址", text: url)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            TextField("规则", text: rule, axis: .vertical)
                .lineLimit(4...12)
        }
    }

    private func ruleOnlySection(
        title: String,
        rule: Binding<String>
    ) -> some View {
        Section(title) {
            TextField("规则", text: rule, axis: .vertical)
                .lineLimit(6...16)
        }
    }

    private var loginVisible: Bool {
        SourceEditorPolicy.transition(
            action: .login,
            original: original,
            draft: draft
        ).loginVisible
    }

    private func perform(_ action: SourceEditorAction) {
        let transition = SourceEditorPolicy.transition(
            action: action,
            original: original,
            draft: draft
        )
        if transition.requiresDiscardConfirmation {
            showsDiscardConfirmation = true
            return
        }
        if action == .finish {
            dismiss()
            return
        }
        guard transition.saveSucceeded else {
            validationMessage = "书源名称和地址不能为空。"
            return
        }
        Task {
            guard await catalog.save(draft) else {
                validationMessage = catalog.errorMessage ?? "保存失败"
                return
            }
            original = draft
            guard let destination = transition.destination else { return }
            if destination == .dismiss {
                dismiss()
            } else {
                navigate(destination, draft.sourceURL)
            }
        }
    }
}

struct SourceDebugView: View {
    let source: BookSourceDraft

    @State private var key = "我的"
    @State private var route: SourceDebugRoute?

    var body: some View {
        List {
            Section("调试输入") {
                TextField("关键词或调试地址", text: $key)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("field.source.debug.key")
                Button("开始调试") {
                    route = SourceDebugRouter.route(for: key)
                }
                .accessibilityIdentifier("action.source.debug.start")
            }
            Section("调试阶段") {
                debugStage("搜索", active: route?.kind == .search)
                debugStage("发现", active: route?.kind == .explore)
                debugStage("详情", active: route?.kind == .bookInfo)
                debugStage("目录", active: route?.kind == .toc)
                debugStage("正文", active: route?.kind == .content)
            }
            if let route {
                Section("当前路由") {
                    Text(route.kind.rawValue)
                        .accessibilityIdentifier("label.source.debug.route")
                    Text(route.payload)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("调试 · \(source.name)")
        .accessibilityIdentifier("screen.source.debug")
    }

    private func debugStage(_ title: String, active: Bool) -> some View {
        Label(
            title,
            systemImage: active ? "checkmark.circle.fill" : "circle"
        )
        .foregroundStyle(active ? Color.accentColor : Color.secondary)
    }
}

struct SourceLoginView: View {
    let source: BookSourceDraft

    var body: some View {
        ContentUnavailableView {
            Label("书源登录", systemImage: "person.badge.key")
        } description: {
            Text(source.loginURL)
        }
        .navigationTitle(source.name)
        .accessibilityIdentifier("screen.source.login")
    }
}

struct SourceSingleSearchView: View {
    let source: BookSourceDraft
    @State private var query = ""

    var body: some View {
        List {
            Section("仅使用此书源") {
                Text(source.name)
                Text(source.sourceURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("搜索") {
                TextField("书名或作者", text: $query)
                    .accessibilityIdentifier("field.source.search.query")
                Button("搜索") {}
                    .disabled(query.isEmpty)
                    .accessibilityIdentifier("action.source.search.submit")
            }
        }
        .navigationTitle("单源搜索")
        .accessibilityIdentifier("screen.source.search")
    }
}
