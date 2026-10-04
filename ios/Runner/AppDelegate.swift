import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let backgroundAudio = BackgroundAudioManager()
  private let systemSettingsChannelName = "app.glaze.flutter/system_settings"
  private let powerSaveEventsChannelName = "app.glaze.flutter/power_save_events"
  private let powerSaveStreamHandler = PowerSaveStreamHandler()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let didFinishLaunching = super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )

    return didFinishLaunching
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return super.application(app, open: url, options: options)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    if let settingsRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "GlazeSystemSettings") {
      let settingsChannel = FlutterMethodChannel(
        name: systemSettingsChannelName,
        binaryMessenger: settingsRegistrar.messenger()
      )
      settingsChannel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "openNotificationSettings":
          self?.openNotificationSettings()
          result(nil)
        case "isPowerSaveMode":
          result(ProcessInfo.processInfo.isLowPowerModeEnabled)
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      FlutterEventChannel(
        name: powerSaveEventsChannelName,
        binaryMessenger: settingsRegistrar.messenger()
      ).setStreamHandler(powerSaveStreamHandler)
    }

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GlazeBackgroundAudio") else { return }
    let channel = FlutterMethodChannel(
      name: "com.hydall.glaze/background_audio",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "start":
        self?.backgroundAudio.start()
        result(nil)
      case "stop":
        self?.backgroundAudio.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func openNotificationSettings() {
    let urlString: String
    if #available(iOS 16.0, *) {
      urlString = UIApplication.openNotificationSettingsURLString
    } else {
      urlString = UIApplication.openSettingsURLString
    }

    guard let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) else {
      return
    }

    UIApplication.shared.open(url)
  }
}

/// Pushes Low Power Mode on every change. Polling cannot see the moment the
/// phone flips, which is the only thing "follow the system" is about;
/// `NSProcessInfoPowerStateDidChange` is the notification that can.
private class PowerSaveStreamHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(powerStateChanged),
      name: Notification.Name.NSProcessInfoPowerStateDidChange,
      object: nil
    )
    // Seed the stream so a listener that attached after a change still starts
    // from the truth rather than from its own default.
    events(ProcessInfo.processInfo.isLowPowerModeEnabled)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    NotificationCenter.default.removeObserver(self)
    sink = nil
    return nil
  }

  @objc private func powerStateChanged() {
    sink?(ProcessInfo.processInfo.isLowPowerModeEnabled)
  }
}
