import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/character.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/lorebook.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/chat_session_ops_provider.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/connection_sheet_widgets.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/help_tip.dart';

class LorebookConnectionsSheet extends ConsumerStatefulWidget {
  final String lorebookId;
  const LorebookConnectionsSheet({super.key, required this.lorebookId});

  @override
  ConsumerState<LorebookConnectionsSheet> createState() =>
      _LorebookConnectionsSheetState();
}

class _LorebookConnectionsSheetState
    extends ConsumerState<LorebookConnectionsSheet> {
  @override
  Widget build(BuildContext context) {
    final lorebooks = ref.watch(lorebooksProvider).value ?? [];
    final lb = lorebooks.where((l) => l.id == widget.lorebookId).firstOrNull;
    if (lb == null) return const SizedBox.shrink();

    final activations = ref.watch(lorebookActivationsProvider);
    final chars = ref.watch(charactersProvider).value ?? const <Character>[];
    final characterTargetIds = activations.character.entries
        .where((e) => e.value.contains(lb.id))
        .map((e) => e.key)
        .toSet();
    if (lb.activationScope == 'character' &&
        lb.activationTargetId?.isNotEmpty == true) {
      final persistedTarget = lb.activationTargetId!;
      if (_isCharacterGroupId(chars, persistedTarget)) {
        characterTargetIds.removeWhere(
          (id) => _characterGroupId(chars, id) == persistedTarget,
        );
      }
      characterTargetIds.add(persistedTarget);
    }
    final chatIds = activations.chat.entries
        .where((e) => e.value.contains(lb.id))
        .map((e) => e.key)
        .toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${'header_connections'.tr()}: ${lb.name}',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const HelpTip(term: 'connections'),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Text(
                'lorebook_scope_label'.tr(),
                style: TextStyle(color: context.cs.onSurfaceVariant),
              ),
              const SizedBox(width: 8),
              ConnectionScopeChip(
                label: 'level_global'.tr(),
                selected: lb.enabled,
                color: Colors.green,
              ),
              const SizedBox(width: 6),
              ConnectionScopeChip(
                label: 'level_character'.tr(),
                selected: characterTargetIds.isNotEmpty,
                color: Colors.purple,
              ),
              const SizedBox(width: 6),
              ConnectionScopeChip(
                label: 'level_chat'.tr(),
                selected: chatIds.isNotEmpty,
                color: Colors.orange,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        ConnectionSection(
          icon: Icons.public,
          title: 'label_global'.tr(),
          child: ConnectionToggleRow(
            label: 'label_global_enabled'.tr(),
            value: lb.enabled,
            onChanged: (v) {
              final notifier = ref.read(lorebooksProvider.notifier);
              notifier.updateLorebook(lb.copyWith(enabled: v));
            },
          ),
        ),

        ConnectionSection(
          icon: Icons.person,
          title: 'lbc_section_characters'.tr(),
          onAdd: () => _addCharacterConnection(lb),
          child: characterTargetIds.isEmpty
              ? ConnectionEmptyHint('no_char_connections'.tr())
              : Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: characterTargetIds
                      .map(
                        (id) => ConnectionChip(
                          id: id,
                          futureLabel: _charName(id),
                          onRemove: () => _setCharacterActivation(
                            lb.id,
                            id,
                            enabled: false,
                          ),
                        ),
                      )
                      .toList(),
                ),
        ),

        ConnectionSection(
          icon: Icons.chat,
          title: 'lbc_section_chats'.tr(),
          onAdd: () => _addChatConnection(lb),
          child: chatIds.isEmpty
              ? ConnectionEmptyHint('no_chat_connections'.tr())
              : Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: chatIds
                      .map(
                        (id) => ConnectionChip(
                          id: id,
                          futureLabel: _chatLabel(id),
                          onRemove: () => _toggleActivation(lb.id, 'chat', id),
                        ),
                      )
                      .toList(),
                ),
        ),

        const SizedBox(height: 24),
      ],
    );
  }

  Future<String> _charName(String id) async {
    final chars = ref.read(charactersProvider).value ?? [];
    final direct = chars.where((c) => c.id == id).firstOrNull;
    if (direct != null && !_isCharacterGroupId(chars, id)) return direct.name;
    final group = chars.where((c) => _characterGroupId(chars, c.id) == id);
    final c =
        group.where((c) => c.variantOrder == 0).firstOrNull ??
        group.firstOrNull;
    return c?.name ?? id;
  }

  String _characterGroupId(List<Character> chars, String characterId) {
    final character = chars.where((c) => c.id == characterId).firstOrNull;
    final groupId = character?.variantGroupId;
    return groupId?.isNotEmpty == true ? groupId! : characterId;
  }

  bool _isCharacterGroupId(List<Character> chars, String id) => chars.any(
    (character) =>
        character.variantGroupId == id ||
        (character.variantGroupId.isEmpty && character.id == id),
  );

  void _setCharacterActivation(
    String lbId,
    String targetId, {
    required bool enabled,
  }) {
    final chars = ref.read(charactersProvider).value ?? const <Character>[];
    final current = ref.read(lorebookActivationsProvider);
    final map = Map<String, List<String>>.from(current.character);
    final targetIsGroup = _isCharacterGroupId(chars, targetId);
    final matchingKeys = map.keys
        .where(
          (id) =>
              id == targetId ||
              (targetIsGroup && _characterGroupId(chars, id) == targetId),
        )
        .toList(growable: false);

    for (final id in matchingKeys) {
      final ids = List<String>.from(map[id]!)..remove(lbId);
      if (ids.isEmpty) {
        map.remove(id);
      } else {
        map[id] = ids;
      }
    }
    if (enabled) {
      final ids = List<String>.from(map[targetId] ?? const []);
      if (!ids.contains(lbId)) ids.add(lbId);
      map[targetId] = ids;
    }
    _commitActivation(lbId, 'character', current.copyWith(character: map));
  }

  Future<String> _chatLabel(String sessionId) async {
    final sessions = ref.read(chatSessionOpsProvider).value ?? [];
    final s = sessions.where((s) => s.id == sessionId).firstOrNull;
    if (s == null) return sessionId;
    final chars = ref.read(charactersProvider).value ?? [];
    final char = chars.where((c) => c.id == s.characterId).firstOrNull;
    return '${char?.name ?? s.characterId} #${s.sessionIndex}';
  }

  void _toggleActivation(String lbId, String scope, String targetId) {
    final current = ref.read(lorebookActivationsProvider);
    final map = scope == 'character'
        ? Map<String, List<String>>.from(current.character)
        : Map<String, List<String>>.from(current.chat);

    final list = List<String>.from(map[targetId] ?? []);
    final wasLinked = list.contains(lbId);
    if (wasLinked) {
      list.remove(lbId);
    } else {
      list.add(lbId);
    }
    if (list.isEmpty) {
      map.remove(targetId);
    } else {
      map[targetId] = list;
    }

    final updated = scope == 'character'
        ? current.copyWith(character: map)
        : current.copyWith(chat: map);
    _commitActivation(lbId, scope, updated);
  }

  void _commitActivation(
    String lbId,
    String scope,
    LorebookActivations updated,
  ) {
    ref.read(lorebookActivationsProvider.notifier).state = updated;
    saveLorebookActivations(updated);

    final lorebooks = ref.read(lorebooksProvider).value ?? [];
    final lb = lorebooks.where((l) => l.id == lbId).firstOrNull;
    if (lb != null) {
      var allLinked = scope == 'character'
          ? updated.character.entries
                .where((e) => e.value.contains(lbId))
                .map((e) => e.key)
                .toList()
          : updated.chat.entries
                .where((e) => e.value.contains(lbId))
                .map((e) => e.key)
                .toList();
      if (allLinked.isEmpty && !lb.enabled) {
        ref
            .read(lorebooksProvider.notifier)
            .updateLorebook(
              lb.copyWith(activationScope: 'global', activationTargetId: null),
            );
      } else if (allLinked.isNotEmpty) {
        ref
            .read(lorebooksProvider.notifier)
            .updateLorebook(
              lb.copyWith(
                activationScope: scope,
                activationTargetId: allLinked.first,
              ),
            );
      }
    }
  }

  void _addCharacterConnection(Lorebook lb) async {
    final chars = ref.read(charactersProvider).value ?? [];
    final activations = ref.read(lorebookActivationsProvider);
    final existingGroupIds = activations.character.entries
        .where((e) => e.value.contains(lb.id))
        .map((e) => _characterGroupId(chars, e.key))
        .toSet();

    final representatives = <String, Character>{};
    for (final character in chars) {
      final groupId = _characterGroupId(chars, character.id);
      final current = representatives[groupId];
      if (current == null || character.variantOrder < current.variantOrder) {
        representatives[groupId] = character;
      }
    }
    final available = representatives.entries
        .where((entry) => !existingGroupIds.contains(entry.key))
        .toList();
    if (available.isEmpty) {
      GlazeToast.show(context, 'lorebook_all_chars_connected'.tr());
      return;
    }

    final selected = await GlazeBottomSheet.show<MapEntry<String, Character>>(
      context,
      title: 'lbc_add_character'.tr(),
      items: available
          .map(
            (entry) => BottomSheetItem(
              label: entry.value.name,
              onTap: () =>
                  Navigator.of(context, rootNavigator: true).pop(entry),
            ),
          )
          .toList(),
    );

    if (selected != null) {
      _setCharacterActivation(lb.id, selected.key, enabled: true);
    }
  }

  void _addChatConnection(Lorebook lb) async {
    final sessions = ref.read(chatSessionOpsProvider).value ?? [];
    final activations = ref.read(lorebookActivationsProvider);
    final existingIds = activations.chat.entries
        .where((e) => e.value.contains(lb.id))
        .map((e) => e.key)
        .toSet();

    final available = sessions
        .where((s) => !existingIds.contains(s.id))
        .toList();
    if (available.isEmpty) {
      GlazeToast.show(context, 'lorebook_no_unbound_chats'.tr());
      return;
    }

    final chars = ref.read(charactersProvider).value ?? [];

    final selected = await GlazeBottomSheet.show<ChatSession>(
      context,
      title: 'lbc_add_chat'.tr(),
      items: available.map((s) {
        final char = chars.where((c) => c.id == s.characterId).firstOrNull;
        return BottomSheetItem(
          label: '${char?.name ?? s.characterId} #${s.sessionIndex}',
          onTap: () => Navigator.of(context, rootNavigator: true).pop(s),
        );
      }).toList(),
    );

    if (selected != null) {
      _toggleActivation(lb.id, 'chat', selected.id);
    }
  }
}

void showLorebookConnections(BuildContext context, String lorebookId) {
  GlazeBottomSheet.show<void>(
    context,
    child: LorebookConnectionsSheet(lorebookId: lorebookId),
  );
}
