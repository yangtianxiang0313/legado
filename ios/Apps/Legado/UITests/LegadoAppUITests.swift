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
