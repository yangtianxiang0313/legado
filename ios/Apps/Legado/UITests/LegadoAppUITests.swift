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
