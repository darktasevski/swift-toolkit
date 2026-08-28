//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit
import UIKit.UIGestureRecognizerSubclass

/// A ``UIGestureRecognizer`` that will forward the touch events to an
/// ``InputObserving``. It will never recognize any gesture, only forward the
/// events.
@MainActor
final class InputObservingGestureRecognizerAdapter: UIGestureRecognizer {
    let observer: InputObserving

    /// Serial event processor that ensures events are processed in order.
    /// This prevents race conditions when touches from different gestures overlap.
    private var eventProcessor: Task<Void, Never>?
    private var eventContinuation: AsyncStream<PointerEvent>.Continuation?

    init(observer: CompositeInputObserver) {
        self.observer = observer
        super.init(target: nil, action: nil)

        // Set up serial event processing via AsyncStream with bounded buffer
        // to prevent unbounded memory growth under backpressure
        let (stream, continuation) = AsyncStream<PointerEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        eventContinuation = continuation

        // Process events serially to ensure order is preserved
        eventProcessor = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { break }
                _ = await self.observer.didReceive(event)
            }
        }
    }

    deinit {
        // Finish the stream first to signal no more events, then cancel the task.
        // Note: Events queued but not yet processed will be lost. This is
        // intentional as the gesture recognizer is being deallocated along with
        // the view hierarchy it was attached to.
        eventContinuation?.finish()
        eventProcessor?.cancel()
    }

    /// Stores the ``PointerEvent`` that were notified to the `observer`, to
    /// cancel them if the gesture recognizer is resetted before the touches
    /// are cancelled or ended.
    private var pendingPointers: [AnyHashable: PointerEvent] = [:]

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        on(.down, touches: touches, event: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        on(.move, touches: touches, event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        on(.cancel, touches: touches, event: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        on(.up, touches: touches, event: event)
    }

    override func reset() {
        // The gesture recognizer can be resetted without receiving the ended
        // or cancelled callbacks for touch events already sent. We will cancel
        // them manually for the observer.
        let pointersToReset = pendingPointers
        pendingPointers = [:]

        // Send cancel events through the serial queue to maintain order
        for (_, event) in pointersToReset {
            var event = event
            event.phase = .cancel
            eventContinuation?.yield(event)
        }
    }

    private func on(_ phase: PointerEvent.Phase, touches: Set<UITouch>, event: UIEvent) {
        for touch in touches {
            guard let view = view else {
                continue
            }

            let pointer = Pointer(touch: touch, event: event)
            let pointerEvent = PointerEvent(
                pointer: pointer,
                phase: phase,
                location: touch.location(in: view),
                modifiers: KeyModifiers(event: event)
            )

            switch phase {
            case .down, .move:
                pendingPointers[pointer.id] = pointerEvent
            case .up, .cancel:
                pendingPointers.removeValue(forKey: pointer.id)
            }

            // Queue the event for serial processing
            eventContinuation?.yield(pointerEvent)
        }
    }
}
