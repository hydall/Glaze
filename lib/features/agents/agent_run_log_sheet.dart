import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/agent_run.dart';
import '../../core/state/agent_providers.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_expansion_tile.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/menu_group.dart';
import 'agent_labels.dart';

/// The run log of one chat: every agent call, newest first, with what it was
/// asked and what it answered.
Future<void> showAgentRunLogSheet(BuildContext context, String sessionId) =>
    GlazeBottomSheet.show<void>(
      context,
      title: 'agents_run_log'.tr(),
      child: AgentRunLogPanel(sessionId: sessionId),
    );

class AgentRunLogPanel extends ConsumerWidget {
  final String sessionId;

  const AgentRunLogPanel({super.key, required this.sessionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = ref.watch(agentRunsProvider(sessionId)).value ?? const [];
    if (runs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'agents_run_log_empty'.tr(),
          style: TextStyle(color: context.cs.onSurfaceVariant),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MenuGroup(items: [for (final run in runs) _RunTile(run: run)]),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _RunTile extends StatelessWidget {
  final AgentRun run;

  const _RunTile({required this.run});

  @override
  Widget build(BuildContext context) {
    final time = DateTime.fromMillisecondsSinceEpoch(run.createdAt);
    final stamp =
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
    final stats = 'agents_run_tokens'.tr(
      args: [
        '${run.promptTokens}',
        '${run.completionTokens}',
        (run.durationMs / 1000).toStringAsFixed(1),
      ],
    );
    return GlazeExpansionTile(
      leading: Icon(
        run.ok ? agentPhaseIcon(run.phase) : Icons.error_outline,
        color: run.ok ? context.cs.onSurfaceVariant : context.cs.error,
        size: 20,
      ),
      title: Text(run.agentName.isEmpty ? run.agentId : run.agentName),
      subtitle: Text('$stamp · ${agentPhaseLabel(run.phase)} · $stats'),
      children: [
        if (run.error != null && run.error!.isNotEmpty)
          _Section(label: 'agents_run_error'.tr(), text: run.error!),
        if (run.output.isNotEmpty)
          _Section(label: 'agents_run_answer'.tr(), text: run.output),
        _Section(label: 'agents_run_request'.tr(), text: _prompt(run)),
      ],
    );
  }

  static String _prompt(AgentRun run) {
    try {
      final messages = jsonDecode(run.promptJson) as List;
      return [
        for (final m in messages)
          if (m is Map) '[${m['role']}]\n${m['content']}',
      ].join('\n\n');
    } catch (_) {
      return run.promptJson;
    }
  }
}

class _Section extends StatelessWidget {
  final String label;
  final String text;

  const _Section({required this.label, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: GestureDetector(
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: text));
          GlazeToast.show(context, 'chat_copied'.tr());
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(text, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
