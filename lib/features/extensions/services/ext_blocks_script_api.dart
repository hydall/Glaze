/// The app-side half of the original ExtBlocks script API.
///
/// A script written for the original calls `GenerationService`,
/// `GeneratedPlugin`, `RewritePlugin`, `BlockService` and the like; the
/// sandbox's compatibility layer turns those calls into the `extBlocks*`
/// bridge methods answered here, all under the preset's "run blocks"
/// permission. Messages are named by their index in the chat, as the
/// original's `messageId` is.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/character.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/persona.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/persona_resolution.dart';
import '../../../core/utils/id_generator.dart';
import '../../chat/chat_provider.dart';
import '../models/block_config.dart';
import '../models/block_modes.dart';
import '../models/block_run_status.dart';
import '../models/extension_preset.dart';
import '../models/info_block.dart';
import '../providers/info_blocks_provider.dart';
import 'block_content_extractor.dart';
import 'card_blocks.dart';
import 'extension_post_gen_service.dart';
import 'info_block_service.dart';
import 'rewrite/rewrite_service.dart';

final extBlocksScriptApiProvider = Provider<ExtBlocksScriptApi>(
  ExtBlocksScriptApi.new,
);

/// Bridge methods of the script API, by name.
abstract final class ExtBlocksScriptMethods {
  /// Generates the named blocks for a message and stores them, as
  /// `GeneratedPlugin.execute` / `GenerationService.handleBlocksGeneration`.
  static const run = 'extBlocksRun';

  /// The named blocks' content for a message, not stored
  /// (`GeneratedPlugin.generateBlockContent`).
  static const generate = 'extBlocksGenerate';

  /// A rewrite: applied to the message, or only returned
  /// (`RewritePlugin.execute` / `generateRewrite`).
  static const rewrite = 'extBlocksRewrite';

  /// Writes or clears a message's stored block states
  /// (`BlockService.addBlocksToExtra` / `purgeBlocksExtra`).
  static const store = 'extBlocksStore';

  /// Stops every block run (`ApiService.abortGeneration`).
  static const abort = 'extBlocksAbort';

  static const all = {run, generate, rewrite, store, abort};
}

/// One message of one chat, with what a block run on it needs.
class _Target {
  const _Target({
    required this.charId,
    required this.sessionId,
    required this.messages,
    required this.index,
    required this.character,
    required this.persona,
    required this.preset,
  });

  final String charId;
  final String sessionId;
  final List<ChatMessage> messages;
  final int index;
  final Character character;
  final Persona? persona;
  final ExtensionPreset preset;

  ChatMessage get message => messages[index];
}

class ExtBlocksScriptApi {
  ExtBlocksScriptApi(this._ref);

  final Ref _ref;

  Future<Object?> handle(
    String method,
    Map<String, dynamic> params,
    Map<String, dynamic> context,
  ) async {
    switch (method) {
      case ExtBlocksScriptMethods.abort:
        _ref.read(extensionPostGenServiceProvider).cancelBlocks();
        return null;
      case ExtBlocksScriptMethods.run:
        await _run(await _target(params, context), params);
        return null;
      case ExtBlocksScriptMethods.generate:
        return _generate(await _target(params, context), params);
      case ExtBlocksScriptMethods.rewrite:
        return _rewrite(await _target(params, context), params);
      case ExtBlocksScriptMethods.store:
        await _store(await _target(params, context), params);
        return null;
    }
    throw UnsupportedError('Unknown ExtBlocks method "$method"');
  }

  Future<_Target> _target(
    Map<String, dynamic> params,
    Map<String, dynamic> context,
  ) async {
    final sessionId = context['sessionId'];
    final charId = context['characterId'];
    if (sessionId is! String || sessionId.isEmpty) {
      throw StateError('Chat session context is not available');
    }
    if (charId is! String || charId.isEmpty) {
      throw StateError('Character context is not available');
    }

    final chat = _ref.read(chatProvider(charId)).value;
    final messages = chat?.session?.id == sessionId
        ? chat!.messages
        : (await _ref.read(chatRepoProvider).getById(sessionId))?.messages ??
              const <ChatMessage>[];
    if (messages.isEmpty) throw StateError('The chat has no messages');

    final character =
        _ref.read(characterByIdProvider(charId)) ??
        await _ref.read(characterRepoProvider).getById(charId);
    if (character == null) throw StateError('Character "$charId" not found');

    final active = activeExtBlocksPresetOf(_ref.read);
    if (active == null) throw StateError('No ExtBlocks preset is active');

    final raw = params['messageId'];
    final index = raw is num ? raw.toInt() : messages.length - 1;
    return _Target(
      charId: charId,
      sessionId: sessionId,
      messages: messages,
      index: index.clamp(0, messages.length - 1),
      character: character,
      persona: _ref.read(
        effectivePersonaForChatProvider((charId: charId, sessionId: sessionId)),
      ),
      preset: withCardBlocks(active, cardBlocksOf(character)),
    );
  }

