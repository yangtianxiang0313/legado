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

    @MainActor
    func testBookDetailCanFollowSearchOnShelfStack() {
        let router = AppRouter(selectedRoot: .shelf)
        let book = SearchBookRoute(
            name: "星河纪事",
            author: "林舟",
            kind: "科幻",
            lastChapter: "第二章",
            intro: "简介",
            bookURL: "book://star-river",
            coverURL: nil,
            originName: "本地科幻书源"
        )

        router.push(.searchBooks)
        router.push(.bookDetail(book))

        XCTAssertEqual(
            router.path(for: .shelf),
            [.searchBooks, .bookDetail(book)]
        )
    }

}
