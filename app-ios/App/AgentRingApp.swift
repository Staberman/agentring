import AgentRingCore
import PushKit
import SwiftUI
import UserNotifications

@main
struct AgentRingApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onChange(of: phase) { _, p in
                    if p == .active, model.creds != nil {
                        model.startSocket()
                        Task { await model.refreshStatus() }
                    }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, PKPushRegistryDelegate, UNUserNotificationCenterDelegate {
    private var voipRegistry: PKPushRegistry?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The CXProvider must exist before the first VoIP push is delivered.
        _ = CallManager.shared

        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        voipRegistry = registry

        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        if AppModel.shared.creds != nil {
            AppModel.shared.requestNotificationPermission()
            AppModel.shared.startSocket()
        }
        return true
    }

    // MARK: Regular APNs token (msg.new alerts)

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in AppModel.shared.setApnsToken(hex) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("agentring: APNs registration failed: \(error.localizedDescription)")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: PushKit (call.invite)

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in AppModel.shared.setVoipToken(hex) }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {}

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        // The delegate queue is main, so this runs synchronously and reports to CallKit
        // before returning. iOS terminates the app if a VoIP push does not report a call.
        MainActor.assumeIsolated {
            CallManager.shared.handleVoIPPush(payload: payload.dictionaryPayload, completion: completion)
        }
    }
}
