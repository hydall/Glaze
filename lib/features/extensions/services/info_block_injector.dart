import '../../../core/llm/prompt/runtime_prompt_block.dart';
import '../../../core/models/chat_message.dart';
import '../models/block_config.dart';
import '../models/block_injection.dart';
import '../models/block_run_status.dart';
import '../models/extension_preset.dart';
import '../models/info_block.dart';
import 'block_content_extractor.dart';
import 'macro_expander.dart';

/// Minimal read surface used by [InfoBlockInjector] (implemented by [InfoBlocksRepository]).
abstract class InfoBlockReader {
  Future<List<InfoBlock>> getByMessageId(
    String sessionId,
    String messageId, {
    int swipeId = 0,
  });
}

/// Инжектирует инфоблоки в историю перед сборкой основного промпта.
///
/// Для каждого блока с `inject=true` берём последние [BlockConfig.injectLastN]
/// assistant-сообщений и дописываем к **каждому** из них только **его**
/// сохранённый вывод этого блока (`content\\n\\n<block>`).
class InfoBlockInjector {
  final InfoBlockReader _repository;
  final MacroContext Function() _macroContext;

  InfoBlockInjector(
    InfoBlockReader repository, {
    MacroContext Function()? macroContextResolver,
  }) : _repository = repository,
       _macroContext = macroContextResolver ?? _emptyMacroContext;

  static MacroContext _emptyMacroContext() => MacroContext.empty;

  Future<List<ChatMessage>> injectBlocks({
    required List<ChatMessage> messages,
    required String sessionId,
    required ExtensionPreset preset,
  }) async {
    final injectableBlocks = preset.blocks
        .where(
          (b) =>
              b.enabled &&
              b.inject &&
              b.injectTarget == InjectionTarget.history,
        )
        .toList();
    if (injectableBlocks.isEmpty) return messages;

    // Collect visible assistant messages from the end (newest first).
    final assistantIndices = <int>[];
    for (int i = messages.length - 1; i >= 0; i--) {
      final msg = messages[i];
      if (msg.isHidden || msg.isTyping) continue;
      if (msg.role == 'assistant' || msg.role == 'character') {
        assistantIndices.add(i);
      }
    }

    if (assistantIndices.isEmpty) return messages;

    final result = List<ChatMessage>.from(messages);
    final macroCtx = _macroContext();

    for (final blockConfig in injectableBlocks) {
      final n = blockConfig.injectLastN.clamp(0, assistantIndices.length);
      if (n <= 0) continue;

      // assistantIndices is newest-first; take first n.
      final targetIndices = assistantIndices.take(n).toList();

      for (final idx in targetIndices) {
        final msg = result[idx];
        final blocks = await _repository.getByMessageId(
          sessionId,
          msg.id,
          swipeId: msg.swipeId,
        );
        final blockResults = blocks
            .where((b) => b.blockId == blockConfig.id)
            .toList();
        if (blockResults.isEmpty) continue;

        final injected = blockResults
            .map(
              (b) => _formatInjectedContent(blockConfig, b.content, macroCtx),
            )
            .where((c) => c.trim().isNotEmpty)
            .join('\n')
            .trim();
        if (injected.isEmpty) continue;

        result[idx] = msg.copyWith(
          content: '${msg.content}\n\n${_injectSuffix(blockConfig, injected)}',
        );
      }
    }

    return result;
  }

  /// The original extension's injection: for every block injected as a
  /// prompt block, its latest finished result in the chat — searched from the
  /// newest message back, whichever side stored it — placed by the block's
  /// role, position and depth.
  ///
  /// A block that has produced nothing yet injects nothing. A negative depth
  /// is read the way the original computes it, `messages - depth`, which puts
  /// the block above the whole chat.
  Future<List<RuntimePromptBlock>> buildPromptBlocks({
    required List<ChatMessage> messages,
    required String sessionId,
    required ExtensionPreset preset,
  }) async {
    final blocks = preset.blocks
        .where(
          (b) =>
              b.enabled &&
              b.inject &&
              b.injectTarget == InjectionTarget.prompt &&
              (b.type == BlockType.generated ||
                  b.type == BlockType.accumulation),
        )
        .toList();
    if (blocks.isEmpty) return const [];

    final latest = await _latestContents(
      messages: messages,
      sessionId: sessionId,
      blockIds: {for (final b in blocks) b.id},
    );

    final macroCtx = _macroContext();
    final result = <RuntimePromptBlock>[];
    for (final block in blocks) {
      final content = latest[block.id];
      if (content == null) continue;
      final formatted = _formatInjectedContent(block, content, macroCtx);
      if (formatted.trim().isEmpty) continue;
      result.add(
        RuntimePromptBlock(
          id: 'extblocks:${block.name}',
          content: formatted,
          depth: block.injectionDepth < 0
              ? messages.length - block.injectionDepth
              : block.injectionDepth,
          role: block.injectionRole.name,
          placement: switch (block.injectionPosition) {
            InjectionPosition.inChat => RuntimePromptPlacement.depth,
            InjectionPosition.afterMainPrompt =>
              RuntimePromptPlacement.afterMain,
            InjectionPosition.beforeMainPrompt =>
              RuntimePromptPlacement.beforeMain,
          },
        ),
      );
    }
    return result;
  }

