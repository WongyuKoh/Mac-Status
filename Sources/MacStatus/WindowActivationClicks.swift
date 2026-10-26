import SwiftUI

extension View {
    /// Lets the click that activates a window also reach its SwiftUI controls.
    @ViewBuilder
    func acceptsWindowActivationClicks() -> some View {
        if #available(macOS 15.0, *) {
            allowsWindowActivationEvents(true)
        } else {
            self
        }
    }
}
