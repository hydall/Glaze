import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/widgets/glaze_toast.dart';

/// Severity for `glaze.showToast(message, { severity })`. Maps to
/// `GlazeToast` presentation:
///   * `info`   — default styling, normal duration.
///   * `success` — same visual as `info` for now (no separate style in
///     the design system); reserved for a future `color: success` flag.
///   * `warning` — yellow accent, longer duration.
///   * `error`   — red accent, longest duration + sticky.
enum GlazeToastSeverity {
  info,
  success,
  warning,
  error;

  static GlazeToastSeverity parse(String? raw) {
    if (raw == null) return GlazeToastSeverity.info;
    switch (raw.trim().toLowerCase()) {
      case 'success':
        return GlazeToastSeverity.success;
      case 'warning':
      case 'warn':
        return GlazeToastSeverity.warning;
      case 'error':
        return GlazeToastSeverity.error;
      case 'info':
      default:
        return GlazeToastSeverity.info;
    }
  }
}

/// Bridge-side controller that surfaces `glaze.showToast` to the user.
/// The MVP only logs to `debugPrint` so the bridge works in headless
/// contexts (where no `OverlayState` is available). When a `BuildContext`
/// is available, the controller upgrades to the real `GlazeToast` widget.
class JsBridgeToastController {
  JsBridgeToastController({this.overlayResolver});

  /// Optional callback that resolves a [BuildContext] for the
  /// currently visible screen. Production code in `ChatWebViewWidget`
  /// passes a function that returns `context` from the widget.
  ///
  /// Mutable so callers can re-target the resolver on rebuild (e.g. a
  /// widget may want the controller to surface toasts from the
  /// currently mounted chat, not the snapshot at bridge init).
  // ignore: prefer_final_fields
  BuildContext? Function()? overlayResolver;

  /// Show a toast. Safe to call from any context — when no overlay is
  /// available the message is logged to debug output (still useful in
  /// headless runs).
  void show(
    String? message, {
    GlazeToastSeverity severity = GlazeToastSeverity.info,
    Duration? duration,
    String? actionLabel,
  }) {
    final text = (message ?? '').trim();
    if (text.isEmpty) return;
    final ctx = overlayResolver?.call();
    if (ctx == null) {
      if (kDebugMode) {
        debugPrint(
          '[JsBridgeToast] ($severity) $text '
          '${actionLabel != null ? "action=$actionLabel" : ""}',
        );
      }
      return;
    }
    final effectiveDurationMs = duration?.inMilliseconds ??
        switch (severity) {
          GlazeToastSeverity.info => 2000,
          GlazeToastSeverity.success => 2000,
          GlazeToastSeverity.warning => 4000,
          GlazeToastSeverity.error => 6000,
        };
    GlazeToast.show(
      ctx,
      text,
      duration: effectiveDurationMs,
      isError: severity == GlazeToastSeverity.error,
    );
  }
}
