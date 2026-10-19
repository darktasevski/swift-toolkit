//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit

/// The scroll view's settlement callbacks, which a reflowable spread overrides
/// to measure where native scrolling came to rest.
extension EPUBSpreadView {
    @objc func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // Do not remove, overridden in subclasses.
    }

    @objc func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // Do not remove, overridden in subclasses.
    }
}
