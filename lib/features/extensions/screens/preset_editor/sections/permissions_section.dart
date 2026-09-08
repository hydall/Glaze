import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../shared/theme/app_colors.dart';
import '../../../../../shared/widgets/menu_group.dart';
import '../../../models/extension_preset.dart';
import '../../../models/preset_permissions.dart';
import '../../../providers/extension_presets_provider.dart';

class PermissionsSection extends ConsumerWidget {
  const PermissionsSection({required this.preset, super.key});

  final ExtensionPreset preset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MenuGroup(
          header: 'Разрешения (capabilities)',
          items: [
            for (final cap in GlazeCapability.values)
              _CapabilityTile(preset: preset, capability: cap),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Каждое разрешение открывает JS-блокам доступ к соответствующему методу glaze.*. По умолчанию всё запрещено (default-deny).',
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

class _CapabilityTile extends ConsumerWidget {
  const _CapabilityTile({required this.preset, required this.capability});

  final ExtensionPreset preset;
  final GlazeCapability capability;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final granted = preset.permissions.isGranted(capability);
    return Material(
      color: Colors.transparent,
      child: SwitchListTile(
        title: Text(capability.label),
        subtitle: Text(
          capability.id,
          style: TextStyle(
            fontSize: 11,
            color: context.cs.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
        value: granted,
        onChanged: (v) {
          final next = preset.permissions.copyWithField(capability, v);
          ref
              .read(extensionPresetsProvider.notifier)
              .update(preset.copyWith(permissions: next));
        },
      ),
    );
  }
}
