import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Which way the screen may turn on phones and tablets: every way, following
/// the system's own auto-rotate switch. A phone turned sideways keeps the
/// phone layout in its landscape form (side tab rail); a tablet turned
/// sideways gets the desktop layout. See `isDesktopViewportSize`.
abstract final class ScreenOrientation {
  /// Whether the screen turns here at all. Desktop windows have no
  /// orientation, so landscape-only settings are hidden there.
  static bool get isConfigurable =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Lets the screen turn every way. Called once before the app starts; an
  /// earlier build locked phones upright.
  static Future<void> allowAll() async {
    if (!isConfigurable) return;
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitDown,
    ]);
  }
}
