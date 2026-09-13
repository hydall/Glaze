import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SystemSettings {
  static const MethodChannel _channel = MethodChannel(
    'app.glaze.flutter/system_settings',
  );

  /// Pushes one bool per change of the OS power-save mode. Separate from the
  /// method channel because a poll cannot see the moment the phone flips —
  /// which is the whole point of following it.
  static const EventChannel _powerSaveEvents = EventChannel(
    'app.glaze.flutter/power_save_events',
  );

  /// Whether this platform has a per-app notification screen to open. Only the
  /// Android and iOS hosts implement the channel, so on desktop the row that
  /// calls [openNotificationSettings] would be a tap with no effect — callers
  /// hide it instead.
  static bool get canOpenNotificationSettings =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Opens the OS notification settings for Glaze. Swallows a missing host
  /// implementation: a settings row must never throw into the void.
  static Future<void> openNotificationSettings() async {
    if (!canOpenNotificationSettings) return;
    try {
      await _channel.invokeMethod<void>('openNotificationSettings');
    } on PlatformException catch (_) {
      // Nothing to open — the OS refused or the screen does not exist.
    } on MissingPluginException catch (_) {
      // Host side not wired on this platform.
    }
  }

  /// Whether this platform can say if the OS is in power-save mode. Android
  /// (`PowerManager.isPowerSaveMode`) and iOS (`ProcessInfo.isLowPowerMode
  /// Enabled`) can; the desktops have no equivalent to follow.
  static bool get canReadPowerSaveMode =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Whether the OS is saving power right now. `false` wherever the platform
  /// cannot answer — "follow the system" has nothing to follow there, and a
  /// setting that silently reduced the UI on a desktop would be worse than one
  /// that does nothing.
  static Future<bool> isPowerSaveMode() async {
    if (!canReadPowerSaveMode) return false;
    try {
      return await _channel.invokeMethod<bool>('isPowerSaveMode') ?? false;
    } on PlatformException catch (_) {
      return false;
    } on MissingPluginException catch (_) {
      return false;
    }
  }

  /// The OS power-save mode as it changes. Empty where the platform cannot
  /// report it, so a listener needs no platform check of its own.
  static Stream<bool> powerSaveModeChanges() {
    if (!canReadPowerSaveMode) return const Stream<bool>.empty();
    return _powerSaveEvents
        .receiveBroadcastStream()
        .map((event) => event == true)
        .handleError((Object _) {});
  }
}
