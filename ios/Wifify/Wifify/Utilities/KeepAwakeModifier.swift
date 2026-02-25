import SwiftUI

/// Prevents the screen from dimming/locking while active.
struct KeepAwakeModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive, initial: true) { _, active in
                UIApplication.shared.isIdleTimerDisabled = active
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
    }
}

extension View {
    func keepAwake(_ active: Bool) -> some View {
        modifier(KeepAwakeModifier(isActive: active))
    }
}
