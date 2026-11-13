import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../diagnostics/app_log.dart';

const _prefsKey = 'gz_window_geometry';
const Size _defaultSize = Size(1280, 820);
const Size _minimumSize = Size(720, 560);

/// `flutter test` runs on the host OS but has no OS window to drive.
bool get _underFlutterTest =>
    !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

/// Whether the app runs in a desktop OS window that window_manager drives.
bool get isDesktopAppWindow =>
    !kIsWeb &&
    !_underFlutterTest &&
    (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// Whether the app draws its own title bar instead of the system one, so the
/// main window matches the windows floating inside it. Windows only: macOS
/// keeps its traffic lights and Linux its window manager's decorations.
bool get usesCustomAppTitleBar => isDesktopAppWindow && Platform.isWindows;

/// Restores the window's last size and position, and keeps them saved.
///
/// The Electron build opened at a fixed 1024x768 every time and the Flutter
/// port had no window management at all, so resizing was forgotten on every
/// launch. Safe to call on mobile: it no-ops there.
Future<void> initDesktopWindow() async {
  if (!isDesktopAppWindow) return;
  await windowManager.ensureInitialized();

  final saved = await _readGeometry();
  final options = WindowOptions(
    size: saved?.size ?? _defaultSize,
    minimumSize: _minimumSize,
    center: saved == null,
    titleBarStyle: usesCustomAppTitleBar
        ? TitleBarStyle.hidden
        : TitleBarStyle.normal,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    if (saved?.position != null) {
      await windowManager.setPosition(saved!.position!);
    }
    await windowManager.show();
    await windowManager.focus();
  });
  windowManager.addListener(_GeometryPersister());
  // The close button no longer destroys the window on its own: the request
  // comes to [DesktopCloseHandler], which marks the run as closed first.
  await windowManager.setPreventClose(true);
  windowManager.addListener(
    DesktopCloseHandler(
      markClosed: AppLog.markClosed,
      unmarkClosed: AppLog.unmarkClosed,
      closeWindow: _letClose,
    ),
  );
}

/// Closes the main window the same way the close button does, so the run is
/// recorded as ended on purpose. Used when the app hands over to its
/// installer.
Future<void> closeDesktopApp() async {
  if (!isDesktopAppWindow) return;
  await windowManager.close();
}

/// Lets the close go through the way it did before it was intercepted: the
/// intercept is lifted and the close requested again, so the system destroys
/// the window at once and the process winds down behind it.
///
/// Not `windowManager.destroy()`: on Windows that only posts the quit message,
/// and the window then stays on screen through the whole engine teardown —
/// several seconds with a large chat open — looking hung.
Future<void> _letClose() async {
  try {
    await windowManager.setPreventClose(false);
    await windowManager.close();
  } catch (e) {
    // The intercept would not lift: the window still has to go, even the
    // slow way.
    debugPrint('[desktop] close could not be released ($e); destroying');
    await windowManager.destroy();
  }
}

/// Closes the window on the user's request, after the run is recorded as
/// ended on purpose.
///
/// Closing the window — the system's X on Windows and Linux, the title bar's
/// own button, Alt+F4 — destroyed the window straight away, and the process
/// went with it before anything in Dart heard of it: neither
/// `AppLifecycleListener.onExitRequested` nor the `detached` state fires on
/// that path. The session marker was left saying `foreground`, which is what
/// a crash looks like, so every launch after a normal close offered a crash
/// report. With the close intercepted, the marker and the log are written
/// first, then the close is let through as before.
class DesktopCloseHandler extends WindowListener {
  final void Function() markClosed;

  /// Undoes [markClosed] when the window did not go after all.
  final void Function() unmarkClosed;
  final Future<void> Function() closeWindow;

  DesktopCloseHandler({
    required this.markClosed,
    required this.closeWindow,
    void Function()? unmarkClosed,
  }) : unmarkClosed = unmarkClosed ?? _noop;

  static void _noop() {}

  bool _closing = false;

  @override
  void onWindowClose() {
    // The close let through below comes back here as a second request, as
    // does a double click on the X: neither marks or closes again.
    if (_closing) return;
    _closing = true;
    try {
      markClosed();
    } finally {
      // Whatever the marker did, the user asked to leave: the window goes.
      // If it will not, the next click gets to try again rather than find
      // the button dead.
      unawaited(
        closeWindow().catchError((Object e, StackTrace s) {
          _closing = false;
          unmarkClosed();
          debugPrint('[desktop] close failed: $e');
        }),
      );
    }
  }
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
