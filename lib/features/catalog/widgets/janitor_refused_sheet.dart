import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../services/janitor_webview_proxy.dart';
import 'janitor_login_sheet.dart';

/// Explains a [JanitorRefusedException] instead of surfacing it as an error.
///
/// A refused `/generateAlpha` is not a bug the user can retry away: the common
/// case is a creator who restricted the character to JanitorAI's own model, so
/// the closed card and its closed lorebooks can never be captured for it. The
/// sheet quotes JanitorAI's own wording (`Proxies are forbidden for this
/// character`) so the reason is unambiguous, and offers the one thing that
/// still works — importing the public part of the card.
///
/// Returns true when the user chose to import anyway.
Future<bool> showJanitorRefusedSheet(
  BuildContext context,
  JanitorRefusedException refusal, {
  bool offerImportAnyway = true,
}) async {
  var importAnyway = false;
  await GlazeBottomSheet.show<void>(
    context,
    title: 'catalog_janitor_refused_title'.tr(),
    bigInfo: BottomSheetBigInfo(
      icon: Icons.lock_outline,
      // JanitorAI's own sentence first, then what it means for the import.
      description: '${refusal.message}.\n\n${'catalog_janitor_refused_body'.tr()}',
      buttonText: offerImportAnyway
          ? 'catalog_janitor_refused_import_anyway'.tr()
          : null,
      onButtonTap: offerImportAnyway
          ? () {
              importAnyway = true;
              Navigator.of(context).pop();
            }
          : null,
    ),
  );
  return importAnyway;
}

/// Asks the user to log into Janitor.AI again after a [JanitorAuthException].
///
/// Reached only with local extraction on and an account Glaze still believes is
/// signed in: the stored session went stale, so the import cannot create the
/// chat it captures from. Tapping the button opens the login sheet directly.
///
/// Returns true when the user went through the login sheet, so the caller can
/// retry the import.
Future<bool> showJanitorSessionExpiredSheet(BuildContext context) async {
  var relog = false;
  await GlazeBottomSheet.show<void>(
    context,
    title: 'catalog_janitor_session_expired_title'.tr(),
    bigInfo: BottomSheetBigInfo(
      icon: Icons.person_off_outlined,
      description: 'catalog_janitor_session_expired'.tr(),
      buttonText: 'catalog_janitor_session_expired_login'.tr(),
      onButtonTap: () {
        relog = true;
        Navigator.of(context).pop();
      },
    ),
  );
  if (!relog || !context.mounted) return false;
  await showJanitorLoginSheet(context);
  return true;
}
