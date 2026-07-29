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

    @discardableResult
    public func pop(on root: RootRoute? = nil) -> AppRoute? {
        let destinationRoot = root ?? selectedRoot
        return rootPaths[destinationRoot, default: []].popLast()
    }
}
