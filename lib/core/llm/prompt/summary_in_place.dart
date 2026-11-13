import '../../models/character.dart';
import '../../models/persona.dart';
import '../../models/preset.dart';
import '../../models/summary_block.dart';
import '../history_assembler.dart';
import '../macro_engine.dart';
import '../prompt_block_resolver.dart';
import 'prompt_payload.dart';

/// One message of a summary sent in place of its messages, and the history
/// message it goes right before — null for after the whole history.
typedef InPlaceSummaryMessage = ({
  PromptMessage message,
  String? beforeMessageId,
});

/// The `summary` block in [summaryInPlaceInsertion] mode: one message per
/// unbroken run of blocks ([PromptPayload.summarySegments]), each formatted
/// the way the block formats the whole summary. A payload without segments
/// sends the whole summary at the top of the history.
List<InPlaceSummaryMessage> resolveInPlaceSummary({
  required PromptPayload payload,
  required PresetBlock block,
  required Character char,
  required Persona? persona,
  required MacroContext macroCtx,
  required Map<String, String> sessionVars,
  required Map<String, String> globalVars,
}) {
  final summary = payload.summaryContent ?? '';
  if (summary.trim().isEmpty) return const [];
  final segments = payload.summarySegments.isNotEmpty
      ? payload.summarySegments
      : [
          SummarySegment(
            content: summary,
            beforeMessageId: payload.history.firstOrNull?.id,
          ),
        ];
  final resolved = <InPlaceSummaryMessage>[];
  for (final segment in segments) {
    // The block already resolved once over the whole summary, which is where
    // any variable it sets took effect; this pass is for the text alone.
    final content = resolveBlockContent(
      id: 'summary',
      rawContent: block.content,
      role: block.role,
      char: char,
      persona: persona,
      macroCtx: macroCtx,
      sessionVars: sessionVars,
      globalVars: globalVars,
      notifyObj: NotifyObj(),
      summaryContent: segment.content,
      summaryPrefix: block.prefix ?? payload.summaryPrefix,
    );
    if (content == null || content.content.trim().isEmpty) continue;
    resolved.add((
      message: PromptMessage(
        role: content.role,
        content: content.content,
        blockId: 'summary',
        blockName: block.name,
        isSummary: true,
      ),
      beforeMessageId: segment.beforeMessageId,
    ));
  }
  return resolved;
}

/// Puts each in-place summary message right before the history message it is
/// anchored to, in story order. Runs last, once the context blocks that sit
/// in front of the history have settled, so the summary stays next to the
/// messages that follow it.
///
/// A run whose anchor is not in the history goes right after the run before
/// it; one with no anchor goes after the last history message.
void placeInPlaceSummary(
  List<PromptMessage> messages,
  List<InPlaceSummaryMessage> summary,
) {
  if (summary.isEmpty) return;
  final firstHistory = messages.indexWhere((m) => m.isHistory);
  var floor = firstHistory < 0 ? messages.length : firstHistory;
  for (final run in summary) {
    final anchor = run.beforeMessageId;
    int at;
    if (anchor == null) {
      final lastHistory = messages.lastIndexWhere((m) => m.isHistory);
      at = lastHistory < floor ? floor : lastHistory + 1;
    } else {
      final found = messages.indexWhere(
        (m) => m.isHistory && m.sourceMessageId == anchor,
        floor,
      );
      at = found < 0 ? floor : found;
    }
    messages.insert(at, run.message);
    floor = at + 1;
  }
}
