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
    let openReading: ((ShelfBookItem) async -> Void)?
    let editSource: ((String) -> Void)?
    let availableSources: [BookSourceDraft]
    let switchSource:
        ((ShelfBookItem, BookSourceDraft) async -> BookSourceSwitchOutcome)?

    @State private var storedItem: ShelfBookItem?
    @State private var showsSourceSwitch = false
    @State private var switchingSource = false
    @State private var sourceSwitchMessage: String?

    init(
        snapshot: BookDetailActionSnapshot,
        display: BookDetailDisplay = .acceptance
    ) {
        self.snapshot = snapshot
        self.display = display
        self.candidate = nil
        self.library = nil
        self.openReading = nil
        self.editSource = nil
        self.availableSources = []
        self.switchSource = nil
        _storedItem = State(initialValue: nil)
    }

    init(
        candidate: ShelfBookCandidate,
        library: ShelfLibrary,
        openReading: @escaping (ShelfBookItem) async -> Void,
        editSource: @escaping (String) -> Void,
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
        self.openReading = openReading
        self.editSource = editSource
        self.availableSources = availableSources
        self.switchSource = switchSource
        _storedItem = State(initialValue: nil)
    }

    private var activeDisplay: BookDetailDisplay {
        storedItem.map { BookDetailDisplay(candidate: $0.candidate) }
            ?? display
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
        BookDetailActionAvailability(
            snapshot: BookDetailActionSnapshot(
                isInBookshelf:
                    storedItem?.membership.isInBookshelf
                    ?? snapshot.isInBookshelf,
                sourceState: snapshot.sourceState,
                loginURLState: snapshot.loginURLState,
                bookKind: snapshot.bookKind,
                canUpdate: snapshot.canUpdate,
                splitsLongChapters: snapshot.splitsLongChapters,
                confirmsDeletion: snapshot.confirmsDeletion
            )
        )
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
    }

    private var shelfButton: some View {
        Button {
            guard let candidate, let library else { return }
            Task {
                if let storedItem,
                   storedItem.membership.isInBookshelf
                {
                    await library.remove(storedItem)
                } else {
                    await library.add(candidate)
                }
                self.storedItem = await library.item(
                    forURL: candidate.bookURL
                )
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
                    editSource?(candidate?.sourceID ?? "")
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
                action("登录书源", id: "login", systemImage: "person.badge.key")
            }
            if availability.actions.setSourceVariable {
                action(
                    "设置书源变量",
                    id: "setSourceVariable",
                    systemImage: "slider.horizontal.3"
                )
            }
            if availability.actions.setBookVariable {
                action(
                    "设置书籍变量",
                    id: "setBookVariable",
                    systemImage: "text.badge.plus"
                )
            }
            if availability.actions.canUpdate {
                checkedAction(
                    "允许更新",
                    id: "canUpdate",
                    checked: availability.checked.canUpdate
                )
            }
            if availability.actions.splitLongChapter {
                checkedAction(
                    "拆分长章节",
                    id: "splitLongChapter",
                    checked: availability.checked.splitLongChapter
                )
            }
            if availability.actions.upload {
                action(
                    "上传到远程",
                    id: "upload",
                    systemImage: "icloud.and.arrow.up"
                )
            }
            checkedAction(
                "删除时确认",
                id: "deleteAlert",
                checked: availability.checked.deleteAlert
            )
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("action.bookDetail.more")
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
            bookRequestExpression: route.bookRequestExpression,
            coverURL: route.coverURL,
            originName: route.originName,
            sourceID: route.sourceID,
            variables: route.variables
        )
    }
}
