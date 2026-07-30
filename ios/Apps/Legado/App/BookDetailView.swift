import AppUseCases
import SwiftUI

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

    private var availability: BookDetailActionAvailability {
        BookDetailActionAvailability(snapshot: snapshot)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 18) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.tint)
                        .frame(width: 104, height: 142)
                        .background(
                            Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14)
                        )

                    VStack(alignment: .leading, spacing: 9) {
                        Text("星河纪事")
                            .font(.title.bold())
                        Text("作者：林舟")
                            .foregroundStyle(.secondary)
                        Text("科幻 · 冒险")
                            .foregroundStyle(.secondary)
                        Text("最新：第二章 回声")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Text("一段包含 & 与 <转义> 的简介。")
                    .font(.body)

                Button {
                } label: {
                    Label("开始阅读", systemImage: "book.pages")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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
    }

    private var shelfButton: some View {
        Button {
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
                action("编辑", id: "edit", systemImage: "pencil")
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
