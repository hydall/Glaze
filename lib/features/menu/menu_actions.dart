import 'package:flutter/material.dart';

import '../../core/services/onboarding_service.dart';
import '../backup/backup_screen.dart';
import '../cloud_sync/widgets/sync_sheet.dart';

/// Openers for the More tab destinations that are sheets rather than routes.
///
/// They live here because both the menu list and the menu search results need
/// to reach them, and a search hit must open exactly what the menu row opens.

Future<void> openBackupsSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      isScrollControlled: true,
      builder: (_) => const BackupScreen(),
    );

Future<void> openCloudSyncSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewPaddingOf(sheetContext).bottom,
        ),
        child: const SyncSheet(),
      ),
    );

/// Clears the "onboarding seen" flag and replays the tour from the top.
Future<void> replayOnboarding(BuildContext context) async {
  await resetOnboarding();
  if (context.mounted) showOnboarding(context);
}
