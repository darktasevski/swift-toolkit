//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

@MainActor
final class EPUBNavigatorPageCommandOutcomeTests: XCTestCase {
    func testSucceededPageCommandProceedsToLandingAndJumpNotification() {
        XCTAssertEqual(
            EPUBNavigatorViewController.navigationDisposition(for: .succeeded),
            .landed
        )
    }

    func testFailedPageCommandIsReportedAsMissWithoutFallback() {
        XCTAssertEqual(
            EPUBNavigatorViewController.navigationDisposition(for: .failed),
            .miss
        )
    }

    func testCancelledPageCommandIsReportedAsCancelledWithoutFallback() {
        XCTAssertEqual(
            EPUBNavigatorViewController.navigationDisposition(for: .cancelled),
            .cancelled
        )
    }

    func testSucceededPageTurnIsReportedAsMoved() {
        XCTAssertEqual(
            EPUBNavigatorViewController.pageTurnNavigationDisposition(for: .succeeded),
            .moved
        )
    }

    func testBoundaryPageTurnFallsBackToCrossResourceNavigation() {
        XCTAssertEqual(
            EPUBNavigatorViewController.pageTurnNavigationDisposition(for: .boundary),
            .crossResource
        )
    }

    func testFailedPageTurnDoesNotFallBackToCrossResourceNavigation() {
        XCTAssertEqual(
            EPUBNavigatorViewController.pageTurnNavigationDisposition(for: .failed),
            .failed
        )
    }

    func testCancelledPageTurnDoesNotFallBackToCrossResourceNavigation() {
        XCTAssertEqual(
            EPUBNavigatorViewController.pageTurnNavigationDisposition(for: .cancelled),
            .cancelled
        )
    }
}
