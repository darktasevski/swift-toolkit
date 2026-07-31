//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import XCTest

final class EPUBNavigatorLocatorStateOwnershipTests: XCTestCase {
    func testLocatorCommandStateIsOwnedByDedicatedStateObject() throws {
        let sourcesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Navigator/EPUB")
        let navigatorSource = try readSource(
            named: "EPUBNavigatorViewController.swift",
            in: sourcesDirectory
        )
        let locatorCommandsSource = try readSource(
            named: "EPUBNavigatorViewController+LocatorCommands.swift",
            in: sourcesDirectory
        )

        let stateOwnerDeclaration = "let locatorCommandState = EPUBLocatorCommandState()"
        XCTAssertEqual(
            navigatorSource.components(separatedBy: stateOwnerDeclaration).count - 1,
            1,
            "The navigator must own exactly one dedicated locator command state object."
        )
        XCTAssertFalse(
            navigatorSource.contains("var locatorOperationSequence"),
            "The navigator must not expose raw mutable locator operation sequence storage."
        )
        XCTAssertFalse(
            navigatorSource.contains("var inFlightLocatorBridge"),
            "The navigator must not expose raw mutable in-flight bridge storage."
        )

        XCTAssertTrue(
            locatorCommandsSource.contains("@MainActor\nfinal class EPUBLocatorCommandState"),
            "Locator command state must be a main-actor-isolated final class."
        )
        XCTAssertTrue(
            locatorCommandsSource.contains("\n    private var locatorOperationSequence"),
            "Locator operation sequence payload must be private to the state object."
        )
        XCTAssertTrue(
            locatorCommandsSource.contains("\n    private weak var inFlightLocatorBridge"),
            "The in-flight bridge payload must remain weak and private to the state object."
        )
        for ownerOnlyAPI in [
            "fileprivate func beginOperation()",
            "fileprivate var operationSequence: UInt64",
            "fileprivate func trackInFlightBridge(",
            "fileprivate func clearInFlightBridge(",
            "fileprivate var currentInFlightBridge: EPUBLocatorCommandBridge?",
        ] {
            XCTAssertTrue(
                locatorCommandsSource.contains(ownerOnlyAPI),
                "Missing owner-only locator state API: \(ownerOnlyAPI)"
            )
        }
        XCTAssertTrue(
            locatorCommandsSource.contains("\n    private func cancelInFlightLocatorNavigation"),
            "Cancellation must be relayed through a private locator-command extension method."
        )
        XCTAssertFalse(
            navigatorSource.contains("func cancelInFlightLocatorNavigation"),
            "Cancellation must not remain module-visible on the main navigator declaration."
        )
    }

    private func readSource(named name: String, in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(name)
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Expected non-empty source at \(url.path)."
        )
        return source
    }
}
