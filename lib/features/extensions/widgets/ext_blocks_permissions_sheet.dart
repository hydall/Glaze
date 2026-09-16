import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/sheet_view.dart';
import '../providers/extension_presets_provider.dart';
import '../screens/preset_editor/sections/permissions_section.dart';

/// What a preset's blocks are allowed to reach, opened from the panel.
///
/// Permissions are the one thing in the preset editor worth reaching without
/// leaving the panel: a block that silently does nothing is nearly always a
/// capability that was never granted.
class ExtBlocksPermissionsSheet extends ConsumerWidget {
  const ExtBlocksPermissionsSheet({required this.presetId, super.key});

  final String presetId;

  static Future<void> show(BuildContext context, String presetId) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => ExtBlocksPermissionsSheet(presetId: presetId),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preset = ref.watch(extensionPresetByIdProvider(presetId));

    return SheetView(
      title: 'extblocks_permissions'.tr(),
      // The header inset SheetView reports lives inside its own subtree, so
      // the padding has to be read from a context below it.
      body: Builder(
        builder: (context) => ListView(
          padding: EdgeInsets.fromLTRB(
            0,
            MediaQuery.paddingOf(context).top + 12,
            0,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: [
            if (preset == null)
              Center(child: Text('preset_not_found'.tr()))
            else
              PermissionsSection(preset: preset),
          ],
        ),
      ),
    );
  }
}
