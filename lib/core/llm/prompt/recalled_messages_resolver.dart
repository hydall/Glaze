import '../game_time.dart';
import '../memory_temporal_context.dart';
import 'recalled_message_chunk.dart';

/// Resolves recalled raw-message evidence against an explicit request window.
final class RecalledMessagesResolver {
  const RecalledMessagesResolver();

  String? resolve({
    required List<RecalledMessageChunk> chunks,
    required Set<String> visibleMessageIds,
    String? fallbackContent,
    bool disableSourceWindowExclusion = false,
    GameTimeState gameTime = const GameTimeState(),
  }) {
    if (chunks.isEmpty) {
      if (fallbackContent == null || fallbackContent.trim().isEmpty) {
        return null;
      }
      return '${historicalMemoryHeader(gameTime)}\n'
          '${memoryOccurrence(null)}\n$fallbackContent';
    }

    final resolvedChunks =
        disableSourceWindowExclusion || visibleMessageIds.isEmpty
        ? chunks
        : chunks
              .where(
                (chunk) =>
                    chunk.messageIds.isEmpty ||
                    !chunk.messageIds.any(visibleMessageIds.contains),
              )
              .toList(growable: false);
    if (!resolvedChunks.any((chunk) => chunk.text.trim().isNotEmpty)) {
      return null;
    }

    final block = StringBuffer();
    block.writeln('<recalled_messages>');
    block.writeln(historicalMemoryHeader(gameTime));
    block.writeln(
      'Semantically relevant raw message chunks from earlier in this chat. '
      'Use them as historical source text, preserving speaker perspective.',
    );
    for (final chunk in resolvedChunks) {
      final text = chunk.text.trim();
      if (text.isEmpty) continue;
      block.writeln('---');
      block.writeln(memoryOccurrence(chunk.ledgerRange));
      block.writeln(text);
    }
    block.writeln('</recalled_messages>');
    return block.toString().trim();
  }
}
