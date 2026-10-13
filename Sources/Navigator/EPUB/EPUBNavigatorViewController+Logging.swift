//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

/// Payload-bearing navigation enums project onto a separate closed vocabulary.
/// Exhaustive switches force new cases to make an explicit diagnostic decision.
extension EPUBNavigatorViewController.State {
    var logToken: EPUBPageWorldLog.NavigationState {
        switch self {
        case .initializing: return .initializing
        case .loading: return .loading
        case .idle: return .idle
        case .jumping: return .jumping
        case .moving: return .moving
        }
    }
}

extension EPUBNavigatorViewController.Event {
    var logToken: EPUBPageWorldLog.NavigationEvent {
        switch self {
        case .load: return .load
        case .loaded: return .loaded
        case .jump: return .jump
        case .jumped: return .jumped
        case .move: return .move
        case .moved: return .moved
        }
    }
}
