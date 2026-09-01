import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/transport/chat_transport_request.dart';
import '../../../core/llm/transport/llm_capture_context.dart';
import '../../../core/llm/transport/transport_factory.dart';
import '../../../core/llm/history_assembler.dart';
import '../../../core/models/api_config.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/character.dart';
import '../../../core/models/persona.dart';
import '../../../core/llm/prompt/main_model_context_snapshot.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/utils/error_format.dart';
import '../../image_gen/services/image_tag_markup.dart';
import '../../settings/api_list_provider.dart';
import '../models/block_config.dart';
import '../models/info_block.dart';
import '../models/extension_context_policy.dart';
import 'block_content_extractor.dart';
import 'block_context_builder.dart';
import 'ext_blocks_prompt_injection.dart';
import 'macro_expander.dart';
import 'extension_context_assembler.dart';
import 'runtime_prompt_injection_service.dart';

final infoBlockServiceProvider = Provider<InfoBlockService>(
  (ref) => InfoBlockService(ref),
);

/// Chat text on its way into a block agent's prompt, with every image block
/// reduced to the tag that asked for the picture.
///
/// The stored form of a finished block carries paths into this device's data
/// root, which mean nothing to a model — and an agent that reads one writes one
/// back, producing a block that points at files nobody generated (INV-IG12).
String _withoutImagePaths(String content) =>
    ImageTagMarkup.reduceBlocksToInstructions(content);

class InfoBlockService {
  InfoBlockService(this._ref);

  final Ref _ref;

