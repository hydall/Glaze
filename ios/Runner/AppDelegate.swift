import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let backgroundAudio = BackgroundAudioManager()
  private let systemSettingsChannelName = "app.glaze.flutter/system_settings"

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
        default:
          result(FlutterMethodNotImplemented)
        }
      }
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
