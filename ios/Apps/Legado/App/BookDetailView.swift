import AppNavigation
import AppUseCases
import LibraryDomain
import SwiftUI

struct BookDetailDisplay: Equatable {
    let name: String
    let author: String
    let kind: String
    let lastChapter: String
    let intro: String
    let coverURL: String?
    let originName: String

    static let acceptance = BookDetailDisplay(
        name: "星河纪事",
        author: "林舟",
        kind: "科幻 · 冒险",
        lastChapter: "第二章 回声",
        intro: "一段包含 & 与 <转义> 的简介。",
        coverURL: nil,
        originName: "本地书源"
    )

    init(route: SearchBookRoute) {
        self.init(
            name: route.name,
            author: route.author,
            kind: route.kind,
            lastChapter: route.lastChapter,
            intro: route.intro,
            coverURL: route.coverURL,
            originName: route.originName
        )
    }

    init(
        name: String,
        author: String,
        kind: String,
        lastChapter: String,
        intro: String,
        coverURL: String?,
        originName: String
    ) {
        self.name = name
        self.author = author
        self.kind = kind
        self.lastChapter = lastChapter
        self.intro = intro
        self.coverURL = coverURL
        self.originName = originName
    }
}

extension BookDetailActionSnapshot {
    static let remoteSourceLoginUnshelved = BookDetailActionSnapshot(
        isInBookshelf: false,
        sourceState: .present,
        loginURLState: .nonblank,
        bookKind: .remote,
        canUpdate: false,
        splitsLongChapters: false,
        confirmsDeletion: true
    )
}

enum BookSourceSwitchOutcome {
    case success(ShelfBookItem)
    case failure(String)
}

enum BookDetailAcceptanceCase: String, CaseIterable {
    case remoteSourceLoginUnshelved = "remote-source-login-unshelved"
    case remoteSourceNoLoginShelved = "remote-source-no-login-shelved"
    case remoteSourceWhitespaceLogin = "remote-source-whitespace-login"
    case remoteMissingSource = "remote-missing-source"
    case localTXTShelved = "local-txt-shelved"
    case localNonTXTUnshelved = "local-non-txt-unshelved"

    init?(processArguments: [String]) {
        guard
            let marker = processArguments.firstIndex(
                of: "--book-detail-case"
            ),
            processArguments.indices.contains(marker + 1)
        else {
            return nil
        }
        self.init(rawValue: processArguments[marker + 1])
    }

    var snapshot: BookDetailActionSnapshot {
        switch self {
        case .remoteSourceLoginUnshelved:
            .remoteSourceLoginUnshelved
        case .remoteSourceNoLoginShelved:
            BookDetailActionSnapshot(
                isInBookshelf: true,
                sourceState: .present,
                loginURLState: .blank,
                bookKind: .remote,
                canUpdate: true,
                splitsLongChapters: true,
                confirmsDeletion: false
            )
        case .remoteSourceWhitespaceLogin:
            BookDetailActionSnapshot(
                isInBookshelf: false,
                sourceState: .present,
                loginURLState: .whitespace,
                bookKind: .remote,
                canUpdate: true,
                splitsLongChapters: false,
                confirmsDeletion: true
            )
        case .remoteMissingSource:
            BookDetailActionSnapshot(
                isInBookshelf: false,
                sourceState: .missing,
                loginURLState: .absent,
                bookKind: .remote,
                canUpdate: false,
                splitsLongChapters: false,
                confirmsDeletion: false
            )
        case .localTXTShelved:
            BookDetailActionSnapshot(
                isInBookshelf: true,
                sourceState: .missing,
                loginURLState: .absent,
                bookKind: .localTXT,
                canUpdate: false,
                splitsLongChapters: true,
                confirmsDeletion: true
            )
        case .localNonTXTUnshelved:
            BookDetailActionSnapshot(
                isInBookshelf: false,
                sourceState: .missing,
                loginURLState: .absent,
                bookKind: .localEPUB,
                canUpdate: true,
                splitsLongChapters: false,
                confirmsDeletion: false
            )
        }
    }
}

struct BookDetailAcceptanceView: View {
    let acceptanceCase: BookDetailAcceptanceCase

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationStack {
            BookDetailView(snapshot: acceptanceCase.snapshot)
        }
        .accessibilityIdentifier("projection.\(projection)")
    }

    private var projection: String {
        horizontalSizeClass == .regular
            ? "regularSplit"
            : "compactStack"
    }
}