  /// What `{{ExtBlocks::name}}` stands for in this request: the latest
  /// finished state of every enabled block that leaves one, in its tag, as
  /// [RuntimePromptPlacement.macro] blocks named after the block.
  Future<List<RuntimePromptBlock>> buildMacroBlocks({
    required List<ChatMessage> messages,
    required String sessionId,
    required ExtensionPreset preset,
  }) async {
    final blocks = preset.blocks
        .where(
          (b) =>
              b.enabled &&
              (b.type == BlockType.generated ||
                  b.type == BlockType.accumulation),
        )
        .toList();
    if (blocks.isEmpty) return const [];
    final latest = await _latestContents(
      messages: messages,
      sessionId: sessionId,
      blockIds: {for (final b in blocks) b.id},
    );
    return [
      for (final block in blocks)
        if (latest[block.id] case final content?)
          RuntimePromptBlock(
            id: block.name,
            content: wrapInBlockTag(block, content),
            depth: 0,
            role: 'system',
            placement: RuntimePromptPlacement.macro,
          ),
    ];
  }

  /// The latest finished, non-empty content of each of [blockIds], searched
  /// from the newest message back on the swipes the chat shows.
  Future<Map<String, String>> _latestContents({
    required List<ChatMessage> messages,
    required String sessionId,
    required Set<String> blockIds,
  }) async {
    final latest = <String, String>{};
    for (var i = messages.length - 1; i >= 0; i--) {
      if (latest.length == blockIds.length) break;
      final msg = messages[i];
      if (msg.isTyping) continue;
      final rows = await _repository.getByMessageId(
        sessionId,
        msg.id,
        swipeId: msg.swipeId,
      );
      for (final row in rows) {
        if (!blockIds.contains(row.blockId)) continue;
        if (row.status != BlockRunStatus.done) continue;
        if (latest.containsKey(row.blockId)) continue;
        if (row.content.trim().isEmpty) continue;
        latest[row.blockId] = row.content;
      }
    }
    return latest;
  }

  /// Text after the blank line and before [blockBody] in injected history.
  String _injectSuffix(BlockConfig blockConfig, String blockBody) {
    final prefix = blockConfig.injectPrefix;
    if (prefix.isEmpty) return blockBody;
    if (prefix.endsWith('\n')) return '$prefix$blockBody';
    return '$prefix\n$blockBody';
  }

  String _formatInjectedContent(
    BlockConfig blockConfig,
    String content,
    MacroContext macroCtx,
  ) {
    // Expand {{user}} / {{char}} / etc. in the stored content so the
    // injected history reflects the current persona/character, not a
    // snapshot the LLM may have left in place at generation time.
    final expanded = expand(content, macroCtx).trim();
    if (expanded.isEmpty) return '';

    final template = blockConfig.template.trim().replaceAll(
      '{{name}}',
      blockConfig.name,
    );
    // Accumulation state is stored bare and always goes in under its block's
    // name, as the original injects it.
    if (template.isEmpty && blockConfig.type != BlockType.accumulation) {
      return expanded;
    }

    final tag = blockTagName(blockConfig, template);
    final wrappedPattern = RegExp(
      '<$tag(\\s+[^>]*)?>[\\s\\S]*<\\/$tag>',
      caseSensitive: false,
    );
    if (wrappedPattern.hasMatch(expanded)) return expanded;

    return '<$tag>\n$expanded\n</$tag>';
  }
}
