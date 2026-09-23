import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/db_provider.dart';
import '../../../core/state/memory_settings_provider.dart';
import '../../../core/state/studio_feature_provider.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../settings/app_settings_provider.dart';

/// Confirms a chat-message deletion and explains what else is affected.
///
/// A delete also rolls back state derived from the deleted message and every
/// message after it. Which features are named in the warning depends on what
/// the chat actually uses: the agent sentence appears only under an agentic
/// preset, and the MemoryBook sentence only when a MemoryBook is enabled for
/// the session. Returns true when the caller may proceed and false when the
/// user backed out. When the `confirmMessageDelete` setting is off the old
/// immediate delete is kept and this returns true without showing the sheet.
Future<bool> confirmMessageDeletion(
  BuildContext context,
  WidgetRef ref, {
  String? sessionId,
}) async {
  final settings = ref.read(appSettingsProvider).value;
  if (settings?.confirmMessageDelete == false) return true;

  final warning = <String>['delete_messages_warning_base'.tr()];
  if (await _agentsInUse(ref)) {
    warning.add('delete_messages_warning_agents'.tr());
  }
  if (await _memoryBookInUse(ref, sessionId)) {
    warning.add('delete_messages_warning_memory'.tr());
  }
  warning.add('delete_messages_warning_confirm'.tr());

  if (!context.mounted) return false;
  final result = await GlazeBottomSheet.show<bool>(
    context,
    title: 'delete_messages_title'.tr(),
    bigInfo: BottomSheetBigInfo(
      icon: Icons.warning_amber_rounded,
      description: warning.join(),
    ),
    items: [
      BottomSheetItem(
        icon: Icons.delete,
        label: 'delete_messages_confirm'.tr(),
        isDestructive: true,
        onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
      ),
      BottomSheetItem(
        icon: Icons.close,
        label: 'delete_messages_cancel'.tr(),
        onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
      ),
    ],
  );
  return result ?? false;
}

/// An agentic preset is active, so its agents hold tracker state that the
/// delete rolls back.
Future<bool> _agentsInUse(WidgetRef ref) async {
  try {
    return await ref.read(studioFeatureSettledProvider.future);
  } catch (_) {
    return false;
  }
}

/// A MemoryBook is enabled for the session, so entries anchored to the deleted
/// messages exist and will be removed.
Future<bool> _memoryBookInUse(WidgetRef ref, String? sessionId) async {
  if (sessionId == null || sessionId.isEmpty) return false;
  try {
    if (!ref.read(memoryGlobalSettingsProvider).enabled) return false;
    final book = await ref.read(memoryBookProvider(sessionId).future);
    return book != null && book.settings.enabled;
  } catch (_) {
    return false;
  }
}
