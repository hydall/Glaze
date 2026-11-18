import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/agent_binding.dart';
import '../../core/models/character.dart';
import '../../core/state/agent_providers.dart';
import '../../core/state/character_provider.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_switch.dart';
import '../../shared/widgets/menu_group.dart';

/// Where one agent runs: its global switch, then the characters and chats
/// that override it — the same levels as preset bindings.
Future<void> showAgentBindingsSheet(BuildContext context, String agentId) =>
    GlazeBottomSheet.show<void>(
      context,
      title: 'agents_bindings'.tr(),
      child: AgentBindingsPanel(agentId: agentId),
    );

class AgentBindingsPanel extends ConsumerWidget {
  final String agentId;

  const AgentBindingsPanel({super.key, required this.agentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agent = ref
        .watch(agentLibraryProvider)
        .value
        ?.where((a) => a.id == agentId)
        .firstOrNull;
    if (agent == null) return const SizedBox(height: 120);
    final bindings = [
      for (final binding
          in ref.watch(agentBindingsProvider).value ?? const <AgentBinding>[])
        if (binding.agentId == agentId) binding,
    ];
    final characters =
        ref.watch(charactersProvider).value ?? const <Character>[];
    String characterName(String id) =>
        characters.where((c) => c.id == id).firstOrNull?.name ?? id;
    String chatName(String sessionId) {
      final cut = sessionId.lastIndexOf('_');
      if (cut <= 0) return sessionId;
      final index = int.tryParse(sessionId.substring(cut + 1));
      final name = characterName(sessionId.substring(0, cut));
      return index == null ? sessionId : '$name · #${index + 1}';
    }

    final repo = ref.read(agentBindingRepoProvider);
    Widget row(AgentBinding binding, String label) => MenuItem(
      icon: binding.scope == AgentBindingScope.chat
          ? Icons.chat_bubble_outline
          : Icons.person_outline,
      label: label,
      subtitle: binding.enabled
          ? 'agents_binding_on'.tr()
          : 'agents_binding_off'.tr(),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlazeSwitch(
            value: binding.enabled,
            onChanged: (v) => repo.set(
              agentId: agentId,
              scope: binding.scope,
              targetId: binding.targetId,
              enabled: v,
            ),
          ),
          InkResponse(
            radius: 20,
            onTap: () => repo.set(
              agentId: agentId,
              scope: binding.scope,
              targetId: binding.targetId,
              enabled: null,
            ),
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.close, size: 18),
            ),
          ),
        ],
      ),
      onTap: () {},
    );

    final characterBindings = [
      for (final b in bindings)
        if (b.scope == AgentBindingScope.character) b,
    ];
    final chatBindings = [
      for (final b in bindings)
        if (b.scope == AgentBindingScope.chat) b,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MenuGroup(
          items: [
            MenuSwitchItem(
              label: 'agents_bindings_global'.tr(),
              description: 'agents_bindings_global_desc'.tr(),
              value: agent.enabledGlobally,
              onChanged: (v) => ref
                  .read(agentLibraryProvider.notifier)
                  .save(agent.copyWith(enabledGlobally: v)),
            ),
          ],
        ),
        MenuGroup(
          header: 'agents_bindings_characters'.tr(),
          items: [
            for (final binding in characterBindings)
              row(binding, characterName(binding.targetId)),
            MenuItem(
              icon: Icons.add,
              label: 'agents_bindings_add_character'.tr(),
              onTap: () => _addCharacter(context, ref, characters, bindings),
            ),
          ],
        ),
        MenuGroup(
          header: 'agents_bindings_chats'.tr(),
          description: 'agents_bindings_chat_hint'.tr(),
          items: [
            if (chatBindings.isEmpty)
              MenuItem(
                icon: Icons.info_outline,
                label: 'agents_bindings_empty'.tr(),
                onTap: () {},
              ),
            for (final binding in chatBindings)
              row(binding, chatName(binding.targetId)),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  void _addCharacter(
    BuildContext context,
    WidgetRef ref,
    List<Character> characters,
    List<AgentBinding> bindings,
  ) {
    final bound = {
      for (final b in bindings)
        if (b.scope == AgentBindingScope.character) b.targetId,
    };
    final candidates = [
      for (final c in characters)
        if (!bound.contains(c.id)) c,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    GlazeBottomSheet.show<void>(
      context,
      title: 'agents_bindings_add_character'.tr(),
      items: [
        for (final character in candidates)
          BottomSheetItem(
            icon: Icons.person_outline,
            label: character.name,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              ref
                  .read(agentBindingRepoProvider)
                  .set(
                    agentId: agentId,
                    scope: AgentBindingScope.character,
                    targetId: character.id,
                    enabled: true,
                  );
            },
          ),
      ],
    );
  }
}
