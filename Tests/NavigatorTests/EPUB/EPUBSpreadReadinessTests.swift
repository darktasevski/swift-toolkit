//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

@MainActor
final class EPUBSpreadReadinessTests: XCTestCase {
    func testLoadingAdvancesTheRenderGeneration() {
        let readiness = EPUBSpreadReadiness()

        XCTAssertEqual(readiness.state, .unavailable(generation: 0))

        let first = readiness.beginLoading()
        let second = readiness.beginLoading()

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(readiness.state, .loading(generation: second))
    }

    func testDocumentAvailabilityDoesNotPublishCommandReadiness() async throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let capability = EPUBSpreadFrameCapability(id: UUID())
        var commandOutcome: EPUBSpreadReadiness.WaitOutcome?

        let documentWaiter = Task { @MainActor in
            await readiness.waitForDocumentAvailability(for: generation)
        }
        let commandWaiter = Task { @MainActor in
            let outcome = await readiness.waitForCommandReadiness(for: generation)
            commandOutcome = outcome
            return outcome
        }
        await Task.yield()

        let initializationLease = try XCTUnwrap(
            readiness.beginInitialization(for: generation, frameCapability: capability)
        )

        let documentOutcome = await documentWaiter.value
        XCTAssertEqual(documentOutcome, .documentAvailable(generation: generation))
        XCTAssertNil(commandOutcome)
        XCTAssertEqual(
            readiness.state,
            .initializing(generation: generation, activeWriterLeases: 1)
        )

        readiness.release(initializationLease)