  /// Generates the text content for a single infoblock block.
  /// Returns `(content, error)` — on success `error` is null; on failure
  /// `content` is null and `error` describes what went wrong.
  Future<({String? content, String? error})> generateSingleBlockContent({
    required String sessionId,
    required String messageId,
    required List<ChatMessage> messages,
    required BlockConfig blockConfig,
    required Character? character,
    required String? persona,
    String? personaPrompt,
    required String? previousOutput,
    ExtensionContextPolicy contextPolicy = const ExtensionContextPolicy(),
    MainModelContextSnapshot? mainModelContextSnapshot,
    Persona? personaModel,
    int swipeId = 0,
    CancelToken? cancelToken,
    void Function(String partial)? onStreamUpdate,
  }) async {
    if (cancelToken?.isCancelled == true) return (content: null, error: null);

    // Pull this block's own prior outputs (same name, earlier messages) so the
    // model can continue/update the existing state instead of regenerating from
    // scratch. Controlled per-block via [previousBlocksCount] (0 = disabled).
    final previousBlocks = await _loadPreviousBlocks(
      sessionId: sessionId,
      currentMessageId: messageId,
      currentSwipeId: swipeId,
      messages: messages,
      blockConfig: blockConfig,
    );

    // Image / JS blocks run an LLM agent first; no XML template extract.
    final isRawAgent =
        blockConfig.type == BlockType.imageGen ||
        blockConfig.type == BlockType.jsRunner;
    final resolvedTemplate = isRawAgent ? '' : _resolveTemplate(blockConfig);
    final systemContent = _buildSystemMessage(
      blockConfig: blockConfig,
      template: resolvedTemplate,
      character: character,
      persona: persona,
    );
    final supplementalContent = _buildSupplementalMessage(
      blockConfig: blockConfig,
      character: character,
      persona: persona,
      previousOutput: previousOutput,
      previousBlocks: previousBlocks,
    );
    final canUseSnapshot = contextPolicy.useMainModelContext
        ? mainModelContextSnapshot != null
        : mainModelContextSnapshot?.filterablePromptMessages != null;
    final needsReconstructedHistory =
        contextPolicy.legacyPromptSemantics || !canUseSnapshot;
    final contextMessages = needsReconstructedHistory
        ? await _ref
              .read(extBlocksPromptInjectionProvider)
              .injectIntoHistory(sessionId: sessionId, messages: messages)
        : messages;
    final legacyContextMessages = contextPolicy.legacyPromptSemantics
        ? buildContextMessages(
            messages: contextMessages,
            anchorMessageId: messageId,
            count: blockConfig.contextMessageCount,
          )
        : const <ChatMessage>[];
    final runtimePromptMessages =
        contextPolicy.includeRuntimePrompts && needsReconstructedHistory
        ? _ref
              .read(runtimePromptInjectionProvider.notifier)
              .bySession(sessionId)
              .map((injection) => injection.toPromptMessage())
              .toList()
        : const <PromptMessage>[];
    final assembly = const ExtensionContextAssembler().assemble(
      policy: contextPolicy,
      blockConfig: blockConfig,
      chatMessages: contextMessages,
      anchorMessageId: messageId,
      character: character,
      persona:
          personaModel ??
          (persona == null
              ? null
              : Persona(id: '', name: persona, prompt: personaPrompt)),
      systemInstruction: systemContent,
      supplementalInstruction: supplementalContent,
      legacyUserContent: contextPolicy.legacyPromptSemantics
          ? InfoBlockService.buildLegacyUserMessage(
              blockConfig: blockConfig,
              character: character,
              persona: persona,
              personaPrompt: personaModel?.prompt ?? personaPrompt,
              contextMessages: legacyContextMessages,
              previousOutput: previousOutput,
              previousBlocks: previousBlocks,
            )
          : null,
      runtimePromptMessages: runtimePromptMessages,
      mainContextSnapshot: mainModelContextSnapshot,
    );
    if (assembly.reconstructed && contextPolicy.useMainModelContext) {
      debugPrint(
        '[InfoBlockService] main context snapshot unavailable; '
        'using reconstructed context for "${blockConfig.name}"',
      );
    }

    // Resolve API config.
    final apiConfigId = blockConfig.apiConfigId;
    if (apiConfigId.isEmpty) {
      debugPrint(
        '[InfoBlockService] No API config for block "${blockConfig.name}"',
      );
      return (
        content: null,
        error: 'API config not set for block "${blockConfig.name}"',
      );
    }

    final apiConfigs = await _ref.read(apiListProvider.future);
    final apiConfig = apiConfigs.where((c) => c.id == apiConfigId).firstOrNull;
    if (apiConfig == null) {
      debugPrint('[InfoBlockService] API config not found: $apiConfigId');
      return (content: null, error: 'API config not found: $apiConfigId');
    }

    if (cancelToken?.isCancelled == true) return (content: null, error: null);

    String? rawResponse;
    try {
      rawResponse = await _callLLM(
        apiConfig: apiConfig,
        blockConfig: blockConfig,
        requestMessages: assembly.messages,
        charName: character?.name,
        userName: personaModel?.name ?? persona ?? 'User',
        cancelToken: cancelToken,
        onStreamUpdate: onStreamUpdate,
        // Diagnostic identity only — never serialized into the provider body.
        // Without it an ext block request lands in the capture log unlabeled,
        // unlike every other stage (chat, cleaner, ledger, summary).
        captureContext: LlmCaptureContext(
          stage: 'extblock.${blockConfig.type.name}',
          sessionId: sessionId,
          messageId: messageId,
          agentId: blockConfig.id,
          logicalCallId: 'extblock:${blockConfig.id}:$messageId#$swipeId',
          relatedArtifactId: messageId,
        ),
      );
    } catch (e) {
      if (cancelToken?.isCancelled == true) return (content: null, error: null);
      return (content: null, error: formatError(e));
    }

    if (cancelToken?.isCancelled == true) return (content: null, error: null);

    if (rawResponse == null || rawResponse.trim().isEmpty) {
      return (content: null, error: 'LLM returned empty response');
    }

    if (isRawAgent) {
      final raw = rawResponse.trim();
      if (raw.isEmpty) {
        return (
          content: null,
          error: blockConfig.type == BlockType.imageGen
              ? 'Image agent returned empty response'
              : 'JS agent returned empty response',
        );
      }
      return (content: raw, error: null);
    }

    final content = resolveBlockContent(
      rawResponse: rawResponse,
      blockConfig: blockConfig,
      resolvedTemplate: resolvedTemplate,
    );
    if (content == null) {
      return (
        content: null,
        error: resolvedTemplate.trim().isNotEmpty
            ? 'LLM returned empty block (no text inside <${blockTagName(blockConfig, resolvedTemplate)}> tags)'
            : 'LLM returned empty response',
      );
    }
    return (content: content, error: null);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Context helpers
  // ─────────────────────────────────────────────────────────────────────────

  /// Builds a [MacroContext] snapshot from the current block generation
  /// arguments. Used to expand `{{char}}` / `{{user}}` / `{{description}}`
  /// / `{{personality}}` / `{{scenario}}` in the LLM-bound prompt and in
  /// the post-LLM content (via [MacroExpander.expand]).
  MacroContext _macroContext({Character? character, String? persona}) {
    return MacroContext(character: character, persona: persona);
  }

  /// Loads up to [BlockConfig.previousBlocksCount] of this block's own prior
  /// outputs (same [BlockConfig.name], same session, from OTHER messages),
  /// ordered oldest → newest for prompt insertion. Returns empty when the
  /// feature is disabled (`previousBlocksCount <= 0`) or the block has no name.
  Future<List<InfoBlock>> _loadPreviousBlocks({
    required String sessionId,
    required String currentMessageId,
    required int currentSwipeId,
    required List<ChatMessage> messages,
    required BlockConfig blockConfig,
  }) async {
    final count = blockConfig.previousBlocksCount;
    if (count <= 0 || blockConfig.name.trim().isEmpty) {
      return const [];
    }

    final anchorIndex = messages.indexWhere((m) => m.id == currentMessageId);
    if (anchorIndex <= 0) return const [];
    final previousMessages = messages
        .take(anchorIndex)
        .where((m) => !m.isHidden && !m.isTyping)
        .toList();
    final previousMessageIds = previousMessages.map((m) => m.id).toList();
    if (previousMessageIds.isEmpty) return const [];
    final messageOrder = {
      for (var i = 0; i < previousMessageIds.length; i++)
        previousMessageIds[i]: i,
    };
    final swipeByMessageId = {
      for (final message in previousMessages) message.id: message.swipeId,
    };

    final repo = _ref.read(infoBlocksRepoProvider);
    final blocks = await repo.getBySessionId(sessionId);

    final filtered =
        blocks
            .where(
              (b) =>
                  b.blockName == blockConfig.name &&
                  b.content.trim().isNotEmpty &&
                  messageOrder.containsKey(b.messageId) &&
                  b.swipeId == swipeByMessageId[b.messageId] &&
                  !(b.messageId == currentMessageId &&
                      b.swipeId == currentSwipeId),
            )
            .toList()
          ..sort((a, b) {
            final byMessage = messageOrder[a.messageId]!.compareTo(
              messageOrder[b.messageId]!,
            );
            if (byMessage != 0) return byMessage;
            final bySwipe = a.swipeId.compareTo(b.swipeId);
            if (bySwipe != 0) return bySwipe;
            return a.createdAt.compareTo(b.createdAt);
          });

    final latestPerMessage = <String, InfoBlock>{};
    for (final block in filtered) {
      latestPerMessage[block.messageId] = block;
    }

    return latestPerMessage.values
        .toList()
        .reversed
        .take(count)
        .toList()
        .reversed
        .toList();
  }

  /// Returns the template sent to the LLM. Empty [blockConfig.template] means
  /// no XML wrapper — the full model reply is stored as-is.
  String _resolveTemplate(BlockConfig blockConfig) {
    final raw = blockConfig.template.trim();
    if (raw.isEmpty) return '';
    return raw.replaceAll('{{name}}', blockConfig.name);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Prompt building (system + user)
  // ─────────────────────────────────────────────────────────────────────────

  /// Builds the system message: shows the model the exact template layout it
  /// must produce, plus optional user-defined prompt instructions.
  /// Mirrors upstream `BlockService.getBlocksFullPrompt`.
  String _buildSystemMessage({
    required BlockConfig blockConfig,
    required String template,
    Character? character,
    String? persona,
  }) {
    if (blockConfig.type == BlockType.imageGen) {
      final prompt = blockConfig.prompt.trim();
      if (prompt.isNotEmpty) {
        return expand(
          prompt,
          _macroContext(character: character, persona: persona),
        );
      }
      return 'Write the roleplay response, then append the visual HTML card with '
          '[IMG:GEN] / data-iig-instruction as instructed.';
    }

    final buffer = StringBuffer();

    if (template.isNotEmpty) {
      buffer.writeln('Output format — fill in the content between these tags:');
      buffer.writeln(template);
      buffer.writeln();
    } else {
      buffer.writeln(
        'Write the block content directly. Do not wrap the answer in XML tags unless asked.',
      );
      buffer.writeln();
    }

    if (blockConfig.prompt.isNotEmpty) {
      buffer.writeln('Instructions:');
      buffer.writeln(
        expand(
          blockConfig.prompt,
          _macroContext(character: character, persona: persona),
        ),
      );
      buffer.writeln();
    }
    return buffer.toString().trimRight();
  }

  /// Builds the user message: the conversation context, character, persona,
  /// and optional chained block output. The model is meant to fill in the
  /// template based on this material.
  String _buildSupplementalMessage({
    required BlockConfig blockConfig,
    required Character? character,
    required String? persona,
    required String? previousOutput,
    List<InfoBlock> previousBlocks = const [],
  }) {
    final buffer = StringBuffer();

    if (blockConfig.contextSystemPrompt.isNotEmpty) {
      final sysPrompt = expand(
        blockConfig.contextSystemPrompt,
        _macroContext(character: character, persona: persona),
      );
      buffer.writeln(sysPrompt);
      buffer.writeln();
    }

    if (previousBlocks.isNotEmpty) {
      final label = blockConfig.name.trim().isEmpty
          ? 'this block'
          : '"${blockConfig.name}"';
      buffer.writeln(
        'Previous outputs of $label (oldest first). Continue and update the '
        'latest state instead of starting over:',
      );
      for (var i = 0; i < previousBlocks.length; i++) {
        buffer.writeln('--- #${i + 1} ---');
        buffer.writeln(_withoutImagePaths(previousBlocks[i].content).trim());
      }
      buffer.writeln();
    }

    if (previousOutput != null && previousOutput.isNotEmpty) {
      buffer.writeln('Output from previous block in chain:');
      buffer.writeln(previousOutput);
      buffer.writeln();
    }

    return buffer.toString().trimRight();
  }

  @visibleForTesting
  static String buildLegacyUserMessage({
    required BlockConfig blockConfig,
    required Character? character,
    required String? persona,
    String? personaPrompt,
    required List<ChatMessage> contextMessages,
    required String? previousOutput,
    List<InfoBlock> previousBlocks = const [],
  }) {
    final buffer = StringBuffer();

    if (blockConfig.contextSystemPrompt.isNotEmpty) {
      buffer
        ..writeln(
          expand(
            blockConfig.contextSystemPrompt,
            MacroContext(character: character, persona: persona),
          ),
        )
        ..writeln();
    }
    if (previousBlocks.isNotEmpty) {
      final label = blockConfig.name.trim().isEmpty
          ? 'this block'
          : '"${blockConfig.name}"';
      buffer.writeln(
        'Previous outputs of $label (oldest first). Continue and update the '
        'latest state instead of starting over:',
      );
      for (var i = 0; i < previousBlocks.length; i++) {
        buffer
          ..writeln('--- #${i + 1} ---')
          ..writeln(_withoutImagePaths(previousBlocks[i].content).trim());
      }
      buffer.writeln();
    }
    if (character != null) {
      buffer.writeln('Character: ${character.name}');
      if ((character.description ?? '').isNotEmpty) {
        buffer.writeln('Description: ${character.description}');
      }
      buffer.writeln();
    }
    if (persona != null && persona.isNotEmpty) {
      buffer.writeln('User Persona: $persona');
      final profile = personaPrompt?.trim();
      if (profile != null && profile.isNotEmpty) {
        buffer
          ..writeln('Persona profile:')
          ..writeln(profile);
      }
      buffer.writeln();
    }
    if (contextMessages.isNotEmpty) {
      buffer.writeln('Recent conversation:');
      for (final message in contextMessages) {
        final role = message.role == 'user' ? 'USER' : 'ASSISTANT';
        buffer.writeln('$role: ${_withoutImagePaths(message.content)}');
      }
      buffer.writeln();
    }
    if (previousOutput != null && previousOutput.isNotEmpty) {
      buffer
        ..writeln('Output from previous block in chain:')
        ..writeln(previousOutput)
        ..writeln();
    }
    return buffer.toString().trimRight();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LLM call
  // ─────────────────────────────────────────────────────────────────────────

  Future<String?> _callLLM({
    required ApiConfig apiConfig,
    required BlockConfig blockConfig,
    required List<Map<String, dynamic>> requestMessages,
    required String? charName,
    required String userName,
    CancelToken? cancelToken,
    void Function(String accumulated)? onStreamUpdate,
    LlmCaptureContext? captureContext,
  }) async {
    final useStream = onStreamUpdate != null;

    try {
      final transport = pickChatTransport(apiConfig.protocol);
      final completer = Completer<String>();
      final buffer = StringBuffer();

      await transport.stream(
        request: ChatTransportRequest.fromApiConfig(
          apiConfig,
          model: blockConfig.model.isNotEmpty
              ? blockConfig.model
              : apiConfig.model,
          messages: requestMessages,
          stream: useStream,
          charName: charName,
          userName: userName,
          captureContext: captureContext,
        ),
        cancelToken: cancelToken,
        onUpdate: useStream
            ? (delta, _) {
                if (delta.isEmpty) return;
                buffer.write(delta);
                onStreamUpdate(buffer.toString());
              }
            : null,
        onComplete: (text, reasoning, {rawResponseJson}) {
          if (!completer.isCompleted) completer.complete(text);
        },
        onError: (error) {
          if (!completer.isCompleted) completer.completeError(error);
        },
      );

      return await completer.future;
    } on DioException catch (e) {
      if (cancelToken?.isCancelled == true || CancelToken.isCancel(e)) {
        return null;
      }
      debugPrint('[InfoBlockService] LLM call failed: $e');
      rethrow;
    } catch (e) {
      if (cancelToken?.isCancelled == true) return null;
      debugPrint('[InfoBlockService] LLM call failed: $e');
      rethrow;
    }
  }
}
