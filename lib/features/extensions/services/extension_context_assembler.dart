import '../../../core/llm/history_assembler.dart';
import '../../../core/llm/prompt/main_model_context_snapshot.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/character.dart';
import '../../../core/models/persona.dart';
import '../../image_gen/services/image_tag_markup.dart';
import '../models/block_config.dart';
import '../models/extension_context_policy.dart';
import 'block_context_builder.dart';
import 'macro_expander.dart';

class ExtensionContextAssembly {
  final List<Map<String, dynamic>> messages;
  final bool reconstructed;

  const ExtensionContextAssembly({
    required this.messages,
    required this.reconstructed,
  });
}

/// Centrally assembles context for every LLM-backed extension block.
///
/// The card and the persona always come from the models, whichever path the
/// rest of the context takes.
///
/// Exact snapshots exist only during the generation that produced the anchor.
/// Historical/manual runs after restart reconstruct card/persona/history from
/// persisted chat data instead of failing or pretending the original prompt is
/// still available.
class ExtensionContextAssembler {
  const ExtensionContextAssembler();

  ExtensionContextAssembly assemble({
    required ExtensionContextPolicy policy,
    required BlockConfig blockConfig,
    required List<ChatMessage> chatMessages,
    required String anchorMessageId,
    required Character? character,
    required Persona? persona,
    required String systemInstruction,
    required String supplementalInstruction,
    String? legacyUserContent,
    List<PromptMessage> runtimePromptMessages = const [],
    MainModelContextSnapshot? mainContextSnapshot,
  }) {
    final snapshot = mainContextSnapshot;
    if (policy.legacyPromptSemantics) {
      return ExtensionContextAssembly(
        messages: _assembleLegacyWireRequest(
          systemInstruction: systemInstruction,
          userContent: legacyUserContent ?? supplementalInstruction,
        ),
        reconstructed: true,
      );
    }
    if (policy.useMainModelContext && snapshot != null) {
      final messages = snapshot.providerMessages.map(_mutableCopy).toList();
      _appendCanonicalAssistant(
        messages,
        chatMessages: chatMessages,
        anchorMessageId: anchorMessageId,
      );
      _appendBlockInstruction(
        messages,
        systemInstruction: systemInstruction,
        supplementalInstruction: supplementalInstruction,
      );
      return ExtensionContextAssembly(messages: messages, reconstructed: false);
    }

    final filterableMessages = snapshot?.filterablePromptMessages;
    // The card and the persona are built from the models, never cut out of
    // the snapshot: presets often switch the standard card blocks off and
    // place `{{description}}` / `{{persona}}` inside their own blocks, where
    // a filter by block id cannot find them. The snapshot's payload carries
    // the character and persona the main request was actually built for.
    final messages = [
      ..._identityMessages(
        policy: policy,
        character: filterableMessages == null
            ? character
            : snapshot!.promptPayload.character,
        persona: filterableMessages == null
            ? persona
            : snapshot!.promptPayload.persona ?? persona,
      ),
      ...filterableMessages == null
          ? _assembleLegacyFallback(
              blockConfig: blockConfig,
              chatMessages: chatMessages,
              anchorMessageId: anchorMessageId,
              runtimePromptMessages: policy.includeRuntimePrompts
                  ? runtimePromptMessages
                  : const [],
            )
          : _filterPromptSnapshot(
              filterableMessages,
              policy,
              blockConfig.contextMessageCount,
            ),
    ];

    _appendCanonicalAssistant(
      messages,
      chatMessages: chatMessages,
      anchorMessageId: anchorMessageId,
    );
    _appendBlockInstruction(
      messages,
      systemInstruction: systemInstruction,
      supplementalInstruction: supplementalInstruction,
    );
    return ExtensionContextAssembly(
      messages: messages,
      reconstructed: filterableMessages == null,
    );
  }

  List<Map<String, dynamic>> _filterPromptSnapshot(
    List<PromptMessage> source,
    ExtensionContextPolicy policy,
    int messageCount,
  ) {
    final history = source.where((message) => message.isHistory).toList();
    final selectedHistory = messageCount == 0
        ? const <PromptMessage>[]
        : messageCount < 0 || messageCount >= history.length
        ? history
        : history.sublist(history.length - messageCount);
    final selectedHistorySet = selectedHistory.toSet();
    return source
        .where(
          (message) => message.isHistory
              ? selectedHistorySet.contains(message)
              : _includesMessage(message, policy),
        )
        .map((message) => _mutableCopy(message.toApiMap()))
        .toList();
  }

  List<Map<String, dynamic>> _assembleLegacyWireRequest({
    required String systemInstruction,
    required String userContent,
  }) {
    return [
      {'role': 'system', 'content': systemInstruction},
      {'role': 'user', 'content': userContent},
    ];
  }