        let readyOutcome = await commandWaiter.value
        XCTAssertEqual(
            readyOutcome,
            .ready(generation: generation, frameCapability: capability)
        )
    }

    func testAllWriterLeasesMustReleaseBeforeReadiness() throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let capability = EPUBSpreadFrameCapability(id: UUID())
        let first = try XCTUnwrap(
            readiness.beginInitialization(for: generation, frameCapability: capability)
        )
        let second = try XCTUnwrap(readiness.acquireWriterLease(for: generation))

        XCTAssertEqual(
            readiness.state,
            .initializing(generation: generation, activeWriterLeases: 2)
        )

        readiness.release(first)
        XCTAssertEqual(
            readiness.state,
            .initializing(generation: generation, activeWriterLeases: 1)
        )

        readiness.release(second)
        XCTAssertEqual(
            readiness.state,
            .ready(generation: generation, frameCapability: capability)
        )
    }

    func testStaleLeaseReleaseCannotPublishAReplacementGeneration() throws {
        let readiness = EPUBSpreadReadiness()
        let firstGeneration = readiness.beginLoading()
        let staleLease = try XCTUnwrap(readiness.beginInitialization(
            for: firstGeneration,
            frameCapability: EPUBSpreadFrameCapability(id: UUID())
        ))

        let replacementGeneration = readiness.beginLoading()
        readiness.release(staleLease)

        XCTAssertEqual(
            readiness.state,
            .loading(generation: replacementGeneration)
        )
    }

    func testStaleGenerationCannotAcquireAWriterLease() throws {
        let readiness = EPUBSpreadReadiness()
        let staleGeneration = readiness.beginLoading()
        let currentGeneration = readiness.beginLoading()

        XCTAssertNil(readiness.beginInitialization(
            for: staleGeneration,
            frameCapability: EPUBSpreadFrameCapability(id: UUID())
        ))
        XCTAssertEqual(readiness.state, .loading(generation: currentGeneration))

        let initialization = try XCTUnwrap(readiness.beginInitialization(
            for: currentGeneration,
            frameCapability: EPUBSpreadFrameCapability(id: UUID())
        ))
        XCTAssertNil(readiness.acquireWriterLease(for: staleGeneration))
        XCTAssertEqual(
            readiness.state,
            .initializing(generation: currentGeneration, activeWriterLeases: 1)
        )
        readiness.release(initialization)
    }

    func testReloadDrainsOldGenerationWaiterAsInvalidated() async {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let waiter = Task { @MainActor in
            await readiness.waitForCommandReadiness(for: generation)
        }
        await Task.yield()

        _ = readiness.beginLoading()

        let outcome = await waiter.value
        XCTAssertEqual(outcome, .invalidated)
    }

    func testCancelledWaiterDoesNotPoisonSharedReadiness() async throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let waiter = Task { @MainActor in
            await readiness.waitForCommandReadiness(for: generation)
        }
        await Task.yield()

        waiter.cancel()

        let cancelledOutcome = await waiter.value
        XCTAssertEqual(cancelledOutcome, .cancelled)

        let capability = EPUBSpreadFrameCapability(id: UUID())
        let lease = try XCTUnwrap(
            readiness.beginInitialization(for: generation, frameCapability: capability)
        )
        readiness.release(lease)

        let laterOutcome = await readiness.waitForCommandReadiness(for: generation)
        XCTAssertEqual(
            laterOutcome,
            .ready(generation: generation, frameCapability: capability)
        )
    }

    func testTimedOutWaiterUnregistersWithoutPoisoningLateReadiness() async throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(10))

        let timedOut = await readiness.waitForCommandReadiness(
            for: generation,
            until: deadline
        )
        XCTAssertEqual(timedOut, .timedOut)

        let capability = EPUBSpreadFrameCapability(id: UUID())
        let rootLease = try XCTUnwrap(
            readiness.beginInitialization(
                for: generation,
                frameCapability: capability
            )
        )
        readiness.release(rootLease)

        let lateOutcome = await readiness.waitForCommandReadiness(for: generation)
        XCTAssertEqual(
            lateOutcome,
            .ready(generation: generation, frameCapability: capability)
        )
    }

    func testSameDocumentMutationAdvancesGenerationAndRetainsFrameCapability() throws {
        let readiness = EPUBSpreadReadiness()
        let firstGeneration = readiness.beginLoading()
        let capability = EPUBSpreadFrameCapability(id: UUID())
        let initialization = try XCTUnwrap(
            readiness.beginInitialization(for: firstGeneration, frameCapability: capability)
        )
        readiness.release(initialization)

        let mutation = try XCTUnwrap(readiness.beginMutation())

        XCTAssertEqual(mutation.generation, firstGeneration + 1)
        XCTAssertEqual(
            readiness.state,
            .initializing(generation: mutation.generation, activeWriterLeases: 1)
        )

        readiness.release(mutation)
        XCTAssertEqual(
            readiness.state,
            .ready(generation: mutation.generation, frameCapability: capability)
        )
    }

    func testFailedInitializationNeverPublishesCommandReadiness() async throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let rootLease = try XCTUnwrap(readiness.beginInitialization(
            for: generation,
            frameCapability: EPUBSpreadFrameCapability(id: UUID())
        ))
        let waiter = Task { @MainActor in
            await readiness.waitForCommandReadiness(for: generation)
        }
        await Task.yield()

        readiness.finishInitialization(rootLease, outcome: .failed)

        XCTAssertFalse(readiness.isCommandReady)
        let outcome = await waiter.value
        XCTAssertEqual(outcome, .invalidated)
    }

    func testFailedRuntimeMutationInvalidatesRetainedFrameCapability() throws {
        let readiness = try makeReadyReadiness()
        let mutation = try XCTUnwrap(readiness.beginMutation())

        readiness.finishMutation(mutation, outcome: .failed)

        XCTAssertFalse(readiness.isCommandReady)
        XCTAssertEqual(
            readiness.state,
            .unavailable(generation: mutation.generation + 1)
        )
    }

    func testSupersededRuntimeMutationReleasesRetainedFrameCapability() throws {
        let readiness = try makeReadyReadiness()
        let mutation = try XCTUnwrap(readiness.beginMutation())

        readiness.finishMutation(mutation, outcome: .superseded)

        guard case let .ready(generation, frameCapability) = readiness.state else {
            return XCTFail("Superseded mutation did not restore command readiness")
        }
        XCTAssertEqual(generation, mutation.generation)
        XCTAssertNotNil(frameCapability)
    }

    func testLatestMutationReplaysAnUpdateThatArrivesDuringInitialWrite() async {
        let mutation = EPUBLatestMutation(initialValue: 1)
        var writes: [Int] = []
        var releaseFirstWrite: CheckedContinuation<Void, Never>?

        let application = Task { @MainActor in
            await mutation.applyLatest { value in
                writes.append(value)
                if value == 1 {
                    await withCheckedContinuation { continuation in
                        releaseFirstWrite = continuation
                    }
                }
                return true
            }
        }
        await waitUntil { releaseFirstWrite != nil }

        mutation.update(2)
        releaseFirstWrite?.resume()

        let succeeded = await application.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(writes, [1, 2])
        XCTAssertEqual(mutation.latestValue, 2)
    }

    func testInitializationLayoutLeaseGatesReadinessAndAppliesLatestViewport() async throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let layouts = EPUBLatestMutation(initialValue: 320)
        layouts.update(640)
        let rootLease = try XCTUnwrap(readiness.beginInitialization(
            for: generation,
            frameCapability: EPUBSpreadFrameCapability(id: UUID())
        ))
        let layoutLease = try XCTUnwrap(readiness.acquireWriterLease(for: generation))
        var appliedWidths: [Int] = []
        var releaseStability: CheckedContinuation<Void, Never>?

        let layout = Task { @MainActor in
            await layouts.applyLatest { width in
                appliedWidths.append(width)
                if width == 640 {
                    await withCheckedContinuation { continuation in
                        releaseStability = continuation
                    }
                }
                return true
            }
        }
        await waitUntil { releaseStability != nil }
        readiness.finishInitialization(rootLease, outcome: .succeeded)

        XCTAssertEqual(
            readiness.state,
            .initializing(generation: generation, activeWriterLeases: 1)
        )
        layouts.update(768)
        releaseStability?.resume()
        let layoutSucceeded = await layout.value
        XCTAssertTrue(layoutSucceeded)
        readiness.release(layoutLease)

        XCTAssertEqual(appliedWidths, [640, 768])
        XCTAssertTrue(readiness.isCommandReady)
    }

    private func waitUntil(
        _ predicate: @MainActor () -> Bool,
        iterations: Int = 100
    ) async {
        for _ in 0 ..< iterations {
            if predicate() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }

    private func makeReadyReadiness() throws -> EPUBSpreadReadiness {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let initialization = try XCTUnwrap(readiness.beginInitialization(
            for: generation,
            frameCapability: EPUBSpreadFrameCapability(id: UUID())
        ))
        readiness.finishInitialization(initialization, outcome: .succeeded)
        return readiness
    }
}
