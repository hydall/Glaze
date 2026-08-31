import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

const _prefsKey = 'gz_window_geometry';
const Size _defaultSize = Size(1280, 820);
const Size _minimumSize = Size(720, 560);

bool get _isDesktopWindow =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// Restores the window's last size and position, and keeps them saved.
///
/// The Electron build opened at a fixed 1024x768 every time and the Flutter
/// port had no window management at all, so resizing was forgotten on every
/// launch. Safe to call on mobile: it no-ops there.
Future<void> initDesktopWindow() async {
  if (!_isDesktopWindow) return;
  await windowManager.ensureInitialized();

  final saved = await _readGeometry();
  final options = WindowOptions(
    size: saved?.size ?? _defaultSize,
    minimumSize: _minimumSize,
    center: saved == null,
    titleBarStyle: TitleBarStyle.normal,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    if (saved?.position != null) {
      await windowManager.setPosition(saved!.position!);
    }
    await windowManager.show();
    await windowManager.focus();
  });
  windowManager.addListener(_GeometryPersister());
}

class _Geometry {
  final Size size;
  final Offset? position;
  const _Geometry(this.size, this.position);
}

Future<_Geometry?> _readGeometry() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return null;
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final width = (map['w'] as num?)?.toDouble();
    final height = (map['h'] as num?)?.toDouble();
    if (width == null || height == null) return null;
    final x = (map['x'] as num?)?.toDouble();
    final y = (map['y'] as num?)?.toDouble();
    return _Geometry(
      Size(
        width.clamp(_minimumSize.width, double.infinity),
        height.clamp(_minimumSize.height, double.infinity),
      ),
      x == null || y == null ? null : Offset(x, y),
    );
  } catch (_) {
    // A corrupt entry must never block startup — fall back to the default.
    return null;
  }
}

/// Writes the geometry back after the user finishes moving or resizing.
class _GeometryPersister extends WindowListener {
  @override
  void onWindowResized() => _save();

  @override
  void onWindowMoved() => _save();

  Future<void> _save() async {
    try {
      if (await windowManager.isMaximized() ||
          await windowManager.isFullScreen()) {
        // Persisting a maximized frame would restore a window that cannot be
        // un-maximized back to a sensible size.
        return;
      }
      final size = await windowManager.getSize();
      final position = await windowManager.getPosition();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode({
          'w': size.width,
          'h': size.height,
          'x': position.dx,
          'y': position.dy,
        }),
      );
    } catch (_) {
      // Best effort: losing the geometry is not worth surfacing an error for.
    }
  }
}
