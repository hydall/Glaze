import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/menu/update_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../navigation/router.dart' show rootNavigatorKey;
import 'onboarding_service.dart' show isOnboardingComplete;
import 'update_check_service.dart';

/// Identity of the update the user chose to stop being reminded about (the
/// "don't remind me about this update" toggle) — a run SHA on the pre-release
/// channels, a release tag on `stable`. While the latest update matches this,
/// the startup check stays silent. Cleared automatically once the user is on
/// the latest build, so future updates remind again.
const _dismissedShaKey = 'update_dismissed_sha';

/// Silent auto-check on startup. Shows the dialog only when something newer
/// exists on this build's channel and the user hasn't muted that exact update.
/// Any failure (offline, rate-limited, dev build) is swallowed — never blocks
/// or interrupts launch. Skipped while onboarding is still pending.
Future<void> checkAndShowUpdateOnStartup({
  UpdateCheckService? service,
  Set<String>? presentedUpdateIds,
}) async {
  if (!await isOnboardingComplete()) return;

  final result = await (service ?? UpdateCheckService()).check();
  final prefs = await SharedPreferences.getInstance();

  // Installed the update (or already current): reset the mute so the next
  // build prompts again.
  if (result.status == UpdateStatus.upToDate) {
    await prefs.remove(_dismissedShaKey);
    return;
  }
  if (result.status != UpdateStatus.available) return;
  final info = result.info;
  if (info == null) return;

  if (prefs.getString(_dismissedShaKey) == info.dismissId) return;
  if (presentedUpdateIds?.contains(info.dismissId) == true) return;

  // Show on the root navigator: the startup hook fires above MaterialApp,
  // so its own context has no Navigator/Overlay (same reason onboarding uses
  // rootNavigatorKey).
  final navContext = rootNavigatorKey.currentContext;
  if (navContext == null || !navContext.mounted) return;
  presentedUpdateIds?.add(info.dismissId);
  await _present(navContext, info);
}

/// Runs silent update checks while the app is in the foreground.
///
/// The same build is presented at most once per app lifetime. Persistent
/// suppression remains owned by [checkAndShowUpdateOnStartup].
class AutomaticUpdateCheckController {
  AutomaticUpdateCheckController({
    required this.check,
    this.interval = const Duration(hours: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Future<void> Function(Set<String> presentedUpdateIds) check;
  final Duration interval;
  final DateTime Function() _now;
  final Set<String> _presentedUpdateIds = {};

  Timer? _timer;
  DateTime? _lastAttemptAt;
  bool _inFlight = false;

  void start() {
    _startTimer();
    _schedule(force: true);
  }

  void pause() => _timer?.cancel();

  void resume() {
    _startTimer();
    _schedule();
  }

  Future<void> runNow({bool force = false}) async {
    if (_inFlight) return;
    final now = _now();
    final lastAttemptAt = _lastAttemptAt;
    if (!force &&
        lastAttemptAt != null &&
        now.difference(lastAttemptAt) < interval) {
      return;
    }

    _lastAttemptAt = now;
    _inFlight = true;
    try {
      await check(_presentedUpdateIds);
    } finally {
      _inFlight = false;
    }
  }

  void dispose() => _timer?.cancel();

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _schedule());
  }

  void _schedule({bool force = false}) {
    unawaited(
      runNow(force: force).catchError((Object _) {
        // Automatic checks are deliberately silent. Manual checks still report
        // failures through [runManualUpdateCheck].
      }),
    );
  }
}

/// Manual "Check for updates" entry point. Always reports the outcome:
/// shows the dialog when a newer build exists, otherwise a toast.
Future<void> runManualUpdateCheck(
  BuildContext context, {
  UpdateCheckService? service,
}) async {
  GlazeToast.show(context, 'update_checking'.tr());

  final result = await (service ?? UpdateCheckService()).check();
  if (!context.mounted) return;

  switch (result.status) {
    case UpdateStatus.available:
      final info = result.info;
      if (info != null) await _present(context, info);
    case UpdateStatus.upToDate:
      GlazeToast.show(context, 'update_up_to_date'.tr());
      await (await SharedPreferences.getInstance()).remove(_dismissedShaKey);
    case UpdateStatus.unknown:
      GlazeToast.show(context, 'update_check_failed'.tr(), isError: true);
  }
}

/// Shows the dialog and persists the "don't remind" mute when the user opts
/// into it. "Later" (or opening Actions) leaves the build un-muted so the
/// prompt reappears next launch until the update is installed or muted.
Future<void> _present(BuildContext context, UpdateInfo info) async {
  final result = await showUpdateDialog(context, info);
  if (result?.dontRemind == true) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dismissedShaKey, info.dismissId);
  }
}
