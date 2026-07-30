import AppUseCases
import LibraryDomain
import SwiftUI

struct ShelfManagementView: View {
    @Bindable var library: ShelfLibrary
    let persistedSources: [BookSourceDraft]
    let openSearch: () -> Void
    let openBook: (ShelfBookItem) -> Void

    @State private var isManaging = false
    @State private var selection: Set<ShelfBookItem.ID> = []
    @State private var pendingDelete = false

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
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text("书架")
                    .font(.largeTitle.bold())
                    .accessibilityIdentifier("screen.root.shelf")
                Spacer()
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
            ForEach(library.availableGroupIDs, id: \.self) { groupID in
                Button("分组 \(groupID)") {
                    Task { await library.selectGroup(groupID) }
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
                    Button("移到分组 1") {
                        runBatch(.moveToGroup(1))
                    }
                }
                .accessibilityIdentifier("action.shelf.batch.group")

                sourceMenu

                Menu {
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
        return groupID == 0 ? "未分组" : "分组 \(groupID)"
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

    private func reportSummary(_ report: ShelfBatchReport) -> String {
        "已完成 \(report.committedBookIDs.count)，"
            + "失败 \(report.failedBookIDs.count)，"
            + "取消 \(report.cancelledBookIDs.count)"
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
