import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';

/// Central gate for UI haptic feedback.
///
/// Call sites use [Haptics.selectionClick] / [lightImpact] / [mediumImpact] /
/// [heavyImpact] instead of [HapticFeedback] directly, so vibration can be
/// gated per-platform and by the user's iOS toggle.
///
/// Platform behaviour:
/// * **iOS** — the only platform with a user toggle. It has haptic hardware
///   but exposes no public API to read the system "System Haptics" setting, so
///   the user controls feedback explicitly via app settings ([configure]).
/// * **Android** — always fires; the OS honours its own haptic setting
///   natively through `performHapticFeedback`, so no app-level toggle is
///   needed.
/// * **Desktop / web** — no haptic hardware, so feedback is suppressed.
///
/// The toggle is cached statically so synchronous tap handlers anywhere in the
/// widget tree can fire feedback without threading a [Ref] through.
class Haptics {
  Haptics._();

  static bool _enabled = true;
  static bool _messageVibrationEnabled = true;

  /// Updates the cached iOS toggle. Called by the app settings notifier on
  /// load and whenever the toggle changes.
  static void configure({required bool enabled}) {
    _enabled = enabled;
  }

  /// Updates the cached incoming-message vibration toggle. Called by the app
  /// settings notifier on load and whenever the toggle changes.
  static void configureMessageVibration({required bool enabled}) {
    _messageVibrationEnabled = enabled;
  }

  /// Whether the haptic toggle is user-configurable on this platform (iOS only;
  /// see the class doc for why).
  static bool get isConfigurable =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Whether the incoming-message vibration is available on this platform.
  /// Offered on both mobile platforms (Android + iOS) since it is an explicit
  /// notification the user opts into, not an OS-level tap echo.
  static bool get isMessageVibrationConfigurable {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return true;
      default:
        return false; // Desktop: no vibration hardware.
    }
  }

  /// Whether feedback should fire on this platform given the iOS toggle.
  static bool get shouldVibrate {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return _enabled;
      case TargetPlatform.android:
        return true; // OS honours its own haptic setting natively.
      default:
        return false; // Desktop: no haptic hardware.
    }
  }

  static Future<void> selectionClick() async {
    if (!shouldVibrate) return;
    await HapticFeedback.selectionClick();
  }

  static Future<void> lightImpact() async {
    if (!shouldVibrate) return;
    await HapticFeedback.lightImpact();
  }

  static Future<void> mediumImpact() async {
    if (!shouldVibrate) return;
    await HapticFeedback.mediumImpact();
  }

  static Future<void> heavyImpact() async {
    if (!shouldVibrate) return;
    await HapticFeedback.heavyImpact();
  }

  /// Fires when a bot message finishes generating, gated by the user's
  /// incoming-message vibration toggle. Unlike UI feedback this fires on
  /// Android too, because it is an explicit app-level notification the user
  /// opted into rather than a tap echo the OS already governs.
  static Future<void> messageReceived() async {
    if (!_messageVibrationEnabled) return;
    if (!isMessageVibrationConfigurable) return;
    await HapticFeedback.mediumImpact();
  }
}
