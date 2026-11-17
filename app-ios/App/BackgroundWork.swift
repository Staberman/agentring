import UIKit

/// A UIKit background task that can be ended any number of times: the expiration handler and the
/// normal finish may both run, and only the first one ends the task.
@MainActor
final class BackgroundWork {
    private var id = UIBackgroundTaskIdentifier.invalid

    /// `onExpire` runs when iOS is about to suspend the app (cancel the work there); the task is ended right after it.
    init(name: String, onExpire: @escaping @MainActor () -> Void = {}) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                NSLog("agentring: background task \(name) expired")
                onExpire()
                self?.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
