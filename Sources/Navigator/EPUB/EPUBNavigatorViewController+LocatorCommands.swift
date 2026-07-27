//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

/// The locator-command surface: the bridge navigation this fork added, the
/// receipt that binds the world a command landed in, and the readiness waits
/// those two rest on.
///
/// It lives in an extension because it is entirely additive to upstream's
/// `EPUBNavigatorViewController`. Keeping it out of the class body is what
/// makes it zero-conflict on a rebase — the highest-value property this file
/// has, since the view controller is the most-diverged file in the fork.
///
/// Only the stored state stayed behind: Swift extensions cannot declare stored
/// properties, so `locatorOperationSequence`, `activeLocatorOperationSlot`,
/// `locatorNavigationTaskQueue`, `idleNotificationGate` and `locatorClock`
/// remain in the class and are `internal` rather than `private` so this file
/// can reach them. That access widening is the whole cost of the split.
extension EPUBNavigatorViewController {
    /// Whether the bridge locator command may animate its scroll. After a
    /// resource hop the document was already positioned at the FULL target
    /// locator during spread initialization (pre-reveal, via the pending
    /// location), so the bridge run is a verification of an already-positioned
    /// page and must be invisible — animating it replays the scroll after
    /// reveal as a spurious slide. Without a hop the bridge IS the user-visible
    /// motion and honors the caller's request.
    nonisolated static func bridgeCommandAnimated(
        requestedAnimated: Bool,
        didHopToResource: Bool
    ) -> Bool {
        requestedAnimated && !didHopToResource
    }

    /// Navigates with the bounded, fixed-source locator command bridge and
    /// reports the command's actual landing result, together with the receipt
    /// binding the world it landed in.
    ///
    /// The receipt is what lets the caller's later steps — uniqueness
    /// validation, a transient decoration, a fallback rung — prove they are
    /// still acting on the world this command landed in rather than on whatever
    /// replaced it while they were suspended. It is present only for `.landed`.
    public func navigateToLocatorJSON(
        _ locatorJSON: String,
        animated: Bool
    ) async -> EPUBLocatorNavigationResult {
        let receiptSlot = EPUBLocatorCommandReceiptSlot()
        let outcome = await locatorNavigationTaskQueue.run { [weak self] in
            guard let self else { return .cancelled }
            return await self.performLocatorNavigation(
                locatorJSON,
                animated: animated,
                receiptSlot: receiptSlot
            )
        } cancellationRelay: { [weak self] in
            await self?.cancelInFlightLocatorNavigation()
        }
        // A landing is the only outcome that bound a world. The queue also
        // downgrades a completed operation to `.cancelled` when the request was
        // superseded on the way out, and that downgrade must drop the receipt
        // with it.
        guard outcome == .landed else {
            return .unreceipted(outcome)
        }
        return EPUBLocatorNavigationResult(outcome: outcome, receipt: receiptSlot.receipt)
    }

    private func performLocatorNavigation(
        _ locatorJSON: String,
        animated: Bool,
        receiptSlot: EPUBLocatorCommandReceiptSlot
    ) async -> LocatorNavigationOutcome {
        guard !Task.isCancelled else {
            return .cancelled
        }
        // Every locator navigation takes the next sequence number, so a later
        // one starting is exactly what makes an earlier one's receipt stale.
        locatorOperationSequence &+= 1
        // Operation start: the ONE deadline every rung below spends from — the
        // cross-resource hop, page identity, command readiness, and the bridge
        // command's own viewport/settle/correction waits. No rung re-mints it, so
        // the wall-clock cost of a landing can no longer grow with the number of
        // resources it passes through.
        let deadline = EPUBLocatorOperationDeadline(
            startingAt: locatorClock.now(),
            budget: .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds)
        )
        guard
            let payload = try? EPUBLocatorCommandDecoder.decode(locatorJSON),
            let decoded = try? Locator(json: payload.locator)
        else {
            return .miss
        }
        let locator = publication.normalizeLocator(decoded)
        guard
            let paginationView,
            let readingOrderIndex = readingOrder.firstIndexWithHREF(locator.href),
            let spreadIndex = spreads.firstIndexWithReadingOrderIndex(readingOrderIndex)
        else {
            return .miss
        }

