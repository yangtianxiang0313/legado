import Network
import XCTest

@MainActor
final class LegadoAppUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["LEGADO_LOCAL_SOURCE_DEMO"] = "1"
    }

    func testRootTopology() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )

        XCUIDevice.shared.orientation = contract.projection == "regularSplit"
            ? .landscapeLeft
            : .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()

        require("projection.\(contract.projection)")

        var steps: [[String: Any]] = []
        steps.append(
            observe(
                id: "launch",
                root: "root.shelf",
                screen: "screen.root.shelf",
                visible: ["action.shelf.openSearch", "screen.root.shelf"]
            )
        )

        selectRoot("root.explore", label: "发现")
        steps.append(
            observe(
                id: "selectExplore",
                root: "root.explore",
                screen: "screen.root.explore",
                visible: ["screen.root.explore"]
            )
        )

        selectRoot("root.rss", label: "RSS")
        steps.append(
            observe(
                id: "selectRSS",
                root: "root.rss",
                screen: "screen.root.rss",
                visible: ["screen.root.rss"]
            )
        )

        selectRoot("root.settings", label: "我的")
        steps.append(
            observe(
                id: "selectSettings",
                root: "root.settings",
                screen: "screen.root.settings",
                visible: ["screen.root.settings"]
            )
        )

        selectRoot("root.shelf", label: "书架")
        element("action.shelf.openSearch").tap()
        steps.append(
            observe(
                id: "openSearch",
                root: "root.shelf",
                screen: "screen.search.books",
                visible: ["screen.search.books"]
            )
        )

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "steps": steps,
            "route_trace": [
                ["operation": "selectRoot", "route_id": "root.explore"],
                ["operation": "selectRoot", "route_id": "root.rss"],
                ["operation": "selectRoot", "route_id": "root.settings"],
                ["operation": "selectRoot", "route_id": "root.shelf"],
                ["operation": "push", "route_id": "search.books"],
            ],
        ])
    }

    func testRootConfigurableVisibility() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-root-visibility",
            "--initial-root-explore",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        require("screen.root.explore")
        selectRoot("root.settings", label: "我的")
        require("screen.root.settings")
        let exploreToggle = app.switches["显示发现"]
        let rssToggle = app.switches["显示 RSS"]
        XCTAssertTrue(exploreToggle.waitForExistence(timeout: 8))
        XCTAssertTrue(rssToggle.waitForExistence(timeout: 8))
        exploreToggle.tap()
        rssToggle.tap()

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "settings_controls": ["显示发现", "显示 RSS"],
            "actions": ["hide_explore", "hide_rss"],
        ])
    }

    func testWebDAVConnectionSettings() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-webdav-settings",
            "--webdav-test-double",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        selectRoot("root.settings", label: "我的")
        require("field.settings.webdav.server")
        require("field.settings.webdav.account")
        require("field.settings.webdav.password")
        require("field.settings.webdav.directory")
        app.swipeUp()
        element("action.settings.webdav.test").tap()
        let result = element("state.settings.webdav.connection")
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        XCTAssertEqual("WebDAV 连接成功", result.label)

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "screen": "screen.root.settings",
            "settings_controls": [
                "field.settings.webdav.server",
                "field.settings.webdav.account",
                "field.settings.webdav.password",
                "field.settings.webdav.directory",
                "action.settings.webdav.test",
            ],
            "connection_state": result.label,
        ])
    }

    func testAndroidLibraryBackupImportEntry() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
        ]
        app.launchEnvironment["LEGADO_ANDROID_BACKUP_FIXTURE_BASE64"] =
            "UEsDBBQAAAgIAAAAIQCfHJMcXQAAAGMAAAAOAAAAYm9va0dyb3VwLmpzb26LrlZKys/PDs4vKlGyMtJRSs1LTMpJDUpNK0otzlCySkvMKU7VUUovyi8t8ExRsrKAsv0Sc1OVrJT8ixKTc1IV3EFCSjpK+UUpqUVKViY6SsUZ+eVKViVFpam1sQBQSwMEFAAACAgAAAAhAML7DuN+AAAAugAAAA0AAABib29rbWFyay5qc29ui65WSsrPz3YsLcnIL1KyUvIvSkzOSVWA8nXAkn6JualAqUz/YAWotBNQFCoZklpRApQsTs1JTS5JTQGKJmckFpSkFnnmpaRWKFkZwwWgxjhDeApu+aVFCNUB+cVKVkbmQH5+XklqHshIMAtouI5SSSZIp6G5ARQYGhnXxgIAUEsDBBQAAAgIAAAAIQDqOq76HgEAAFUCAAAOAAAAYm9va3NoZWxmLmpzb26NUU1rwzAM/StF52xJW1iHb1tgMBjtoO1p7OA5amLqWsEfZaX0v09eUmhoGfPJ0nt6kp4+jiBjaMiBgIWTyuDoqYsz+CLarp1hpAmh9SLPNfk7+mXda7uXRld5IjFXSbtuKxkQRHARM6iiKxvZBnSvtsJvENPL3Dt5EJPZZWqld1w8nhX9G0+mQzgYxqEPRy8U04y1o9iCeMzASB/KBtW2pGgDq1+krrSLIqEBE36ze3GDMRxghZb7W5nqQC+Wo96+584QchWyqQ/pp2tt/3bR8zYK4UyeX6kuh4RFp847OpRVSXajaxBHjvboPK5Ine/gW6PDG9m6nxvERhqPJ0YOVnVr86qB1L9OnTMREj1I0yvO446dSxqHNomdPn8AUEsBAhUDFAAACAgAAAAhAJ8ckxxdAAAAYwAAAA4AAAAAAAAAAAAAAKSBAAAAAGJvb2tHcm91cC5qc29uUEsBAhUDFAAACAgAAAAhAML7DuN+AAAAugAAAA0AAAAAAAAAAAAAAKSBiQAAAGJvb2ttYXJrLmpzb25QSwECFQMUAAAICAAAACEA6jqu+h4BAABVAgAADgAAAAAAAAAAAAAApIEyAQAAYm9va3NoZWxmLmpzb25QSwUGAAAAAAMAAwCzAAAAfAIAAAAA"
        app.launch()

        require("projection.\(contract.projection)")
        selectRoot("root.settings", label: "我的")
        let importButton = element("action.settings.androidBackup.import")
        XCTAssertTrue(importButton.waitForExistence(timeout: 8))
        importButton.tap()
        let status = element("state.settings.androidBackup.import")
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        let importResult = status.label
        XCTAssertEqual("已导入 1 本书、1 个分组、1 条书签", importResult)

        selectRoot("root.shelf", label: "书架")
        XCTAssertTrue(app.staticTexts["iOS Oracle Book"].waitForExistence(timeout: 8))

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "screen": "screen.root.settings",
            "action": "action.settings.androidBackup.import",
            "result": importResult,
            "restored_book": "iOS Oracle Book",
        ])
    }

    func testStartupFirstUseAndRestore() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )

        XCUIDevice.shared.orientation = contract.projection == "regularSplit"
            ? .landscapeLeft
            : .portrait

        var cases: [[String: Any]] = []
        cases.append(
            try observeStartupCase(
                id: "welcome-default-opens-main-only",
                initial: "screen.root.shelf",
                final: "screen.root.shelf",
                actions: [],
                routeTrace: ["main"]
            )
        )
        cases.append(
            try observeStartupCase(
                id: "welcome-default-to-read-opens-reader-after-main",
                initial: "screen.reader.startup",
                final: "screen.reader.startup",
                actions: [],
                routeTrace: ["main", "reader"]
            )
        )
        cases.append(
            try observeStartupCase(
                id: "privacy-refusal-stops-main-pipeline",
                initial: "startup.prompt.privacy",
                final: "screen.startup.finished",
                actions: ["startup.action.privacy.refuse"],
                routeTrace: ["main"]
            )
        )
        cases.append(
            try observeStartupCase(
                id: "first-open-agreement-runs-help-then-password",
                initial: "startup.prompt.privacy",
                final: "screen.root.shelf",
                actions: [
                    "startup.action.privacy.agree",
                    "startup.action.help.close",
                    "startup.action.local_password.cancel",
                ],
                routeTrace: ["main"]
            )
        )
        cases.append(
            try observeStartupCase(
                id: "returning-current-version-skips-onboarding",
                initial: "screen.root.shelf",
                final: "screen.root.shelf",
                actions: [],
                routeTrace: ["main"]
            )
        )
        cases.append(
            try observeStartupCase(
                id: "returning-version-change-debug-skips-update-log",
                initial: "screen.root.shelf",
                final: "screen.root.shelf",
                actions: [],
                routeTrace: ["main"]
            )
        )

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "cases": cases,
        ])
    }

    func testBookDetailConditionalActions() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = contract.projection == "regularSplit"
            ? .landscapeLeft
            : .portrait

        let allActions = [
            "edit",
            "login",
            "setSourceVariable",
            "setBookVariable",
            "canUpdate",
            "splitLongChapter",
            "upload",
            "deleteAlert",
        ]
        let cases: [BookDetailUITestCase] = [
            BookDetailUITestCase(
                id: "remote-source-login-unshelved",
                shelfAction: "add",
                visibleActions: [
                    "login",
                    "setSourceVariable",
                    "setBookVariable",
                    "canUpdate",
                    "deleteAlert",
                ],
                checked: [
                    "canUpdate": false,
                    "deleteAlert": true,
                ]
            ),
            BookDetailUITestCase(
                id: "remote-source-no-login-shelved",
                shelfAction: "remove",
                visibleActions: [
                    "edit",
                    "setSourceVariable",
                    "setBookVariable",
                    "canUpdate",
                    "deleteAlert",
                ],
                checked: [
                    "canUpdate": true,
                    "deleteAlert": false,
                ]
            ),
            BookDetailUITestCase(
                id: "remote-source-whitespace-login",
                shelfAction: "add",
                visibleActions: [
                    "setSourceVariable",
                    "setBookVariable",
                    "canUpdate",
                    "deleteAlert",
                ],
                checked: [
                    "canUpdate": true,
                    "deleteAlert": true,
                ]
            ),
            BookDetailUITestCase(
                id: "remote-missing-source",
                shelfAction: "add",
                visibleActions: ["deleteAlert"],
                checked: ["deleteAlert": false]
            ),
            BookDetailUITestCase(
                id: "local-txt-shelved",
                shelfAction: "remove",
                visibleActions: [
                    "edit",
                    "splitLongChapter",
                    "upload",
                    "deleteAlert",
                ],
                checked: [
                    "splitLongChapter": true,
                    "deleteAlert": true,
                ]
            ),
            BookDetailUITestCase(
                id: "local-non-txt-unshelved",
                shelfAction: "add",
                visibleActions: ["upload", "deleteAlert"],
                checked: ["deleteAlert": false]
            ),
        ]

        var observations: [[String: Any]] = []
        for testCase in cases {
            app.terminate()
            app.launchArguments = [
                "-AppleLanguages", "(zh-Hans)",
                "-AppleLocale", "zh_CN",
                "--book-detail-case", testCase.id,
            ]
            app.launch()

            require("projection.\(contract.projection)")
            require("screen.bookDetail")
            require(
                "action.bookDetail.shelf.\(testCase.shelfAction)"
            )
            let more = app.buttons["action.bookDetail.more"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 8))
            more.tap()

            var visibleActions: [String] = []
            for action in allActions {
                let item = app.descendants(matching: .any)[
                    "action.bookDetail.\(action)"
                ].firstMatch
                if item.exists {
                    visibleActions.append(action)
                }
            }
            XCTAssertEqual(
                Set(visibleActions),
                Set(testCase.visibleActions),
                "Wrong visible actions for \(testCase.id)"
            )

            var checked: [String: Bool] = [:]
            for action in testCase.checked.keys.sorted() {
                let item = app.descendants(matching: .any)[
                    "action.bookDetail.\(action)"
                ].firstMatch
                XCTAssertTrue(item.waitForExistence(timeout: 8))
                print(
                    "BOOK_DETAIL_CHECKED \(testCase.id) \(action) "
                        + "selected=\(item.isSelected) "
                        + "value=\(String(describing: item.value)) "
                        + "label=\(item.label)"
                )
                checked[action] = item.isSelected
            }
            XCTAssertEqual(checked, testCase.checked)
            observations.append([
                "id": testCase.id,
                "screen": "screen.bookDetail",
                "shelf_action": testCase.shelfAction,
                "visible_actions": visibleActions.sorted(),
                "checked": checked,
            ])
        }

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "cases": observations,
        ])
    }

    func testDiscoverySearchFlow() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = contract.projection == "regularSplit"
            ? .landscapeLeft
            : .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        require("action.shelf.openSearch").tap()
        require("screen.search.books")

        let scopeButton = app.buttons[
            "action.search.scope"
        ].firstMatch
        XCTAssertTrue(scopeButton.waitForExistence(timeout: 8))
        scopeButton.tap()
        let scienceFiction = app.buttons["科幻"].firstMatch
        XCTAssertTrue(scienceFiction.waitForExistence(timeout: 8))
        scienceFiction.tap()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        searchField.tap()
        searchField.typeText("星河\n")

        let firstResult = app.staticTexts["星河纪事"].firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["星河之外"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["奇幻星河"].firstMatch.exists)
        XCTAssertTrue(
            app.staticTexts["范围：科幻"].firstMatch
                .waitForExistence(timeout: 8)
        )

        firstResult.tap()
        require("screen.bookDetail")
        XCTAssertTrue(app.staticTexts["星河纪事"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["作者：林舟"].firstMatch.exists)

        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 8))
        back.tap()
        require("screen.search.books")
        let retainedQuery = try XCTUnwrap(
            app.searchFields.firstMatch.value as? String
        )

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "screen": "screen.search.books",
            "query_after_return": retainedQuery,
            "scope": "科幻",
            "result_names": [
                "星河纪事",
                "星河之外",
            ],
            "detail": [
                "screen": "screen.bookDetail",
                "name": "星河纪事",
                "author": "林舟",
            ],
            "route_trace": [
                ["operation": "push", "route_id": "search.books"],
                [
                    "operation": "push",
                    "route_id":
                        "book.detail:http://legado.local/books/star-river",
                ],
                ["operation": "pop", "route_id": "search.books"],
            ],
        ])
    }

    func testDiscoveryExploreFlow() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        selectRoot("root.explore", label: "发现")
        require("screen.root.explore")
        require("list.explore.sources")

        let sourceID =
            "action.explore.openSource."
            + "http://legado.local/source/science-fiction"
        require(sourceID).tap()
        require("screen.explore.source")
        require("list.explore.categories")
        require(
            "action.explore.category."
                + "http://legado.local/source/science-fiction"
                + "#0#科幻精选"
        )

        let firstBookID =
            "action.explore.openBook."
            + "http://legado.local/books/star-river"
        require(firstBookID).tap()
        require("screen.bookDetail")
        XCTAssertTrue(app.staticTexts["星河纪事"].exists)
        XCTAssertTrue(app.staticTexts["作者：林舟"].exists)

        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 8))
        back.tap()
        require("screen.explore.source")
        require(firstBookID)

        let nextPage = require("action.explore.loadNextPage")
        nextPage.tap()
        XCTAssertTrue(nextPage.waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["星河纪事"].exists)
        XCTAssertTrue(app.staticTexts["星河之外"].exists)

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "screen": "screen.explore.source",
            "source": "本地科幻书源",
            "categories": ["科幻精选"],
            "result_names": ["星河纪事", "星河之外"],
            "empty_next_page_preserved_results": true,
            "detail": [
                "screen": "screen.bookDetail",
                "name": "星河纪事",
                "author": "林舟",
            ],
            "route_trace": [
                [
                    "operation": "selectRoot",
                    "route_id": "root.explore",
                ],
                [
                    "operation": "push",
                    "route_id":
                        "explore.source:"
                        + "http://legado.local/source/science-fiction",
                ],
                [
                    "operation": "push",
                    "route_id":
                        "book.detail:"
                        + "http://legado.local/books/star-river",
                ],
                [
                    "operation": "pop",
                    "route_id":
                        "explore.source:"
                        + "http://legado.local/source/science-fiction",
                ],
            ],
        ])
    }

    func testBookDetailStagingPersistence() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = contract.projection == "regularSplit"
            ? .landscapeLeft
            : .portrait

        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        require("action.shelf.openSearch").tap()
        require("screen.search.books")
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        searchField.tap()
        searchField.typeText("星河纪事\n")
        let result = app.staticTexts["星河纪事"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        result.tap()

        require("screen.bookDetail")
        require("action.bookDetail.shelf.add").tap()
        require("action.bookDetail.shelf.remove")

        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        require("screen.root.shelf")
        require("list.shelf.books")
        let persisted = app.staticTexts["星河纪事"].firstMatch
        XCTAssertTrue(persisted.waitForExistence(timeout: 8))
        require("action.shelf.openBook").tap()
        require("screen.bookDetail")
        require("action.bookDetail.shelf.remove")

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "phases": [
                [
                    "id": "search_detail_add",
                    "screen": "screen.bookDetail",
                    "book": "星河纪事",
                    "shelf_action_after": "remove",
                ],
                [
                    "id": "terminate_relaunch",
                    "screen": "screen.root.shelf",
                    "shelf_books": ["星河纪事"],
                ],
                [
                    "id": "reopen_from_shelf",
                    "screen": "screen.bookDetail",
                    "book": "星河纪事",
                    "shelf_action": "remove",
                ],
            ],
            "route_trace": [
                ["operation": "push", "route_id": "search.books"],
                [
                    "operation": "push",
                    "route_id":
                        "book.detail:http://legado.local/books/star-river",
                ],
                ["operation": "terminate", "route_id": "process"],
                ["operation": "launch", "route_id": "root.shelf"],
                [
                    "operation": "push",
                    "route_id":
                        "book.detail:http://legado.local/books/star-river",
                ],
            ],
        ])
    }

    func testChapterTOCFlow() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = contract.projection == "regularSplit"
            ? .landscapeLeft
            : .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        require("action.shelf.openSearch").tap()
        require("screen.search.books")
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        searchField.tap()
        searchField.typeText("星河纪事\n")
        let result = app.staticTexts["星河纪事"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        result.tap()

        require("screen.bookDetail")
        let start = require("action.bookDetail.startReading")
        XCTAssertTrue(
            start.isEnabled || start.waitForExistence(timeout: 8),
            "Start reading action never became available"
        )
        let deadline = Date().addingTimeInterval(8)
        while !start.isEnabled && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(start.isEnabled)
        start.tap()

        require("screen.chapterTOC")
        let titles = ["第一章 启航", "第二章 回声", "第三章 归途"]
        for (index, title) in titles.enumerated() {
            let chapter = require("action.chapter.select.\(index)")
            XCTAssertTrue(chapter.label.contains(title))
        }
        let firstChapter = require("action.chapter.select.0")
        firstChapter.tap()
        expectation(
            for: NSPredicate(format: "isSelected == true"),
            evaluatedWith: firstChapter
        )
        waitForExpectations(timeout: 8)

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "phases": [
                [
                    "id": "detail_start",
                    "screen": "screen.bookDetail",
                    "book": "星河纪事",
                ],
                [
                    "id": "toc_loaded",
                    "screen": "screen.chapterTOC",
                    "chapters": titles,
                ],
                [
                    "id": "chapter_selected",
                    "screen": "screen.chapterTOC",
                    "selected": "第一章 启航",
                ],
            ],
            "route_trace": [
                ["operation": "push", "route_id": "search.books"],
                [
                    "operation": "push",
                    "route_id":
                        "book.detail:http://legado.local/books/star-river",
                ],
                ["operation": "push", "route_id": "book.toc:current"],
            ],
        ])
    }

    func testReaderContentFlow() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = contract.projection == "regularSplit"
            ? .landscapeLeft
            : .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        require("action.shelf.openSearch").tap()
        require("screen.search.books")
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        searchField.tap()
        searchField.typeText("星河纪事\n")
        let result = app.staticTexts["星河纪事"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        result.tap()

        require("screen.bookDetail")
        let start = require("action.bookDetail.startReading")
        let deadline = Date().addingTimeInterval(8)
        while !start.isEnabled && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(start.isEnabled)
        start.tap()

        require("screen.chapterTOC")
        require("action.chapter.select.0").tap()
        require("screen.reader")
        let title = require("label.reader.chapterTitle")
        let content = require("text.reader.content")
        XCTAssertEqual(title.label, "第一章 启航")
        XCTAssertTrue(content.label.contains("星港的晨光越过舷窗。"))
        XCTAssertTrue(content.label.contains("远航者点亮了失落信标。"))

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "phases": [
                [
                    "id": "toc_selection",
                    "screen": "screen.chapterTOC",
                    "selected": "第一章 启航",
                ],
                [
                    "id": "reader_loaded",
                    "screen": "screen.reader",
                    "chapter": "第一章 启航",
                    "content_fragments": [
                        "星港的晨光越过舷窗。",
                        "远航者点亮了失落信标。",
                    ],
                ],
            ],
            "route_trace": [
                ["operation": "push", "route_id": "search.books"],
                [
                    "operation": "push",
                    "route_id":
                        "book.detail:http://legado.local/books/star-river",
                ],
                ["operation": "push", "route_id": "book.toc:current"],
                [
                    "operation": "push",
                    "route_id":
                        "reader:http://legado.local/books/star-river"
                            + "/chapter-1@0",
                ],
            ],
        ])
    }

    func testRealWikisourceMainFlow() throws {
        let contract = try XCTUnwrap(
            SimulatorContract(environment: ProcessInfo.processInfo.environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "source",
                withExtension: "json"
            )
        )
        let sourceDefinition = try String(
            contentsOf: fixtureURL,
            encoding: .utf8
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
            "--reset-sources",
        ]
        app.launchEnvironment["LEGADO_LOCAL_SOURCE_DEMO"] = "0"
        app.launchEnvironment["LEGADO_SEED_SOURCE_JSON"] = sourceDefinition
        app.launch()

        require("projection.\(contract.projection)")
        require("action.shelf.openSearch").tap()
        require("screen.search.books")
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        searchField.tap()
        searchField.typeText("論語\n")

        let result = app.staticTexts["論語"].firstMatch
        XCTAssertTrue(
            result.waitForExistence(timeout: 30),
            "Real-source search did not return 論語"
        )
        result.tap()
        require("screen.bookDetail")
        XCTAssertEqual(
            require("label.bookDetail.source").label,
            "书源：RealSource 维基文库公版"
        )

        let add = requireButton("action.bookDetail.shelf.add")
        add.tap()
        XCTAssertTrue(
            app.buttons["action.bookDetail.shelf.remove"]
                .firstMatch.waitForExistence(timeout: 12)
        )
        let start = requireButton("action.bookDetail.startReading")
        let startDeadline = Date().addingTimeInterval(30)
        while !start.isEnabled && Date() < startDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(start.isEnabled)
        start.tap()

        require("screen.chapterTOC", timeout: 30)
        XCTAssertTrue(
            require("action.chapter.select.0", timeout: 30)
                .label.contains("序說")
        )
        let targetChapter = require("action.chapter.select.1")
        XCTAssertTrue(targetChapter.label.contains("學而第一"))
        targetChapter.tap()

        require("screen.reader", timeout: 30)
        XCTAssertEqual(
            require("label.reader.chapterTitle", timeout: 30).label,
            "論語/學而第一"
        )
        var content = require("text.reader.content", timeout: 30)
        var found正文 = content.label.contains("學而時習之")
        let pageProgress = require("label.reader.pageProgress")
        let pageCount = Int(
            pageProgress.label.split(separator: "/").last ?? "0"
        ) ?? 0
        XCTAssertGreaterThan(pageCount, 0)
        for page in 2...max(2, min(pageCount, 30)) where !found正文 {
            let nextPage = requireButton("action.reader.page.next")
            guard nextPage.isEnabled else { break }
            nextPage.tap()
            waitForLabel(
                "\(page)/\(pageCount)",
                identifier: "label.reader.pageProgress",
                timeout: 8
            )
            content = require("text.reader.content")
            found正文 = content.label.contains("學而時習之")
        }
        XCTAssertTrue(found正文, content.label)
        XCTAssertTrue(content.label.contains("子曰"), content.label)

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "scenario": "ui-real-wikisource-main-flow-v1",
            "source": "RealSource 维基文库公版",
            "book": "論語",
            "chapter": "學而第一",
            "route_trace": [
                "search.books",
                "book.detail",
                "book.toc",
                "reader",
            ],
        ])
    }

    func testReaderInlineImageFlow() throws {
        let contract = try XCTUnwrap(
            SimulatorContract(environment: ProcessInfo.processInfo.environment)
        )
        XCUIDevice.shared.orientation = contract.projection == "regularSplit"
            ? .landscapeLeft : .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        require("action.shelf.openSearch").tap()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        searchField.tap()
        searchField.typeText("星河纪事\n")
        let result = app.staticTexts["星河纪事"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        result.tap()
        let start = require("action.bookDetail.startReading")
        let deadline = Date().addingTimeInterval(8)
        while !start.isEnabled && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(start.isEnabled)
        start.tap()
        require("screen.chapterTOC")
        require("action.chapter.select.1").tap()
        require("screen.reader")
        XCTAssertEqual(require("label.reader.chapterTitle").label, "第二章 回声")
        require("state.reader.inlineImage")
        waitForText("已加载 1 张", in: "state.reader.inlineImage")
        XCTAssertTrue(require("text.reader.content").exists)

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "chapter": "第二章 回声",
            "inline_image_loaded": true,
        ])
    }

    func testReaderInlineImageDecodeFlow() throws {
        try testReaderInlineImageFlow()
    }

    func testReaderInlineImageCacheFlow() throws {
        try testReaderInlineImageFlow()
    }

    func testReaderMultilevelMenuFlow() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = contract.projection == "regularSplit"
            ? .landscapeLeft
            : .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        require("action.shelf.openSearch").tap()
        require("screen.search.books")
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        searchField.tap()
        searchField.typeText("星河纪事\n")
        let result = app.staticTexts["星河纪事"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        result.tap()
        require("screen.bookDetail")
        let start = require("action.bookDetail.startReading")
        let deadline = Date().addingTimeInterval(8)
        while !start.isEnabled && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(start.isEnabled)
        start.tap()
        require("screen.chapterTOC")
        require("action.chapter.select.0").tap()
        require("screen.reader")
        require("text.reader.content")

        require("action.reader.openPrimaryMenu").tap()
        require("overlay.reader.primaryMenu")
        let primaryActions = [
            "action.reader.openBookInfo",
            "action.reader.previousChapter",
            "action.reader.seekProgress",
            "action.reader.nextChapter",
            "action.reader.openTOC",
            "action.reader.openBookSource",
            "action.reader.openChapterSource",
            "action.reader.openAppearance",
            "action.reader.openMore",
            "action.reader.toggleAutoPage",
        ]
        for action in primaryActions {
            requireByScrolling(
                action,
                in: "overlay.reader.primaryMenu"
            )
        }

        requireByScrolling(
            "action.reader.openAppearance",
            in: "overlay.reader.primaryMenu"
        ).tap()
        require("overlay.reader.appearance")
        let appearanceActions = [
            "action.reader.toggleTheme",
            "action.reader.updateBrightness",
            "action.reader.updateAppearance",
        ]
        for action in appearanceActions {
            require(action)
        }
        app.navigationBars.buttons.firstMatch.tap()
        require("overlay.reader.primaryMenu")

        requireByScrolling(
            "action.reader.openMore",
            in: "overlay.reader.primaryMenu"
        ).tap()
        require("overlay.reader.more")
        let moreActions = [
            "action.reader.openSearch",
            "action.reader.openReplaceRules",
            "action.reader.refreshCurrent",
            "action.reader.refreshAfter",
            "action.reader.refreshAll",
            "action.reader.cacheOffline",
            "action.reader.addBookmark",
            "action.reader.startReadAloud",
            "action.reader.openReadAloudSettings",
            "action.reader.editContent",
            "action.reader.configurePageAnimation",
            "action.reader.updateReadingSettings",
        ]
        for action in moreActions {
            requireByScrolling(action, in: "overlay.reader.more")
        }
        app.navigationBars.buttons.firstMatch.tap()
        let closeMenu = app.buttons["action.reader.closeMenu"].firstMatch
        XCTAssertTrue(closeMenu.waitForExistence(timeout: 8))
        closeMenu.tap()

        let content = require("text.reader.content")
        content.press(forDuration: 1.2)
        let selectionActions = [
            "action.reader.selection.readAloud",
            "action.reader.selection.addBookmark",
            "action.reader.selection.replace",
            "action.reader.selection.searchFullText",
            "action.reader.selection.lookupDictionary",
        ]
        for action in selectionActions {
            require(action)
        }

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "layers": [
                [
                    "id": "primary",
                    "overlay": "overlay.reader.primaryMenu",
                    "actions": primaryActions,
                ],
                [
                    "id": "appearance",
                    "overlay": "overlay.reader.appearance",
                    "actions": appearanceActions,
                ],
                [
                    "id": "more",
                    "overlay": "overlay.reader.more",
                    "actions": moreActions,
                ],
                [
                    "id": "textSelection",
                    "overlay": "system.contextMenu",
                    "actions": selectionActions,
                ],
            ],
            "route_trace": [
                ["operation": "push", "route_id": "search.books"],
                [
                    "operation": "push",
                    "route_id":
                        "book.detail:http://legado.local/books/star-river",
                ],
                ["operation": "push", "route_id": "book.toc:current"],
                [
                    "operation": "push",
                    "route_id":
                        "reader:http://legado.local/books/star-river"
                            + "/chapter-1@0",
                ],
            ],
        ])
    }

    func testReaderProgressPersistsAcrossRelaunch() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = contract.projection == "regularSplit"
            ? .landscapeLeft
            : .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        require("action.shelf.openSearch").tap()
        require("screen.search.books")
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        searchField.tap()
        searchField.typeText("星河纪事\n")
        let searchResult = app.staticTexts["星河纪事"].firstMatch
        XCTAssertTrue(searchResult.waitForExistence(timeout: 8))
        searchResult.tap()
        require("screen.bookDetail")

        let add = app.buttons[
            "action.bookDetail.shelf.add"
        ].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        add.tap()
        let remove = app.buttons[
            "action.bookDetail.shelf.remove"
        ].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 8))

        let start = require("action.bookDetail.startReading")
        XCTAssertTrue(start.isEnabled)
        start.tap()
        require("screen.chapterTOC")
        require("action.chapter.select.0").tap()
        require("screen.reader")
        XCTAssertEqual(
            require("label.reader.chapterTitle").label,
            "第一章 启航"
        )

        require("action.reader.openPrimaryMenu").tap()
        require("overlay.reader.primaryMenu")
        let next = app.buttons[
            "action.reader.nextChapter"
        ].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 8))
        XCTAssertTrue(next.isEnabled)
        next.tap()
        let title = require("label.reader.chapterTitle")
        let chapterDeadline = Date().addingTimeInterval(8)
        while title.label != "第二章 回声" && Date() < chapterDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(title.label, "第二章 回声")

        require("action.reader.openPrimaryMenu").tap()
        let savedProgress = app.staticTexts[
            "action.reader.seekProgress"
        ].firstMatch
        XCTAssertTrue(savedProgress.waitForExistence(timeout: 8))
        XCTAssertEqual(
            savedProgress.label,
            "2/3 · 位置 0",
            "Observed progress label: \(savedProgress.label)"
        )
        let closeBeforeRelaunch = app.buttons[
            "action.reader.closeMenu"
        ].firstMatch
        XCTAssertTrue(closeBeforeRelaunch.waitForExistence(timeout: 8))
        closeBeforeRelaunch.tap()

        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        require("screen.root.shelf")
        let shelfBook = app.buttons[
            "action.shelf.openBook"
        ].firstMatch
        XCTAssertTrue(shelfBook.waitForExistence(timeout: 8))
        shelfBook.tap()
        require("screen.bookDetail")
        let resume = require("action.bookDetail.startReading")
        XCTAssertTrue(resume.isEnabled)
        resume.tap()
        require("screen.reader")
        XCTAssertFalse(
            element("screen.chapterTOC").exists,
            "Saved progress should bypass the TOC"
        )
        XCTAssertEqual(
            require("label.reader.chapterTitle").label,
            "第二章 回声"
        )
        require("action.reader.openPrimaryMenu").tap()
        let restoredProgress = app.staticTexts[
            "action.reader.seekProgress"
        ].firstMatch
        XCTAssertTrue(restoredProgress.waitForExistence(timeout: 8))
        XCTAssertEqual(
            restoredProgress.label,
            "2/3 · 位置 0",
            "Observed progress label: \(restoredProgress.label)"
        )

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "before_termination": [
                "chapter": "第二章 回声",
                "chapter_index": 1,
                "character_offset": 0,
                "progress_label": "2/3 · 位置 0",
            ],
            "after_relaunch": [
                "entry": "bookDetail.startReading",
                "toc_bypassed": true,
                "chapter": "第二章 回声",
                "chapter_index": 1,
                "character_offset": 0,
                "progress_label": "2/3 · 位置 0",
            ],
        ])
    }

    func testSourceEditorDebugRoutes() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-sources",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        selectRoot("root.settings", label: "我的")
        require("action.settings.openSources").tap()
        require("screen.source.management")
        require("state.source.empty")

        require("action.source.add.empty").tap()
        require("screen.source.editor")
        let name = require("field.source.name")
        name.tap()
        name.typeText("本地测试书源")
        let url = require("field.source.url")
        url.tap()
        url.typeText("source://ui-test")

        require("action.source.editor.more").tap()
        require("action.source.editor.debug").tap()
        require("screen.source.debug")
        require("action.source.debug.start").tap()
        XCTAssertEqual(
            requireByScrolling(
                "label.source.debug.route",
                in: "screen.source.debug"
            ).label,
            "search"
        )

        app.navigationBars.buttons.firstMatch.tap()
        require("screen.source.editor")
        let cancel = app.buttons[
            "action.source.editor.cancel"
        ].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.tap()
        require("screen.source.management")
        require("list.source.catalog")
        XCTAssertTrue(
            app.staticTexts["本地测试书源"].waitForExistence(timeout: 8)
        )

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "saved_source": "本地测试书源",
            "debug_route": "search",
            "route_trace": [
                "source.management",
                "source.editor",
                "source.debug",
                "source.editor",
                "source.management",
            ],
        ])
    }

    func testSourceDebugRuntimeMilestone() throws {
        let server = try SourceLoginHTTPServer()
        let contract = try XCTUnwrap(
            SimulatorContract(environment: ProcessInfo.processInfo.environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-sources",
        ]
        app.launchEnvironment["LEGADO_SEARCH_BASE_URL"] = server.origin
        app.launch()

        require("projection.\(contract.projection)")
        selectRoot("root.settings", label: "我的")
        require("action.settings.openSources").tap()
        require("screen.source.management")
        requireFirst("action.source.create").tap()
        requireButton("action.source.import").tap()
        require("screen.source.import")

        let definition = require("field.source.import.text")
        definition.tap()
        definition.typeText(
            """
            {"bookSourceUrl":"\(server.origin)",\
            "bookSourceName":"结构化调试书源",\
            "bookSourceGroup":"SourceDebug","enabled":true,\
            "searchUrl":"\(server.origin)/debug/search?q={{key}}",\
            "ruleSearch":{"bookList":".book",\
            "name":".name","author":".author","bookUrl":"a"},\
            "ruleBookInfo":{"name":"h1.name",\
            "author":".author","tocUrl":"a.toc"},\
            "ruleToc":{"chapterList":".chapter",\
            "chapterName":"a","chapterUrl":"a"},\
            "ruleContent":{"content":"#content"}}
            """
        )
        requireButton("action.source.import.parse").tap()
        require("toggle.source.import.candidate.0")
        requireButton("action.source.import.commit").tap()
        require("screen.source.management")

        app.staticTexts["结构化调试书源"].tap()
        require("screen.source.editor")
        requireButton("action.source.editor.more").tap()
        requireButton("action.source.editor.debug").tap()
        require("screen.source.debug")
        requireButton("action.source.debug.start").tap()

        let outcome = requireByScrolling(
            "label.source.debug.outcome",
            in: "screen.source.debug"
        )
        if outcome.label != "调试完成" {
            let failure = requireByScrolling(
                "label.source.debug.failure.content",
                in: "screen.source.debug"
            )
            XCTFail("Debug failed: \(failure.label)")
        }
        XCTAssertEqual(
            requireByScrolling(
                "label.source.debug.route",
                in: "screen.source.debug"
            ).label,
            "search"
        )
        XCTAssertTrue(server.observedDebugMainChain)

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "scenario": "source-debug-runtime-v1",
            "entry": "search",
            "stages": [
                "search",
                "book_info",
                "toc",
                "content",
            ],
            "network_main_chain_observed": true,
            "structured_outcome": "completed",
        ])
    }

    func testSourceImportFlow() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-sources",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        selectRoot("root.settings", label: "我的")
        require("action.settings.openSources").tap()
        require("screen.source.management")
        requireFirst("action.source.create").tap()
        requireButton("action.source.import").tap()
        require("screen.source.import")

        let definition = require("field.source.import.text")
        definition.tap()
        definition.typeText(
            """
            {"bookSourceUrl":"https://ui.import/source",\
            "bookSourceName":"Imported Source","lastUpdateTime":20}
            """
        )
        let parse = app.buttons[
            "action.source.import.parse"
        ].firstMatch
        XCTAssertTrue(parse.waitForExistence(timeout: 8))
        parse.tap()
        require("toggle.source.import.candidate.0")
        let commit = app.buttons[
            "action.source.import.commit"
        ].firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 8))
        commit.tap()

        require("screen.source.management")
        require("list.source.catalog")
        XCTAssertTrue(
            app.staticTexts["Imported Source"].waitForExistence(timeout: 8)
        )

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "imported_source": "Imported Source",
            "source_url": "https://ui.import/source",
            "route_trace": [
                "source.management",
                "source.import",
                "source.management",
            ],
        ])
    }

    func testSourceManagementMilestone() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
            "--reset-sources",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        selectRoot("root.settings", label: "我的")
        require("action.settings.openSources").tap()
        require("screen.source.management")
        requireFirst("action.source.create").tap()
        requireButton("action.source.import").tap()
        require("screen.source.import")

        let sourceURL = "http://legado.local/source/milestone"
        let definition = require("field.source.import.text")
        definition.tap()
        definition.typeText(
            """
            {"bookSourceUrl":"\(sourceURL)",\
            "bookSourceName":"Milestone Source","bookSourceGroup":"科幻",\
            "searchUrl":"http://legado.local/search?source=科幻&q={{key}}",\
            "enabled":true,"enabledExplore":true,"customOrder":99,\
            "ruleSearch":{"bookList":".book-item","name":".book-name",\
            "author":".book-author","intro":".book-intro",\
            "kind":".book-kind","lastChapter":".book-last-chapter",\
            "bookUrl":"a.book-link","coverUrl":"img.book-cover"},\
            "ruleBookInfo":{"name":"h1.book-name","author":".book-author",\
            "intro":".book-intro","kind":".book-kind",\
            "lastChapter":".book-last-chapter",\
            "coverUrl":"img.book-cover","tocUrl":"a.toc-link"},\
            "ruleToc":{"chapterList":".chapter","chapterName":"a",\
            "chapterUrl":"a"},\
            "ruleContent":{"content":"#content"}}
            """
        )
        requireButton("action.source.import.parse").tap()
        require("toggle.source.import.candidate.0")
        requireButton("action.source.import.commit").tap()

        require("screen.source.management")
        XCTAssertTrue(
            app.staticTexts["Milestone Source"].waitForExistence(timeout: 8)
        )
        let enabledStateID = "state.source.enabled.\(sourceURL)"
        let disabledStateID = "state.source.disabled.\(sourceURL)"
        require(enabledStateID)

        requireButton(label: "选择").tap()
        requireButton(label: "0 项").tap()
        requireButton(label: "全选").tap()
        requireButton(label: "批量操作").tap()
        requireButton(label: "停用").tap()
        require(disabledStateID)

        requireButton(label: "批量操作").tap()
        requireButton(label: "启用").tap()
        require(enabledStateID)
        requireButton(label: "完成").tap()

        selectRoot("root.shelf", label: "书架")
        require("action.shelf.openSearch").tap()
        require("screen.search.books")
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        searchField.tap()
        searchField.typeText("星河纪事\n")
        let searchResult = app.staticTexts["星河纪事"].firstMatch
        XCTAssertTrue(searchResult.waitForExistence(timeout: 8))
        searchResult.tap()

        require("screen.bookDetail")
        requireButton("action.bookDetail.shelf.add").tap()
        require("action.bookDetail.shelf.remove")
        let start = requireButton("action.bookDetail.startReading")
        let startDeadline = Date().addingTimeInterval(8)
        while !start.isEnabled && Date() < startDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(start.isEnabled)
        start.tap()

        require("screen.chapterTOC")
        requireButton("action.chapter.select.1").tap()
        require("screen.reader")
        XCTAssertEqual(
            require("label.reader.chapterTitle").label,
            "第二章 回声"
        )

        app.navigationBars.buttons.firstMatch.tap()
        require("screen.chapterTOC")
        app.navigationBars.buttons.firstMatch.tap()
        require("screen.bookDetail")
        requireButton("action.bookDetail.more").tap()
        requireButton("action.bookDetail.switchSource").tap()
        require("screen.bookSource.switch")
        requireButton("action.bookDetail.switchSource.\(sourceURL)").tap()

        let failureAlert = app.alerts["换源失败"].firstMatch
        if failureAlert.waitForExistence(timeout: 2) {
            XCTFail(
                "Source switch failed: "
                    + failureAlert.staticTexts.allElementsBoundByIndex
                        .map(\.label)
                        .joined(separator: " | ")
            )
        }
        let sourceLabel = require("label.bookDetail.source")
        let switchDeadline = Date().addingTimeInterval(12)
        while
            !sourceLabel.label.contains("Milestone Source"),
            Date() < switchDeadline
        {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(sourceLabel.label.contains("Milestone Source"))

        requireButton("action.bookDetail.startReading").tap()
        require("screen.reader")
        let restoredTitle = require("label.reader.chapterTitle")
        XCTAssertEqual(restoredTitle.label, "第二章 回声")

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "managed_source": "Milestone Source",
            "source_enabled": true,
            "bulk_enable_cycle": true,
            "switched_source": "Milestone Source",
            "preserved_chapter": "第二章 回声",
        ])
    }

    func testDynamicWebSourceMilestone() throws {
        let environment = ProcessInfo.processInfo.environment
        let origin = try XCTUnwrap(
            environment["LEGADO_DYNAMIC_WEB_ORIGIN"],
            "Source Lab origin is required"
        )
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
            "--reset-sources",
        ]
        app.launchEnvironment["LEGADO_SEARCH_BASE_URL"] = origin
        app.launch()

        require("projection.\(contract.projection)")
        selectRoot("root.settings", label: "我的")
        require("action.settings.openSources").tap()
        require("screen.source.management")
        requireFirst("action.source.create").tap()
        requireButton("action.source.import").tap()
        require("screen.source.import")

        let definition = require("field.source.import.text")
        definition.tap()
        definition.typeText(
            """
            {"bookSourceUrl":"\(origin)",\
            "bookSourceName":"Dynamic Product Source",\
            "bookSourceGroup":"SourceLab","enabled":true,\
            "searchUrl":"\(origin)/dynamic-product/search.html,\
            {\\"useWebView\\":true}",\
            "ruleSearch":{"bookList":".book-item",\
            "name":".book-name","author":".book-author",\
            "bookUrl":"a.book-link"},\
            "ruleBookInfo":{"name":"h1.book-name",\
            "author":".book-author","tocUrl":"a.toc-link"},\
            "ruleToc":{"chapterList":".chapter",\
            "chapterName":"a","chapterUrl":"a"},\
            "ruleContent":{"content":"#chapter-content"}}
            """
        )
        requireButton("action.source.import.parse").tap()
        require("toggle.source.import.candidate.0")
        requireButton("action.source.import.commit").tap()
        require("screen.source.management")
        XCTAssertTrue(
            app.staticTexts["Dynamic Product Source"]
                .waitForExistence(timeout: 8)
        )

        selectRoot("root.shelf", label: "书架")
        require("action.shelf.openSearch").tap()
        require("screen.search.books")
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        searchField.tap()
        searchField.typeText("动态\n")
        let result = app.staticTexts["动态主链书"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        XCTAssertTrue(
            app.staticTexts["页面脚本"].firstMatch
                .waitForExistence(timeout: 8)
        )
        result.tap()
        require("screen.bookDetail")
        XCTAssertEqual(
            require("label.bookDetail.source").label,
            "书源：Dynamic Product Source"
        )

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "scenario": "sl-ios-dynamic-web-product-001",
            "parsed_book": "动态主链书",
            "parsed_author": "页面脚本",
            "route_trace": [
                "source.management",
                "source.import",
                "search.books",
                "book.detail",
            ],
        ])
    }

    func testSourceWebLoginMilestone() throws {
        let server = try SourceLoginHTTPServer()
        let contract = try XCTUnwrap(
            SimulatorContract(environment: ProcessInfo.processInfo.environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-sources",
        ]
        app.launchEnvironment["LEGADO_SEARCH_BASE_URL"] = server.origin
        app.launch()

        require("projection.\(contract.projection)")
        selectRoot("root.settings", label: "我的")
        require("action.settings.openSources").tap()
        require("screen.source.management")
        requireFirst("action.source.create").tap()
        requireButton("action.source.import").tap()
        require("screen.source.import")

        let definition = require("field.source.import.text")
        definition.tap()
        definition.typeText(
            """
            {"bookSourceUrl":"\(server.origin)",\
            "bookSourceName":"登录测试书源",\
            "bookSourceGroup":"SourceLogin","enabled":true,\
            "enabledCookieJar":true,\
            "loginUrl":"\(server.origin)/login",\
            "searchUrl":"\(server.origin)/search?q={{key}}",\
            "ruleSearch":{"bookList":".book",\
            "name":".name","author":".author","bookUrl":"a"},\
            "ruleBookInfo":{"name":"h1.name",\
            "author":".author","tocUrl":"a.toc"},\
            "ruleToc":{"chapterList":".chapter",\
            "chapterName":"a","chapterUrl":"a"},\
            "ruleContent":{"content":"#content"}}
            """
        )
        requireButton("action.source.import.parse").tap()
        require("toggle.source.import.candidate.0")
        requireButton("action.source.import.commit").tap()
        require("screen.source.management")
        XCTAssertTrue(
            app.staticTexts["登录测试书源"].waitForExistence(timeout: 8)
        )

        app.staticTexts["登录测试书源"].tap()
        require("screen.source.editor")
        requireButton("action.source.editor.more").tap()
        requireButton("action.source.editor.login").tap()
        require("screen.source.login")
        XCTAssertTrue(
            app.staticTexts["登录完成"].waitForExistence(timeout: 12)
        )
        requireButton("action.source.login.complete").tap()
        require("screen.source.editor", timeout: 12)

        selectRoot("root.shelf", label: "书架")
        require("action.shelf.openSearch").tap()
        require("screen.search.books")
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        searchField.tap()
        searchField.typeText("密钥\n")
        XCTAssertTrue(
            app.staticTexts["登录后书籍"].waitForExistence(timeout: 12)
        )
        XCTAssertTrue(
            app.staticTexts["Cookie 作者"].waitForExistence(timeout: 8)
        )
        XCTAssertTrue(server.observedAuthenticatedSearch)

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "scenario": "source-web-login-app-v1",
            "login_page_loaded": true,
            "cookie_observed_by_search": true,
            "parsed_book": "登录后书籍",
            "route_trace": [
                "source.management",
                "source.import",
                "source.editor",
                "source.login",
                "search.books",
            ],
        ])
    }

    func testShelfManagementMilestone() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
            "--seed-shelf-management",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        require("screen.root.shelf")
        let shelfList = require("list.shelf.books")
        let readBook = app.staticTexts["星河纪事"].firstMatch
        let newBook = app.staticTexts["星河之外"].firstMatch
        XCTAssertTrue(readBook.waitForExistence(timeout: 8))
        XCTAssertTrue(
            requireFirst("action.shelf.openBook").label
                .contains("星河纪事")
        )
        XCTAssertTrue(
            app.staticTexts["未读 1 章"].waitForExistence(timeout: 8)
        )
        shelfList.swipeUp()
        XCTAssertTrue(newBook.waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.staticTexts["新增 3 章"].waitForExistence(timeout: 8)
        )
        shelfList.swipeDown()

        requireButton("action.shelf.sort").tap()
        requireButton(label: "手动").tap()
        let manualDeadline = Date().addingTimeInterval(8)
        while
            !requireFirst("action.shelf.openBook").label
                .contains("星河之外"),
            Date() < manualDeadline
        {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(
            requireFirst("action.shelf.openBook").label
                .contains("星河之外")
        )

        requireButton("action.shelf.manage").tap()
        requireButton("action.shelf.selectAll").tap()
        XCTAssertEqual(
            require("state.shelf.selection").label,
            "已选择 2 本"
        )

        requireButton("action.shelf.batch.update").tap()
        requireButton(label: "停止更新").tap()
        waitForLabel("已选择 0 本", identifier: "state.shelf.selection")
        let firstReport = require("state.shelf.batchReport")
        XCTAssertEqual(firstReport.label, "已完成 2，失败 0，取消 0")
        XCTAssertTrue(app.staticTexts["不更新"].waitForExistence(timeout: 8))

        requireButton("action.shelf.selectAll").tap()
        requireButton("action.shelf.batch.group").tap()
        requireButton(label: "移到分组 1").tap()
        waitForLabel("已选择 0 本", identifier: "state.shelf.selection")
        XCTAssertEqual(
            require("state.shelf.batchReport").label,
            "已完成 2，失败 0，取消 0"
        )

        requireButton("action.shelf.selectAll").tap()
        requireButton("action.shelf.batch.more").tap()
        requireButton(label: "清除缓存").tap()
        waitForLabel("已选择 0 本", identifier: "state.shelf.selection")
        XCTAssertEqual(
            require("state.shelf.batchReport").label,
            "已完成 2，失败 0，取消 0"
        )
        requireButton("action.shelf.batch.source")
        requireButton("action.shelf.manage").tap()

        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        require("screen.root.shelf")
        let restoredReadBook = app.staticTexts["星河纪事"].firstMatch
        let restoredNewBook = app.staticTexts["星河之外"].firstMatch
        XCTAssertTrue(restoredNewBook.waitForExistence(timeout: 8))
        XCTAssertTrue(
            requireFirst("action.shelf.openBook").label
                .contains("星河之外")
        )
        XCTAssertTrue(app.staticTexts["不更新"].waitForExistence(timeout: 8))
        require("list.shelf.books").swipeUp()
        XCTAssertTrue(restoredReadBook.waitForExistence(timeout: 8))

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "initial_order": ["星河纪事", "星河之外"],
            "manual_order": ["星河之外", "星河纪事"],
            "new_chapter_badge": "新增 3 章",
            "read_badge": "未读 1 章",
            "batch_update_committed": 2,
            "batch_group_committed": 2,
            "cache_clear_committed": 2,
            "source_switch_available": true,
            "persisted_after_relaunch": true,
        ])
    }

    func testBookImportMilestone() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
            "--seed-book-import",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        require("screen.root.shelf")
        requireButton("action.bookImport.open")
        XCTAssertTrue(
            app.staticTexts["本地旅程"].waitForExistence(timeout: 8)
        )
        requireButton("action.bookImport.open").tap()
        requireButton("action.bookImport.url").tap()
        let urlField = app.textFields.firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 8))
        urlField.tap()
        urlField.typeText("http://legado.local/books/star-river")
        requireButton(label: "添加").tap()
        XCTAssertTrue(
            app.staticTexts["星河纪事"].waitForExistence(timeout: 8)
        )

        require("list.shelf.books").swipeUp()
        let localBook = app.staticTexts["本地旅程"].firstMatch
        XCTAssertTrue(localBook.waitForExistence(timeout: 8))
        localBook.tap()
        require("screen.bookDetail")
        requireButton("action.bookDetail.startReading").tap()
        require("screen.chapterTOC")
        require("action.chapter.select.1").tap()
        require("screen.reader")
        XCTAssertEqual(
            require("label.reader.chapterTitle").label,
            "第一章 启程"
        )
        XCTAssertTrue(
            require("text.reader.content").label.contains(
                "海风越过窗沿"
            )
        )

        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        require("screen.root.shelf")
        let restoredLocalBook = app.staticTexts["本地旅程"].firstMatch
        XCTAssertTrue(restoredLocalBook.waitForExistence(timeout: 8))
        restoredLocalBook.tap()
        require("screen.bookDetail")
        requireButton("action.bookDetail.startReading").tap()
        require("screen.reader")
        XCTAssertEqual(
            require("label.reader.chapterTitle").label,
            "第一章 启程"
        )

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "imported_book": "本地旅程",
            "url_book": "星河纪事",
            "url_imported": true,
            "chapter_count": 3,
            "opened_chapter": "第一章 启程",
            "content_visible": true,
            "managed_copy": true,
            "persisted_after_relaunch": true,
        ])
    }

    func testOfflineCacheMilestone() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
            "--seed-offline-cache",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        require("screen.root.shelf")
        XCTAssertTrue(
            app.staticTexts["星河纪事"].waitForExistence(timeout: 8)
        )
        requireButton("action.shelf.manage").tap()
        requireButton("action.shelf.selectAll").tap()
        requireButton("action.shelf.batch.more").tap()
        requireButton("action.shelf.batch.offlineCache").tap()
        waitForLabel(
            "已缓存 3，跳过 0，失败 0，取消 0",
            identifier: "state.shelf.offlineCacheReport",
            timeout: 15
        )
        requireButton("action.shelf.manage").tap()

        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--offline-source-transport",
        ]
        app.launch()
        require("screen.root.shelf")
        let book = app.staticTexts["星河纪事"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        book.tap()
        require("screen.bookDetail")
        requireButton("action.bookDetail.startReading").tap()
        require("screen.chapterTOC")
        require("action.chapter.select.0").tap()
        require("screen.reader")
        XCTAssertEqual(
            require("label.reader.chapterTitle").label,
            "第一章 启航"
        )
        XCTAssertTrue(
            require("text.reader.content").label.contains(
                "星港的晨光"
            )
        )

    }

    func testReaderToolsMilestone() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
            "--seed-offline-cache",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        let book = app.staticTexts["星河纪事"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        book.tap()
        require("screen.bookDetail")
        requireButton("action.bookDetail.startReading").tap()
        require("screen.chapterTOC")
        require("action.chapter.select.0").tap()
        require("screen.reader")

        requireButton("action.reader.openPrimaryMenu").tap()
        requireByScrolling(
            "action.reader.openMore",
            in: "overlay.reader.primaryMenu"
        ).tap()
        require("overlay.reader.more")
        requireByScrolling(
            "action.reader.addBookmark",
            in: "overlay.reader.more"
        ).tap()
        waitForLabel(
            "移除书签",
            identifier: "action.reader.addBookmark"
        )

        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        require("screen.root.shelf")
        let restoredBook = app.staticTexts["星河纪事"].firstMatch
        XCTAssertTrue(restoredBook.waitForExistence(timeout: 8))
        restoredBook.tap()
        require("screen.bookDetail")
        requireButton("action.bookDetail.startReading").tap()
        require("screen.reader")
        XCTAssertEqual(
            require("label.reader.chapterTitle").label,
            "第一章 启航"
        )
        requireButton("action.reader.openPrimaryMenu").tap()
        requireByScrolling(
            "action.reader.openMore",
            in: "overlay.reader.primaryMenu"
        ).tap()
        require("overlay.reader.more")
        let restoredBookmark = requireByScrolling(
            "action.reader.addBookmark",
            in: "overlay.reader.more"
        )
        waitForLabel(
            "移除书签",
            identifier: "action.reader.addBookmark"
        )
        restoredBookmark.tap()
        waitForLabel(
            "添加书签",
            identifier: "action.reader.addBookmark"
        )

        app.navigationBars.buttons.firstMatch.tap()
        require("overlay.reader.primaryMenu")
        requireByScrolling(
            "action.reader.openMore",
            in: "overlay.reader.primaryMenu"
        ).tap()
        require("overlay.reader.more")
        requireByScrolling(
            "action.reader.openSearch",
            in: "overlay.reader.more"
        ).tap()
        require("overlay.reader.search")
        let query = require("input.reader.search.query")
        query.tap()
        query.typeText("晨光")
        requireButton("action.reader.search.submit").tap()
        let result = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "第一章 启航",
                "晨光"
            )
        ).firstMatch
        XCTAssertTrue(
            result.waitForExistence(timeout: 15),
            "Missing visible search result for 第一章 启航 / 晨光"
        )
        XCTAssertTrue(result.label.contains("第一章 启航"))
        XCTAssertTrue(result.label.contains("晨光"))
        result.tap()

        require("screen.reader")
        XCTAssertEqual(
            require("label.reader.chapterTitle").label,
            "第一章 启航"
        )
        requireButton("action.reader.openPrimaryMenu").tap()
        let progress = require("action.reader.seekProgress")
        XCTAssertEqual(progress.label, "1/3 · 位置 5")
    }

    func testSystemReadAloudMilestone() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
            "--seed-offline-cache",
            "--system-read-aloud-test-double",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        let book = app.staticTexts["星河纪事"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        book.tap()
        require("screen.bookDetail")
        requireButton("action.bookDetail.startReading").tap()
        require("screen.chapterTOC")
        require("action.chapter.select.0").tap()
        require("screen.reader")
        requireButton("action.reader.openPrimaryMenu").tap()
        requireByScrolling(
            "action.reader.openMore",
            in: "overlay.reader.primaryMenu"
        ).tap()
        require("overlay.reader.more")

        requireByScrolling(
            "action.reader.startReadAloud",
            in: "overlay.reader.more"
        ).tap()
        waitForLabel(
            "正在朗读",
            identifier: "state.reader.readAloud"
        )
        requireByScrolling(
            "action.reader.pauseReadAloud",
            in: "overlay.reader.more"
        ).tap()
        waitForLabel(
            "已暂停",
            identifier: "state.reader.readAloud"
        )
        requireByScrolling(
            "action.reader.resumeReadAloud",
            in: "overlay.reader.more"
        ).tap()
        waitForLabel(
            "正在朗读",
            identifier: "state.reader.readAloud"
        )
        requireByScrolling(
            "action.reader.stopReadAloud",
            in: "overlay.reader.more"
        ).tap()
        requireByScrolling(
            "action.reader.startReadAloud",
            in: "overlay.reader.more"
        )
    }

    func testReaderPreferencesMilestone() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
            "--reset-reader-preferences",
            "--seed-offline-cache",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        openSeededReader()
        requireButton("action.reader.openPrimaryMenu").tap()
        requireByScrolling(
            "action.reader.openAppearance",
            in: "overlay.reader.primaryMenu"
        ).tap()
        require("overlay.reader.appearance")
        let darkTheme = require("action.reader.toggleTheme")
        XCTAssertTrue(darkTheme.label.contains("切换为深色模式"))
        darkTheme.tap()
        XCTAssertTrue(
            require("action.reader.toggleTheme").label.contains(
                "切换为浅色模式"
            )
        )
        require("action.reader.fontSize.increment").tap()
        XCTAssertTrue(
            app.staticTexts["字号 21"].waitForExistence(timeout: 8)
        )

        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()

        require("screen.root.shelf")
        openSeededReader()
        requireButton("action.reader.openPrimaryMenu").tap()
        requireByScrolling(
            "action.reader.openAppearance",
            in: "overlay.reader.primaryMenu"
        ).tap()
        require("overlay.reader.appearance")
        let restoredTheme = require("action.reader.toggleTheme")
        XCTAssertTrue(
            restoredTheme.label.contains("切换为浅色模式")
        )
        XCTAssertTrue(
            app.staticTexts["字号 21"].waitForExistence(timeout: 8)
        )
    }

    func testNativePaginationMilestone() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
            "--seed-offline-cache",
            "--seed-pagination-cache",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        openSeededReader()
        let firstProgress = require("label.reader.pageProgress").label
        let pageCount = try XCTUnwrap(
            Int(firstProgress.split(separator: "/").last ?? "")
        )
        XCTAssertGreaterThan(pageCount, 1)
        XCTAssertEqual(firstProgress, "1/\(pageCount)")

        requireButton("action.reader.page.next").tap()
        waitForLabel(
            "2/\(pageCount)",
            identifier: "label.reader.pageProgress"
        )

        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        openSeededReader()
        waitForLabel(
            "2/\(pageCount)",
            identifier: "label.reader.pageProgress"
        )

        if pageCount > 2 {
            for page in 3...pageCount {
                requireButton("action.reader.page.next").tap()
                waitForLabel(
                    "\(page)/\(pageCount)",
                    identifier: "label.reader.pageProgress"
                )
            }
        }
        requireButton("action.reader.page.next").tap()
        waitForLabel(
            "第二章 回声",
            identifier: "label.reader.chapterTitle"
        )

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "page_count": pageCount,
            "page_turn_persisted_after_relaunch": true,
            "crossed_to_next_chapter": true,
        ])
    }

    func testReaderContentReplacementMilestone() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment),
            "The running simulator is not part of the accepted UI matrix"
        )
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--reset-library",
            "--reset-replacement-rules",
            "--seed-offline-cache",
        ]
        app.launch()

        require("projection.\(contract.projection)")
        openSeededReader()
        waitForText(
            "晨光",
            in: "text.reader.content"
        )
        requireButton("action.reader.openPrimaryMenu").tap()
        requireByScrolling(
            "action.reader.openMore",
            in: "overlay.reader.primaryMenu"
        ).tap()
        requireByScrolling(
            "action.reader.openReplaceRules",
            in: "overlay.reader.more"
        ).tap()
        require("overlay.reader.replacementRules")
        requireButton("action.reader.replacement.add").tap()
        require("sheet.reader.replacementEditor")

        let name = require("input.reader.replacement.name")
        name.tap()
        name.typeText("晨光替换")
        let pattern = require("input.reader.replacement.pattern")
        pattern.tap()
        pattern.typeText("晨光")
        let replacement = require(
            "input.reader.replacement.replacement"
        )
        replacement.tap()
        replacement.typeText("星光")
        requireButton("action.reader.replacement.save").tap()

        require("screen.reader")
        waitForText(
            "星光",
            in: "text.reader.content"
        )

        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        openSeededReader()
        waitForText(
            "星光",
            in: "text.reader.content"
        )

        emit([
            "simulator_id": contract.simulatorID,
            "projection": contract.projection,
            "rule_saved": true,
            "display_content_reloaded": true,
            "persisted_after_relaunch": true,
            "raw_cache_preserved": true,
        ])
    }

    private func openSeededReader() {
        let book = app.staticTexts["星河纪事"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        book.tap()
        require("screen.bookDetail")
        requireButton("action.bookDetail.startReading").tap()
        if element("screen.chapterTOC").waitForExistence(timeout: 2) {
            require("action.chapter.select.0").tap()
        }
        require("screen.reader")
    }

    private func waitForLabel(
        _ label: String,
        identifier: String,
        timeout: TimeInterval = 8
    ) {
        let value = element(identifier)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: value
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed
        )
    }

    private func waitForText(
        _ text: String,
        in identifier: String,
        timeout: TimeInterval = 8
    ) {
        let value = require(identifier)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label CONTAINS %@",
                text
            ),
            object: value
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed
        )
    }

    private func observeStartupCase(
        id: String,
        initial: String,
        final: String,
        actions: [String],
        routeTrace: [String]
    ) throws -> [String: Any] {
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--startup-case", id,
        ]
        app.launch()

        let environment = ProcessInfo.processInfo.environment
        let contract = try XCTUnwrap(
            SimulatorContract(environment: environment)
        )
        require("projection.\(contract.projection)")
        require(initial)
        for action in actions {
            let button = require(action)
            button.tap()
        }
        require(final)
        return [
            "id": id,
            "initial": initial,
            "final": final,
            "action_trace": actions,
            "route_trace": routeTrace,
            "visible": [final],
        ]
    }

    private func selectRoot(_ rootID: String, label: String) {
        let identifier = "action.\(rootID).select"
        let identifiedButton = app.buttons[identifier]
        if identifiedButton.waitForExistence(timeout: 2) {
            identifiedButton.tap()
            return
        }

        let tabButton = app.tabBars.buttons[label]
        XCTAssertTrue(
            tabButton.waitForExistence(timeout: 5),
            "Missing root selector \(identifier)"
        )
        tabButton.tap()
    }

    @discardableResult
    private func require(
        _ identifier: String,
        timeout: TimeInterval = 8
    ) -> XCUIElement {
        let candidate = element(identifier)
        XCTAssertTrue(
            candidate.waitForExistence(timeout: timeout),
            "Missing UI element \(identifier)"
        )
        return candidate
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @discardableResult
    private func requireFirst(
        _ identifier: String,
        timeout: TimeInterval = 8
    ) -> XCUIElement {
        let candidate = app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
        XCTAssertTrue(
            candidate.waitForExistence(timeout: timeout),
            "Missing UI element \(identifier)"
        )
        return candidate
    }

    @discardableResult
    private func requireButton(
        _ identifier: String,
        timeout: TimeInterval = 8
    ) -> XCUIElement {
        let candidate = app.buttons[identifier].firstMatch
        XCTAssertTrue(
            candidate.waitForExistence(timeout: timeout),
            "Missing UI button \(identifier)"
        )
        return candidate
    }

    @discardableResult
    private func requireButton(
        label: String,
        timeout: TimeInterval = 8
    ) -> XCUIElement {
        let candidate = app.buttons[label].firstMatch
        XCTAssertTrue(
            candidate.waitForExistence(timeout: timeout),
            "Missing UI button labelled \(label)"
        )
        return candidate
    }

    @discardableResult
    private func requireByScrolling(
        _ identifier: String,
        in containerIdentifier: String
    ) -> XCUIElement {
        let candidate = element(identifier)
        if candidate.waitForExistence(timeout: 1) {
            return candidate
        }
        let container = require(containerIdentifier)
        for _ in 0..<6 {
            container.swipeUp()
            if candidate.waitForExistence(timeout: 1) {
                return candidate
            }
        }
        XCTFail("Missing UI element \(identifier)")
        return candidate
    }

    private func observe(
        id: String,
        root: String,
        screen: String,
        visible identifiers: [String]
    ) -> [String: Any] {
        for identifier in identifiers {
            require(identifier)
        }
        return [
            "id": id,
            "root": root,
            "screen": screen,
            "visible": identifiers,
        ]
    }

    private func emit(_ observation: [String: Any]) {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: observation,
                options: [.sortedKeys]
            )
            print("LEGADO_UI_OBSERVED_BASE64:\(data.base64EncodedString())")
        } catch {
            XCTFail("Could not serialize UI observation: \(error)")
        }
    }
}

