import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/chat_message.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../chat_provider.dart';
import 'coverage_rows.dart';
import 'next_turn_coverage_view.dart';
import 'past_turn_coverage_view.dart';

/// Coverage, in the same shape as the request timeline next to it: the next
/// request at the top, then the turns that already happened.
///
/// Splitting it that way is the whole point — "what would fire now" and "what
/// actually fired then" are different questions, and the old single Coverage
/// tab only ever answered the first one while looking like it answered both.
class CoverageSubTab extends ConsumerStatefulWidget {
  const CoverageSubTab({
    super.key,
    required this.charId,
    required this.onDetailChanged,
  });

  final String charId;
  final ValueChanged<bool> onDetailChanged;

  @override
  ConsumerState<CoverageSubTab> createState() => _CoverageSubTabState();
}

class _CoverageSubTabState extends ConsumerState<CoverageSubTab> {
  bool _openNext = false;
  String? _openMessageId;

  void _open({bool next = false, String? messageId}) {
    setState(() {
      _openNext = next;
      _openMessageId = messageId;
    });
    widget.onDetailChanged(true);
  }

  void _close() {
    setState(() {
      _openNext = false;
      _openMessageId = null;
    });
    widget.onDetailChanged(false);
  }

  @override
  void dispose() {
    if (_openNext || _openMessageId != null) widget.onDetailChanged(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatProvider(widget.charId)).value;
    final sessionId = state?.session?.id ?? '';
    final messages = state?.messages ?? const <ChatMessage>[];

    if (_openNext) {
      return NextTurnCoverageView(
        charId: widget.charId,
        sessionId: sessionId,
        onBack: _close,
      );
    }

    final openId = _openMessageId;
    if (openId != null) {
      final index = messages.indexWhere((m) => m.id == openId);
      if (index >= 0) {
        return PastTurnCoverageView(
          sessionId: sessionId,
          message: messages[index],
          turnNumber: index + 1,
          onBack: _close,
        );
      }
    }

    // Newest first, and only assistant turns: a user message injects nothing.
    final turns = <({ChatMessage message, int number})>[
      for (var i = messages.length - 1; i >= 0; i--)
        if (messages[i].role == 'assistant' && !messages[i].isTyping)
          (message: messages[i], number: i + 1),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        CoverageNextRow(onTap: () => _open(next: true)),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
          child: Text(
            'coverage_past_turns'.tr(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurfaceVariant,
            ),
          ),
        ),
        if (turns.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 18),
            child: Text(
              'coverage_no_past_turns'.tr(),
              style: TextStyle(
                fontSize: 13,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final turn in turns)
            CoverageTurnRow(
              number: turn.number,
              message: turn.message,
              onTap: () => _open(messageId: turn.message.id),
            ),
      ],
    );
  }
}