struct BookDetailView: View {
    let snapshot: BookDetailActionSnapshot
    let display: BookDetailDisplay
    let candidate: ShelfBookCandidate?
    let library: ShelfLibrary?
    let preferences: BookDetailPreferencesStore?
    let copyToClipboard: ((String) -> Void)?
    let refreshBookInfo:
        ((ShelfBookItem) async -> ShelfBookItem?)?
    let openReading: ((ShelfBookItem) async -> Void)?
    let editSource: ((String) -> Void)?
    let loginSource: ((String) -> Void)?
    let setSourceVariable: ((String, String) async -> Bool)?
    let setSplitLongChapters:
        ((ShelfBookItem, Bool) async -> ShelfBookItem?)?
    let availableSources: [BookSourceDraft]
    let switchSource:
        ((ShelfBookItem, BookSourceDraft) async -> BookSourceSwitchOutcome)?

    @State private var storedItem: ShelfBookItem?
    @State private var showsSourceSwitch = false
    @State private var switchingSource = false
    @State private var sourceSwitchMessage: String?
    @State private var showsBookVariable = false
    @State private var bookVariableDraft = ""
    @State private var savingBookVariable = false
    @State private var showsSourceVariable = false
    @State private var sourceVariableDraft = ""
    @State private var savingSourceVariable = false
    @State private var savingCanUpdate = false
    @State private var clearingCache = false
    @State private var cacheMessage: String?
    @State private var copiedMessage: String?
    @State private var refreshingBookInfo = false
    @State private var refreshMessage: String?
    @State private var showsDeleteConfirmation = false
    @State private var rebuildingLocalText = false

    init(
        snapshot: BookDetailActionSnapshot,
        display: BookDetailDisplay = .acceptance
    ) {
        self.snapshot = snapshot
        self.display = display
        self.candidate = nil
        self.library = nil
        self.preferences = nil
        self.copyToClipboard = nil
        self.refreshBookInfo = nil
        self.openReading = nil
        self.editSource = nil
        self.loginSource = nil
        self.setSourceVariable = nil
        self.setSplitLongChapters = nil
        self.availableSources = []
        self.switchSource = nil
        _storedItem = State(initialValue: nil)
    }

    init(
        candidate: ShelfBookCandidate,
        library: ShelfLibrary,
        preferences: BookDetailPreferencesStore,
        copyToClipboard: @escaping (String) -> Void,
        refreshBookInfo:
            @escaping (ShelfBookItem) async -> ShelfBookItem?,
        openReading: @escaping (ShelfBookItem) async -> Void,
        editSource: @escaping (String) -> Void,
        loginSource: @escaping (String) -> Void,
        setSourceVariable: @escaping (String, String) async -> Bool,
        setSplitLongChapters:
            @escaping (ShelfBookItem, Bool) async -> ShelfBookItem?,
        availableSources: [BookSourceDraft],
        switchSource:
            @escaping (
                ShelfBookItem,
                BookSourceDraft
            ) async -> BookSourceSwitchOutcome
    ) {
        self.snapshot = .remoteSourceLoginUnshelved
        self.display = BookDetailDisplay(candidate: candidate)
        self.candidate = candidate
        self.library = library
        self.preferences = preferences
        self.copyToClipboard = copyToClipboard
        self.refreshBookInfo = refreshBookInfo
        self.openReading = openReading
        self.editSource = editSource
        self.loginSource = loginSource
        self.setSourceVariable = setSourceVariable
        self.setSplitLongChapters = setSplitLongChapters
        self.availableSources = availableSources
        self.switchSource = switchSource
        _storedItem = State(initialValue: nil)
    }

    private var activeDisplay: BookDetailDisplay {
        storedItem.map { BookDetailDisplay(candidate: $0.candidate) }
            ?? display
    }

    private var activeCandidate: ShelfBookCandidate? {
        storedItem?.candidate ?? candidate
    }

    private var activeSource: BookSourceDraft? {
        guard let sourceID = activeCandidate?.sourceID else { return nil }
        return availableSources.first { $0.sourceURL == sourceID }
    }

    private var switchableSources: [BookSourceDraft] {
        let currentSourceID =
            storedItem?.candidate.sourceID ?? candidate?.sourceID
        return availableSources.filter {
            $0.sourceURL != currentSourceID
                && ($0.importMetadata?.enabled ?? true)
        }
    }

