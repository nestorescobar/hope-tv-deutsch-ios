import SwiftUI

/// The return to the foreground (awe#5398). A port of `apps/mobile`'s `useAppForeground`.
///
/// `.inactive` → `.active` is not a return: a system overlay or the app switcher reports
/// `.inactive` only. So the trigger arms on a real `.background` and fires once on the next
/// `.active`, which also covers `.background` → `.inactive` → `.active`. Pure, so it is testable.
struct ForegroundTrigger {
    private var backgrounded = false

    mutating func fires(on phase: ScenePhase) -> Bool {
        switch phase {
        case .background:
            backgrounded = true
            return false
        case .active where backgrounded:
            backgrounded = false
            return true
        default:
            return false
        }
    }
}
