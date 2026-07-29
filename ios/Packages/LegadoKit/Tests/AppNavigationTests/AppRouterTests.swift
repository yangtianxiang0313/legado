import AppNavigation
import XCTest

final class AppRouterTests: XCTestCase {
    @MainActor
    func testDefaultsToShelfWithEmptyPath() {
        let router = AppRouter()

        XCTAssertEqual(router.selectedRoot, .shelf)
        XCTAssertEqual(router.path(for: .shelf), [])
    }

    @MainActor
    func testEachRootKeepsAnIndependentPath() {
        let router = AppRouter()

        router.push(.searchBooks, on: .shelf)
        router.selectRoot(.explore)

        XCTAssertEqual(router.path(for: .shelf), [.searchBooks])
        XCTAssertEqual(router.path(for: .explore), [])
    }

    @MainActor
    func testSetAndPopMutateOnlyTheSelectedRoot() {
        let router = AppRouter(selectedRoot: .shelf)
        router.setPath([.searchBooks], for: .shelf)

        XCTAssertEqual(router.pop(), .searchBooks)
        XCTAssertEqual(router.path(for: .shelf), [])
        XCTAssertNil(router.pop())
    }
}
