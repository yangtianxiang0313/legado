import Observation

@MainActor
@Observable
public final class AppRouter {
    public var selectedRoot: RootRoute

    private var rootPaths: [RootRoute: [AppRoute]]

    public init(
        selectedRoot: RootRoute = .shelf,
        rootPaths: [RootRoute: [AppRoute]] = [:]
    ) {
        self.selectedRoot = selectedRoot
        self.rootPaths = rootPaths
    }

    public func selectRoot(_ root: RootRoute) {
        selectedRoot = root
    }

    public func reconcileVisibleRoots(_ roots: [RootRoute]) {
        guard roots.contains(selectedRoot) else {
            selectedRoot = .shelf
            return
        }
    }

    public func path(for root: RootRoute) -> [AppRoute] {
        rootPaths[root, default: []]
    }

    public func setPath(_ path: [AppRoute], for root: RootRoute) {
        rootPaths[root] = path
    }

    public func push(_ route: AppRoute, on root: RootRoute? = nil) {
        let destinationRoot = root ?? selectedRoot
        rootPaths[destinationRoot, default: []].append(route)
    }

    public func replaceTop(
        with route: AppRoute,
        on root: RootRoute? = nil
    ) {
        let destinationRoot = root ?? selectedRoot
        var path = rootPaths[destinationRoot, default: []]
        if path.isEmpty {
            path.append(route)
        } else {
            path[path.index(before: path.endIndex)] = route
        }
        rootPaths[destinationRoot] = path
    }

    @discardableResult
    public func pop(on root: RootRoute? = nil) -> AppRoute? {
        let destinationRoot = root ?? selectedRoot
        return rootPaths[destinationRoot, default: []].popLast()
    }
}
