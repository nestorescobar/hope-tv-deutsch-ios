import UIKit

/// The app stays portrait; only the player rotates. `Info.plist` lists the landscape orientations,
/// and this mask narrows them at run time.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientations: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientations
    }
}

enum OrientationLock {
    /// Allows `mask` and turns the screen to it when the current orientation is not in it.
    @MainActor
    static func set(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientations = mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}
