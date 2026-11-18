import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/agent_binding.dart';
import '../../core/models/agent_definition.dart';
import '../../core/state/agent_providers.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_switch.dart';
import '../../shared/widgets/menu_group.dart';
import '../chat/chat_provider.dart';
import 'agent_labels.dart';
import 'agent_run_log_sheet.dart';
import 'agents_screen.dart';

/// "Agents in this chat": the chat's off switch, every agent with its state
/// here and where that state comes from, the cost of a reply, and the way to
/// the run log and the library.
Future<void> showChatAgentsSheet(BuildContext context, String charId) =>
    GlazeBottomSheet.show<void>(
      context,
      title: 'agents_chat_title'.tr(),
      child: ChatAgentsSheet(charId: charId),
    );

class ChatAgentsSheet extends ConsumerWidget {
  final String charId;

  const ChatAgentsSheet({super.key, required this.charId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(
      chatProvider(charId).select((s) => s.value?.session),
    );
    if (session == null) return const SizedBox(height: 120);
    final off = agentsOffInSession(session.sessionVars);
    final entries =
        ref
            .watch(chatAgentsProvider((charId: charId, sessionId: session.id)))
            .value ??
        const <ChatAgentEntry>[];
    final active = [
      for (final entry in entries)
        if (entry.state.enabled && !off) entry.agent,
    ];
    final requests = active.fold<double>(
      0,
      (sum, agent) => sum + agentRequestsPerReply(agent),
    );
    final blocking = active
        .where((a) => a.phase == AgentPhase.preGeneration)
        .length;
    final repo = ref.read(agentBindingRepoProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MenuGroup(
          items: [
            MenuSwitchItem(
              label: 'agents_chat_master'.tr(),
              description: 'agents_chat_master_desc'.tr(),
              value: !off,
              onChanged: (v) =>
                  ref.read(chatProvider(charId).notifier).setAgentsOff(!v),
            ),
          ],
        ),
        if (active.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              [
                'agents_cost'.tr(args: [formatRequestCount(requests)]),
                if (blocking > 0) 'agents_cost_delay'.tr(args: ['$blocking']),
              ].join(' · '),
              style: TextStyle(
                fontSize: 13,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
        MenuGroup(
          items: [
            for (final entry in entries)
              MenuItem(
                icon: agentPhaseIcon(entry.agent.phase),
                label: entry.agent.displayName,
                subtitle:
                    '${agentPhaseLabel(entry.agent.phase)} · '
                    '${agentSourceLabel(entry.state.source)}',
                trailing: GlazeSwitch(
                  value: entry.state.enabled,
                  onChanged: off
                      ? null
                      : (v) => repo.set(
                          agentId: entry.agent.id,
                          scope: AgentBindingScope.chat,
                          targetId: session.id,
                          enabled: v,
                        ),
                ),
                onTap: () {
                  if (entry.state.source != AgentStateSource.chat) return;
                  GlazeBottomSheet.show<void>(
                    context,
                    title: entry.agent.displayName,
                    items: [
                      BottomSheetItem(
                        icon: Icons.undo,
                        label: 'agents_chat_reset'.tr(),
                        onTap: () {
                          Navigator.of(context, rootNavigator: true).pop();
                          repo.set(
                            agentId: entry.agent.id,
                            scope: AgentBindingScope.chat,
                            targetId: session.id,
                            enabled: null,
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
          ],
        ),
        MenuGroup(
          items: [
            MenuItem(
              icon: Icons.receipt_long_outlined,
              label: 'agents_run_log'.tr(),
              onTap: () => showAgentRunLogSheet(context, session.id),
            ),
            MenuItem(
              icon: Icons.smart_toy_outlined,
              label: 'agents_open_library'.tr(),
              onTap: () => showAgentsSheet(context),
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
