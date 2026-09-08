import 'package:flutter/services.dart';

/// Native access to the device wallpaper. Android-only; returns null on every
/// other platform and on any failure (missing permission, live wallpaper,
/// SecurityException) so callers can fall back to a plain surface.
class Wallpaper {
  static const MethodChannel _channel =
      MethodChannel('app.glaze.flutter/wallpaper');

  /// Fetches the current home-screen wallpaper as raw PNG bytes. Reads only when
  /// the storage/media permission is already granted — never prompts. Returns
  /// null when unavailable or not yet permitted.
  static Future<Uint8List?> getWallpaper() async {
    try {
      return await _channel.invokeMethod<Uint8List>('getWallpaper');
    } catch (_) {
      return null;
    }
  }

  /// Whether the storage/media permission needed to read the wallpaper is
  /// already granted. False on non-Android platforms.
  static Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Shows the system permission prompt (if not already granted) and resolves
  /// to whether the wallpaper permission ended up granted.
  static Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } catch (_) {
      return false;
    }
  }
}
