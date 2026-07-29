import AppNavigation
import SwiftUI

struct RootShellView: View {
    @Bindable var router: AppRouter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            regularShell
                .accessibilityIdentifier("projection.regularSplit")
        } else {
            compactShell
                .accessibilityIdentifier("projection.compactStack")
        }
    }

    private var compactShell: some View {
        TabView(selection: $router.selectedRoot) {
            ForEach(RootRoute.allCases) { root in
                navigationStack(for: root)
                    .tabItem {
                        Label(root.title, systemImage: root.systemImage)
                            .accessibilityIdentifier(root.selectionIdentifier)
                    }
                    .tag(root)
            }
        }
    }

    private var regularShell: some View {
        NavigationSplitView {
            List {
                ForEach(RootRoute.allCases) { root in
                    Button {
                        router.selectRoot(root)
                    } label: {
                        Label(root.title, systemImage: root.systemImage)
                    }
                    .accessibilityIdentifier(root.selectionIdentifier)
                    .listRowBackground(
                        router.selectedRoot == root
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear
                    )
                }
            }
            .navigationTitle("Legado")
        } detail: {
            navigationStack(for: router.selectedRoot)
        }
    }

    private func navigationStack(for root: RootRoute) -> some View {
        NavigationStack(path: pathBinding(for: root)) {
            RootContentView(root: root) {
                router.push(.searchBooks, on: .shelf)
            }
            .navigationDestination(for: AppRoute.self) { route in
                destination(for: route)
            }
        }
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .searchBooks:
            SearchBooksView()
        }
    }

    private func pathBinding(for root: RootRoute) -> Binding<[AppRoute]> {
        Binding(
            get: { router.path(for: root) },
            set: { router.setPath($0, for: root) }
        )
    }
}

private struct RootContentView: View {
    let root: RootRoute
    let openSearch: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: root.systemImage)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)

            Text(root.title)
                .font(.largeTitle.bold())
                .accessibilityIdentifier(root.screenIdentifier)

            Text(root.subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if root == .shelf {
                Button(action: openSearch) {
                    Label("搜索书籍", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("action.shelf.openSearch")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(root.title)
    }
}

private struct SearchBooksView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)

            Text("搜索书籍")
                .font(.title.bold())
                .accessibilityIdentifier("screen.search.books")

            Text("书源搜索能力将在后续 Feature 切片中接入。")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("搜索")
    }
}

private extension RootRoute {
    var title: String {
        switch self {
        case .shelf:
            "书架"
        case .explore:
            "发现"
        case .rss:
            "RSS"
        case .settings:
            "我的"
        }
    }

    var subtitle: String {
        switch self {
        case .shelf:
            "管理与阅读已收藏的书籍"
        case .explore:
            "发现书源与新的阅读内容"
        case .rss:
            "查看订阅内容"
        case .settings:
            "管理书源、备份与应用设置"
        }
    }

    var systemImage: String {
        switch self {
        case .shelf:
            "books.vertical"
        case .explore:
            "safari"
        case .rss:
            "dot.radiowaves.left.and.right"
        case .settings:
            "person.crop.circle"
        }
    }

    var screenIdentifier: String {
        "screen.\(rawValue)"
    }

    var selectionIdentifier: String {
        "action.\(rawValue).select"
    }
}
