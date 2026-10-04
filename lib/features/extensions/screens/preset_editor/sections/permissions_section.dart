import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../shared/theme/app_colors.dart';
import '../../../../../shared/widgets/menu_group.dart';
import '../../../models/extension_preset.dart';
import '../../../models/preset_permissions.dart';
import '../../../providers/extension_presets_provider.dart';

/// One card of the permissions list: a scope, and the capabilities under it.
typedef _PermissionGroup = (
  String header,
  List<(GlazeCapability, String)> rows,
);

/// The twenty capabilities, grouped the way they are reasoned about — the four
/// variable scopes first, then the things a block can *do*. A flat list of
/// twenty switches is the same information and unreadable.
const List<_PermissionGroup> _groups = [
  (
    'perm_group_chat_vars',
    [
      (GlazeCapability.readChatVars, 'perm_read'),
      (GlazeCapability.writeChatVars, 'perm_write'),
      (GlazeCapability.deleteChatVars, 'perm_delete'),
    ],
  ),
  (
    'perm_group_character_vars',
    [
      (GlazeCapability.readCharacterVars, 'perm_read'),
      (GlazeCapability.writeCharacterVars, 'perm_write'),
      (GlazeCapability.deleteCharacterVars, 'perm_delete'),
    ],
  ),
  (
    'perm_group_global_vars',
    [
      (GlazeCapability.readGlobalVars, 'perm_read'),
      (GlazeCapability.writeGlobalVars, 'perm_write'),
      (GlazeCapability.deleteGlobalVars, 'perm_delete'),
    ],
  ),
  (
    'perm_group_message_vars',
    [
      (GlazeCapability.readMessageVars, 'perm_read'),
      (GlazeCapability.writeMessageVars, 'perm_write'),
      (GlazeCapability.deleteMessageVars, 'perm_delete'),
    ],
  ),
  (
    'perm_group_actions',
    [
      (GlazeCapability.generateText, 'perm_generate_text'),
      (GlazeCapability.triggerGeneration, 'perm_trigger_generation'),
      (GlazeCapability.injectPrompt, 'perm_inject_prompt'),
      (GlazeCapability.uninjectPrompt, 'perm_uninject_prompt'),
      (GlazeCapability.playAudio, 'perm_play_audio'),
      (GlazeCapability.executeCommand, 'perm_execute_command'),
      (GlazeCapability.showToast, 'perm_show_toast'),
    ],
  ),
];

/// Capability switches for one extension preset.
///
/// Used twice over the same widget: as a section of the preset editor, and as
/// the body of the panel's permissions sheet. Both write straight to the
/// preset, so there is no draft to keep in step.
class PermissionsSection extends StatelessWidget {
  const PermissionsSection({required this.preset, super.key});

  final ExtensionPreset preset;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (header, rows) in _groups)
          MenuGroup(
            header: header.tr(),
            items: [
              for (final (capability, labelKey) in rows)
                _CapabilityTile(
                  preset: preset,
                  capability: capability,
                  label: labelKey.tr(),
                ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            'perm_default_deny_hint'.tr(),
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
  const _CapabilityTile({
    required this.preset,
    required this.capability,
    required this.label,
  });

  final ExtensionPreset preset;
  final GlazeCapability capability;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuSwitchItem(
      label: label,
      // The bridge checks this exact id, so it stays on screen next to the
      // switch that grants it.
      description: capability.id,
      value: preset.permissions.isGranted(capability),
      onChanged: (value) => ref
          .read(extensionPresetsProvider.notifier)
          .update(
            preset.copyWith(
              permissions: preset.permissions.copyWithField(capability, value),
            ),
          ),
    );
  }
}
