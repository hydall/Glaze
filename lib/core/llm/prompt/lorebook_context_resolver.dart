import '../../models/character.dart';
import '../../models/chat_message.dart';
import '../../models/lorebook.dart';
import '../history_assembler.dart';
import '../lorebook_merger.dart';
import '../lorebook_scanner.dart';
import '../macro_engine.dart';
import '../tokenizer.dart';
import 'lorebook_classifier.dart';

final class LorebookContextResolution {
  final List<LorebookEntry> mergedEntries;
  final List<PromptMessage> loreBefore;
  final List<PromptMessage> loreAfter;
  final List<String> loreMacroBuffer;
  final List<String> loreScenario;
  final List<String> lorePersonality;
  final List<String> loreDescription;
  final List<TriggeredEntry> triggeredEntries;
  final int vectorLoreTokens;
  final Map<String, ScannedEntry> keywordEntries;
  final Map<String, LorebookEntry> vectorEntries;

  const LorebookContextResolution({
    required this.mergedEntries,
    required this.loreBefore,
    required this.loreAfter,
    required this.loreMacroBuffer,
    required this.loreScenario,
    required this.lorePersonality,
    required this.loreDescription,
    required this.triggeredEntries,
    required this.vectorLoreTokens,
    required this.keywordEntries,
    required this.vectorEntries,
  });
}

final class LorebookContextResolver {
  const LorebookContextResolver();

  LorebookContextResolution resolve({
    required List<ChatMessage> history,
    required Character character,
    required String? sessionId,
    required List<Lorebook> lorebooks,
    required LorebookGlobalSettings settings,
    required LorebookActivations activations,
    required List<LorebookEntry> vectorEntries,
    required MacroContext macroContext,
    List<ScannedEntry>? preScannedEntries,
  }) {
    final visibleHistory = history
        .where((message) => !message.isHidden && !message.isTyping)
        .toList();
    final textToScan =
        visibleHistory
            .where((message) => message.role == 'user')
            .lastOrNull
            ?.content ??
        '';
    final keywordEntries =
        preScannedEntries ??
        scanLorebooks(
          history: visibleHistory,
          char: character,
          textToScan: textToScan,
          chatId: sessionId,
          lorebooks: lorebooks,
          globalSettings: settings,
          activations: activations,
          applyPerBookLimits: false,
        );

    final normalizedVectorEntries = vectorEntries
        .map((entry) {
          if (entry.lorebookId.isNotEmpty) return entry;
          final matches = lorebooks.where(
            (book) => book.entries.any(
              (candidate) =>
                  candidate.id == entry.id &&
                  candidate.content == entry.content,
            ),
          );
          final book = matches.length == 1 ? matches.single : null;
          return book == null
              ? entry
              : entry.copyWith(lorebookId: book.id, lorebookName: book.name);
        })
        .map((entry) {
          final book = lorebooks
              .where((candidate) => candidate.id == entry.lorebookId)
              .firstOrNull;
          final effectiveEntry = book?.entries
              .where((candidate) => candidate.id == entry.id)
              .firstOrNull;
          return effectiveEntry == null
              ? entry
              : entry.copyWith(content: effectiveEntry.content);
        })
        .toList();

    final mergedEntries = mergeKeywordVector(
      keywordEntries: keywordEntries,
      vectorEntries: normalizedVectorEntries,
      settings: settings,
    );
    final keywordEntriesByKey = <String, ScannedEntry>{
      for (final entry in keywordEntries)
        '${entry.lorebookId}_${entry.id}': entry,
    };
    final vectorEntriesByKey = <String, LorebookEntry>{
      for (final entry in normalizedVectorEntries)
        '${entry.lorebookId}_${entry.id}': entry,
    };

    final vectorLoreContent = mergedEntries
        .where((entry) {
          final key = '${entry.lorebookId}_${entry.id}';
          return vectorEntriesByKey.containsKey(key) &&
              !keywordEntriesByKey.containsKey(key);
        })
        .map((entry) => entry.content)
        .join('\n\n');
    final triggeredEntries = <TriggeredEntry>[];
    for (final merged in mergedEntries) {
      final key = '${merged.lorebookId}_${merged.id}';
      final keyword = keywordEntriesByKey[key];
      if (keyword != null) {
        triggeredEntries.add(
          TriggeredEntry(
            id: keyword.id,
            name: keyword.comment.isNotEmpty ? keyword.comment : keyword.id,
            lorebookName: keyword.lorebookName,
            lorebookId: keyword.lorebookId,
            source: keyword.constant ? 'constant' : 'keyword',
          ),
        );
        continue;
      }
      final vector = vectorEntriesByKey[key];
      if (vector != null) {
        triggeredEntries.add(
          TriggeredEntry(
            id: vector.id,
            name: vector.comment.isNotEmpty ? vector.comment : vector.id,
            lorebookName: vector.lorebookName,
            lorebookId: vector.lorebookId,
            source: 'vector',
          ),
        );
      }
    }

    final classified = classifyLorebooks(mergedEntries, macroContext, settings);
    return LorebookContextResolution(
      mergedEntries: mergedEntries,
      loreBefore: classified.loreBefore,
      loreAfter: classified.loreAfter,
      loreMacroBuffer: classified.loreMacroBuffer,
      loreScenario: classified.loreScenario,
      lorePersonality: classified.lorePersonality,
      loreDescription: classified.loreDescription,
      triggeredEntries: triggeredEntries,
      vectorLoreTokens: vectorLoreContent.isEmpty
          ? 0
          : estimateTokens(vectorLoreContent),
      keywordEntries: keywordEntriesByKey,
      vectorEntries: vectorEntriesByKey,
    );
  }
}
