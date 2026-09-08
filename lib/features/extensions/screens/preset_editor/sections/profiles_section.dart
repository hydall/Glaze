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

class ProfilesSection extends ConsumerWidget {
  const ProfilesSection({required this.preset, super.key});

  final ExtensionPreset preset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MenuGroup(
          header: 'Профили подключения (generateText)',
          items: [
            _ProfileTile(preset: preset, profile: ConnectionProfile.big),
            _ProfileTile(preset: preset, profile: ConnectionProfile.medium),
            _ProfileTile(preset: preset, profile: ConnectionProfile.small),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Сопоставление для glaze.generateText({ preset }). Пусто = использовать активный API.',
            style: TextStyle(
              fontSize: 12,
              color: context.cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ),
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
    final configsAsync = ref.watch(apiListProvider);
    final configs = configsAsync.value ?? const <ApiConfig>[];
    return Material(
      color: Colors.transparent,
      child: ListTile(
        title: Text(profile.name),
        subtitle: Text(
          _displayName(configs, current),
          style: TextStyle(
            fontSize: 12,
            color: context.cs.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openProfilePicker(context, ref, configs, current),
      ),
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
  if (current.isEmpty) return 'Использовать основной';
  final match = configs.where((c) => c.id == current).firstOrNull;
  return match == null
      ? 'Не найдено (id=$current)'
      : (match.name.isNotEmpty ? match.name : 'Без имени');
}
