//
//  PaginationView+PageTurnAnimation.swift
//  Reader App - Readium Fork Extension
//
//  Extends PaginationView with custom page turn animation support.
//

import UIKit

// MARK: - Animation Shadow View

/// Custom view class for animation shadows.
/// Using a dedicated subclass allows type-based filtering for cleanup,
/// avoiding potential conflicts with hardcoded view tags.
private final class AnimationShadowView: UIView {
    static let offsetMagnitude: CGFloat = 10
    static let opacity: Float = 0.3
    static let radius: CGFloat = 15
}

// MARK: - PaginationView Animation Extension

/// Page turn animation methods for PaginationView.
/// All methods are @MainActor isolated as they manipulate UIKit views.
@MainActor
extension PaginationView {

    /// Navigates to the target index with the specified animation.
    ///
    /// This is the main entry point for animated page transitions.
    /// Called from `goToIndex` when animation is enabled.
    ///
    /// - Parameters:
    ///   - targetIndex: The page index to navigate to.
    ///   - location: The location within the target page.
    ///   - options: Navigation options including animation settings.
    func animateToView(
        at targetIndex: Int,
        location: PageLocation,
        options: NavigatorGoOptions
    ) async {
        let animation = options.paginationAnimationType
        let duration = options.pageTurnDuration

        // Disable scroll for non-slide animations to prevent interference
        // Slide uses the scroll view directly, so we don't disable for it
        let shouldDisableScroll = animation != .none && animation != .slide
        if shouldDisableScroll {
            scrollView.isScrollEnabled = false
        }

        switch animation {
        case .none:
            await scrollToView(at: targetIndex, location: location)

        case .slide:
            await slideToView(at: targetIndex, location: location, duration: duration)

        case .fade:
            await fadeToViewAnimated(at: targetIndex, location: location, duration: duration)

        case .cover:
            await coverToView(at: targetIndex, location: location, duration: duration)

        case .reveal:
            await revealToView(at: targetIndex, location: location, duration: duration)
        }
    }

    // MARK: - Slide Animation

