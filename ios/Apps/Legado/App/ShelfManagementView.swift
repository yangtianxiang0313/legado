import AppUseCases
import IntegrationKit
import LibraryDomain
import SwiftUI
import UniformTypeIdentifiers

struct ShelfManagementView: View {
    @Bindable var library: ShelfLibrary
    let persistedSources: [BookSourceDraft]
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
    }

    private var supportedLocalBookTypes: [UTType] {
        var values: [UTType] = [.plainText]
        if let epub = UTType(filenameExtension: "epub") {
            values.append(epub)
        }
        return values
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
                                    persistedSources: persistedSources
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
