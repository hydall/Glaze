import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/glaze_toast.dart';
import '../state/continue_failure_provider.dart';

/// A failed continuation leaves the message it was extending untouched — no
/// error swipe, no appended error bubble (INV-CM4) — so the toast is the only
/// thing that tells the user the run did not land. It carries the reason, or
/// a report of it says nothing more than "it failed".
class ContinueFailureListener extends ConsumerWidget {
  final Widget child;

  const ContinueFailureListener({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(continueFailureProvider, (previous, next) {
      if (next == null) return;
      final reason = continueFailureReason(next.error);
      GlazeToast.showWithoutContext(
        reason.isEmpty
            ? 'error_continue_failed'.tr()
            : '${'error_continue_failed'.tr()}: $reason',
        duration: reason.isEmpty ? 4000 : 8000,
        position: ToastPosition.top,
        isError: true,
        showCopyButton: reason.isNotEmpty,
      );
    });
    return child;
  }
}

/// Longest reason the toast shows. A provider can answer with a page of JSON,
/// and the toast's text has no line cap of its own.
const int _maxReasonLength = 300;

/// [error] on one line and cut to [_maxReasonLength], for the toast.
@visibleForTesting
String continueFailureReason(String error) {
  final flat = error.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= _maxReasonLength) return flat;
  return '${flat.substring(0, _maxReasonLength).trimRight()}…';
}