    /// Animates to target using UIScrollView's native scroll animation.
    private func slideToView(
        at targetIndex: Int,
        location: PageLocation,
        duration: TimeInterval
    ) async {
        let targetOffset = xOffsetForIndex(targetIndex)

        await withCheckedContinuation { continuation in
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.curveEaseOut, .allowUserInteraction]
            ) {
                self.scrollView.contentOffset.x = targetOffset
            } completion: { _ in
                continuation.resume()
            }
        }

        await finalizeNavigation(to: targetIndex, location: location)
    }

    // MARK: - Fade Animation

    /// Animates to target using alpha crossfade.
    private func fadeToViewAnimated(
        at targetIndex: Int,
        location: PageLocation,
        duration: TimeInterval
    ) async {
        let halfDuration = duration / 2

        // Fade out
        await withCheckedContinuation { continuation in
            UIView.animate(withDuration: halfDuration, delay: 0, options: .curveEaseIn) {
                self.alpha = 0
            } completion: { _ in
                continuation.resume()
            }
        }

        // Switch content (instant)
        scrollView.contentOffset.x = xOffsetForIndex(targetIndex)
        setCurrentIndex(targetIndex, location: location)

        // Fade in
        await withCheckedContinuation { continuation in
            UIView.animate(withDuration: halfDuration, delay: 0, options: .curveEaseOut) {
                self.alpha = 1
            } completion: { _ in
                continuation.resume()
            }
        }
    }

    // MARK: - Cover Animation

    /// Animates target page sliding over current page.
    private func coverToView(
        at targetIndex: Int,
        location: PageLocation,
        duration: TimeInterval
    ) async {
        guard let targetView = loadedViews[targetIndex] else {
            // Fallback if target view not loaded
            await fadeToViewAnimated(at: targetIndex, location: location, duration: duration)
            return
        }

        let direction = targetIndex > currentIndex ? 1 : -1
        let offset = bounds.width * CGFloat(direction)

        // Position target offscreen
        targetView.transform = CGAffineTransform(translationX: offset, y: 0)

        // Bring target to front (over current)
        scrollView.bringSubviewToFront(targetView)

        // Add shadow to leading edge
        let shadowView = createShadowView(for: targetView, direction: direction)
        targetView.addSubview(shadowView)

        // Animate target sliding in
        await withCheckedContinuation { continuation in
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.curveEaseOut, .allowUserInteraction]
            ) {
                targetView.transform = .identity
            } completion: { _ in
                shadowView.removeFromSuperview()
                continuation.resume()
            }
        }

        await finalizeNavigation(to: targetIndex, location: location)
    }

    // MARK: - Reveal Animation

    /// Animates current page sliding away to reveal target.
    private func revealToView(
        at targetIndex: Int,
        location: PageLocation,
        duration: TimeInterval
    ) async {
        guard let currentView = loadedViews[currentIndex] else {
            // Fallback if current view not available
            await fadeToViewAnimated(at: targetIndex, location: location, duration: duration)
            return
        }

        let direction = targetIndex > currentIndex ? 1 : -1
        let offset = bounds.width * CGFloat(-direction)

        // Ensure current view is on top
        scrollView.bringSubviewToFront(currentView)

        // Add shadow to trailing edge
        let shadowView = createShadowView(for: currentView, direction: -direction)
        currentView.addSubview(shadowView)

        // Animate current sliding away
        await withCheckedContinuation { continuation in
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.curveEaseOut, .allowUserInteraction]
            ) {
                currentView.transform = CGAffineTransform(translationX: offset, y: 0)
            } completion: { _ in
                // Reset transform
                currentView.transform = .identity
                shadowView.removeFromSuperview()
                continuation.resume()
            }
        }

        await finalizeNavigation(to: targetIndex, location: location)
    }

    // MARK: - Helpers

    /// Finalizes navigation after animation completes.
    private func finalizeNavigation(to targetIndex: Int, location: PageLocation) async {
        // Ensure scroll position is correct
        scrollView.contentOffset.x = xOffsetForIndex(targetIndex)

        // Update internal state
        setCurrentIndex(targetIndex, location: location)

        // Re-enable scroll view after animation completes
        scrollView.isScrollEnabled = isScrollEnabled

        // Announce page change for VoiceOver users
        UIAccessibility.post(notification: .pageScrolled, argument: nil)
    }

    /// Creates a shadow view for animation effects.
    ///
    /// Uses a custom `AnimationShadowView` subclass for type-based cleanup,
    /// avoiding potential conflicts with hardcoded view tags.
    private func createShadowView(for view: UIView, direction: Int) -> UIView {
        // Remove any existing orphaned shadow views first (cleanup safety)
        view.subviews
            .compactMap { $0 as? AnimationShadowView }
            .forEach { $0.removeFromSuperview() }

        let shadowView = AnimationShadowView(frame: view.bounds)
        shadowView.backgroundColor = .clear
        shadowView.layer.shadowColor = UIColor.black.cgColor
        shadowView.layer.shadowOffset = CGSize(
            width: CGFloat(direction) * AnimationShadowView.offsetMagnitude,
            height: 0
        )
        shadowView.layer.shadowOpacity = AnimationShadowView.opacity
        shadowView.layer.shadowRadius = AnimationShadowView.radius
        shadowView.layer.shadowPath = UIBezierPath(rect: view.bounds).cgPath
        shadowView.isUserInteractionEnabled = false

        // Prevent VoiceOver from reading shadow
        shadowView.isAccessibilityElement = false
        shadowView.accessibilityElementsHidden = true

        return shadowView
    }
}

// MARK: - Interactive Animation Support

/// Interactive gesture-driven animation methods for PaginationView.
/// All methods are @MainActor isolated as they manipulate UIKit views.
/// Public for Features module gesture handling access.
@MainActor
public extension PaginationView {

    /// Prepares views for interactive animation.
    ///
    /// Call this when a pan gesture begins to set up the animation state.
    /// Disables scroll view to prevent interference with custom animation.
    ///
    /// - Parameters:
    ///   - direction: Navigation direction (1 for forward, -1 for backward)
    ///   - animationType: The animation type to use
    /// - Returns: The target index if valid, nil otherwise
    func prepareInteractiveAnimation(
        direction: Int,
        animationType: PaginationAnimationType
    ) -> Int? {
        let targetIndex = currentIndex + direction

        guard targetIndex >= 0, targetIndex < pageCount else {
            return nil
        }

        guard let targetView = loadedViews[targetIndex] else {
            return nil
        }

        // Disable scroll view to prevent interference with our custom animation
        scrollView.isScrollEnabled = false

        switch animationType {
        case .cover:
            // Position target offscreen
            let offset = bounds.width * CGFloat(direction)
            targetView.transform = CGAffineTransform(translationX: offset, y: 0)
            scrollView.bringSubviewToFront(targetView)

        case .reveal:
            // Ensure current is on top
            if let currentView = loadedViews[currentIndex] {
                scrollView.bringSubviewToFront(currentView)
            }

        default:
            break
        }

        return targetIndex
    }

