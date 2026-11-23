import SwiftUI

extension String {
    var localized: LocalizedStringKey { LocalizedStringKey(self) }
    var localizedString: String { NSLocalizedString(self, comment: "") }
}