    private var availability: BookDetailActionAvailability {
        let sourceState: BookDetailSourceState
        let loginURLState: BookDetailLoginURLState
        if candidate == nil {
            sourceState = snapshot.sourceState
            loginURLState = snapshot.loginURLState
        } else {
            sourceState = activeSource == nil ? .missing : .present
            loginURLState = Self.loginURLState(activeSource?.loginURL)
        }
        return BookDetailActionAvailability(
            snapshot: BookDetailActionSnapshot(
                isInBookshelf:
                    storedItem?.membership.isInBookshelf
                    ?? snapshot.isInBookshelf,
                sourceState: sourceState,
                loginURLState: loginURLState,
                bookKind:
                    candidate == nil
                    ? snapshot.bookKind
                    : activeBookKind,
                canUpdate: storedItem?.canUpdate ?? snapshot.canUpdate,
                splitsLongChapters:
                    storedItem?.splitsLongChapters
                    ?? snapshot.splitsLongChapters,
                confirmsDeletion:
                    preferences?.value.confirmsDeletion
                    ?? snapshot.confirmsDeletion
            )
        )
    }

    private var activeBookKind: BookDetailBookKind {
        guard activeCandidate?.sourceID == "local-file" else {
            return .remote
        }
        return activeCandidate?.kind
            .localizedCaseInsensitiveContains("txt") == true
            ? .localTXT
            : .localEPUB
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 18) {
                    AsyncImage(
                        url: activeDisplay.coverURL.flatMap(URL.init(string:))
                    ) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(.tint)
                    }
                        .frame(width: 104, height: 142)
                        .background(
                            Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14)
                        )

                    VStack(alignment: .leading, spacing: 9) {
                        Text(activeDisplay.name)
                            .font(.title.bold())
                        Text("作者：\(activeDisplay.author)")
                            .foregroundStyle(.secondary)
                        Text(activeDisplay.kind)
                            .foregroundStyle(.secondary)
                        Text("最新：\(activeDisplay.lastChapter)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("书源：\(activeDisplay.originName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(
                                "label.bookDetail.source"
                            )
                    }
                }

                Divider()

                Text(activeDisplay.intro)
                    .font(.body)

                Button {
                    guard let storedItem else { return }
                    Task {
                        await openReading?(storedItem)
                    }
                } label: {
                    Label("开始阅读", systemImage: "book.pages")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(storedItem == nil || openReading == nil)
                .accessibilityIdentifier("action.bookDetail.startReading")
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("书籍详情")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.bookDetail")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                actionMenu
            }
        }
        .safeAreaInset(edge: .bottom) {
            shelfButton
        }
        .task(id: candidate?.bookURL) {
            guard let candidate, let library else { return }
            if let existing = await library.item(
                forURL: candidate.bookURL
            ) {
                storedItem = existing
            } else {
                storedItem = await library.stage(candidate)
            }
        }
        .sheet(isPresented: $showsSourceSwitch) {
            NavigationStack {
                List(switchableSources) { source in
                    Button {
                        performSourceSwitch(source)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(source.name)
                            Text(source.sourceURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(switchingSource)
                    .accessibilityIdentifier(
                        "action.bookDetail.switchSource.\(source.sourceURL)"
                    )
                }
                .overlay {
                    if switchingSource {
                        ProgressView("正在切换书源…")
                            .padding()
                            .background(
                                .regularMaterial,
                                in: .rect(cornerRadius: 12)
                            )
                    }
                }
                .navigationTitle("切换书源")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            showsSourceSwitch = false
                        }
                    }
                }
                .accessibilityIdentifier("screen.bookSource.switch")
            }
        }
        .sheet(isPresented: $showsBookVariable) {
            VariableEditorSheet(
                title: "设置书籍变量",
                comment: bookVariableComment,
                accessibilityName: "bookVariable",
                value: $bookVariableDraft,
                isSaving: savingBookVariable,
                canSave: storedItem != nil && library != nil,
                cancel: { showsBookVariable = false },
                save: saveBookVariable
            )
        }
        .sheet(isPresented: $showsSourceVariable) {
            VariableEditorSheet(
                title: "设置书源变量",
                comment: sourceVariableComment,
                accessibilityName: "sourceVariable",
                value: $sourceVariableDraft,
                isSaving: savingSourceVariable,
                canSave:
                    activeSource != nil && setSourceVariable != nil,
                cancel: { showsSourceVariable = false },
                save: saveSourceUserVariable
            )
        }
        .alert(
            "换源失败",
            isPresented: Binding(
                get: { sourceSwitchMessage != nil },
                set: { if !$0 { sourceSwitchMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(sourceSwitchMessage ?? "")
        }
        .alert(
            "清除缓存",
            isPresented: Binding(
                get: { cacheMessage != nil },
                set: { if !$0 { cacheMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(cacheMessage ?? "")
        }
        .alert(
            "复制成功",
            isPresented: Binding(
                get: { copiedMessage != nil },
                set: { if !$0 { copiedMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(copiedMessage ?? "")
        }
        .alert(
            "刷新书籍",
            isPresented: Binding(
                get: { refreshMessage != nil },
                set: { if !$0 { refreshMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(refreshMessage ?? "")
        }
        .confirmationDialog(
            "确定将这本书移出书架吗？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("移出书架", role: .destructive) {
                performShelfRemoval()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var shelfButton: some View {
        Button {
            guard let candidate, let library else { return }
            if let storedItem,
               storedItem.membership.isInBookshelf
            {
                if preferences?.value.confirmsDeletion ?? true {
                    showsDeleteConfirmation = true
                } else {
                    performShelfRemoval()
                }
            } else {
                Task {
                    await library.add(candidate)
                    self.storedItem = await library.item(
                        forURL: candidate.bookURL
                    )
                }
            }
        } label: {
            Label(
                availability.shelfAction == .add
                    ? "加入书架"
                    : "移出书架",
                systemImage: availability.shelfAction == .add
                    ? "books.vertical"
                    : "books.vertical.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .padding()
        .background(.bar)
        .accessibilityIdentifier(
            "action.bookDetail.shelf.\(availability.shelfAction.rawValue)"
        )
    }

    private var actionMenu: some View {
        Menu {
            if availability.actions.edit {
                Button {
                    editSource?(activeCandidate?.sourceID ?? "")
                } label: {
                    Label("编辑书源", systemImage: "pencil")
                }
                .accessibilityIdentifier("action.bookDetail.edit")
            }
            if
                storedItem != nil,
                switchSource != nil,
                !switchableSources.isEmpty
            {
                Button {
                    showsSourceSwitch = true
                } label: {
                    Label(
                        "切换书源",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .accessibilityIdentifier("action.bookDetail.switchSource")
            }
            if availability.actions.login {
                Button {
                    guard let sourceID = activeCandidate?.sourceID else {
                        return
                    }
                    loginSource?(sourceID)
                } label: {
                    Label(
                        "登录书源",
                        systemImage: "person.badge.key"
                    )
                }
                .accessibilityIdentifier("action.bookDetail.login")
            }
            if
                activeBookKind == .remote,
                storedItem != nil,
                activeSource != nil,
                refreshBookInfo != nil
            {
                Button {
                    performBookInfoRefresh()
                } label: {
                    Label(
                        refreshingBookInfo
                            ? "正在刷新…"
                            : "刷新书籍信息",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(refreshingBookInfo)
                .accessibilityIdentifier(
                    "action.bookDetail.refresh"
                )
            }
            if availability.actions.setSourceVariable {
                Button {
                    sourceVariableDraft =
                        activeSource?.userVariable ?? ""
                    showsSourceVariable = true
                } label: {
                    Label(
                        "设置书源变量",
                        systemImage: "slider.horizontal.3"
                    )
                }
                .accessibilityIdentifier(
                    "action.bookDetail.setSourceVariable"
                )
            }
            if availability.actions.setBookVariable {
                Button {
                    bookVariableDraft =
                        activeCandidate?.variables["custom"] ?? ""
                    showsBookVariable = true
                } label: {
                    Label(
                        "设置书籍变量",
                        systemImage: "text.badge.plus"
                    )
                }
                .accessibilityIdentifier(
                    "action.bookDetail.setBookVariable"
                )
            }
            if
                let bookURL = activeCandidate?.bookURL,
                !bookURL.isEmpty,
                copyToClipboard != nil
            {
                Button {
                    copyURL(bookURL, label: "书籍 URL")
                } label: {
                    Label("复制书籍 URL", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier(
                    "action.bookDetail.copyBookURL"
                )
            }
            if
                let tocURL = activeCandidate?.tocURL,
                !tocURL.isEmpty,
                copyToClipboard != nil
            {
                Button {
                    copyURL(tocURL, label: "目录 URL")
                } label: {
                    Label(
                        "复制目录 URL",
                        systemImage: "list.bullet.clipboard"
                    )
                }
                .accessibilityIdentifier(
                    "action.bookDetail.copyTOCURL"
                )
            }
            if availability.actions.canUpdate {
                Toggle(
                    isOn: Binding(
                        get: {
                            availability.checked.canUpdate
                        },
                        set: { canUpdate in
                            saveCanUpdate(canUpdate)
                        }
                    )
                ) {
                    Label(
                        "允许更新",
                        systemImage:
                            availability.checked.canUpdate
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                }
                .disabled(
                    storedItem == nil
                        || library == nil
                        || savingCanUpdate
                )
                .accessibilityIdentifier(
                    "action.bookDetail.canUpdate"
                )
            }
            if availability.actions.splitLongChapter {
                Toggle(
                    isOn: Binding(
                        get: {
                            availability.checked.splitLongChapter
                        },
                        set: { enabled in
                            rebuildLocalText(
                                splittingLongChapters: enabled
                            )
                        }
                    )
                ) {
                    Label(
                        rebuildingLocalText
                            ? "正在重建目录…"
                            : "拆分长章节",
                        systemImage:
                            availability.checked.splitLongChapter
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                }
                .disabled(
                    storedItem == nil
                        || setSplitLongChapters == nil
                        || rebuildingLocalText
                )
                .accessibilityIdentifier(
                    "action.bookDetail.splitLongChapter"
                )
            }
            if storedItem != nil {
                Button {
                    clearBookCache()
                } label: {
                    Label(
                        clearingCache ? "正在清除缓存…" : "清除缓存",
                        systemImage: "trash.slash"
                    )
                }
                .disabled(clearingCache || library == nil)
                .accessibilityIdentifier(
                    "action.bookDetail.clearCache"
                )
            }
            if availability.actions.upload {
                action(
                    "上传到远程",
                    id: "upload",
                    systemImage: "icloud.and.arrow.up"
                )
            }
            Toggle(
                isOn: Binding(
                    get: {
                        availability.checked.deleteAlert
                    },
                    set: { enabled in
                        preferences?.setConfirmsDeletion(enabled)
                    }
                )
            ) {
                Label(
                    "删除时确认",
                    systemImage:
                        availability.checked.deleteAlert
                        ? "checkmark.circle.fill"
                        : "circle"
                )
            }
            .disabled(preferences == nil)
            .accessibilityIdentifier(
                "action.bookDetail.deleteAlert"
            )
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("action.bookDetail.more")
    }

    private func copyURL(_ value: String, label: String) {
        copyToClipboard?(value)
        copiedMessage = "\(label)已复制"
    }

    private func performBookInfoRefresh() {
        guard let storedItem, let refreshBookInfo else { return }
        refreshingBookInfo = true
        Task {
            if let refreshed = await refreshBookInfo(storedItem) {
                self.storedItem = refreshed
                refreshMessage = "书籍信息和目录已更新"
            } else {
                refreshMessage = "刷新失败，已保留原有数据"
            }
            refreshingBookInfo = false
        }
    }

    private func performSourceSwitch(_ source: BookSourceDraft) {
        guard let storedItem, let switchSource else { return }
        switchingSource = true
        Task {
            let outcome = await switchSource(storedItem, source)
            switchingSource = false
            switch outcome {
            case .success(let switched):
                self.storedItem = switched
                showsSourceSwitch = false
            case .failure(let message):
                sourceSwitchMessage = message
            }
        }
    }

    private func saveBookVariable() {
        guard
            let storedItem,
            let library
        else { return }
        savingBookVariable = true
        Task {
            let updated = await library.setBookCustomVariable(
                bookVariableDraft,
                bookID: storedItem.id
            )
            if let updated {
                self.storedItem = updated
                showsBookVariable = false
            }
            savingBookVariable = false
        }
    }

    private func saveSourceUserVariable() {
        guard
            let sourceID = activeSource?.sourceURL,
            let setSourceVariable
        else { return }
        savingSourceVariable = true
        Task {
            if await setSourceVariable(
                sourceID,
                sourceVariableDraft
            ) {
                showsSourceVariable = false
            }
            savingSourceVariable = false
        }
    }

    private func saveCanUpdate(_ canUpdate: Bool) {
        guard
            let storedItem,
            let library,
            !savingCanUpdate
        else { return }
        savingCanUpdate = true
        Task {
            if let updated = await library.setCanUpdate(
                canUpdate,
                bookID: storedItem.id
            ) {
                self.storedItem = updated
            }
            savingCanUpdate = false
        }
    }

    private func clearBookCache() {
        guard
            let storedItem,
            let library,
            !clearingCache
        else { return }
        clearingCache = true
        Task {
            let cleared = await library.clearCache(
                bookID: storedItem.id
            )
            cacheMessage = cleared ? "缓存已清除" : "清除缓存失败"
            clearingCache = false
        }
    }

    private func performShelfRemoval() {
        guard
            let storedItem,
            let library,
            storedItem.membership.isInBookshelf
        else { return }
        Task {
            await library.remove(storedItem)
            self.storedItem = await library.item(id: storedItem.id)
        }
    }

    private func rebuildLocalText(
        splittingLongChapters enabled: Bool
    ) {
        guard
            let storedItem,
            let setSplitLongChapters,
            !rebuildingLocalText
        else { return }
        rebuildingLocalText = true
        Task {
            if let updated = await setSplitLongChapters(
                storedItem,
                enabled
            ) {
                self.storedItem = updated
            }
            rebuildingLocalText = false
        }
    }

    private var sourceVariableComment: String {
        variableComment(
            fallback:
                "源变量可在 JS 中通过 source.getVariable() 获取"
        )
    }

    private var bookVariableComment: String {
        variableComment(
            fallback:
                "书籍变量可在 JS 中通过 book.getVariable(\"custom\") 获取"
        )
    }

    private func variableComment(fallback: String) -> String {
        guard
            let data = activeSource?.rawDefinition,
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let comment = root["variableComment"] as? String,
            !comment.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            return fallback
        }
        return "\(comment)\n\(fallback)"
    }

    private func action(
        _ title: String,
        id: String,
        systemImage: String
    ) -> some View {
        Button {
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityIdentifier("action.bookDetail.\(id)")
    }

    private func checkedAction(
        _ title: String,
        id: String,
        checked: Bool
    ) -> some View {
        Toggle(isOn: .constant(checked)) {
            Label(
                title,
                systemImage: checked ? "checkmark.circle.fill" : "circle"
            )
        }
        .accessibilityIdentifier("action.bookDetail.\(id)")
    }

    private static func loginURLState(
        _ value: String?
    ) -> BookDetailLoginURLState {
        guard let value else { return .absent }
        if value.isEmpty { return .blank }
        if value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            return .whitespace
        }
        return .nonblank
    }
}

private struct VariableEditorSheet: View {
    let title: String
    let comment: String
    let accessibilityName: String
    @Binding var value: String
    let isSaving: Bool
    let canSave: Bool
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $value)
                        .frame(minHeight: 180)
                        .accessibilityIdentifier(
                            "field.bookDetail.\(accessibilityName)"
                        )
                } header: {
                    Text("变量内容")
                } footer: {
                    Text(comment)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: cancel)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(isSaving || !canSave)
                        .accessibilityIdentifier(
                            "action.bookDetail."
                                + "\(accessibilityName).save"
                        )
                }
            }
            .overlay {
                if isSaving {
                    ProgressView("正在保存…")
                }
            }
            .accessibilityIdentifier(
                "screen.bookDetail.\(accessibilityName)"
            )
        }
    }
}

private extension BookDetailDisplay {
    init(candidate: ShelfBookCandidate) {
        self.init(
            name: candidate.name,
            author: candidate.author,
            kind: candidate.kind,
            lastChapter: candidate.lastChapter,
            intro: candidate.intro,
            coverURL: candidate.coverURL,
            originName: candidate.originName
        )
    }
}

extension ShelfBookCandidate {
    init(route: SearchBookRoute) {
        self.init(
            name: route.name,
            author: route.author,
            kind: route.kind,
            lastChapter: route.lastChapter,
            intro: route.intro,
            bookURL: route.bookURL,
            tocURL: route.tocURL,
            bookRequestExpression: route.bookRequestExpression,
            coverURL: route.coverURL,
            originName: route.originName,
            sourceID: route.sourceID,
            variables: route.variables
        )
    }
}