    /// Updates the interactive animation progress.
    ///
    /// - Parameters:
    ///   - progress: Value from 0 (start) to 1 (complete)
    ///   - targetIndex: The target page index
    ///   - direction: Navigation direction
    ///   - animationType: The animation type
    func updateInteractiveProgress(
        _ progress: CGFloat,
        targetIndex: Int,
        direction: Int,
        animationType: PaginationAnimationType
    ) {
        let clampedProgress = max(0, min(1, progress))

        switch animationType {
        case .cover:
            guard let targetView = loadedViews[targetIndex] else { return }
            let offset = bounds.width * CGFloat(direction) * (1 - clampedProgress)
            targetView.transform = CGAffineTransform(translationX: offset, y: 0)

        case .reveal:
            guard let currentView = loadedViews[currentIndex] else { return }
            let offset = bounds.width * CGFloat(-direction) * clampedProgress
            currentView.transform = CGAffineTransform(translationX: offset, y: 0)

        default:
            break
        }
    }

    /// Completes the interactive animation.
    ///
    /// - Parameters:
    ///   - targetIndex: The target page index
    ///   - animationType: The animation type
    ///   - duration: Remaining animation duration
    ///   - location: The location within the target page (preserves user's position)
    func completeInteractiveAnimation(
        targetIndex: Int,
        animationType: PaginationAnimationType,
        duration: TimeInterval,
        location: PageLocation = .start
    ) async {
        switch animationType {
        case .cover:
            guard let targetView = loadedViews[targetIndex] else {
                scrollView.isScrollEnabled = isScrollEnabled
                return
            }
            await withCheckedContinuation { continuation in
                UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut) {
                    targetView.transform = .identity
                } completion: { _ in
                    continuation.resume()
                }
            }

        case .reveal:
            guard let currentView = loadedViews[currentIndex] else {
                scrollView.isScrollEnabled = isScrollEnabled
                return
            }
            let direction = targetIndex > currentIndex ? 1 : -1
            let offset = bounds.width * CGFloat(-direction)
            await withCheckedContinuation { continuation in
                UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut) {
                    currentView.transform = CGAffineTransform(translationX: offset, y: 0)
                } completion: { _ in
                    currentView.transform = .identity
                    continuation.resume()
                }
            }

        default:
            scrollView.isScrollEnabled = isScrollEnabled
            break
        }

        await finalizeNavigation(to: targetIndex, location: location)
    }

    /// Reverts the interactive animation to start position.
    ///
    /// - Parameters:
    ///   - targetIndex: The target page index (will not navigate here)
    ///   - animationType: The animation type
    ///   - duration: Revert animation duration
    func revertInteractiveAnimation(
        targetIndex: Int,
        animationType: PaginationAnimationType,
        duration: TimeInterval
    ) async {
        switch animationType {
        case .cover:
            guard let targetView = loadedViews[targetIndex] else {
                scrollView.isScrollEnabled = isScrollEnabled
                return
            }
            let direction = targetIndex > currentIndex ? 1 : -1
            let offset = bounds.width * CGFloat(direction)
            await withCheckedContinuation { continuation in
                UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut) {
                    targetView.transform = CGAffineTransform(translationX: offset, y: 0)
                } completion: { _ in
                    targetView.transform = .identity
                    continuation.resume()
                }
            }

        case .reveal:
            guard let currentView = loadedViews[currentIndex] else {
                scrollView.isScrollEnabled = isScrollEnabled
                return
            }
            await withCheckedContinuation { continuation in
                UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut) {
                    currentView.transform = .identity
                } completion: { _ in
                    continuation.resume()
                }
            }

        default:
            break
        }

        // Re-enable scroll view after revert completes
        scrollView.isScrollEnabled = isScrollEnabled
    }
}