  /// The blocks [params] names, in the order it names them.
  List<BlockConfig> _blocks(_Target target, Map<String, dynamic> params) {
    final raw = params['blocks'];
    final names = raw is List ? raw.whereType<String>().toList() : <String>[];
    final blocks = [
      for (final name in names)
        ?target.preset.blocks.where((b) => b.name == name).firstOrNull,
    ];
    if (blocks.isEmpty) {
      throw ArgumentError('No block named ${names.join(', ')}');
    }
    return blocks;
  }

  Map<String, String> _macros(Map<String, dynamic> params) {
    final raw = params['additionalMacro'];
    if (raw is! Map) return const {};
    return {for (final e in raw.entries) '${e.key}': '${e.value ?? ''}'};
  }

  /// Runs the named blocks on the message the way the original's generation
  /// order does: rewrites marked "before", then generated and accumulation
  /// blocks, then rewrites marked "after". Scripts run in the sandbox.
  Future<void> _run(_Target target, Map<String, dynamic> params) async {
    final blocks = _blocks(target, params);
    final macros = _macros(params);
    final post = _ref.read(extensionPostGenServiceProvider);
    var messages = target.messages;

    Future<void> rewrite(BlockRunOrder order) async {
      final rewrites = [
        for (final b in blocks)
          if (b.type == BlockType.rewrite && b.generationOrder == order) b,
      ];
      if (rewrites.isEmpty) return;
      messages = await _ref
          .read(extBlocksRewriteServiceProvider)
          .rewriteMessage(
            blocks: rewrites,
            charId: target.charId,
            sessionId: target.sessionId,
            messageId: target.message.id,
            messages: messages,
            character: target.character,
            persona: target.persona,
            preset: target.preset,
            additionalMacros: macros,
          );
    }

    Future<void> generate(BlockConfig block) {
      final binding = _binding(target);
      return post.rerunBlock(
        blockId: block.id,
        messageId: target.message.id,
        swipeId: binding.swipeId,
        agentSwipeId: binding.agentSwipeId,
        sessionId: target.sessionId,
        charId: target.charId,
        messages: messages,
        character: target.character,
        persona: target.persona,
      );
    }

    await rewrite(BlockRunOrder.before);
    final generated = [
      for (final b in blocks)
        if (b.type == BlockType.generated) b,
    ];
    if (params['parallel'] == true) {
      await Future.wait(generated.map(generate));
    } else {
      for (final block in generated) {
        await generate(block);
      }
    }
    for (final block in blocks) {
      if (block.type == BlockType.accumulation) await generate(block);
    }
    await rewrite(BlockRunOrder.after);
  }

  /// The blocks' content, in their tags, joined; nothing is stored.
  Future<String> _generate(_Target target, Map<String, dynamic> params) async {
    final blocks = _blocks(target, params);
    final first = blocks.first;
    final result = await _withBlockRun(
      (cancelToken) => _ref
          .read(infoBlockServiceProvider)
          .generateSingleBlockContent(
            sessionId: target.sessionId,
            messageId: target.message.id,
            messages: target.messages,
            blockConfig: first,
            character: target.character,
            persona: target.persona?.name,
            personaModel: target.persona,
            previousOutput: null,
            contextPolicy: first.contextPolicy,
            preset: target.preset,
            swipeId: target.message.swipeId,
            cancelToken: cancelToken,
            dynamicMacros: _macros(params),
            group: blocks.length > 1 ? blocks : const [],
          ),
    );
    if (result.error != null) throw StateError(result.error!);
    return result.content ?? '';
  }

