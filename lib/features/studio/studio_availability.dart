import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/studio_feature_provider.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';

/// Studio is closed until it is reworked after the 1.0 release.
///
/// While this is false the interface hides every Studio surface: agentic
/// presets stay in the Presets list but can only be exported or deleted, the
/// Studio slots leave the Agents tab, and a Studio left switched on from an
/// earlier version is turned off at launch. Flip it back to reopen all of it.
const bool studioAvailable = false;

/// Explains why an agentic preset cannot be picked.
Future<void> showStudioUnavailableSheet(BuildContext context) {
  return GlazeBottomSheet.show<void>(
    context,
    title: 'menu_studio'.tr(),
    bigInfo: BottomSheetBigInfo(
      icon: Icons.smart_toy_outlined,
      description: 'studio_unavailable_notice'.tr(),
    ),
    items: [
      BottomSheetItem(
        label: 'btn_ok'.tr(),
        centered: true,
        onTap: () => Navigator.of(context, rootNavigator: true).pop(),
      ),
    ],
  );
}

/// Turns off a Studio that an earlier version left active and tells the user
/// why. The plain preset that was active before Studio takes over again.
Future<void> retireActiveStudio(BuildContext context, WidgetRef ref) async {
  if (studioAvailable) return;
  final notifier = ref.read(studioFeatureEnabledProvider.notifier);
  if (!await notifier.settled) return;
  await notifier.setEnabled(false);
  if (!context.mounted) return;
  await showStudioUnavailableSheet(context);
}
