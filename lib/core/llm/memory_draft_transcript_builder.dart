import '../models/chat_message.dart';
import '../models/preset.dart';
import 'auxiliary_timed_history.dart';
import 'regex_service.dart';

class MemoryDraftTranscriptBuilder {
  const MemoryDraftTranscriptBuilder._();

  static String? ledgerRange(List<ChatMessage> messages) {
    final stamps = messages
        .where(
          (message) =>
              !message.isHidden &&
              !message.isTyping &&
              message.content.trim().isNotEmpty &&
              (message.role == 'user' || message.role == 'assistant'),
        )
        .map((message) => message.time?.trim())
        .whereType<String>()
        .where((stamp) => stamp.isNotEmpty)
        .toList(growable: false);
    if (stamps.isEmpty) return null;
    if (stamps.length == 1 || stamps.first == stamps.last) return stamps.first;
    return '${stamps.first} -> ${stamps.last}';
  }

  static String build({
    required List<ChatMessage> messages,
    required List<PresetRegex> scripts,
    required RegexApplyContext context,
  }) {
    final enabled = scripts
        .where((script) => !script.disabled && script.memoryBookRetrieval)
        .toList(growable: false);
    final eligible = messages
        .where(
          (message) =>
              !message.isHidden &&
              !message.isTyping &&
              message.content.trim().isNotEmpty &&
              (message.role == 'user' || message.role == 'assistant'),
        )
        .toList(growable: false);

    final transcript = [
      for (var index = 0; index < eligible.length; index++)
        _formatMessage(
          eligible[index],
          enabled,
          context,
          depth: eligible.length - 1 - index,
          totalMessages: eligible.length,
        ),
    ].join('\n\n');
    final range = ledgerRange(eligible);
    if (range == null) return transcript;
    return 'AUTHORITATIVE_LEDGER_RANGE: $range\n'
        'Treat this exact value as source metadata. Do not infer, shorten, '
        'translate, or recalculate it.\n\n'
        '$transcript';
  }

  static String _formatMessage(
    ChatMessage message,
    List<PresetRegex> scripts,
    RegexApplyContext context, {
    required int depth,
    required int totalMessages,
  }) {
    final transformed = scripts.isEmpty
        ? message.content
        : applyRegexes(
            message.content,
            message.role == 'user' ? 1 : 2,
            2,
            scripts,
            RegexApplyContext(
              char: context.char,
              persona: context.persona,
              sessionVars: context.sessionVars,
              globalVars: context.globalVars,
              depth: depth,
              totalMessages: totalMessages,
              macroContext: context.macroContext,
            ),
            isPrompt: true,
            ignoreEphemerality: true,
          );
    return '${message.role}: ${auxiliaryTimedContent(message.copyWith(content: transformed))}';
  }
}
