import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/glaze_toast.dart';
import '../state/continue_failure_provider.dart';

/// A failed continuation leaves the message it was extending untouched — no
/// error swipe, no appended error bubble (INV-CM4) — so the toast is the only
/// thing that tells the user the run did not land.
class ContinueFailureListener extends ConsumerWidget {
  final Widget child;

  const ContinueFailureListener({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(continueFailureProvider, (previous, next) {
      if (next == null) return;
      GlazeToast.showWithoutContext(
        'error_continue_failed'.tr(),
        duration: 4000,
        position: ToastPosition.top,
        isError: true,
      );
    });
    return child;
  }
}
