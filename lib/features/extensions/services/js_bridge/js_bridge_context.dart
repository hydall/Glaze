import 'dart:async';

import '../../../../core/db/repositories/character_repo.dart';
import '../../../../core/db/repositories/chat_repo.dart';
import '../../../../core/db/repositories/global_variables_repo.dart';
import '../../state/message_variables_notifier.dart';
import 'permission_gate.dart';

typedef GenerateTextHandler =
    Future<String> Function(
      String prompt,
      Map<String, dynamic> options,
      Map<String, dynamic> context,
    );

typedef InjectPromptHandler =
    FutureOr<Map<String, dynamic>> Function(
      String id,
      String content,
      Map<String, dynamic> options,
      Map<String, dynamic> context,
    );

typedef UninjectPromptHandler =
    FutureOr<Map<String, dynamic>> Function(
      String id,
      Map<String, dynamic> context,
    );

/// Optional handler for `glaze.triggerGeneration({ mode, reason })`.
///
/// `charId` is the resolved character id from the JS bridge context
/// (`context.characterId` first, then the current character fallback,
/// then null). Returns a structured result the JS SDK can inspect.
typedef TriggerGenerationHandlerFn =
    FutureOr<Map<String, dynamic>> Function(
      String? charId,
      Map<String, dynamic> params,
    );

/// Permission lookup. Returns `true` when the current context is allowed
/// to call the glaze capability identified by [capabilityId].
typedef PermissionCheck = bool Function(String capabilityId);

/// Snapshot accessor for the [MessageVariablesNotifier]. The bridge never
/// holds onto the notifier directly; production code injects a function that
/// reads from Riverpod.
typedef MessageVariablesAccessor = MessageVariablesNotifier Function();

/// Audio facade for `glaze.playAudio(source, options)`.
typedef PlayAudioHandler =
    FutureOr<void> Function(String? source, Map<String, dynamic> options);

/// Slash-command dispatcher. The bridge serializes the result back to the JS
/// SDK as a plain map (`{ ok, message, data }`).
typedef ExecuteCommandHandler =
    FutureOr<Map<String, dynamic>> Function(
      String command,
      Map<String, dynamic> args,
      Map<String, dynamic> context,
    );

/// Toast surface. The MVP `JsBridgeToastController` logs when no overlay is
/// available and calls `GlazeToast.show` when one is.
typedef ShowToastHandler =
    void Function(String? message, Map<String, dynamic> options);

class JsBridgeContext {
  final Map<String, dynamic> params;
  final Map<String, dynamic> context;
  final ChatRepo chatRepo;
  final CharacterRepo characterRepo;
  final GlobalVariablesRepo globalVariablesRepo;
  final MessageVariablesAccessor messageVariables;
  final String? Function() currentSessionId;
  final String? Function() currentCharacterId;
  final GenerateTextHandler generateText;
  final InjectPromptHandler injectPrompt;
  final UninjectPromptHandler uninjectPrompt;
  final TriggerGenerationHandlerFn triggerGeneration;
  final PermissionCheck permissionCheck;
  final PlayAudioHandler playAudio;
  final ExecuteCommandHandler executeCommand;
  final ShowToastHandler showToast;

  const JsBridgeContext({
    required this.params,
    required this.context,
    required this.chatRepo,
    required this.characterRepo,
    required this.globalVariablesRepo,
    required this.messageVariables,
    required this.currentSessionId,
    required this.currentCharacterId,
    required this.generateText,
    required this.injectPrompt,
    required this.uninjectPrompt,
    required this.triggerGeneration,
    required this.permissionCheck,
    required this.playAudio,
    required this.executeCommand,
    required this.showToast,
  });

  void requireCapability(String capabilityId) {
    requireBridgeCapability(permissionCheck, capabilityId);
  }

  String sessionId() {
    final value = (context['sessionId'] as String?) ?? currentSessionId();
    if (value == null || value.isEmpty) {
      throw StateError('Chat session context is not available');
    }
    return value;
  }

  String characterId() {
    final value = (context['characterId'] as String?) ?? currentCharacterId();
    if (value == null || value.isEmpty) {
      throw StateError('Character context is not available');
    }
    return value;
  }

  String? characterIdOrNull() {
    final raw = context['characterId'];
    if (raw is String && raw.isNotEmpty) return raw;
    final fallback = currentCharacterId();
    if (fallback == null || fallback.isEmpty) return null;
    return fallback;
  }

  String messageId() {
    final value = context['messageId'] as String?;
    if (value == null || value.isEmpty) {
      throw StateError('Message id context is not available');
    }
    return value;
  }
}

Map<String, dynamic> asBridgeMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}
