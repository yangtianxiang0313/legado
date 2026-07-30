import AppUseCases
import SwiftUI
import UniformTypeIdentifiers

struct SourceManagementView: View {
    @Bindable var catalog: SourceCatalog
    let openEditor: (String?) -> Void
    @State private var showsImport = false
    @State private var query = ""
    @State private var filter: SourceManagementFilter = .all
    @State private var sort: SourceManagementSort = .defaultOrder
    @State private var ascending = true
    @State private var selection: Set<String> = []
    @State private var editMode: EditMode = .inactive
    @State private var groupName = ""
    @State private var groupMutation: SourceBulkMutation?
    @State private var showsDeleteConfirmation = false
    @State private var exportDocument = SourceJSONDocument()
    @State private var showsExporter = false

    private var visibleSources: [BookSourceDraft] {
        SourceManagementPolicy.visibleSources(
            catalog.sources,
            query: query,
            filter: filter,
            sort: sort,
            ascending: ascending
        )
    }

    private var visibleIDs: [String] {
        visibleSources.map(\.sourceURL)
    }

    private var groups: [String] {
        Array(Set(catalog.sources.flatMap {
            $0.group.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        })).filter { !$0.isEmpty }.sorted()
    }

    private var sharePayload: String {
        guard
            let data = try? catalog.exportData(selectedIDs: selection),
            let value = String(data: data, encoding: .utf8)
        else { return "[]" }
        return value
    }

    private var groupDialogTitle: String {
        guard let groupMutation else { return "修改分组" }
        switch groupMutation {
        case .addGroup:
            return "添加分组"
        case .removeGroup:
            return "移除分组"
        default:
            return "修改分组"
        }
    }

