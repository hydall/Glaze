/// NoAssistant mode — a port of the legacy Vue app's `noAssistant` preset
/// option (`buildNoAssistantHistory` in `generationWorker.js`).
///
/// Instead of a turn-by-turn conversation, the whole chat history goes out as
/// **one assistant message**, every line labelled with a speaker prefix
/// (`User: …`, `Char: …`). The model then continues that assistant message
/// rather than answering a user turn, which is what text-completion-style
/// backends and "no assistant" jailbreak setups expect.
///
/// Around the history the prompt is merged the way Vue's forced
/// `mergePrompts` did: each run of non-assistant preset blocks collapses into
/// one message of the preset's merge role, assistant blocks (a prefill, say)
/// stay on their own.
///
/// It is a **preset** setting, as it was in Vue: the prompt shape belongs with
/// the prompt.
///
/// **Deviations from Vue.**
/// - Prefixes and the stop string go through macros, so `{{user}}:` stops on
///   the persona's name rather than on the literal text.
/// - Depth injections (author's note, depth lorebook entries) that sit inside
///   the history are kept, inline and unprefixed, at their depth. Vue dropped
///   them altogether, which silently lost the author's note.
/// - History attachments are not sent: the combined message is an assistant
///   turn, and chat-completion endpoints reject images there. Vue lost them
///   the same way, by flattening the content to a string.
library;

import '../../models/preset.dart';
import '../history_assembler.dart' show PromptMessage;
import '../macro_engine.dart';

/// Values offered for [Preset.squashRole]. `none` turns the squash off.
class NoAssistantSquashRole {
  const NoAssistantSquashRole._();

  static const String assistant = 'assistant';
  static const String user = 'user';
  static const String none = 'none';

  static const List<String> all = [assistant, user, none];

  /// Vue offered `system`, which no history message carries — the same as
  /// [none]. Anything else unrecognised falls back to [assistant], Vue's
  /// default.
  static String normalize(String? value) {
    if (value == 'system') return none;
    return all.contains(value) ? value! : assistant;
  }
}

/// Values offered for [Preset.mergeRole].
class NoAssistantMergeRole {
  const NoAssistantMergeRole._();

  static const List<String> all = ['system', 'user', 'assistant'];

  /// Anything unrecognised falls back to `system`, Vue's default.
  static String normalize(String? value) =>
      all.contains(value) ? value! : 'system';
}

/// The NoAssistant settings of one preset, resolved for a request.
class NoAssistantOptions {
  const NoAssistantOptions({
    this.userPrefix = '',
    this.charPrefix = '',
    this.squashRole = NoAssistantSquashRole.assistant,
    this.mergeRole = 'system',
    this.stopString = '',
  });

  /// Prepended to every user message in the history block.
  final String userPrefix;

  /// Prepended to every character message in the history block.
  final String charPrefix;

  /// Consecutive history messages of this role are joined into one before
  /// the prefixes go on — see [NoAssistantSquashRole].
  final String squashRole;

  /// Role of each merged run of preset blocks around the history.
  final String mergeRole;

  /// Sent as the request's stop sequence; empty sends none.
  final String stopString;

  /// The `stop` list for a request.
  List<String> get stop => stopString.isEmpty ? const [] : [stopString];

  /// The options [preset] asks for, or null when the mode is off. Prefixes
  /// and the stop string are macro-expanded with [charName] and [userName]:
  /// a stop string of `{{user}}:` has to match the name the model actually
  /// writes.
  static NoAssistantOptions? of(
    Preset? preset, {
    required String charName,
    required String userName,
  }) {
    if (preset == null || !preset.noAssistant) return null;
    final ctx = MacroContext(
      charName: charName,
      userName: userName,
      charId: '',
      sessionId: '',
    );
    String expand(String text) =>
        text.contains('{{') ? replaceMacros(text, ctx).text : text;
    return NoAssistantOptions(
      userPrefix: expand(preset.userPrefix),
      charPrefix: expand(preset.charPrefix),
      squashRole: NoAssistantSquashRole.normalize(preset.squashRole),
      mergeRole: NoAssistantMergeRole.normalize(preset.mergeRole),
      stopString: expand(preset.stopString),
    );
  }
}

