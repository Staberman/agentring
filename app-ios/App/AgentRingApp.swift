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
                    model.appActive = (p == .active)
                    if p == .active, model.creds != nil {
                        model.startSocket()
                        Task {
                            await model.refreshStatus()
                            await model.refreshMessages()
                        }
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
        AppModel.registerNotificationCategories()
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

    /// Inline reply from a `msg.new` alert. The action does not open the app, so a background task keeps
    /// the process alive until the relay has the message; the completion handler is called after it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == NotificationReply.replyActionId,
              let input = response as? UNTextInputNotificationResponse else {
            completionHandler()
            return
        }
        let userInfo = response.notification.request.content.userInfo
        let text = input.userText
        Task { @MainActor in
            ReplyJob(completionHandler: completionHandler).run(userInfo: userInfo, text: text)
        }
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

/// One notification reply: the background task and the completion handler are released exactly once,
/// whether the reply finishes or iOS expires the task first (the send is cancelled then).
@MainActor
private final class ReplyJob {
    private let completionHandler: () -> Void
    private var work: BackgroundWork?
    private var task: Task<Void, Never>?
    private var finished = false

    init(completionHandler: @escaping () -> Void) { self.completionHandler = completionHandler }

    func run(userInfo: [AnyHashable: Any], text: String) {
        work = BackgroundWork(name: "agentring.reply") { [self] in
            task?.cancel()
            finish()
        }
        task = Task {
            await AppModel.shared.reply(toNotification: userInfo, text: text)
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        work?.end()
        completionHandler()
    }
}
