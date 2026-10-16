import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/lorebook_merger.dart';
import '../../../core/llm/lorebook_scanner.dart';
import '../../../core/llm/macro_engine.dart' as engine;
import '../../../core/llm/prompt/lorebook_classifier.dart';
import '../../../core/models/character.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/lorebook_provider.dart';

/// World info for the original's `{{wiBefore}}`, `{{wiAfter}}`,
/// `{{wiExamples}}`, `{{wiDepth}}` and `{{wiAll}}`.
typedef BlockWorldInfo = ({
  String before,
  String after,
  String examples,
  String depth,
});

final _wiMacro = RegExp(
  r'\{\{(wiBefore|wiAfter|wiExamples|wiDepth|wiAll)\}\}',
  caseSensitive: false,
);
final _mainPromptMacro = RegExp(r'\{\{mainPrompt\}\}', caseSensitive: false);

/// Whether any of [messages] asks for world info.
bool requestNeedsWorldInfo(List<Map<String, dynamic>> messages) =>
    messages.any((m) => _wiMacro.hasMatch('${m['content'] ?? ''}'));

/// Whether any of [messages] asks for the main prompt.
bool requestNeedsMainPrompt(List<Map<String, dynamic>> messages) =>
    messages.any((m) => _mainPromptMacro.hasMatch('${m['content'] ?? ''}'));

/// The original's `checkAllMacros` over a block's finished request: the world
/// info macros and `{{mainPrompt}}` are filled in, every message keeping its
/// role. A value left `null` leaves its macros as they are.
List<Map<String, dynamic>> applyBlockRequestMacros(
  List<Map<String, dynamic>> messages, {
  BlockWorldInfo? worldInfo,
  String? mainPrompt,
}) {
  if (worldInfo == null && mainPrompt == null) return messages;
  final all = worldInfo == null
      ? ''
      : [
          worldInfo.before,
          worldInfo.after,
          worldInfo.examples,
          worldInfo.depth,
        ].where((part) => part.isNotEmpty).join('\n\n');
  return [
    for (final message in messages)
      if (message['content'] is String)
        {
          ...message,
          'content': _fill(
            message['content'] as String,
            worldInfo: worldInfo,
            all: all,
            mainPrompt: mainPrompt,
          ),
        }
      else
        message,
  ];
}

String _fill(
  String text, {
  required BlockWorldInfo? worldInfo,
  required String all,
  required String? mainPrompt,
}) {
  var out = text;
  if (worldInfo != null) {
    out = out.replaceAllMapped(
      _wiMacro,
      (m) => switch (m.group(1)!.toLowerCase()) {
        'wibefore' => worldInfo.before,
        'wiafter' => worldInfo.after,
        'wiexamples' => worldInfo.examples,
        'widepth' => worldInfo.depth,
        _ => all,
      },
    );
  }
  if (mainPrompt != null) {
    out = out.replaceAllMapped(_mainPromptMacro, (_) => mainPrompt);
  }
  return out;
}

final blockRequestMacrosProvider = Provider<BlockRequestMacros>(
  (ref) => BlockRequestMacros(ref),
);

/// Reads what [applyBlockRequestMacros] fills in: the chat preset's main
/// prompt and the world info a block's request activates.
class BlockRequestMacros {
  BlockRequestMacros(this._ref);

  final Ref _ref;

  /// [messages] with the macros filled in, reading only what they ask for.
  Future<List<Map<String, dynamic>>> apply(
    List<Map<String, dynamic>> messages, {
    required Character? character,
    required String sessionId,
    String userName = 'User',
  }) async {
    final needsWi = requestNeedsWorldInfo(messages);
    final needsMain = requestNeedsMainPrompt(messages);
    if (!needsWi && !needsMain) return messages;
    return applyBlockRequestMacros(
      messages,
      worldInfo: needsWi
          ? await _worldInfo(messages, character, sessionId, userName)
          : null,
      mainPrompt: needsMain ? await _mainPrompt(character, sessionId) : null,
    );
  }

  /// The chat preset's `main` block as written; `''` when it has none.
  Future<String> _mainPrompt(Character? character, String sessionId) async {
    final presets = await _ref.read(presetRepoProvider).getAll();
    final preset = getEffectivePreset(
      presets,
      character?.id,
      sessionId.isEmpty ? null : sessionId,
      _ref.read(activePresetIdProvider),
      _ref.read(presetConnectionsProvider),
    );
    final main = preset?.blocks.where((b) => b.id == 'main').firstOrNull;
    return main?.content ?? '';
  }

  /// The world info the request itself activates, as the original scans the
  /// block's prompt rather than the chat.
  Future<BlockWorldInfo> _worldInfo(
    List<Map<String, dynamic>> messages,
    Character? character,
    String sessionId,
    String userName,
  ) async {
    final source = await _ref.read(lorebookRepoProvider).getAll();
    final lorebooks = sessionId.isEmpty
        ? source
        : await _ref
              .read(sessionLorebookEvolutionRepoProvider)
              .applyOverlays(sessionId: sessionId, lorebooks: source);
    final settings = _ref.read(lorebookSettingsProvider);
    final history = [
      for (var i = 0; i < messages.length; i++)
        ChatMessage(
          id: 'extblock-request-$i',
          role: messages[i]['role'] == 'assistant' ? 'assistant' : 'user',
          content: '${messages[i]['content'] ?? ''}',
        ),
    ];
    final scanned = scanLorebooks(
      history: history,
      char: character,
      textToScan: history.map((m) => m.content).join('\n'),
      chatId: sessionId.isEmpty ? null : sessionId,
      lorebooks: lorebooks,
      globalSettings: settings,
      activations: _ref.read(lorebookActivationsProvider),
      applyPerBookLimits: false,
    );
    final classified = classifyLorebooks(
      mergeKeywordVector(
        keywordEntries: scanned,
        vectorEntries: const [],
        settings: settings,
      ),
      engine.MacroContext(
        charName: character?.name ?? '',
        charDescription: character?.description,
        charScenario: character?.scenario,
        charPersonality: character?.personality,
        userName: userName,
        charId: character?.id ?? '',
        sessionId: sessionId,
        macroName: character?.macroName,
      ),
      settings,
    );
    String join(Iterable<String> parts) =>
        parts.where((p) => p.trim().isNotEmpty).join('\n');
    return (
      before: join(classified.loreBefore.map((m) => m.content)),
      after: join(classified.loreAfter.map((m) => m.content)),
      // This app's lorebooks have no example or at-depth positions.
      examples: '',
      depth: '',
    );
  }
}