        let spreadView: EPUBSpreadView
        var didHopToResource = false
        if
            paginationView.currentIndex == spreadIndex,
            let loaded = paginationView.loadedViews[spreadIndex] as? EPUBSpreadView,
            loaded.isCommandReady
        {
            spreadView = loaded
        } else {
            // Hop with the FULL locator, not a resource-only one: the pending
            // location applies it as the final initialization stage, so the
            // spread reveals ALREADY positioned at the target (a single
            // perceived landing — no chapter-top paint, no post-reveal slide).
            // The bridge run below stays the truthful landing authority.
            didHopToResource = true
            // Publish the hop so the TARGET spread's stylesheet/font/geometry
            // stabilization spends what is LEFT of this deadline rather than minting a
            // fresh allowance of its own. The spread initializes on its own load event,
            // so it pulls this back through the delegate instead of receiving it down
            // the call stack. Scoped to the hop and identity-guarded on withdrawal: a
            // preloaded neighbour loading in this window is not part of the operation,
            // and a superseded predecessor unwinding here must not clear a successor's
            // entry.
            let hop = EPUBActiveLocatorOperation(
                readingOrderIndex: readingOrderIndex,
                deadline: deadline
            )
            activeLocatorOperationSlot.publish(hop)
            defer { activeLocatorOperationSlot.clear(hop) }

            let resourceOutcome = await goToLocator(
                locator,
                options: NavigatorGoOptions(animated: animated)
            )
            switch Self.navigationDisposition(for: resourceOutcome) {
            case .landed:
                break
            case .miss:
                return .miss
            case .cancelled:
                return .cancelled
            }
            switch await waitForReadySpread(at: spreadIndex, deadline: deadline) {
            case let .ready(loaded):
                spreadView = loaded
            case .miss:
                return .miss
            case .cancelled:
                return .cancelled
            }
        }

        guard let writerLease = spreadView.readiness.acquirePositionWriter() else {
            return .cancelled
        }
        defer { spreadView.readiness.release(writerLease) }

        // Expose this bridge so a superseding request's relay can abort the
        // command below in its own frame. Clear only if a newer request has not
        // already claimed the tracker (the bounded-acknowledgement race).
        let bridge = spreadView.locatorCommandBridge
        inFlightLocatorBridge = bridge
        defer {
            if inFlightLocatorBridge === bridge {
                inFlightLocatorBridge = nil
            }
        }

