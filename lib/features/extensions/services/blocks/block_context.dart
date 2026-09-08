import 'package:dio/dio.dart';

import '../../../../core/models/character.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/models/persona.dart';
import '../../../../core/llm/prompt/main_model_context_snapshot.dart';
import '../../models/block_config.dart';
import '../../models/extension_preset.dart';
import '../../models/info_block.dart';

class BlockContext {
  final String charId;
  final String sessionId;
  final String messageId;
  final int swipeId;
  final int agentSwipeId;
  final List<ChatMessage> messages;
  final BlockConfig blockConfig;
  final ExtensionPreset? preset;
  final Character character;
  final Persona? persona;
  final String? previousOutput;
  final CancelToken cancelToken;
  final String placeholderId;
  final InfoBlock placeholder;
  final MainModelContextSnapshot? mainModelContextSnapshot;

  const BlockContext({
    required this.charId,
    required this.sessionId,
    required this.messageId,
    required this.swipeId,
    this.agentSwipeId = -1,
    required this.messages,
    required this.blockConfig,
    required this.preset,
    required this.character,
    required this.persona,
    required this.previousOutput,
    required this.cancelToken,
    required this.placeholderId,
    required this.placeholder,
    this.mainModelContextSnapshot,
  });
}
