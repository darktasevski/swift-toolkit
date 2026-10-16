//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit

public extension EPUBNavigatorDelegate {
    func navigatorWillBeginUserNavigation(_ navigator: EPUBNavigatorViewController) {}
}

extension EPUBSpreadViewDelegate {
    func spreadViewWillBeginUserNavigation(_ spreadView: EPUBSpreadView) {}
}

extension PaginationViewDelegate {
    func paginationViewWillBeginUserNavigation(_ paginationView: PaginationView) {}
}

extension PaginationView {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        delegate?.paginationViewWillBeginUserNavigation(self)
    }
}

extension EPUBNavigatorViewController {
    func spreadViewWillBeginUserNavigation(_ spreadView: EPUBSpreadView) {
        guard currentSelection == nil else { return }
        delegate?.navigatorWillBeginUserNavigation(self)
    }

    func paginationViewWillBeginUserNavigation(_ paginationView: PaginationView) {
        guard currentSelection == nil else { return }
        delegate?.navigatorWillBeginUserNavigation(self)
    }
}