  bool _includesMessage(PromptMessage message, ExtensionContextPolicy policy) {
    final id = (message.blockId ?? '').toLowerCase();
    if (message.isLorebook ||
        id == 'worldinfobefore' ||
        id == 'worldinfoafter') {
      return policy.includeLorebooks;
    }
    if (message.isSummary || id == 'summary') return policy.includeSummary;
    if (id == 'memory' || id == 'recalled_messages') {
      return policy.includeMemoryBooks;
    }
    if (id == 'studio_session_state' || id == 'current_character_state') {
      return policy.includeStudioState;
    }
    if (id == 'authors_note') return policy.includeAuthorsNote;
    if (id.startsWith('runtime_prompt:')) return policy.includeRuntimePrompts;
    // Built from the models by [_identityMessages] instead.
    if (_identityBlockIds.contains(id)) return false;
    return policy.includeMainPresetInstructions;
  }

  static const _identityBlockIds = {
    'char_card',
    'char_personality',
    'scenario',
    'example_dialogue',
    'user_persona',
  };

  List<Map<String, dynamic>> _identityMessages({
    required ExtensionContextPolicy policy,
    required Character? character,
    required Persona? persona,
  }) {
    final macros = MacroContext(character: character, persona: persona?.name);
    String field(String label, String? value) {
      final text = expand(value ?? '', macros).trim();
      return text.isEmpty ? '' : '$label: $text';
    }

    final messages = <Map<String, dynamic>>[];
    if (policy.includeCharacterCard && character != null) {
      final content = <String>[
        'Character: ${character.name}',
        field('Description', character.description),
        field('Personality', character.personality),
        field('Scenario', character.scenario),
        field('Example dialogue', character.mesExample),
      ].where((line) => line.isNotEmpty).join('\n');
      messages.add({'role': 'system', 'content': content});
    }
    if (policy.includePersona && persona != null) {
      messages.add({
        'role': 'system',
        'content': [
          'User persona: ${persona.name}',
          expand(persona.prompt ?? '', macros).trim(),
        ].where((line) => line.isNotEmpty).join('\n'),
      });
    }
    return messages;
  }

  List<Map<String, dynamic>> _assembleLegacyFallback({
    required BlockConfig blockConfig,
    required List<ChatMessage> chatMessages,
    required String anchorMessageId,
    List<PromptMessage> runtimePromptMessages = const [],
  }) {
    final messages = <Map<String, dynamic>>[];
    final scoped = buildContextMessages(
      messages: chatMessages,
      anchorMessageId: anchorMessageId,
      count: blockConfig.contextMessageCount,
    );
    final history = scoped
        .map(
          (message) => PromptMessage(
            role: message.role,
            // Image blocks reach a block agent as the tag that asked for the
            // picture: the stored element's file paths are this device's, and
            // an agent that reads one writes one back (INV-IG12).
            content: ImageTagMarkup.reduceBlocksToInstructions(message.content),
            isHistory: true,
            sourceMessageId: message.id,
          ),
        )
        .toList();
    messages.addAll(
      interleaveDepthWithHistory(history, runtimePromptMessages).map(
        (message) => {
          ...message.toApiMap(),
          if (message.sourceMessageId != null)
            '_sourceMessageId': message.sourceMessageId,
        },
      ),
    );
    return messages;
  }

  void _appendCanonicalAssistant(
    List<Map<String, dynamic>> messages, {
    required List<ChatMessage> chatMessages,
    required String anchorMessageId,
  }) {
    final anchor = chatMessages
        .where((message) => message.id == anchorMessageId)
        .firstOrNull;
    if (anchor == null ||
        anchor.role == 'user' ||
        anchor.content.trim().isEmpty) {
      _stripInternalMetadata(messages);
      return;
    }
    messages.removeWhere(
      (message) => message['_sourceMessageId'] == anchorMessageId,
    );
    _stripInternalMetadata(messages);
    messages.add({
      'role': 'assistant',
      'content': ImageTagMarkup.reduceBlocksToInstructions(anchor.content),
    });
  }

  void _appendBlockInstruction(
    List<Map<String, dynamic>> messages, {
    required String systemInstruction,
    required String supplementalInstruction,
  }) {
    if (systemInstruction.trim().isNotEmpty) {
      messages.add({'role': 'system', 'content': systemInstruction});
    }
    if (supplementalInstruction.trim().isNotEmpty) {
      messages.add({'role': 'user', 'content': supplementalInstruction});
    }
  }

  void _stripInternalMetadata(List<Map<String, dynamic>> messages) {
    for (final message in messages) {
      message.remove('_sourceMessageId');
    }
  }

  Map<String, dynamic> _mutableCopy(Map<String, dynamic> source) =>
      source.map((key, value) => MapEntry(key, _mutableValue(value)));

  Object? _mutableValue(Object? value) {
    if (value is Map) {
      return value.map(
        (key, child) => MapEntry(key.toString(), _mutableValue(child)),
      );
    }
    if (value is List) return value.map(_mutableValue).toList();
    return value;
  }
}
