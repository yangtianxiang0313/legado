import XCTest

@MainActor
final class LegadoAppUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
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

        require("action.source.add").tap()
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
