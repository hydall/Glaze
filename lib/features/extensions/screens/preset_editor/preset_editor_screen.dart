import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../shared/shell/nav_height_provider.dart';
import '../../../../shared/widgets/glaze_scaffold.dart';
import '../../providers/extension_presets_provider.dart';
import 'sections/blocks_section.dart';
import 'sections/permissions_section.dart';
import 'sections/profiles_section.dart';

class PresetEditorScreen extends ConsumerWidget {
  const PresetEditorScreen({required this.presetId, super.key});

  final String presetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preset = ref.watch(extensionPresetByIdProvider(presetId));
    final bottomPad = ref.watch(navHeightProvider) + 20;

    if (preset == null) {
      return GlazeScaffold(
        title: 'preset_options'.tr(),
        onBack: () => context.pop(),
        body: Center(child: Text('preset_not_found'.tr())),
      );
    }

    return GlazeScaffold(
      title: preset.name,
      onBack: () => context.pop(),
      body: ListView(
        padding: EdgeInsets.fromLTRB(0, 12, 0, bottomPad),
        children: [
          BlocksSection(preset: preset),
          const SizedBox(height: 24),
          PermissionsSection(preset: preset),
          const SizedBox(height: 24),
          ProfilesSection(preset: preset),
        ],
      ),
    );
  }
}
