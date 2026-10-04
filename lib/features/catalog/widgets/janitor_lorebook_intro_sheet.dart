import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/widgets/glaze_bottom_sheet.dart';

/// Persisted flag so the closed-lorebook explainer is shown at most once ever.
const _kLorebookIntroShownKey = 'janitor_lorebook_intro_shown';

/// Explains the closed-lorebook capture the first time its sheet is opened:
/// how entries are recovered, and that the recovery is never guaranteed to be
/// complete — only entries whose keys fire in the trigger message come back.
///
/// Marks it seen up front so a dismissed sheet never reappears. A no-op on
/// every later open.
Future<void> maybeShowJanitorLorebookIntro(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_kLorebookIntroShownKey) ?? false) return;
  await prefs.setBool(_kLorebookIntroShownKey, true);
  if (!context.mounted) return;

  await GlazeBottomSheet.show<void>(
    context,
    title: 'catalog_lorebooks_intro_title'.tr(),
    bigInfo: BottomSheetBigInfo(
      icon: Icons.menu_book_outlined,
      description: 'catalog_lorebooks_intro_body'.tr(),
      buttonText: 'catalog_lorebooks_intro_ok'.tr(),
      onButtonTap: () => Navigator.of(context).pop(),
    ),
  );
}