/// `blockId` of the combined history message.
const String noAssistantHistoryBlockId = 'chat_history';

/// Reshapes a built prompt for NoAssistant mode.
///
/// The history span runs from the first history message to the last one;
/// whatever the builder injected between them (depth blocks) is folded into
/// the combined message with it. Blocks before and after the span are merged
/// into [NoAssistantOptions.mergeRole] runs. [messages] is never mutated.
List<PromptMessage> applyNoAssistant(
  List<PromptMessage> messages,
  NoAssistantOptions options,
) {
  final first = messages.indexWhere((m) => m.isHistory);
  if (first < 0) return _mergeBlocks(messages, options.mergeRole);
  final last = messages.lastIndexWhere((m) => m.isHistory);

  final history = _buildHistoryContent(
    messages.sublist(first, last + 1),
    options,
  );
  return [
    ..._mergeBlocks(messages.sublist(0, first), options.mergeRole),
    if (history.isNotEmpty)
      PromptMessage(
        role: 'assistant',
        content: history,
        blockId: noAssistantHistoryBlockId,
        blockName: 'chat_history',
        isHistory: true,
      ),
    ..._mergeBlocks(messages.sublist(last + 1), options.mergeRole),
  ];
}

/// Vue's forced `mergePrompts`: consecutive non-assistant blocks become one
/// [mergeRole] message joined by newlines; an assistant block ends the run and
/// passes through untouched.
List<PromptMessage> _mergeBlocks(List<PromptMessage> blocks, String mergeRole) {
  final out = <PromptMessage>[];
  final run = <PromptMessage>[];

  void flush() {
    final parts = run
        .map((m) => m.content)
        .where((c) => c.trim().isNotEmpty)
        .toList();
    if (parts.isNotEmpty || run.any((m) => m.sendEmptyBlock)) {
      out.add(
        PromptMessage(
          role: mergeRole,
          content: parts.join('\n'),
          blockName: 'merged prompt',
          isLorebook: run.any((m) => m.isLorebook),
          isSummary: run.any((m) => m.isSummary),
          imagePaths: [for (final m in run) ...m.imagePaths],
          sendEmptyBlock: run.any((m) => m.sendEmptyBlock),
        ),
      );
    }
    run.clear();
  }

  for (final block in blocks) {
    if (block.role == 'assistant') {
      flush();
      out.add(block);
    } else {
      run.add(block);
    }
  }
  flush();
  return out;
}

/// One line per message, squashed first and prefixed after — Vue's
/// `squashHistory` + `buildNoAssistantHistory`. Injected blocks carry no
/// speaker, so they get no prefix and never join a squash run.
String _buildHistoryContent(
  List<PromptMessage> span,
  NoAssistantOptions options,
) {
  final lines = <({String? speaker, String text})>[];
  for (final message in span) {
    if (message.content.trim().isEmpty) continue;
    final speaker = message.isHistory
        ? (message.role == 'user' ? 'user' : 'assistant')
        : null;
    final previous = lines.isEmpty ? null : lines.last;
    if (speaker != null &&
        speaker == options.squashRole &&
        previous?.speaker == speaker) {
      lines[lines.length - 1] = (
        speaker: speaker,
        text: '${previous!.text}\n${message.content}',
      );
    } else {
      lines.add((speaker: speaker, text: message.content));
    }
  }

  return lines
      .map(
        (line) => switch (line.speaker) {
          'user' => '${options.userPrefix}${line.text}',
          'assistant' => '${options.charPrefix}${line.text}',
          _ => line.text,
        },
      )
      .join('\n');
}
