import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SystemSettings {
  static const MethodChannel _channel = MethodChannel(
    'app.glaze.flutter/system_settings',
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
}
