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
        XCTAssertEqual(
            EPUBNavigatorViewController.readySpreadNavigationDisposition(
                for: outcome,
                targetIsCurrent: true,
                documentIsCurrent: readiness.generation == generation,
                taskIsCancelled: false
            ),
            .cancelled
        )
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

    func testCurrentInitializationFailureMapsToNavigationMiss() async throws {
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
        XCTAssertEqual(outcome, .failed(generation: generation))
        XCTAssertEqual(readiness.state, .failed(generation: generation))
        let laterOutcome = await readiness.waitForCommandReadiness(for: generation)
        XCTAssertEqual(laterOutcome, .failed(generation: generation))
        XCTAssertEqual(
            EPUBNavigatorViewController.readySpreadNavigationDisposition(
                for: laterOutcome,
                targetIsCurrent: true,
                documentIsCurrent: readiness.generation == generation,
                taskIsCancelled: false
            ),
            .miss
        )
    }

    func testReloadAfterFailureAdvancesOnceAndIgnoresStaleFailure() throws {
        let readiness = EPUBSpreadReadiness()
        let failedGeneration = readiness.beginLoading()
        let staleLease = try XCTUnwrap(readiness.beginInitialization(
            for: failedGeneration,
            frameCapability: EPUBSpreadFrameCapability(id: UUID())
        ))

        readiness.finishInitialization(staleLease, outcome: .failed)
        let replacementGeneration = readiness.beginLoading()

        XCTAssertEqual(replacementGeneration, failedGeneration + 1)
        let replacementCapability = EPUBSpreadFrameCapability(id: UUID())
        let replacementLease = try XCTUnwrap(readiness.beginInitialization(
            for: replacementGeneration,
            frameCapability: replacementCapability
        ))
        readiness.finishInitialization(staleLease, outcome: .failed)
        readiness.finishInitialization(replacementLease, outcome: .succeeded)

        XCTAssertEqual(
            readiness.state,
            .ready(
                generation: replacementGeneration,
                frameCapability: replacementCapability
            )
        )
    }

    func testFailedRuntimeMutationRevokesCapabilityWithoutChangingIdentity() throws {
        let readiness = try makeReadyReadiness()
        let mutation = try XCTUnwrap(readiness.beginMutation())

        readiness.finishMutation(mutation, outcome: .failed)

        XCTAssertFalse(readiness.isCommandReady)
        XCTAssertNil(readiness.currentFrameCapability)
        XCTAssertEqual(
            readiness.state,
            .failed(generation: mutation.generation)
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

    func testCurrentFrameCapabilitySurvivesPositionMutationAndDiesWithTheDocument() throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let capability = EPUBSpreadFrameCapability(id: UUID())
        let initialization = try XCTUnwrap(readiness.beginInitialization(
            for: generation,
            frameCapability: capability
        ))
        XCTAssertEqual(readiness.currentFrameCapability, capability)

        readiness.finishInitialization(initialization, outcome: .succeeded)
        XCTAssertEqual(readiness.currentFrameCapability, capability)

        // A same-document position mutation advances the generation but keeps
        // the frame document: the capability must survive both phases.
        let writer = try XCTUnwrap(readiness.acquirePositionWriter())
        XCTAssertNotEqual(writer.generation, generation)
        XCTAssertEqual(readiness.currentFrameCapability, capability)

        readiness.release(writer)
        XCTAssertEqual(readiness.currentFrameCapability, capability)

        // Document replacement/invalidation clears the capability.
        readiness.invalidate()
        XCTAssertNil(readiness.currentFrameCapability)
    }

    func testCurrentFrameCapabilityIsClearedByFailureAndReplacementLoad() throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let capability = EPUBSpreadFrameCapability(id: UUID())
        _ = try XCTUnwrap(readiness.beginInitialization(
            for: generation,
            frameCapability: capability
        ))

        readiness.fail(ifCurrent: generation)
        XCTAssertNil(readiness.currentFrameCapability)

        readiness.beginLoading()
        XCTAssertNil(readiness.currentFrameCapability)
    }

    func testDocumentScopedCommandReadinessReturnsImmediatelyWhenReady() async throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let capability = EPUBSpreadFrameCapability(id: UUID())
        let initialization = try XCTUnwrap(readiness.beginInitialization(
            for: generation,
            frameCapability: capability
        ))
        readiness.finishInitialization(initialization, outcome: .succeeded)

        let outcome = await readiness.waitForCommandReadiness(forDocument: capability)
        XCTAssertEqual(
            outcome,
            .ready(generation: generation, frameCapability: capability)
        )
    }

    func testDocumentScopedCommandReadinessSurvivesPositionMutation() async throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let capability = EPUBSpreadFrameCapability(id: UUID())
        let initialization = try XCTUnwrap(readiness.beginInitialization(
            for: generation,
            frameCapability: capability
        ))
        readiness.finishInitialization(initialization, outcome: .succeeded)

        // A position writer (a precise locator landing) races in right after
        // readiness publishes and advances the generation.
        let writer = try XCTUnwrap(readiness.acquirePositionWriter())

        var outcome: EPUBSpreadReadiness.WaitOutcome?
        let waiter = Task { @MainActor in
            let value = await readiness.waitForCommandReadiness(forDocument: capability)
            outcome = value
            return value
        }
        await Task.yield()
        XCTAssertNil(outcome)

        readiness.release(writer)

        let resumed = await waiter.value
        XCTAssertEqual(
            resumed,
            .ready(generation: writer.generation, frameCapability: capability)
        )
    }

    func testDocumentScopedCommandReadinessIsInvalidatedByReplacementLoad() async throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let capability = EPUBSpreadFrameCapability(id: UUID())
        let initialization = try XCTUnwrap(readiness.beginInitialization(
            for: generation,
            frameCapability: capability
        ))
        readiness.finishInitialization(initialization, outcome: .succeeded)
        _ = try XCTUnwrap(readiness.acquirePositionWriter())

        let waiter = Task { @MainActor in
            await readiness.waitForCommandReadiness(forDocument: capability)
        }
        await Task.yield()

        readiness.beginLoading()

        let outcome = await waiter.value
        XCTAssertEqual(outcome, .invalidated)
    }

    func testDocumentScopedCommandReadinessRejectsForeignCapabilityImmediately() async throws {
        let readiness = try makeReadyReadiness()

        let outcome = await readiness.waitForCommandReadiness(
            forDocument: EPUBSpreadFrameCapability(id: UUID())
        )
        XCTAssertEqual(outcome, .invalidated)
    }

    // MARK: - Deadline-bounded document-scoped readiness

    func testDeadlineBoundedDocumentReadinessSurvivesPositionMutation() async throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let capability = EPUBSpreadFrameCapability(id: UUID())
        let initialization = try XCTUnwrap(readiness.beginInitialization(
            for: generation,
            frameCapability: capability
        ))
        readiness.finishInitialization(initialization, outcome: .succeeded)

        // The landing path reads the generation, then yields before its wait
        // registers. A decoration or position writer acquired in that window
        // advances the generation while keeping the same frame document — the
        // benign same-document mutation that used to surface as `.cancelled`.
        let writer = try XCTUnwrap(readiness.acquirePositionWriter())

        let waiter = Task { @MainActor in
            await readiness.waitForCommandReadiness(
                forDocument: capability,
                until: ContinuousClock.now.advanced(by: .seconds(5))
            )
        }
        await Task.yield()

        readiness.release(writer)

        let resumed = await waiter.value
        XCTAssertEqual(
            resumed,
            .ready(generation: writer.generation, frameCapability: capability)
        )
    }

    func testDeadlineBoundedDocumentReadinessTimesOutWithoutPoisoningLateReadiness() async throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let capability = EPUBSpreadFrameCapability(id: UUID())
        let initialization = try XCTUnwrap(readiness.beginInitialization(
            for: generation,
            frameCapability: capability
        ))
        readiness.finishInitialization(initialization, outcome: .succeeded)
        let writer = try XCTUnwrap(readiness.acquirePositionWriter())

        let timedOut = await readiness.waitForCommandReadiness(
            forDocument: capability,
            until: ContinuousClock.now.advanced(by: .milliseconds(10))
        )
        XCTAssertEqual(timedOut, .timedOut)

        readiness.release(writer)
        let lateOutcome = await readiness.waitForCommandReadiness(forDocument: capability)
        XCTAssertEqual(
            lateOutcome,
            .ready(generation: writer.generation, frameCapability: capability)
        )
    }

    func testDeadlineBoundedDocumentRewaitsReuseOneAbsoluteDeadline() async throws {
        let readiness = try makeReadyReadiness()
        let capability = try XCTUnwrap(readiness.currentFrameCapability)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var observedDeadlines: [ContinuousClock.Instant] = []
        var observedGenerations: [EPUBSpreadReadiness.Generation] = []

        let outcome = await readiness.waitForCommandReadiness(
            forDocument: capability,
            until: deadline
        ) { generation, receivedDeadline in
            observedGenerations.append(generation)
            observedDeadlines.append(receivedDeadline)
            guard observedDeadlines.count == 3 else {
                guard let writer = readiness.acquirePositionWriter() else {
                    return .failed(generation: generation)
                }
                readiness.release(writer)
                return .invalidated
            }
            return .ready(generation: generation, frameCapability: capability)
        }

        XCTAssertEqual(
            outcome,
            .ready(generation: readiness.generation, frameCapability: capability)
        )
        XCTAssertEqual(observedDeadlines, [deadline, deadline, deadline])
        XCTAssertEqual(observedGenerations.count, 3)
        if let firstGeneration = observedGenerations.first {
            XCTAssertEqual(observedGenerations, [
                firstGeneration,
                firstGeneration + 1,
                firstGeneration + 2,
            ])
        }
    }

    // MARK: - The document-following law

    // The `.invalidated` re-wait arm is the whole reason a document-scoped wait exists, and it is
    // unreachable from outside: its only production trigger is `beginMutation` draining an
    // already-registered waiter, which needs the main-actor race between reading `generation` and
    // registering on it. Every other test in this file acquires its writer BEFORE starting the
    // waiter, so the loop registers on the mutation generation directly and returns on iteration
    // one — an implementation that replaced `continue` with `return .invalidated` would pass all
    // of them. These drive the loop with an injected per-generation wait instead.

    func testDocumentFollowingReWaitsOnTheSuccessorGenerationAfterASameDocumentMutation() async throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let capability = EPUBSpreadFrameCapability(id: UUID())
        let initialization = try XCTUnwrap(readiness.beginInitialization(
            for: generation,
            frameCapability: capability
        ))
        readiness.finishInitialization(initialization, outcome: .succeeded)

        var awaitedGenerations: [EPUBSpreadReadiness.Generation] = []
        let outcome = await readiness.waitForCommandReadiness(
            forDocument: capability
        ) { awaited in
            awaitedGenerations.append(awaited)
            guard awaitedGenerations.count > 1 else {
                // The first wait is drained by a same-document mutation. Advance the generation
                // for real so the loop's re-read observes a successor rather than a replay.
                _ = readiness.acquirePositionWriter()
                return .invalidated
            }
            return .ready(generation: awaited, frameCapability: capability)
        }

        XCTAssertEqual(
            outcome,
            .ready(generation: readiness.generation, frameCapability: capability)
        )
        XCTAssertEqual(awaitedGenerations.count, 2)
        XCTAssertEqual(awaitedGenerations.first, generation)
        // The re-wait must read the CURRENT generation, not replay the drained one.
        XCTAssertEqual(awaitedGenerations.last, readiness.generation)
        XCTAssertNotEqual(awaitedGenerations.first, awaitedGenerations.last)
    }

    func testDocumentFollowingStopsWhenTheCapabilityDiesUnderTheReWait() async throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let capability = EPUBSpreadFrameCapability(id: UUID())
        let initialization = try XCTUnwrap(readiness.beginInitialization(
            for: generation,
            frameCapability: capability
        ))
        readiness.finishInitialization(initialization, outcome: .succeeded)

        var waitCount = 0
        let outcome = await readiness.waitForCommandReadiness(
            forDocument: capability
        ) { _ in
            waitCount += 1
            // A replacement load, not a same-document mutation: the document is gone.
            readiness.beginLoading()
            return .invalidated
        }

        XCTAssertEqual(outcome, .invalidated)
        // The capability guard runs BEFORE the re-wait, so the loop must not wait a second time.
        XCTAssertEqual(waitCount, 1)
    }

    func testDocumentFollowingRejectsReadinessPublishedForADifferentDocument() async throws {
        let readiness = try makeReadyReadiness()
        let capability = try XCTUnwrap(readiness.currentFrameCapability)

        let outcome = await readiness.waitForCommandReadiness(
            forDocument: capability
        ) { awaited in
            .ready(generation: awaited, frameCapability: EPUBSpreadFrameCapability(id: UUID()))
        }

        XCTAssertEqual(outcome, .invalidated)
    }

    func testDeadlineBoundedDocumentReadinessReportsCancellationDistinctlyFromTimeout() async throws {
        // Cancellation and timeout diverge at the consumer — `.cancelled` stops silently while
        // `.timedOut` advances a fallback rung — and the only thing separating them is one `catch`
        // arm in the deadline racer. The far deadline makes a `.timedOut` result unambiguously a
        // misclassification rather than a race.
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let capability = EPUBSpreadFrameCapability(id: UUID())
        _ = try XCTUnwrap(readiness.beginInitialization(
            for: generation,
            frameCapability: capability
        ))

        let waiter = Task { @MainActor in
            await readiness.waitForCommandReadiness(
                forDocument: capability,
                until: ContinuousClock.now.advanced(by: .seconds(30))
            )
        }
        await Task.yield()

        waiter.cancel()

        let outcome = await waiter.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testDeadlineBoundedDocumentReadinessIsInvalidatedByReplacementLoad() async throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let capability = EPUBSpreadFrameCapability(id: UUID())
        let initialization = try XCTUnwrap(readiness.beginInitialization(
            for: generation,
            frameCapability: capability
        ))
        readiness.finishInitialization(initialization, outcome: .succeeded)
        _ = try XCTUnwrap(readiness.acquirePositionWriter())

        let waiter = Task { @MainActor in
            await readiness.waitForCommandReadiness(
                forDocument: capability,
                until: ContinuousClock.now.advanced(by: .seconds(5))
            )
        }
        await Task.yield()

        readiness.beginLoading()

        let outcome = await waiter.value
        XCTAssertEqual(outcome, .invalidated)
    }

    // MARK: - Decoration replay lease discipline

    func testDecorationReplayWriteHoldsALeaseDuringTheWriteOnAReadySpread() async throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        let capability = EPUBSpreadFrameCapability(id: UUID())
        let initialization = try XCTUnwrap(readiness.beginInitialization(
            for: generation,
            frameCapability: capability
        ))
        readiness.finishInitialization(initialization, outcome: .succeeded)
        XCTAssertEqual(
            readiness.state,
            .ready(generation: generation, frameCapability: capability)
        )

        var observedInitializingLeaseCount: Int?
        let didWrite = await EPUBNavigatorViewController.runDecorationReplayWrite(
            on: readiness
        ) {
            if case let .initializing(_, leases) = readiness.state {
                observedInitializingLeaseCount = leases
            }
        }

        XCTAssertTrue(didWrite)
        // The write ran while a single generation-bound lease was held, so a
        // concurrent command-readiness reader could not observe `.ready`
        // mid-write.
        XCTAssertEqual(observedInitializingLeaseCount, 1)
        // The mutation advanced the generation and republished readiness against
        // the SAME frame document.
        XCTAssertEqual(
            readiness.state,
            .ready(generation: generation + 1, frameCapability: capability)
        )
    }

    func testDecorationReplayWriteSkipsASpreadThatIsNotCommandReady() async {
        let loading = EPUBSpreadReadiness()
        _ = loading.beginLoading()

        var wrote = false
        let didWrite = await EPUBNavigatorViewController.runDecorationReplayWrite(
            on: loading
        ) {
            wrote = true
        }

        XCTAssertFalse(didWrite)
        XCTAssertFalse(wrote)
        XCTAssertEqual(loading.state, .loading(generation: 1))
    }

    func testDecorationReplayWriteSkipsASpreadMidInitialization() async throws {
        let readiness = EPUBSpreadReadiness()
        let generation = readiness.beginLoading()
        _ = try XCTUnwrap(readiness.beginInitialization(
            for: generation,
            frameCapability: EPUBSpreadFrameCapability(id: UUID())
        ))
        XCTAssertEqual(
            readiness.state,
            .initializing(generation: generation, activeWriterLeases: 1)
        )

        var wrote = false
        let didWrite = await EPUBNavigatorViewController.runDecorationReplayWrite(
            on: readiness
        ) {
            wrote = true
        }

        // The `isCommandReady` gate rejects the write before
        // `acquirePositionWriter()` could join the in-flight initialization as
        // an additional writer, so the lease count is untouched.
        XCTAssertFalse(didWrite)
        XCTAssertFalse(wrote)
        XCTAssertEqual(
            readiness.state,
            .initializing(generation: generation, activeWriterLeases: 1)
        )
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
