import AppUseCases
import BackupInteropUseCases
import CoreTransferable
import IntegrationKit
import LibraryDomain
import SwiftUI
import UniformTypeIdentifiers

struct ShelfManagementView: View {
    @Bindable var library: ShelfLibrary
    let persistedSources: [BookSourceDraft]
    @Bindable var sourceSwitchPreferences: SourceSwitchPreferencesStore
    let webDAVServerProfiles: any WebDAVServerProfileRepository
    let webDAVServerCredentials: any WebDAVServerCredentialVault
    let webDAVRemoteBooks: any WebDAVRemoteBookTransferring
    let openSearch: () -> Void
    let openBook: (ShelfBookItem) -> Void

    @State private var isManaging = false
    @State private var selection: Set<ShelfBookItem.ID> = []
    @State private var pendingDelete = false
    @State private var fileImporterPresented = false
    @State private var urlImporterPresented = false
    @State private var webDAVImporterPresented = false
    @State private var bookshelfListImporterPresented = false
    @State private var importURL = ""
    @State private var importStatus: String?

    var body: some View {
        VStack(spacing: 12) {
            header

            if library.books.isEmpty {
                ContentUnavailableView {
                    Label("书架还是空的", systemImage: "books.vertical")
                } description: {
                    Text("搜索并加入书籍后，可以在这里排序和批量管理。")
                }
                .accessibilityIdentifier("state.shelf.empty")
            } else {
                bookList
            }

            if isManaging {
                managementBar
            } else {
                Button(action: openSearch) {
                    Label("搜索书籍", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("action.shelf.openSearch")
            }

            if let report = library.lastBatchReport {
                Text(reportSummary(report))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("state.shelf.batchReport")
            }
            if let importStatus {
                Text(importStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("state.bookImport.result")
            }
            if let report = library.lastOfflineCacheReport {
                Text(offlineCacheSummary(report))
                    .font(.caption)
                    .foregroundStyle(
                        report.failedCount == 0
                            ? Color.secondary
                            : Color.red
                    )
                    .accessibilityIdentifier(
                        "state.shelf.offlineCacheReport"
                    )
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("书架")
        .confirmationDialog(
            "确定删除所选书籍？",
            isPresented: $pendingDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                runBatch(.delete)
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            Task { await library.reload() }
        }
        .fileImporter(
            isPresented: $fileImporterPresented,
            allowedContentTypes: supportedLocalBookTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first
            else {
                importStatus = "未选择书籍"
                return
            }
            Task {
                do {
                    let file = try ManagedBookFileStore
                        .importSelectedURL(url)
                    if file.fileName.lowercased().hasSuffix(".zip") {
                        let prepared = try ManagedBookFileStore
                            .localArchiveItems(from: file)
                        let report = await library.importLocalArchive(
                            archiveName: file.fileName,
                            items: prepared.items,
                            skipped: prepared.skipped
                        )
                        importStatus = archiveReportSummary(report)
                        return
                    }
                    let payload: LocalBookPayload = file.fileName
                        .lowercased().hasSuffix(".epub")
                        ? .epub(try ManagedBookFileStore.epubMembers(from: file))
                        : .text(file.data)
                    let item = await library.importLocalBook(
                        fileName: file.fileName,
                        managedReference: file.reference,
                        payload: payload
                    )
                    importStatus = item == nil
                        ? (library.errorMessage ?? "导入失败")
                        : "已导入《\(item!.candidate.name)》"
                } catch {
                    importStatus = "无法读取所选文件"
                }
            }
        }
        .alert(
            "添加书籍网址",
            isPresented: $urlImporterPresented
        ) {
            TextField("https://…", text: $importURL)
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("field.bookImport.url")
            Button("添加") {
                let value = importURL
                Task {
                    do {
                        let item = try await SearchEnvironment
                            .importBookURL(
                                value,
                                library: library,
                                persistedSources: persistedSources
                            )
                        importStatus = "已导入《\(item.candidate.name)》"
                    } catch {
                        importStatus = "网址或匹配书源不可用"
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $webDAVImporterPresented) {
            WebDAVRemoteBookImportView(
                library: library,
                repository: webDAVServerProfiles,
                credentialVault: webDAVServerCredentials,
                transfer: webDAVRemoteBooks
            )
        }
        .sheet(isPresented: $bookshelfListImporterPresented) {
            BookshelfListImportView(
                library: library,
                persistedSources: persistedSources,
                initialData: nil,
                dismiss: { bookshelfListImporterPresented = false },
                onComplete: { importStatus = $0 }
            )
        }
    }

    private var supportedLocalBookTypes: [UTType] {
        var values: [UTType] = [.plainText]
        if let epub = UTType(filenameExtension: "epub") {
            values.append(epub)
        }
        values.append(.zip)
        return values
    }

    private func archiveReportSummary(_ report: LocalArchiveImportReport) -> String {
        "已导入 \(report.imported.count) 本，失败 \(report.failures.count) 本，"
            + "跳过 \(report.skipped.count) 项"
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text("书架")
                    .font(.largeTitle.bold())
                    .accessibilityIdentifier("screen.root.shelf")
                Spacer()
                Menu {
                    Button {
                        fileImporterPresented = true
                    } label: {
                        Label("从文件导入", systemImage: "doc")
                    }
                    .accessibilityIdentifier(
                        "action.bookImport.file"
                    )
                    Button {
                        importURL = ""
                        urlImporterPresented = true
                    } label: {
                        Label("添加网址", systemImage: "link")
                    }
                    .accessibilityIdentifier(
                        "action.bookImport.url"
                    )
                    Button {
                        webDAVImporterPresented = true
                    } label: {
                        Label("WebDAV 远程书", systemImage: "externaldrive")
                    }
                    .accessibilityIdentifier(
                        "action.bookImport.webdav"
                    )
                    Button {
                        bookshelfListImporterPresented = true
                    } label: {
                        Label(
                            "导入 Android 书架清单",
                            systemImage: "books.vertical"
                        )
                    }
                    .accessibilityIdentifier(
                        "action.bookshelfList.import"
                    )
                    if !library.books.isEmpty,
                       let data = try? AndroidBookshelfListCodec.export(
                        library.books
                       ) {
                        ShareLink(
                            item: BookshelfListShareItem(data: data),
                            preview: SharePreview(
                                "bookshelf.json",
                                image: Image(systemName: "books.vertical")
                            )
                        ) {
                            Label(
                                "分享 Android 书架清单",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        .accessibilityIdentifier(
                            "action.bookshelfList.export"
                        )
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("action.bookImport.open")
                groupMenu
                sortMenu
                Button(isManaging ? "完成" : "管理") {
                    isManaging.toggle()
                    if !isManaging {
                        selection.removeAll()
                    }
                }
                .accessibilityIdentifier("action.shelf.manage")
            }

            HStack {
                Text(groupTitle)
                Text("·")
                Text(library.sortMode.title)
                Spacer()
                Text("\(library.books.count) 本")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("state.shelf.projection")
        }
    }

    private var bookList: some View {
        List {
            ForEach(library.books) { book in
                Button {
                    if isManaging {
                        toggle(book.id)
                    } else {
                        openBook(book)
                    }
                } label: {
                    HStack(spacing: 12) {
                        if isManaging {
                            Image(
                                systemName: selection.contains(book.id)
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                            .foregroundStyle(
                                selection.contains(book.id)
                                    ? Color.accentColor
                                    : Color.secondary
                            )
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(book.candidate.name)
                                .font(.headline)
                            Text("作者：\(book.candidate.author)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                if book.latestCheckCount > 0 {
                                    badge(
                                        "新增 \(book.latestCheckCount) 章",
                                        color: .orange
                                    )
                                }
                                if book.unreadChapterCount > 0 {
                                    badge(
                                        "未读 \(book.unreadChapterCount) 章",
                                        color: .blue
                                    )
                                }
                                if !book.canUpdate {
                                    badge("不更新", color: .secondary)
                                }
                            }
                        }
                        Spacer()
                        if !isManaging {
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(
                    isManaging
                        ? "action.shelf.select.\(book.id.rawValue)"
                        : "action.shelf.openBook"
                )
            }
            .onMove { fromOffsets, toOffset in
                Task {
                    await library.moveBooks(
                        fromOffsets: fromOffsets,
                        toOffset: toOffset
                    )
                }
            }
        }
        .environment(
            \.editMode,
            .constant(isManaging ? .active : .inactive)
        )
        .accessibilityIdentifier("list.shelf.books")
        .frame(maxHeight: isManaging ? 90 : 300)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(ShelfSortMode.allCases, id: \.rawValue) { mode in
                Button {
                    Task {
                        await library.setSortMode(
                            mode,
                            forCurrentGroup:
                                library.selectedGroupID != nil
                        )
                    }
                } label: {
                    if mode == library.sortMode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
                .accessibilityIdentifier(
                    "action.shelf.sort.\(mode.rawValue)"
                )
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("action.shelf.sort")
    }

    private var groupMenu: some View {
        Menu {
            Button("全部书籍") {
                Task { await library.selectGroup(nil) }
            }
            Button("未分组") {
                Task { await library.selectGroup(0) }
            }
            ForEach(library.availableGroups) { group in
                Button(group.name) {
                    Task { await library.selectGroup(group.id) }
                }
            }
        } label: {
            Image(systemName: "folder")
        }
        .accessibilityIdentifier("action.shelf.group")
    }

    private var managementBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text("已选择 \(selection.count) 本")
                    .accessibilityIdentifier("state.shelf.selection")
                Spacer()
                Button(
                    selection.count == library.books.count
                        ? "取消全选"
                        : "全选"
                ) {
                    if selection.count == library.books.count {
                        selection.removeAll()
                    } else {
                        selection = Set(library.books.map(\.id))
                    }
                }
                .accessibilityIdentifier("action.shelf.selectAll")
            }

            HStack {
                Menu("更新") {
                    Button("允许更新") {
                        runBatch(.setCanUpdate(true))
                    }
                    Button("停止更新") {
                        runBatch(.setCanUpdate(false))
                    }
                }
                .accessibilityIdentifier("action.shelf.batch.update")

                Menu("分组") {
                    Button("移到未分组") {
                        runBatch(.moveToGroup(0))
                    }
                    ForEach(library.availableGroups) { group in
                        Button("移到\(group.name)") {
                            runBatch(.moveToGroup(group.id))
                        }
                    }
                }
                .accessibilityIdentifier("action.shelf.batch.group")

                sourceMenu

                Menu {
                    Button("离线缓存") {
                        runOfflineCache()
                    }
                    .accessibilityIdentifier(
                        "action.shelf.batch.offlineCache"
                    )
                    Button("清除缓存") {
                        runBatch(.clearCache)
                    }
                    Button("删除", role: .destructive) {
                        pendingDelete = true
                    }
                } label: {
                    Text("更多")
                }
                .accessibilityIdentifier("action.shelf.batch.more")
            }
            .disabled(selection.isEmpty)
            .buttonStyle(.bordered)
        }
    }

    private var sourceMenu: some View {
        Menu("换源") {
            ForEach(
                persistedSources.filter {
                    $0.importMetadata?.enabled ?? true
                },
                id: \.sourceURL
            ) { source in
                Button(source.name) {
                    let selected = orderedSelection
                    Task {
                        _ = await library.switchSources(
                            bookIDs: selected,
                            targetSourceID: source.sourceURL
                        ) { current in
                            let resolved = try await SearchEnvironment
                                .resolveSourceSwitch(
                                    current: current,
                                    target: source,
                                    persistedSources: persistedSources,
                                    requiresAuthorMatch:
                                        sourceSwitchPreferences.value
                                        .requiresAuthorMatch
                                )
                            return (
                                candidate: resolved.candidate,
                                chapters: resolved.chapters
                            )
                        }
                        selection.removeAll()
                    }
                }
            }
        }
        .accessibilityIdentifier("action.shelf.batch.source")
    }

    private var orderedSelection: [ShelfBookItem.ID] {
        library.books.map(\.id).filter(selection.contains)
    }

    private var groupTitle: String {
        guard let groupID = library.selectedGroupID else {
            return "全部书籍"
        }
        if groupID == 0 {
            return "未分组"
        }
        return library.availableGroups.first { $0.id == groupID }?.name
            ?? "分组 \(groupID)"
    }

    private func toggle(_ id: ShelfBookItem.ID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func runBatch(_ mutation: ShelfBatchMutation) {
        let selected = orderedSelection
        Task {
            _ = await library.performBatch(mutation, bookIDs: selected)
            selection.removeAll()
        }
    }

    private func runOfflineCache() {
        let selected = orderedSelection
        Task {
            _ = await library.cacheOffline(
                bookIDs: selected,
                loader: SearchEnvironment.makeReaderContentLoader(
                    persistedSources: persistedSources
                )
            )
            selection.removeAll()
        }
    }

    private func reportSummary(_ report: ShelfBatchReport) -> String {
        "已完成 \(report.committedBookIDs.count)，"
            + "失败 \(report.failedBookIDs.count)，"
            + "取消 \(report.cancelledBookIDs.count)"
    }

    private func offlineCacheSummary(
        _ report: OfflineCacheReport
    ) -> String {
        "已缓存 \(report.cachedCount)，"
            + "跳过 \(report.skippedCount)，"
            + "失败 \(report.failedCount)，"
            + "取消 \(report.cancelledCount)"
    }

    private func badge(
        _ title: String,
        color: Color
    ) -> some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private extension ShelfSortMode {
    var title: String {
        switch self {
        case .recentlyRead:
            "最近阅读"
        case .recentlyUpdated:
            "最近更新"
        case .name:
            "书名"
        case .manual:
            "手动"
        case .combinedTime:
            "综合时间"
        }
    }
}

private struct BookshelfListShareItem: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
            .suggestedFileName { _ in "bookshelf.json" }
    }
}

struct BookshelfListImportView: View {
    @Bindable var library: ShelfLibrary
    let persistedSources: [BookSourceDraft]
    let initialData: Data?
    let dismiss: () -> Void
    let onComplete: (String) -> Void

    @State private var input = ""
    @State private var resolutions: [BookshelfListResolution]?
    @State private var isResolving = false
    @State private var fileImporterPresented = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                if isResolving {
                    Section {
                        ProgressView("正在按书名和作者精确搜索…")
                    }
                } else if let resolutions {
                    Section("结构化匹配结果") {
                        ForEach(resolutions.indices, id: \.self) { index in
                            resolutionRow(index)
                        }
                    }
                } else {
                    Section("Android bookshelf.json 或远程地址") {
                        TextEditor(text: $input)
                            .frame(minHeight: 180)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier(
                                "field.bookshelfList.import"
                            )
                        Button("选择 JSON 文件") {
                            fileImporterPresented = true
                        }
                        .accessibilityIdentifier(
                            "action.bookshelfList.importFile"
                        )
                    }
                }
                if let message {
                    Section {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(
                                "state.bookshelfList.import"
                            )
                    }
                }
            }
            .navigationTitle("导入 Android 书架")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: dismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if resolutions == nil {
                        Button("解析并匹配") {
                            Task { await parseAndResolve() }
                        }
                        .disabled(
                            input.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty || isResolving
                        )
                    } else {
                        Button("加入书架") {
                            Task { await commit() }
                        }
                        .disabled(selectedCandidates.isEmpty)
                    }
                }
            }
            .fileImporter(
                isPresented: $fileImporterPresented,
                allowedContentTypes: [.json, .plainText],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result,
                      let url = urls.first
                else {
                    message = "未选择书架清单"
                    return
                }
                loadFile(url)
            }
            .task {
                guard let initialData, resolutions == nil else { return }
                await resolve(data: initialData)
            }
        }
    }

    @ViewBuilder
    private func resolutionRow(_ index: Int) -> some View {
        let resolution = resolutions![index]
        Toggle(isOn: Binding(
            get: { resolutions?[index].isSelected ?? false },
            set: { resolutions?[index].isSelected = $0 }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text(resolution.entry.name)
                Text(
                    resolution.entry.author.isEmpty
                        ? resolution.status
                        : "\(resolution.entry.author) · \(resolution.status)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .disabled(resolution.candidate == nil)
    }

    private var selectedCandidates: [ShelfBookCandidate] {
        (resolutions ?? []).compactMap {
            $0.isSelected ? $0.candidate : nil
        }
    }

    private func parseAndResolve() async {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let data: Data
            if let url = URL(string: value),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                data = try await SearchEnvironment
                    .loadRemoteRuleSubscriptionPayload(value)
            } else {
                data = Data(value.utf8)
            }
            await resolve(data: data)
        } catch {
            message = "无法下载远程书架清单"
        }
    }

    private func resolve(data: Data) async {
        isResolving = true
        message = nil
        defer { isResolving = false }
        do {
            let entries = try AndroidBookshelfListCodec.decode(data)
            var seen: Set<String> = []
            var values: [BookshelfListResolution] = []
            for entry in entries {
                let key = entry.name + "\u{0}" + entry.author
                guard !entry.name.isEmpty, seen.insert(key).inserted else {
                    continue
                }
                if library.containsBook(name: entry.name, author: entry.author) {
                    values.append(BookshelfListResolution(
                        entry: entry,
                        candidate: nil,
                        status: "已在书架",
                        isSelected: false
                    ))
                    continue
                }
                let candidate = try? await SearchEnvironment
                    .resolveBookshelfEntry(
                        entry,
                        persistedSources: persistedSources
                    )
                values.append(BookshelfListResolution(
                    entry: entry,
                    candidate: candidate,
                    status: candidate == nil
                        ? "启用书源中未找到"
                        : "已匹配 \(candidate!.originName)",
                    isSelected: candidate != nil
                ))
            }
            resolutions = values
            let matched = values.filter { $0.candidate != nil }.count
            message = "共 \(values.count) 项，匹配 \(matched) 项"
        } catch {
            message = "不是有效的 Android bookshelf.json"
        }
    }

    private func commit() async {
        let candidates = selectedCandidates
        let groupID = library.selectedGroupID ?? 0
        for candidate in candidates {
            await library.add(candidate, groupID: groupID)
        }
        let summary = "已从 Android 书架清单加入 \(candidates.count) 本书"
        onComplete(summary)
        dismiss()
    }

    private func loadFile(_ url: URL) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 32 * 1_024 * 1_024 else {
                message = "书架清单超过 32 MB"
                return
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            Task { await resolve(data: data) }
        } catch {
            message = "无法读取书架清单"
        }
    }
}

private struct BookshelfListResolution {
    let entry: AndroidBookshelfListEntry
    let candidate: ShelfBookCandidate?
    let status: String
    var isSelected: Bool
}
