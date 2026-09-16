import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/models/api_config.dart';
import '../../../../../shared/theme/app_colors.dart';
import '../../../../../shared/widgets/menu_group.dart';
import '../../../../settings/api_list_provider.dart';
import '../../../models/connection_profiles.dart';
import '../../../models/extension_preset.dart';
import '../../../providers/extension_presets_provider.dart';
import '../widgets/profile_picker_sheet.dart';

/// Which connection each of the preset's three profiles talks to.
///
/// This is the preset's API card: `glaze.generateText({ preset: 'big' })` and
/// its two siblings resolve here, and a profile left empty falls back to the
/// connection the app is on.
class ProfilesSection extends ConsumerWidget {
  const ProfilesSection({required this.preset, super.key});

  final ExtensionPreset preset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuGroup(
      header: 'extblocks_api_section'.tr(),
      description: 'extblocks_api_section_desc'.tr(),
      items: [
        for (final profile in ConnectionProfile.values)
          _ProfileTile(preset: preset, profile: profile),
      ],
    );
  }
}

class _ProfileTile extends ConsumerWidget {
  const _ProfileTile({required this.preset, required this.profile});

  final ExtensionPreset preset;
  final ConnectionProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = _profileId(preset, profile);
    final configs = ref.watch(apiListProvider).value ?? const <ApiConfig>[];
    // A compact value row rather than a boxed selector: three of those would
    // make the API card taller than the block list it sits above.
    return MenuItem(
      label: 'extblocks_profile_${profile.id}'.tr(),
      value: _displayName(configs, current),
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 20,
        color: context.cs.onSurfaceVariant,
      ),
      onTap: () => _openProfilePicker(context, ref, configs, current),
    );
  }

  Future<void> _openProfilePicker(
    BuildContext context,
    WidgetRef ref,
    List<ApiConfig> configs,
    String current,
  ) async {
    final next = await ProfilePickerSheet.pick(
      context,
      profile: profile,
      configs: configs,
      current: current,
    );
    if (next == null || next == current) return;
    final updated = switch (profile) {
      ConnectionProfile.big => preset.copyWith(
        connectionProfiles: preset.connectionProfiles.copyWith(big: next),
      ),
      ConnectionProfile.medium => preset.copyWith(
        connectionProfiles: preset.connectionProfiles.copyWith(medium: next),
      ),
      ConnectionProfile.small => preset.copyWith(
        connectionProfiles: preset.connectionProfiles.copyWith(small: next),
      ),
    };
    await ref.read(extensionPresetsProvider.notifier).update(updated);
  }
}

String _profileId(ExtensionPreset preset, ConnectionProfile profile) {
  return switch (profile) {
    ConnectionProfile.big => preset.connectionProfiles.big,
    ConnectionProfile.medium => preset.connectionProfiles.medium,
    ConnectionProfile.small => preset.connectionProfiles.small,
  };
}

String _displayName(List<ApiConfig> configs, String current) {
  if (current.isEmpty) return 'extblocks_profile_default'.tr();
  final match = configs.where((c) => c.id == current).firstOrNull;
  if (match == null) return 'extblocks_profile_missing'.tr(args: [current]);
  return match.name.isNotEmpty ? match.name : 'unnamed_entry'.tr();
}