    var body: some View {
        List(selection: $selection) {
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
                Section {
                    ForEach(visibleSources) { source in
                        let metadata = source.importMetadata ?? .init()
                        Button {
                            if editMode == .active {
                                if selection.contains(source.sourceURL) {
                                    selection.remove(source.sourceURL)
                                } else {
                                    selection.insert(source.sourceURL)
                                }
                            } else {
                                openEditor(source.sourceURL)
                            }
                        } label: {
                            HStack {
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
                                Spacer()
                                Image(systemName: metadata.enabled
                                    ? "checkmark.circle.fill"
                                    : "pause.circle")
                                    .foregroundStyle(
                                        metadata.enabled ? .green : .secondary
                                    )
                                    .accessibilityIdentifier(
                                        "state.source."
                                            + (metadata.enabled
                                                ? "enabled."
                                                : "disabled.")
                                            + source.sourceURL
                                    )
                                if metadata.enabledExplore {
                                    Image(systemName: "safari")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .tag(source.sourceURL)
                        .accessibilityIdentifier(
                            "action.source.open.\(source.sourceURL)"
                        )
                    }
                } header: {
                    Text("书源（\(visibleSources.count)）")
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
        .searchable(text: $query, prompt: "名称、地址或分组")
        .environment(\.editMode, $editMode)
        .accessibilityIdentifier("screen.source.management")
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                filterMenu
                sortMenu
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if editMode == .inactive {
                    Menu {
                        Button {
                            showsImport = true
                        } label: {
                            Label(
                                "导入书源",
                                systemImage: "square.and.arrow.down"
                            )
                        }
                        .accessibilityIdentifier("action.source.import")

                        Button {
                            openEditor(nil)
                        } label: {
                            Label("新建书源", systemImage: "plus")
                        }
                        .accessibilityIdentifier("action.source.add")
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .accessibilityIdentifier("action.source.create")
                }
                Button {
                    withAnimation {
                        if editMode == .active {
                            editMode = .inactive
                            selection.removeAll()
                        } else {
                            editMode = .active
                        }
                    }
                } label: {
                    Text(editMode == .active ? "完成" : "选择")
                }
                .accessibilityIdentifier("action.source.selection")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editMode == .active {
                selectionBar
            }
        }
        .sheet(isPresented: $showsImport) {
            NavigationStack {
                SourceImportView(catalog: catalog) {
                    showsImport = false
                }
            }
        }
        .task {
            await catalog.reload()
        }
        .onChange(of: visibleIDs) { _, ids in
            selection.formIntersection(ids)
        }
        .alert(
            groupDialogTitle,
            isPresented: Binding(
                get: { groupMutation != nil },
                set: { if !$0 { groupMutation = nil } }
            )
        ) {
            TextField("分组名称", text: $groupName)
            Button("取消", role: .cancel) {
                groupMutation = nil
            }
            Button("确定") {
                guard let mutation = groupMutation else { return }
                let final: SourceBulkMutation
                switch mutation {
                case .addGroup:
                    final = .addGroup(groupName)
                case .removeGroup:
                    final = .removeGroup(groupName)
                default:
                    return
                }
                apply(final)
                groupMutation = nil
            }
        }
        .confirmationDialog(
            "删除选中的 \(selection.count) 个书源？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                let selected = selection
                Task {
                    if await catalog.delete(selectedIDs: selected) {
                        selection.removeAll()
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .fileExporter(
            isPresented: $showsExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "bookSource.json"
        ) { _ in }
    }

    private var filterMenu: some View {
        Menu {
            filterButton("全部", value: .all)
            filterButton("已启用", value: .enabled)
            filterButton("已停用", value: .disabled)
            filterButton("发现已启用", value: .exploreEnabled)
            filterButton("发现已停用", value: .exploreDisabled)
            filterButton("无分组", value: .ungrouped)
            if !groups.isEmpty {
                Divider()
                ForEach(groups, id: \.self) { group in
                    filterButton(group, value: .group(group))
                }
            }
        } label: {
            Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private var sortMenu: some View {
        Menu {
            sortButton("默认顺序", value: .defaultOrder)
            sortButton("名称", value: .name)
            sortButton("地址", value: .url)
            sortButton("更新时间", value: .updated)
            sortButton("启用状态", value: .enabled)
            Divider()
            Button {
                ascending.toggle()
            } label: {
                Label(
                    ascending ? "升序" : "降序",
                    systemImage: ascending
                        ? "arrow.up"
                        : "arrow.down"
                )
            }
        } label: {
            Label("排序", systemImage: "arrow.up.arrow.down")
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 14) {
            Menu {
                Button("全选") {
                    selection = SourceManagementPolicy.selectAll(
                        visibleIDs: visibleIDs
                    )
                }
                Button("反选") {
                    selection = SourceManagementPolicy.invertSelection(
                        selection,
                        visibleIDs: visibleIDs
                    )
                }
                Button("补全选择区间") {
                    selection = SourceManagementPolicy.fillSelectionInterval(
                        selection,
                        visibleIDs: visibleIDs
                    )
                }
            } label: {
                Label("\(selection.count) 项", systemImage: "checklist")
            }
            .accessibilityIdentifier("action.source.selectionOptions")

            Spacer()

            Menu {
                Button("启用") { apply(.setEnabled(true)) }
                    .accessibilityIdentifier("action.source.batch.enable")
                Button("停用") { apply(.setEnabled(false)) }
                    .accessibilityIdentifier("action.source.batch.disable")
                Button("启用发现") { apply(.setExploreEnabled(true)) }
                Button("停用发现") { apply(.setExploreEnabled(false)) }
                Divider()
                Button("置顶") { apply(.moveToTop) }
                Button("置底") { apply(.moveToBottom) }
                Button("添加分组") {
                    groupName = ""
                    groupMutation = .addGroup("")
                }
                Button("移除分组") {
                    groupName = ""
                    groupMutation = .removeGroup("")
                }
                Divider()
                Button("导出 JSON") {
                    guard
                        let data = try? catalog.exportData(
                            selectedIDs: selection
                        )
                    else { return }
                    exportDocument = SourceJSONDocument(data: data)
                    showsExporter = true
                }
                ShareLink(
                    item: sharePayload,
                    subject: Text("书源"),
                    message: Text("Legado 书源 JSON")
                ) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            } label: {
                Label("批量操作", systemImage: "ellipsis.circle")
            }
            .disabled(selection.isEmpty)
            .accessibilityIdentifier("action.source.batch")

            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityIdentifier("bar.source.selection")
    }

    @ViewBuilder
    private func filterButton(
        _ title: String,
        value: SourceManagementFilter
    ) -> some View {
        Button {
            filter = value
        } label: {
            if filter == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    @ViewBuilder
    private func sortButton(
        _ title: String,
        value: SourceManagementSort
    ) -> some View {
        Button {
            sort = value
        } label: {
            if sort == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func apply(_ mutation: SourceBulkMutation) {
        let selected = selection
        Task {
            _ = await catalog.apply(mutation, selectedIDs: selected)
        }
    }
}

private struct SourceJSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data = Data("[]".utf8)

    init(data: Data = Data("[]".utf8)) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data("[]".utf8)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct SourceImportView: View {
    @Bindable var catalog: SourceCatalog
    let dismiss: () -> Void

    @State private var payload = ""
    @State private var candidates: [SourceImportCandidate]?
    @State private var showsFileImporter = false
    @State private var message: String?
    @State private var keepName = false
    @State private var keepGroup = false
    @State private var keepEnable = false
    @State private var group = ""
    @State private var groupMode: SourceImportGroupMode = .unchanged

    var body: some View {
        Form {
            if let candidates {
                preview(candidates)
            } else {
                Section("书源定义") {
                    TextEditor(text: $payload)
                        .frame(minHeight: 180)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("field.source.import.text")
                    Button("选择 JSON 文件") {
                        showsFileImporter = true
                    }
                    .accessibilityIdentifier("action.source.import.file")
                }
            }
            if let message {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("label.source.import.message")
                }
            }
        }
        .navigationTitle("导入书源")
        .accessibilityIdentifier("screen.source.import")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", action: dismiss)
                    .accessibilityIdentifier("action.source.import.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                if candidates == nil {
                    Button("解析", action: parse)
                        .disabled(payload.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty)
                        .accessibilityIdentifier("action.source.import.parse")
                } else {
                    Button("导入", action: commit)
                        .accessibilityIdentifier("action.source.import.commit")
                }
            }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.json, .plainText]
        ) { result in
            switch result {
            case .success(let url):
                load(url)
            case .failure:
                message = "无法读取所选文件"
            }
        }
    }

    @ViewBuilder
    private func preview(
        _ values: [SourceImportCandidate]
    ) -> some View {
        if values.isEmpty {
            ContentUnavailableView(
                "没有可导入的书源",
                systemImage: "tray"
            )
            .accessibilityIdentifier("state.source.import.empty")
        } else {
            Section("导入预览") {
                ForEach(values.indices, id: \.self) { index in
                    Toggle(isOn: Binding(
                        get: { candidates?[index].selected ?? false },
                        set: { candidates?[index].selected = $0 }
                    )) {
                        VStack(alignment: .leading) {
                            Text(values[index].incoming.name)
                            Text(values[index].incoming.sourceURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(status(values[index]))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier(
                        "toggle.source.import.candidate.\(index)"
                    )
                }
            }
            Section("冲突处理") {
                Toggle("保留现有名称", isOn: $keepName)
                Toggle("保留现有分组", isOn: $keepGroup)
                Toggle("保留现有启停状态", isOn: $keepEnable)
                Picker("指定分组", selection: $groupMode) {
                    Text("不修改").tag(SourceImportGroupMode.unchanged)
                    Text("替换").tag(SourceImportGroupMode.replace)
                    Text("追加").tag(SourceImportGroupMode.append)
                }
                if groupMode != .unchanged {
                    TextField("分组名称", text: $group)
                }
            }
        }
    }

    private func status(_ candidate: SourceImportCandidate) -> String {
        if candidate.isNew { return "新增" }
        if candidate.isUpdate { return "可更新" }
        return "已是最新"
    }

    private func parse() {
        do {
            let imported = try SourceDefinitionImport.decode(
                Data(payload.utf8)
            )
            candidates = SourceImportPolicy.preview(
                incoming: imported,
                existing: catalog.sources
            )
            message = imported.isEmpty ? "文件中没有书源" : nil
        } catch SourceImportError.notSource {
            message = "内容不是有效书源"
        } catch {
            message = "书源格式不正确"
        }
    }

    private func commit() {
        guard let candidates else { return }
        let sources = SourceImportPolicy.mergedSelection(
            candidates,
            options: SourceImportOptions(
                keepName: keepName,
                keepGroup: keepGroup,
                keepEnable: keepEnable,
                group: group,
                groupMode: groupMode
            )
        )
        guard !sources.isEmpty else {
            message = "没有选中有效书源"
            return
        }
        Task {
            if await catalog.importSources(sources) {
                dismiss()
            }
        }
    }

    private func load(_ url: URL) {
        let granted = url.startAccessingSecurityScopedResource()
        defer {
            if granted {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            payload = try String(contentsOf: url, encoding: .utf8)
            candidates = nil
            message = nil
        } catch {
            message = "无法读取所选文件"
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
