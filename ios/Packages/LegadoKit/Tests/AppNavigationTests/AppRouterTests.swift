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

    @MainActor
    func testReaderRouteCarriesStableChapterIdentityAndOffset() {
        let target = ReaderRoute(
            bookID: .init(rawValue: "book"),
            chapterID: .init(rawValue: "chapter"),
            characterOffset: 128
        )
        let router = AppRouter()

        router.push(.reader(target))

        XCTAssertEqual(router.path(for: .shelf), [.reader(target)])
        XCTAssertEqual(target.characterOffset, 128)
    }

    @MainActor
    func testReplacingReaderChapterDoesNotGrowNavigationStack() {
        let first = ReaderRoute(
            bookID: .init(rawValue: "book"),
            chapterID: .init(rawValue: "chapter-1")
        )
        let second = ReaderRoute(
            bookID: .init(rawValue: "book"),
            chapterID: .init(rawValue: "chapter-2")
        )
        let router = AppRouter()
        router.push(.searchBooks)
        router.push(.reader(first))

        router.replaceTop(with: .reader(second))

        XCTAssertEqual(
            router.path(for: .shelf),
            [.searchBooks, .reader(second)]
        )
    }

    func testReaderMenuCatalogKeepsSourceAlignedLayersDisjoint() {
        let layers = ReaderMenuLayer.allCases.map {
            Set(ReaderMenuCatalog.actions(in: $0))
        }
        let flattened = layers.reduce(into: Set<ReaderMenuAction>()) {
            result,
            actions in
            XCTAssertTrue(result.isDisjoint(with: actions))
            result.formUnion(actions)
        }

        XCTAssertEqual(flattened, Set(ReaderMenuAction.allCases))
        XCTAssertTrue(
            ReaderMenuCatalog.primary.contains(.openAppearance)
        )
        XCTAssertTrue(ReaderMenuCatalog.primary.contains(.openMore))
        XCTAssertEqual(
            ReaderMenuCatalog.textSelection,
            [
                .selectionReadAloud,
                .selectionAddBookmark,
                .selectionReplace,
                .selectionSearchFullText,
                .selectionLookupDictionary,
            ]
        )
    }

    @MainActor
    func testSourceManagementRoutesKeepStableSourceIdentity() {
        let router = AppRouter(selectedRoot: .settings)

        router.push(.sourceManagement)
        router.push(.sourceEditor("source://primary"))
        router.push(.sourceDebug("source://primary"))

        XCTAssertEqual(
            router.path(for: .settings).map(\.id),
            [
                "source.management",
                "source.editor:source://primary",
                "source.debug:source://primary",
            ]
        )
    }

}