  /// The rewritten text. With `apply` the message is rewritten and saved, as
  /// `RewritePlugin.execute` does; without, the text is only returned, as
  /// `RewritePlugin.generateRewrite` does.
  Future<String> _rewrite(_Target target, Map<String, dynamic> params) async {
    final blocks = [
      for (final b in _blocks(target, params))
        if (b.type == BlockType.rewrite) b,
    ];
    if (blocks.isEmpty) throw ArgumentError('No rewrite block named');
    final macros = _macros(params);
    final textToRewrite = macros['textToRewrite'];
    final rawRange = params['rewriteTarget'];
    final range =
        rawRange is Map && rawRange['start'] is num && rawRange['end'] is num
        ? (
            start: (rawRange['start'] as num).toInt(),
            end: (rawRange['end'] as num).toInt(),
          )
        : null;

    if (params['apply'] == true) {
      final messages = await _ref
          .read(extBlocksRewriteServiceProvider)
          .rewriteMessage(
            blocks: blocks,
            charId: target.charId,
            sessionId: target.sessionId,
            messageId: target.message.id,
            messages: target.messages,
            character: target.character,
            persona: target.persona,
            preset: target.preset,
            additionalMacros: macros,
            textToRewrite: textToRewrite,
            range: range,
          );
      return messages
              .where((m) => m.id == target.message.id)
              .firstOrNull
              ?.content ??
          target.message.content;
    }

    final source = textToRewrite == null || textToRewrite.isEmpty
        ? target.message.content
        : textToRewrite;
    final outcome = await _withBlockRun(
      (cancelToken) => _ref
          .read(extBlocksRewriteServiceProvider)
          .generateRewrite(
            block: blocks.first,
            sourceText: source,
            charId: target.charId,
            sessionId: target.sessionId,
            messageId: target.message.id,
            swipeId: target.message.swipeId,
            messages: target.messages,
            character: target.character,
            persona: target.persona,
            preset: target.preset,
            additionalMacros: macros,
            cancelToken: cancelToken,
          ),
    );
    return outcome.text;
  }

  /// `addBlocksToExtra`: each block named in `text` replaces that block's
  /// stored state on the message. `purge` clears every state it holds.
  Future<void> _store(_Target target, Map<String, dynamic> params) async {
    final notifier = _ref.read(infoBlocksProvider(target.sessionId).notifier);
    final binding = _binding(target);
    if (params['purge'] == true) {
      await notifier.deleteByMessageId(
        target.message.id,
        swipeId: binding.swipeId,
      );
      return;
    }

    final text = params['text'];
    if (text is! String || text.trim().isEmpty) return;
    final repo = _ref.read(infoBlocksRepoProvider);
    for (final block in target.preset.blocks) {
      final tag = blockTagName(
        block,
        block.template.replaceAll('{{name}}', block.name),
      );
      if (tag.isEmpty) continue;
      final inner = extractBlockInnerContent(text, tag);
      if (inner == null) continue;
      final stored = await repo.getByMessageId(
        target.sessionId,
        target.message.id,
        swipeId: binding.swipeId,
      );
      for (final row in stored.where((r) => r.blockId == block.id)) {
        await notifier.delete(row.id);
      }
      final row = InfoBlock(
        id: generateId(),
        sessionId: target.sessionId,
        messageId: target.message.id,
        swipeId: binding.swipeId,
        agentSwipeId: binding.agentSwipeId,
        blockId: block.id,
        blockName: block.name,
        blockType: block.type.name,
        content: inner.trim(),
        createdAt: DateTime.now().millisecondsSinceEpoch,
        order: block.order,
        status: BlockRunStatus.done,
      );
      await repo.insert(row);
      notifier.addOrReplace(row);
    }
  }

  ({int swipeId, int agentSwipeId}) _binding(_Target target) {
    final message = target.message;
    final agentSwipeId = _ref
        .read(infoBlocksProvider(target.sessionId).notifier)
        .resolveAgentSwipeId(
          message.id,
          swipeId: message.swipeId,
          agentSwipeId: message.agentSwipeId,
        );
    return (swipeId: message.swipeId, agentSwipeId: agentSwipeId);
  }

  /// Runs [body] as a block run, so Stop and `abortGeneration` reach it.
  Future<T> _withBlockRun<T>(Future<T> Function(CancelToken) body) =>
      _ref.read(extensionPostGenServiceProvider).withBlockRun(body);
}
