import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../settings/widgets/api_slot_group.dart';
import '../../../models/extension_preset.dart';
import '../../../providers/extension_presets_provider.dart';

/// The connection every LLM call this preset makes runs on.
///
/// It is the same [ApiSlotGroup] the Agents tab and the memory books sheet bind
/// their auxiliary calls with, so the connection and model rows read and behave
/// identically here. Unlike those two it writes straight through — the panel
/// has no draft to save.
class ProfilesSection extends ConsumerWidget {
  const ProfilesSection({required this.preset, super.key});

  final ExtensionPreset preset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void update(ExtensionPreset next) =>
        ref.read(extensionPresetsProvider.notifier).update(next);

    return ApiSlotGroup(
      header: 'tab_api'.tr(),
      description: 'extblocks_api_section_desc'.tr(),
      apiConfigId: preset.apiConfigId,
      onApiConfigChanged: (id) => update(
        // Endpoint and key always come from the selected connection; a model
        // chosen against the previous one would not resolve.
        preset.copyWith(apiConfigId: id, apiModel: ''),
      ),
      modelRows: [
        ApiSlotModelRow(
          value: preset.apiModel,
          onChanged: (value) => update(preset.copyWith(apiModel: value)),
        ),
      ],
    );
  }
}
