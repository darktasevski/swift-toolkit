//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

@MainActor
final class EPUBLocatorDecorationActivationTests: XCTestCase {
    func test_matchingIdentityAcceptsActivationWhenBudgetDiffers() {
        let expected = token(budgetMilliseconds: 750)
        let messageToken = token(budgetMilliseconds: 0)

        XCTAssertNotNil(validate(body(token: messageToken), expectedToken: expected))
    }

    func test_forgedIdentityFieldsRejectActivation() {
        let expected = token()
        let forgeries = [
            token(webViewInstanceID: "forged-web-view"),
            token(documentEpoch: 8),
            token(operationKind: .navigation),
            token(sequence: 42),
            token(groupID: "forged-group"),
        ]

        for forged in forgeries {
            XCTAssertNil(
                validate(body(token: forged, groupID: forged.groupID ?? "highlights"), expectedToken: expected),
                "Accepted forged token: \(forged)"
            )
        }
    }

    func test_identifierOutsideActivatedSetRejectsActivation() {
        let expected = token()
        var forged = body(token: expected)
        forged["id"] = "highlight-2"

        XCTAssertNil(validate(forged, expectedToken: expected))
    }

    func test_unexpectedBodyKeyRejectsActivation() {
        let expected = token()
        var forged = body(token: expected)
        forged["extra"] = "payload"

        XCTAssertNil(validate(forged, expectedToken: expected))
    }

    func test_outOfRangeRectRejectsActivation() {
        let expected = token()
        var forged = body(token: expected)
        forged["rect"] = ["left": 10.0, "top": 20.0, "width": -1.0, "height": 40.0]

        XCTAssertNil(validate(forged, expectedToken: expected))
    }

    func test_nonFiniteClickRejectsActivation() {
        let expected = token()
        var forged = body(token: expected)
        forged["click"] = [
            "defaultPrevented": false,
            "x": Double.infinity,
            "y": 35.0,
            "targetElement": "mark",
        ]

        XCTAssertNil(validate(forged, expectedToken: expected))
    }

    private func validate(
        _ body: [String: Any],
        expectedToken: EPUBLocatorCommandToken
    ) -> [String: Any]? {
        EPUBLocatorCommandBridge.validatedDecorationActivationBody(
            body,
            webViewInstanceID: "web-view",
            documentEpoch: 7,
            expectedToken: expectedToken,
            identifiers: ["highlight-1"]
        )
    }

    private func token(
        webViewInstanceID: String = "web-view",
        documentEpoch: Int = 7,
        operationKind: EPUBLocatorCommandOperationKind = .decoration,
        sequence: Int = 41,
        groupID: String? = "highlights",
        budgetMilliseconds: Int = 500
    ) -> EPUBLocatorCommandToken {
        EPUBLocatorCommandToken(
            webViewInstanceID: webViewInstanceID,
            documentEpoch: documentEpoch,
            operationKind: operationKind,
            sequence: sequence,
            groupID: groupID,
            budgetMilliseconds: budgetMilliseconds
        )
    }

    private func body(
        token: EPUBLocatorCommandToken,
        groupID: String = "highlights"
    ) -> [String: Any] {
        [
            "id": "highlight-1",
            "group": groupID,
            "token": token.javascriptValue,
            "rect": [
                "left": 10.0,
                "top": 20.0,
                "width": 30.0,
                "height": 40.0,
            ],
            "click": [
                "defaultPrevented": false,
                "x": 25.0,
                "y": 35.0,
                "targetElement": "mark",
            ],
        ]
    }
}
