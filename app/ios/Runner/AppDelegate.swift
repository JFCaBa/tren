import ActivityKit
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// APNs device token as lowercase hex, once iOS has given one. Never logged.
  private var deviceToken: String?
  /// Callers waiting for iOS to answer registerForRemoteNotifications.
  private var pendingToken: [FlutterResult] = []
  private var tokenTimeout: DispatchWorkItem?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    UNUserNotificationCenter.current().delegate = self
    return launched
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // After the plugins register, so no plugin can take over as the notification delegate.
    UNUserNotificationCenter.current().delegate = self
    let channel = FlutterMethodChannel(
      name: "anden/push", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    let activity = FlutterMethodChannel(
      name: "anden/activity", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    activityChannel = activity
    activity.setMethodCallHandler { [weak self] call, result in
      self?.handleActivity(call, result: result)
    }
  }

  private var activityChannel: FlutterMethodChannel?
  private var activityTokenTask: Task<Void, Never>?

  /// The followed train's Live Activity (iOS 16.1+): start / update / end. Its push tokens go
  /// back to Dart ("token") for the server; never logged.
  private func handleActivity(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard #available(iOS 16.1, *) else {
      result(false)
      return
    }
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "start":
      activityTokenTask?.cancel()
      activityTokenTask = nil
      guard ActivityAuthorizationInfo().areActivitiesEnabled,
        let title = args?["title"] as? String, let station = args?["station"] as? String,
        let state = Self.state(args?["state"])
      else {
        result(false)
        return
      }
      Task { @MainActor in
        await Self.endAll()
        do {
          let a = try Activity<TrainActivityAttributes>.request(
            attributes: TrainActivityAttributes(title: title, station: station),
            contentState: state, pushType: .token)
          self.watchTokens(a)
          result(true)
        } catch {
          result(false)
        }
      }
    case "update":
      guard let state = Self.state(args?["state"]) else {
        result(nil)
        return
      }
      Task { @MainActor in
        for a in Activity<TrainActivityAttributes>.activities { await a.update(using: state) }
        result(nil)
      }
    case "end":
      activityTokenTask?.cancel()
      activityTokenTask = nil
      Task { @MainActor in
        await Self.endAll()
        result(nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @available(iOS 16.1, *)
  private func watchTokens(_ a: Activity<TrainActivityAttributes>) {
    activityTokenTask?.cancel()
    activityTokenTask = Task { @MainActor [weak self] in
      for await data in a.pushTokenUpdates {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        self?.activityChannel?.invokeMethod("token", arguments: hex)
      }
    }
  }

  @available(iOS 16.1, *)
  private static func endAll() async {
    for a in Activity<TrainActivityAttributes>.activities {
      await a.end(dismissalPolicy: .immediate)
    }
  }

  /// The content state from Dart's map (same keys as the server's JSON).
  @available(iOS 16.1, *)
  private static func state(_ raw: Any?) -> TrainActivityAttributes.ContentState? {
    guard let m = raw as? [String: Any] else { return nil }
    return TrainActivityAttributes.ContentState(
      departs: (m["departs"] as? NSNumber)?.doubleValue,
      status: m["status"] as? String ?? "",
      platform: m["platform"] as? String,
      usual: m["usual"] as? Bool,
      where: m["where"] as? String,
      cancelled: m["cancelled"] as? Bool ?? false)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestPermission":
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
        DispatchQueue.main.async { result(granted) }
      }
    case "token":
      if let token = deviceToken {
        result(token)
        return
      }
      pendingToken.append(result)
      if pendingToken.count == 1 {
        let timeout = DispatchWorkItem { [weak self] in
          self?.finishToken(FlutterError(code: "timeout", message: "No push token", details: nil))
        }
        tokenTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        UIApplication.shared.registerForRemoteNotifications()
      }
    case "environment":
      result(AppDelegate.apsEnvironment())
    case "openSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func finishToken(_ value: Any?) {
    tokenTimeout?.cancel()
    tokenTimeout = nil
    let waiting = pendingToken
    pendingToken = []
    for r in waiting { r(value) }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    self.deviceToken = hex
    finishToken(hex)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    finishToken(FlutterError(code: "register_failed", message: error.localizedDescription, details: nil))
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  /// iOS hides pushes while the app is open: show the follow alerts anyway.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  /// The APNs environment the token belongs to, from the provisioning profile's aps-environment:
  /// App Store and TestFlight builds carry no profile and use "production". A profile we can't read
  /// falls back on the build type.
  private static func apsEnvironment() -> String {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
      return "production"
    }
    if let data = try? Data(contentsOf: url) {
      let text = String(decoding: data, as: UTF8.self)
      let pattern = "<key>aps-environment</key>\\s*<string>(development|production)</string>"
      if let range = text.range(of: pattern, options: .regularExpression) {
        return text[range].contains("development") ? "sandbox" : "production"
      }
    }
    #if DEBUG
      return "sandbox"
    #else
      return "production"
    #endif
  }
}
