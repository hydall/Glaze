import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/state/character_provider.dart' show kRevealHiddenTapCount;
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';

/// SharedPreferences flag: has the one-time "characters are now hidden"
/// explainer already been shown? Kept out of [character_provider.dart] so the
/// explainer's lifecycle stays self-contained in this feature widget.
const _kHidingOnboardingShownKey = 'char_hiding_onboarding_shown';

/// Seconds the explainer stays non-dismissible so the user actually reads it.
const int _kMandatorySeconds = 4;

/// Shows the one-time "characters and their chats are now hidden" explainer the
/// **first** time the user hides a character, then records that it has been
/// shown so it never appears again.
///
/// Call this right after a hide action succeeds (never on unhide). It is a
/// no-op on every subsequent hide. Safe to call from any hide entry point
/// (card menu, detail screen, bulk selection) — the shared-prefs guard makes it
/// idempotent across all of them.
Future<void> maybeShowCharacterHidingOnboarding(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_kHidingOnboardingShownKey) ?? false) return;
  // Mark as shown up front so a rapid second hide can't race a second sheet.
  await prefs.setBool(_kHidingOnboardingShownKey, true);
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    // Non-dismissible: no tap-outside, no swipe-down, no back button until the
    // countdown elapses (see [PopScope] inside the sheet).
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (_) => const _CharacterHidingOnboardingSheet(),
  );
}

class _CharacterHidingOnboardingSheet extends StatefulWidget {
  const _CharacterHidingOnboardingSheet();

  @override
  State<_CharacterHidingOnboardingSheet> createState() =>
      _CharacterHidingOnboardingSheetState();
}

class _CharacterHidingOnboardingSheetState
    extends State<_CharacterHidingOnboardingSheet> {
  int _remaining = _kMandatorySeconds;
  Timer? _timer;

  bool get _canClose => _remaining <= 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        _remaining--;
        if (_remaining <= 0) t.cancel();
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return PopScope(
      canPop: _canClose,
      child: GlazeBottomSheetFrame(
        showHandle: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.visibility_off_outlined,
                  color: cs.primary,
                  size: 30,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'char_hiding_onboarding_title'.tr(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'char_hiding_onboarding_body'.tr(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.45,
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: cs.primary.withValues(alpha: 0.20),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.touch_app_outlined,
                      size: 20,
                      color: cs.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'char_hiding_onboarding_reveal'.tr(
                          namedArgs: {'count': '$kRevealHiddenTapCount'},
                        ),
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.4,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              FilledButton(
                onPressed:
                    _canClose ? () => Navigator.of(context).pop() : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  _canClose
                      ? 'char_hiding_onboarding_dismiss'.tr()
                      : 'char_hiding_onboarding_dismiss_countdown'.tr(
                          namedArgs: {'seconds': '$_remaining'},
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
