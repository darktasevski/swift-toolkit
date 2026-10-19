//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit

/// The reflowable spread's settled-location observation: when a read may
/// start, and the scroll and scene signals that ask for one. Its stored
/// state stays in the class body (`builtLocationObservation`,
/// `hasActivePositionCommand`).
extension EPUBReflowableSpreadView {
    var locationObservation: EPUBLocationObservation {
        if let builtLocationObservation {
            return builtLocationObservation
        }
        let observation = EPUBLocationObservation(
            scheduler: locatorCommandBridge.deadlineScheduler,
            eligibility: { [weak self] in
                self?.observationEligibility ?? .unsettled
            },
            documentCapability: { [weak self] in
                self?.readiness.currentFrameCapability
            },
            nativeScrollOffset: { [weak self] in
                self.map { EPUBScrollOffset(x: Double($0.scrollView.contentOffset.x), y: Double($0.scrollView.contentOffset.y)) }
            },
            read: { [weak self] deadline, completion in
                guard let self else {
                    return .frameUnavailable
                }
                return locatorCommandBridge.readProgression(
                    targetHREF: viewModel.url(to: spread.first.link),
                    deadline: deadline,
                    completion: completion
                )
            },
            reissueHandshake: { [weak self] capability in
                self?.locatorCommandBridge.setFrameCapability(capability)
            },
            onAccepted: { [weak self] _ in
                self?.observationDidAccept()
            }
        )
        builtLocationObservation = observation
        return observation
    }

    /// Read live at every decision: ready, commanded by nothing, and at rest.
    var observationEligibility: EPUBObservationEligibility {
        guard
            case let .ready(_, capability) = readiness.state,
            !hasActivePositionCommand
        else {
            return .unsettled
        }
        if scrollView.isDragging || scrollView.isDecelerating {
            return .nativeMotion
        }
        return .eligible(capability)
    }

    func observationDidAccept() {
        // An equal range is reported too: pending navigator work may be
        // waiting for it.
        delegate?.spreadViewPagesDidChange(self)
    }

    // MARK: - Owning scene

    /// Only the scene showing this spread grants recovery when it becomes
    /// active again; other windows and scenes are ignored.
    @objc func sceneDidActivate(_ notification: Notification) {
        guard
            let scene = window?.windowScene,
            notification.object as AnyObject? === scene
        else {
            return
        }
        locationObservation.grant(.visibility)
    }

    // MARK: - UIScrollViewDelegate

    override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        super.scrollViewDidEndDragging(scrollView, willDecelerate: decelerate)
        if !decelerate {
            locationObservation.request()
        }
    }

    override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        super.scrollViewDidEndDecelerating(scrollView)
        locationObservation.request()
    }

    override func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        super.scrollViewDidEndScrollingAnimation(scrollView)
        locationObservation.request()
    }
}
