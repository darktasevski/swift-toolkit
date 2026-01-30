//
//  NavigatorGoOptions+Animation.swift
//  Reader App - Readium Fork Extension
//
//  Extends NavigatorGoOptions to support page turn animations without
//  modifying the upstream struct definition. Maps Domain's PageTurnAnimation
//  via raw value strings to avoid creating duplicate enums.
//

import Foundation

// MARK: - Animation Option Keys

private enum AnimationOptionKeys {
    static let animationType = "readerApp.pageTurnAnimation"
    static let animationDuration = "readerApp.pageTurnDuration"
}

// MARK: - Internal Animation Type

/// Animation type for Readium fork page turn animations.
///
/// This enum mirrors Domain's `PageTurnAnimation` using raw string values
/// to avoid a direct package dependency. The Readium fork must remain
/// isolated from app packages to enable upstream merging.
///
/// **Synchronization:** Raw values must match Domain's `PageTurnAnimation.rawValue`.
/// When adding new animation types to Domain, update this enum accordingly.
///
/// Public to allow Features module to access for interactive gesture handling.
public enum PaginationAnimationType: String, Equatable, Sendable {
    case none
    case slide
    case fade
    case cover
    case reveal

    /// Initialize from Domain's PageTurnAnimation raw value.
    ///
    /// - Parameter rawValue: The raw string value from `PageTurnAnimation.rawValue`
    /// - Note: Defaults to `.fade` if nil or unknown for backwards compatibility
    ///         with Readium's original fade behavior.
    public init(fromDomainRawValue rawValue: String?) {
        guard let rawValue else {
            self = .fade
            return
        }
        self = PaginationAnimationType(rawValue: rawValue) ?? .fade
    }
}

// MARK: - Duration Constants

private enum AnimationDuration {
    static let `default`: TimeInterval = 0.3
    static let minimum: TimeInterval = 0.1
    static let maximum: TimeInterval = 0.5
}

// MARK: - NavigatorGoOptions Animation Extension

public extension NavigatorGoOptions {

    /// Raw value of the page turn animation (Domain's PageTurnAnimation.rawValue).
    ///
    /// This property is stored in `otherOptions` to avoid modifying the
    /// upstream `NavigatorGoOptions` struct definition.
    var pageTurnAnimationRawValue: String? {
        get { otherOptions[AnimationOptionKeys.animationType] as? String }
        set { otherOptions[AnimationOptionKeys.animationType] = newValue }
    }

    /// Animation duration in seconds.
    ///
    /// This property is stored in `otherOptions` to avoid modifying the
    /// upstream `NavigatorGoOptions` struct definition. Values are clamped
    /// to the valid range (0.1-0.5 seconds).
    var pageTurnDuration: TimeInterval {
        get {
            otherOptions[AnimationOptionKeys.animationDuration] as? TimeInterval
                ?? AnimationDuration.default
        }
        set {
            let clamped = min(max(newValue, AnimationDuration.minimum), AnimationDuration.maximum)
            otherOptions[AnimationOptionKeys.animationDuration] = clamped
        }
    }

    /// Internal animation type for PaginationView.
    internal var paginationAnimationType: PaginationAnimationType {
        PaginationAnimationType(fromDomainRawValue: pageTurnAnimationRawValue)
    }
}