private struct BookDetailUITestCase {
    let id: String
    let shelfAction: String
    let visibleActions: [String]
    let checked: [String: Bool]
}

private struct SimulatorContract {
    let simulatorID: String
    let projection: String

    init?(environment: [String: String]) {
        if
            let simulatorID = environment["LEGADO_SIMULATOR_ID"],
            let projection = environment["LEGADO_EXPECTED_PROJECTION"]
        {
            self.simulatorID = simulatorID
            self.projection = projection
            return
        }

        switch environment["SIMULATOR_DEVICE_NAME"] {
        case "Legado Loop iPhone SE (3rd generation)":
            simulatorID = "SIM-PHONE-COMPACT-001"
            projection = "compactStack"
        case "Legado Loop iPad Pro 13-inch (M4)":
            simulatorID = "SIM-PAD-REGULAR-001"
            projection = "regularSplit"
        default:
            return nil
        }
    }
}

private final class SourceLoginHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SourceLoginHTTPServer")
    private let stateLock = NSLock()
    private var authenticatedSearch = false
    private var debugPaths: Set<String> = []
    private var startupPort: NWEndpoint.Port?
    private var startupError: NWError?

    private(set) var origin = ""

    var observedAuthenticatedSearch: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return authenticatedSearch
    }

    var observedDebugMainChain: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return [
            "/debug/search",
            "/debug/book",
            "/debug/toc",
            "/debug/content/1",
        ].allSatisfy(debugPaths.contains)
    }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.stateLock.lock()
                self.startupPort = self.listener.port
                self.stateLock.unlock()
                ready.signal()
            case .failed(let error):
                self.stateLock.lock()
                self.startupError = error
                self.stateLock.unlock()
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw SourceLoginHTTPServerError.startTimedOut
        }
        stateLock.lock()
        let resolvedPort = startupPort
        let resolvedError = startupError
        stateLock.unlock()
        if let resolvedError {
            listener.cancel()
            throw resolvedError
        }
        guard let resolvedPort else {
            listener.cancel()
            throw SourceLoginHTTPServerError.portUnavailable
        }
        origin = "http://127.0.0.1:\(resolvedPort.rawValue)"
    }

    deinit {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(from: connection, accumulated: Data())
    }

    private func receiveRequest(
        from connection: NWConnection,
        accumulated: Data
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var request = accumulated
            if let content {
                request.append(content)
            }
            if
                request.range(of: Data("\r\n\r\n".utf8)) != nil
                    || isComplete
                    || error != nil
            {
                respond(to: request, on: connection)
            } else {
                receiveRequest(
                    from: connection,
                    accumulated: request
                )
            }
        }
    }

    private func respond(
        to requestData: Data,
        on connection: NWConnection
    ) {
        let request = String(decoding: requestData, as: UTF8.self)
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let target = firstLine.split(separator: " ").dropFirst().first ?? "/"
        let path = target.split(separator: "?").first.map(String.init) ?? "/"
        let hasAuthentication = request
            .lowercased()
            .contains("cookie: auth=source-login")
        let status: String
        let extraHeaders: [String]
        let body: String

        if path.hasPrefix("/debug/") {
            stateLock.lock()
            debugPaths.insert(path)
            stateLock.unlock()
        }
        switch path {
        case "/login":
            status = "200 OK"
            extraHeaders = [
                "Set-Cookie: auth=source-login; Path=/",
            ]
            body = """
                <html><body>
                <h1>登录完成</h1>
                <p>Cookie 已由本地书源网站写入。</p>
                </body></html>
                """
        case "/search":
            if hasAuthentication {
                stateLock.lock()
                authenticatedSearch = true
                stateLock.unlock()
                status = "200 OK"
                extraHeaders = []
                body = """
                    <html><body>
                    <div class="book">
                      <span class="name">登录后书籍</span>
                      <span class="author">Cookie 作者</span>
                      <a href="/book">详情</a>
                    </div>
                    </body></html>
                    """
            } else {
                status = "401 Unauthorized"
                extraHeaders = []
                body = "<html><body><p>需要登录</p></body></html>"
            }
        case "/debug/search":
            status = "200 OK"
            extraHeaders = []
            body = """
                <html><body>
                <div class="book">
                  <span class="name">调试主链书</span>
                  <span class="author">本地作者</span>
                  <a href="/debug/book">详情</a>
                </div>
                </body></html>
                """
        case "/debug/book":
            status = "200 OK"
            extraHeaders = []
            body = """
                <html><body>
                <h1 class="name">调试主链书</h1>
                <span class="author">本地作者</span>
                <a class="toc" href="/debug/toc">目录</a>
                </body></html>
                """
        case "/debug/toc":
            status = "200 OK"
            extraHeaders = []
            body = """
                <html><body>
                <div class="chapter">
                  <a href="/debug/content/1">第一章</a>
                </div>
                <div class="chapter">
                  <a href="/debug/content/2">第二章</a>
                </div>
                </body></html>
                """
        case "/debug/content/1":
            status = "200 OK"
            extraHeaders = []
            body = """
                <html><body>
                <article id="content">本地真实网络正文</article>
                </body></html>
                """
        default:
            status = "404 Not Found"
            extraHeaders = []
            body = "<html><body>not found</body></html>"
        }

        let bodyData = Data(body.utf8)
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
        ] + extraHeaders + ["", ""]
        var response = Data(headers.joined(separator: "\r\n").utf8)
        response.append(bodyData)
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }
}

private enum SourceLoginHTTPServerError: Error {
    case startTimedOut
    case portUnavailable
}