        let result = await bridge.navigate(
            locatorJSON: locatorJSON,
            targetHREF: locator.href,
            animated: Self.bridgeCommandAnimated(
                requestedAnimated: animated,
                didHopToResource: didHopToResource
            ),
            deadline: deadline
        )
        switch result.outcome {
        case .applied:
            // Mint the receipt from the SAME snapshot every later revalidation
            // rebuilds, so the two can never drift apart. If the world has
            // already moved off this spread by the time the command reports,
            // there is nothing truthful to bind and the landing carries no
            // receipt — the caller then treats every later step as stale, which
            // is the fail-closed direction.
            if
                let world = currentLocatorWorld(),
                world.spreadIndex == spreadIndex,
                world.spreadIdentity == ObjectIdentifier(spreadView)
            {
                receiptSlot.record(EPUBLocatorCommandReceipt(world: world))
            }
            return .landed
        case .miss:
            return .miss
        case .cancelled:
            return .cancelled
        }
    }

    /// Snapshots the render world of the spread currently on screen.
    ///
    /// One builder serves both minting and revalidation: a receipt is this
    /// snapshot taken at landing, and currency is the comparison against a later
    /// one. Sharing the builder is what makes "the same world" mean the same
    /// thing at both ends.
    private func currentLocatorWorld() -> EPUBLocatorCommandReceipt.World? {
        guard let paginationView else { return nil }
        let index = paginationView.currentIndex
        guard let spreadView = paginationView.loadedViews[index] as? EPUBSpreadView else {
            return nil
        }
        return EPUBLocatorCommandReceipt.World(
            spreadIndex: index,
            spreadIdentity: ObjectIdentifier(spreadView),
            generation: spreadView.readiness.generation,
            frameCapability: spreadView.readiness.currentFrameCapability,
            isCommandReady: spreadView.isCommandReady,
            operationSequence: locatorOperationSequence
        )
    }

    /// Whether a landing receipt still describes the live world.
    ///
    /// Callers revalidate after every suspension between the landing and the
    /// act it authorizes — uniqueness validation, a transient decoration apply
    /// or clear — so a command superseded mid-flight cannot paint into, or wipe,
    /// the world its successor established.
    public func isReceiptCurrent(_ receipt: EPUBLocatorCommandReceipt) -> Bool {
        guard let world = currentLocatorWorld() else { return false }
        return receipt.isCurrent(in: world)
    }

    /// Checks the transient-highlight uniqueness rule inside the isolated
    /// command world. Only a closed command outcome crosses back to native.
    ///
    /// Requires the landing's receipt, and revalidates it on both sides of the
    /// bridge round-trip: a uniqueness answer is only meaningful for the
    /// document the command landed in, and a stale `true` is precisely what
    /// would let a superseded command paint a look-alike occurrence in whatever
    /// replaced it.
    public func isLocatorTextUnique(
        _ locatorJSON: String,
        cssSelector: String?,
        receipt: EPUBLocatorCommandReceipt
    ) async -> Bool {
        guard
            !Task.isCancelled,
            isReceiptCurrent(receipt),
            let payload = try? EPUBLocatorCommandDecoder.decode(locatorJSON),
            let decoded = try? Locator(json: payload.locator)
        else {
            return false
        }
        let locator = publication.normalizeLocator(decoded)
        guard
            let readingOrderIndex = readingOrder.firstIndexWithHREF(locator.href),
            let spreadIndex = spreads.firstIndexWithReadingOrderIndex(readingOrderIndex),
            let paginationView,
            paginationView.currentIndex == spreadIndex,
            let spreadView = paginationView.loadedViews[spreadIndex] as? EPUBSpreadView,
            spreadView.isCommandReady
        else {
            return false
        }
        let result = await spreadView.locatorCommandBridge.validateUniqueTextMatch(
            locatorJSON: locatorJSON,
            targetHREF: locator.href,
            cssSelector: cssSelector,
            deadline: EPUBLocatorOperationDeadline(
                startingAt: locatorClock.now(),
                budget: .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds)
            )
        )
        guard !Task.isCancelled, isReceiptCurrent(receipt) else { return false }
        return result.outcome == .applied
    }

    /// Extracts a bounded visible excerpt through fixed source in the isolated
    /// content world. Publisher content is returned only to the local caller.
    public func extractVisibleText(maximumLength: Int) async -> String? {
        guard
            let paginationView,
            let spreadView = paginationView.currentView as? EPUBSpreadView,
            spreadView.isCommandReady
        else {
            return nil
        }
        let targetHREF = currentLocation?.href ?? spreadView.spread.first.link.url()
        return await spreadView.locatorCommandBridge.visibleText(
            targetHREF: targetHREF,
            maximumLength: maximumLength,
            deadline: EPUBLocatorOperationDeadline(
                startingAt: locatorClock.now(),
                budget: .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds)
            )
        )
    }

    private enum ReadySpreadWaitResult {
        case ready(EPUBSpreadView)
        case miss
        case cancelled
    }

    /// - Parameter deadline: the operation-wide deadline; this rung is bounded by the
    ///   smaller of its own cap and what remains of it.
    private func waitForReadySpread(
        at index: Int,
        deadline: EPUBLocatorOperationDeadline
    ) async -> ReadySpreadWaitResult {
        guard
            let paginationView,
            paginationView.currentIndex == index
        else {
            return .cancelled
        }

        guard let spreadView = await paginationView.waitForCurrentPage(at: index) as? EPUBSpreadView else {
            let targetIsCurrent = self.paginationView === paginationView
                && paginationView.currentIndex == index
            return Task.isCancelled || !targetIsCurrent ? .cancelled : .miss
        }

        // Bounded by the SMALLER of this rung's own cap and what is left of the
        // operation: the per-rung cap still limits a single stuck readiness wait,
        // but it can no longer extend a landing past the operation deadline.
        let readinessCap = locatorClock.now().advanced(
            by: EPUBSpreadReadiness.commandReadinessBudget
        )
        let readinessDeadline = deadline.effectiveDeadline(cappedBy: readinessCap)
        // Follow the DOCUMENT, not a fixed generation. Between reading readiness
        // here and the wait registering, the host can acquire a position or
        // decoration writer on a `.ready` spread — which advances the generation
        // while keeping the same frame document. A generation-keyed wait sees
        // that benign same-document mutation as `.invalidated` and reports the
        // whole landing `.cancelled`, so the tap does nothing: no fallback rung,
        // no logged failure. The document-keyed wait resumes on the successor
        // generation instead. Only when no document is live is there nothing to
        // follow, and the generation wait is the honest fallback.
        let outcome: EPUBSpreadReadiness.WaitOutcome
        if let capability = spreadView.readiness.currentFrameCapability {
            outcome = await spreadView.readiness.waitForCommandReadiness(
                forDocument: capability,
                until: readinessDeadline
            )
        } else {
            outcome = await spreadView.readiness.waitForCommandReadiness(
                for: spreadView.readiness.generation,
                until: readinessDeadline
            )
        }
        let targetIsCurrent = self.paginationView === paginationView
            && paginationView.currentIndex == index
            && paginationView.loadedViews[index] === spreadView
        // Currency is asked of the world the OUTCOME bound, matching
        // `EPUBLocatorCommandReceipt.isCurrent`.
        let documentIsCurrent = Self.readySpreadDocumentIsCurrent(
            for: outcome,
            currentCapability: spreadView.readiness.currentFrameCapability,
            currentGeneration: spreadView.readiness.generation
        )

        switch Self.readySpreadNavigationDisposition(
            for: outcome,
            targetIsCurrent: targetIsCurrent,
            documentIsCurrent: documentIsCurrent,
            taskIsCancelled: Task.isCancelled
        ) {
        case .landed:
            return .ready(spreadView)
        case .miss:
            return .miss
        case .cancelled:
            return .cancelled
        }
    }
}
