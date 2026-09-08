import 'package:flutter/services.dart';

class SystemSettings {
  static const MethodChannel _channel =
      MethodChannel('app.glaze.flutter/system_settings');

  static Future<void> openNotificationSettings() {
    return _channel.invokeMethod<void>('openNotificationSettings');
  }
}
